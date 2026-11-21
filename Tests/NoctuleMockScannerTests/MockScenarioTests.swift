// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleMockScanner

private func tx(_ at: Double, _ duration: Double, _ channel: String) -> MockTransmission {
    MockTransmission(at: at, duration: duration, system: "Test System", department: "Test Dept",
                     channel: channel, tgid: "1", frequencyMHz: 851.0)
}

private let idle = MockIdle(system: "Test System", site: "Test Site", frequencyMHz: 851.0)

@Suite(.timeLimit(.minutes(1))) struct MockScenarioTests {
    @Test func defaultScenarioDecodes() throws {
        let url = try #require(MockScenario.bundledURL("default"))
        let scenario = try MockScenario.load(url)
        #expect(scenario == MockScenario.default)
        #expect(scenario.model == "SDS200")
        #expect(scenario.firmware == "1.26.01")
        #expect(scenario.mode == .trunk)
        #expect(scenario.transmissions.count >= 3)
        #expect(scenario.transmissions.contains { !$0.programmed })
        #expect(scenario.transmissions.contains { $0.programmed })

        // Fictional names only: nothing from the owner's git-ignored deny-list of real names
        // (config/real-names.txt; checked only when it exists).
        let names = scenario.transmissions.flatMap { [$0.system, $0.department, $0.channel] }
            + [scenario.idle.system, scenario.idle.site]
        if let realNames = RealNames.list {
            for name in names {
                let hits = RealNames.hits(in: name, list: realNames)
                #expect(hits.isEmpty, "\(name) contains \(hits)")
            }
        }
        #expect(names.contains("Riverbend County P25"))
        #expect(names.contains("Lakeview Fire"))
        #expect(Set(scenario.transmissions.map(\.toneHz)).count == scenario.transmissions.count)
    }

    @Test func weatherScenarioDecodes() throws {
        let url = try #require(MockScenario.bundledURL("weather"))
        let scenario = try MockScenario.load(url)
        #expect(scenario == MockScenario.weather)
        #expect(scenario.mode == .weather)
        let first = try #require(scenario.transmissions.first)
        #expect(first.frequencyMHz == 162.425)
        #expect(first.modulation == "FM")
        // Weather audio is continuous, so the channel is active for the whole loop.
        if case .transmission = scenario.moment(at: 0) {} else { Issue.record("weather should start active") }
        if case .transmission = scenario.moment(at: scenario.period * 3 + 1) {} else { Issue.record("weather should stay active") }
    }

    @Test func missingKeysTakeDefaults() throws {
        let json = """
        {"idle": {"system": "S", "site": "T", "frequencyMHz": 851.5, "modulation": "NFM", "rssi": -999},
         "transmissions": [{"at": 1, "duration": 2, "system": "S", "department": "D", "channel": "C",
                            "frequencyMHz": 852, "modulation": "NFM", "rssi": -60, "programmed": true, "toneHz": 500}]}
        """
        let scenario = try MockScenario.decode(Data(json.utf8))
        #expect(scenario.model == "SDS200")
        #expect(scenario.firmware == "1.26.01")
        #expect(scenario.loop)
        #expect(scenario.mode == .trunk)
        try #require(scenario.transmissions.count == 1)
        #expect(scenario.transmissions[0].tgid == nil)
    }

    @Test func timelineLookup() throws {
        let scenario = MockScenario(idle: idle, transmissions: [tx(2, 3, "A"), tx(7, 2, "B"), tx(12, 1, "C")])
        // Loop period: last end (13) plus the leading idle gap (2).
        #expect(scenario.period == 15)
        #expect(scenario.moment(at: 0) == .idle(idle))
        #expect(scenario.moment(at: 2) == .transmission(index: 0, scenario.transmissions[0]))
        #expect(scenario.moment(at: 4.99) == .transmission(index: 0, scenario.transmissions[0]))
        #expect(scenario.moment(at: 5) == .idle(idle))
        #expect(scenario.moment(at: 8) == .transmission(index: 1, scenario.transmissions[1]))
        #expect(scenario.moment(at: 10) == .idle(idle))
        #expect(scenario.moment(at: 12.5) == .transmission(index: 2, scenario.transmissions[2]))
        #expect(scenario.moment(at: 14) == .idle(idle))
        // Wraps.
        #expect(scenario.moment(at: 15 + 8) == .transmission(index: 1, scenario.transmissions[1]))
        #expect(scenario.moment(at: 30 + 1) == .idle(idle))

        var once = scenario
        once.loop = false
        #expect(once.moment(at: 15 + 8) == .idle(idle))
        #expect(once.moment(at: 8) == .transmission(index: 1, scenario.transmissions[1]))
    }

    @Test func rejectsOverlappingTransmissions() throws {
        let overlapping = MockScenario(idle: idle, transmissions: [tx(2, 3, "A"), tx(4, 2, "B")])
        #expect(throws: MockScenarioError.overlapping(first: 0, second: 1)) { try overlapping.validate() }

        let touching = MockScenario(idle: idle, transmissions: [tx(2, 3, "A"), tx(5, 2, "B")])
        #expect(throws: Never.self) { try touching.validate() }

        let badDuration = MockScenario(idle: idle, transmissions: [tx(2, 0, "A")])
        #expect(throws: MockScenarioError.invalidTiming(index: 0)) { try badDuration.validate() }

        // Loading validates too.
        let data = try JSONEncoder().encode(overlapping)
        #expect(throws: MockScenarioError.overlapping(first: 0, second: 1)) { try MockScenario.decode(data) }
    }
}
