// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI

/// The key map editor in Settings › Stations: a row per front-panel key with its label and the
/// chord in force, conflicts in red with the other keys named, and "Reset to Model Defaults".
///
/// Each chord is a recorder field: click it and press a chord. Esc cancels, Delete (⌫ or ⌦) clears
/// the override (back to the model's default), and a chord that is a menu shortcut (⌘Q, ⌘W, ⌘,)
/// is left to the menu. While recording, a local key-down monitor consumes the keys of this
/// window only; the scanner windows' monitors act only on their own windows, so nothing reaches
/// the scanner. Every change is saved at once and applied to an open session without a restart.
struct KeyMapEditor: View {
    let rows: [KeyMapEditing.Row]
    let set: (FrontPanelKey, KeyChord?) -> Void
    let reset: () -> Void

    @State private var recorder = ChordRecorderMonitor()

    var body: some View {
        ForEach(rows) { row in
            KeyMapRow(row: row, recording: recorder.recordingKey == row.key) {
                if recorder.recordingKey == row.key { recorder.stop() } else { start(row.key) }
            }
        }
        HStack {
            Text("Click a shortcut and press new keys. Esc cancels; Delete returns the key to its default.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset to Model Defaults") {
                recorder.stop()
                reset()
            }
            .disabled(!rows.contains { $0.isOverridden })
        }
        .onDisappear { recorder.stop() }
    }

    private func start(_ key: FrontPanelKey) {
        recorder.start(key) { key, chord in set(key, chord) }
    }
}

private struct KeyMapRow: View {
    let row: KeyMapEditing.Row
    let recording: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(KeyLabels.name(row.key))
                if !row.conflicts.isEmpty {
                    Text(KeyLabels.conflictText(row.conflicts))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if row.isOverridden {
                Text("Custom").font(.caption).foregroundStyle(.secondary)
            }
            ChordField(text: row.chord ?? "None", recording: recording, conflict: !row.conflicts.isEmpty,
                       action: toggle)
        }
    }
}

/// The clickable chord ("⌘4"), or "Type a shortcut…" while recording.
private struct ChordField: View {
    let text: String
    let recording: Bool
    let conflict: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(recording ? "Type a shortcut…" : text)
                .font(recording ? .callout : .body.monospaced())
                .foregroundStyle(recording ? Color.secondary : (conflict ? Color.red : Color.primary))
                .frame(width: 130, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(recording ? Color.accentColor.opacity(0.12) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(recording ? Color.accentColor : (conflict ? Color.red : Color.secondary.opacity(0.4)),
                                  lineWidth: recording ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Press a key or chord; Esc cancels, Delete returns to the default" : "Click to change")
    }
}

/// The front-panel names the editor shows.
enum KeyLabels {
    static func name(_ key: FrontPanelKey) -> String {
        switch key {
        case .menu: "Menu"
        case .function: "Func"
        case .avoid: "Avoid"
        case .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9: key.rawValue
        case .dotNo: ". / No"
        case .enterYes: "E / Yes"
        case .scrollRight: "Scroll right"
        case .scrollLeft: "Scroll left"
        case .scrollPush: "Scroll knob push"
        case .volumePush: "Volume knob push"
        case .squelchPush: "Squelch knob push"
        case .replay: "Replay"
        case .soft1: "Soft key 1"
        case .soft2: "Soft key 2"
        case .soft3: "Soft key 3"
        case .zip: "Zip"
        case .serviceType: "Services"
        case .range: "Range"
        }
    }

    /// "Also bound to Avoid" / "Also bound to Avoid and Zip".
    static func conflictText(_ others: [FrontPanelKey]) -> String {
        let names = others.map(name)
        let list: String
        switch names.count {
        case 0: return ""
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
        return "Also bound to \(list)"
    }
}

/// What a key-down does while a chord is being recorded.
enum ChordRecording {
    enum Action: Equatable {
        /// Esc: stop recording, change nothing.
        case cancel
        /// Delete or forward delete: stop recording and clear the override.
        case clear
        /// Stop recording and bind this chord.
        case record(KeyChord)
        /// A menu shortcut (⌘Q, ⌘W, ⌘,): stop recording and let the menu have the event.
        case passToMenu
        /// A key a key map can't name (Tab, …) or a bare modifier: keep recording, swallow it.
        case ignore
    }

    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117

    static func decide(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       menuChords: Set<KeyChord>) -> Action {
        let mods = KeyEventMapping.keyModifiers(modifiers)
        if keyCode == escape && mods.isEmpty { return .cancel }
        if (keyCode == delete || keyCode == forwardDelete) && mods.isEmpty { return .clear }
        guard let chord = KeyEventMapping.chord(characters: characters, keyCode: keyCode, modifiers: modifiers) else {
            return .ignore
        }
        if menuChords.contains(chord) { return .passToMenu }
        return .record(chord)
    }
}

/// The recording state and its local key-down monitor (one per editor, so one key at a time).
@MainActor @Observable
final class ChordRecorderMonitor {
    private(set) var recordingKey: FrontPanelKey?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?

    /// Records a chord for `key` from key-downs in the current key window (the Settings window the
    /// click came from). A key-down in any other window ends recording and goes on as usual, and so does
    /// that window resigning key: a station window's key monitor consumes the scanner keys it presses, so
    /// this monitor never sees those.
    func start(_ key: FrontPanelKey, in window: NSWindow? = NSApp.keyWindow,
               onRecord: @escaping (FrontPanelKey, KeyChord?) -> Void) {
        stop()
        recordingKey = key
        self.window = window
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let key = self.recordingKey else { return event }
            guard event.window != nil, event.window === self.window else {
                self.stop()
                return event
            }
            let menuChords = NSApp.mainMenu.map(KeyEventMapping.menuChords(in:)) ?? []
            switch ChordRecording.decide(characters: event.characters(byApplyingModifiers: []),
                                         keyCode: event.keyCode, modifiers: event.modifierFlags,
                                         menuChords: menuChords) {
            case .cancel:
                self.stop()
                return nil
            case .clear:
                self.stop()
                onRecord(key, nil)
                return nil
            case .record(let chord):
                self.stop()
                onRecord(key, chord)
                return nil
            case .passToMenu:
                self.stop()
                return event
            case .ignore:
                return nil
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        recordingKey = nil
        window = nil
    }
}
#endif
