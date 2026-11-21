// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// Where a station's line-in audio comes from this run.
public enum LineInSelection: Equatable {
    /// The system's audio inputs (Core Audio, in the shell).
    case system
    /// No audio input is opened or listed; the station logs without audio and says why.
    case disabled(reason: String)
    /// Tests only: the file or pipe `noctule-mock-scanner --line-out` writes, in place of a device.
    case testStream(path: String)
}

/// Which audio input `noctule` and the app may open (line-in design §8): `USBDetection`'s
/// kill-switch also turns audio inputs off, so a run against the mocks never opens the system's.
/// Pure on the environment it is given.
public enum LineInDetection {
    /// Tests only: a path that stands in for the line-in device. Honoured only with the kill-switch
    /// set, and in the app only with a private settings directory too.
    public static let testStreamKey = "NOCTULE_TEST_LINE_IN"
    public static let disabledReason = "audio input disabled by \(USBDetection.disableKey)"

    /// In order: the kill-switch set and a non-empty `testStreamKey` (and, for the app, a private
    /// settings directory) is the test stream; the kill-switch set is disabled; anything else is the
    /// system's inputs (the test variable is ignored without the kill-switch).
    public static func selection(environment: [String: String], privateSettings: Bool, app: Bool) -> LineInSelection {
        guard !USBDetection.isEnabled(environment) else { return .system }
        if let path = testStream(environment, privateSettings: privateSettings, app: app) { return .testStream(path: path) }
        return .disabled(reason: disabledReason)
    }

    /// The `test override: …` notes the shell (and the app) print to stderr: `testStreamKey` when it
    /// replaces the line-in device. Nothing otherwise.
    public static func overrideNotes(_ environment: [String: String], privateSettings: Bool, app: Bool) -> [String] {
        guard let path = testStream(environment, privateSettings: privateSettings, app: app) else { return [] }
        return ["\(testStreamKey)=\(path) (in place of the line-in device)"]
    }

    private static func testStream(_ environment: [String: String], privateSettings: Bool, app: Bool) -> String? {
        guard !USBDetection.isEnabled(environment), !app || privateSettings,
              let path = environment[testStreamKey], !path.isEmpty else { return nil }
        return path
    }
}
