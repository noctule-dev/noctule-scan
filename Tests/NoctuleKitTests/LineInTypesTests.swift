// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

@Suite(.timeLimit(.minutes(1))) struct LineInTypesTests {
    @Test func disabledSourceReportsItsReason() async {
        let source = DisabledLineInSource(reason: "audio input disabled by NOCTULE_NO_USB_DETECTION")
        await source.start()
        var states: [LineInState] = []
        for await state in source.states {
            states.append(state)
            break
        }
        #expect(states == [.failed("audio input disabled by NOCTULE_NO_USB_DETECTION")])
        await source.stop()
        var chunks = 0
        for await _ in source.chunks { chunks += 1 }
        var levels = 0
        for await _ in source.levels { levels += 1 }
        #expect(chunks == 0 && levels == 0)
        var rest: [LineInState] = []
        for await state in source.states { rest.append(state) }
        #expect(rest.isEmpty)
    }

    @Test func fixedListingReturnsItsInputs() {
        let mic = AudioInputDevice(uid: "UID-1", name: "Fictional Interface", channelCount: 2)
        #expect(FixedAudioInputListing(inputs: [mic]).inputs() == [mic])
        #expect(FixedAudioInputListing.empty.inputs().isEmpty)
        #expect(mic.id == "UID-1")
    }

    @Test func channelRawValuesAreTheSavedWords() {
        #expect(LineInChannel.allCases.map(\.rawValue) == ["left", "right", "both"])
    }
}
