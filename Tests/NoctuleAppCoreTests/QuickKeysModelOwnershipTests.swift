// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleMockScanner
@testable import NoctuleAppCore

// QuickKeysModel and a late `GLT` reply for another parent (design `docs/specs/2026-11-18-quick-keys-design.md` §5.4,
// §10 "Late replies"; the SDS200's residual of final review C1). Replies are matched by command name, so a `GLT,DEPT`
// reply later than its read's timeout and rest can answer another system's `GLT,DEPT` (or a `GLT,SYS` another list's).
// Every `Index` in the Favorites tree is unique across the whole tree [hw, 2026-11-19], so a reply that puts an item
// under another parent than the one known to hold it is refused; tree switches wait until every list has been read
// this open, since a stray whose true owner hasn't been read yet is caught only when the owner is; and a `GLT` read
// that times out is retried once in place. Against MockSDS200 over UDP and MockSerialScanner (SDS150) over serial,
// each on a stepped clock with `quickKeySetDelay: .zero`, behind a `LateReplyTransport` and a `RefusingTransport`.
// Every name is fictional.

private struct QKOwnRig {
    let label: String
    let client: ScannerClient
    let cacheURL: URL
    let late: LateReplyTransport
    let refusing: RefusingTransport
    let favorites: @Sendable () async -> MockFavorites
    let setFavorites: @Sendable (MockFavorites) async -> Void
    let commands: @Sendable () async -> [String]
}

/// A transport that makes a reply arrive late, or answer another read, deterministically, by the commands' exact
/// text (e.g. `GLT,DEPT,900`). The commands still reach the mock (a misdirected one as its new text).
/// - `hold`: the reply to the next `command` written is held back (that read times out) and handed on just before
///   the first command `releaseBefore` accepts is written: a late reply that answers a later read of the same name.
///   The next `swallowRepeats` writes of the same text then get no reply at all (their reads time out too), so the
///   held reply can outlast the in-place retry and the rest after it.
/// - `swallow`: the next `times` writes of `command` get no reply, after `skipping` writes that do.
/// - `misdirect`: the next write of `command` (after `skipping` that don't) goes out as `instead`, so its read takes
///   another scope's answer, as a
///   stray reply would, with no reply of its own still on the way.
final class LateReplyTransport: ScannerTransport, Sendable {
    private struct State {
        var holdText: String?
        var holding: String?
        var held: ScannerResponse?
        var releaseBefore: (@Sendable (String) -> Bool)?
        var released = false
        var swallowCounts: [String: Int] = [:]
        var swallowSkips: [String: Int] = [:]
        var swallowing: String?
        var misdirections: [String: (instead: ScannerCommand, skip: Int)] = [:]
        var continuation: AsyncStream<ScannerResponse>.Continuation?
    }

    private let base: any ScannerTransport
    private let state = Mutex(State())

    init(_ base: any ScannerTransport) { self.base = base }

    func hold(_ command: String, swallowRepeats: Int = 0, releaseBefore: @escaping @Sendable (String) -> Bool) {
        state.withLock {
            $0.holdText = command
            $0.releaseBefore = releaseBefore
            $0.held = nil
            $0.released = false
            if swallowRepeats > 0 { $0.swallowCounts[command] = swallowRepeats }
        }
    }

    func swallow(_ command: String, times: Int, skipping: Int = 0) {
        state.withLock {
            $0.swallowCounts[command] = times
            $0.swallowSkips[command] = skipping
        }
    }

    func misdirect(_ command: String, to instead: ScannerCommand, skipping: Int = 0) {
        state.withLock { $0.misdirections[command] = (instead, skipping) }
    }

    var hasHeld: Bool { state.withLock { $0.held != nil || $0.released } }
    var released: Bool { state.withLock { $0.released } }

    func open() async throws { try await base.open() }
    func close() async { await base.close() }

    func send(_ command: ScannerCommand) async throws {
        let text = ([command.name] + command.arguments).joined(separator: ",")
        let (late, continuation, outgoing) = state.withLock {
            state -> (ScannerResponse?, AsyncStream<ScannerResponse>.Continuation?, ScannerCommand) in
            var late: ScannerResponse?
            if let held = state.held, let release = state.releaseBefore, release(text) {
                late = held
                state.held = nil
                state.released = true
            }
            var outgoing = command
            if let misdirection = state.misdirections[text] {
                if misdirection.skip > 0 {
                    state.misdirections[text] = (misdirection.instead, misdirection.skip - 1)
                } else {
                    state.misdirections[text] = nil
                    outgoing = misdirection.instead
                }
            }
            // Set before the write: the reply can come back before `send` returns.
            if state.holdText == text {
                state.holding = command.name
                state.holdText = nil
            } else if let skips = state.swallowSkips[text], skips > 0 {
                state.swallowSkips[text] = skips - 1
            } else if let count = state.swallowCounts[text], count > 0 {
                state.swallowing = command.name
                state.swallowCounts[text] = count - 1
            }
            return (late, state.continuation, outgoing)
        }
        if let late { continuation?.yield(late) }
        try await base.send(outgoing)
    }

