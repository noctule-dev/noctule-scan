// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleAudioPlayback

/// The app's speaker output: `AudioPlayer` (AVAudioEngine) already has `play(_:)`, `stop()` and
/// `volume` with the protocol's meaning. Both types are in this package (so no `@retroactive`);
/// only the app declares this conformance.
extension AudioPlayer: AudioOutput {}
#endif
