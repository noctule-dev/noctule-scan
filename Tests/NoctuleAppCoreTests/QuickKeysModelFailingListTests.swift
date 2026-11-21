// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleMockScanner
@testable import NoctuleAppCore

// QuickKeysModel with a list whose read fails every time (design `docs/specs/2026-11-18-quick-keys-design.md`
// §10, "A list that keeps failing"): on the owner's SDS150 one list's `GLT` was refused on every read, its error
// showed for under one poll interval, and the list was read again before any other, for ever, so no list after
// it ever loaded, the one the user opened included. Against MockSDS200 over UDP and MockSerialScanner (SDS150)
// over serial, each on a stepped clock with `quickKeySetDelay: .zero`, behind a `RefusingTransport`. Every name
// is fictional (`MockFavorites.default`).

private struct QKFailRig {
    let label: String
    let client: ScannerClient
    let cacheURL: URL
    let refusing: RefusingTransport
    let commands: @Sendable () async -> [String]
}

/// A transport that, for each command whose exact text it was given (e.g. `GLT,SYS,4`), hands on something else in
/// place of the scanner's reply: `<NAME>,NG` (`refuse`, as a scanner that refuses one list's read every time), a
/// reply the client can't use (`garble`: `<NAME>,X`), or nothing at all (`swallow`: the read times out). The
/// command still reaches the mock (so its log shows it); only its reply is replaced.
final class RefusingTransport: ScannerTransport, Sendable {
    enum Answer: Sendable {
        case refused, garbled, swallowed
    }

    private struct State {
        var answers: [String: Answer] = [:]
        /// The command name whose next reply is replaced, and with what.
        var replacing: (name: String, answer: Answer)?
    }

    private let base: any ScannerTransport
    private let state = Mutex(State())

    init(_ base: any ScannerTransport) { self.base = base }

    /// The commands (exact text) refused from now on, in place of any given before; an empty set refuses nothing.
    func refuse(_ commands: Set<String>) { answer(commands, .refused) }

    /// The commands (exact text) whose replies are garbled from now on, in place of any given before.
    func garble(_ commands: Set<String>) { answer(commands, .garbled) }

    /// The commands (exact text) whose replies are dropped from now on, in place of any given before.
    func swallow(_ commands: Set<String>) { answer(commands, .swallowed) }

    private func answer(_ commands: Set<String>, _ answer: Answer) {
        state.withLock { $0.answers = Dictionary(uniqueKeysWithValues: commands.map { ($0, answer) }) }
    }

    func open() async throws { try await base.open() }
    func close() async { await base.close() }

    func send(_ command: ScannerCommand) async throws {
        let text = ([command.name] + command.arguments).joined(separator: ",")
        state.withLock { state in
            // Set before the write: the reply can come back before `send` returns.
            if let answer = state.answers[text] { state.replacing = (command.name, answer) }
        }
        try await base.send(command)
    }

