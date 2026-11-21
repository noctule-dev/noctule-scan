// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleMockScanner
@testable import NoctuleAppCore

// QuickKeyPages and QuickKeyTyping (Plan 20 Task 6; design `docs/specs/2026-11-18-quick-keys-design.md` §5.5
// "The tens", "Search", "Keyboard"): the pop-over's paging, slot and search logic, on the keypad and trees
// a model reads from the mocks (`MockFavorites.default`: keys 0, 7, 1, 3, 12, none, 23, 41; every name
// fictional), and on hand-made keypads.

/// Runs `body` with a model that has read every list from the network SDS200 mock, then from the serial
/// SDS150 mock; stops everything on every path.
@MainActor
private func withLoadedModel(_ body: @MainActor (QuickKeysModel, String) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("qk-pages-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    @MainActor func run(_ client: ScannerClient, _ label: String, _ cache: String) async throws {
        let model = QuickKeysModel(cacheURL: directory.appendingPathComponent(cache), pollInterval: .seconds(30))
        model.attach(control: { client })
        model.open()
        var failure: (any Error)?
        do {
            try await waitUntil("every list read (\(label))") {
                !model.lists.isEmpty && model.lists.allSatisfy { model.trees[$0.index]?.freshness == .fresh }
            }
            try await body(model, label)
        } catch { failure = error }
        model.close()
        model.detach()
        await model.quiesce()
        if let failure { throw failure }
    }
    do {
        let mock = MockSDS200(scenario: .default, options: MockSDS200.Options(clock: .stepped(at: 3), quickKeySetDelay: .zero))
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort))
        var failure: (any Error)?
        do {
            try await client.connect()
            try await run(client, "SDS200 over UDP", "sds200/quick-keys.json")
        } catch { failure = error }
        await client.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
    do {
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 3), personality: .sds150, quickKeySetDelay: .zero)
        var failure: (any Error)?
        var client: ScannerClient?
        do {
            let connected = ScannerClient(transport: SerialTransport(path: try await mock.start()))
            client = connected
            try await connected.connect()
            try await run(connected, "SDS150 over serial", "sds150/quick-keys.json")
        } catch { failure = error }
        await client?.disconnect()
        await mock.stop()
        if let failure { throw failure }
    }
}

