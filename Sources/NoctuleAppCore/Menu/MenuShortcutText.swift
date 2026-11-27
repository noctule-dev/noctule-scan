// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import NoctuleKit

/// What the Scanner view says when a Services or Range walk (`StationSession.startMenuShortcut`)
/// fails (services-range design §5.4 "Feedback"). The destination's name comes from the shortcut,
/// never from `MenuActionError.walkStopped`'s `expected`, which is the screen needed at the step
/// that failed.
public enum MenuShortcutText {
    /// The screen a shortcut opens, as `MenuPath.serviceTypes` and `MenuPath.range` name it. A
    /// constant, so a model with no path for the shortcut still has a name to say.
    public static func destination(of shortcut: MenuShortcut) -> String {
        switch shortcut {
        case .serviceTypes: "Select Service Types"
        case .range: "Set Range"
        }
    }

    /// The message for a walk that failed with `error`; nil for `.busy` (the keypad is disabled
    /// while a walk runs, and a press refused for queued keys needs no words).
    public static func message(for error: MenuActionError, shortcut: MenuShortcut) -> String? {
        let destination = destination(of: shortcut)
        switch error {
        case .busy:
            return nil
        case .alreadyInMenu:
            return "Already in a menu. Exit it first."
        case .functionPending:
            return "Func is on. Press a key to clear it first."
        case .walkStopped(_, let found?):
            return "Couldn't open \(destination): the scanner showed \(found)."
        case .walkStopped(_, nil):
            return "Couldn't open \(destination): the scanner didn't show the expected screen."
        case .noAnswer:
            return "Couldn't open \(destination): the scanner didn't answer."
        case .rejected:
            return "Couldn't open \(destination): the scanner refused a step."
        case .notConnected, .notInMenu, .menuChanged, .needsConfirmation, .invalidValue:
            return "Couldn't open \(destination)."
        }
    }
}