    var responses: AsyncStream<ScannerResponse> {
        let upstream = base.responses
        return AsyncStream { continuation in
            state.withLock { $0.continuation = continuation }
            let relay = Task { [self] in
                for await response in upstream {
                    let pass = state.withLock { state -> Bool in
                        if state.holding == response.command, state.held == nil {
                            state.held = response
                            state.holding = nil
                            return false
                        }
                        if state.swallowing == response.command {
                            state.swallowing = nil
                            return false
                        }
                        return true
                    }
                    if pass { continuation.yield(response) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}

/// Runs `body` against the network SDS200 mock, then the serial SDS150 mock, each with `favorites` (the default
/// tree when nil), `cache` written first when given, and its own temporary cache directory; the client's transport
/// is a `LateReplyTransport` over a `RefusingTransport`. Stops the client and the mock on every path.
@MainActor
private func onBothMocks(favorites: MockFavorites? = nil, cache: [UInt32: QuickKeyListTree]? = nil,
                         replyDelays: [String: Duration] = [:], commandTimeout: Duration = .milliseconds(300),
                         _ body: @MainActor (QKOwnRig) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("qk-own-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func cacheURL(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent("\(name)/quick-keys.json")
        if let cache { try QuickKeysCache.save(cache, to: url) }
        return url
    }
    do {
        let options = MockSDS200.Options(clock: .stepped(at: 3), replyDelays: replyDelays, quickKeySetDelay: .zero)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        if let favorites { await mock.setFavorites(favorites) }
        let refusing = RefusingTransport(UDPTransport(host: "127.0.0.1", port: ports.udpPort))
        let late = LateReplyTransport(refusing)
        let client = ScannerClient(transport: late, commandTimeout: commandTimeout)
        var failure: (any Error)?
        do {
            try await client.connect()
            let rig = QKOwnRig(label: "SDS200 over UDP", client: client, cacheURL: try cacheURL("sds200"), late: late,
                               refusing: refusing, favorites: { await mock.favorites },
                               setFavorites: { await mock.setFavorites($0) },
                               commands: { await mock.control.receivedCommands })
            try await body(rig)
        } catch { failure = error }
        await client.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
    do {
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 3), personality: .sds150,
                                     replyDelays: replyDelays, quickKeySetDelay: .zero)
        var failure: (any Error)?
        var client: ScannerClient?
        do {
            let path = try await mock.start()
            if let favorites { await mock.setFavorites(favorites) }
            let refusing = RefusingTransport(SerialTransport(path: path))
            let late = LateReplyTransport(refusing)
            let connected = ScannerClient(transport: late, commandTimeout: commandTimeout)
            client = connected
            try await connected.connect()
            let rig = QKOwnRig(label: "SDS150 over serial", client: connected, cacheURL: try cacheURL("sds150"),
                               late: late, refusing: refusing, favorites: { await mock.favorites },
                               setFavorites: { await mock.setFavorites($0) }, commands: { await mock.receivedCommands })
            try await body(rig)
        } catch { failure = error }
        await client?.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
}

@MainActor
private func makeModel(_ rig: QKOwnRig, pollInterval: Duration = .milliseconds(150)) -> QuickKeysModel {
    let model = QuickKeysModel(cacheURL: rig.cacheURL, pollInterval: pollInterval)
    let client = rig.client
    model.attach(control: { client })
    return model
}

@MainActor
private func shutDown(_ model: QuickKeysModel) async {
    model.close()
    model.detach()
    await model.quiesce()
}

@MainActor
private func allFresh(_ model: QuickKeysModel) -> Bool {
    !model.lists.isEmpty && model.lists.allSatisfy { model.trees[$0.index]?.freshness == .fresh }
}

/// Every system, department and site row of `model`'s trees.
@MainActor
private func treeRows(_ model: QuickKeysModel) -> [QuickKeyRow] {
    var rows: [QuickKeyRow] = []
    for list in model.lists {
        for system in model.trees[list.index]?.systems ?? [] {
            rows.append(.system(list: list.index, system: system.index))
            rows += system.children.map { .child(list: list.index, system: system.index, child: $0.index) }
        }
    }
    return rows
}

/// The list indexes of every `GLT,SYS,<index>` in `commands`, in order.
private func systemReads(_ commands: [String]) -> [UInt32] {
    commands.compactMap { command in
        let parts = command.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GLT", parts[1] == "SYS" else { return nil }
        return UInt32(parts[2])
    }
}

/// Any quick-key set: `FQK` with arguments, `SQK` with more than one, `DQK` with more than two.
private func sets(_ commands: [String]) -> [String] {
    commands.filter { setValues($0) != nil }
}

/// The 100 values of a quick-key set, or nil for anything else.
private func setValues(_ command: String) -> [String]? {
    let parts = command.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    switch parts.first?.uppercased() {
    case "FQK" where parts.count > 1: return Array(parts.dropFirst(1))
    case "SQK" where parts.count > 2: return Array(parts.dropFirst(2))
    case "DQK" where parts.count > 3: return Array(parts.dropFirst(3))
    default: return nil
    }
}

/// True when `values` is 100 values, `"0"` everywhere but `key`, which is `value`.
private func namesOnlyKey(_ values: [String]?, _ key: Int, _ value: String) -> Bool {
    guard let values, values.count == 100 else { return false }
    return values.indices.allSatisfy { values[$0] == ($0 == key ? value : "0") }
}

private func count(_ command: String, in commands: [String]) -> Int {
    commands.filter { $0 == command }.count
}

private func system(_ index: UInt32, in tree: QuickKeyListTree?) -> QuickKeyListTree.SystemRow? {
    tree?.systems.first { $0.index == index }
}

/// One list, 30 (F5), with two conventional systems: 900 (S0: 700 Mock Alpha D0, 701 Mock Bravo D1) and 901 (S1:
/// 710 Mock Charlie D0, 711 Mock Delta D1). Every key on.
private func twoConventionalSystems() -> MockFavorites {
    MockFavorites(
        lists: [.init(index: 30, name: "Mock Conventional", quickKey: 5)],
        systems: [.init(index: 900, listIndex: 30, name: "Mock Conv X", type: "Conventional", quickKey: 0),
                  .init(index: 901, listIndex: 30, name: "Mock Conv Y", type: "Conventional", quickKey: 1)],
        children: [.init(index: 700, systemIndex: 900, kind: .department, name: "Mock Alpha", quickKey: 0),
                   .init(index: 701, systemIndex: 900, kind: .department, name: "Mock Bravo", quickKey: 1),
                   .init(index: 710, systemIndex: 901, kind: .department, name: "Mock Charlie", quickKey: 0),
                   .init(index: 711, systemIndex: 901, kind: .department, name: "Mock Delta", quickKey: 1)])
}

/// Lists 60 (F2: system 960 S0, department 770 Mock East Gate D0) and 61 (F3: system 961 S0, department 771 Mock West
/// Gate D0), read in that order. Every key on.
private func eastAndWest() -> MockFavorites {
    MockFavorites(
        lists: [.init(index: 60, name: "Mock East", quickKey: 2), .init(index: 61, name: "Mock West", quickKey: 3)],
        systems: [.init(index: 960, listIndex: 60, name: "Mock East Conv", type: "Conventional", quickKey: 0),
                  .init(index: 961, listIndex: 61, name: "Mock West Conv", type: "Conventional", quickKey: 0)],
        children: [.init(index: 770, systemIndex: 960, kind: .department, name: "Mock East Gate", quickKey: 0),
                   .init(index: 771, systemIndex: 961, kind: .department, name: "Mock West Gate", quickKey: 0)])
}

/// `eastAndWest()` reprogrammed since `cachedEastAndWest()`: list 60 now holds 961 (771) and list 61 holds 960 (770),
/// each cache claim crossing the other; plus list 62 (F4: system 962 S0, department 772 Mock North Gate D0), read last.
private func swappedEastAndWest() -> MockFavorites {
    var favorites = eastAndWest()
    for at in favorites.systems.indices { favorites.systems[at].listIndex = favorites.systems[at].listIndex == 60 ? 61 : 60 }
    favorites.lists.append(.init(index: 62, name: "Mock North", quickKey: 4))
    favorites.systems.append(.init(index: 962, listIndex: 62, name: "Mock North Conv", type: "Conventional", quickKey: 0))
    favorites.children.append(.init(index: 772, systemIndex: 962, kind: .department, name: "Mock North Gate",
                                    quickKey: 0))
    return favorites
}

/// `eastAndWest()` as a previous run would have cached it.
private func cachedEastAndWest() -> [UInt32: QuickKeyListTree] {
    func tree(_ system: UInt32, _ name: String, _ child: UInt32, _ childName: String) -> QuickKeyListTree {
        QuickKeyListTree(systems: [.init(index: system, name: name, type: "Conventional", key: 0, avoided: false,
                                         state: nil,
                                         children: [.init(index: child, name: childName, kind: .department, key: 0,
                                                          avoided: false, state: nil)])],
                         freshness: .checking)
    }
    return [60: tree(960, "Mock East Conv", 770, "Mock East Gate"), 61: tree(961, "Mock West Conv", 771, "Mock West Gate")]
}

/// `twoConventionalSystems()` as a previous run would have cached it.
private func cachedTwoConventionalSystems() -> [UInt32: QuickKeyListTree] {
    func child(_ index: UInt32, _ name: String, _ key: Int) -> QuickKeyListTree.ChildRow {
        .init(index: index, name: name, kind: .department, key: key, avoided: false, state: nil)
    }
    let systems: [QuickKeyListTree.SystemRow] = [
        .init(index: 900, name: "Mock Conv X", type: "Conventional", key: 0, avoided: false, state: nil,
              children: [child(700, "Mock Alpha", 0), child(701, "Mock Bravo", 1)]),
        .init(index: 901, name: "Mock Conv Y", type: "Conventional", key: 1, avoided: false, state: nil,
              children: [child(710, "Mock Charlie", 0), child(711, "Mock Delta", 1)]),
    ]
    return [30: QuickKeyListTree(systems: systems, freshness: .checking)]
}

private func scannerInfo(_ xml: String) throws -> ScannerInfo {
    try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

/// A scanning status naming list 1 (with the wrong `Q_Key`, as the real scanner does) and system 101.
private func scanningListOne() throws -> ScannerInfo {
    try scannerInfo("<ScannerInfo Mode=\"Trunk Scan\" V_Screen=\"trunk_scan\">"
        + "<MonitorList Name=\"Mock List\" Index=\"1\" ListType=\"FL\" Q_Key=\"0\" N_Tag=\"None\" DB_Counter=\"1\"/>"
        + "<System Name=\"Mock System\" Index=\"101\" Avoid=\"Off\" SystemType=\"P25 Trunk\" Q_Key=\"0\" N_Tag=\"None\" Hold=\"Off\"/>"
        + "</ScannerInfo>")
}

private func inMenu() throws -> ScannerInfo {
    try scannerInfo("<ScannerInfo Mode=\"Menu tree\" V_Screen=\"menu_selection\"><MenuSummary name=\"MENU\" index=\"4293060001\"/></ScannerInfo>")
}

/// `MockFavorites.default` with system 102 moved from list 1 to list 4, as S3.
private func moving102ToListFour() -> MockFavorites {
    var moved = MockFavorites.default
    if let at = moved.systems.firstIndex(where: { $0.index == 102 }) {
        moved.systems[at].listIndex = 4
        moved.systems[at].quickKey = 3
    }
    return moved
}

/// A structure-only tree for list 1 of the default tree, as a previous run would have cached it (101, then 102).
private func cachedListOne() -> [UInt32: QuickKeyListTree] {
    func child(_ index: UInt32, _ name: String, _ key: Int?, _ kind: FavoritesChild.Kind = .department)
        -> QuickKeyListTree.ChildRow {
        .init(index: index, name: name, kind: kind, key: key, avoided: false, state: nil)
    }
    let systems: [QuickKeyListTree.SystemRow] = [
        .init(index: 101, name: "Riverbend County P25", type: "P25 Trunk", key: 0, avoided: false, state: nil,
              children: [child(118, "Road Crews", nil), child(200, "Lakeview Fire", 0),
                         child(201, "Riverbend Sheriff", 1), child(203, "Lakeview Fire Tac", 0),
                         child(301, "Riverbend Simulcast", 0, .site)]),
        .init(index: 102, name: "Mock Simplex", type: "Conventional", key: 1, avoided: false, state: nil,
              children: [child(400, "Simplex A", 0), child(401, "Simplex B", 1), child(402, "Simplex C", 2)]),
    ]
    return [1: QuickKeyListTree(systems: systems, freshness: .checking)]
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct QuickKeysModelOwnershipTests {
    // MARK: The hardware fact the guard rests on

    @Test func theMockTreesIndexesAreUniqueAcrossKinds() {
        // Every `Index` in the owner's trees is unique, between a department and a site and between a system and a
        // child too [hw, 2026-11-19]; the built-ins (the `Unknown` department) repeat and are dropped by the parser.
        let tree = MockFavorites.default
        let unknown: UInt32 = 4_294_967_295
        let indexes = tree.lists.map(\.index) + tree.systems.map(\.index)
            + tree.children.map(\.index).filter { $0 != unknown }
        #expect(Set(indexes).count == indexes.count, "\(indexes)")
    }

    // MARK: A stray reply is refused

    @Test func aLateDepartmentsReplyAfterTheRestIsRefused() async throws {
        // The reply to `GLT,DEPT,900` is held; the in-place retry gets no reply either, so list 30's read fails and
        // rests. The held reply comes just before `GLT,DEPT,901` of the next read: it carries 900's departments (700,
        // 701), which that same read has just put under 900, so it is refused, and system 901 never shows them.
        // Before, 901 showed Mock Alpha and Mock Bravo, fresh, and a click under it set a key of 900's.
        try await onBothMocks(favorites: twoConventionalSystems()) { rig in
            rig.late.hold("GLT,DEPT,900", swallowRepeats: 1) { $0 == "GLT,DEPT,901" }
            let model = makeModel(rig)
            model.open()
            model.showList(30)
            var wrong: [String] = []
            try await waitUntil("the late reply, then list 30 read (\(rig.label))") {
                if let children = system(901, in: model.trees[30])?.children.map(\.index), children != [710, 711] {
                    wrong.append("901 showed \(children) (\(String(describing: model.trees[30]?.freshness)))")
                }
                return rig.late.released && model.trees[30]?.freshness == .fresh
            }
            #expect(wrong.isEmpty, "\(rig.label): \(wrong)")
            let tree = try #require(model.trees[30])
            #expect(system(900, in: tree)?.children.map(\.index) == [700, 701], "\(rig.label)")
            #expect(system(901, in: tree)?.children.map(\.index) == [710, 711], "\(rig.label)")
            // The held read, its retry, the read after the rest, and the read after the refusal.
            #expect(await count("GLT,DEPT,900", in: rig.commands()) >= 4, "\(rig.label)")
            // A click on Mock Charlie switches Mock Charlie, and nothing else.
            #expect(model.switchState(for: .child(list: 30, system: 901, child: 710)) == .on, "\(rig.label)")
            let mark = await rig.commands().count
            await model.toggle(.child(list: 30, system: 901, child: 710))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("DQK,5,1,") == true, "\(rig.label): \(after)")
            #expect(namesOnlyKey(sets(after).first.flatMap(setValues), 0, "1"), "\(rig.label)")
            let favorites = await rig.favorites()
            #expect(favorites.children.first { $0.index == 710 }?.isOn == false, "\(rig.label)")
            #expect(favorites.children.first { $0.index == 700 }?.isOn == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aLateSystemsReplyIsRefusedOnAnotherList() async throws {
        // The final review's probe, on lists: the reply to `GLT,SYS,1` is held, its in-place retry gets none, list 1
        // is read again after the rest and is fresh; the held reply then answers `GLT,SYS,4`. Its systems (101, 102) are
        // list 1's, read this open, so it is refused, list 1 is checked again, and list 4 is read again. List 4 never
        // shows list 1's systems, and a click on its system 120 sends `SQK,1` naming 120's key and nothing else.
        try await onBothMocks { rig in
            rig.late.hold("GLT,SYS,1", swallowRepeats: 1) { $0 == "GLT,SYS,4" }
            let model = makeModel(rig)
            model.open()
            model.showList(1)
            var wrong: [String] = []
            try await waitUntil("the late reply, then every list read (\(rig.label))") {
                if let systems = model.trees[4]?.systems.map(\.index), systems.contains(101) || systems.contains(102) {
                    wrong.append("list 4 showed \(systems)")
                }
                return rig.late.released && allFresh(model) && !model.isCheckingOtherLists
            }
            #expect(wrong.isEmpty, "\(rig.label): \(wrong)")
            #expect(model.trees[1]?.systems.map(\.index) == [101, 102], "\(rig.label)")
            #expect(model.trees[4]?.systems.map(\.index) == [120, 121, 122], "\(rig.label)")
            let reads = systemReads(await rig.commands())
            #expect(reads.filter { $0 == 4 }.count >= 2, "list 4 read again (\(rig.label)): \(reads)")
            #expect(reads.filter { $0 == 1 }.count >= 4, "list 1 checked again (\(rig.label)): \(reads)")
            let mark = await rig.commands().count
            #expect(model.switchState(for: .system(list: 4, system: 120)) == .on, "\(rig.label)")
            await model.toggle(.system(list: 4, system: 120))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("SQK,1,") == true, "\(rig.label): \(after)")
            #expect(namesOnlyKey(sets(after).first.flatMap(setValues), 0, "1"), "\(rig.label)")
            let favorites = await rig.favorites()
            #expect(favorites.systems.first { $0.index == 120 }?.isOn == false, "\(rig.label)")
            #expect(favorites.systems.first { $0.index == 101 }?.isOn == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aStrayOnAListReadBeforeItsOwnerIsCaughtWhenTheOwnerIsRead() async throws {
        // List 60's `GLT,SYS,60` takes list 61's answer (system 961), as a stray would, and nothing holds 961 yet, so
        // list 60 reads it as its own. When list 61 is read, its 961 is claimed by list 60: both lists are checked
        // again, and they end with their own systems. Meanwhile no tree row was ever switchable: list 61 hadn't been
        // read, so tree switches were waiting for every list.
        try await onBothMocks(favorites: eastAndWest()) { rig in
            rig.late.misdirect("GLT,SYS,60", to: try ScannerCommand("GLT", "SYS", "61"))
            let model = makeModel(rig)
            model.open()
            var switchable: [String] = []
            var sawStray = false
            try await waitUntil("both lists read with their own systems (\(rig.label))") {
                if system(961, in: model.trees[60]) != nil { sawStray = true }
                for row in treeRows(model) {
                    let state = model.switchState(for: row)
                    if (state == .on || state == .off), system(961, in: model.trees[60]) != nil {
                        switchable.append("\(row) \(state)")
                    }
                }
                return allFresh(model) && !model.isCheckingOtherLists
                    && model.trees[60]?.systems.map(\.index) == [960]
            }
            #expect(sawStray, "list 60 took the stray (\(rig.label))")
            #expect(switchable.isEmpty, "\(rig.label): \(switchable)")
            #expect(system(960, in: model.trees[60])?.children.map(\.index) == [770], "\(rig.label)")
            #expect(model.trees[61]?.systems.map(\.index) == [961], "\(rig.label)")
            #expect(system(961, in: model.trees[61])?.children.map(\.index) == [771], "\(rig.label)")
            // The scanner saw list 61's systems read for list 60, then list 61's read refused, list 60 read again, and
            // list 61 read again.
            let reads = systemReads(await rig.commands())
            #expect(reads.contains(60), "list 60 checked again (\(rig.label)): \(reads)")
            #expect(reads.filter { $0 == 61 }.count >= 3, "\(rig.label): \(reads)")
            #expect(sets(await rig.commands()).isEmpty, "\(rig.label)")
            // Now every row switches, under its own list's key.
            let mark = await rig.commands().count
            #expect(model.switchState(for: .system(list: 61, system: 961)) == .on, "\(rig.label)")
            await model.toggle(.system(list: 61, system: 961))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("SQK,3,") == true, "\(rig.label): \(after)")
            #expect(await rig.favorites().systems.first { $0.index == 961 }?.isOn == false, "\(rig.label)")
            #expect(await rig.favorites().systems.first { $0.index == 960 }?.isOn == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aCachedClaimIsSettledByTheOtherListsRead() async throws {
        // The cache says system 102 is list 1's, but the radio has since moved it to list 4 (as S3). List 4 is read
        // before list 1: its 102 conflicts with a claim that isn't fresh (from the cache), so the reply is refused,
        // list 1 is read first, no longer holds 102, and list 4 is read again and keeps it.
        try await onBothMocks(favorites: moving102ToListFour(), cache: cachedListOne()) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("every list read (\(rig.label))") { allFresh(model) && !model.isCheckingOtherLists }
            let reads = systemReads(await rig.commands())
            #expect(Array(reads.prefix(4)) == [0, 4, 1, 4], "\(rig.label): \(reads)")
            #expect(model.trees[1]?.systems.map(\.index) == [101], "\(rig.label)")
            #expect(Set(model.trees[4]?.systems.map(\.index) ?? []) == [102, 120, 121, 122], "\(rig.label)")
            #expect(model.trees[4]?.readError == nil, "\(rig.label)")
            let saved = try #require(QuickKeysCache.load(from: rig.cacheURL), "\(rig.label)")
            #expect(saved[1]?.systems.map(\.index) == [101], "\(rig.label)")
            #expect(system(102, in: saved[4]) != nil, "\(rig.label)")
            // A click on 102 now sends `SQK,1` naming its new key.
            let mark = await rig.commands().count
            #expect(model.switchState(for: .system(list: 4, system: 102)) == .on, "\(rig.label)")
            await model.toggle(.system(list: 4, system: 102))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("SQK,1,") == true, "\(rig.label): \(after)")
            #expect(namesOnlyKey(sets(after).first.flatMap(setValues), 3, "1"), "\(rig.label)")
            await shutDown(model)
        }
    }

    // MARK: Tree switches wait for every list

    @Test func treeSwitchesWaitForEveryListTilesDont() async throws {
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(60)], commandTimeout: .milliseconds(600)) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("list 0 read (\(rig.label))") { model.trees[0]?.freshness == .fresh }
            #expect(!allFresh(model), "\(rig.label)")
            // Its rows show their states, but no switch works until the other lists are read.
            #expect(system(110, in: model.trees[0])?.state == .on, "\(rig.label)")
            #expect(model.switchState(for: .system(list: 0, system: 110)) == .checkingOtherLists, "\(rig.label)")
            // Rows that wouldn't switch anyway keep saying why (S0 is shared by 110 and 111; 610 has no key).
            #expect(model.switchState(for: .child(list: 0, system: 110, child: 500)) == .sharedSystemKey(0),
                    "\(rig.label)")
            #expect(model.switchState(for: .child(list: 0, system: 110, child: 610)) == .noQuickKey, "\(rig.label)")
            #expect(model.isCheckingOtherLists, "\(rig.label)")
            var mark = await rig.commands().count
            await model.toggle(.system(list: 0, system: 110))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            // A tile switches at once.
            #expect(model.switchState(for: .list(4)) == .off, "\(rig.label)")
            await model.toggle(.list(4))
            var after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("FQK,") == true, "\(rig.label): \(after)")
            #expect(model.switchState(for: .list(4)) == .on, "\(rig.label)")
            try await waitUntil("every list read (\(rig.label))") { allFresh(model) }
            #expect(!model.isCheckingOtherLists, "\(rig.label)")
            #expect(model.switchState(for: .system(list: 0, system: 110)) == .on, "\(rig.label)")
            mark = await rig.commands().count
            await model.toggle(.system(list: 0, system: 110))
            after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("SQK,0,") == true, "\(rig.label): \(after)")
            await shutDown(model)
            #expect(!model.isCheckingOtherLists, "closed (\(rig.label))")
        }
    }

    @Test func aListThatKeepsFailingDoesntHoldTheOthersSwitches() async throws {
        // List 0 is refused every time. Once it has failed twice and every other list is read, the others switch;
        // list 0's own rows stay as they are (no tree, nothing switchable).
        try await onBothMocks(commandTimeout: .milliseconds(600)) { rig in
            rig.refusing.refuse(["GLT,SYS,0"])
            let model = makeModel(rig)
            model.open()
            try await waitUntil("the other lists switch (\(rig.label))", .seconds(5)) {
                model.switchState(for: .system(list: 1, system: 101)) == .on
            }
            #expect(!model.isCheckingOtherLists, "\(rig.label)")
            #expect(await count("GLT,SYS,0", in: rig.commands()) >= 2, "\(rig.label)")
            #expect(model.trees[0]?.freshness != .fresh, "\(rig.label)")
            await shutDown(model)
        }
    }

    // MARK: One in-place retry for GLT reads

    @Test func aLostGLTReplyIsRetriedInPlace() async throws {
        // One lost reply in a list's read costs one command, not the list's read after a rest.
        try await onBothMocks { rig in
            rig.late.swallow("GLT,DEPT,101", times: 1)
            let model = makeModel(rig, pollInterval: .seconds(3))
            model.open()
            model.showList(1)
            var errors: [String] = []
            try await waitUntil("list 1 read (\(rig.label))", .seconds(2)) {
                if let error = model.trees[1]?.readError { errors.append(error) }
                return model.trees[1]?.freshness == .fresh
            }
            #expect(errors.isEmpty, "\(rig.label): \(errors)")
            let commands = await rig.commands()
            let first = try #require(commands.firstIndex(of: "GLT,DEPT,101"), "\(rig.label): \(commands)")
            #expect(Array(commands[first...].prefix(2)) == ["GLT,DEPT,101", "GLT,DEPT,101"], "\(rig.label): \(commands)")
            #expect(systemReads(commands).filter { $0 == 1 }.count == 1, "\(rig.label): \(commands)")
            await shutDown(model)
        }
    }

    @Test func twoLostGLTRepliesInARowFailTheList() async throws {
        try await onBothMocks { rig in
            rig.late.swallow("GLT,DEPT,101", times: 2)
            let model = makeModel(rig, pollInterval: .seconds(3))
            model.open()
            model.showList(1)
            try await waitUntil("list 1's error (\(rig.label))") { model.trees[1]?.readError != nil }
            #expect(model.trees[1]?.readError == "The scanner didn't answer GLT,DEPT.", "\(rig.label)")
            #expect(await count("GLT,DEPT,101", in: rig.commands()) == 2, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func theKeypadsGLTIsRetriedInPlace() async throws {
        try await onBothMocks { rig in
            rig.late.swallow("GLT,FL", times: 1)
            let model = makeModel(rig, pollInterval: .seconds(3))
            model.open()
            try await waitUntil("the keypad (\(rig.label))", .seconds(2)) { !model.lists.isEmpty }
            #expect(model.lastError == nil, "\(rig.label)")
            #expect(Array(await rig.commands().prefix(3)) == ["GLT,FL", "GLT,FL", "FQK"], "\(rig.label)")
            await shutDown(model)
        }
    }

    // MARK: Fix round 1 (QA C1, I1-I4, m1)

    @Test func aLateReplyCantShiftAListsOwnSystems() async throws {
        // QA C1. List 30's read fails at `GLT,DEPT,901` (held, its retry swallowed). After the rest, the re-read's first
        // `GLT,DEPT` (900) takes the held 901 reply, and with the mock's replies a little slow, 900's own reply then
        // answers `GLT,DEPT,901`. Nothing in the re-read itself tells: 900's departments are known only from the failed
        // read, whose rows now count as claims. Before, list 30 was fresh with 900 and 901 swapped, and a click on Mock
        // Charlie (under 900) turned Mock Alpha off.
        try await onBothMocks(favorites: twoConventionalSystems(), replyDelays: ["GLT": .milliseconds(40)]) { rig in
            rig.late.hold("GLT,DEPT,901", swallowRepeats: 1) { $0 == "GLT,DEPT,900" }
            let model = makeModel(rig)
            model.open()
            model.showList(30)
            var wrong: [String] = []
            try await waitUntil("released, list 30 fresh with its own departments (\(rig.label))", .seconds(8)) {
                let a = system(900, in: model.trees[30])?.children.map(\.index) ?? []
                let b = system(901, in: model.trees[30])?.children.map(\.index) ?? []
                if model.trees[30]?.freshness == .fresh, a != [700, 701] || b != [710, 711] {
                    wrong.append("900:\(a) 901:\(b)")
                }
                return rig.late.released && model.trees[30]?.freshness == .fresh
                    && model.switchState(for: .child(list: 30, system: 901, child: 710)) == .on
            }
            #expect(wrong.isEmpty, "\(rig.label): \(wrong)")
            let mark = await rig.commands().count
            await model.toggle(.child(list: 30, system: 901, child: 710))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("DQK,5,1,") == true, "\(rig.label): \(after)")
            #expect(namesOnlyKey(sets(after).first.flatMap(setValues), 0, "1"), "\(rig.label)")
            let favorites = await rig.favorites()
            #expect(favorites.children.first { $0.index == 710 }?.isOn == false, "\(rig.label)")
            #expect(favorites.children.first { $0.index == 700 }?.isOn == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aStrayThatIsTheOnlyWrongReplyIsRefused() async throws {
        // The variant of QA C1 where the held 901 reply is the only wrong one: it answers the re-read's `GLT,DEPT,900`
        // and 900's own reply to that read is lost, so `GLT,DEPT,901` gets its own answer, which names departments the
        // pass has just put under 900. List 30 is never fresh with them there.
        try await onBothMocks(favorites: twoConventionalSystems()) { rig in
            rig.late.hold("GLT,DEPT,901", swallowRepeats: 1) { $0 == "GLT,DEPT,900" }
            rig.late.swallow("GLT,DEPT,900", times: 1, skipping: 1)
            let model = makeModel(rig)
            model.open()
            model.showList(30)
            var wrong: [String] = []
            try await waitUntil("released, list 30 fresh (\(rig.label))", .seconds(8)) {
                let a = system(900, in: model.trees[30])?.children.map(\.index) ?? []
                let b = system(901, in: model.trees[30])?.children.map(\.index) ?? []
                if model.trees[30]?.freshness == .fresh, a != [700, 701] || b != [710, 711] {
                    wrong.append("900:\(a) 901:\(b)")
                }
                return rig.late.released && model.trees[30]?.freshness == .fresh
            }
            #expect(wrong.isEmpty, "\(rig.label): \(wrong)")
            #expect(sets(await rig.commands()).isEmpty, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aDepartmentThatReallyMovedIsAcceptedOnASecondRead() async throws {
        // The cache has Mock Bravo (701) under 900; the radio has since moved it to 901 (as D2). The first read's
        // `GLT,DEPT,901` names 701, which the list's own cached structure puts under 900: refused once, with no error,
        // and the list read again; that second read agrees, and is taken.
        var moved = twoConventionalSystems()
        if let at = moved.children.firstIndex(where: { $0.index == 701 }) {
            moved.children[at].systemIndex = 901
            moved.children[at].quickKey = 2
        }
        try await onBothMocks(favorites: moved, cache: cachedTwoConventionalSystems()) { rig in
            let model = makeModel(rig)
            model.open()
            var errors: [String] = []
            try await waitUntil("list 30 read (\(rig.label))") {
                if let error = model.trees[30]?.readError { errors.append(error) }
                return model.trees[30]?.freshness == .fresh
            }
            #expect(errors.isEmpty, "\(rig.label): \(errors)")
            #expect(system(900, in: model.trees[30])?.children.map(\.index) == [700], "\(rig.label)")
            #expect(Set(system(901, in: model.trees[30])?.children.map(\.index) ?? []) == [701, 710, 711], "\(rig.label)")
            #expect(systemReads(await rig.commands()) == [30, 30], "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func crossingCachedClaimsAreSettledOnce() async throws {
        // QA I1. Each list now holds the system the other's cache claims. List 60's read asks list 61 to settle; list
        // 61's re-read then meets list 60's cached claim, and its fresh reply wins. Before, the two re-checked each
        // other for ever and list 62 was never read.
        try await onBothMocks(favorites: swappedEastAndWest(), cache: cachedEastAndWest()) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("every list read, switches on (\(rig.label))", .seconds(5)) {
                allFresh(model) && !model.isCheckingOtherLists
            }
            #expect(model.trees[60]?.systems.map(\.index) == [961], "\(rig.label)")
            #expect(system(961, in: model.trees[60])?.children.map(\.index) == [771], "\(rig.label)")
            #expect(model.trees[61]?.systems.map(\.index) == [960], "\(rig.label)")
            #expect(system(960, in: model.trees[61])?.children.map(\.index) == [770], "\(rig.label)")
            #expect(model.trees[62]?.systems.map(\.index) == [962], "\(rig.label)")
            let reads = systemReads(await rig.commands())
            #expect(Array(reads.prefix(4)) == [60, 61, 60, 62], "\(rig.label): \(reads)")
            let mark = await rig.commands().count
            #expect(model.switchState(for: .system(list: 60, system: 961)) == .on, "\(rig.label)")
            await model.toggle(.system(list: 60, system: 961))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("SQK,2,") == true, "\(rig.label): \(after)")
            #expect(await rig.favorites().systems.first { $0.index == 961 }?.isOn == false, "\(rig.label)")
            #expect(await rig.favorites().systems.first { $0.index == 960 }?.isOn == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func rotatedCachedClaimsAreSettledOnceEach() async throws {
        // Three lists, each now holding the system the next one's cache claims (60 has 961, 61 has 962, 62 has 960).
        // 60 asks 61 to settle; 61's settle re-read takes 962 over 62's cached claim, which it contradicts, and that
        // claim is dropped; then 60 and 62 read with nothing left to contradict them.
        var rotated = swappedEastAndWest()
        for at in rotated.systems.indices {
            switch rotated.systems[at].index {
            case 960: rotated.systems[at].listIndex = 62
            case 961: rotated.systems[at].listIndex = 60
            default: rotated.systems[at].listIndex = 61
            }
        }
        var cache = cachedEastAndWest()
        cache[62] = QuickKeyListTree(
            systems: [.init(index: 962, name: "Mock North Conv", type: "Conventional", key: 0, avoided: false, state: nil,
                            children: [.init(index: 772, name: "Mock North Gate", kind: .department, key: 0,
                                             avoided: false, state: nil)])],
            freshness: .checking)
        try await onBothMocks(favorites: rotated, cache: cache) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("every list read, switches on (\(rig.label))", .seconds(5)) {
                allFresh(model) && !model.isCheckingOtherLists
            }
            #expect(model.trees[60]?.systems.map(\.index) == [961], "\(rig.label)")
            #expect(model.trees[61]?.systems.map(\.index) == [962], "\(rig.label)")
            #expect(model.trees[62]?.systems.map(\.index) == [960], "\(rig.label)")
            let reads = systemReads(await rig.commands())
            #expect(Array(reads.prefix(4)) == [60, 61, 60, 62], "\(rig.label): \(reads)")
            #expect(model.lists.allSatisfy { model.trees[$0.index]?.readError == nil }, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aStrayStaysHeldWhileItsOwnerKeepsFailingAfterATimeout() async throws {
        // QA I2. List 61's `GLT,DEPT,961` times out twice (held, its retry swallowed), and from then on its `GLT,SYS,61` is
        // refused. The held reply (961's department 771) answers list 60's `GLT,DEPT,960`, and nothing yet claims 771,
        // so list 60 shows it under 960. List 61 has failed more than twice, but one of its failures was a `GLT` that
        // timed out, whose reply may still be on its way: tree switches stay held. Before, they came on, and a click on
        // 771 under 960 turned 770 off.
        try await onBothMocks(favorites: eastAndWest()) { rig in
            rig.late.hold("GLT,DEPT,961", swallowRepeats: 1) { $0 == "GLT,DEPT,960" }
            let model = makeModel(rig, pollInterval: .milliseconds(500))
            model.open()
            model.showList(61)
            try await waitUntil("61 failed once (\(rig.label))") { model.trees[61]?.readError != nil }
            rig.refusing.refuse(["GLT,SYS,61"])
            model.hideList()
            try await waitUntil("60 fresh, 61 refused twice more (\(rig.label))", .seconds(8)) {
                let tries = count("GLT,SYS,61", in: await rig.commands())
                return model.trees[60]?.freshness == .fresh && tries >= 4
            }
            #expect(rig.late.released, "\(rig.label)")
            var switchable: [String] = []
            let deadline = ContinuousClock.now + .seconds(1)
            while ContinuousClock.now < deadline {
                for row in treeRows(model) {
                    let state = model.switchState(for: row)
                    if state == .on || state == .off { switchable.append("\(row) \(state)") }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(switchable.isEmpty, "\(rig.label): \(Set(switchable))")
            #expect(model.isCheckingOtherLists, "\(rig.label)")
            let mark = await rig.commands().count
            await model.toggle(.child(list: 60, system: 960, child: 771))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(await rig.favorites().children.first { $0.index == 770 }?.isOn == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aMenuExitStartsTheFullPassAgain() async throws {
        // The menus may have edited Favorites, so after a menu exit tree switches wait for every list again.
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(60)], commandTimeout: .milliseconds(600)) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("every list read (\(rig.label))") { allFresh(model) && !model.isCheckingOtherLists }
            model.statusArrived(try inMenu())
            model.statusArrived(try scanningListOne())
            try await waitUntil("list 1 read again (\(rig.label))") { model.trees[1]?.freshness == .fresh }
            #expect(!allFresh(model), "\(rig.label)")
            #expect(model.isCheckingOtherLists, "\(rig.label)")
            #expect(model.switchState(for: .system(list: 1, system: 101)) == .checkingOtherLists, "\(rig.label)")
            try await waitUntil("every list read again (\(rig.label))") { allFresh(model) && !model.isCheckingOtherLists }
            #expect(model.switchState(for: .system(list: 1, system: 101)) == .on, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aReopenOrReconnectStartsTheFullPassAgain() async throws {
        // QA I3: "every list read" counts from this open (and this connection).
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(60)], commandTimeout: .milliseconds(600)) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("every list read (\(rig.label))") { allFresh(model) && !model.isCheckingOtherLists }
            model.close()
            await model.quiesce()
            model.open()
            try await waitUntil("list 0 read after the reopen (\(rig.label))") { model.trees[0]?.freshness == .fresh }
            #expect(!allFresh(model), "\(rig.label)")
            #expect(model.switchState(for: .system(list: 0, system: 110)) == .checkingOtherLists, "reopen (\(rig.label))")
            try await waitUntil("every list read again (\(rig.label))") { allFresh(model) && !model.isCheckingOtherLists }
            model.detach()
            await model.quiesce()
            let client = rig.client
            model.attach(control: { client })
            try await waitUntil("list 0 read after the reconnect (\(rig.label))") { model.trees[0]?.freshness == .fresh }
            #expect(!allFresh(model), "\(rig.label)")
            #expect(model.switchState(for: .system(list: 0, system: 110)) == .checkingOtherLists,
                    "reconnect (\(rig.label))")
            await shutDown(model)
        }
    }

    @Test func aFailingClaimantDoesntStarveTheOthers() async throws {
        // QA I4. The cache says 102 is list 1's; the radio moved it to list 4; and list 1's `GLT,SYS,1` is refused every
        // time. List 1 is the scanning list, so it has already failed when list 4 is read: nothing would settle its
        // claim, so list 4's read fails like any (it goes last) instead of asking list 1 again and again, and every
        // other list loads and switches. List 4 stays unread while list 1 keeps failing (a known limit).
        try await onBothMocks(favorites: moving102ToListFour(), cache: cachedListOne(),
                              commandTimeout: .milliseconds(600)) { rig in
            rig.refusing.refuse(["GLT,SYS,1"])
            let model = makeModel(rig)
            model.statusArrived(try scanningListOne())
            model.open()
            try await waitUntil("the other lists read and switching (\(rig.label))", .seconds(6)) {
                [0, 6, 8, 10, 12, 14].allSatisfy { model.trees[$0]?.freshness == .fresh }
                    && model.switchState(for: .system(list: 6, system: 130)) == .on
            }
            #expect(!model.isCheckingOtherLists, "\(rig.label)")
            let reads = systemReads(await rig.commands())
            #expect(Array(reads.prefix(4)) == [1, 1, 0, 4], "\(rig.label): \(reads)")
            // List 4 has no tree to show (never read, no cache) until it is opened; its error is kept meanwhile.
            model.showList(4)
            #expect(model.trees[4]?.freshness != .fresh, "\(rig.label)")
            #expect(model.trees[4]?.readError == "The scanner's reply to GLT,SYS belonged to another list.",
                    "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aClaimAskedToSettleStillCountsWhenItsReReadFails() async throws {
        // The same, but list 4 is read first: it asks list 1 to settle, and list 1's settle re-read is refused. A claim
        // is settled once per open and stops counting only during that re-read, so list 1's cached claim counts again:
        // list 4's next read fails like any (a known limit while list 1 keeps failing), and the other lists load.
        try await onBothMocks(favorites: moving102ToListFour(), cache: cachedListOne(),
                              commandTimeout: .milliseconds(600)) { rig in
            rig.refusing.refuse(["GLT,SYS,1"])
            let model = makeModel(rig)
            model.open()
            try await waitUntil("the other lists read (\(rig.label))", .seconds(6)) {
                [0, 6, 8, 10, 12, 14].allSatisfy { model.trees[$0]?.freshness == .fresh }
                    && model.switchState(for: .system(list: 6, system: 130)) == .on
            }
            let reads = systemReads(await rig.commands())
            #expect(Array(reads.prefix(5)) == [0, 4, 1, 1, 4], "\(rig.label): \(reads)")
            model.showList(4)
            #expect(model.trees[4]?.freshness != .fresh, "\(rig.label)")
            #expect(model.trees[4]?.readError == "The scanner's reply to GLT,SYS belonged to another list.",
                    "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aSettleWaitsForTheRest() async throws {
        // QA m1. A refused reply may be a stray whose own reply is still on its way, so the re-reads a settle asks for
        // wait one poll interval, like any failure's.
        try await onBothMocks(favorites: moving102ToListFour(), cache: cachedListOne()) { rig in
            let model = makeModel(rig, pollInterval: .milliseconds(1500))
            model.open()
            try await waitUntil("list 4's refused read (\(rig.label))") { await rig.commands().contains("GLT,SYS,4") }
            let mark = await rig.commands().count
            try await Task.sleep(for: .milliseconds(700))
            #expect(Array(await rig.commands().dropFirst(mark)).isEmpty, "\(rig.label)")
            try await waitUntil("list 1, then list 4 (\(rig.label))", .seconds(5)) {
                await systemReads(rig.commands()).prefix(4) == [0, 4, 1, 4]
            }
            await shutDown(model)
        }
    }

    // MARK: Fix round 2 (QA NEW-1, N7-N10)

    @Test func anAskedClaimStillCountsAfterARecheck() async throws {
        // QA NEW-1. List 61's cache claims 960, so list 60's first read asks 61 to settle; both then read. Later every
        // system's key moves, so the polls re-check 61 (shown): its `GLT,DEPT,961` times out twice (held, its retry
        // swallowed) and its reads are refused from then on. Then 60 is shown and re-checked, and the held 961 reply
        // (771) lands on its `GLT,DEPT,960`. Before, 61's claim on 771 no longer counted (61 had been asked once), 60
        // read fresh with 771 under 960, switches were on, and a click sent `DQK,2,1` and turned 770 off.
        func cache() -> [UInt32: QuickKeyListTree] {
            func system(_ index: UInt32, _ child: UInt32) -> QuickKeyListTree.SystemRow {
                .init(index: index, name: "Mock S\(index)", type: "Conventional", key: 0, avoided: false, state: nil,
                      children: [.init(index: child, name: "Mock D\(child)", kind: .department, key: 0, avoided: false,
                                       state: nil)])
            }
            return [61: QuickKeyListTree(systems: [system(961, 771), system(960, 770)], freshness: .checking)]
        }
        try await onBothMocks(favorites: eastAndWest(), cache: cache()) { rig in
            let model = makeModel(rig, pollInterval: .milliseconds(400))
            model.open()
            try await waitUntil("both read (\(rig.label))", .seconds(8)) { allFresh(model) && !model.isCheckingOtherLists }
            rig.late.hold("GLT,DEPT,961", swallowRepeats: 1) { $0 == "GLT,DEPT,960" }
            var moved = eastAndWest()
            for at in moved.systems.indices { moved.systems[at].quickKey = 1 }
            await rig.setFavorites(moved)
            model.showList(61)
            try await waitUntil("61 failed (\(rig.label))", .seconds(8)) { model.trees[61]?.readError != nil }
            rig.refusing.refuse(["GLT,SYS,61"])
            model.hideList()
            model.showList(60)
            var switchable: [String] = []
            try await waitUntil("the late reply released, 60 read again (\(rig.label))", .seconds(10)) {
                if system(960, in: model.trees[60])?.children.contains(where: { $0.index == 771 }) == true {
                    let state = model.switchState(for: .child(list: 60, system: 960, child: 771))
                    if state == .on || state == .off { switchable.append("\(state)") }
                }
                return rig.late.released && model.trees[60]?.freshness == .fresh
            }
            try await Task.sleep(for: .milliseconds(500))
            #expect(switchable.isEmpty, "\(rig.label): \(switchable)")
            let mark = await rig.commands().count
            await model.toggle(.child(list: 60, system: 960, child: 771))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(await rig.favorites().children.first { $0.index == 770 }?.isOn == true, "\(rig.label)")
            #expect(model.isCheckingOtherLists, "61's GLT timed out and it hasn't read since (\(rig.label))")
            await shutDown(model)
        }
    }

    @Test func aTimeoutTheRetryAbsorbedStillHoldsTheSwitches() async throws {
        // QA NEW-1, last paragraph. List 1's `GLT,DEPT,101` times out once (the in-place retry gets an answer), and
        // the read then fails on a refused `GLT,SITE,101`, every time. List 1 fails only by refusals, but the first
        // try's reply may still be on its way: tree switches stay held until list 1 reads.
        try await onBothMocks(commandTimeout: .milliseconds(600)) { rig in
            rig.late.swallow("GLT,DEPT,101", times: 1)
            rig.refusing.refuse(["GLT,SITE,101"])
            let model = makeModel(rig)
            model.open()
            model.showList(1)
            try await waitUntil("every other list read, list 1 failed twice (\(rig.label))", .seconds(6)) {
                let tries = count("GLT,SITE,101", in: await rig.commands())
                return [0, 4, 6, 8, 10, 12, 14].allSatisfy { model.trees[$0]?.freshness == .fresh } && tries >= 2
            }
            #expect(model.isCheckingOtherLists, "\(rig.label)")
            #expect(model.switchState(for: .system(list: 6, system: 130)) == .checkingOtherLists, "\(rig.label)")
            rig.refusing.refuse([])
            try await waitUntil("list 1 read, switches on (\(rig.label))", .seconds(6)) {
                model.trees[1]?.freshness == .fresh && model.switchState(for: .system(list: 6, system: 130)) == .on
            }
            await shutDown(model)
        }
    }

    @Test func twoDepartmentsSwappedOnTheRadioTakeTwoReads() async throws {
        // QA N7. The cache has 701 under 900 and 711 under 901; the radio has swapped them. The first read meets 711
        // under 900 against the cache: refused once. The second read is checked against that refused read, not the
        // cache, so it is taken, including 701 under 901, which only the cache contradicts.
        var swapped = twoConventionalSystems()
        for at in swapped.children.indices {
            switch swapped.children[at].index {
            case 701: swapped.children[at].systemIndex = 901; swapped.children[at].quickKey = 2
            case 711: swapped.children[at].systemIndex = 900; swapped.children[at].quickKey = 2
            default: break
            }
        }
        try await onBothMocks(favorites: swapped, cache: cachedTwoConventionalSystems()) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("list 30 read (\(rig.label))") { model.trees[30]?.freshness == .fresh }
            #expect(Set(system(900, in: model.trees[30])?.children.map(\.index) ?? []) == [700, 711], "\(rig.label)")
            #expect(Set(system(901, in: model.trees[30])?.children.map(\.index) ?? []) == [701, 710], "\(rig.label)")
            #expect(systemReads(await rig.commands()) == [30, 30], "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aReadRefusedForTheCacheIsAClaimOnTheNext() async throws {
        // QA N9. The cache has 701 under 901; the radio moved it to 900. The first read's `GLT,DEPT,900` names 701:
        // refused against the cache, the first system read. In the second read 900's and 901's replies swap: 900 takes
        // 901's departments, which nothing in that read contradicts, but 901 then takes 700, which the refused read had
        // under 900. So it is refused too, and list 30 is never fresh with them swapped.
        var moved = twoConventionalSystems()
        if let at = moved.children.firstIndex(where: { $0.index == 701 }) { moved.children[at].systemIndex = 900 }
        var cache = cachedTwoConventionalSystems()
        if var tree = cache[30] {
            let bravo = tree.systems[0].children.removeLast()
            tree.systems[1].children.insert(bravo, at: 0)
            cache[30] = tree
        }
        try await onBothMocks(favorites: moved, cache: cache) { rig in
            rig.late.misdirect("GLT,DEPT,900", to: try ScannerCommand("GLT", "DEPT", "901"), skipping: 1)
            rig.late.misdirect("GLT,DEPT,901", to: try ScannerCommand("GLT", "DEPT", "900"))
            let model = makeModel(rig)
            model.open()
            var wrong: [String] = []
            try await waitUntil("list 30 read with its own departments (\(rig.label))", .seconds(6)) {
                let a = Set(system(900, in: model.trees[30])?.children.map(\.index) ?? [])
                let b = Set(system(901, in: model.trees[30])?.children.map(\.index) ?? [])
                if model.trees[30]?.freshness == .fresh, a != [700, 701] || b != [710, 711] { wrong.append("\(a) \(b)") }
                return model.trees[30]?.freshness == .fresh
            }
            #expect(wrong.isEmpty, "\(rig.label): \(wrong)")
            #expect(systemReads(await rig.commands()).count >= 3, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aReopenSettlesAgain() async throws {
        // QA N8. Settling is once per open, not once per model: the crossing claims settle on the first open; the radio
        // then swaps them back, so the cache (rewritten by the first open) crosses again, and the second open settles
        // them the same way, with no failure.
        try await onBothMocks(favorites: swappedEastAndWest(), cache: cachedEastAndWest()) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("every list read (\(rig.label))", .seconds(5)) { allFresh(model) && !model.isCheckingOtherLists }
            model.close()
            await model.quiesce()
            var back = swappedEastAndWest()
            for at in back.systems.indices where back.systems[at].index != 962 {
                back.systems[at].listIndex = back.systems[at].listIndex == 60 ? 61 : 60
            }
            await rig.setFavorites(back)
            let mark = await rig.commands().count
            model.open()
            try await waitUntil("every list read again (\(rig.label))", .seconds(5)) {
                allFresh(model) && !model.isCheckingOtherLists
            }
            let reads = systemReads(Array(await rig.commands().dropFirst(mark)))
            #expect(Array(reads.prefix(4)) == [60, 61, 60, 62], "\(rig.label): \(reads)")
            #expect(model.trees[60]?.systems.map(\.index) == [960], "\(rig.label)")
            #expect(model.trees[61]?.systems.map(\.index) == [961], "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aSettlingListKeepsItsClaimsForItsNextRead() async throws {
        // QA N10. List 30's read meets 711 under 901, which list 31's cache claims (under 905): list 31 is asked to
        // settle, and list 30 is read again after it. That read's replies for 900 and 901 swap; 900 taking 901's
        // departments is caught only because the systems list 30 had read before it asked (900: 700, 701) still count.
        var favorites = twoConventionalSystems()
        favorites.lists.append(.init(index: 31, name: "Mock Spare", quickKey: 6))
        favorites.systems.append(.init(index: 905, listIndex: 31, name: "Mock Spare Conv", type: "Conventional",
                                       quickKey: 0))
        favorites.children.append(.init(index: 715, systemIndex: 905, kind: .department, name: "Mock Spare Gate",
                                        quickKey: 0))
        let cache: [UInt32: QuickKeyListTree] = [31: QuickKeyListTree(
            systems: [.init(index: 905, name: "Mock Spare Conv", type: "Conventional", key: 0, avoided: false, state: nil,
                            children: [.init(index: 711, name: "Mock Spare Gate", kind: .department, key: 0,
                                             avoided: false, state: nil)])],
            freshness: .checking)]
        try await onBothMocks(favorites: favorites, cache: cache) { rig in
            rig.late.misdirect("GLT,DEPT,900", to: try ScannerCommand("GLT", "DEPT", "901"), skipping: 1)
            rig.late.misdirect("GLT,DEPT,901", to: try ScannerCommand("GLT", "DEPT", "900"), skipping: 1)
            let model = makeModel(rig)
            model.open()
            var wrong: [String] = []
            try await waitUntil("both lists read (\(rig.label))", .seconds(6)) {
                let a = Set(system(900, in: model.trees[30])?.children.map(\.index) ?? [])
                let b = Set(system(901, in: model.trees[30])?.children.map(\.index) ?? [])
                if model.trees[30]?.freshness == .fresh, a != [700, 701] || b != [710, 711] { wrong.append("\(a) \(b)") }
                return allFresh(model)
            }
            #expect(wrong.isEmpty, "\(rig.label): \(wrong)")
            #expect(Array(systemReads(await rig.commands()).prefix(3)) == [30, 31, 30], "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aSettleReReadDropsTheClaimsItContradicts() async throws {
        // In the rotation, list 61's settle re-read takes 962, which list 62's cache claims: once it succeeds, list 62's
        // cached tree no longer shows 962, before list 62 is read itself.
        var rotated = swappedEastAndWest()
        for at in rotated.systems.indices {
            switch rotated.systems[at].index {
            case 960: rotated.systems[at].listIndex = 62
            case 961: rotated.systems[at].listIndex = 60
            default: rotated.systems[at].listIndex = 61
            }
        }
        var cache = cachedEastAndWest()
        cache[62] = QuickKeyListTree(
            systems: [.init(index: 962, name: "Mock North Conv", type: "Conventional", key: 0, avoided: false, state: nil,
                            children: [.init(index: 772, name: "Mock North Gate", kind: .department, key: 0,
                                             avoided: false, state: nil)])],
            freshness: .checking)
        try await onBothMocks(favorites: rotated, cache: cache, replyDelays: ["GLT": .milliseconds(80)],
                              commandTimeout: .milliseconds(600)) { rig in
            let model = makeModel(rig)
            model.open()
            var before62: [[UInt32]] = []
            try await waitUntil("every list read (\(rig.label))", .seconds(8)) {
                if model.trees[61]?.freshness == .fresh, model.trees[62]?.freshness != .fresh {
                    before62.append(model.trees[62]?.systems.map(\.index) ?? [])
                }
                return allFresh(model)
            }
            #expect(!before62.isEmpty, "\(rig.label)")
            #expect(before62.allSatisfy { !$0.contains(962) }, "\(rig.label): \(before62)")
            await shutDown(model)
        }
    }
}

// MARK: The pre-set check (fix round 2, the coordinator's ruling)

/// The keys `MockFavorites` holds for one child (to check a set changed nothing).
private func childIsOn(_ index: UInt32, _ favorites: MockFavorites) -> Bool? {
    favorites.children.first { $0.index == index }?.isOn
}

/// A model on `rig` with every list read, its polls far off (so the mock's log after a click holds only the click's
/// commands).
@MainActor
private func readModel(_ rig: QKOwnRig) async throws -> QuickKeysModel {
    let model = makeModel(rig, pollInterval: .seconds(30))
    model.open()
    try await waitUntil("every list read (\(rig.label))") { allFresh(model) && !model.isCheckingOtherLists }
    return model
}

/// A set proves its own address just before it is sent (fix round 3): `GLT,FL` (the list and its key), `GLT,SYS` (the
/// system and its key), then the decisive scope twice with a `GLT,FL` fence between and after: for a system `GLT,SYS`
/// again, for a department or site its `GLT,DEPT` or `GLT,SITE` (the child, its key, and the system's known children of
/// that kind) both times. The two replies must agree.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct QuickKeysModelSetCheckTests {
    @Test func aSetProvesItsAddressFirst() async throws {
        try await onBothMocks { rig in
            let model = try await readModel(rig)
            // System 102 (S1) of list 1 (F7): on, so the click asks for off.
            var mark = await rig.commands().count
            await model.toggle(.system(list: 1, system: 102))
            var after = Array(await rig.commands().dropFirst(mark))
            #expect(Array(after.prefix(5)) == ["GLT,FL", "GLT,SYS,1", "GLT,FL", "GLT,SYS,1", "GLT,FL"],
                    "\(rig.label): \(after)")
            #expect(after.count == 7 && after[5].hasPrefix("SQK,7,") && after[6] == "SQK,7", "\(rig.label): \(after)")
            #expect(sets(after).count == 1, "\(rig.label)")
            // Site 621 (D1) of system 120 (S0) in list 4 (F1): off, so the click asks for on.
            mark = await rig.commands().count
            await model.toggle(.child(list: 4, system: 120, child: 621))
            after = Array(await rig.commands().dropFirst(mark))
            #expect(Array(after.prefix(6)) == ["GLT,FL", "GLT,SYS,4", "GLT,SITE,120", "GLT,FL", "GLT,SITE,120", "GLT,FL"],
                    "\(rig.label): \(after)")
            #expect(after.count == 8 && after[6].hasPrefix("DQK,1,0,") && after[7] == "DQK,1,0", "\(rig.label): \(after)")
            #expect(childIsOn(621, await rig.favorites()) == true, "\(rig.label)")
            // Department 201 (D1) of system 101 (S0) in list 1: on, so the click asks for off.
            mark = await rig.commands().count
            await model.toggle(.child(list: 1, system: 101, child: 201))
            after = Array(await rig.commands().dropFirst(mark))
            #expect(Array(after.prefix(6)) == ["GLT,FL", "GLT,SYS,1", "GLT,DEPT,101", "GLT,FL", "GLT,DEPT,101", "GLT,FL"],
                    "\(rig.label): \(after)")
            #expect(after.count == 8 && after[6].hasPrefix("DQK,7,0,") && after[7] == "DQK,7,0", "\(rig.label): \(after)")
            #expect(childIsOn(201, await rig.favorites()) == false, "\(rig.label)")
            #expect(model.lastError == nil, "\(rig.label)")
            // A tile's address is the list key `GLT,FL` gives the keypad: its set needs no check.
            mark = await rig.commands().count
            await model.toggle(.list(4))
            after = Array(await rig.commands().dropFirst(mark))
            #expect(after.first?.hasPrefix("FQK,") == true, "\(rig.label): \(after)")
            await shutDown(model)
        }
    }

    @Test func aWrongReplyAtAnyStepSendsNothing() async throws {
        // Each step of the check on site 621 (system 120, list 4) gets another scope's reply: another kind, or the
        // right kind without the element. Nothing is sent, the list is checked again first, and the pop-over says so.
        let cases: [(command: String, instead: ScannerCommand, skipping: Int)] = [
            ("GLT,FL", try ScannerCommand("GLT", "SYS", "4"), 0),
            ("GLT,SYS,4", try ScannerCommand("GLT", "SYS", "1"), 0),
            ("GLT,SYS,4", try ScannerCommand("GLT", "SITE", "120"), 0),
            ("GLT,SITE,120", try ScannerCommand("GLT", "SITE", "101"), 0),
            ("GLT,SITE,120", try ScannerCommand("GLT", "DEPT", "120"), 0),
            ("GLT,FL", try ScannerCommand("GLT", "SITE", "120"), 1),
            ("GLT,SITE,120", try ScannerCommand("GLT", "SITE", "101"), 1),
            ("GLT,SITE,120", try ScannerCommand("GLT", "FL"), 1),
            ("GLT,FL", try ScannerCommand("GLT", "SITE", "120"), 2),
        ]
        for item in cases {
            try await onBothMocks { rig in
                let model = try await readModel(rig)
                rig.late.misdirect(item.command, to: item.instead, skipping: item.skipping)
                let mark = await rig.commands().count
                await model.toggle(.child(list: 4, system: 120, child: 621))
                let label = "\(rig.label), \(item.command) as \(item.instead.name),\(item.instead.arguments)"
                #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(label)")
                #expect(model.lastError == "The list changed on the scanner; nothing was sent.", "\(label)")
                #expect(model.trees[4]?.freshness != .fresh, "\(label)")
                #expect(childIsOn(621, await rig.favorites()) == false, "\(label)")
                try await waitUntil("list 4 read again (\(label))") { model.trees[4]?.freshness == .fresh }
                #expect(model.switchState(for: .child(list: 4, system: 120, child: 621)) == .off, "\(label)")
                await shutDown(model)
            }
        }
    }

    @Test func aCheckThatGoesUnansweredOrRefusedSendsNothing() async throws {
        for refuse in [false, true] {
            try await onBothMocks { rig in
                let model = try await readModel(rig)
                if refuse { rig.refusing.refuse(["GLT,SYS,4"]) } else { rig.late.swallow("GLT,SYS,4", times: 1) }
                let mark = await rig.commands().count
                await model.toggle(.child(list: 4, system: 120, child: 621))
                let after = Array(await rig.commands().dropFirst(mark))
                #expect(sets(after).isEmpty, "\(rig.label), refuse \(refuse): \(after)")
                #expect(count("GLT,SYS,4", in: after) == 1, "not retried (\(rig.label), refuse \(refuse)): \(after)")
                #expect(model.lastError == "The scanner didn't answer; nothing was sent.", "\(rig.label), refuse \(refuse)")
                #expect(childIsOn(621, await rig.favorites()) == false, "\(rig.label)")
                await shutDown(model)
            }
        }
    }

    @Test func aKeyOrASiteChangedOnTheRadioSendsNothing() async throws {
        // The radio changes the clicked site's key, its system's key, or adds a site to its system, after list 4 was
        // read (it isn't shown, so no poll sees it).
        for change in ["key", "system key", "site"] {
            try await onBothMocks { rig in
                let model = try await readModel(rig)
                var favorites = await rig.favorites()
                if change == "key" {
                    if let at = favorites.children.firstIndex(where: { $0.index == 621 }) { favorites.children[at].quickKey = 3 }
                } else if change == "system key" {
                    if let at = favorites.systems.firstIndex(where: { $0.index == 120 }) { favorites.systems[at].quickKey = 3 }
                } else {
                    favorites.children.append(.init(index: 622, systemIndex: 120, kind: .site, name: "Mock East Site",
                                                    quickKey: 2))
                }
                await rig.setFavorites(favorites)
                let mark = await rig.commands().count
                await model.toggle(.child(list: 4, system: 120, child: 621))
                #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label), \(change)")
                #expect(model.lastError == "The list changed on the scanner; nothing was sent.", "\(rig.label), \(change)")
                await shutDown(model)
            }
        }
    }

    @Test func theCheckStandsOnItsOwnAgainstAShiftedList() async throws {
        // QA C1's probe with the ownership guard and the full-pass hold turned off (test-only): list 30 is fresh with
        // 900's and 901's departments swapped, and a click on Mock Charlie (710) under 900 is taken. The check's
        // `GLT,DEPT,900` has no 710 in it, so nothing is sent.
        try await onBothMocks(favorites: twoConventionalSystems(), replyDelays: ["GLT": .milliseconds(40)]) { rig in
            rig.late.hold("GLT,DEPT,901", swallowRepeats: 1) { $0 == "GLT,DEPT,900" }
            let model = makeModel(rig)
            model.structureGuardsOn = false
            model.open()
            model.showList(30)
            try await waitUntil("list 30 fresh, shifted (\(rig.label))", .seconds(8)) {
                rig.late.released && model.trees[30]?.freshness == .fresh
                    && system(900, in: model.trees[30])?.children.map(\.index) == [710, 711]
            }
            #expect(model.switchState(for: .child(list: 30, system: 900, child: 710)) == .on, "\(rig.label)")
            let mark = await rig.commands().count
            await model.toggle(.child(list: 30, system: 900, child: 710))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(model.lastError == "The list changed on the scanner; nothing was sent.", "\(rig.label)")
            let favorites = await rig.favorites()
            #expect(childIsOn(700, favorites) == true && childIsOn(710, favorites) == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func theCheckStandsOnItsOwnAgainstAStrayDepartment() async throws {
        // QA NEW-1's end state, reached with the guards off (test-only): list 60 fresh with 771 (961's department) under
        // 960. The check's `GLT,DEPT,960` has no 771 in it, so nothing is sent.
        try await onBothMocks(favorites: eastAndWest()) { rig in
            rig.late.misdirect("GLT,DEPT,960", to: try ScannerCommand("GLT", "DEPT", "961"))
            let model = makeModel(rig, pollInterval: .seconds(30))
            model.structureGuardsOn = false
            model.open()
            try await waitUntil("list 60 fresh with 771 (\(rig.label))") {
                allFresh(model) && system(960, in: model.trees[60])?.children.map(\.index) == [771]
            }
            #expect(model.switchState(for: .child(list: 60, system: 960, child: 771)) == .on, "\(rig.label)")
            let mark = await rig.commands().count
            await model.toggle(.child(list: 60, system: 960, child: 771))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(model.lastError == "The list changed on the scanner; nothing was sent.", "\(rig.label)")
            let favorites = await rig.favorites()
            #expect(childIsOn(770, favorites) == true && childIsOn(771, favorites) == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aWrongSecondSystemsReplySendsNothing() async throws {
        // A system's set (102 under list 1): the second `GLT,SYS,1` gets list 4's systems, without 102.
        try await onBothMocks { rig in
            let model = try await readModel(rig)
            rig.late.misdirect("GLT,SYS,1", to: try ScannerCommand("GLT", "SYS", "4"), skipping: 1)
            let mark = await rig.commands().count
            await model.toggle(.system(list: 1, system: 102))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(model.lastError == "The list changed on the scanner; nothing was sent.", "\(rig.label)")
            #expect(await rig.favorites().systems.first { $0.index == 102 }?.isOn == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func theCheckSurvivesOneLateAndOneLostReply() async throws {
        // QA NEW-2 (`qaCheckDefeatedByOneLateOneLost`), the guards off. List 60's tree holds 771 (961's) under 960, from
        // a misdirected read, and a `GLT,DEPT,961` reply of list 61's is held (its retry answered). On the click the
        // check's first `GLT,DEPT,960` takes the held reply (771, the known children, the same key) and its own reply is
        // lost. Before, the fence passed and the set went out, turning 770 off; now the second `GLT,DEPT,960` gets 960's
        // own departments, which don't agree, so nothing is sent.
        try await onBothMocks(favorites: eastAndWest()) { rig in
            rig.late.misdirect("GLT,DEPT,960", to: try ScannerCommand("GLT", "DEPT", "961"))
            rig.late.hold("GLT,DEPT,961") { $0 == "GLT,DEPT,960" }
            let model = makeModel(rig, pollInterval: .seconds(30))
            model.structureGuardsOn = false
            model.open()
            try await waitUntil("60 has the stray, 61 read, a 961 reply held (\(rig.label))", .seconds(8)) {
                allFresh(model) && system(960, in: model.trees[60])?.children.map(\.index) == [771]
                    && rig.late.hasHeld && !rig.late.released
            }
            rig.late.swallow("GLT,DEPT,960", times: 1)
            #expect(model.switchState(for: .child(list: 60, system: 960, child: 771)) == .on, "\(rig.label)")
            let mark = await rig.commands().count
            await model.toggle(.child(list: 60, system: 960, child: 771))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(rig.late.released, "\(rig.label)")
            #expect(sets(after).isEmpty, "\(rig.label): \(after)")
            #expect(model.lastError == "The list changed on the scanner; nothing was sent.", "\(rig.label)")
            let favorites = await rig.favorites()
            #expect(childIsOn(770, favorites) == true && childIsOn(771, favorites) == true, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func theSystemCheckSurvivesAShiftOfTwo() async throws {
        // QA NEW-2 (`qaSystemCheckDefeatedByAShiftOfTwo`), the guards off, on the network mock (a persistent shift is
        // UDP's: serial replies come in order). List 60's tree holds 961 (61's), from a misdirected `GLT,SYS,60`; the
        // keypad's first `GLT,FL` reply and list 61's first `GLT,SYS,61` reply are held (their retries answered). From
        // the click on, every `GLT` read gets the reply of the read two before it. Before, the check (`GLT,FL`,
        // `GLT,SYS,60`, `GLT,FL`) took an old `FL`, the old `SYS,61` (961) and its own first `FL`, and the set turned 960
        // off. Now its second `GLT,SYS,60` gets its first one's own reply (960), which doesn't agree.
        let options = MockSDS200.Options(clock: .stepped(at: 3), quickKeySetDelay: .zero)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        await mock.setFavorites(eastAndWest())
        let shift = ShiftingTransport(UDPTransport(host: "127.0.0.1", port: ports.udpPort))
        let client = ScannerClient(transport: shift, commandTimeout: .milliseconds(300))
        var failure: (any Error)?
        do {
            try await client.connect()
            shift.misdirect("GLT,SYS,60", to: try ScannerCommand("GLT", "SYS", "61"))
            shift.hold(["GLT,FL", "GLT,SYS,61"])
            // A short poll interval: each held reply's timeout rests the reads for one.
            let model = QuickKeysModel(cacheURL: nil, pollInterval: .milliseconds(700))
            model.attach(control: { client })
            model.structureGuardsOn = false
            model.open()
            try await waitUntil("60 holds 961, two replies held", .seconds(8)) {
                allFresh(model) && model.trees[60]?.systems.map(\.index) == [961] && shift.heldCount == 2
            }
            shift.shift(from: "GLT,FL", count: 5)
            #expect(model.switchState(for: .system(list: 60, system: 961)) == .on)
            let mark = await mock.control.receivedCommands.count
            await model.toggle(.system(list: 60, system: 961))
            let after = Array(await mock.control.receivedCommands.dropFirst(mark))
            #expect(sets(after).isEmpty, "\(after)")
            #expect(model.lastError == "The list changed on the scanner; nothing was sent.", "\(after)")
            let favorites = await mock.favorites
            #expect(favorites.systems.allSatisfy { $0.isOn }, "\(favorites.systems.map { ($0.index, $0.isOn) })")
            await shutDown(model)
        } catch { failure = error }
        await client.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
}

/// A transport for a persistent shift of UDP replies (after the QA's `QAShiftTransport`): it holds the replies to the
/// first write of each `hold` entry; then, from the first write of `shift(from:)` on, before each of the next `count`
/// `GLT` writes it hands on the oldest held reply and holds that write's own, so every `GLT` read gets the reply of the
/// read as many before it as replies were held.
final class ShiftingTransport: ScannerTransport, Sendable {
    private struct State {
        var holdTexts: [String] = []
        /// Command names whose next reply is to be held, oldest first.
        var holdingNames: [String] = []
        var held: [ScannerResponse] = []
        var shiftStart: String?
        var shifting = false
        var shiftLeft = 0
        /// Shifted writes that found no held reply yet: the next reply that would be held is handed on instead (the
        /// next one in line is the oldest, since the mock answers in order).
        var owed = 0
        var misdirections: [String: ScannerCommand] = [:]
        var continuation: AsyncStream<ScannerResponse>.Continuation?
    }

    private let base: any ScannerTransport
    private let state = Mutex(State())

    init(_ base: any ScannerTransport) { self.base = base }

    func hold(_ texts: [String]) { state.withLock { $0.holdTexts += texts } }
    func shift(from start: String, count: Int) { state.withLock { $0.shiftStart = start; $0.shiftLeft = count } }
    func misdirect(_ command: String, to instead: ScannerCommand) { state.withLock { $0.misdirections[command] = instead } }
    var heldCount: Int { state.withLock { $0.held.count } }

    func open() async throws { try await base.open() }
    func close() async { await base.close() }

    func send(_ command: ScannerCommand) async throws {
        let text = ([command.name] + command.arguments).joined(separator: ",")
        let (late, continuation, outgoing) = state.withLock {
            state -> (ScannerResponse?, AsyncStream<ScannerResponse>.Continuation?, ScannerCommand) in
            var late: ScannerResponse?
            var outgoing = command
            if let instead = state.misdirections.removeValue(forKey: text) { outgoing = instead }
            if !state.shifting, let start = state.shiftStart, text == start { state.shifting = true }
            if state.shifting, command.name == "GLT", state.shiftLeft > 0 {
                if !state.held.isEmpty { late = state.held.removeFirst() } else { state.owed += 1 }
                state.holdingNames.append(command.name)
                state.shiftLeft -= 1
            } else if let at = state.holdTexts.firstIndex(of: text) {
                state.holdTexts.remove(at: at)
                state.holdingNames.append(command.name)
            }
            return (late, state.continuation, outgoing)
        }
        if let late { continuation?.yield(late) }
        try await base.send(outgoing)
    }

    var responses: AsyncStream<ScannerResponse> {
        let upstream = base.responses
        return AsyncStream { continuation in
            state.withLock { $0.continuation = continuation }
            let relay = Task { [self] in
                for await response in upstream {
                    let pass = state.withLock { state -> Bool in
                        guard state.holdingNames.first == response.command else { return true }
                        state.holdingNames.removeFirst()
                        if state.owed > 0 {
                            state.owed -= 1
                            return true
                        }
                        state.held.append(response)
                        return false
                    }
                    if pass { continuation.yield(response) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}

// MARK: The settle re-read's skip (fix round 3, QA R11, R12)

@MainActor
@Suite(.timeLimit(.minutes(1))) struct QuickKeysModelSettleSkipTests {
    @Test func theSkipEndsWithTheSettleReRead() async throws {
        // QA R11. List 60's read asks list 61 to settle (crossing cached claims), and 61's settle re-read takes its
        // fresh reply. After a menu exit every list is re-checked, and 61 is read first (shown); its `GLT,SYS,61` takes
        // list 60's systems (961), which list 60 still claims, not fresh. That read isn't a settle re-read any more, so
        // the claim counts: refused (list 60 is asked to settle in turn), and 61 never shows 961.
        try await onBothMocks(favorites: swappedEastAndWest(), cache: cachedEastAndWest()) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("every list read (\(rig.label))", .seconds(5)) { allFresh(model) && !model.isCheckingOtherLists }
            rig.late.misdirect("GLT,SYS,61", to: try ScannerCommand("GLT", "SYS", "60"))
            model.showList(61)
            let mark = await rig.commands().count
            model.menuReadChanged(true)
            model.menuReadChanged(false)
            var wrong: [String] = []
            try await waitUntil("every list read again (\(rig.label))", .seconds(6)) {
                if model.trees[61]?.freshness == .fresh, model.trees[61]?.systems.map(\.index) != [960] {
                    wrong.append("\(String(describing: model.trees[61]?.systems.map(\.index)))")
                }
                return allFresh(model) && !model.isCheckingOtherLists && model.trees[61]?.systems.map(\.index) == [960]
            }
            #expect(wrong.isEmpty, "\(rig.label): \(wrong)")
            #expect(model.trees[60]?.systems.map(\.index) == [961], "\(rig.label)")
            // 61's read is refused and asks 60 to settle; 60 reads, then 61, then 62. (The mock logs the misdirected
            // read as list 60's.)
            let reads = systemReads(Array(await rig.commands().dropFirst(mark)))
            #expect(Array(reads.prefix(4)) == [60, 60, 61, 62], "\(rig.label): \(reads)")
            await shutDown(model)
        }
    }

    @Test func theTwoDecisiveRepliesMustAgree() async throws {
        // A system's set (102 under list 1). The check's first `GLT,SYS,1` takes a reply left over from list 1's own
        // read (whose retry answered), from before the radio added system 103 to list 1, and its own reply is lost;
        // the second `GLT,SYS,1` gets the radio's list now. Both hold 102 with its key, but they don't agree: nothing
        // is sent.
        try await onBothMocks { rig in
            let armed = Mutex(false)
            rig.late.hold("GLT,SYS,1") { text in text == "GLT,SYS,1" && armed.withLock { $0 } }
            // A short poll interval: the held reply's timeout rests the reads for one. No list is shown, so the polls
            // read only `FQK`.
            let model = makeModel(rig, pollInterval: .milliseconds(300))
            model.open()
            try await waitUntil("every list read (\(rig.label))") { allFresh(model) && !model.isCheckingOtherLists }
            #expect(rig.late.hasHeld && !rig.late.released, "\(rig.label)")
            var favorites = await rig.favorites()
            favorites.systems.append(.init(index: 103, listIndex: 1, name: "Mock Extra", type: "Conventional",
                                           quickKey: 2))
            await rig.setFavorites(favorites)
            armed.withLock { $0 = true }
            rig.late.swallow("GLT,SYS,1", times: 1)
            let mark = await rig.commands().count
            await model.toggle(.system(list: 1, system: 102))
            #expect(rig.late.released, "\(rig.label)")
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(model.lastError == "The list changed on the scanner; nothing was sent.", "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aSettleReReadDoesntSkipAFreshClaim() async throws {
        // QA R12. List 4 asks list 1 to settle (the cache says 102 is list 1's; the radio moved it to list 4). List 1's
        // settle re-read takes list 0's systems (a misdirected `GLT,SYS,1`); list 0 was read this open, so its claim is
        // fresh: the reply is refused, list 0 keeps its systems, and list 1 never shows them.
        try await onBothMocks(favorites: moving102ToListFour(), cache: cachedListOne()) { rig in
            rig.late.misdirect("GLT,SYS,1", to: try ScannerCommand("GLT", "SYS", "0"))
            let model = makeModel(rig)
            model.open()
            var wrong: [String] = []
            try await waitUntil("every list read (\(rig.label))", .seconds(6)) {
                if model.trees[1]?.freshness == .fresh, system(110, in: model.trees[1]) != nil { wrong.append("1 has 110") }
                if let zero = model.trees[0], system(110, in: zero) == nil { wrong.append("0 lost 110") }
                return allFresh(model) && !model.isCheckingOtherLists
            }
            #expect(wrong.isEmpty, "\(rig.label): \(Set(wrong))")
            #expect(model.trees[1]?.systems.map(\.index) == [101], "\(rig.label)")
            #expect(model.trees[0]?.systems.map(\.index) == [110, 111, 112], "\(rig.label)")
            #expect(Set(model.trees[4]?.systems.map(\.index) ?? []) == [102, 120, 121, 122], "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func theTwoDecisiveChildRepliesMustAgree() async throws {
        // The same for a department's set (201 under system 101, list 1): the check's first `GLT,DEPT,101` takes a
        // reply left over from list 1's read, from before the radio added department 204 to 101 (the known
        // departments, so it passes), and its own reply is lost; the second gets 101's departments now. Both hold 201
        // with its key, but they don't agree: nothing is sent.
        try await onBothMocks { rig in
            let armed = Mutex(false)
            rig.late.hold("GLT,DEPT,101") { text in text == "GLT,DEPT,101" && armed.withLock { $0 } }
            let model = makeModel(rig, pollInterval: .milliseconds(300))
            model.open()
            try await waitUntil("every list read (\(rig.label))") { allFresh(model) && !model.isCheckingOtherLists }
            #expect(rig.late.hasHeld && !rig.late.released, "\(rig.label)")
            var favorites = await rig.favorites()
            favorites.children.append(.init(index: 204, systemIndex: 101, kind: .department, name: "Mock Extra Dept",
                                            quickKey: 2))
            await rig.setFavorites(favorites)
            armed.withLock { $0 = true }
            rig.late.swallow("GLT,DEPT,101", times: 1)
            let mark = await rig.commands().count
            await model.toggle(.child(list: 1, system: 101, child: 201))
            #expect(rig.late.released, "\(rig.label)")
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(model.lastError == "The list changed on the scanner; nothing was sent.", "\(rig.label)")
            await shutDown(model)
        }
    }
}
