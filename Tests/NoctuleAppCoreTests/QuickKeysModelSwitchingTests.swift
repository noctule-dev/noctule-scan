// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
@testable import NoctuleKit
import NoctuleMockScanner
@testable import NoctuleAppCore

// QuickKeysModel switching (Plan 20 Task 6; design `docs/specs/2026-11-18-quick-keys-design.md` §5.4
// "Switching", "Shared numbers", "What can't be switched", "When not to switch"): one set per click, naming
// one key, never resent, confirmed by a re-read; against MockSDS200 over UDP and MockSerialScanner (SDS150)
// over serial, each on a stepped clock with `quickKeySetDelay: .zero`. Every name is fictional
// (`MockFavorites.default`).

private struct QKSwitchRig {
    let label: String
    let client: ScannerClient
    let cacheURL: URL
    /// The transport wrapper, when the test asked for one (`onBothMocks(stray: true)`).
    let stray: StrayReplyTransport?
    let setFaults: @Sendable (MockFaults) async -> Void
    let favorites: @Sendable () async -> MockFavorites
    let setFavorites: @Sendable (MockFavorites) async -> Void
    let commands: @Sendable () async -> [String]
}

/// Runs `body` against the network SDS200 mock, then the serial SDS150 mock, each with its own temporary
/// cache directory; stops the client and the mock on every path. With `stray`, the client's transport is
/// wrapped in a `StrayReplyTransport`.
@MainActor
private func onBothMocks(commandTimeout: Duration = .milliseconds(600), stray: Bool = false,
                         _ body: @MainActor (QKSwitchRig) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("qk-switch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func wrapped(_ transport: any ScannerTransport) -> (any ScannerTransport, StrayReplyTransport?) {
        guard stray else { return (transport, nil) }
        let wrapper = StrayReplyTransport(transport)
        return (wrapper, wrapper)
    }
    do {
        let options = MockSDS200.Options(clock: .stepped(at: 3), quickKeySetDelay: .zero)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        let (transport, wrapper) = wrapped(UDPTransport(host: "127.0.0.1", port: ports.udpPort))
        let client = ScannerClient(transport: transport, commandTimeout: commandTimeout)
        var failure: (any Error)?
        do {
            try await client.connect()
            let rig = QKSwitchRig(label: "SDS200 over UDP", client: client,
                                  cacheURL: directory.appendingPathComponent("sds200/quick-keys.json"), stray: wrapper,
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
                                     quickKeySetDelay: .zero)
        var failure: (any Error)?
        var client: ScannerClient?
        do {
            let path = try await mock.start()
            let (transport, wrapper) = wrapped(SerialTransport(path: path))
            let connected = ScannerClient(transport: transport, commandTimeout: commandTimeout)
            client = connected
            try await connected.connect()
            let rig = QKSwitchRig(label: "SDS150 over serial", client: connected,
                                  cacheURL: directory.appendingPathComponent("sds150/quick-keys.json"), stray: wrapper,
                                  setFaults: { await mock.setFaults($0) }, favorites: { await mock.favorites },
                                  setFavorites: { await mock.setFavorites($0) }, commands: { await mock.receivedCommands })
            try await body(rig)
        } catch { failure = error }
        await client?.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
}

/// A transport that can deliver one reply late, deterministically: once armed it holds back the reply to the
/// next command written as `holdReplyTo` (the next response with that command's name), so that read times out,
/// and delivers it just before writing the first command `releaseBefore` accepts (given the commands written
/// since arming and the one about to go). That is the stray of design §5.4 Switching 4: a reply that arrives
/// after its read gave up and answers a later command of the same name. (A mock `replyDelays` entry delays
/// every reply of that name, the set's and the confirming re-read's too, so no read of it would get its own
/// reply in time and which stray answers what would depend on timing alone.)
final class StrayReplyTransport: ScannerTransport, Sendable {
    private struct State {
        var holdReplyTo: String?
        var holding: String?
        var held: ScannerResponse?
        var releaseBefore: (@Sendable ([String], String) -> Bool)?
        var sinceArming: [String] = []
        var released = false
        var continuation: AsyncStream<ScannerResponse>.Continuation?
    }

    private let base: any ScannerTransport
    private let state = Mutex(State())

    init(_ base: any ScannerTransport) { self.base = base }

    /// Holds the reply to the next `command` written (exact text, e.g. `DQK,7,0`), until a command that
    /// `releaseBefore` accepts is about to be written.
    func arm(holdReplyTo command: String, releaseBefore: @escaping @Sendable ([String], String) -> Bool) {
        state.withLock {
            $0.holdReplyTo = command
            $0.releaseBefore = releaseBefore
            $0.sinceArming = []
            $0.held = nil
            $0.released = false
        }
    }

    var hasHeld: Bool { state.withLock { $0.held != nil || $0.released } }
    var released: Bool { state.withLock { $0.released } }

    func open() async throws { try await base.open() }
    func close() async { await base.close() }

    func send(_ command: ScannerCommand) async throws {
        let text = ([command.name] + command.arguments).joined(separator: ",")
        let (late, continuation) = state.withLock { state -> (ScannerResponse?, AsyncStream<ScannerResponse>.Continuation?) in
            var late: ScannerResponse?
            if let held = state.held, let release = state.releaseBefore, release(state.sinceArming, text) {
                late = held
                state.held = nil
                state.released = true
            }
            if state.holdReplyTo == text {
                // Set before the write: the reply can come back before `send` returns.
                state.holding = command.name
                state.holdReplyTo = nil
            }
            if state.releaseBefore != nil { state.sinceArming.append(text) }
            return (late, state.continuation)
        }
        if let late { continuation?.yield(late) }
        try await base.send(command)
    }

    var responses: AsyncStream<ScannerResponse> {
        let upstream = base.responses
        return AsyncStream { continuation in
            state.withLock { $0.continuation = continuation }
            let relay = Task { [self] in
                for await response in upstream {
                    let hold = state.withLock { state -> Bool in
                        guard state.holding == response.command, state.held == nil else { return false }
                        state.held = response
                        state.holding = nil
                        return true
                    }
                    if !hold { continuation.yield(response) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}

@MainActor
private func makeModel(_ rig: QKSwitchRig, pollInterval: Duration = .milliseconds(150)) -> QuickKeysModel {
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
private func waitAllFresh(_ model: QuickKeysModel, _ label: String) async throws {
    try await waitUntil("every list read (\(label))") {
        !model.lists.isEmpty && model.lists.allSatisfy { model.trees[$0.index]?.freshness == .fresh }
    }
}

private func scannerInfo(_ xml: String) throws -> ScannerInfo {
    try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

private func scanning() throws -> ScannerInfo {
    try scannerInfo("<ScannerInfo Mode=\"Trunk Scan\" V_Screen=\"trunk_scan\">"
        + "<MonitorList Name=\"Mock List\" Index=\"1\" ListType=\"FL\" Q_Key=\"0\" N_Tag=\"None\" DB_Counter=\"1\"/>"
        + "<System Name=\"Mock System\" Index=\"101\" Avoid=\"Off\" SystemType=\"P25 Trunk\" Q_Key=\"0\" N_Tag=\"None\" Hold=\"Off\"/>"
        + "</ScannerInfo>")
}

private func inMenu() throws -> ScannerInfo {
    try scannerInfo("<ScannerInfo Mode=\"Menu tree\" V_Screen=\"menu_selection\"><MenuSummary name=\"MENU\" index=\"4293060001\"/></ScannerInfo>")
}

/// Any quick-key set: `FQK` with arguments, `SQK` with more than one, `DQK` with more than two.
private func sets(_ commands: [String]) -> [String] {
    commands.filter { setValues($0) != nil }
}

/// One of the open pop-over's background polls: `FQK`, `SQK,<list key>` or `DQK,<list key>,<system key>`, with
/// no values (never a `GLT`, never a set).
private func isPollRead(_ command: String) -> Bool {
    let parts = command.split(separator: ",", omittingEmptySubsequences: false)
    switch parts.first?.uppercased() {
    case "FQK": return parts.count == 1
    case "SQK": return parts.count == 2
    case "DQK": return parts.count == 3
    default: return false
    }
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

/// The command right after the first one starting with `prefix` (the set), or nil.
private func command(after prefix: String, in commands: [String]) -> String? {
    guard let at = commands.firstIndex(where: { $0.hasPrefix(prefix) }), at + 1 < commands.count else { return nil }
    return commands[at + 1]
}

private func count(_ command: String, in commands: [String]) -> Int {
    commands.filter { $0 == command }.count
}

/// Waits for a poll to end (its last read, `last`, logged once more), so a fault armed right after is
/// in place before the next poll's first read: these tests poll every second. Armed at a random
/// moment between 150 ms polls, the fault came too late on a runner VM, the read it was meant to lose
/// was answered and the poll went on (run 45019776194).
private func waitForAPollToEnd(_ rig: QKSwitchRig, last: String) async throws {
    let before = count(last, in: await rig.commands())
    try await waitUntil("a poll to end (\(rig.label))") { await count(last, in: rig.commands()) > before }
}

private func child(_ index: UInt32, in favorites: MockFavorites) -> MockFavorites.ChildRow? {
    favorites.children.first { $0.index == index }
}

private func system(_ index: UInt32, in favorites: MockFavorites) -> MockFavorites.SystemRow? {
    favorites.systems.first { $0.index == index }
}

private func system(_ index: UInt32, in tree: QuickKeyListTree) -> QuickKeyListTree.SystemRow? {
    tree.systems.first { $0.index == index }
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

/// Lists 40 and 41, both on F5, each with one conventional system on S0: 800 (750 Mock Gate D0) and 801 (760 Mock
/// Yard D0). Every key on.
private func twoListsOnOneKey() -> MockFavorites {
    MockFavorites(
        lists: [.init(index: 40, name: "Mock North", quickKey: 5), .init(index: 41, name: "Mock South", quickKey: 5)],
        systems: [.init(index: 800, listIndex: 40, name: "Mock North Conv", type: "Conventional", quickKey: 0),
                  .init(index: 801, listIndex: 41, name: "Mock South Conv", type: "Conventional", quickKey: 0)],
        children: [.init(index: 750, systemIndex: 800, kind: .department, name: "Mock Gate", quickKey: 0),
                   .init(index: 760, systemIndex: 801, kind: .department, name: "Mock Yard", quickKey: 0)])
}

/// Every row of `model`'s keypad and trees.
@MainActor
private func everyRow(_ model: QuickKeysModel) -> [QuickKeyRow] {
    var rows: [QuickKeyRow] = model.lists.map { .list($0.index) }
    for list in model.lists {
        for system in model.trees[list.index]?.systems ?? [] {
            rows.append(.system(list: list.index, system: system.index))
            rows += system.children.map { .child(list: list.index, system: system.index, child: $0.index) }
        }
    }
    return rows
}

/// A click whose set queues for the client's request slot behind a read the mock never answers (QA's probe for
/// I2 in the flaky-sweep review, made deterministic). Once armed, the model's `control()` just before the set
/// (after `checkReads` calls for the pre-set check's reads) first starts a `GSI` the mock drops, waits until the mock has it (so it holds the slot), and
/// then hands over the client. When the set is queued behind it (`requestsWaitingForTheSlot`), `interfere` runs
/// on the main actor; then the `GSI` is cancelled, which frees the slot at once. Returns every command the mock
/// received from the click on, after the click and every stopped loop have ended.
@MainActor
private func clickHeldAtTheSlot(_ rig: QKSwitchRig, _ row: QuickKeyRow, checkReads: Int = 0,
                                whileWaiting interfere: @MainActor (QuickKeysModel) throws -> Void,
                                then check: @MainActor (QuickKeysModel, [String]) async throws -> Void) async throws {
    // nil: disarmed; else the control calls still to pass before the one that holds the slot.
    let armed = Mutex<Int?>(nil)
    let held = Mutex<Task<Void, Never>?>(nil)
    let client = rig.client
    let commands = rig.commands
    let model = QuickKeysModel(cacheURL: rig.cacheURL, pollInterval: .seconds(30))
    model.attach(control: {
        let hold = armed.withLock { armed -> Bool in
            guard let left = armed else { return false }
            armed = left == 0 ? nil : left - 1
            return left == 0
        }
        if hold {
            let mark = await commands().count
            held.withLock { $0 = Task { _ = try? await client.scannerInfo() } }
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await commands().dropFirst(mark).contains("GSI")), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        return client
    })
    model.open()
    try await waitAllFresh(model, rig.label)
    let mark = await rig.commands().count
    await rig.setFaults(MockFaults(dropNextRequest: "GSI"))
    armed.withLock { $0 = checkReads }
    let click = Task { await model.toggle(row) }
    do {
        try await waitUntil("the set queued behind the held GSI (\(rig.label))") {
            await client.requestsWaitingForTheSlot == 1
        }
        try interfere(model)
    } catch {
        held.withLock { $0?.cancel() }
        await click.value
        await shutDown(model)
        throw error
    }
    held.withLock { $0?.cancel() }
    await click.value
    await model.quiesce()
    await held.withLock { $0 }?.value
    try await check(model, Array(await rig.commands().dropFirst(mark)))
    await shutDown(model)
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct QuickKeysModelSwitchingTests {
    // MARK: One set per click

    @Test func aTileClickSendsOneSet() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            #expect(model.switchState(for: .list(4)) == .off, "\(rig.label)")
            let mark = await rig.commands().count
            await model.toggle(.list(4))
            let after = Array(await rig.commands().dropFirst(mark))
            let sent = sets(after)
            #expect(sent.count == 1, "\(rig.label): \(after)")
            #expect(sent.first?.hasPrefix("FQK,") == true, "\(rig.label): \(sent)")
            // List 4's key is 1: "2" (on) there, "0" (leave alone) everywhere else.
            #expect(namesOnlyKey(sent.first.flatMap(setValues), 1, "2"), "\(rig.label): \(sent)")
            // Then the scope is read again, and the tile shows what the scanner holds.
            #expect(command(after: "FQK,", in: after) == "FQK", "\(rig.label): \(after)")
            #expect(model.switchState(for: .list(4)) == .on, "\(rig.label)")
            #expect(model.lists.first { $0.index == 4 }?.state == .on, "\(rig.label)")
            #expect(await rig.favorites().lists.first { $0.index == 4 }?.isOn == true, "\(rig.label)")
            #expect(model.lastError == nil, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aSystemAndAChildSwitch() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            var mark = await rig.commands().count
            // System 102 is S1 of list 1 (key 7), on: the click asks for off.
            #expect(model.switchState(for: .system(list: 1, system: 102)) == .on, "\(rig.label)")
            await model.toggle(.system(list: 1, system: 102))
            var after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("SQK,7,") == true, "\(rig.label): \(after)")
            #expect(namesOnlyKey(sets(after).first.flatMap(setValues), 1, "1"), "\(rig.label)")
            #expect(command(after: "SQK,7,", in: after) == "SQK,7", "\(rig.label): \(after)")
            #expect(model.switchState(for: .system(list: 1, system: 102)) == .off, "\(rig.label)")
            #expect(system(102, in: await rig.favorites())?.isOn == false, "\(rig.label)")
            // Site 621 is D1 of system 120 (S0) in list 4 (key 1), off: the click asks for on.
            mark = await rig.commands().count
            #expect(model.switchState(for: .child(list: 4, system: 120, child: 621)) == .off, "\(rig.label)")
            await model.toggle(.child(list: 4, system: 120, child: 621))
            after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("DQK,1,0,") == true, "\(rig.label): \(after)")
            #expect(namesOnlyKey(sets(after).first.flatMap(setValues), 1, "2"), "\(rig.label)")
            #expect(command(after: "DQK,1,0,", in: after) == "DQK,1,0", "\(rig.label): \(after)")
            #expect(model.switchState(for: .child(list: 4, system: 120, child: 621)) == .on, "\(rig.label)")
            #expect(child(621, in: await rig.favorites())?.isOn == true, "\(rig.label)")
            #expect(model.lastError == nil, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aRadioChangeIsNeverOverwritten() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            #expect(model.switchState(for: .system(list: 1, system: 102)) == .on, "\(rig.label)")
            // The radio turns S1 of list 7 (system 102) off; the model hasn't seen it (list 1 isn't shown).
            var favorites = await rig.favorites()
            if let at = favorites.systems.firstIndex(where: { $0.index == 102 }) { favorites.systems[at].isOn = false }
            await rig.setFavorites(favorites)
            await model.toggle(.system(list: 1, system: 101))
            let after = await rig.favorites()
            #expect(system(101, in: after)?.isOn == false, "\(rig.label)")
            #expect(system(102, in: after)?.isOn == false, "the radio's change stands (\(rig.label))")
            // The re-read shows both.
            #expect(model.switchState(for: .system(list: 1, system: 101)) == .off, "\(rig.label)")
            #expect(model.switchState(for: .system(list: 1, system: 102)) == .off, "\(rig.label)")
            await shutDown(model)
        }
    }

    // MARK: Unconfirmed changes

    @Test func aSetThatTimesOutIsNotResent() async throws {
        try await onBothMocks(commandTimeout: .milliseconds(300)) { rig in
            // List 1 isn't shown, so no poll reads SQK,7: the fault can only meet the set.
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            let mark = await rig.commands().count
            await rig.setFaults(MockFaults(dropNextReply: "SQK"))
            await model.toggle(.system(list: 1, system: 101))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "never resent (\(rig.label)): \(after)")
            #expect(model.lastError == "The scanner didn't confirm the change", "\(rig.label)")
            // The set took effect; the re-read shows it.
            #expect(count("SQK,7", in: after) >= 1, "\(rig.label): \(after)")
            #expect(model.switchState(for: .system(list: 1, system: 101)) == .off, "\(rig.label)")
            #expect(system(101, in: await rig.favorites())?.isOn == false, "\(rig.label)")
            // No later read sends it again.
            try await Task.sleep(for: .milliseconds(450))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).count == 1, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aFailedReReadOfAListNotShownShowsNoStateAndIsReadAgain() async throws {
        try await onBothMocks(commandTimeout: .milliseconds(300)) { rig in
            // List 1 isn't shown, so no poll reads SQK,7: the set's reply and its re-read's are lost (a state read
            // isn't retried in place).
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            let mark = await rig.commands().count
            await rig.setFaults(MockFaults(dropNextReply: "SQK", dropCount: 2))
            await model.toggle(.system(list: 1, system: 101))
            // Nothing confirmed what the scanner holds: no on/off, nothing switchable, and the error says so.
            let state = model.switchState(for: .system(list: 1, system: 101))
            #expect(state == .unknown || state == .checking, "\(rig.label): \(state)")
            #expect(model.trees[1]?.systems.first { $0.index == 101 }?.state == nil, "\(rig.label)")
            #expect(model.lastError == "The scanner didn't confirm the change", "\(rig.label)")
            await model.toggle(.system(list: 1, system: 101))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).count == 1, "\(rig.label)")
            // No poll reads that scope, so the list is read again by itself, and shows what the scanner holds.
            try await waitUntil("system 101 read again (\(rig.label))") {
                model.switchState(for: .system(list: 1, system: 101)) == .off
            }
            #expect(system(101, in: await rig.favorites())?.isOn == false, "\(rig.label)")
            #expect(sets(Array(await rig.commands().dropFirst(mark))).count == 1, "never resent (\(rig.label))")
            await shutDown(model)
        }
    }

    @Test func aFailedReReadOfTheShownListShowsNoStateUntilThePoll() async throws {
        try await onBothMocks(commandTimeout: .milliseconds(300)) { rig in
            // List 1 is shown and polled every 1.5 s; the click comes just after a poll's SQK,7, so the faults meet
            // only the set and its re-read.
            let model = makeModel(rig, pollInterval: .milliseconds(1500))
            model.open()
            model.showList(1)
            try await waitAllFresh(model, rig.label)
            let before = await count("SQK,7", in: rig.commands())
            try await waitUntil("a poll of SQK,7 (\(rig.label))") { await count("SQK,7", in: rig.commands()) > before }
            let mark = await rig.commands().count
            await rig.setFaults(MockFaults(dropNextReply: "SQK", dropCount: 2))
            await model.toggle(.system(list: 1, system: 101))
            #expect(model.switchState(for: .system(list: 1, system: 101)) == .unknown, "\(rig.label)")
            #expect(model.switchState(for: .system(list: 1, system: 102)) == .unknown, "the whole scope (\(rig.label))")
            #expect(model.lastError == "The scanner didn't confirm the change", "\(rig.label)")
            await model.toggle(.system(list: 1, system: 102))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).count == 1, "\(rig.label)")
            // The next poll reads the scope and shows what the scanner holds.
            try await waitUntil("the next poll (\(rig.label))") {
                model.switchState(for: .system(list: 1, system: 101)) == .off
            }
            #expect(model.switchState(for: .system(list: 1, system: 102)) == .on, "\(rig.label)")
            #expect(sets(Array(await rig.commands().dropFirst(mark))).count == 1, "never resent (\(rig.label))")
            await shutDown(model)
        }
    }

    @Test func aMenuPushJustBeforeTheSetStopsIt() async throws {
        try await onBothMocks { rig in
            // The model asks for the client right before each command. Armed, that request first delivers a push
            // saying the scanner entered a menu: the click is checked again with the client in hand.
            let pushMenu = Mutex(false)
            let model = QuickKeysModel(cacheURL: rig.cacheURL, pollInterval: .seconds(30))
            let client = rig.client
            let menu = try inMenu()
            model.attach(control: { [weak model] in
                if pushMenu.withLock({ armed in defer { armed = false }; return armed }) {
                    await MainActor.run { model?.statusArrived(menu) }
                }
                return client
            })
            model.open()
            try await waitAllFresh(model, rig.label)
            let mark = await rig.commands().count
            pushMenu.withLock { $0 = true }
            await model.toggle(.list(4))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(model.switchState(for: .list(4)) == .inMenu, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aRejectedSetIsReported() async throws {
        try await onBothMocks { rig in
            // No poll within the test: the fault can only meet the set.
            let model = makeModel(rig, pollInterval: .seconds(30))
            model.open()
            try await waitAllFresh(model, rig.label)
            let mark = await rig.commands().count
            await rig.setFaults(MockFaults(rejectNext: "FQK"))
            await model.toggle(.list(4))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(command(after: "FQK,", in: after) == "FQK", "the re-read (\(rig.label)): \(after)")
            #expect(model.lastError == "The scanner didn't confirm the change", "\(rig.label)")
            #expect(model.switchState(for: .list(4)) == .off, "\(rig.label)")
            #expect(await rig.favorites().lists.first { $0.index == 4 }?.isOn == false, "\(rig.label)")
            // The next accepted click clears it.
            await model.toggle(.list(4))
            #expect(model.lastError == nil, "\(rig.label)")
            #expect(model.switchState(for: .list(4)) == .on, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aStrayReplyIsDropped() async throws {
        // A poll's DQK,7,0 (system 101: keys {0, 1}) is answered late, after its read gave up; it reaches the
        // confirming re-read of a set under system 102 (DQK,7,1: keys {0, 1, 2}). Its pattern differs, so it is
        // dropped and the scope read again. If it were taken, 400 (D0) would show on and 402 (D2) unreported.
        try await onBothMocks(commandTimeout: .milliseconds(300), stray: true) { rig in
            let stray = try #require(rig.stray)
            let model = makeModel(rig)
            model.open()
            model.showList(1)
            try await waitAllFresh(model, rig.label)
            try await waitUntil("a poll of DQK,7,1 (\(rig.label))") { await count("DQK,7,1", in: rig.commands()) >= 2 }
            #expect(model.switchState(for: .child(list: 1, system: 102, child: 400)) == .on, "\(rig.label)")
            stray.arm(holdReplyTo: "DQK,7,0") { sent, next in
                next == "DQK,7,1" && sent.contains { $0.hasPrefix("DQK,7,1,") }
            }
            try await waitUntil("the poll's late DQK,7,0 (\(rig.label))") { stray.hasHeld }
            let mark = await rig.commands().count
            await model.toggle(.child(list: 1, system: 102, child: 400))
            #expect(stray.released, "\(rig.label)")
            let after = Array(await rig.commands().dropFirst(mark))
            let set = try #require(after.firstIndex { $0.hasPrefix("DQK,7,1,") }, "\(rig.label): \(after)")
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(namesOnlyKey(setValues(after[set]), 0, "1"), "\(rig.label)")
            // The late reply answered the first re-read; the model read again.
            #expect(Array(after.dropFirst(set + 1).prefix(2)) == ["DQK,7,1", "DQK,7,1"], "\(rig.label): \(after)")
            #expect(model.lastError == nil, "the set itself was confirmed (\(rig.label))")
            #expect(model.switchState(for: .child(list: 1, system: 102, child: 400)) == .off, "\(rig.label)")
            #expect(model.switchState(for: .child(list: 1, system: 102, child: 401)) == .off, "\(rig.label)")
            #expect(model.switchState(for: .child(list: 1, system: 102, child: 402)) == .off, "\(rig.label)")
            #expect(child(400, in: await rig.favorites())?.isOn == false, "\(rig.label)")
            #expect(model.trees[1]?.freshness == .fresh, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aStrayReplyToTheSetIsAnUnconfirmedChange() async throws {
        // The same late DQK,7,0 reply answers the set itself: its outcome is unknown, so it is reported, never
        // resent, and the re-read decides what shows.
        try await onBothMocks(commandTimeout: .milliseconds(300), stray: true) { rig in
            let stray = try #require(rig.stray)
            let model = makeModel(rig)
            model.open()
            model.showList(1)
            try await waitAllFresh(model, rig.label)
            try await waitUntil("a poll of DQK,7,1 (\(rig.label))") { await count("DQK,7,1", in: rig.commands()) >= 2 }
            stray.arm(holdReplyTo: "DQK,7,0") { _, next in next.hasPrefix("DQK,7,1,") }
            try await waitUntil("the poll's late DQK,7,0 (\(rig.label))") { stray.hasHeld }
            let mark = await rig.commands().count
            await model.toggle(.child(list: 1, system: 102, child: 400))
            #expect(stray.released, "\(rig.label)")
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(model.lastError == "The scanner didn't confirm the change", "\(rig.label)")
            #expect(model.switchState(for: .child(list: 1, system: 102, child: 400)) == .off, "\(rig.label)")
            #expect(model.switchState(for: .child(list: 1, system: 102, child: 402)) == .off, "\(rig.label)")
            #expect(child(400, in: await rig.favorites())?.isOn == false, "\(rig.label)")
            // Later polls never send it again.
            try await waitUntil("a later poll (\(rig.label))") {
                await count("DQK,7,1", in: Array(rig.commands().dropFirst(mark))) >= 3
            }
            #expect(sets(Array(await rig.commands().dropFirst(mark))).count == 1, "\(rig.label)")
            await shutDown(model)
        }
    }

    // MARK: Late replies (final review C1)

    @Test func aLateStructureReplyNeverLandsOnAnotherSystem() async throws {
        // List 30 (F5): conventional systems 900 (S0: Mock Alpha D0, Mock Bravo D1) and 901 (S1: Mock Charlie D0,
        // Mock Delta D1). The reply to `GLT,DEPT,900` comes after its read gave up, just before the next `GLT` of
        // another scope is written. The first build's retry in place met it with `GLT,DEPT,901`: system 901 showed
        // 900's departments, fresh, and a click on Mock Alpha under it turned Mock Charlie off. The retry in place is
        // back (its own scope's answer), and the late reply still lands on `GLT,DEPT,901`, but its departments are
        // 900's, read by that same read, so it is refused: the list fails and is read again from `GLT,SYS` after a
        // rest (`QuickKeysModelOwnershipTests` has the cases the retry alone wouldn't cover).
        try await onBothMocks(commandTimeout: .milliseconds(300), stray: true) { rig in
            let stray = try #require(rig.stray)
            await rig.setFavorites(twoConventionalSystems())
            stray.arm(holdReplyTo: "GLT,DEPT,900") { _, next in next.hasPrefix("GLT,") && next != "GLT,DEPT,900" }
            let model = makeModel(rig)
            model.open()
            model.showList(30)
            try await waitUntil("the late reply, then list 30 read (\(rig.label))") {
                stray.released && model.trees[30]?.freshness == .fresh
            }
            let commands = await rig.commands()
            // The read that timed out is retried in place; the next system's read takes the late reply and is
            // refused, so the list starts again.
            let held = try #require(commands.firstIndex(of: "GLT,DEPT,900"), "\(rig.label): \(commands)")
            #expect(Array(commands[(held + 1)...].filter { $0.hasPrefix("GLT,") }.prefix(3))
                        == ["GLT,DEPT,900", "GLT,DEPT,901", "GLT,SYS,30"], "\(rig.label): \(commands)")
            let tree = try #require(model.trees[30])
            #expect(tree.systems.map(\.index) == [900, 901], "\(rig.label)")
            #expect(system(900, in: tree)?.children.map(\.index) == [700, 701], "\(rig.label)")
            #expect(system(901, in: tree)?.children.map(\.index) == [710, 711], "\(rig.label)")
            // A click on Mock Charlie switches Mock Charlie, and nothing else.
            #expect(model.switchState(for: .child(list: 30, system: 901, child: 710)) == .on, "\(rig.label)")
            let mark = await rig.commands().count
            await model.toggle(.child(list: 30, system: 901, child: 710))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(sets(after).first?.hasPrefix("DQK,5,1,") == true, "\(rig.label): \(after)")
            #expect(namesOnlyKey(sets(after).first.flatMap(setValues), 0, "1"), "\(rig.label)")
            let favorites = await rig.favorites()
            #expect(child(710, in: favorites)?.isOn == false, "\(rig.label)")
            #expect(child(700, in: favorites)?.isOn == true, "\(rig.label)")
            #expect(model.switchState(for: .child(list: 30, system: 901, child: 710)) == .off, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aLateSystemsReplyNeverBecomesAnotherListsSystems() async throws {
        // The reply to list 1's `GLT,SYS,1` comes after its read gave up, and is delivered just before the next GLT
        // of another scope. The read is retried in place (`GLT,SYS,1` again: no release, the same answer), so that GLT
        // is its `GLT,DEPT,101`, which refuses a `SYS` document: the list fails, and during the rest that follows the
        // user opens list 4, which jumps the queue. Were list 4 read next, nothing would be late any more; a list whose
        // read failed is still read again before any other. (`QuickKeysModelOwnershipTests.
        // aLateSystemsReplyIsRefusedOnAnotherList` has the late reply landing on `GLT,SYS,4` itself.)
        try await onBothMocks(commandTimeout: .milliseconds(300), stray: true) { rig in
            let stray = try #require(rig.stray)
            stray.arm(holdReplyTo: "GLT,SYS,1") { _, next in next.hasPrefix("GLT,") && next != "GLT,SYS,1" }
            // A rest long enough to open list 4 in it.
            let model = makeModel(rig, pollInterval: .seconds(1))
            model.open()
            model.showList(1)
            // A list's read error is on its tree (the status line is for the keypad, the polls and changes).
            try await waitUntil("GLT,DEPT,101 refused the late reply (\(rig.label))") {
                model.trees[1]?.readError == "The scanner's reply to GLT,DEPT couldn't be read."
            }
            #expect(await !rig.commands().contains("GLT,SYS,4"), "\(rig.label)")
            model.showList(4)
            try await waitAllFresh(model, rig.label)
            #expect(stray.released, "\(rig.label)")
            let commands = await rig.commands()
            let held = try #require(commands.firstIndex(of: "GLT,SYS,1"), "\(rig.label): \(commands)")
            #expect(commands[(held + 1)...].first { $0.hasPrefix("GLT,") } == "GLT,SYS,1", "\(rig.label): \(commands)")
            #expect(model.trees[1]?.systems.map(\.index) == [101, 102], "\(rig.label)")
            #expect(model.trees[4]?.systems.map(\.index) == [120, 121, 122], "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func theRestHoldsThePolls() async throws {
        // After a failed read nothing is read for a poll interval, not even a poll that is due, so a late reply
        // finds no read of its name. Here a click's set and confirming re-read both go unanswered (2 × 600 ms), so the
        // next poll (every 1 s) is already due when the click returns; it waits for the rest instead.
        try await onBothMocks { rig in
            let model = makeModel(rig, pollInterval: .seconds(1))
            model.open()
            try await waitAllFresh(model, rig.label)
            let before = await count("FQK", in: rig.commands())
            try await waitUntil("a poll (\(rig.label))") { await count("FQK", in: rig.commands()) > before }
            await rig.setFaults(MockFaults(dropNextReply: "FQK", dropCount: 2))
            await model.toggle(.list(4))
            #expect(model.lastError == "The scanner didn't confirm the change", "\(rig.label)")
            let mark = await rig.commands().count
            try await Task.sleep(for: .milliseconds(600))
            #expect(Array(await rig.commands().dropFirst(mark)).isEmpty, "\(rig.label)")
            try await waitUntil("the poll after the rest (\(rig.label))") { model.switchState(for: .list(4)) == .on }
            await shutDown(model)
        }
    }

    @Test func theQuietTimeOutlastsAReopen() async throws {
        // A late reply can come whatever run is going: after a timeout, a close and reopen doesn't read the keypad
        // until the quiet time (a poll interval, 3 s here) is over.
        try await onBothMocks(commandTimeout: .milliseconds(300)) { rig in
            let model = makeModel(rig, pollInterval: .seconds(3))
            model.open()
            try await waitAllFresh(model, rig.label)
            await rig.setFaults(MockFaults(dropNextRequest: "FQK"))
            try await waitUntil("a poll's FQK timed out (\(rig.label))", .seconds(8)) {
                model.lastError == "The scanner didn't answer FQK."
            }
            model.close()
            model.open()
            let mark = await rig.commands().count
            try await Task.sleep(for: .milliseconds(1500))
            #expect(Array(await rig.commands().dropFirst(mark)).isEmpty, "\(rig.label)")
            try await waitUntil("the keypad after the quiet time (\(rig.label))", .seconds(5)) {
                model.switchState(for: .list(4)) == .off
            }
            #expect(Array(await rig.commands().dropFirst(mark)).prefix(2) == ["GLT,FL", "FQK"], "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func busyRefusesASecondClick() async throws {
        try await onBothMocks { rig in
            // The set's reply is lost, so the action lasts a command timeout; no poll meets the fault.
            let model = makeModel(rig, pollInterval: .seconds(30))
            model.open()
            try await waitAllFresh(model, rig.label)
            let mark = await rig.commands().count
            await rig.setFaults(MockFaults(dropNextReply: "FQK"))
            let first = Task { await model.toggle(.list(4)) }
            try await waitUntil("the action (\(rig.label))") { model.switchState(for: .list(4)) == .busy }
            // While the action runs, every row of its scope (the keypad) is busy, and a click there is refused.
            #expect(model.switchState(for: .list(0)) == .busy, "\(rig.label)")
            #expect(model.switchState(for: .list(10)) == .noQuickKey, "\(rig.label)")
            #expect(model.switchState(for: .system(list: 1, system: 101)) == .on, "another scope (\(rig.label))")
            await model.toggle(.list(4))
            await model.toggle(.list(0))
            await first.value
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(model.switchState(for: .list(4)) == .on, "\(rig.label)")
            #expect(model.switchState(for: .list(0)) == .on, "\(rig.label)")
            await shutDown(model)
        }
    }

    /// The click must come while the poll's lost `SQK` still holds it. With 300 ms timeouts a loaded
    /// machine's click came after that poll had ended, during the next one (local sweep, bgload);
    /// two-second timeouts hold the poll that long.
    @Test func aClickWaitsForThePollUnderWay() async throws {
        try await onBothMocks(commandTimeout: .seconds(2)) { rig in
            let model = makeModel(rig, pollInterval: .seconds(1))
            model.open()
            model.showList(1)
            try await waitAllFresh(model, rig.label)
            try await waitForAPollToEnd(rig, last: "DQK,7,1")
            let mark = await rig.commands().count
            // The next poll's SQK,7 goes unanswered, so the poll is under way for a command timeout.
            await rig.setFaults(MockFaults(dropNextRequest: "SQK"))
            try await waitUntil("the poll's lost SQK,7 (\(rig.label))") {
                await rig.commands().dropFirst(mark).contains("SQK,7")
            }
            await model.toggle(.list(4))
            let after = Array(await rig.commands().dropFirst(mark))
            let lost = try #require(after.firstIndex(of: "SQK,7"), "\(rig.label): \(after)")
            let set = try #require(after.firstIndex { $0.hasPrefix("FQK,") }, "\(rig.label): \(after)")
            // The set waits for the poll's step: its lost SQK,7 ends the poll (a state read is never retried in place,
            // final review C1), and the set comes after, never between a poll's reads.
            #expect(set == lost + 1, "\(rig.label): \(after)")
            #expect(command(after: "FQK,", in: after) == "FQK", "\(rig.label): \(after)")
            #expect(model.switchState(for: .list(4)) == .on, "\(rig.label)")
            await shutDown(model)
        }
    }

    /// The click waits behind a poll held up by two unanswered `FQK`s; the close must come while it
    /// is still queued, which is all this pins: a click still queued at the close sends nothing. (One
    /// already past `perform`'s last check, waiting for the client's request slot, can still send its
    /// set after the close; that gap is the product's, open in its own pull request.) With 300 ms
    /// timeouts the window was 600 ms, which a slow runner overran: the poll had ended, the click had
    /// sent its set while the pop-over was open, and only then did the close come (flake hunt on
    /// hunt/flaky-1). Two-second timeouts keep the click queued for about four seconds.
    @Test func aClickStillWaitingWhenThePopoverClosesSendsNothing() async throws {
        try await onBothMocks(commandTimeout: .seconds(2)) { rig in
            let model = makeModel(rig, pollInterval: .seconds(1))
            model.open()
            try await waitAllFresh(model, rig.label)
            try await waitForAPollToEnd(rig, last: "FQK")
            let mark = await rig.commands().count
            // The next poll's FQK goes unanswered twice: the poll is under way for two command timeouts.
            await rig.setFaults(MockFaults(dropNextRequest: "FQK", dropCount: 2))
            try await waitUntil("the poll's lost FQK (\(rig.label))") {
                await rig.commands().dropFirst(mark).contains("FQK")
            }
            let click = Task { await model.toggle(.list(4)) }
            try await waitUntil("the click waiting (\(rig.label))") { model.switchState(for: .list(4)) == .busy }
            model.close()
            await click.value
            await model.quiesce()
            try await Task.sleep(for: .milliseconds(450))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(await rig.favorites().lists.first { $0.index == 4 }?.isOn == false, "\(rig.label)")
            // Opened again, the tile works.
            model.open()
            try await waitUntil("the keypad (\(rig.label))") { model.switchState(for: .list(4)) == .off }
            await shutDown(model)
        }
    }

    /// As above: two-second timeouts keep the click queued while the menu arrives, so this pins that a
    /// click still queued when the scanner enters a menu sends nothing. A click already past its last
    /// check can still send after the menu (QA's I2; its own pull request), which this doesn't reach.
    @Test func aClickWaitingWhenTheScannerEntersAMenuSendsNothing() async throws {
        try await onBothMocks(commandTimeout: .seconds(2)) { rig in
            let model = makeModel(rig, pollInterval: .seconds(1))
            model.open()
            try await waitAllFresh(model, rig.label)
            try await waitForAPollToEnd(rig, last: "FQK")
            let mark = await rig.commands().count
            await rig.setFaults(MockFaults(dropNextRequest: "FQK", dropCount: 2))
            try await waitUntil("the poll's lost FQK (\(rig.label))") {
                await rig.commands().dropFirst(mark).contains("FQK")
            }
            let click = Task { await model.toggle(.list(4)) }
            try await waitUntil("the click waiting (\(rig.label))") { model.switchState(for: .list(4)) == .busy }
            // When its turn comes the row is checked again: in a menu, nothing is sent.
            let beforeMenu = sets(Array(await rig.commands().dropFirst(mark))).count
            model.statusArrived(try inMenu())
            await click.value
            // Which side of the menu a set fell on tells a broken premise (the click had already
            // sent while it looked busy) from a set sent after the menu came (a click past its last
            // check, waiting for the request slot: the product gap its own pull request closes).
            let all = sets(Array(await rig.commands().dropFirst(mark))).count
            #expect(all == 0, "\(rig.label): \(beforeMenu) set(s) before the menu came, \(all - beforeMenu) after it")
            #expect(model.switchState(for: .list(4)) == .inMenu, "\(rig.label)")
            await shutDown(model)
        }
    }

    // MARK: Decided at the slot (flaky-sweep review I2)

    @Test func aClickHeldAtTheSlotSendsItsSetOnce() async throws {
        try await onBothMocks(commandTimeout: .seconds(10)) { rig in
            try await clickHeldAtTheSlot(rig, .list(4), whileWaiting: { _ in }) { model, after in
                #expect(sets(after).count == 1, "\(rig.label): \(after)")
                #expect(namesOnlyKey(sets(after).first.flatMap(setValues), 1, "2"), "\(rig.label): \(after)")
                #expect(command(after: "FQK,", in: after) == "FQK", "\(rig.label): \(after)")
                #expect(model.switchState(for: .list(4)) == .on, "\(rig.label)")
                #expect(await rig.favorites().lists.first { $0.index == 4 }?.isOn == true, "\(rig.label)")
                #expect(model.lastError == nil, "\(rig.label)")
            }
        }
    }

    @Test func aClickHeldAtTheSlotWhenThePopoverClosesSendsNothing() async throws {
        try await onBothMocks(commandTimeout: .seconds(10)) { rig in
            try await clickHeldAtTheSlot(rig, .list(4), whileWaiting: { $0.close() }) { _, after in
                #expect(sets(after).isEmpty, "\(rig.label): \(after)")
                #expect(await rig.favorites().lists.first { $0.index == 4 }?.isOn == false, "\(rig.label)")
            }
        }
    }

    @Test func aClickHeldAtTheSlotWhenTheScannerEntersAMenuSendsNothing() async throws {
        try await onBothMocks(commandTimeout: .seconds(10)) { rig in
            try await clickHeldAtTheSlot(rig, .list(4), whileWaiting: { $0.statusArrived(try inMenu()) }) { model, after in
                #expect(sets(after).isEmpty, "\(rig.label): \(after)")
                #expect(await rig.favorites().lists.first { $0.index == 4 }?.isOn == false, "\(rig.label)")
                #expect(model.switchState(for: .list(4)) == .inMenu, "\(rig.label)")
                // Nothing was sent, so nothing is unconfirmed.
                #expect(model.lastError == nil, "\(rig.label)")
            }
        }
    }

    @Test func aClickHeldAtTheSlotWhenTheSessionDetachesSendsNothing() async throws {
        try await onBothMocks(commandTimeout: .seconds(10)) { rig in
            try await clickHeldAtTheSlot(rig, .list(4), whileWaiting: { $0.detach() }) { _, after in
                #expect(sets(after).isEmpty, "\(rig.label): \(after)")
                #expect(await rig.favorites().lists.first { $0.index == 4 }?.isOn == false, "\(rig.label)")
            }
        }
    }

    @Test func aSystemClickHeldAtTheSlotWhenThePopoverClosesSendsNothing() async throws {
        try await onBothMocks(commandTimeout: .seconds(10)) { rig in
            // The pre-set check's five reads come first and pass; the control call just before the set holds the slot.
            try await clickHeldAtTheSlot(rig, .system(list: 1, system: 102), checkReads: 5,
                                         whileWaiting: { $0.close() }) { _, after in
                #expect(Array(after.prefix(6)) == ["GLT,FL", "GLT,SYS,1", "GLT,FL", "GLT,SYS,1", "GLT,FL", "GSI"],
                        "the check passed, then the slot was held (\(rig.label)): \(after)")
                #expect(sets(after).isEmpty, "\(rig.label): \(after)")
                #expect(system(102, in: await rig.favorites())?.isOn == true, "\(rig.label)")
            }
        }
    }

    // MARK: Shared numbers and what can't be switched

    @Test func sharedKeysSwitchTogether() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            // 200, 203 (departments) and 301 (a site) of system 101 all hold D0.
            #expect(model.sharing(for: .child(list: 1, system: 101, child: 200)) == 3, "\(rig.label)")
            #expect(model.sharing(for: .child(list: 1, system: 101, child: 301)) == 3, "\(rig.label)")
            #expect(model.sharing(for: .child(list: 1, system: 101, child: 201)) == 1, "\(rig.label)")
            #expect(model.sharing(for: .child(list: 1, system: 101, child: 118)) == 1, "no key (\(rig.label))")
            #expect(model.sharing(for: .system(list: 0, system: 110)) == 2, "\(rig.label)")
            #expect(model.sharing(for: .list(4)) == 1, "\(rig.label)")
            let mark = await rig.commands().count
            await model.toggle(.child(list: 1, system: 101, child: 200))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).count == 1, "\(rig.label)")
            for index: UInt32 in [200, 203, 301] {
                #expect(model.switchState(for: .child(list: 1, system: 101, child: index)) == .off,
                        "\(index) (\(rig.label))")
            }
            #expect(model.switchState(for: .child(list: 1, system: 101, child: 201)) == .on, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func whatCantBeSwitched() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            #expect(model.switchState(for: .list(10)) == .noQuickKey, "\(rig.label)")
            #expect(model.switchState(for: .system(list: 10, system: 150)) == .noQuickKey, "a list without a key (\(rig.label))")
            #expect(model.switchState(for: .child(list: 0, system: 112, child: 520)) == .noQuickKey, "\(rig.label)")
            #expect(model.switchState(for: .child(list: 1, system: 101, child: 118)) == .noQuickKey, "\(rig.label)")
            #expect(model.switchState(for: .child(list: 4, system: 122, child: 540)) == .unreported, "\(rig.label)")
            #expect(model.switchState(for: .child(list: 0, system: 110, child: 500)) == .sharedSystemKey(0), "\(rig.label)")
            #expect(model.switchState(for: .child(list: 0, system: 111, child: 510)) == .sharedSystemKey(0), "\(rig.label)")
            // The systems sharing S0 are one switch; it still works.
            #expect(model.switchState(for: .system(list: 0, system: 110)) == .on, "\(rig.label)")
            #expect(model.switchState(for: .child(list: 1, system: 999, child: 1)) == .unknown, "\(rig.label)")
            let mark = await rig.commands().count
            for row: QuickKeyRow in [.list(10), .system(list: 10, system: 150), .child(list: 0, system: 112, child: 520),
                                     .child(list: 4, system: 122, child: 540), .child(list: 0, system: 110, child: 500),
                                     .child(list: 1, system: 999, child: 1)] {
                await model.toggle(row)
            }
            // The open pop-over's polls go on meanwhile (every `pollInterval`); only they may have been sent.
            #expect(Array(await rig.commands().dropFirst(mark)).filter { !isPollRead($0) } == [],
                    "nothing sent but the polls (\(rig.label))")
            // A list that isn't monitored keeps a working tile.
            #expect(model.lists.first { $0.index == 8 }?.monitored == false, "\(rig.label)")
            #expect(model.switchState(for: .list(8)) == .off, "\(rig.label)")
            await model.toggle(.list(8))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).count == 1, "\(rig.label)")
            #expect(model.switchState(for: .list(8)) == .on, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func listsSharingAKeyDontSwitchTheirSystems() async throws {
        // Lists 40 and 41 both hold F5. `SQK,5` and `DQK,5,<s>` can't tell them apart (final review I1): a click on
        // list 41's system switched list 40's. Their systems, departments and sites don't switch; their tiles do,
        // together, since `FQK` addresses the key.
        try await onBothMocks { rig in
            await rig.setFavorites(twoListsOnOneKey())
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            let rows: [QuickKeyRow] = [.system(list: 40, system: 800), .system(list: 41, system: 801),
                                       .child(list: 40, system: 800, child: 750),
                                       .child(list: 41, system: 801, child: 760)]
            for row in rows {
                #expect(model.switchState(for: row) == .sharedListKey(5), "\(row) (\(rig.label))")
            }
            // Their states are still shown.
            #expect(model.trees[41]?.systems.first?.state == .on, "\(rig.label)")
            let mark = await rig.commands().count
            for row in rows { await model.toggle(row) }
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            #expect(system(800, in: await rig.favorites())?.isOn == true, "\(rig.label)")
            #expect(system(801, in: await rig.favorites())?.isOn == true, "\(rig.label)")
            // The tiles are one switch on the scanner, and still work.
            #expect(model.sharing(for: .list(41)) == 2, "\(rig.label)")
            #expect(model.switchState(for: .list(41)) == .on, "\(rig.label)")
            await model.toggle(.list(41))
            let after = Array(await rig.commands().dropFirst(mark))
            #expect(sets(after).count == 1, "\(rig.label): \(after)")
            #expect(namesOnlyKey(sets(after).first.flatMap(setValues), 5, "1"), "\(rig.label): \(after)")
            #expect(model.switchState(for: .list(40)) == .off, "\(rig.label)")
            #expect(model.switchState(for: .list(41)) == .off, "\(rig.label)")
            await shutDown(model)
        }
    }

    // MARK: When not to switch

    @Test func inAMenuNothingSwitches() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            model.statusArrived(try inMenu())
            #expect(model.isInMenu, "\(rig.label)")
            let rows = everyRow(model)
            #expect(rows.count > 20, "\(rig.label)")
            for row in rows {
                #expect(model.switchState(for: row) == .inMenu, "\(row) (\(rig.label))")
            }
            let mark = await rig.commands().count
            await model.toggle(.list(4))
            await model.toggle(.system(list: 1, system: 101))
            await model.toggle(.child(list: 1, system: 101, child: 200))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            // Leaving the menu re-checks everything first; then it switches again.
            model.statusArrived(try scanning())
            #expect(!model.isInMenu, "\(rig.label)")
            #expect(model.switchState(for: .system(list: 1, system: 101)) == .checking, "\(rig.label)")
            // The keypad is read again too (a menu can move a list's key): no tile switches until then.
            #expect(model.switchState(for: .list(4)) == .checking, "\(rig.label)")
            await model.toggle(.list(4))
            #expect(sets(Array(await rig.commands().dropFirst(mark))).isEmpty, "\(rig.label)")
            try await waitAllFresh(model, rig.label)
            try await waitUntil("the keypad re-read (\(rig.label))") { model.switchState(for: .list(4)) == .off }
            await shutDown(model)
        }
    }

    @Test func afterDetachNothingSwitches() async throws {
        try await onBothMocks { rig in
            let model = makeModel(rig)
            model.open()
            try await waitAllFresh(model, rig.label)
            let lists = model.lists.map(\.index)
            model.detach()
            await model.quiesce()
            // This session's last lists and trees stay, read-only, with no on/off.
            #expect(model.lists.map(\.index) == lists, "\(rig.label)")
            #expect(model.lists.allSatisfy { $0.state == nil }, "\(rig.label)")
            #expect(Set(model.trees.keys) == Set(lists), "\(rig.label)")
            #expect(model.trees.values.allSatisfy { $0.freshness == .checking }, "\(rig.label)")
            let rows = everyRow(model)
            #expect(rows.count > 20, "\(rig.label)")
            for row in rows {
                #expect(model.switchState(for: row) == .unavailable, "\(row) (\(rig.label))")
            }
            let mark = await rig.commands().count
            await model.toggle(.list(4))
            await model.toggle(.system(list: 1, system: 101))
            await model.toggle(.child(list: 1, system: 101, child: 200))
            // Reopened while detached: still the last lists and trees, still read-only.
            model.close()
            model.open()
            #expect(model.lists.map(\.index) == lists, "\(rig.label)")
            #expect(Set(model.trees.keys) == Set(lists), "\(rig.label)")
            #expect(model.switchState(for: .list(4)) == .unavailable, "\(rig.label)")
            await model.toggle(.list(4))
            try await Task.sleep(for: .milliseconds(450))
            #expect(await rig.commands().count == mark, "nothing sent while detached (\(rig.label))")
            // Attached again: a fresh keypad replaces them, and the rows switch again.
            let client = rig.client
            model.attach(control: { client })
            try await waitUntil("the keypad (\(rig.label))") { model.switchState(for: .list(4)) == .off }
            #expect(count("GLT,FL", in: Array(await rig.commands().dropFirst(mark))) == 1, "\(rig.label)")
            try await waitAllFresh(model, rig.label)
            #expect(model.switchState(for: .system(list: 1, system: 101)) == .on, "\(rig.label)")
            await shutDown(model)
        }
    }
}
