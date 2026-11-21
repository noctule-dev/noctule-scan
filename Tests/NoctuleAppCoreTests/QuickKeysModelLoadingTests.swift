// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleMockScanner
@testable import NoctuleAppCore

// QuickKeysModel (Plan 20 Task 5; design `docs/specs/2026-11-18-quick-keys-design.md` §5.4): loading the
// keypad first, the background reads, the structure-only cache and the polls, against MockSDS200 over UDP
// and MockSerialScanner (SDS150) over serial, each on a stepped clock with `quickKeySetDelay: .zero`, a
// short poll interval and a temporary cache file. The model only reads: every test can check the mock's
// log for sets. Every name is fictional (`MockFavorites.default`).

private struct QKRig {
    let label: String
    let client: ScannerClient
    let cacheURL: URL
    let setFaults: @Sendable (MockFaults) async -> Void
    let favorites: @Sendable () async -> MockFavorites
    let setFavorites: @Sendable (MockFavorites) async -> Void
    let commands: @Sendable () async -> [String]
}

/// The lists of `MockFavorites.default`, in `GLT` order.
private let defaultLists: [UInt32] = [0, 1, 4, 6, 8, 10, 12, 14]

/// Runs `body` against the network SDS200 mock, then the serial SDS150 mock, each with its own
/// temporary cache directory; stops the client and the mock on every path.
@MainActor
private func onBothMocks(replyDelays: [String: Duration] = [:], commandTimeout: Duration = .milliseconds(600),
                         _ body: @MainActor (QKRig) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("qk-model-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let options = MockSDS200.Options(clock: .stepped(at: 3), replyDelays: replyDelays, quickKeySetDelay: .zero)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort),
                                   commandTimeout: commandTimeout)
        var failure: (any Error)?
        do {
            try await client.connect()
            let rig = QKRig(label: "SDS200 over UDP", client: client,
                            cacheURL: directory.appendingPathComponent("sds200/quick-keys.json"),
                            setFaults: { await mock.setFaults($0) }, favorites: { await mock.favorites },
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
            let connected = ScannerClient(transport: SerialTransport(path: path), commandTimeout: commandTimeout)
            client = connected
            try await connected.connect()
            let rig = QKRig(label: "SDS150 over serial", client: connected,
                            cacheURL: directory.appendingPathComponent("sds150/quick-keys.json"),
                            setFaults: { await mock.setFaults($0) }, favorites: { await mock.favorites },
                            setFavorites: { await mock.setFavorites($0) }, commands: { await mock.receivedCommands })
            try await body(rig)
        } catch { failure = error }
        await client?.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
}

/// Records how many lists the model had published each time it asked for the client.
@MainActor
private final class ListsWatch {
    weak var model: QuickKeysModel?
    var counts: [Int] = []
    func note() { counts.append(model?.lists.count ?? 0) }
}

/// A model attached to `rig`'s client. `onControl` runs (on the main actor) each time the model asks for
/// the client, which it does right before each command.
@MainActor
private func makeModel(_ rig: QKRig, pollInterval: Duration = .milliseconds(150),
                       onControl: (@MainActor @Sendable () -> Void)? = nil) -> QuickKeysModel {
    let model = QuickKeysModel(cacheURL: rig.cacheURL, pollInterval: pollInterval)
    let client = rig.client
    model.attach(control: {
        if let onControl { await MainActor.run { onControl() } }
        return client
    })
    return model
}

/// Closes and detaches `model` and waits for its reads to end.
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

@MainActor
private func waitAllFresh(_ model: QuickKeysModel, _ label: String) async throws {
    try await waitUntil("every list read (\(label))") { allFresh(model) }
}

private func scannerInfo(_ xml: String) throws -> ScannerInfo {
    try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

/// A scanning status naming list 1 with the wrong `Q_Key` (as the real scanner does, design §3.4).
private func scanning(list: UInt32 = 1, system: UInt32 = 101, department: UInt32? = 200,
                      site: UInt32? = nil) throws -> ScannerInfo {
    var xml = "<ScannerInfo Mode=\"Trunk Scan\" V_Screen=\"trunk_scan\">"
    xml += "<MonitorList Name=\"Mock List\" Index=\"\(list)\" ListType=\"FL\" Q_Key=\"0\" N_Tag=\"None\" DB_Counter=\"1\"/>"
    xml += "<System Name=\"Mock System\" Index=\"\(system)\" Avoid=\"Off\" SystemType=\"P25 Trunk\" Q_Key=\"0\" N_Tag=\"None\" Hold=\"Off\"/>"
    if let department {
        xml += "<Department Name=\"Mock Department\" Index=\"\(department)\" Avoid=\"Off\" Q_Key=\"0\" Hold=\"Off\"/>"
    }
    if let site {
        xml += "<Site Name=\"Mock Site\" Index=\"\(site)\" Avoid=\"Off\" Q_Key=\"0\" Hold=\"Off\" Mod=\"NFM\"/>"
    }
    xml += "</ScannerInfo>"
    return try scannerInfo(xml)
}

private func inMenu() throws -> ScannerInfo {
    try scannerInfo("<ScannerInfo Mode=\"Menu tree\" V_Screen=\"menu_selection\"><MenuSummary name=\"MENU\" index=\"4293060001\"/></ScannerInfo>")
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
    commands.filter { command in
        let parts = command.split(separator: ",", omittingEmptySubsequences: false)
        switch parts.first.map(String.init)?.uppercased() {
        case "FQK": return parts.count > 1
        case "SQK": return parts.count > 2
        case "DQK": return parts.count > 3
        default: return false
        }
    }
}

private func count(_ command: String, in commands: [String]) -> Int {
    commands.filter { $0 == command }.count
}

/// Every system and child state in `tree`.
private func states(_ tree: QuickKeyListTree?) -> [QuickKeyState?] {
    guard let tree else { return [] }
    return tree.systems.flatMap { [$0.state] + $0.children.map(\.state) }
}

private func system(_ index: UInt32, in tree: QuickKeyListTree?) -> QuickKeyListTree.SystemRow? {
    tree?.systems.first { $0.index == index }
}

/// `favorites` with system 102 ("Mock Simplex", S1 in list 1) moved to quick key 3.
private func moving102(_ favorites: MockFavorites) -> MockFavorites {
    var moved = favorites
    if let at = moved.systems.firstIndex(where: { $0.index == 102 }) { moved.systems[at].quickKey = 3 }
    return moved
}

/// A structure-only tree for list 1 as a previous run would have cached it (102 is S1).
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
    return [1: QuickKeyListTree(systems: systems, freshness: .fresh)]
}

/// Samples `trees[list]` every 5 ms until `done` holds, returning each distinct snapshot.
@MainActor
private func sample(_ model: QuickKeysModel, list: UInt32, until what: String,
                    _ done: @MainActor (QuickKeyListTree?) -> Bool) async throws -> [QuickKeyListTree?] {
    var seen: [QuickKeyListTree?] = []
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
        let tree = model.trees[list]
        if seen.last.map({ $0 != tree }) ?? true { seen.append(tree) }
        if done(tree) { return seen }
        guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Like `sample`, also recording `row`'s switch state with each snapshot; whenever the row shows `.checking` it
/// is clicked (Task 6, R4: a click there is refused and sends nothing).
@MainActor
private func sampleSwitching(_ model: QuickKeysModel, list: UInt32, row: QuickKeyRow, until what: String,
                             _ done: @MainActor (QuickKeyListTree?) -> Bool) async throws
    -> [(tree: QuickKeyListTree?, state: QuickKeySwitchState)] {
    var seen: [(tree: QuickKeyListTree?, state: QuickKeySwitchState)] = []
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
        let tree = model.trees[list]
        let state = model.switchState(for: row)
        if seen.last.map({ $0.tree != tree || $0.state != state }) ?? true { seen.append((tree, state)) }
        if done(tree) { return seen }
        if state == .checking { await model.toggle(row) }
        guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct QuickKeysModelLoadingTests {
    // MARK: Loading order

    @Test func theKeypadComesFirst() async throws {
        try await onBothMocks { rig in
            // How many lists were published each time the model asked for the client (right before each command).
            let watch = ListsWatch()
            let model = makeModel(rig, onControl: { watch.note() })
            watch.model = model
            model.open()
            try await waitUntil("the keypad (\(rig.label))") { !model.lists.isEmpty }
            #expect(model.lists.map(\.index) == defaultLists, "\(rig.label)")
            #expect(model.lists.map(\.key) == [0, 7, 1, 3, 12, nil, 23, 41], "\(rig.label)")
            #expect(model.lists.first { $0.index == 1 }?.state == .on, "\(rig.label)")
            #expect(model.lists.first { $0.index == 4 }?.monitored == true, "\(rig.label)")
            #expect(model.lists.first { $0.index == 10 }?.state == nil, "no key, no state (\(rig.label))")
            try await waitAllFresh(model, rig.label)
            await shutDown(model)
            let commands = await rig.commands()
            #expect(Array(commands.prefix(2)) == ["GLT,FL", "FQK"], "\(rig.label): \(commands)")
            let firstSystems = try #require(commands.firstIndex { $0.hasPrefix("GLT,SYS") }, "\(rig.label)")
            let seen = watch.counts
            #expect(seen.count > firstSystems, "\(rig.label)")
            if seen.count > firstSystems {
                #expect(seen[0] == 0 && seen[1] == 0, "\(rig.label): \(seen)")
                #expect(seen[firstSystems] == defaultLists.count, "lists published before GLT,SYS (\(rig.label))")
            }
        }
    }

    @Test func scanningListLoadsFirst() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.statusArrived(try scanning(list: 1))
            model.open()
            try await waitAllFresh(model, rig.label)
            await shutDown(model)
            let order = systemReads(await rig.commands())
            // The scanning list, then the keyed lists by key (0, 1, 3, 12, 23, 41), then the unkeyed one.
            #expect(order == [1, 0, 4, 6, 8, 12, 14, 10], "\(rig.label)")
        }
    }

    @Test func listsLoadByKeyWithoutAScanningList() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            await shutDown(model)
            #expect(systemReads(await rig.commands()) == [0, 4, 6, 1, 8, 12, 14, 10], "\(rig.label)")
        }
    }

    @Test func showingAListJumpsTheQueue() async throws {
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(40)]) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("list 0 read (\(rig.label))") { model.trees[0]?.freshness == .fresh }
            model.showList(14)
            #expect(model.shownList == 14, "\(rig.label)")
            #expect(model.trees[14]?.freshness == .loading, "\(rig.label)")
            try await waitUntil("list 14 read (\(rig.label))") { model.trees[14]?.freshness == .fresh }
            await shutDown(model)
            let order = systemReads(await rig.commands())
            // Without the jump 14 would be seventh (keys 0, 1, 3, 7, 12, 23, 41). At most the list already
            // being read (4, key 1) comes between list 0 and 14.
            let at = try #require(order.firstIndex(of: 14), "\(rig.label): \(order)")
            #expect(at <= 2, "\(rig.label): \(order)")
            #expect(order.prefix(at).allSatisfy { $0 == 0 || $0 == 4 }, "\(rig.label): \(order)")
        }
    }

    // MARK: The cache

    @Test func theCacheIsShownCheckingWithoutStates() async throws {
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(150)]) { rig in
            try QuickKeysCache.save(cachedListOne(), to: rig.cacheURL)
            let model = makeModel(rig)
            #expect(model.trees.isEmpty, "nothing before the keypad (\(rig.label))")
            model.statusArrived(try scanning(list: 1))
            model.open()
            var atKeypad: [UInt32: QuickKeyListTree] = [:]
            try await waitUntil("the keypad (\(rig.label))") {
                atKeypad = model.trees
                return !model.lists.isEmpty
            }
            let cached = try #require(atKeypad[1], "the cached tree is shown with the keypad (\(rig.label))")
            #expect(cached.freshness == .checking, "\(rig.label)")
            #expect(cached.systems.map(\.index) == [101, 102], "\(rig.label)")
            #expect(states(cached).allSatisfy { $0 == nil }, "no cached state (\(rig.label))")
            #expect(atKeypad[0] == nil, "a list never cached has no tree yet (\(rig.label))")
            try await waitUntil("list 1 read (\(rig.label))") { model.trees[1]?.freshness == .fresh }
            let fresh = try #require(model.trees[1])
            #expect(system(102, in: fresh)?.state == .on, "\(rig.label)")
            #expect(fresh.systems.first?.children.first { $0.index == 200 }?.state == .on, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aMovedKeyIsNeverSwitchedFromTheCache() async throws {
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(100)]) { rig in
            try QuickKeysCache.save(cachedListOne(), to: rig.cacheURL)
            await rig.setFavorites(moving102(await rig.favorites()))
            let model = makeModel(rig)
            model.statusArrived(try scanning(list: 1))
            model.open()
            try await waitUntil("the keypad (\(rig.label))") { !model.lists.isEmpty }
            let seen = try await sampleSwitching(model, list: 1, row: .system(list: 1, system: 102),
                                                 until: "list 1 read (\(rig.label))") { $0?.freshness == .fresh }
            let first = try #require(seen.first?.tree, "\(rig.label)")
            #expect(system(102, in: first)?.key == 1, "the cached S1 is shown first (\(rig.label))")
            for (tree, state) in seen.dropLast() {
                // Until the re-read finishes, nothing in the list is switchable: checking, with no state.
                #expect(tree?.freshness == .checking, "\(rig.label): \(String(describing: tree))")
                #expect(states(tree).allSatisfy { $0 == nil }, "\(rig.label)")
                #expect(state == .checking, "\(rig.label)")
            }
            let last = try #require(seen.last?.tree)
            #expect(last.freshness == .fresh, "\(rig.label)")
            #expect(system(102, in: last)?.key == 3, "\(rig.label)")
            #expect(system(102, in: last)?.state == .on, "\(rig.label)")
            // List 1, the scanning list, is read first: its switches wait for the other lists.
            #expect(seen.last?.state == .checkingOtherLists, "\(rig.label)")
            try await waitAllFresh(model, rig.label)
            #expect(model.switchState(for: .system(list: 1, system: 102)) == .on, "\(rig.label)")
            await shutDown(model)
            // The clicks while it was checking sent nothing.
            #expect(sets(await rig.commands()).isEmpty, "\(rig.label)")
            // The cache now holds the moved key.
            let saved = try #require(QuickKeysCache.load(from: rig.cacheURL), "\(rig.label)")
            #expect(system(102, in: saved[1])?.key == 3, "\(rig.label)")
        }
    }

    @Test func theCacheHoldsNoStates() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            let shown = model.trees
            await shutDown(model)
            let text = try String(contentsOf: rig.cacheURL, encoding: .utf8)
            #expect(!text.contains("\"state\""), "\(rig.label)")
            #expect(!text.contains("freshness"), "\(rig.label)")
            #expect(text.contains("\"version\""), "\(rig.label)")
            let loaded = try #require(QuickKeysCache.load(from: rig.cacheURL), "\(rig.label)")
            #expect(Set(loaded.keys) == Set(defaultLists), "\(rig.label)")
            for (index, tree) in loaded {
                #expect(tree.freshness == .checking, "\(rig.label)")
                #expect(states(tree).allSatisfy { $0 == nil }, "\(rig.label)")
                // The same structure the model showed, without its states.
                let names = shown[index]?.systems.map { [$0.name] + $0.children.map(\.name) }
                #expect(tree.systems.map { [$0.name] + $0.children.map(\.name) } == names, "\(rig.label)")
                let keys = shown[index]?.systems.map { [$0.key] + $0.children.map(\.key) }
                #expect(tree.systems.map { [$0.key] + $0.children.map(\.key) } == keys, "\(rig.label)")
            }
        }
    }

    @Test func aMissingOrUnreadableCacheIsNoCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qk-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("quick-keys.json")
        #expect(QuickKeysCache.load(from: file) == nil)
        try Data("not json".utf8).write(to: file)
        #expect(QuickKeysCache.load(from: file) == nil)
        try Data(#"{"version":99,"lists":[]}"#.utf8).write(to: file)
        #expect(QuickKeysCache.load(from: file) == nil, "a newer version is no cache")
        try QuickKeysCache.save(cachedListOne(), to: file)
        let loaded = try #require(QuickKeysCache.load(from: file))
        #expect(loaded[1]?.systems.map(\.index) == [101, 102])
        #expect(loaded[1]?.systems.last?.children.map(\.key) == [0, 1, 2])
        #expect(loaded[1]?.systems.first?.children.last?.kind == .site)
    }

    // MARK: Re-checks

    @Test func aKeyMovedWhileOpenIsRecheckedBeforeSwitching() async throws {
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(60)]) { rig in
            let model = makeModel(rig)
            model.open()
            model.showList(1)
            try await waitAllFresh(model, rig.label)
            // A poll of the shown list has run with the tree's own pattern.
            try await waitUntil("a poll of SQK,7 (\(rig.label))") { await count("SQK,7", in: rig.commands()) >= 2 }
            #expect(system(102, in: model.trees[1])?.key == 1, "\(rig.label)")
            let mark = await rig.commands().count
            await rig.setFavorites(moving102(await rig.favorites()))
            let sampled = try await sampleSwitching(model, list: 1, row: .system(list: 1, system: 102),
                                                    until: "102 re-read as S3 (\(rig.label))") {
                $0?.freshness == .fresh && system(102, in: $0)?.key == 3
            }
            let seen = sampled.map(\.tree)
            #expect(seen.contains { $0?.freshness == .checking && states($0).allSatisfy { $0 == nil } },
                    "the list showed as checking (\(rig.label))")
            // Once the change is seen, the moved row can't be switched until the re-read is done.
            for (tree, state) in sampled where tree?.freshness == .checking {
                #expect(state == .checking, "\(rig.label)")
            }
            #expect(sampled.last?.state == .on, "\(rig.label)")
            for tree in seen where tree?.freshness == .fresh {
                // Any fresh view has states only for the keys it names.
                #expect(system(102, in: tree)?.key == 1 || system(102, in: tree)?.key == 3, "\(rig.label)")
            }
            await shutDown(model)
            let after = Array(await rig.commands().dropFirst(mark))
            let firstSystems = try #require(after.firstIndex(of: "GLT,SYS,1"), "\(rig.label): \(after)")
            // The scope that saw the change was read twice in a row (a stray reply is read again once) just
            // before the re-read. Moving 102 changes both SQK,7's pattern and DQK,7,1's, and the change can land
            // between a poll's two reads, so either can be the one.
            #expect(firstSystems >= 2, "\(rig.label): \(after)")
            if firstSystems >= 2 {
                let twice = Array(after[(firstSystems - 2)..<firstSystems])
                #expect(twice == ["SQK,7", "SQK,7"] || twice == ["DQK,7,1", "DQK,7,1"], "\(rig.label): \(after)")
            }
            #expect(sets(after).isEmpty, "\(rig.label)")
        }
    }

    @Test func leavingAMenuRechecksTheTrees() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            let before = systemReads(await rig.commands())
            model.statusArrived(try inMenu())
            #expect(model.trees.values.allSatisfy { $0.freshness == .fresh }, "entering a menu changes nothing (\(rig.label))")
            model.statusArrived(try scanning())
            #expect(model.trees.count == defaultLists.count, "\(rig.label)")
            #expect(model.trees.values.allSatisfy { $0.freshness == .checking }, "\(rig.label)")
            #expect(model.trees.values.allSatisfy { states($0).allSatisfy { $0 == nil } }, "\(rig.label)")
            try await waitAllFresh(model, rig.label)
            await shutDown(model)
            let after = systemReads(await rig.commands())
            for list in defaultLists {
                #expect(after.filter { $0 == list }.count == before.filter { $0 == list }.count + 1,
                        "GLT,SYS,\(list) re-sent once (\(rig.label))")
            }
        }
    }

    // MARK: Polling

    @Test func pollsOnlyWhileOpen() async throws {
        let interval: Duration = .milliseconds(150)
        try await onBothMocks { rig in
            let model = makeModel(rig, pollInterval: interval)
            #expect(await rig.commands().isEmpty, "nothing before open (\(rig.label))")
            model.open()
            model.showList(1)
            try await waitAllFresh(model, rig.label)
            try await waitUntil("polls (\(rig.label))") {
                let commands = await rig.commands()
                return count("FQK", in: commands) >= 3 && count("SQK,7", in: commands) >= 3
                    && count("DQK,7,0", in: commands) >= 3 && count("DQK,7,1", in: commands) >= 3
            }
            let commands = await rig.commands()
            // Only the shown list is polled: list 0 (key 0) was read once and never again.
            #expect(count("SQK,0", in: commands) == 1, "\(rig.label)")
            #expect(count("GLT,FL", in: commands) == 1, "the tree is read on open, not on the timer (\(rig.label))")
            model.close()
            await model.quiesce()
            let closed = await rig.commands().count
            try await Task.sleep(for: interval * 3)
            #expect(await rig.commands().count == closed, "nothing read while closed (\(rig.label))")
            #expect(model.lists.allSatisfy { $0.state == nil }, "\(rig.label)")
            #expect(model.trees.values.allSatisfy { states($0).allSatisfy { $0 == nil } }, "\(rig.label)")
            // Opening again reads the keypad and every tree again.
            model.open()
            try await waitAllFresh(model, rig.label)
            #expect(count("GLT,FL", in: await rig.commands()) == 2, "\(rig.label)")
            model.detach()
            await model.quiesce()
            let detached = await rig.commands().count
            try await Task.sleep(for: interval * 3)
            #expect(await rig.commands().count == detached, "nothing read once detached (\(rig.label))")
            await shutDown(model)
        }
    }

    @Test func aSilentScannerIsReported() async throws {
        try await onBothMocks(commandTimeout: .milliseconds(300)) { rig in
            let model = makeModel(rig, pollInterval: .milliseconds(250))
            model.open()
            try await waitAllFresh(model, rig.label)
            #expect(model.isScannerAnswering, "\(rig.label)")
            let mark = await rig.commands().count
            await rig.setFaults(MockFaults(dropNextRequest: "FQK", dropCount: 2))
            try await waitUntil("not answering (\(rig.label))") { !model.isScannerAnswering }
            try await waitUntil("answering again (\(rig.label))") { model.isScannerAnswering }
            await shutDown(model)
            let after = Array(await rig.commands().dropFirst(mark))
            // Nothing is shown, so the polls read only FQK: two unanswered in a row, then one answered.
            #expect(count("FQK", in: after) >= 3, "\(rig.label): \(after)")
            #expect(after.allSatisfy { $0 == "FQK" }, "\(rig.label): \(after)")
        }
    }

    @Test func aTimedOutReadIsNotRetriedInPlace() async throws {
        // A state read (`FQK` here) isn't retried in place, which would only pass a late reply on to the next read of
        // the same name (final review C1): the read fails, and nothing is read until the rest is over, so a late reply
        // finds no read to answer. (`GLT` reads are retried once: `QuickKeysModelOwnershipTests`.)
        try await onBothMocks(commandTimeout: .milliseconds(300)) { rig in
            let model = makeModel(rig, pollInterval: .seconds(3))
            model.open()
            try await waitAllFresh(model, rig.label)
            let mark = await rig.commands().count
            await rig.setFaults(MockFaults(dropNextRequest: "FQK", dropCount: 1))
            try await waitUntil("the next poll (\(rig.label))", .seconds(5)) {
                await rig.commands().count > mark
            }
            // Its timeout (300 ms) passes with no second FQK: the next one waits for the rest (3 s).
            try await Task.sleep(for: .milliseconds(1000))
            #expect(Array(await rig.commands().dropFirst(mark)) == ["FQK"], "\(rig.label)")
            #expect(model.lastError == "The scanner didn't answer FQK.", "\(rig.label)")
            #expect(model.isScannerAnswering, "one timeout isn't a silent scanner (\(rig.label))")
            try await waitUntil("the poll after the rest (\(rig.label))", .seconds(5)) {
                await count("FQK", in: Array(rig.commands().dropFirst(mark))) >= 2
            }
            try await waitUntil("the error cleared (\(rig.label))") { model.lastError == nil }
            #expect(model.isScannerAnswering, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func noSetIsEverSent() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.statusArrived(try scanning())
            model.open()
            model.showList(4)
            try await waitAllFresh(model, rig.label)
            try await waitUntil("polls (\(rig.label))") { await count("SQK,1", in: rig.commands()) >= 3 }
            model.statusArrived(try inMenu())
            model.statusArrived(try scanning())
            try await waitAllFresh(model, rig.label)
            model.showList(1)
            try await waitUntil("polls of list 1 (\(rig.label))") { await count("SQK,7", in: rig.commands()) >= 3 }
            await shutDown(model)
            let commands = await rig.commands()
            #expect(sets(commands).isEmpty, "\(rig.label): \(sets(commands))")
            let names = Set(commands.map { $0.split(separator: ",").first.map(String.init) ?? $0 })
            #expect(names.isSubset(of: ["GLT", "FQK", "SQK", "DQK"]), "\(rig.label): \(names)")
        }
    }

    // MARK: Scanning now

    @Test func scanningMatchesByIndex() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            // GSI's MonitorList says Q_Key 0, which is list 0's key: matching by key would pick list 0.
            model.statusArrived(try scanning(list: 1, system: 101, department: 200))
            #expect(model.scanning == QuickKeyScanning(list: 1, system: 101, child: 200), "\(rig.label)")
            model.statusArrived(try scanning(list: 1, system: 101, department: ScannerInfo.unprogrammedIndex,
                                             site: 999))
            #expect(model.scanning == QuickKeyScanning(list: 1, system: 101, child: nil), "\(rig.label)")
            model.statusArrived(try scanning(list: 1, system: 101, department: ScannerInfo.unprogrammedIndex,
                                             site: 301))
            #expect(model.scanning == QuickKeyScanning(list: 1, system: 101, child: 301), "\(rig.label)")
            model.statusArrived(try scanning(list: 1, system: 999, department: 200))
            #expect(model.scanning == QuickKeyScanning(list: 1, system: nil, child: nil), "\(rig.label)")
            model.statusArrived(try scanning(list: 77, system: 101, department: 200))
            #expect(model.scanning == QuickKeyScanning(list: nil, system: nil, child: nil), "\(rig.label)")
            await shutDown(model)
        }
    }

    // MARK: Constraints and races (QA round 1)

    @Test func sitesAreReadOnlyForTrunkedSystems() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            await shutDown(model)
            let commands = await rig.commands()
            let systems = await rig.favorites().systems
            for system in systems {
                let site = "GLT,SITE,\(system.index)"
                if system.type == "Conventional" {
                    #expect(!commands.contains(site), "no sites for a conventional system (\(rig.label)): \(site)")
                } else {
                    #expect(count(site, in: commands) == 1, "\(rig.label): \(site)")
                }
                #expect(count("GLT,DEPT,\(system.index)", in: commands) == 1, "\(rig.label)")
            }
            #expect(systems.contains { $0.type == "Conventional" } && systems.contains { $0.type != "Conventional" })
        }
    }

    @Test func reopeningDuringAListReadKeepsTheKeypad() async throws {
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(200)]) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("GLT,SYS sent (\(rig.label))") { await rig.commands().contains { $0.hasPrefix("GLT,SYS") } }
            model.close()
            model.open()
            try await waitUntil("the keypad again (\(rig.label))") { !model.lists.isEmpty }
            #expect(model.lists.map(\.index) == defaultLists, "\(rig.label)")
            await shutDown(model)
            // The read under way when the pop-over closed was answered before the reopen's first read went out.
            let commands = await rig.commands()
            let reopened = try #require(commands.indices.filter { commands[$0] == "GLT,FL" }.dropFirst().first,
                                        "\(rig.label): \(commands)")
            #expect(commands[reopened - 1].hasPrefix("GLT,SYS"), "\(rig.label): \(commands)")
        }
    }

    @Test func reopeningDuringTheKeypadDoesNotDelayTheLists() async throws {
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(200)]) { rig in
            let model = makeModel(rig, pollInterval: .seconds(3))
            model.open()
            try await waitUntil("GLT,FL sent (\(rig.label))") { await rig.commands().contains("GLT,FL") }
            model.close()
            model.open()
            let reopened = ContinuousClock.now
            try await waitUntil("the first GLT,SYS (\(rig.label))") {
                await rig.commands().contains { $0.hasPrefix("GLT,SYS") }
            }
            let elapsed = reopened.duration(to: .now)
            await shutDown(model)
            // The closed run's unanswered keypad must not rest the new run's reads for a poll interval (3 s).
            #expect(elapsed < .milliseconds(1500), "\(rig.label): \(elapsed)")
        }
    }

    @Test func aMenuExitDuringAKeypadReReadIsNotLost() async throws {
        // FQK is slow, so the keypad re-read (GLT,FL then FQK) is still under way when the menu exit comes.
        try await onBothMocks(replyDelays: ["FQK": .milliseconds(150)]) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            let mark = await rig.commands().count
            // List 8's key moves (12 to 13): FQK's pattern changes, so the keypad is read again.
            var favorites = await rig.favorites()
            if let at = favorites.lists.firstIndex(where: { $0.index == 8 }) { favorites.lists[at].quickKey = 13 }
            await rig.setFavorites(favorites)
            try await waitUntil("the keypad re-read (\(rig.label))") {
                await rig.commands().dropFirst(mark).contains("GLT,FL")
            }
            // The scanner leaves a menu while that re-read is under way.
            model.statusArrived(try inMenu())
            model.statusArrived(try scanning())
            #expect(model.trees.values.allSatisfy { $0.freshness == .checking }, "\(rig.label)")
            try await waitAllFresh(model, rig.label)
            #expect(model.lists.first { $0.index == 8 }?.key == 13, "\(rig.label)")
            await shutDown(model)
            let after = systemReads(Array(await rig.commands().dropFirst(mark)))
            #expect(Set(after) == Set(defaultLists), "every list read again (\(rig.label)): \(after)")
        }
    }

    @Test func aListReadBeforeAMenuExitIsNotFresh() async throws {
        try await onBothMocks(replyDelays: ["GLT": .milliseconds(100)]) { rig in
            let model = makeModel(rig)
            model.statusArrived(try scanning(list: 1))
            model.open()
            try await waitUntil("list 1's departments (\(rig.label))") {
                await rig.commands().contains("GLT,DEPT,101")
            }
            let mark = await rig.commands().count
            model.statusArrived(try inMenu())
            model.statusArrived(try scanning(list: 1))
            // List 1 may be fresh again only from a read that began after the exit: GLT,SYS,1 and its last
            // structure read (GLT,DEPT,102, a conventional system) both sent after the mark.
            let seen = try await sample(model, list: 1, until: "list 1 fresh again (\(rig.label))") {
                $0?.freshness == .fresh
            }
            let after = Array(await rig.commands().dropFirst(mark))
            let systems = try #require(after.firstIndex(of: "GLT,SYS,1"), "\(rig.label): \(after)")
            #expect(after[systems...].contains("GLT,DEPT,102"), "\(rig.label): \(after)")
            #expect(seen.dropLast().allSatisfy { $0?.freshness != .fresh }, "\(rig.label)")
            await shutDown(model)
        }
    }
}
