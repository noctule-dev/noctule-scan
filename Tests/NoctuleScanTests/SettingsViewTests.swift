// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import Foundation
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import Testing
@testable import NoctuleScan

/// The Settings and picker helpers, and the key map editor's chord recorder: its decisions, and
/// its monitor end to end next to a station window's key monitor (a recorded key never reaches
/// the scanner). Windows claim to be key (a test process can't become active).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct SettingsViewTests {
    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    private func window() -> KeyWindow {
        _ = NSApplication.shared
        let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                          backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: keyCode))
    }

    @Test func recorderDecisions() {
        let menu: Set<KeyChord> = [KeyChord(key: "q", modifiers: [.command])]
        func decide(_ c: String?, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> ChordRecording.Action {
            ChordRecording.decide(characters: c, keyCode: code, modifiers: mods, menuChords: menu)
        }
        #expect(decide("\u{1B}", 53) == .cancel)
        #expect(decide("\u{7F}", 51) == .clear)
        #expect(decide("\u{F728}", 117) == .clear)
        #expect(decide("4", 21, [.command]) == .record(KeyChord(key: "4", modifiers: [.command])))
        #expect(decide("x", 7) == .record(KeyChord(key: "x")))
        #expect(decide(nil, 122) == .record(KeyChord(key: "F1")))
        #expect(decide(" ", 49) == .record(KeyChord(key: "space")))
        #expect(decide("q", 12, [.command]) == .passToMenu)
        #expect(decide("\t", 48) == .ignore, "tab can't be named in a key map")
        #expect(decide("\u{1B}", 53, [.shift]) == .ignore, "⇧Esc isn't cancel and has no key-map name")
    }

    /// A chord typed into the recorder in the Settings window is recorded and consumed; a station
    /// window's key monitor (acting only on its own window) never presses a scanner key for it.
    @Test func recordedKeysNeverReachTheScanner() throws {
        let settingsWindow = window()
        let stationWindow = window()
        var pressed: [FrontPanelKey] = []
        let monitorView = KeyboardShortcuts.MonitorView()
        monitorView.router = KeyboardRouter(map: KeyMap().resolved(for: .sds200))
        monitorView.press = { pressed.append($0) }
        stationWindow.contentView?.addSubview(monitorView)
        let recorder = ChordRecorderMonitor()
        var recorded: [(FrontPanelKey, KeyChord?)] = []
        defer {
            recorder.stop(); monitorView.removeFromSuperview()
            settingsWindow.close(); stationWindow.close()
        }

        recorder.start(.zip, in: settingsWindow) { recorded.append(($0, $1)) }
        #expect(recorder.recordingKey == .zip)
        NSApp.sendEvent(try key("4", keyCode: 21, window: settingsWindow))  // "4" is the scanner's 4 key
        #expect(recorded.count == 1 && recorded.first?.0 == .zip && recorded.first?.1 == KeyChord(key: "4"))
        #expect(recorder.recordingKey == nil, "one chord per click")
        #expect(pressed.isEmpty, "nothing reached the scanner")

        // Esc cancels; Delete clears.
        recorder.start(.zip, in: settingsWindow) { recorded.append(($0, $1)) }
        NSApp.sendEvent(try key("\u{1B}", keyCode: 53, window: settingsWindow))
        #expect(recorded.count == 1 && recorder.recordingKey == nil)
        recorder.start(.range, in: settingsWindow) { recorded.append(($0, $1)) }
        NSApp.sendEvent(try key("\u{7F}", keyCode: 51, window: settingsWindow))
        #expect(recorded.count == 2 && recorded.last?.0 == .range && recorded.last?.1 == nil)

        // A key in another window ends recording and is left alone (there, the station's monitor presses).
        recorder.start(.zip, in: settingsWindow) { recorded.append(($0, $1)) }
        NSApp.sendEvent(try key("x", keyCode: 7, window: stationWindow))
        #expect(recorder.recordingKey == nil)
        #expect(recorded.count == 2)
        // A scanner key there is pressed by the station's monitor, which now consumes it (Plan 20 Task 8
        // fix: a consumed key goes no further). AppKit calls local monitors in no fixed order, so the
        // recorder may not see it; recording also ends when the Settings window resigns key, as clicking
        // into the station window does.
        recorder.start(.zip, in: settingsWindow) { recorded.append(($0, $1)) }
        NSApp.sendEvent(try key("4", keyCode: 21, window: stationWindow))
        #expect(pressed == [.digit4])
        #expect(recorded.count == 2, "nothing recorded from the station window")
        recorder.start(.zip, in: settingsWindow) { recorded.append(($0, $1)) }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settingsWindow)
        #expect(recorder.recordingKey == nil, "the Settings window resigned key")
        #expect(recorded.count == 2)
    }

    @Test func conflictText() {
        #expect(KeyLabels.conflictText([.avoid]) == "Also bound to Avoid")
        #expect(KeyLabels.conflictText([.avoid, .zip]) == "Also bound to Avoid and Zip")
        #expect(KeyLabels.conflictText([.avoid, .zip, .soft1]) == "Also bound to Avoid, Zip, and Soft key 1")
        #expect(Set(FrontPanelKey.allCases.map(KeyLabels.name)).count == FrontPanelKey.allCases.count, "names are distinct")
    }

    @Test func recordingsFolderText() {
        let root = URL(fileURLWithPath: "/Users/tester/Music/Noctule Scan", isDirectory: true)
        let home = "/Users/tester"
        #expect(RecordingsFolderText.path(custom: nil, root: root, stationName: "Home Scanner")
                == "/Users/tester/Music/Noctule Scan/Home Scanner")
        #expect(RecordingsFolderText.display(custom: nil, root: root, stationName: "Home Scanner", home: home)
                == "~/Music/Noctule Scan/Home Scanner (default)")
        #expect(RecordingsFolderText.display(custom: "/Volumes/Archive/Scans", root: root, stationName: "Home Scanner",
                                             home: home) == "/Volumes/Archive/Scans")
        #expect(RecordingsFolderText.display(custom: "/Users/tester/Desktop/Rec", root: root, stationName: "X",
                                             home: home) == "~/Desktop/Rec")
        #expect(RecordingsFolderText.abbreviate("/Users/testerx/a", home: home) == "/Users/testerx/a")
        #expect(RecordingsFolderText.abbreviate("/Users/tester", home: home + "/") == "~")
        #expect(RecordingsFolderText.format == "WAV, 16-bit, 8 kHz mono")
        // The folder name is sanitized the way the runner does it.
        #expect(RecordingsFolderText.path(custom: nil, root: root, stationName: "A/B")
                == root.appendingPathComponent(RecordingName.sanitizeFolderName("A/B")).path)
    }

    @Test func generalAndEditorText() {
        let locations = AppSettings.availableLocations()
        #expect(locations.map(GeneralText.title) == ["On this Mac", "iCloud — requires an Apple Developer Program membership"])
        #expect(GeneralText.exportFileName == "Noctule Scan Settings.json")
        #expect(EditorText.sentence("the station needs a name") == "The station needs a name.")
        #expect(EditorText.sentence("Done.") == "Done.")
        #expect(EditorText.testOK(model: "SDS200", firmware: "1.26.01") == "Connected: SDS200, firmware 1.26.01")
        #expect(EditorText.reconnectWaitFootnote.contains("after a clean disconnect"))
        #expect(EditorText.reconnectWaitFootnote.contains("always wait 120 s"))
        #expect(EditorText.reconnectWaitFootnote.contains("power cycle"))
    }

    /// The editor's Connection rows (SDS150 design §7.1): a network station's address, ports and
    /// reconnect wait; a USB station's Scanner row, plus a Port picker only when there is a choice
    /// to make (several ports found) or a port is saved.
    @Test func editorRowsFollowTheConnection() {
        let network: [EditorRow] = [.address, .controlPort, .audioPort, .reconnectWait]
        #expect(EditorRows.visible(for: .network, portCount: 0, savedPort: false) == network)
        #expect(EditorRows.visible(for: .network, portCount: 2, savedPort: true) == network)
        #expect(EditorRows.visible(for: .usbSerial, portCount: 0, savedPort: false) == [.scanner])
        #expect(EditorRows.visible(for: .usbSerial, portCount: 1, savedPort: false) == [.scanner])
        #expect(EditorRows.visible(for: .usbSerial, portCount: 2, savedPort: false) == [.scanner, .port])
        #expect(EditorRows.visible(for: .usbSerial, portCount: 1, savedPort: true) == [.scanner, .port])
        #expect(EditorRows.visible(for: .usbSerial, portCount: 0, savedPort: true) == [.scanner, .port])
        #expect(EditorRows.visible(for: .bluetooth, portCount: 0, savedPort: false) == [])
    }
}
#endif
