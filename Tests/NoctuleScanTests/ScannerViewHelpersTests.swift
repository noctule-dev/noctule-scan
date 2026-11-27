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

/// The scanner view's non-trivial formatting and input logic, without any views.
@MainActor @Suite(.timeLimit(.minutes(3))) struct ScannerViewHelpersTests {
    // MARK: Indicators

    @Test func screenWidthFollowsTheColumns() {
        #expect(DisplayView.screenWidth(columns: 24) < DisplayView.screenWidth(columns: 30))
    }

    @Test func everyModelShowsZipServicesRange() {
        for model in ScannerModel.allCases {
            let rows = KeypadView.rows(keys: ModelProfile.profile(for: model).frontPanelKeys)
            #expect(rows[1].map(\.key) == [.zip, .serviceType, .range], "\(model)")
            #expect(rows.allSatisfy { !$0.isEmpty })
        }
    }

    @Test func bcdFixedKeysLabels() {
        #expect(DisplayView.fixedKeys.map(\.label) == ["System", "Dept", "Channel"])
        #expect(DisplayView.fixedKeys.map(\.key) == [.soft1, .soft2, .soft3])
    }

    @Test func fixedKeysShowOnlyWithoutASoftKeyLine() {
        let bcd = ModelProfile.profile(for: .bcd436hp)
        #expect(DisplayView.showsFixedKeys(layout: bcd.display, keys: bcd.frontPanelKeys))
        let sds = ModelProfile.profile(for: .sds200)
        #expect(!DisplayView.showsFixedKeys(layout: sds.display, keys: sds.frontPanelKeys))
    }

    @Test func encoderHelpOnlyOnTheHandhelds() {
        #expect(ScannerView.scrollPushHelp(caption: "Vol") == "Press: volume. Func, then press: squelch.")
        #expect(ScannerView.scrollPushHelp(caption: "Func") == nil)
    }

    @Test func phaseIndicatorText() {
        let name = "Test Station"
        #expect(ScannerIndicators.phase(.connecting, stationName: name).text == "Connecting…")
        #expect(ScannerIndicators.phase(.waitingForCooldown(secondsLeft: 87), stationName: name).text
                == "Waiting for scanner cooldown, 87 s")
        let waiting = ScannerIndicators.phase(.waitingForScanner(hint: SerialPort.noneFoundHint), stationName: name)
        #expect(waiting == StatusIndicator(text: "Waiting for the scanner", symbol: "cable.connector", tone: .busy))
        let connected = ScannerIndicators.phase(.connected(model: "SDS200", firmware: "1.26.01"), stationName: name)
        #expect(connected.text == "Connected — SDS200, firmware 1.26.01")
        #expect(connected.tone == .good)
        let noAnswer = StationSession.noAnswerMessage(host: "127.0.0.1", port: 50536)
        #expect(ScannerIndicators.phase(.noAnswer(noAnswer), stationName: name).text == noAnswer)
        #expect(ScannerIndicators.phase(.noAnswer(noAnswer), stationName: name).tone == .bad)
        #expect(ScannerIndicators.phase(.inUse(pid: 4242), stationName: name).text
                == "Test Station is open in another Noctule Scan process (pid 4242).")
        #expect(ScannerIndicators.phase(.inUse(pid: nil), stationName: name).text
                == "Test Station is open in another Noctule Scan process.")
        #expect(ScannerIndicators.phase(.scannerInUse(byStation: "Other Station"), stationName: name).text
                == "Other Station is already connected to this scanner.")
        #expect(ScannerIndicators.phase(.idle, stationName: name).text == "Not connected")
        #expect(ScannerIndicators.phase(.stopping, stationName: name).text == "Disconnecting…")
        #expect(ScannerIndicators.phase(.stopped, stationName: name).text == "Disconnected")
    }

    @Test func audioIndicatorText() {
        #expect(ScannerIndicators.audio(.streaming, listening: true).text == "Listening")
        #expect(ScannerIndicators.audio(.streaming, listening: false).text == "Audio streaming, not playing")
        #expect(ScannerIndicators.audio(.recovering(attempt: 2), listening: true).text == "Audio recovering (attempt 2)")
        let failed = ScannerIndicators.audio(.failed("timeout"), listening: true)
        #expect(failed.text == "Scanner audio isn't responding")
        #expect(failed.tone == .bad)
        #expect(ScannerIndicators.audio(.starting, listening: true).text == "Audio starting…")
        #expect(ScannerIndicators.audio(.idle, listening: true).text == "Audio off")
        #expect(ScannerIndicators.audio(.stopped, listening: true).text == "Audio off")
    }

    /// The status bar's battery (SDS150 design §7.2, D9): the percent, plus the charger state only
    /// when it is charging or full; an unknown `CST` code (8 on the owner's unit) says nothing more.
    @Test func batteryIndicator() throws {
        func status(_ code: Int, _ percent: Int) throws -> ChargeStatus {
            try ChargeStatus(fields: ["CST=\(code)", "VOLT=4100mV:\(percent)%", "CURR=0000mA", "TEMP=27.65C"])
        }
        #expect(ScannerIndicators.battery(try status(8, 100))
                == StatusIndicator(text: "Battery 100%", symbol: "battery.100percent", tone: .neutral))
        #expect(ScannerIndicators.battery(try status(6, 85))
                == StatusIndicator(text: "Battery 85%, charging", symbol: "battery.100percent.bolt", tone: .neutral))
        #expect(ScannerIndicators.battery(try status(5, 40))
                == StatusIndicator(text: "Battery 40%, charging", symbol: "battery.100percent.bolt", tone: .neutral))
        #expect(ScannerIndicators.battery(try status(4, 100))
                == StatusIndicator(text: "Battery 100%, full", symbol: "battery.100percent.bolt", tone: .neutral))
        #expect(ScannerIndicators.battery(try status(0, 12))
                == StatusIndicator(text: "Battery 12%", symbol: "battery.0percent", tone: .warning))
        #expect(ScannerIndicators.battery(try status(6, 12))?.tone == .neutral, "low but charging")
        #expect(ScannerIndicators.battery(try status(0, 15))?.tone == .warning)
        #expect(ScannerIndicators.battery(try status(0, 16))?.tone == .neutral)
        #expect(ScannerIndicators.battery(try status(1, 50))?.text == "Battery 50%", "initializing: nothing more")
        // The level symbol by percent: ≥ 88, ≥ 63, ≥ 38, ≥ 13, below.
        #expect(ScannerIndicators.battery(try status(0, 88))?.symbol == "battery.100percent")
        #expect(ScannerIndicators.battery(try status(0, 87))?.symbol == "battery.75percent")
        #expect(ScannerIndicators.battery(try status(0, 63))?.symbol == "battery.75percent")
        #expect(ScannerIndicators.battery(try status(0, 62))?.symbol == "battery.50percent")
        #expect(ScannerIndicators.battery(try status(0, 38))?.symbol == "battery.50percent")
        #expect(ScannerIndicators.battery(try status(0, 37))?.symbol == "battery.25percent")
        #expect(ScannerIndicators.battery(try status(0, 13))?.symbol == "battery.25percent")
        #expect(ScannerIndicators.battery(try status(0, 0))?.symbol == "battery.0percent")
        #expect(ScannerIndicators.battery(nil) == nil)
        #expect(ScannerIndicators.noAudioOverUSB
                == StatusIndicator(text: "No audio over USB", symbol: "speaker.slash", tone: .neutral))
    }

    /// A station without audio (USB) shows no Listen and no app volume; Logging stays.
    @Test func audioControlsHiddenWithoutAudio() {
        let usb = MacControlsBar.Enablement(connected: true, canHoldAny: true, inMenu: false, hasAudio: false)
        #expect(usb.showsAudioControls == false)
        #expect(!usb.listen)
        #expect(usb.logging && usb.hold && usb.avoid)
        let network = MacControlsBar.Enablement(connected: true, canHoldAny: true, inMenu: false, hasAudio: true)
        #expect(network.showsAudioControls)
        #expect(network.hold && network.avoid && network.listen && network.logging)
        let offline = MacControlsBar.Enablement(connected: false, canHoldAny: true, inMenu: false, hasAudio: true)
        #expect(offline.showsAudioControls && !offline.listen && !offline.logging)
    }

    @Test func loggingIndicatorText() {
        #expect(ScannerIndicators.logging(paused: false, connected: true).text == "Logging")
        #expect(ScannerIndicators.logging(paused: false, connected: true).tone == .good)
        #expect(ScannerIndicators.logging(paused: true, connected: true).text == "Logging paused")
        #expect(ScannerIndicators.logging(paused: true, connected: true).tone == .warning)
        // QA (Task 13, M4): nothing logs here unless connected (e.g. the station is in use elsewhere).
        #expect(ScannerIndicators.logging(paused: false, connected: false).text == "Not logging")
        #expect(ScannerIndicators.logging(paused: false, connected: false).tone == .neutral)
    }

    @Test func softKeyTitle() {
        #expect(DisplayView.softKeyTitle(SoftKey(key: .soft1, label: "SYSTEM")) == "System")
        #expect(DisplayView.softKeyTitle(SoftKey(key: .soft2, label: "", isGlyph: true)) == "•")
        #expect(DisplayView.softKeyTitle(SoftKey(key: .soft3, label: "")) == " ")
        #expect(DisplayView.softKeyTitle(nil) == " ")
    }

    @Test func exactCopy() {
        #expect(ScannerCopy.audioFailed == "Scanner audio isn't responding")
        #expect(ScannerCopy.restartTitle(host: "127.0.0.1") == "Restart the scanner at 127.0.0.1?")
        #expect(ScannerCopy.restartNote
                == "Whether a restart revives a stuck audio server is unverified; if audio stays off, power-cycle the scanner.")
        #expect(ScannerCopy.restartButton == "Restart")
        #expect(ScannerCopy.cancelButton == "Cancel")
    }

    // MARK: Knob steps

    @Test func wheelNotchIsOneStep() {
        var acc = KnobStepAccumulator()
        #expect(acc.scroll(delta: 1, precise: false) == 1)
        #expect(acc.scroll(delta: 7.5, precise: false) == 1, "an accelerated notch is still one step")
        #expect(acc.scroll(delta: -3, precise: false) == -1)
        #expect(acc.scroll(delta: 0, precise: false) == 0)
    }

    @Test func trackpadDeltasAccumulateToWholeSteps() {
        var acc = KnobStepAccumulator(pointsPerScrollStep: 10)
        #expect(acc.scroll(delta: 4, precise: true) == 0)
        #expect(acc.scroll(delta: 4, precise: true) == 0)
        #expect(acc.scroll(delta: 4, precise: true) == 1, "12 points: one step, 2 left over")
        #expect(acc.scroll(delta: 28, precise: true) == 3, "30 points: three steps")
        #expect(acc.scroll(delta: -5, precise: true) == 0, "back to -5")
        #expect(acc.scroll(delta: -5, precise: true) == -1)
        acc.reset()
        #expect(acc.scroll(delta: 9, precise: true) == 0, "reset drops the residue")
    }

    @Test func dragAccumulatesToWholeSteps() {
        var acc = KnobStepAccumulator(pointsPerDragStep: 8)
        #expect(acc.drag(delta: 5) == 0)
        #expect(acc.drag(delta: 5) == 1)
        #expect(acc.drag(delta: 30) == 4, "2 left over + 30 = 32 points: four steps")
        #expect(acc.drag(delta: -20) == -2)
    }

    @Test func levelTargetClampsAndBuildsOnPending() {
        #expect(LevelStepper.target(current: 10, pending: nil, steps: 2, range: 0...29) == 12)
        #expect(LevelStepper.target(current: 10, pending: 14, steps: 1, range: 0...29) == 15, "steps build on what was asked")
        #expect(LevelStepper.target(current: 28, pending: nil, steps: 5, range: 0...29) == 29)
        #expect(LevelStepper.target(current: 1, pending: nil, steps: -5, range: 0...29) == 0)
        #expect(LevelStepper.target(current: nil, pending: nil, steps: 1, range: 0...29) == nil, "unknown level: nothing sent")
        #expect(LevelStepper.target(current: 29, pending: nil, steps: 1, range: 0...29) == nil, "already at the end: nothing sent")
    }

    // MARK: Keyboard

    private var router: KeyboardRouter { KeyboardRouter(map: KeyMap().resolved(for: .sds200)) }

    @Test func keyEventsMapToChords() {
        #expect(KeyEventMapping.chord(characters: "4", keyCode: 21, modifiers: []) == KeyChord(key: "4"))
        #expect(KeyEventMapping.chord(characters: "a", keyCode: 0, modifiers: [.shift]) == KeyChord(key: "a", modifiers: [.shift]))
        #expect(KeyEventMapping.chord(characters: "4", keyCode: 21, modifiers: [.command, .option])
                == KeyChord(key: "4", modifiers: [.command, .option]))
        #expect(KeyEventMapping.chord(characters: "\r", keyCode: 36, modifiers: []) == KeyChord("↩"))
        #expect(KeyEventMapping.chord(characters: "\u{3}", keyCode: 76, modifiers: [.numericPad]) == KeyChord("↩"))
        #expect(KeyEventMapping.chord(characters: " ", keyCode: 49, modifiers: []) == KeyChord("space"))
        #expect(KeyEventMapping.chord(characters: "\u{F702}", keyCode: 123, modifiers: [.function, .numericPad]) == KeyChord("←"))
        #expect(KeyEventMapping.chord(characters: "\u{F703}", keyCode: 124, modifiers: [.function, .numericPad]) == KeyChord("→"))
        #expect(KeyEventMapping.chord(characters: "\u{F704}", keyCode: 122, modifiers: [.function]) == KeyChord("F1"))
        #expect(KeyEventMapping.chord(characters: "\u{F706}", keyCode: 99, modifiers: [.function]) == KeyChord("F3"))
        #expect(KeyEventMapping.chord(characters: "5", keyCode: 87, modifiers: [.numericPad]) == KeyChord(key: "5"), "keypad digits")
        #expect(KeyEventMapping.chord(characters: "\t", keyCode: 48, modifiers: []) == nil, "tab stays with focus navigation")
        #expect(KeyEventMapping.chord(characters: "\u{1B}", keyCode: 53, modifiers: []) == nil, "escape")
        #expect(KeyEventMapping.chord(characters: "\u{7F}", keyCode: 51, modifiers: []) == nil, "delete")
        #expect(KeyEventMapping.chord(characters: nil, keyCode: 200, modifiers: []) == nil)
    }

    @Test func routingPressesMappedKeys() {
        let four = KeyChord(key: "4")
        #expect(KeyRouting.decide(chord: four, router: router, isRepeat: false, focusElsewhere: false, menuChords: [])
                == .press(.digit4))
        #expect(KeyRouting.decide(chord: KeyChord(key: "x"), router: router, isRepeat: false, focusElsewhere: false,
                                  menuChords: []) == .pass, "unmapped keys pass through")
        #expect(KeyRouting.decide(chord: nil, router: router, isRepeat: false, focusElsewhere: false, menuChords: []) == .pass)
    }

    @Test func routingLeavesTextFieldsAlone() {
        #expect(KeyRouting.decide(chord: KeyChord(key: "4"), router: router, isRepeat: false, focusElsewhere: true,
                                  menuChords: []) == .pass)
    }

    @Test func routingLeavesMenuEquivalentsAlone() throws {
        var map = KeyMap()
        map.overrides[FrontPanelKey.menu.rawValue] = "⌘q"
        map.overrides[FrontPanelKey.replay.rawValue] = "⌘4"
        let custom = KeyboardRouter(map: map.resolved(for: .sds200))
        let quit = try #require(KeyChord("⌘q"))
        let menus: Set<KeyChord> = [quit, try #require(KeyChord("⌘w"))]
        #expect(KeyRouting.decide(chord: quit, router: custom, isRepeat: false, focusElsewhere: false, menuChords: menus)
                == .pass, "⌘Q still quits even when mapped")
        #expect(KeyRouting.decide(chord: KeyChord("⌘4"), router: custom, isRepeat: false, focusElsewhere: false,
                                  menuChords: menus) == .press(.replay), "a mapped ⌘ chord that no menu uses is pressed")
        #expect(KeyRouting.decide(chord: KeyChord("⌘w"), router: custom, isRepeat: false, focusElsewhere: false,
                                  menuChords: menus) == .pass)
    }

    @Test func routingRepeatsOnlyScroll() {
        #expect(KeyRouting.decide(chord: KeyChord("→"), router: router, isRepeat: true, focusElsewhere: false,
                                  menuChords: []) == .press(.scrollRight), "a held arrow keeps scrolling (the queue caps it)")
        #expect(KeyRouting.decide(chord: KeyChord(key: "4"), router: router, isRepeat: true, focusElsewhere: false,
                                  menuChords: []) == .swallow, "a held digit is one press")
    }

    @Test func menuChordsFromAMenu() throws {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "App", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "App")
        appMenu.addItem(NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q"))
        let hide = NSMenuItem(title: "Hide Others", action: nil, keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hide)
        appMenu.addItem(NSMenuItem(title: "Redo", action: nil, keyEquivalent: "Z"))
        appMenu.addItem(NSMenuItem(title: "No shortcut", action: nil, keyEquivalent: ""))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let chords = KeyEventMapping.menuChords(in: main)
        #expect(chords == [try #require(KeyChord("⌘q")), try #require(KeyChord("⌥⌘h")), try #require(KeyChord("⇧⌘z"))])
    }

    // MARK: Recent hits

    private func hit(channel: String?, tg: String?, mhz: Double?, system: String? = "Testville") -> Hit {
        Hit(id: UUID(), key: HitKey(system: system, talkgroupID: tg, frequencyMHz: mhz),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), startInstant: .now, system: system, channel: channel)
    }

    @Test func recentHitText() {
        let trunk = hit(channel: "Fire Dispatch", tg: "1201", mhz: nil)
        #expect(RecentHitText.title(trunk) == "Fire Dispatch")
        #expect(RecentHitText.detail(trunk) == "TG 1201 · Testville")
        let unnamed = hit(channel: "  ", tg: "4417", mhz: nil)
        #expect(RecentHitText.title(unnamed) == "TG 4417")
        let conventional = hit(channel: nil, tg: nil, mhz: 155.7525, system: nil)
        #expect(RecentHitText.title(conventional) == "155.7525 MHz")
        #expect(RecentHitText.detail(conventional) == "155.7525 MHz")
        #expect(RecentHitText.title(hit(channel: nil, tg: nil, mhz: nil, system: nil)) == "Unknown")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(RecentHitText.time(Date(timeIntervalSince1970: 1_700_000_000), calendar: utc) == "22:13:20")
    }
}
#endif
