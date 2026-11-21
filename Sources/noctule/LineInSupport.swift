// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleAudioCapture
import NoctuleKit
import NoctuleStore

// The shell's line-in pieces (Plan 19; line-in design §8): which audio input a run may open, the
// source factory for it and the input listing. The decision is `LineInDetection`'s, on the
// environment; this file only builds what it chose. Only the `.system` case reaches Core Audio
// (and the microphone permission request), so nothing under the kill-switch ever does.

enum LineInSupport {
    /// `noctule` has no private settings directory of its own (`--settings-dir` is a station
    /// option, not a sandbox), and is not the app.
    static func selection(environment: [String: String]) -> LineInSelection {
        LineInDetection.selection(environment: environment, privateSettings: false, app: false)
    }

    /// The factory a `StationRunner` or `listen` opens its line-in with.
    static func factory(for selection: LineInSelection) -> LineInSourceFactory {
        switch selection {
        case .system:
            return { EngineLineInSource.system($0) }
        case .disabled(let reason):
            return { _ in DisabledLineInSource(reason: reason) }
        case .testStream(let path):
            return { PipeLineInSource(path: path, config: $0) }
        }
    }

    /// The inputs `audio-inputs` lists and a station's `--audio-input` name is matched against: the
    /// system's, or none (the kill-switch, and the test stream, which stands in for a device and
    /// has no list of its own).
    static func listing(for selection: LineInSelection) -> any AudioInputListing {
        switch selection {
        case .system: CoreAudioInputs()
        case .disabled, .testStream: FixedAudioInputListing.empty
        }
    }
}
