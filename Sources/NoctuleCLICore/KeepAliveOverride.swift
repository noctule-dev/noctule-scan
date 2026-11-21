// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleStore

/// The push keep-alive the `noctule` shell passes (`watch`'s choice; `log`'s goes through
/// `StationRunner`), and its one test-only override.
///
/// `NOCTULE_TEST_KEEPALIVE_SECONDS` (tests against the mock only; **never set it against a real
/// scanner**): a number of seconds from 0.05 to 60 that replaces the interval of a keep-alive the
/// model already has (the SDS150's 60 s), so a test can run past the mock's shortened push lifetime
/// in seconds. It can't make `noctule` send a keep-alive to a model without one, and it does
/// nothing on a network scanner. It applies only while the USB detection kill-switch
/// (`USBDetection.disableKey`) is set, so it can never shorten the keep-alive of a port the CLI
/// found by itself (on the development Mac, the owner's real SDS150); without it, it is named and
/// ignored. Like `USBDetection.testPortsKey`, it is announced on stderr when in effect (`notes`);
/// a value it can't use is named and ignored.
public enum KeepAliveOverride {
    public static let key = "NOCTULE_TEST_KEEPALIVE_SECONDS"
    /// The accepted range, in seconds: `PushKeepAlive.overrideRange` (0.05 to 60), which
    /// `forSubscription` applies again. Checked as a number before any `Duration` is made, so
    /// `inf`, `nan` and `1e300` are refused rather than converted.
    static let range = (PushKeepAlive.overrideRange.lowerBound / .seconds(1))
        ... (PushKeepAlive.overrideRange.upperBound / .seconds(1))

    /// The override's interval; nil when unset, empty, not a number of seconds in `range`, or set
    /// while the kill-switch isn't.
    public static func interval(_ environment: [String: String]) -> Duration? {
        guard !USBDetection.isEnabled(environment) else { return nil }
        guard let text = environment[key], let seconds = Double(text), range.contains(seconds) else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    /// The `noctule: test override: …` notes the shell prints to stderr (none when unset or empty).
    public static func notes(_ environment: [String: String]) -> [String] {
        guard let text = environment[key], !text.isEmpty else { return [] }
        guard !USBDetection.isEnabled(environment) else {
            return ["ignoring \(key)=\(text) (it needs \(USBDetection.disableKey) set)"]
        }
        guard interval(environment) != nil else {
            return ["ignoring \(key)=\(text) (not a number of seconds from 0.05 to 60)"]
        }
        return ["\(key)=\(text) (in place of the model's keep-alive interval; "
            + "a model without a keep-alive, or a network scanner, still gets none)"]
    }

    /// The keep-alive `watch` passes to `startPush`: the keep-alive of the model `MDL` reported,
    /// only when `invocation` talks to a serial port (`--serial`), with the override's interval
    /// when it is in effect.
    public static func forWatch(reportedModel: String, invocation: CLIInvocation,
                                environment: [String: String]) -> PushKeepAlive? {
        PushKeepAlive.forSubscription(reportedModel: reportedModel, overSerial: invocation.serial != nil,
                                      interval: interval(environment))
    }
}