    var responses: AsyncStream<ScannerResponse> {
        let upstream = base.responses
        return AsyncStream { continuation in
            let relay = Task { [self] in
                for await response in upstream {
                    let answer = state.withLock { state -> Answer? in
                        guard let replacing = state.replacing, replacing.name == response.command else { return nil }
                        state.replacing = nil
                        return replacing.answer
                    }
                    switch answer {
                    case nil: continuation.yield(response)
                    case .refused: continuation.yield(.fields(command: response.command, fields: ["NG"]))
                    case .garbled: continuation.yield(.fields(command: response.command, fields: ["X"]))
                    case .swallowed: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}

/// Runs `body` against the network SDS200 mock, then the serial SDS150 mock, each behind a `RefusingTransport`
/// that refuses `refused` and with its own temporary cache directory (`cache`, when given, is written there
/// first); stops the client and the mock on every path.
@MainActor
private func onBothMocks(refusing refused: Set<String>, cache: [UInt32: QuickKeyListTree]? = nil,
                         _ body: @MainActor (QKFailRig) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("qk-fail-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func cacheURL(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent("\(name)/quick-keys.json")
        if let cache { try QuickKeysCache.save(cache, to: url) }
        return url
    }
    do {
        let options = MockSDS200.Options(clock: .stepped(at: 3), quickKeySetDelay: .zero)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        let refusing = RefusingTransport(UDPTransport(host: "127.0.0.1", port: ports.udpPort))
        refusing.refuse(refused)
        let client = ScannerClient(transport: refusing, commandTimeout: .milliseconds(600))
        var failure: (any Error)?
        do {
            try await client.connect()
            let rig = QKFailRig(label: "SDS200 over UDP", client: client, cacheURL: try cacheURL("sds200"),
                                refusing: refusing, commands: { await mock.control.receivedCommands })
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
            let refusing = RefusingTransport(SerialTransport(path: path))
            refusing.refuse(refused)
            let connected = ScannerClient(transport: refusing, commandTimeout: .milliseconds(600))
            client = connected
            try await connected.connect()
            let rig = QKFailRig(label: "SDS150 over serial", client: connected, cacheURL: try cacheURL("sds150"),
                                refusing: refusing, commands: { await mock.receivedCommands })
            try await body(rig)
        } catch { failure = error }
        await client?.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
}

@MainActor
private func makeModel(_ rig: QKFailRig, pollInterval: Duration = .milliseconds(150)) -> QuickKeysModel {
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

/// The list indexes of every `GLT,SYS,<index>` in `commands`, in order.
private func systemReads(_ commands: [String]) -> [UInt32] {
    commands.compactMap { command in
        let parts = command.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GLT", parts[1] == "SYS" else { return nil }
        return UInt32(parts[2])
    }
}

private func count(_ command: String, in commands: [String]) -> Int {
    commands.filter { $0 == command }.count
}

/// A structure-only tree for list 1, as a previous run would have cached it.
private func cachedListOne() -> [UInt32: QuickKeyListTree] {
    let systems: [QuickKeyListTree.SystemRow] = [
        .init(index: 101, name: "Riverbend County P25", type: "P25 Trunk", key: 0, avoided: false, state: nil,
              children: [.init(index: 200, name: "Lakeview Fire", kind: .department, key: 0, avoided: false,
                               state: nil)]),
    ]
    return [1: QuickKeyListTree(systems: systems, freshness: .checking)]
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct QuickKeysModelFailingListTests {
    /// The lists of `MockFavorites.default` other than `failing`, in `GLT` order.
    private static func others(than failing: UInt32) -> [UInt32] {
        [0, 1, 4, 6, 8, 10, 12, 14].filter { $0 != failing }
    }

    @Test func aFailingListKeepsItsErrorAcrossPolls() async throws {
        // List 4 is shown and refused on every read. Its error stays on its tree while the polls (FQK, which
        // succeed) come and go; before, each poll's success cleared it within one interval.
        try await onBothMocks(refusing: ["GLT,SYS,4"]) { rig in
            let model = makeModel(rig)
            model.open()
            model.showList(4)
            try await waitUntil("list 4's error (\(rig.label))") { model.trees[4]?.readError != nil }
            let polls = await count("FQK", in: rig.commands())
            var cleared = false
            try await waitUntil("two more polls (\(rig.label))") {
                if model.trees[4]?.readError == nil { cleared = true }
                return await count("FQK", in: rig.commands()) >= polls + 2
            }
            #expect(!cleared, "a poll cleared the list's error (\(rig.label))")
            let tree = try #require(model.trees[4], "\(rig.label)")
            #expect(tree.freshness != .fresh, "\(rig.label)")
            #expect(tree.readError?.contains("GLT,SYS") == true, "\(rig.label): \(tree.readError ?? "nil")")
            // The status line is for the keypad, the polls and changes: a list's error is on its tree only.
            #expect(model.lastError == nil, "\(rig.label): \(model.lastError ?? "nil")")
            #expect(model.isScannerAnswering, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func openingAListLoadsItWhileAnotherKeepsFailing() async throws {
        // List 0 (key 0) is read first and refused every time. Opening list 14 (key 41, the last keyed list) loads
        // it at once: at most list 0's first retry (or the read under way) comes before it. Then every other list
        // loads too.
        try await onBothMocks(refusing: ["GLT,SYS,0"]) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("list 0 refused (\(rig.label))") { await count("GLT,SYS,0", in: rig.commands()) >= 1 }
            let mark = await rig.commands().count
            model.showList(14)
            try await waitUntil("list 14 read (\(rig.label))", .seconds(3)) { model.trees[14]?.freshness == .fresh }
            let order = systemReads(Array(await rig.commands().dropFirst(mark)))
            let at = try #require(order.firstIndex(of: 14), "\(rig.label): \(order)")
            #expect(order.prefix(at).filter { $0 == 0 }.count <= 2, "\(rig.label): \(order)")
            #expect(order.prefix(at).filter { $0 != 0 }.count <= 1, "\(rig.label): \(order)")
            try await waitUntil("every other list read (\(rig.label))", .seconds(5)) {
                Self.others(than: 0).allSatisfy { model.trees[$0]?.freshness == .fresh }
            }
            #expect(model.trees[0]?.freshness != .fresh, "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func theFirstRetryIsTheFailedListsOwnThenItGoesLast() async throws {
        // Final review C1: the first `GLT` after a failed list's rest is that list's own `GLT,SYS`, so a late reply to
        // it meets the same read. If that retry fails too, the list goes behind every other one (keys 1, 3, 7, 12,
        // 23, 41, then the unkeyed list 10) and is tried again after them, and again after that.
        try await onBothMocks(refusing: ["GLT,SYS,0"]) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("list 0 tried after the others, twice (\(rig.label))", .seconds(5)) {
                await count("GLT,SYS,0", in: rig.commands()) >= 4
            }
            #expect(Self.others(than: 0).allSatisfy { model.trees[$0]?.freshness == .fresh }, "\(rig.label)")
            let order = systemReads(await rig.commands())
            #expect(Array(order.prefix(11)) == [0, 0, 4, 6, 1, 8, 12, 14, 10, 0, 0], "\(rig.label): \(order)")
            await shutDown(model)
        }
    }

    @Test func aFailingListsErrorClearsOnceItReads() async throws {
        // Once the list reads, its error and its count of failures are gone: a menu exit's re-check shows the tree
        // `.checking` with no error, and its next failure gets the first retry again (C1), not the back of the queue.
        try await onBothMocks(refusing: ["GLT,SYS,4"]) { rig in
            let model = makeModel(rig)
            model.open()
            model.showList(4)
            try await waitUntil("list 4 failed twice (\(rig.label))") {
                await count("GLT,SYS,4", in: rig.commands()) >= 2 && model.trees[4]?.readError != nil
            }
            rig.refusing.refuse([])
            try await waitUntil("list 4 read (\(rig.label))", .seconds(5)) { model.trees[4]?.freshness == .fresh }
            #expect(model.trees[4]?.readError == nil, "\(rig.label)")
            #expect(model.trees[4]?.systems.map(\.index) == [120, 121, 122], "\(rig.label)")
            #expect(model.lastError == nil, "\(rig.label)")
            try await waitUntil("every list read (\(rig.label))", .seconds(5)) {
                [0, 1, 4, 6, 8, 10, 12, 14].allSatisfy { model.trees[$0]?.freshness == .fresh }
            }
            rig.refusing.refuse(["GLT,SYS,4"])
            let mark = await rig.commands().count
            model.menuReadChanged(true)
            model.menuReadChanged(false)
            #expect(model.trees[4]?.freshness == .checking, "\(rig.label)")
            #expect(model.trees[4]?.readError == nil, "a read cleared the stored error (\(rig.label))")
            try await waitUntil("the re-read after the menu (\(rig.label))", .seconds(5)) {
                await systemReads(Array(rig.commands().dropFirst(mark))).count >= 3
            }
            // List 4 is shown, so it goes first; its failure count starts again at one, so its retry is next.
            let order = systemReads(Array(await rig.commands().dropFirst(mark)))
            #expect(Array(order.prefix(2)) == [4, 4], "\(rig.label): \(order)")
            await shutDown(model)
        }
    }

    @Test func aListErrorSaysWhatFailedInWords() async throws {
        // The tree's error is a sentence, never a Swift error's description, and never reaches `lastError`. The
        // first poll is 3 s away, so nothing could have cleared a `lastError` set by the list's failure.
        let cases: [(answer: RefusingTransport.Answer, command: String, expected: String)] = [
            (.refused, "GLT,SYS,4", "The scanner refused GLT,SYS."),
            (.garbled, "GLT,DEPT,120", "The scanner's reply to GLT,DEPT couldn't be read."),
            (.swallowed, "GLT,SITE,120", "The scanner didn't answer GLT,SITE."),
        ]
        for item in cases {
            try await onBothMocks(refusing: []) { rig in
                switch item.answer {
                case .refused: rig.refusing.refuse([item.command])
                case .garbled: rig.refusing.garble([item.command])
                case .swallowed: rig.refusing.swallow([item.command])
                }
                let model = makeModel(rig, pollInterval: .seconds(3))
                model.open()
                model.showList(4)
                try await waitUntil("list 4's error (\(rig.label), \(item.command))") {
                    model.trees[4]?.readError != nil
                }
                #expect(model.trees[4]?.readError == item.expected, "\(rig.label)")
                #expect(model.lastError == nil, "\(rig.label): \(model.lastError ?? "nil")")
                await shutDown(model)
            }
        }
    }

    @Test func theStatusLineSaysWhatFailedInWords() async throws {
        // `lastError`'s read errors take the same sentences: here the keypad's `FQK` is refused every time.
        try await onBothMocks(refusing: ["FQK"]) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("the keypad's error (\(rig.label))") { model.lastError != nil }
            #expect(model.lastError == "The scanner refused FQK.", "\(rig.label)")
            await shutDown(model)
        }
    }

    @Test func aListThatKeepsFailingGoesLastOnAMenuExit() async throws {
        // A menu exit reads the keypad and every list again; list 0, which has failed more than once, goes after
        // every other list (it isn't shown), not first by its key. The menu exit comes in the rest after one of list
        // 0's failures (2 s, with nothing read), so no read of it is under way.
        try await onBothMocks(refusing: ["GLT,SYS,0"]) { rig in
            let model = makeModel(rig, pollInterval: .seconds(2))
            model.open()
            try await waitUntil("every other list read, then list 0 again (\(rig.label))", .seconds(10)) {
                let tries = count("GLT,SYS,0", in: await rig.commands())
                return Self.others(than: 0).allSatisfy { model.trees[$0]?.freshness == .fresh } && tries >= 3
            }
            try await Task.sleep(for: .milliseconds(200))
            let mark = await rig.commands().count
            model.menuReadChanged(true)
            model.menuReadChanged(false)
            func afterKeypad() async -> [UInt32] {
                let after = Array(await rig.commands().dropFirst(mark))
                guard let at = after.firstIndex(of: "GLT,FL") else { return [] }
                return systemReads(Array(after[(at + 1)...]))
            }
            try await waitUntil("every list read again (\(rig.label))", .seconds(8)) { await afterKeypad().count >= 8 }
            let order = await afterKeypad()
            #expect(Array(order.prefix(8)) == [4, 6, 1, 8, 12, 14, 10, 0], "\(rig.label): \(order)")
            await shutDown(model)
        }
    }

    @Test func aReopenStartsTheCountAgain() async throws {
        // Closing drops a list's failures with its error, so the next open gives a failing list its first retry
        // again (C1) before it goes last.
        try await onBothMocks(refusing: ["GLT,SYS,0"]) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("every other list read (\(rig.label))", .seconds(5)) {
                Self.others(than: 0).allSatisfy { model.trees[$0]?.freshness == .fresh }
            }
            model.close()
            await model.quiesce()
            let mark = await rig.commands().count
            model.open()
            func afterKeypad() async -> [UInt32] {
                let after = Array(await rig.commands().dropFirst(mark))
                guard let at = after.firstIndex(of: "GLT,FL") else { return [] }
                return systemReads(Array(after[(at + 1)...]))
            }
            try await waitUntil("list 0 and the next list (\(rig.label))", .seconds(5)) { await afterKeypad().count >= 3 }
            let order = await afterKeypad()
            #expect(Array(order.prefix(3)) == [0, 0, 4], "\(rig.label): \(order)")
            await shutDown(model)
        }
    }

    @Test func aCachedListShowsItsErrorUntilClosed() async throws {
        // List 1 isn't shown, but its cached tree is: the error shows there. Closing drops it with the states.
        try await onBothMocks(refusing: ["GLT,SYS,1"], cache: cachedListOne()) { rig in
            let model = makeModel(rig)
            model.open()
            try await waitUntil("list 1's error (\(rig.label))") { model.trees[1]?.readError != nil }
            #expect(model.trees[1]?.freshness == .checking, "\(rig.label)")
            model.close()
            #expect(model.trees[1] != nil, "\(rig.label)")
            #expect(model.trees[1]?.readError == nil, "\(rig.label)")
            await shutDown(model)
        }
    }
}
