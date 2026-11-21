// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import NoctuleAppCore
import NoctuleAudioCapture
import NoctuleKit
import NoctuleStore

/// The app's `SessionEnvironment`: the standard one with the shell's pieces in it (the speaker, the
/// system's serial ports, the system's line-in source and input listing), then the test overrides
/// applied (`applyingOverrides`: the kill-switch swaps the line-in pieces for disabled ones and never
/// asks the system's). Under `NOCTULE_TEST_LINE_IN` the overrides leave only the stream's path
/// (`lineInTestStream`) and the disabled factory; this puts a `PipeLineInSource` on that path in its
/// place, so a test run hears the mock's line-out and never an audio input.
///
/// The pieces are parameters so a test can pass fakes that count their calls; `AppDelegate` passes the
/// real ones (`EngineLineInSource.system`, `CoreAudioInputs`), which nothing else may call.
func appSessionEnvironment(variables: [String: String],
                           makeAudioOutput: @escaping @Sendable () -> any AudioOutput,
                           serialPorts: any SerialPortListing,
                           systemLineIn: @escaping LineInSourceFactory,
                           systemInputs: any AudioInputListing,
                           makeLineInAudioOutput: @escaping @Sendable () -> any AudioOutput)
    -> (environment: SessionEnvironment, notes: [String]) {
    var (environment, notes) = SessionEnvironment.standard(
        makeAudioOutput: makeAudioOutput, serialPorts: serialPorts, lineInSources: systemLineIn,
        audioInputs: systemInputs, makeLineInAudioOutput: makeLineInAudioOutput)
        .applyingOverrides(variables)
    if let path = environment.lineInTestStream {
        environment.lineInSources = { PipeLineInSource(path: path, config: $0) }
    }
    return (environment, notes)
}
