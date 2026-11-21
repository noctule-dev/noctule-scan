// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
@testable import NoctuleMockScanner

// The mocks' fictional Favorites tree and the GLT / FQK / SQK / DQK commands (Plan 20 Task 2),
// through the real client stack: MockSDS200 over UDPTransport, and MockSerialScanner in both
// personalities over SerialTransport. Each test runs on all three.

private struct FavRig: Sendable {
    let label: String
    let client: ScannerClient
    let favorites: @Sendable () async -> MockFavorites
    let setFavorites: @Sendable (MockFavorites) async -> Void
    let setFaults: @Sendable (MockFaults) async -> Void
    let commands: @Sendable () async -> [String]

    func fields(_ name: String, _ arguments: String...) async throws -> [String] {
        let response = try await client.send(ScannerCommand(name, arguments: arguments))
        guard case .fields(_, let fields) = response else { throw ScannerClientError.unexpectedResponse(command: name) }
        return fields
    }

    func states(_ name: String, _ arguments: String...) async throws -> QuickKeyStates {
        let response = try await client.send(ScannerCommand(name, arguments: arguments))
        guard case .fields(_, let fields) = response, let states = QuickKeyStates(fields: fields) else {
            throw ScannerClientError.unexpectedResponse(command: name)
        }
        return states
    }

    func glt(_ arguments: String...) async throws -> NoctuleKit.XMLNode {
        let response = try await client.send(ScannerCommand("GLT", arguments: arguments))
        guard case .xml(_, let root) = response else { throw ScannerClientError.unexpectedResponse(command: "GLT") }
        return root
    }

    func set(_ name: String, _ prefix: [String], _ values: [String]) async throws -> [String] {
        let response = try await client.send(ScannerCommand(name, arguments: prefix + values))
        guard case .fields(_, let fields) = response else { throw ScannerClientError.unexpectedResponse(command: name) }
        return fields
    }
}

private func isRejected(_ error: any Error) -> Bool {
    if case ScannerClientError.rejected = error { return true }
    return false
}

private func isTimeout(_ error: any Error) -> Bool {
    if case ScannerClientError.timeout = error { return true }
    return false
}

/// Runs `body` on the SDS200 mock (UDP) and on the SDS150 and SDS100 serial mocks, one after the other.
private func onEveryMock(
    delay: Duration = .zero, replyDelays: [String: Duration] = [:], commandTimeout: Duration = .milliseconds(700),
    gltPageSize: Int = MockFavorites.defaultGLTPageSize,
    _ body: @escaping @Sendable (FavRig) async throws -> Void
) async throws {
    // MockSDS200 over UDP.
    do {
        let options = MockSDS200.Options(clock: .stepped(at: 3), replyDelays: replyDelays, quickKeySetDelay: delay,
                                         gltPageSize: gltPageSize)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort),
                                   commandTimeout: commandTimeout)
        var failure: (any Error)?
        do {
            try await client.connect()
            let rig = FavRig(
                label: "SDS200 over UDP", client: client, favorites: { await mock.favorites },
                setFavorites: { await mock.setFavorites($0) }, setFaults: { await mock.setFaults($0) },
                commands: { await mock.control.receivedCommands })
            try await within(.seconds(15)) { try await body(rig) }
        } catch { failure = error }
        await client.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
    for personality in [MockPersonality.sds150, .sds100] {
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 3), personality: personality,
                                     replyDelays: replyDelays, quickKeySetDelay: delay, gltPageSize: gltPageSize)
        var failure: (any Error)?
        var client: ScannerClient?
        do {
            let path = try await mock.start()
            let connected = ScannerClient(transport: SerialTransport(path: path), commandTimeout: commandTimeout)
            client = connected
            try await connected.connect()
            let rig = FavRig(
                label: "\(personality.reportedModel) over serial", client: connected,
                favorites: { await mock.favorites }, setFavorites: { await mock.setFavorites($0) },
                setFaults: { await mock.setFaults($0) }, commands: { await mock.receivedCommands })
            try await within(.seconds(15)) { try await body(rig) }
        } catch { failure = error }
        await client?.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
}

