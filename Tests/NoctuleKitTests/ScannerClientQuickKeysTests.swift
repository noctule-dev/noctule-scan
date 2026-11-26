// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKitTestSupport
@testable import NoctuleMockScanner
@testable import NoctuleKit

// ScannerClient's Favorites calls (Plan 20 Task 3) over the mocks: the SDS200 over UDP and the SDS150 and
// SDS100 over serial. Every name is fictional (`MockFavorites.default`).

private struct QKRig: Sendable {
    let label: String
    let client: ScannerClient
    let setFaults: @Sendable (MockFaults) async -> Void
    let commands: @Sendable () async -> [String]
}

private func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw CancellationError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

private func onEveryMock(
    commandTimeout: Duration = .milliseconds(700), gltPageSize: Int = MockFavorites.defaultGLTPageSize,
    _ body: @escaping @Sendable (QKRig) async throws -> Void
) async throws {
    do {
        let options = MockSDS200.Options(clock: .stepped(at: 3), quickKeySetDelay: .zero, gltPageSize: gltPageSize)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort),
                                   commandTimeout: commandTimeout)
        var failure: (any Error)?
        do {
            try await client.connect()
            let rig = QKRig(label: "SDS200 over UDP", client: client, setFaults: { await mock.setFaults($0) },
                            commands: { await mock.control.receivedCommands })
            try await withTimeout(.seconds(15)) { try await body(rig) }
        } catch { failure = error }
        await client.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
    for personality in [MockPersonality.sds150, .sds100] {
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 3), personality: personality,
                                     quickKeySetDelay: .zero, gltPageSize: gltPageSize)
        var failure: (any Error)?
        var client: ScannerClient?
        do {
            let path = try await mock.start()
            let connected = ScannerClient(transport: SerialTransport(path: path), commandTimeout: commandTimeout)
            client = connected
            try await connected.connect()
            let rig = QKRig(label: "\(personality.reportedModel) over serial", client: connected,
                            setFaults: { await mock.setFaults($0) }, commands: { await mock.receivedCommands })
            try await withTimeout(.seconds(15)) { try await body(rig) }
        } catch { failure = error }
        await client?.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ScannerClientQuickKeysTests {
    @Test func readsTheWholeDefaultTree() async throws {
        try await onEveryMock { rig in
            let c = rig.client
            let lists = try await c.favoritesLists()
            #expect(lists.map(\.index) == [0, 1, 4, 6, 8, 10, 12, 14], "\(rig.label)")
            #expect(lists.map(\.quickKey) == [0, 7, 1, 3, 12, nil, 23, 41], "\(rig.label)")
            let systems = try await c.favoritesSystems(inList: 1)
            #expect(systems.map(\.index) == [101, 102], "\(rig.label)")
            #expect(systems.map(\.quickKey) == [0, 1], "\(rig.label)")
            let departments = try await c.favoritesDepartments(inSystem: 101)
            #expect(departments.map(\.index) == [118, 200, 201, 203], "\(rig.label)")
            #expect(departments.map(\.quickKey) == [nil, 0, 1, 0], "\(rig.label)")
            let sites = try await c.favoritesSites(inSystem: 101)
            #expect(sites.map(\.index) == [301], "\(rig.label)")
            let sites120 = try await c.favoritesSites(inSystem: 120)
            #expect(sites120.map(\.index) == [620, 621], "\(rig.label)")
            let departments120 = try await c.favoritesDepartments(inSystem: 120)
            #expect(departments120.map(\.index) == [530], "\(rig.label)")
            let listKeys = try await c.listKeyStates()
            #expect(listKeys.existingKeys == [0, 1, 3, 7, 12, 23, 41], "\(rig.label)")
            let systemKeys = try await c.systemKeyStates(listKey: 7)
            #expect(systemKeys.existingKeys == [0, 1], "\(rig.label)")
            let departmentKeys = try await c.departmentKeyStates(listKey: 7, systemKey: 1)
            #expect(departmentKeys.existingKeys == [0, 1, 2], "\(rig.label)")
        }
    }

    /// `GLT` replies come in pages (the SDS150 and the SDS100 over serial, 2026-11-19): with two elements a
    /// page every read still gets its whole reply, and the next read never gets an earlier reply's pages
    /// (on the SDS150, `GLT,DEPT` once received the second page of the `GLT,SITE` before it).
    @Test func pagedRepliesAnswerOnlyTheirOwnRead() async throws {
        try await onEveryMock(gltPageSize: 2) { rig in
            let c = rig.client
            for _ in 0..<2 {
                let departments = try await c.favoritesDepartments(inSystem: 101)
                #expect(departments.map(\.index) == [118, 200, 201, 203], "\(rig.label)")
                let sites = try await c.favoritesSites(inSystem: 120)
                #expect(sites.map(\.index) == [620, 621], "\(rig.label)")
                let departments120 = try await c.favoritesDepartments(inSystem: 120)
                #expect(departments120.map(\.index) == [530], "\(rig.label)")
                let lists = try await c.favoritesLists()
                #expect(lists.map(\.index) == [0, 1, 4, 6, 8, 10, 12, 14], "\(rig.label)")
                let systems = try await c.favoritesSystems(inList: 4)
                #expect(systems.map(\.index) == [120, 121, 122], "\(rig.label)")
                let empty = try await c.favoritesDepartments(inSystem: 999_999)
                #expect(empty.isEmpty, "\(rig.label)")
            }
        }
    }

    /// `GLT` is expected as XML. Over the mock the reply carries its `GLT,<XML>,` prefix, which
    /// the assembler needs no hint for; the hint matters for a bare document, which
    /// `UDPTransportTests/loopbackGLTReassemblesBareDocument` covers.
    @Test func gltAssemblesOverUDP() async throws {
        let options = MockSDS200.Options(clock: .stepped(at: 3), quickKeySetDelay: .zero)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort),
                                   commandTimeout: .milliseconds(700))
        var failure: (any Error)?
        do {
            try await client.connect()
            let departments = try await client.favoritesDepartments(inSystem: 101)
            #expect(departments.count == 4)
        } catch { failure = error }
        await client.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }

    @Test func setsNameOneKey() async throws {
        try await onEveryMock { rig in
            try await rig.client.setSystemKey(1, inList: 7, on: true)
            let log = await rig.commands()
            let expected = (["SQK", "7"] + QuickKeyStates.setting(1, on: true)).joined(separator: ",")
            #expect(log.last == expected, "\(rig.label)")
            let states = try await rig.client.systemKeyStates(listKey: 7)
            #expect(states[1] == .on, "\(rig.label)")
            try await rig.client.setListKey(3, on: false)
            #expect(try await rig.client.listKeyStates()[3] == .off, "\(rig.label)")
            try await rig.client.setDepartmentKey(2, inList: 7, system: 1, on: true)
            #expect(try await rig.client.departmentKeyStates(listKey: 7, systemKey: 1)[2] == .on, "\(rig.label)")
            let last = (await rig.commands()).filter { $0.hasPrefix("DQK,7,1,") }.last
            #expect(last == (["DQK", "7", "1"] + QuickKeyStates.setting(2, on: true)).joined(separator: ","))
        }
    }

    @Test func aKeyOutOfRangeSendsNothing() async throws {
        try await onEveryMock { rig in
            let c = rig.client
            for key in [-1, 100] {
                await #expect(throws: ScannerClientError.self) { try await c.setListKey(key, on: true) }
                await #expect(throws: ScannerClientError.self) { try await c.setSystemKey(key, inList: 7, on: true) }
                await #expect(throws: ScannerClientError.self) { try await c.setDepartmentKey(key, inList: 7, system: 1, on: true) }
            }
            await #expect(throws: ScannerClientError.self) { try await c.setSystemKey(1, inList: 100, on: true) }
            await #expect(throws: ScannerClientError.self) { try await c.setDepartmentKey(1, inList: 7, system: -1, on: true) }
            await #expect(throws: ScannerClientError.self) { _ = try await c.systemKeyStates(listKey: 100) }
            await #expect(throws: ScannerClientError.self) { _ = try await c.departmentKeyStates(listKey: 7, systemKey: 100) }
            let log = await rig.commands()
            #expect(!log.contains { $0.hasPrefix("FQK,") || $0.hasPrefix("SQK") || $0.hasPrefix("DQK") }, "\(rig.label): \(log)")
        }
    }

    @Test func aRejectedSetThrows() async throws {
        try await onEveryMock { rig in
            await rig.setFaults(MockFaults(rejectNext: "DQK"))
            do {
                try await rig.client.setDepartmentKey(1, inList: 7, system: 1, on: true)
                Issue.record("\(rig.label): a rejected set didn't throw")
            } catch ScannerClientError.rejected(let command, _) {
                #expect(command == "DQK", "\(rig.label)")
            }
        }
    }

    @Test func aSetIsNotRetried() async throws {
        try await onEveryMock(commandTimeout: .milliseconds(300)) { rig in
            await rig.setFaults(MockFaults(dropNextReply: "FQK"))
            do {
                try await rig.client.setListKey(1, on: false)
                Issue.record("\(rig.label): a set with no reply didn't throw")
            } catch ScannerClientError.timeout {
            }
            try await Task.sleep(for: .milliseconds(100))
            let sets = (await rig.commands()).filter { $0.hasPrefix("FQK,") }
            #expect(sets.count == 1, "\(rig.label): \(sets.count)")
        }
    }

    @Test func profilesSupportQuickKeys() {
        #expect(ModelProfile.profile(for: .sds200).supportsQuickKeys)
        #expect(ModelProfile.profile(for: .sds150).supportsQuickKeys)
        #expect(ModelProfile.profile(for: .sds100).supportsQuickKeys)
        #expect(ModelProfile.profile(for: .bcd436hp).supportsQuickKeys)
    }
}
