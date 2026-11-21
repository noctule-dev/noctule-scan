// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import NoctuleAppCore
import Observation

/// Whether the Stations window closes itself after a Connect (Plan 5 Task 3).
///
/// Connect (the button, a double-click or the context menu) makes its station the one awaited.
/// The picker feeds every phase change of that station's session to `update`; the first
/// `.connected` answers true, once, and the picker dismisses itself. Only the latest Connect
/// counts, and selecting a different station (or none) cancels the wait, so the window never
/// closes under someone choosing another station. A failure (`.noAnswer`, `.inUse`,
/// `.scannerInUse`, `.stopped`) ends the wait with the picker still open: a later Reconnect from
/// the station window doesn't close it. No session yet, `.idle`, `.waitingForCooldown`,
/// `.waitingForScanner` (a USB station opened before its scanner was plugged in), `.connecting`
/// and `.stopping` (a previous session still closing after a Disconnect) keep waiting. A session that goes away once it was there (its window closed, for example while it
/// waited out the cooldown) cancels the wait. A sheet or alert up in the picker cancels it too
/// (`cancel()`), so it never closes under an edit.
@MainActor @Observable
final class PickerAutoClose {
    /// The station whose connect would close the picker, if any.
    private(set) var awaiting: UUID?
    /// The awaited station has had a session since the Connect.
    @ObservationIgnored private var sawSession = false

    func connectRequested(_ id: UUID) {
        awaiting = id
        sawSession = false
    }

    func selectionChanged(_ id: UUID?) {
        if id != awaiting { awaiting = nil }
    }

    func cancel() {
        awaiting = nil
    }

    /// The phase of `station`'s session (nil: none open, before or after). True when the picker
    /// should close.
    func update(station: UUID, phase: SessionPhase?) -> Bool {
        guard let awaiting, station == awaiting else { return false }
        guard let phase else {
            if sawSession { self.awaiting = nil }
            return false
        }
        sawSession = true
        switch phase {
        case .connected:
            self.awaiting = nil
            return true
        case .noAnswer, .inUse, .scannerInUse, .stopped:
            self.awaiting = nil
            return false
        case .idle, .waitingForCooldown, .waitingForScanner, .connecting, .stopping:
            return false
        }
    }
}

/// The station windows showing a station, by a per-window key, so closing the last one brings
/// the Stations window back (the red button, ⌘W, Disconnect, or the window closing because its
/// station was deleted), but not while the app is quitting (`isQuitting`): a quit stops every
/// session, which closes their windows. A window counts only once it shows a station (it opened
/// the station's session); one with no station, or whose station no longer exists, never does.
@MainActor
final class StationWindowTracker {
    private var showingKeys: Set<UUID> = []
    private let isQuitting: @MainActor () -> Bool

    init(isQuitting: @escaping @MainActor () -> Bool) {
        self.isQuitting = isQuitting
    }

    var openWindows: Int { showingKeys.count }

    /// The window `key` shows a station. Idempotent.
    func showing(_ key: UUID) {
        showingKeys.insert(key)
    }

    /// The window `key` went away. True when the picker should open: it was showing a station, it
    /// was the last such window, and the app isn't quitting.
    func closed(_ key: UUID) -> Bool {
        guard showingKeys.remove(key) != nil else { return false }
        return showingKeys.isEmpty && !isQuitting()
    }
}

/// The status bar's Stations and Disconnect buttons.
enum StationFooterText {
    static let stationsSymbol = "list.bullet"
    static let stationsHelp = "Show the Stations window"
    static let disconnectSymbol = "eject"
    static let disconnectHelp = "Disconnect and show the Stations window"
}
#endif
