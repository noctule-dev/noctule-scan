// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import NoctuleAppCore
import Testing
@testable import NoctuleScan

/// Plan 5 Task 3: the Stations window closes itself after a successful Connect (`PickerAutoClose`),
/// closing the last station window brings it back (`StationWindowTracker`), and the status bar's
/// Stations and Disconnect buttons (`StationFooterText`).
@MainActor @Suite struct StationFlowTests {
    private let a = UUID()
    private let b = UUID()
    private let connected = SessionPhase.connected(model: "SDS200", firmware: "1.26.01")

    // MARK: PickerAutoClose

    @Test func closesOnceTheConnectedStationConnects() {
        let rule = PickerAutoClose()
        #expect(!rule.update(station: a, phase: connected), "nothing was connected from the picker")
        rule.connectRequested(a)
        #expect(rule.awaiting == a)
        #expect(!rule.update(station: a, phase: nil), "its window hasn't opened the session yet")
        #expect(!rule.update(station: a, phase: .idle))
        #expect(!rule.update(station: a, phase: .waitingForCooldown(secondsLeft: 12)))
        #expect(!rule.update(station: a, phase: .connecting))
        #expect(rule.update(station: a, phase: connected))
        #expect(rule.awaiting == nil)
        #expect(!rule.update(station: a, phase: connected), "only once per Connect")
    }

    @Test func anAlreadyConnectedStationClosesAtOnce() {
        let rule = PickerAutoClose()
        rule.connectRequested(a)
        #expect(rule.update(station: a, phase: connected))
    }

    @Test func theLatestConnectWins() {
        let rule = PickerAutoClose()
        rule.connectRequested(a)
        rule.connectRequested(b)
        #expect(!rule.update(station: a, phase: connected), "the earlier connect no longer counts")
        #expect(rule.awaiting == b)
        #expect(rule.update(station: b, phase: connected))
    }

    @Test func selectingAnotherStationCancels() {
        let rule = PickerAutoClose()
        rule.connectRequested(a)
        rule.selectionChanged(a)
        #expect(rule.awaiting == a, "selecting the same station keeps waiting")
        rule.selectionChanged(b)
        #expect(rule.awaiting == nil)
        #expect(!rule.update(station: a, phase: connected))
        rule.connectRequested(a)
        rule.selectionChanged(nil)
        #expect(rule.awaiting == nil, "clearing the selection cancels too")
        rule.connectRequested(a)
        rule.cancel()
        #expect(!rule.update(station: a, phase: connected), "a sheet or alert in the picker cancels")
    }

    @Test func aFailedConnectKeepsThePickerOpen() {
        let failures: [SessionPhase] = [.noAnswer("No answer from 127.0.0.1:1."), .inUse(pid: 4242),
                                        .scannerInUse(byStation: "Other Station"), .stopped]
        for failure in failures {
            let rule = PickerAutoClose()
            rule.connectRequested(a)
            #expect(!rule.update(station: a, phase: .connecting))
            #expect(!rule.update(station: a, phase: failure), "\(failure)")
            #expect(rule.awaiting == nil, "a failure ends the wait: \(failure)")
            #expect(!rule.update(station: a, phase: connected), "a later Reconnect doesn't close it: \(failure)")
        }
    }

    @Test func aStoppingSessionKeepsWaiting() {
        // Disconnect then a quick Connect: the old session is still stopping when the new one is asked for.
        let rule = PickerAutoClose()
        rule.connectRequested(a)
        #expect(!rule.update(station: a, phase: .stopping))
        #expect(rule.awaiting == a)
        #expect(rule.update(station: a, phase: connected))
    }

    @Test func aUSBStationWaitingForItsScannerKeepsWaiting() {
        // The station opened before the scanner was plugged in: the picker closes when it connects.
        let rule = PickerAutoClose()
        rule.connectRequested(a)
        #expect(!rule.update(station: a, phase: .connecting))
        #expect(!rule.update(station: a, phase: .waitingForScanner(hint: "Plug the scanner in and choose Serial Port on its screen.")))
        #expect(rule.awaiting == a)
        #expect(rule.update(station: a, phase: .connected(model: "SDS150", firmware: "1.01.02")))
    }

    @Test func aSessionThatGoesAwayCancels() {
        // The station's window closed (its session released) while it waited out the cooldown.
        let rule = PickerAutoClose()
        rule.connectRequested(a)
        #expect(!rule.update(station: a, phase: nil), "not open yet: keep waiting")
        #expect(rule.awaiting == a)
        #expect(!rule.update(station: a, phase: .waitingForCooldown(secondsLeft: 90)))
        #expect(!rule.update(station: a, phase: nil), "the session went away")
        #expect(rule.awaiting == nil)
        #expect(!rule.update(station: a, phase: connected), "a later open elsewhere doesn't close the picker")

        // A new Connect starts afresh: no session yet is waiting again, not a cancel.
        rule.connectRequested(a)
        #expect(!rule.update(station: a, phase: nil))
        #expect(rule.awaiting == a)
        #expect(rule.update(station: a, phase: connected))
    }

    // MARK: StationWindowTracker

    @Test func closingTheLastStationWindowOpensThePicker() {
        var quitting = false
        let tracker = StationWindowTracker(isQuitting: { quitting })
        let w1 = UUID(), w2 = UUID()
        tracker.showing(w1)
        tracker.showing(w2)
        tracker.showing(w1)
        #expect(tracker.openWindows == 2, "a window counts once")
        #expect(!tracker.closed(w1), "another station window is still open")
        #expect(tracker.closed(w2), "the last one")
        #expect(tracker.openWindows == 0)
        #expect(!tracker.closed(w2), "closing twice never reopens")
        #expect(tracker.openWindows == 0)

        tracker.showing(w1)
        quitting = true
        #expect(!tracker.closed(w1), "not while the app is quitting")
    }

    @Test func windowsWithoutAStationDontCount() {
        let tracker = StationWindowTracker(isQuitting: { false })
        let shown = UUID(), empty = UUID()
        #expect(!tracker.closed(empty), "a window that never showed a station")
        tracker.showing(shown)
        #expect(!tracker.closed(empty))
        #expect(tracker.openWindows == 1, "an empty window's close doesn't take a station window's count")
        #expect(tracker.closed(shown))
    }

    // MARK: Footer

    @Test func footerCopy() {
        #expect(StationFooterText.stationsHelp == "Show the Stations window")
        #expect(StationFooterText.disconnectHelp == "Disconnect and show the Stations window")
        #expect(StationFooterText.stationsSymbol == "list.bullet")
        #expect(StationFooterText.disconnectSymbol == "eject")
    }
}
#endif
