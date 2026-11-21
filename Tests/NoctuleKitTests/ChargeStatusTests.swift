// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
@testable import NoctuleKit

@Suite struct ChargeStatusTests {
    @Test func chargeStatusSpecExample() throws {
        let s = try ChargeStatus(fields: ["CST=4", "VOLT=4184mV:100%", "CURR=0000mA", "TEMP= 27.65C"])
        #expect(s.state == .full)
        #expect(s.millivolts == 4184)
        #expect(s.percent == 100)
        #expect(s.milliamps == 0)
        #expect(s.celsius == 27.65)
    }

    @Test func chargeStatusDischarging() throws {
        let s = try ChargeStatus(fields: ["CST=0", "VOLT=3712mV:48%", "CURR=-0123mA", "TEMP=31.50C"])
        #expect(s.state == .notCharging)
        #expect(s.milliamps == -123)
        #expect(s.millivolts == 3712)
        #expect(s.percent == 48)
        #expect(s.celsius == 31.5)

        let out = try ChargeStatus(fields: ["CST=9", "VOLT=4184mV:100%", "CURR=0000mA", "TEMP=27.65C"])
        #expect(out.state == nil)
        let negative = try ChargeStatus(fields: ["CST=-1", "VOLT=4184mV:100%", "CURR=0000mA", "TEMP=27.65C"])
        #expect(negative.state == nil)
    }

    /// The raw `CST` code is kept, known or not.
    @Test func chargeStatusKeepsTheCode() throws {
        for code in [-1, 0, 4, 6, 7, 9, 12] {
            let s = try ChargeStatus(fields: ["CST=\(code)", "VOLT=4184mV:100%", "CURR=0000mA", "TEMP=27.65C"])
            #expect(s.stateCode == code)
            #expect(s.state == ChargeStatus.State(rawValue: code))
        }
        #expect(try ChargeStatus(fields: ["CST= 7", "VOLT=4184mV:100%", "CURR=0000mA", "TEMP=27.65C"]).stateCode == 7)
    }

    @Test func chargeStatusStatesMapByCode() throws {
        let expected: [ChargeStatus.State] =
            [.notCharging, .initializing, .temperatureFault, .powerFault, .full, .recharge, .charging]
        for (code, state) in expected.enumerated() {
            let s = try ChargeStatus(fields: ["CST=\(code)", "VOLT=4000mV:80%", "CURR=0500mA", "TEMP=20.00C"])
            #expect(s.state == state, "CST=\(code)")
        }
    }

    @Test func chargeStatusChargingAndColdTemperature() throws {
        let s = try ChargeStatus(fields: ["CST=6", "VOLT=3900mV:70%", "CURR=0850mA", "TEMP=-5.25C"])
        #expect(s.state == .charging)
        #expect(s.milliamps == 850)
        #expect(s.celsius == -5.25)
    }

    @Test func chargeStatusAcceptsFieldsInAnyOrderAndIgnoresExtras() throws {
        let s = try ChargeStatus(fields: ["TEMP= 27.65C", "EXTRA=1", "CURR=0000mA", "VOLT=4184mV:100%", "CST=4"])
        #expect(s.state == .full)
        #expect(s.millivolts == 4184)
        #expect(s.celsius == 27.65)
    }

    @Test func chargeStatusMalformed() {
        let cases: [[String]] = [
            ["CST=4"],
            ["CST=x", "VOLT=?", "CURR=", "TEMP="],
            ["CST=x", "VOLT=4184mV:100%", "CURR=0000mA", "TEMP=27.65C"],   // non-numeric state
            ["VOLT=4184mV:100%", "CURR=0000mA", "TEMP=27.65C"],            // no CST
            ["CST=4", "CURR=0000mA", "TEMP=27.65C"],                       // no VOLT
            ["CST=4", "VOLT=4184mV:100%", "TEMP=27.65C"],                  // no CURR
            ["CST=4", "VOLT=4184mV:100%", "CURR=0000mA"],                  // no TEMP
            ["CST=4", "VOLT=4184mV", "CURR=0000mA", "TEMP=27.65C"],        // no percent
            ["CST=4", "VOLT=4184:100%", "CURR=0000mA", "TEMP=27.65C"],     // no mV unit
            ["CST=4", "VOLT=4184mV:100%", "CURR=0000", "TEMP=27.65C"],     // no mA unit
            ["CST=4", "VOLT=4184mV:100%", "CURR=0000mA", "TEMP=27.65"],    // no C unit
            [],
        ]
        for fields in cases {
            #expect(throws: ChargeStatusError.self, "\(fields)") { _ = try ChargeStatus(fields: fields) }
        }
    }
}