@Suite(.timeLimit(.minutes(1))) struct MockFavoritesTests {
    @Test func gltListsTheDefaultTree() async throws {
        try await onEveryMock { rig in
            let root = try await rig.glt("FL")
            // The built-ins come first, then the eight lists.
            let names = root.children.map { $0.attributes["Name"] ?? "" }
            #expect(names == ["Full Database", "Search with Scan", "Mock Police", "Mock Favorites", "Mock Fire & EMS",
                              "Mock Utilities", "Mock Marine", "Mock Events", "Mock Air", "Mock Interop"], "\(rig.label)")
            #expect(root.children[0].attributes["Index"] == "4294967295")
            #expect(root.children[1].attributes["Index"] == "4261412864")
            for builtin in root.children.prefix(2) {
                #expect(builtin.attributes["Monitor"] == "Off" && builtin.attributes["Q_Key"] == "None")
            }
            let lists = try FavoritesXML.lists(root)
            #expect(lists.map(\.index) == [0, 1, 4, 6, 8, 10, 12, 14], "\(rig.label)")
            #expect(lists.map(\.quickKey) == [0, 7, 1, 3, 12, nil, 23, 41], "\(rig.label)")
            // Monitor (Select Lists to Monitor) is not the quick key's state: only list 8 is unmonitored.
            #expect(lists.map(\.monitored) == [true, true, true, true, false, true, true, true], "\(rig.label)")
        }
    }

    @Test func aListsMonitorIsKeptApartFromItsQuickKeyState() async throws {
        try await onEveryMock { rig in
            func monitors() async throws -> [UInt32: Bool] {
                Dictionary(uniqueKeysWithValues: try FavoritesXML.lists(try await rig.glt("FL")).map { ($0.index, $0.monitored) })
            }
            let before = try await monitors()
            // List 4 is monitored with its key off; list 8 is neither monitored nor on.
            #expect(before[4] == true && before[8] == false, "\(rig.label)")
            let states = try await rig.states("FQK")
            #expect(states[1] == .off && states[12] == .off, "\(rig.label)")
            // Turning the keys on changes the state and no Monitor.
            _ = try await rig.set("FQK", [], QuickKeyStates.setting(1, on: true))
            _ = try await rig.set("FQK", [], QuickKeyStates.setting(12, on: true))
            let after = try await rig.states("FQK")
            #expect(after[1] == .on && after[12] == .on, "\(rig.label)")
            #expect(try await monitors() == before, "\(rig.label)")
        }
    }

    @Test func gltDrillsDownByIndex() async throws {
        try await onEveryMock { rig in
            let systems = try FavoritesXML.systems(try await rig.glt("SYS", "1"))
            #expect(systems.map(\.index) == [101, 102], "\(rig.label)")
            #expect(systems.map(\.quickKey) == [0, 1], "\(rig.label)")
            #expect(systems.map(\.type) == ["P25 Trunk", "Conventional"], "\(rig.label)")
            let departments = try await rig.glt("DEPT", "101")
            #expect(departments.children.map { $0.attributes["Index"] ?? "" }
                    == ["4294967295", "118", "200", "201", "203"], "\(rig.label)")
            #expect(departments.children.map { $0.attributes["Name"] ?? "" }
                    == ["Unknown", "Road Crews", "Lakeview Fire", "Riverbend Sheriff", "Lakeview Fire Tac"])
            let sites = try FavoritesXML.sites(try await rig.glt("SITE", "120"))
            #expect(sites.map(\.index) == [620, 621], "\(rig.label)")
            #expect(sites.map(\.quickKey) == [0, 1], "\(rig.label)")
            let avoided = try FavoritesXML.systems(try await rig.glt("SYS", "4"))
            #expect(avoided.map(\.avoided) == [false, true, false], "\(rig.label)")
            // An index nothing has is an empty document.
            let empty = try await rig.glt("DEPT", "999999")
            #expect(empty.name == "GLT" && empty.children.isEmpty, "\(rig.label)")
        }
    }

    @Test func fqkReadsTheStates() async throws {
        try await onEveryMock { rig in
            let states = try await rig.states("FQK")
            #expect(states[0] == .on && states[1] == .off && states[7] == .on && states[9] == .none, "\(rig.label)")
            #expect(states[3] == .on && states[12] == .off && states[23] == .on && states[41] == .off)
            #expect(states.existingKeys == [0, 1, 3, 7, 12, 23, 41], "\(rig.label)")
        }
    }

    @Test func systemsHaveDifferentKeyPatterns() async throws {
        try await onEveryMock { rig in
            let first = try await rig.states("DQK", "7", "0")
            let second = try await rig.states("DQK", "7", "1")
            #expect(first.existingKeys == [0, 1], "\(rig.label)")
            #expect(second.existingKeys == [0, 1, 2], "\(rig.label)")
            #expect(second[0] == .on && second[1] == .off && second[2] == .off, "\(rig.label)")
            let systemKeys = try await rig.states("SQK", "7")
            #expect(systemKeys.existingKeys == [0, 1], "\(rig.label)")
        }
    }

    @Test func aSetChangesOneKeyAndIgnoresZeros() async throws {
        try await onEveryMock { rig in
            let reply = try await rig.set("SQK", ["7"], QuickKeyStates.setting(1, on: false))
            #expect(reply == ["OK"], "\(rig.label)")
            let states = try await rig.states("SQK", "7")
            #expect(states[0] == .on && states[1] == .off, "\(rig.label)")
            // FQK too: turn list 0 off, and one key that doesn't exist is ignored.
            _ = try await rig.set("FQK", [], QuickKeyStates.setting(0, on: false))
            _ = try await rig.set("FQK", [], QuickKeyStates.setting(9, on: true))
            let lists = try await rig.states("FQK")
            #expect(lists[0] == .off && lists[9] == .none && lists[7] == .on, "\(rig.label)")
            // A department key.
            _ = try await rig.set("DQK", ["7", "1"], QuickKeyStates.setting(1, on: true))
            let departments = try await rig.states("DQK", "7", "1")
            #expect(departments[0] == .on && departments[1] == .on && departments[2] == .off, "\(rig.label)")
        }
    }

    @Test func aSharedDepartmentKeySwitchesTogether() async throws {
        try await onEveryMock { rig in
            #expect(try await rig.set("DQK", ["7", "0"], QuickKeyStates.setting(0, on: false)) == ["OK"])
            let favorites = await rig.favorites()
            let held = favorites.children.filter { $0.systemIndex == 101 && $0.quickKey == 0 }
            #expect(held.map(\.index) == [200, 203, 301], "\(rig.label)")
            #expect(held.allSatisfy { !$0.isOn }, "\(rig.label)")
            let states = try await rig.states("DQK", "7", "0")
            #expect(states[0] == .off && states[1] == .on, "\(rig.label)")
        }
    }

    @Test func badSetsAreRefused() async throws {
        try await onEveryMock { rig in
            let before = await rig.favorites()
            var tooFew = QuickKeyStates.setting(1, on: false)
            tooFew.removeLast()
            var badValue = QuickKeyStates.setting(1, on: false)
            badValue[5] = "3"
            let attempts: [(String, [String], [String])] = [
                ("SQK", ["7"], tooFew), ("SQK", ["7"], badValue), ("SQK", ["99"], QuickKeyStates.setting(1, on: false)),
                ("FQK", [], tooFew), ("FQK", [], badValue),
                ("DQK", ["7", "1"], tooFew), ("DQK", ["7", "99"], QuickKeyStates.setting(1, on: false)),
                ("DQK", ["99", "1"], QuickKeyStates.setting(1, on: false)),
            ]
            for (name, prefix, values) in attempts {
                do {
                    _ = try await rig.set(name, prefix, values)
                    Issue.record("\(rig.label): \(name) \(prefix) \(values.count) values was accepted")
                } catch {
                    #expect(isRejected(error), "\(rig.label): \(name) \(prefix): \(error)")
                }
            }
            #expect(await rig.favorites() == before, "\(rig.label)")
        }
    }

    @Test func theMismatchReportsZeros() async throws {
        try await onEveryMock { rig in
            // System 122 (key 2 in list key 1) has a department with a GLT key, but DQK says nothing exists.
            let departments = try FavoritesXML.departments(try await rig.glt("DEPT", "122"))
            #expect(departments.map(\.quickKey) == [2], "\(rig.label)")
            let states = try await rig.states("DQK", "1", "2")
            #expect(states.existingKeys.isEmpty, "\(rig.label)")
            // A set there changes nothing and is accepted (the key doesn't exist).
            let before = await rig.favorites()
            #expect(try await rig.set("DQK", ["1", "2"], QuickKeyStates.setting(2, on: false)) == ["OK"])
            #expect(await rig.favorites() == before, "\(rig.label)")
        }
    }

    @Test func listAndSystemSetsWait() async throws {
        try await onEveryMock(delay: .milliseconds(800), commandTimeout: .seconds(3)) { rig in
            let clock = ContinuousClock()
            var started = clock.now
            _ = try await rig.set("FQK", [], QuickKeyStates.setting(7, on: true))
            #expect(started.duration(to: clock.now) >= .milliseconds(750), "\(rig.label) FQK")
            started = clock.now
            _ = try await rig.set("SQK", ["7"], QuickKeyStates.setting(0, on: true))
            #expect(started.duration(to: clock.now) >= .milliseconds(750), "\(rig.label) SQK")
            started = clock.now
            _ = try await rig.set("DQK", ["7", "0"], QuickKeyStates.setting(0, on: true))
            #expect(started.duration(to: clock.now) < .milliseconds(200), "\(rig.label) DQK")
            started = clock.now
            _ = try await rig.states("FQK")
            #expect(started.duration(to: clock.now) < .milliseconds(200), "\(rig.label) read")
        }
    }

    @Test func gsiStillNamesListOneWithKeyZero() async throws {
        try await onEveryMock { rig in
            let response = try await rig.client.send(ScannerCommand("GSI"))
            guard case .xml(_, let root) = response else { Issue.record("no GSI document"); return }
            func find(_ node: NoctuleKit.XMLNode) -> NoctuleKit.XMLNode? {
                if node.name == "MonitorList" { return node }
                for child in node.children { if let found = find(child) { return found } }
                return nil
            }
            let list = find(root)
            #expect(list?.attributes["Index"] == "1" && list?.attributes["Q_Key"] == "0", "\(rig.label)")
            let lists = try FavoritesXML.lists(try await rig.glt("FL"))
            #expect(lists.first { $0.index == 1 }?.quickKey == 7, "\(rig.label)")
        }
    }

    @Test func setFavoritesMovesAKey() async throws {
        try await onEveryMock { rig in
            var favorites = await rig.favorites()
            let position = try #require(favorites.systems.firstIndex { $0.index == 102 })
            favorites.systems[position].quickKey = 3
            await rig.setFavorites(favorites)
            let systems = try FavoritesXML.systems(try await rig.glt("SYS", "1"))
            #expect(systems.map(\.quickKey) == [0, 3], "\(rig.label)")
            let states = try await rig.states("SQK", "7")
            #expect(states[3] == .on && states[1] == .none && states[0] == .on, "\(rig.label)")
        }
    }

    @Test func faultsAndDelaysApplyToTheNewCommands() async throws {
        try await onEveryMock(replyDelays: ["GLT": .milliseconds(300)]) { rig in
            let clock = ContinuousClock()
            let started = clock.now
            _ = try await rig.glt("FL")
            #expect(started.duration(to: clock.now) >= .milliseconds(250), "\(rig.label) GLT delay")

            // A reply dropped after the command was carried out.
            await rig.setFaults(MockFaults(dropNextReply: "FQK"))
            do {
                _ = try await rig.set("FQK", [], QuickKeyStates.setting(0, on: false))
                Issue.record("\(rig.label): the FQK reply wasn't dropped")
            } catch { #expect(isTimeout(error), "\(rig.label): \(error)") }
            #expect(await rig.favorites().lists.first { $0.index == 0 }?.isOn == false, "\(rig.label)")

            // Rejected without being carried out.
            await rig.setFaults(MockFaults(rejectNext: "SQK"))
            let before = await rig.favorites()
            do {
                _ = try await rig.set("SQK", ["7"], QuickKeyStates.setting(1, on: false))
                Issue.record("\(rig.label): SQK wasn't rejected")
            } catch { #expect(isRejected(error), "\(rig.label): \(error)") }
            #expect(await rig.favorites() == before, "\(rig.label)")
        }
    }

    @Test func aSharedKeyReadsTheFirstHolderInGLTOrder() async throws {
        try await onEveryMock { rig in
            // Systems 110 and 111 share S0 in list key 0; give them different states.
            var favorites = await rig.favorites()
            func put(_ system: UInt32, on: Bool) {
                favorites.systems[favorites.systems.firstIndex { $0.index == system }!].isOn = on
            }
            func put(child index: UInt32, of system: UInt32, on: Bool) {
                favorites.children[favorites.children.firstIndex { $0.index == index && $0.systemIndex == system }!].isOn = on
            }
            put(110, on: true); put(111, on: false)
            await rig.setFavorites(favorites)
            let first = try await rig.states("SQK", "0"); #expect(first[0] == .on, "\(rig.label) first on, second off")
            put(110, on: false); put(111, on: true)
            await rig.setFavorites(favorites)
            let second = try await rig.states("SQK", "0"); #expect(second[0] == .off, "\(rig.label) first off, second on")

            // System 101's D0 is held by departments 200 and 203 and by site 301: departments first.
            put(child: 200, of: 101, on: true); put(child: 203, of: 101, on: false); put(child: 301, of: 101, on: false)
            await rig.setFavorites(favorites)
            let third = try await rig.states("DQK", "7", "0"); #expect(third[0] == .on, "\(rig.label) first department on")
            put(child: 200, of: 101, on: false); put(child: 203, of: 101, on: true); put(child: 301, of: 101, on: true)
            await rig.setFavorites(favorites)
            let fourth = try await rig.states("DQK", "7", "0"); #expect(fourth[0] == .off, "\(rig.label) first department off")
        }
    }

    @Test func noDelaysZeroesTheSetDelay() throws {
        let normal = try MockScannerArguments.parse([])
        #expect(normal.quickKeySetDelay == .milliseconds(800))
        #expect(normal.options(log: nil).quickKeySetDelay == .milliseconds(800))
        let quick = try MockScannerArguments.parse(["--no-delays"])
        #expect(quick.quickKeySetDelay == .zero)
        #expect(quick.options(log: nil).quickKeySetDelay == .zero)
    }

    /// `GLT` replies come in pages, as the SDS150's and the SDS100's do over serial (2026-11-19): one document
    /// per page of at most `pageSize` elements, each with its own `GLT,<XML>,` line and a footer numbered from
    /// 1, `EOT="1"` on the last only; an empty reply is one page. The same on every model.
    @Test func gltRepliesComeInPages() throws {
        var favorites = MockFavorites.default
        func glt(_ args: [String], _ lineBreak: String, pageSize: Int = MockFavorites.defaultGLTPageSize) throws
            -> (replies: [String], delayed: Bool) {
            let answer = favorites.reply(to: "GLT", args: args, lineBreak: lineBreak, pageSize: pageSize)
            return try #require(answer)
        }
        for lineBreak in ["\r", "\n"] {
            let fl = try glt(["FL"], lineBreak, pageSize: 4)
            #expect(!fl.delayed)
            #expect(fl.replies.count == 3, "10 rows: 4, 4, 2")
            for (offset, page) in fl.replies.enumerated() {
                #expect(page.hasPrefix("GLT,<XML>,\r<?xml"))
                let last = offset == fl.replies.count - 1
                #expect(page.hasSuffix("<Footer No=\"\(offset + 1)\" EOT=\"\(last ? 1 : 0)\"/>\(lineBreak)</GLT>"))
                #expect(page.components(separatedBy: "<FL ").count - 1 == (last ? 2 : 4))
            }
            let one = try glt(["SYS", "1"], lineBreak, pageSize: 4)
            #expect(one.replies.count == 1)
            #expect(one.replies[0].contains("<Footer No=\"1\" EOT=\"1\"/>"))
            let empty = try glt(["DEPT", "999999"], lineBreak)
            #expect(empty.replies.count == 1)
            #expect(empty.replies[0].hasSuffix("<GLT>\(lineBreak)<Footer No=\"1\" EOT=\"1\"/>\(lineBreak)</GLT>"))
            let single = try glt(["FL"], lineBreak, pageSize: 1)
            #expect(single.replies.count == 10)
        }
        #expect(MockFavorites.defaultGLTPageSize == 4)
        // The other commands still answer one line.
        #expect(favorites.reply(to: "FQK", args: [], lineBreak: "\r")?.replies.count == 1)
    }

    /// Through the real client stack on every mock, with pages of one element: every read gets its whole
    /// reply, however many pages, and the next read never sees an earlier reply's pages.
    @Test func pagedRepliesReachTheClientWhole() async throws {
        try await onEveryMock(gltPageSize: 1) { rig in
            let lists = try FavoritesXML.lists(try await rig.glt("FL"))
            #expect(lists.map(\.index) == [0, 1, 4, 6, 8, 10, 12, 14], "\(rig.label)")
            let departments = try await rig.glt("DEPT", "101")
            #expect(departments.children.map { $0.attributes["Index"] ?? "" }
                    == ["4294967295", "118", "200", "201", "203"], "\(rig.label)")
            #expect(!departments.children.contains { $0.name == "Footer" }, "\(rig.label)")
            let sites = try FavoritesXML.sites(try await rig.glt("SITE", "120"))
            #expect(sites.map(\.index) == [620, 621], "\(rig.label)")
            let systems = try FavoritesXML.systems(try await rig.glt("SYS", "4"))
            #expect(systems.map(\.index) == [120, 121, 122], "\(rig.label)")
        }
    }
}
