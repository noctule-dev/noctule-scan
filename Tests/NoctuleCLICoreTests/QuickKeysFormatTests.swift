// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
@testable import NoctuleCLICore

/// `noctule quick-keys`: the tree's text (design §5.3, with the plan's exact format) and its arguments.
@Suite(.timeLimit(.minutes(1))) struct QuickKeysFormatTests {
    private func states(_ values: [Int: Int]) throws -> QuickKeyStates {
        try #require(QuickKeyStates(fields: (0..<100).map { String(values[$0] ?? 0) }))
    }

    private func list(_ index: UInt32, _ name: String, key: Int?, monitored: Bool = true) -> FavoritesList {
        FavoritesList(index: index, name: name, quickKey: key, monitored: monitored)
    }

    private func system(_ index: UInt32, _ name: String, _ type: String, key: Int?, avoided: Bool = false) -> FavoritesSystem {
        FavoritesSystem(index: index, name: name, type: type, quickKey: key, avoided: avoided)
    }

    private func child(_ index: UInt32, _ name: String, key: Int?, _ kind: FavoritesChild.Kind) -> FavoritesChild {
        FavoritesChild(index: index, name: name, quickKey: key, avoided: false, kind: kind)
    }

    /// A slice of the mock's tree, with the lists in an order that isn't their key order.
    private func mockTree() throws -> QuickKeyTree {
        let police = QuickKeyTree.ListNode(list: list(0, "Mock Police", key: 0), systems: [
            .init(system: system(110, "Metro P25", "P25 Trunk", key: 0), children: [
                child(500, "Patrol", key: 0, .department), child(501, "Detectives", key: 1, .department),
                child(610, "Metro Simulcast", key: nil, .site)]),
            .init(system: system(112, "Metro Conventional", "Conventional", key: nil), children: [
                child(520, "Records", key: 0, .department)]),
        ])
        let fire = QuickKeyTree.ListNode(list: list(4, "Mock Fire & EMS", key: 1), systems: [
            .init(system: system(120, "Lakeview City P25", "P25 Trunk", key: 0), children: [
                child(530, "Fire Dispatch", key: nil, .department), child(620, "North Site", key: 0, .site)]),
            .init(system: system(121, "County 800 Trunk", "Motorola", key: 1, avoided: true), children: []),
            .init(system: system(122, "State Forestry", "Conventional", key: 2), children: [
                child(540, "Air Attack", key: 2, .department)]),
        ])
        let marine = QuickKeyTree.ListNode(list: list(8, "Mock Marine", key: 12, monitored: false), systems: [])
        let events = QuickKeyTree.ListNode(list: list(10, "Mock Events", key: nil), systems: [])
        return QuickKeyTree(
            nodes: [events, marine, fire, police],
            lists: try states([0: 2, 1: 1, 12: 1]),
            systems: [0: try states([0: 2]), 1: try states([0: 2, 1: 1, 2: 2])],
            children: [QuickKeyPair(list: 0, system: 0): try states([0: 2, 1: 1]),
                       QuickKeyPair(list: 1, system: 0): try states([0: 2]),
                       // The conventional system's DQK reads all zeros (design §3.2).
                       QuickKeyPair(list: 1, system: 2): try states([:])])
    }

    @Test func formatsTheMockTree() throws {
        #expect(CLIFormat.quickKeys(try mockTree()) == [
            "F0    on   Mock Police",
            "  S0    on   Metro P25 (P25 Trunk)",
            "    D0    on   Patrol",
            "    D1    off  Detectives",
            "    -     -    Metro Simulcast (site)",
            "  -     -    Metro Conventional",
            "    D0    -    Records",
            "F1    off  Mock Fire & EMS",
            "  S0    on   Lakeview City P25 (P25 Trunk)",
            "    -     -    Fire Dispatch",
            "    D0    on   North Site (site)",
            "  S1    off  County 800 Trunk (Motorola) (avoided)",
            "  S2    on   State Forestry",
            "    D2    ?    Air Attack",
            "F12   off  Mock Marine (not monitored)",
            "-     -    Mock Events",
        ])
    }

    @Test func parsesQuickKeys() throws {
        #expect(try CLIArguments.parse(["quick-keys"]).command == .quickKeys)
        #expect(try CLIArguments.parse(["quick-keys", "--serial", "/tmp/x"]).serial == .path("/tmp/x"))
        #expect(try CLIArguments.parse(["quick-keys", "--host", "h"]).host == "h")
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["quick-keys", "--interval", "5"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["quick-keys", "extra"]) }
    }
}
