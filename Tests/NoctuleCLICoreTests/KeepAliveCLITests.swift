// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleStore
@testable import NoctuleCLICore

// The push keep-alive `watch` passes, and the test-only `NOCTULE_TEST_KEEPALIVE_SECONDS`.

@Suite struct KeepAliveOverrideTests {
    private let key = "NOCTULE_TEST_KEEPALIVE_SECONDS"

    @Test func keyName() {
        #expect(KeepAliveOverride.key == key)
    }

    /// The kill-switch, which the override needs.
    private let killSwitch = [USBDetection.disableKey: "1"]

    /// `environment` with the kill-switch set.
    private func with(_ environment: [String: String]) -> [String: String] {
        environment.merging(killSwitch) { _, new in new }
    }

    @Test func interval() {
        #expect(KeepAliveOverride.interval(with([:])) == nil)
        #expect(KeepAliveOverride.interval(with([key: ""])) == nil)
        #expect(KeepAliveOverride.interval(with([key: "0.5"])) == .milliseconds(500))
        #expect(KeepAliveOverride.interval(with([key: "2"])) == .seconds(2))
        // 0.05 to 60 s: enough for every test, and no setting that floods the port or, past
        // 183 s, turns the keep-alive off in effect.
        #expect(KeepAliveOverride.interval(with([key: "0.05"])) == .milliseconds(50))
        #expect(KeepAliveOverride.interval(with([key: "60"])) == .seconds(60))
        for bad in ["0", "-1", "abc", "inf", "nan", "0.001", "0.049", "60.1", "61", "184", "3600", "1e300", " 1", "1s"] {
            #expect(KeepAliveOverride.interval(with([key: bad])) == nil, "\(bad)")
        }
    }

    /// The override applies only while USB detection is off, so it can never shorten the
    /// keep-alive of a port the CLI found by itself (which, on the development Mac, is the real
    /// SDS150); without the kill-switch it is named and ignored, and the model's interval stays.
    @Test func overrideNeedsTheKillSwitch() throws {
        #expect(KeepAliveOverride.interval([key: "1"]) == nil)
        #expect(KeepAliveOverride.interval([key: "1", USBDetection.disableKey: ""]) == nil)
        #expect(KeepAliveOverride.interval([key: "1", USBDetection.disableKey: "1"]) == .seconds(1))
        let needs = ["ignoring NOCTULE_TEST_KEEPALIVE_SECONDS=1 (it needs NOCTULE_NO_USB_DETECTION set)"]
        #expect(KeepAliveOverride.notes([key: "1"]) == needs)
        #expect(KeepAliveOverride.notes([key: "1", USBDetection.disableKey: ""]) == needs)
        #expect(KeepAliveOverride.notes([key: "abc"]) == [
            "ignoring NOCTULE_TEST_KEEPALIVE_SECONDS=abc (it needs NOCTULE_NO_USB_DETECTION set)",
        ])
        #expect(KeepAliveOverride.notes([:]) == [])
        let serial = try CLIArguments.parse(["watch", "--serial", "/tmp/mock-port"])
        #expect(KeepAliveOverride.forWatch(reportedModel: "SDS150", invocation: serial, environment: [key: "1"])
                == ModelProfile.profile(for: .sds150).pushKeepAlive)
    }

    /// Announced when in effect, as `NOCTULE_TEST_SERIAL_PORTS` is; a value it can't use is
    /// named and ignored; unset or empty says nothing.
    @Test func notes() {
        #expect(KeepAliveOverride.notes(with([key: "0.4"])) == [
            "NOCTULE_TEST_KEEPALIVE_SECONDS=0.4 (in place of the model's keep-alive interval; "
                + "a model without a keep-alive, or a network scanner, still gets none)",
        ])
        #expect(KeepAliveOverride.notes(with([key: "abc"])) == [
            "ignoring NOCTULE_TEST_KEEPALIVE_SECONDS=abc (not a number of seconds from 0.05 to 60)",
        ])
        #expect(KeepAliveOverride.notes(with([key: "0.001"])) == [
            "ignoring NOCTULE_TEST_KEEPALIVE_SECONDS=0.001 (not a number of seconds from 0.05 to 60)",
        ])
        #expect(KeepAliveOverride.notes(with([key: ""])) == [])
        #expect(KeepAliveOverride.notes(with([:])) == [])
        #expect(KeepAliveOverride.notes([key: ""]) == [])
    }

    /// `watch`'s choice: the model's keep-alive (from its `MDL`), only when the invocation uses
    /// `--serial`, with the override's interval.
    @Test func forWatch() throws {
        let kal = ModelProfile.profile(for: .sds150).pushKeepAlive
        #expect(kal != nil)
        let serial = try CLIArguments.parse(["watch", "--serial", "/tmp/mock-port"])
        let bareSerial = try CLIArguments.parse(["watch", "--serial"])
        let network = try CLIArguments.parse(["watch", "--host", "127.0.0.1"])
        let configured = try CLIArguments.parse(["watch"])
        #expect(KeepAliveOverride.forWatch(reportedModel: "SDS150", invocation: serial, environment: [:]) == kal)
        #expect(KeepAliveOverride.forWatch(reportedModel: "SDS150", invocation: bareSerial, environment: [:]) == kal)
        #expect(KeepAliveOverride.forWatch(reportedModel: "SDS150", invocation: serial, environment: with([key: "0.4"]))
                == PushKeepAlive(command: "KAL", interval: .milliseconds(400)))
        #expect(KeepAliveOverride.forWatch(reportedModel: "SDS150", invocation: serial, environment: with([key: "x"])) == kal)
        // The SDS100 renews its own PSI (never a command), over serial only.
        let renewal = PushKeepAlive(action: .renewSubscription, interval: .seconds(60))
        #expect(KeepAliveOverride.forWatch(reportedModel: "SDS100", invocation: serial, environment: [:]) == renewal)
        #expect(KeepAliveOverride.forWatch(reportedModel: "SDS100", invocation: serial, environment: with([key: "0.4"]))
                == PushKeepAlive(action: .renewSubscription, interval: .milliseconds(400)))
        #expect(KeepAliveOverride.forWatch(reportedModel: "SDS100", invocation: network, environment: [:]) == nil)
        #expect(KeepAliveOverride.forWatch(reportedModel: "SDS100", invocation: configured, environment: with([key: "0.4"])) == nil)
        // A network scanner (even one that says SDS150), or a model without one: none.
        for environment in [[:], with([key: "0.4"])] {
            for invocation in [network, configured] {
                #expect(KeepAliveOverride.forWatch(reportedModel: "SDS150", invocation: invocation, environment: environment) == nil)
                #expect(KeepAliveOverride.forWatch(reportedModel: "SDS200", invocation: invocation, environment: environment) == nil)
            }
            for reported in ["SDS200", "BCD436HP", "Mystery"] {
                #expect(KeepAliveOverride.forWatch(reportedModel: reported, invocation: serial, environment: environment) == nil)
            }
        }
    }
}
