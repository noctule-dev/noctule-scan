// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import Foundation
import NoctuleAppCore
import NoctuleKit
import Testing
@testable import NoctuleScan

/// Task 12 QA minors: the problem banner after a failed restart and for a station in use, and a
/// disabled knob.
@MainActor @Suite(.timeLimit(.minutes(3))) struct ProblemBannerTests {
    // MARK: Problem banner (Task 12 QA minors 1 and 2)

    private func banner(phase: SessionPhase = .connected(model: "SDS200", firmware: "1.26.01"),
                        audio: AudioSessionState = .streaming, hint: RestartHint? = nil,
                        failure: RestartOutcome? = nil, restarting: Bool = false) -> ProblemBannerContent? {
        ProblemBannerContent.make(phase: phase, audio: audio, restartHint: hint, lastRestartFailure: failure,
                                  isRestarting: restarting, stationName: "Test Station")
    }

    @Test func bannerOffersRestartOnlyWhileControlAnswers() throws {
        #expect(banner() == nil)
        let canRestart = try #require(banner(audio: .failed("x"), hint: .canRestart))
        #expect(canRestart.title == "Scanner audio isn't responding")
        #expect(canRestart.offersRestart && canRestart.retryTitle == "Reconnect")
        let powerCycle = try #require(banner(audio: .failed("x"), hint: .powerCycleNeeded))
        #expect(!powerCycle.offersRestart)
        let restarting = try #require(banner(audio: .stopped, restarting: true))
        #expect(restarting.restarting && restarting.retryTitle == nil && !restarting.offersRestart)
        #expect(restarting.title == "Restarting scanner…")
    }

    @Test func failedRestartOffersOnlyReconnect() throws {
        let gone = try #require(banner(phase: .stopped, audio: .failed("x"), hint: .canRestart, failure: .didNotComeBack))
        #expect(gone.title == "Scanner audio isn't responding")
        #expect(gone.detail == "The scanner didn't come back after the restart. Power-cycle it.")
        #expect(!gone.offersRestart)
        #expect(gone.retryTitle == "Reconnect")
        let refused = try #require(banner(phase: .stopped, audio: .failed("x"), hint: .canRestart,
                                          failure: .notAccepted("ERR")))
        #expect(!refused.offersRestart)
        #expect(refused.detail?.contains("ERR") == true)
    }

    @Test func inUseOffersTryAgain() throws {
        let inUse = try #require(banner(phase: .inUse(pid: 4242), audio: .idle))
        #expect(inUse.title == "Test Station is open in another Noctule Scan process (pid 4242).")
        #expect(inUse.retryTitle == "Try Again")
        #expect(!inUse.offersRestart)
        let sameScanner = try #require(banner(phase: .scannerInUse(byStation: "Other Station"), audio: .idle))
        #expect(sameScanner.title == "Other Station is already connected to this scanner.")
        #expect(sameScanner.retryTitle == "Try Again")
        #expect(!sameScanner.offersRestart)
        let noAnswer = try #require(banner(phase: .noAnswer("No answer from 127.0.0.1:1."), audio: .idle))
        #expect(noAnswer.detail == "No answer from 127.0.0.1:1.")
        #expect(noAnswer.retryTitle == "Reconnect")
    }

    // MARK: A USB station (Plan 8 Task 9; SDS150 design §7.2)

    /// While a USB station waits for its scanner, the banner says so with the hint and offers only
    /// Stations (which ends the wait: the window's disconnect).
    @Test func waitingForTheScannerOffersStations() throws {
        let waiting = try #require(banner(phase: .waitingForScanner(hint: SerialPort.noneFoundHint), audio: .idle))
        #expect(waiting == ProblemBannerContent(title: "Waiting for the scanner", detail: SerialPort.noneFoundHint,
                                                retryTitle: nil, offersStations: true))
        #expect(waiting.offersRestart == false)
        #expect(!waiting.restarting)
    }

    @Test func usbNoAnswerOffersReconnectOnly() throws {
        let noAnswer = try #require(banner(phase: .noAnswer(SerialPort.notSendingUpdatesHint), audio: .idle))
        #expect(noAnswer.title == "Can't reach the scanner")
        #expect(noAnswer.detail == SerialPort.notSendingUpdatesHint)
        #expect(noAnswer.retryTitle == "Reconnect")
        #expect(!noAnswer.offersRestart)
        #expect(!noAnswer.offersStations)
    }

    // MARK: Knob (Task 12 QA minor 4)

    /// Records the cursor rects the knob asks for.
    final class CursorProbe: KnobInput.InputView {
        var cursorRects = 0
        override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) { cursorRects += 1 }
    }

    @Test func disabledKnobIgnoresClicksAndScrolls() throws {
        var pushes = 0
        var steps = 0
        let view = CursorProbe(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        view.onPush = { pushes += 1 }
        view.onSteps = { steps += $0 }
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        /// A mouse-wheel notch up (line units: one step when enabled). The deltas are set by hand:
        /// `CGEvent(scrollWheelEvent2Source:)` sometimes comes back with all-zero deltas for a
        /// fraction of a second (system state outside the test; LESSONS 2026-11-09), and a
        /// zero-delta wheel event turns nothing.
        func wheel() throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3,
                                          wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 3)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 30)
            let event = try #require(NSEvent(cgEvent: cg))
            try #require(event.scrollingDeltaY == 3 && !event.hasPreciseScrollingDeltas
                         && !event.isDirectionInvertedFromDevice && event.phase == [] && event.momentumPhase == [])
            return event
        }
        /// A drag 40 points up (five steps when enabled).
        func drag() throws -> NSEvent {
            let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                          mouseCursorPosition: .zero, mouseButton: .left))
            cg.setIntegerValueField(.mouseEventDeltaX, value: 0)
            cg.setIntegerValueField(.mouseEventDeltaY, value: -40)
            let event = try #require(NSEvent(cgEvent: cg))
            try #require(event.deltaY == -40 && event.deltaX == 0)
            return event
        }

        view.enabled = false
        view.mouseDown(with: try mouse(.leftMouseDown))
        view.mouseUp(with: try mouse(.leftMouseUp))
        view.scrollWheel(with: try wheel())
        view.mouseDown(with: try mouse(.leftMouseDown))
        view.mouseDragged(with: try drag())
        view.mouseUp(with: try mouse(.leftMouseUp))
        view.resetCursorRects()
        #expect(pushes == 0, "no push")
        #expect(steps == 0, "no turn")
        #expect(view.cursorRects == 0, "no pointing-hand cursor")

        view.enabled = true
        view.mouseDown(with: try mouse(.leftMouseDown))
        view.mouseUp(with: try mouse(.leftMouseUp))
        #expect(pushes == 1)
        view.scrollWheel(with: try wheel())
        #expect(steps == 1, "one notch, one step")
        view.mouseDown(with: try mouse(.leftMouseDown))
        view.mouseDragged(with: try drag())
        view.mouseUp(with: try mouse(.leftMouseUp))
        #expect(steps == 6, "40 points up: five more steps")
        #expect(pushes == 1, "a drag isn't a push")
        view.resetCursorRects()
        #expect(view.cursorRects == 1)
    }
}
#endif