private func item(_ index: UInt32, key: Int?, state: QuickKeyState? = .on) -> QuickKeyListItem {
    QuickKeyListItem(index: index, name: "Mock List \(index)", key: key, monitored: true, state: state, systemCount: 1)
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct QuickKeyPagesTests {
    // MARK: The tens

    @Test func tensFromTheMock() async throws {
        try await withLoadedModel { model, label in
            let pages = QuickKeyPages(lists: model.lists, scanningList: 1)
            #expect(pages.tens.count == 10, "\(label)")
            #expect(pages.tens.map(\.range) == (0..<10).map { ($0 * 10)...($0 * 10 + 9) }, "\(label)")
            #expect(pages.tens.map(\.isEnabled) == [true, true, true, false, true, false, false, false, false, false],
                    "\(label)")
            #expect(pages.tens.map(\.listCount) == [4, 1, 1, 0, 1, 0, 0, 0, 0, 0], "\(label)")
            // Ten 0 holds keys 0 (on), 1 (list 4, off), 3 (on) and 7 (on): the states FQK read.
            #expect(pages.tens[0].onCount == 3, "\(label)")
            #expect(pages.tens[1].onCount == 0, "list 8 isn't monitored (\(label))")
            #expect(pages.tens[2].onCount == 1, "\(label)")
            // List 1 (key 7) is being scanned.
            #expect(pages.tens.map(\.holdsScanning) == [true] + Array(repeating: false, count: 9), "\(label)")
        }
    }

    @Test func nextSkipsEmptyTens() {
        let pages = QuickKeyPages(lists: [item(0, key: 0), item(4, key: 12), item(6, key: 23), item(8, key: 41),
                                          item(10, key: nil)], scanningList: nil)
        #expect(pages.next(after: 0) == 1)
        #expect(pages.next(after: 2) == 4)
        #expect(pages.next(after: 4) == nil)
        #expect(pages.next(after: 9) == nil)
        #expect(pages.previous(before: 4) == 2)
        #expect(pages.previous(before: 1) == 0)
        #expect(pages.previous(before: 0) == nil)
        #expect(pages.previous(before: 7) == 4)
    }

    @Test func slotsKeepPlaces() async throws {
        try await withLoadedModel { model, label in
            let pages = QuickKeyPages(lists: model.lists, scanningList: nil)
            let ten = pages.slots(inTen: 1)
            #expect(ten.count == 10, "\(label)")
            #expect(ten[2]?.index == 8, "key 12 is list 8 (\(label))")
            #expect(ten.enumerated().allSatisfy { $0.offset == 2 || $0.element == nil }, "\(label)")
            // Ten 0: keys 0, 1, 3 and 7 in their own places.
            #expect(pages.slots(inTen: 0).map { $0?.index } == [0, 4, nil, 6, nil, nil, nil, 1, nil, nil], "\(label)")
            #expect(pages.slots(inTen: 3).allSatisfy { $0 == nil }, "\(label)")
            #expect(pages.slots(inTen: 12).count == 10, "\(label)")
        }
    }

    @Test func initialTenIsTheScanningOne() {
        let lists = [item(0, key: 3), item(4, key: 41), item(6, key: 57), item(10, key: nil)]
        #expect(QuickKeyPages(lists: lists, scanningList: 4).initialTen() == 4)
        // Not scanning, or scanning a list without a key: the first ten with lists.
        #expect(QuickKeyPages(lists: lists, scanningList: nil).initialTen() == 0)
        #expect(QuickKeyPages(lists: lists, scanningList: 10).initialTen() == 0)
        #expect(QuickKeyPages(lists: Array(lists.dropFirst()), scanningList: 99).initialTen() == 4)
        #expect(QuickKeyPages(lists: [], scanningList: nil).initialTen() == 0)
    }

    // MARK: Typing

    @Test func typingTwoDigits() {
        let start = ContinuousClock.now
        var typing = QuickKeyTyping()
        #expect(typing.type(4, at: start) == 4)
        #expect(typing.type(1, at: start + .milliseconds(600)) == 41)
        // A third digit starts again.
        #expect(typing.type(7, at: start + .milliseconds(900)) == 7)

        var slow = QuickKeyTyping()
        #expect(slow.type(4, at: start) == 4)
        #expect(slow.type(1, at: start + .milliseconds(1500)) == 1)

        var bad = QuickKeyTyping()
        #expect(bad.type(10, at: start) == nil)
        #expect(bad.type(-1, at: start) == nil)
    }

    // MARK: Search

    @Test func searchFindsByNameOrNumber() async throws {
        try await withLoadedModel { model, label in
            #expect(QuickKeyPages.search("tower", in: model) == .child(list: 12, system: 160, child: 580), "\(label)")
            #expect(QuickKeyPages.search("TOWER", in: model) == .child(list: 12, system: 160, child: 580), "\(label)")
            #expect(QuickKeyPages.search("F12", in: model) == .list(8), "\(label)")
            #expect(QuickKeyPages.search("f12", in: model) == .list(8), "\(label)")
            #expect(QuickKeyPages.search("12", in: model) == .list(8), "\(label)")
            #expect(QuickKeyPages.search("nothing", in: model) == nil, "\(label)")
            #expect(QuickKeyPages.search("", in: model) == nil, "\(label)")
            // Lists before systems before children.
            #expect(QuickKeyPages.search("harbor", in: model) == .system(list: 8, system: 140), "\(label)")
            #expect(QuickKeyPages.search("marine", in: model) == .list(8), "\(label)")
            #expect(QuickKeyPages.search("S4", in: model) == .system(list: 12, system: 160), "\(label)")
            #expect(QuickKeyPages.search("D2", in: model) == .child(list: 1, system: 102, child: 402), "\(label)")
        }
    }
}
