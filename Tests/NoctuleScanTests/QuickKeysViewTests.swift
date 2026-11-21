// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import Foundation
@testable import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import Testing
@testable import NoctuleScan

/// The Quick Keys pop-over's helpers (design `docs/specs/2026-11-18-quick-keys-design.md` §5.5): its exact
/// copy, the look per `QuickKeySwitchState`, the tens and paging, typing, the tree's first expansion, the
/// toolbar button's visibility, the pop-over's and the tear-off panel's hold on the model, and the station
/// window's key monitor leaving the pop-over's and the panel's keys alone.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct QuickKeysViewTests {
    // MARK: Copy

    @Test func tileAccessibility() {
        #expect(QuickKeysText.tileAccessibilityLabel(name: "Mock Police", key: 0) == "Mock Police, quick key 0")
        let on = QuickKeySwitchLook(state: .on, raw: .on)
        #expect(on.isOn == true && on.isEnabled)
        #expect(QuickKeysText.accessibilityValue(isOn: on.isOn) == "on")
        let off = QuickKeySwitchLook(state: .off, raw: .off)
        #expect(QuickKeysText.accessibilityValue(isOn: off.isOn) == "off")
        #expect(QuickKeysText.accessibilityValue(isOn: nil) == nil)
    }

    @Test func cornerButtonLabel() {
        #expect(QuickKeysText.cornerButtonLabel(name: "Mock Police") == "Show systems in Mock Police")
        #expect(QuickKeysText.cornerButtonTitle(systemCount: 3) == "3 ›")
        #expect(QuickKeysText.cornerButtonTitle(systemCount: nil) == "›")
    }

    @Test func headerDetail() {
        #expect(QuickKeysText.headerDetail(systems: 3, on: 2) == "3 systems, 2 on")
        #expect(QuickKeysText.headerDetail(systems: 1, on: 1) == "1 system, 1 on")
        #expect(QuickKeysText.headerDetail(systems: 3, on: nil) == "3 systems", "no on count before states are read")
        #expect(QuickKeysText.scanThisList == "Scan this list")
    }

    @Test func helpTexts() {
        #expect(QuickKeysText.help(for: .unreported) == "The scanner doesn't report this key's state.")
        #expect(QuickKeysText.help(for: .sharedSystemKey(2))
            == "Systems S2 share a quick key, so their departments can't be switched separately here.")
        #expect(QuickKeysText.help(for: .sharedListKey(5))
            == "Lists F5 share a quick key, so their systems can't be switched separately here.")
        #expect(QuickKeysText.help(for: .inMenu) == "The scanner is in a menu")
        #expect(QuickKeysText.help(for: .checking) == "Checking…")
        #expect(QuickKeysText.help(for: .checkingOtherLists) == "Checking the other lists…")
        #expect(QuickKeysText.checkingOtherLists == "Checking the other lists…", "the status line's words too")
        for state: QuickKeySwitchState in [.on, .off, .unknown, .busy, .noQuickKey, .unavailable] {
            #expect(QuickKeysText.help(for: state) == nil, "\(state)")
        }
        #expect(QuickKeysText.sharingHelp(count: 3, tag: "D0") == "3 items share quick key D0; they switch together.")
        #expect(QuickKeysText.sharingHelp(count: 2, tag: "S1") == "2 items share quick key S1; they switch together.")
        #expect(QuickKeysText.keyTag(.child(list: 1, system: 101, child: 200), key: 0) == "D0")
        #expect(QuickKeysText.keyTag(.system(list: 1, system: 101), key: 4) == "S4")
        #expect(QuickKeysText.keyTag(.list(1), key: 7) == "F7")
        #expect(QuickKeysText.notMonitoredTag == "Not monitored")
        #expect(QuickKeysText.noQuickKeyTag == "no quick key")
        #expect(QuickKeysText.siteTag == "site")
        #expect(QuickKeysText.avoidedTag == "Avoided")
        #expect(QuickKeysText.sharedTag == "shared")
        #expect(QuickKeysText.notMonitoredLine
            == "Not monitored. Turn it on in Select Lists to Monitor on the scanner or in Sentinel.")
        #expect(QuickKeysText.checking == "Checking…")
        #expect(QuickKeysText.noQuickKeyTitle == "No quick key")
    }

    @Test func errorLine() {
        #expect(QuickKeysText.errorLine(lastError: "The scanner didn't confirm the change", isScannerAnswering: true)
            == "The scanner didn't confirm the change")
        #expect(QuickKeysText.unconfirmed == QuickKeysModel.unconfirmedMessage, "the line matches the model's words")
        #expect(QuickKeysText.errorLine(lastError: "The scanner didn't confirm the change", isScannerAnswering: false)
            == "The scanner didn't confirm the change", "the unconfirmed change comes first, as in the model")
        #expect(QuickKeysText.errorLine(lastError: "The scanner didn't answer FQK.", isScannerAnswering: false)
            == "The scanner isn't answering")
        #expect(QuickKeysText.errorLine(lastError: nil, isScannerAnswering: false) == "The scanner isn't answering")
        #expect(QuickKeysText.errorLine(lastError: nil, isScannerAnswering: true) == nil)
        // A set that its check stopped is a change error too: shown as the model words it.
        for message in [QuickKeysModel.listChangedMessage, QuickKeysModel.checkUnansweredMessage] {
            #expect(QuickKeysText.errorLine(lastError: message, isScannerAnswering: true) == message)
            #expect(QuickKeysText.errorLine(lastError: message, isScannerAnswering: false) == message)
        }
        #expect(QuickKeysModel.listChangedMessage == "The list changed on the scanner; nothing was sent.")
        #expect(QuickKeysModel.checkUnansweredMessage == "The scanner didn't answer; nothing was sent.")
    }

    @Test func listReadErrorLine() {
        // The model's sentences (`QuickKeysModelFailingListTests.aListErrorSaysWhatFailedInWords`), lower-cased after
        // the colon.
        #expect(QuickKeysText.listReadError("The scanner refused GLT,SYS.")
            == "Couldn't read this list: the scanner refused GLT,SYS. Trying again.")
        #expect(QuickKeysText.listReadError("The scanner's reply to GLT,DEPT couldn't be read.")
            == "Couldn't read this list: the scanner's reply to GLT,DEPT couldn't be read. Trying again.")
        #expect(QuickKeysText.listReadError("The scanner didn't answer GLT,SITE.")
            == "Couldn't read this list: the scanner didn't answer GLT,SITE. Trying again.")
        // Under the "Checking…" line of a tree that isn't fresh, only while it has an error.
        let failing = QuickKeyListTree(systems: [], freshness: .checking, readError: "The scanner refused GLT,SYS.")
        #expect(QuickKeyTreePanel.readErrorLine(failing)
            == "Couldn't read this list: the scanner refused GLT,SYS. Trying again.")
        #expect(QuickKeyTreePanel.readErrorLine(QuickKeyListTree(systems: [], freshness: .loading,
                                                                  readError: "The scanner didn't answer GLT,DEPT."))
            == "Couldn't read this list: the scanner didn't answer GLT,DEPT. Trying again.")
        #expect(QuickKeyTreePanel.readErrorLine(QuickKeyListTree(systems: [], freshness: .checking)) == nil)
        #expect(QuickKeyTreePanel.readErrorLine(QuickKeyListTree(systems: [], freshness: .fresh, readError: "x")) == nil)
    }

    // MARK: Looks

    /// `.unknown`, `.checking`, `.unavailable` and `.unreported` show no on/off; busy, a menu, a shared
    /// system or list key and the other lists being checked keep showing the state read, but nothing switches.
    @Test func switchLooks() {
        for state: QuickKeySwitchState in [.unknown, .checking, .unavailable, .unreported, .noQuickKey] {
            let look = QuickKeySwitchLook(state: state, raw: .on)
            #expect(look.isOn == nil && !look.isEnabled, "\(state)")
        }
        for state: QuickKeySwitchState in [.busy, .inMenu, .sharedSystemKey(0), .sharedListKey(0), .checkingOtherLists] {
            #expect(QuickKeySwitchLook(state: state, raw: .on).isOn == true, "\(state)")
            #expect(QuickKeySwitchLook(state: state, raw: .off).isOn == false, "\(state)")
            #expect(!QuickKeySwitchLook(state: state, raw: .on).isEnabled, "\(state)")
        }
        #expect(QuickKeySwitchLook(state: .busy, raw: .on).isBusy)
        #expect(!QuickKeySwitchLook(state: .on, raw: .on).isBusy)
    }

    /// Blue fill and border on, gray off, neutral unknown; green ring scanning; outline and pointer shown.
    @Test func tileLooks() {
        #expect(QuickKeyTileLook(state: .on, raw: .on, isScanning: false, isShown: false).fill == .on)
        #expect(QuickKeyTileLook(state: .off, raw: .off, isScanning: false, isShown: false).fill == .off)
        #expect(QuickKeyTileLook(state: .unknown, raw: nil, isScanning: false, isShown: false).fill == .neutral)
        #expect(QuickKeyTileLook(state: .checking, raw: nil, isScanning: false, isShown: false).fill == .neutral)
        let scanning = QuickKeyTileLook(state: .on, raw: .on, isScanning: true, isShown: true)
        #expect(scanning.hasScanningRing && scanning.hasShownOutline)
        let plain = QuickKeyTileLook(state: .off, raw: .off, isScanning: false, isShown: false)
        #expect(!plain.hasScanningRing && !plain.hasShownOutline)
    }

    // MARK: Tens, typing, the tree

    private func list(_ index: UInt32, _ name: String, key: Int?, _ state: QuickKeyState? = .on) -> QuickKeyListItem {
        QuickKeyListItem(index: index, name: name, key: key, monitored: true, state: state, systemCount: 1)
    }

    @Test func tenCaptions() {
        let pages = QuickKeyPages(lists: [list(0, "Mock Police", key: 0), list(1, "Mock Air", key: 3, .off),
                                          list(2, "Mock Interop", key: 41, nil)],
                                  scanningList: 2)
        #expect(QuickKeysText.tenTitle(pages.tens[0]) == "0–9")
        #expect(QuickKeysText.tenTitle(pages.tens[9]) == "90–99")
        #expect(QuickKeysText.tenCaption(pages.tens[0], statesKnown: true) == "1/2 on")
        #expect(QuickKeysText.tenCaption(pages.tens[0], statesKnown: false) == "2 lists")
        #expect(QuickKeysText.tenCaption(pages.tens[4], statesKnown: false) == "1 list")
        #expect(QuickKeysText.tenCaption(pages.tens[5], statesKnown: true) == "—")
    }

    /// Digits jump to the key's ten and highlight it; a second digit within a second makes two digits.
    @Test func typingJumpsAndHighlights() {
        let state = QuickKeysViewState()
        let start = ContinuousClock.now
        state.typed(4, at: start)
        #expect(state.ten == 0 && state.highlighted == 4)
        state.typed(1, at: start + .milliseconds(300))
        #expect(state.ten == 4 && state.highlighted == 41)
        state.typed(7, at: start + .seconds(3))
        #expect(state.ten == 0 && state.highlighted == 7)
    }

    /// The pop-over's own keys: digits, Space and Return (not repeated), ⌘↓, ⌘F; everything else passes.
    @Test func popoverKeys() {
        #expect(QuickKeysKeyRouting.decide(characters: "4", keyCode: 21, modifiers: [], isRepeat: false) == .digit(4))
        #expect(QuickKeysKeyRouting.decide(characters: "0", keyCode: 29, modifiers: [], isRepeat: true) == .digit(0))
        #expect(QuickKeysKeyRouting.decide(characters: " ", keyCode: 49, modifiers: [], isRepeat: false) == .toggle)
        #expect(QuickKeysKeyRouting.decide(characters: "\r", keyCode: 36, modifiers: [], isRepeat: false) == .toggle)
        #expect(QuickKeysKeyRouting.decide(characters: "\r", keyCode: 36, modifiers: [], isRepeat: true) == .swallow,
                "a held key never toggles twice")
        #expect(QuickKeysKeyRouting.decide(characters: "\u{F701}", keyCode: 125, modifiers: .command, isRepeat: false)
            == .showTree)
        #expect(QuickKeysKeyRouting.decide(characters: "f", keyCode: 3, modifiers: .command, isRepeat: false) == .find)
        #expect(QuickKeysKeyRouting.decide(characters: "w", keyCode: 13, modifiers: .command, isRepeat: false) == nil)
        #expect(QuickKeysKeyRouting.decide(characters: "4", keyCode: 21, modifiers: .command, isRepeat: false) == nil)
        #expect(QuickKeysKeyRouting.decide(characters: "a", keyCode: 0, modifiers: [], isRepeat: false) == nil)
    }

    /// A two-finger swipe steps one ten per gesture, left for the next and right for the previous.
    @Test func swipeStepsOncePerGesture() {
        var swipe = QuickKeysSwipe()
        #expect(swipe.scroll(deltaX: -4, deltaY: 0, phase: .began) == nil)
        #expect(swipe.scroll(deltaX: -30, deltaY: 1, phase: .changed) == 1)
        #expect(swipe.scroll(deltaX: -30, deltaY: 0, phase: .changed) == nil, "once per gesture")
        #expect(swipe.scroll(deltaX: 0, deltaY: 0, phase: .ended) == nil)
        #expect(swipe.scroll(deltaX: 20, deltaY: 0, phase: .began) == nil)
        #expect(swipe.scroll(deltaX: 20, deltaY: 0, phase: .changed) == -1)
        #expect(swipe.scroll(deltaX: 0, deltaY: 0, phase: .ended) == nil)
        #expect(swipe.scroll(deltaX: 5, deltaY: 40, phase: .began) == nil)
        #expect(swipe.scroll(deltaX: 30, deltaY: 80, phase: .changed) == nil, "a vertical scroll isn't a swipe")
    }

    /// Systems start expanded when the list has three or fewer, else collapsed but for the scanning one.
    @Test func initialExpansion() {
        #expect(QuickKeyTreeExpansion.initial(systems: [1, 2, 3], scanning: nil) == [1, 2, 3])
        #expect(QuickKeyTreeExpansion.initial(systems: [1, 2, 3, 4], scanning: 3) == [3])
        #expect(QuickKeyTreeExpansion.initial(systems: [1, 2, 3, 4], scanning: nil) == [])
        #expect(QuickKeyTreeExpansion.initial(systems: [1, 2, 3, 4], scanning: 9) == [])
    }

    /// A search hit opens its ten and its list, and expands the system holding a department or site.
    @Test func searchJump() {
        let state = QuickKeysViewState()
        state.jump(to: .child(list: 14, system: 170, child: 590), listKey: 41)
        #expect(state.ten == 4 && state.highlighted == 41)
        #expect(state.expanded.contains(170) && state.searchHit == .child(list: 14, system: 170, child: 590))
        state.jump(to: .list(10), listKey: nil)
        #expect(state.ten == 4, "a list without a key is in no ten")
    }

    /// A search hit on a list with no key leaves no tile highlighted (Space and Return would toggle another list).
    @Test func searchHitOnAKeylessListClearsTheHighlight() {
        let state = QuickKeysViewState()
        state.jump(to: .list(2), listKey: 41)
        #expect(state.highlighted == 41)
        state.jump(to: .list(3), listKey: nil)
        #expect(state.highlighted == nil && state.ten == 4)
    }

    // MARK: The tree belongs to the focused tile (design §5.5)

    private var focusLists: [QuickKeyListItem] {
        [list(0, "Mock Police", key: 0), list(1, "Mock Air", key: 7), list(2, "Mock Interop", key: 41),
         list(3, "Mock Marine", key: nil)]
    }

    /// A click on another list's tile highlights it and closes the shown tree; on the shown list's own tile
    /// the tree stays.
    @Test func clickingAnotherTileClosesTheTree() {
        let model = QuickKeysModel(cacheURL: nil)
        let state = QuickKeysViewState()
        model.showList(1)
        state.clicked(focusLists[2], in: model)
        #expect(state.highlighted == 41 && model.shownList == nil)
        model.showList(1)
        state.clicked(focusLists[1], in: model)
        #expect(state.highlighted == 7 && model.shownList == 1, "the shown list's own tile keeps its tree")
        model.hideList()
        state.clicked(focusLists[0], in: model)
        #expect(state.highlighted == 0 && model.shownList == nil, "with no tree shown, none opens")
    }

    /// A typed key (one digit or two) that lands on another list closes the tree; on the shown list's key it stays.
    @Test func typingAnotherKeyClosesTheTree() {
        let model = QuickKeysModel(cacheURL: nil)
        let state = QuickKeysViewState()
        let start = ContinuousClock.now
        model.showList(2)
        state.typed(4, at: start, lists: focusLists, in: model)
        #expect(state.highlighted == 4 && model.shownList == nil, "key 4 is no list's: the tree closes")
        model.showList(2)
        state.typed(1, at: start + .milliseconds(300), lists: focusLists, in: model)
        #expect(state.highlighted == 41 && model.shownList == 2, "41 is the shown list's key")
        state.typed(7, at: start + .seconds(3), lists: focusLists, in: model)
        #expect(state.highlighted == 7 && model.shownList == nil)
    }

    /// "n ›" and a search hit show and highlight the same list; a list with no key leaves no highlight; paging
    /// moves no focus.
    @Test func showingHighlightsAndPagingKeepsTheTree() {
        let model = QuickKeysModel(cacheURL: nil)
        let state = QuickKeysViewState()
        state.show(focusLists[1], in: model)
        #expect(state.highlighted == 7 && model.shownList == 1)
        state.ten = 4
        #expect(model.shownList == 1, "paging keeps the tree")
        state.show(focusLists[3], in: model)
        #expect(state.highlighted == nil && model.shownList == 3, "a list with no key has no highlighted tile")
        state.clicked(focusLists[1], in: model)
        #expect(state.highlighted == 7 && model.shownList == nil)
    }

    // MARK: The window

    private func session(model: ScannerModel?) throws -> (StationSession, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-quickkeys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let environment = SessionEnvironment(
            settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
            recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
            cooldownStore: InMemoryRTSPCooldownStore(), cooldown: .milliseconds(300))
        var station = Station()
        station.name = "Test Station"
        station.connection.modelOverride = model
        return (StationSession(station: station, environment: environment), dir)  // never started
    }

    @Test func toolbarButtonHiddenWithoutSupport() throws {
        #expect(QuickKeysText.toolbarLabel == "Quick Keys")
        #expect(QuickKeysText.toolbarHelp == "Turn Favorites Lists, systems and departments on and off")
        #expect(!QuickKeysToolbar.isShown(for: nil))
        let (without, dir1) = try session(model: .bcd436hp)
        defer { try? FileManager.default.removeItem(at: dir1) }
        #expect(!without.supportsQuickKeys)
        #expect(!QuickKeysToolbar.isShown(for: without))
        let (with, dir2) = try session(model: .sds200)
        defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(QuickKeysToolbar.isShown(for: with))
    }

    /// The pop-over opens the model; a tear-off keeps it open after the pop-over closes, until the panel
    /// closes; one panel per window; closing everything closes the model.
    @Test func tearOffKeepsTheModelOpenUntilThePanelCloses() throws {
        _ = NSApplication.shared
        let (session, dir) = try session(model: .sds200)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = QuickKeysPanelController()
        let popover = controller.makePopover(for: session)
        #expect(session.quickKeys.isOpen, "showing the pop-over opens the model")
        let panel = try #require(controller.detachableWindow(for: popover) as? NSPanel)
        #expect(panel.isFloatingPanel)
        #expect(controller.detachableWindow(for: popover) === panel, "one panel per station window")
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        #expect(session.quickKeys.isOpen, "torn off: still open")
        panel.close()
        #expect(!session.quickKeys.isOpen, "the panel closed: the model closes")
        #expect(controller.panel == nil)

        _ = controller.makePopover(for: session)
        #expect(session.quickKeys.isOpen)
        controller.closeAll()
        #expect(!session.quickKeys.isOpen)
    }

    // MARK: Keys

    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// The station window's key monitor passes every key for the pop-over's or the panel's window, and
    /// while the pop-over is shown on its window it presses nothing at all; the panel's own monitor takes
    /// the digits, Space and Return.
    @Test func keysInThePanelNeverReachTheScanner() throws {
        _ = NSApplication.shared
        let (session, dir) = try session(model: .sds200)
        defer { try? FileManager.default.removeItem(at: dir) }
        var pressed: [FrontPanelKey] = []
        let station = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                                backing: .buffered, defer: false)
        station.isReleasedWhenClosed = false
        let monitor = KeyboardShortcuts.MonitorView()
        monitor.router = KeyboardRouter(map: KeyMap().resolved(for: .sds200))
        monitor.press = { pressed.append($0) }
        station.contentView?.addSubview(monitor)

        let controller = QuickKeysPanelController()
        let popover = controller.makePopover(for: session)
        let panel = try #require(controller.detachableWindow(for: popover))
        defer { monitor.removeFromSuperview(); station.close(); controller.closeAll() }
        #expect(panel.windowNumber > 0 && panel.windowNumber != station.windowNumber,
                "the panel's events name its own window")

        for (characters, code) in [("4", UInt16(21)), (" ", 49), ("\r", 36), ("1", 18)] {
            #expect(monitor.handle(try key(characters, keyCode: code, window: panel)) != nil, "passed: \(characters)")
        }
        #expect(monitor.handle(try key("\u{F701}", keyCode: 125, modifiers: .command, window: panel)) != nil)
        #expect(pressed.isEmpty, "nothing reached the scanner from the panel")

        // While the attached pop-over shows, the station window presses nothing even if it is key.
        monitor.stepsAside = { true }
        #expect(monitor.handle(try key("4", keyCode: 21, window: station)) != nil)
        #expect(pressed.isEmpty)
        monitor.stepsAside = { false }
        #expect(monitor.handle(try key("4", keyCode: 21, window: station)) == nil)
        #expect(pressed == [.digit4], "the scanner's keys work again once it hides")

        // The panel's own monitor takes its keys.
        var commands: [QuickKeysKeyCommand] = []
        let own = QuickKeysKeyMonitor.MonitorView()
        own.isKey = { _ in true }
        own.perform = { commands.append($0) }
        panel.contentView?.addSubview(own)
        defer { own.removeFromSuperview() }
        #expect(own.handle(try key("4", keyCode: 21, window: panel)) == nil, "consumed by the panel")
        #expect(own.handle(try key(" ", keyCode: 49, window: panel)) == nil)
        #expect(own.handle(try key("4", keyCode: 21, window: station)) != nil, "another window's key")
        #expect(commands == [.digit(4), .toggle])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        panel.contentView?.addSubview(field)
        if panel.makeFirstResponder(field) {
            #expect(own.handle(try key("4", keyCode: 21, window: panel)) != nil, "typing in the search field")
        }
        #expect(commands == [.digit(4), .toggle])
    }

    /// On the real app an attached pop-over's window says it is key, yet AppKit addresses the keys to the
    /// window it is attached to (its parent): the pop-over's monitor takes those, and the station window's
    /// monitor steps aside meanwhile, so the scanner never sees them. A text field focused in the parent
    /// keeps its keys.
    @Test func thePopoversKeysComeThroughItsParentWindow() throws {
        _ = NSApplication.shared
        var pressed: [FrontPanelKey] = []
        let station = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                                backing: .buffered, defer: false)
        station.isReleasedWhenClosed = false
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        station.addChildWindow(child, ordered: .above)
        let stationMonitor = KeyboardShortcuts.MonitorView()
        stationMonitor.router = KeyboardRouter(map: KeyMap().resolved(for: .sds200))
        stationMonitor.press = { pressed.append($0) }
        stationMonitor.stepsAside = { true }
        station.contentView?.addSubview(stationMonitor)
        var commands: [QuickKeysKeyCommand] = []
        let own = QuickKeysKeyMonitor.MonitorView()
        own.isKey = { _ in true }
        own.isOnScreen = { _ in true }
        own.perform = { commands.append($0) }
        child.contentView?.addSubview(own)
        defer {
            stationMonitor.removeFromSuperview(); own.removeFromSuperview()
            station.removeChildWindow(child); child.close(); station.close()
        }
        #expect(child.parent === station)

        let four = try key("4", keyCode: 21, window: station)
        #expect(stationMonitor.handle(four) != nil, "the station window steps aside")
        #expect(own.handle(four) == nil, "the pop-over takes its parent's key")
        #expect(commands == [.digit(4)] && pressed.isEmpty)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        station.contentView?.addSubview(field)
        if station.makeFirstResponder(field) {
            // A focused field in the station window (the Mac-style menu's entry field, whose Return saves
            // to the scanner) gets nothing while the pop-over shows.
            #expect(own.handle(four) == nil, "the pop-over still takes it")
            #expect(own.handle(try key("\r", keyCode: 36, window: station)) == nil)
        }
        #expect(commands == [.digit(4), .digit(4), .toggle] && pressed.isEmpty)
    }

    // MARK: Fix round 1 (QA I1–I3)

    /// I1: while the pop-over is attached, every key AppKit addresses to the station window is the
    /// pop-over's: its own commands, Esc closes it, the app's menu key equivalents pass, and everything
    /// else (arrows, Tab, letters, other chords) is swallowed so it can't reach a station control.
    @Test func theAttachedPopoverKeepsEveryKey() {
        let menu: Set<KeyChord> = [KeyChord(key: "q", modifiers: [.command]), KeyChord(key: "w", modifiers: [.command])]
        func decide(_ characters: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = [], repeated: Bool = false,
                    focused: Bool = false) -> QuickKeysKeyRouting.AttachedDecision {
            QuickKeysKeyRouting.attached(characters: characters, keyCode: code, modifiers: mods, isRepeat: repeated,
                                         menuChords: menu, controlFocused: focused)
        }
        #expect(decide("\u{1B}", 53) == .close, "Esc closes the pop-over")
        #expect(decide("4", 21) == .perform(.digit(4)))
        #expect(decide(" ", 49) == .perform(.toggle))
        #expect(decide("\r", 36, repeated: true) == .perform(.swallow))
        #expect(decide("f", 3, .command) == .perform(.find))
        #expect(decide("\u{F701}", 125, .command) == .perform(.showTree))
        #expect(decide("q", 12, .command) == .pass, "a menu key equivalent")
        #expect(decide("w", 13, .command) == .pass)
        for (characters, code, mods) in [("\u{F702}", UInt16(123), NSEvent.ModifierFlags()), ("\u{F703}", 124, []),
                                         ("\u{F700}", 126, []), ("\u{F701}", 125, []), ("\t", 48, []),
                                         ("a", 0, []), ("l", 37, .command), ("\u{1B}", 53, .shift)] {
            #expect(decide(characters, code, mods) == .swallow, "\(code) \(mods)")
        }
        #expect(decide(" ", 49, focused: true) == .swallow, "a focused control can't take it here: never the tile")
        #expect(decide("\r", 36, focused: true) == .swallow)
    }

    /// I1 end to end: the station window steps aside, and the attached pop-over's monitor consumes Esc
    /// (closing it), arrows and Tab; only a menu key equivalent goes on.
    @Test func noKeyReachesTheStationWindowWhileThePopoverShows() throws {
        _ = NSApplication.shared
        var pressed: [FrontPanelKey] = []
        let station = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                                backing: .buffered, defer: false)
        station.isReleasedWhenClosed = false
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        station.addChildWindow(child, ordered: .above)
        let stationMonitor = KeyboardShortcuts.MonitorView()
        stationMonitor.router = KeyboardRouter(map: KeyMap().resolved(for: .sds200))
        stationMonitor.press = { pressed.append($0) }
        stationMonitor.stepsAside = { true }
        station.contentView?.addSubview(stationMonitor)
        var closed = 0
        var commands: [QuickKeysKeyCommand] = []
        let own = QuickKeysKeyMonitor.MonitorView()
        own.isKey = { _ in true }
        own.isOnScreen = { _ in true }
        own.menuChords = { [KeyChord(key: "q", modifiers: [.command])] }
        own.perform = { commands.append($0) }
        own.close = { closed += 1 }
        child.contentView?.addSubview(own)
        defer {
            stationMonitor.removeFromSuperview(); own.removeFromSuperview()
            station.removeChildWindow(child); child.close(); station.close()
        }
        // Anything the station monitor passes on must then be consumed by the pop-over's.
        func reachesStation(_ event: NSEvent) -> Bool {
            guard let passed = stationMonitor.handle(event) else { return false }
            return own.handle(passed) != nil
        }
        #expect(!reachesStation(try key("\u{1B}", keyCode: 53, window: station)))
        #expect(closed == 1, "Esc closed the pop-over")
        for (characters, code) in [("\u{F702}", UInt16(123)), ("\u{F703}", 124), ("\u{F700}", 126), ("\t", 48), ("a", 0)] {
            #expect(!reachesStation(try key(characters, keyCode: code, window: station)), "\(code)")
        }
        #expect(reachesStation(try key("q", keyCode: 12, modifiers: .command, window: station)), "⌘Q still quits")
        #expect(pressed.isEmpty && commands.isEmpty)
    }

    /// I2: a focused button, switch or field keeps Space and Return (and every other key); only with
    /// nothing focused do they toggle the highlighted tile.
    @Test func aFocusedControlKeepsSpaceAndReturn() throws {
        _ = NSApplication.shared
        let panel = QuickKeysPanelController.makePanel(content: NSViewController(nibName: nil, bundle: nil), title: "Test")
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        defer { panel.close() }
        var commands: [QuickKeysKeyCommand] = []
        let focus = ControlFocus()
        let own = QuickKeysKeyMonitor.MonitorView()
        own.isKey = { _ in true }
        own.controlFocus = focus
        own.perform = { commands.append($0) }
        panel.contentView?.addSubview(own)
        let space = try key(" ", keyCode: 49, window: panel)
        let enter = try key("\r", keyCode: 36, window: panel)

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        panel.contentView?.addSubview(button)
        if panel.makeFirstResponder(button) {
            #expect(own.handle(space) != nil, "the focused button keeps Space")
            #expect(own.handle(enter) != nil)
        }
        #expect(panel.makeFirstResponder(nil))
        let id = UUID()
        focus.set(id, focused: true)
        #expect(own.handle(space) != nil, "a focused SwiftUI switch keeps Space")
        #expect(own.handle(enter) != nil)
        #expect(commands.isEmpty)
        focus.set(id, focused: false)
        #expect(own.handle(space) == nil)
        #expect(commands == [.toggle], "nothing focused: the highlighted tile")
    }

    /// I3: the station window steps aside exactly while the pop-over is attached: shown → true; torn off
    /// (the pop-over closes, the panel stays) → false; panel closed → false; `closeAll` → false.
    @Test func theStationStepsAsideOnlyWhileThePopoverIsAttached() throws {
        _ = NSApplication.shared
        let (session, dir) = try session(model: .sds200)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = QuickKeysPanelController()
        #expect(!controller.isPopoverShown)
        let popover = controller.makePopover(for: session)
        #expect(controller.isPopoverShown, "attached: the station window steps aside")
        let panel = try #require(controller.detachableWindow(for: popover))
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        #expect(!controller.isPopoverShown, "torn off: the station window's keys work again")
        panel.close()
        #expect(!controller.isPopoverShown)

        let again = controller.makePopover(for: session)
        #expect(controller.isPopoverShown)
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: again))
        #expect(!controller.isPopoverShown, "closed with no panel")

        _ = controller.makePopover(for: session)
        controller.closeAll()
        #expect(!controller.isPopoverShown)
    }

    /// I1 (found on the app): the attached pop-over can't become the key window, so its keys are addressed to
    /// the station window. Its monitor consumes the keys it takes (`aConsumedKeyGoesNoFurther`); as a backstop,
    /// should a key ever get past it, the station window's shortcuts (the Mac-style menu's Save, Open, Cancel,
    /// and "Send to Scanner") are off while the pop-over shows: the controller publishes it (`presence`), and
    /// the shortcuts read it.
    @Test func theStationsShortcutsAreOffWhileThePopoverShows() throws {
        _ = NSApplication.shared
        #expect(StationShortcuts.shortcut(.defaultAction, quickKeysShown: false) == .defaultAction)
        #expect(StationShortcuts.shortcut(.cancelAction, quickKeysShown: false) == .cancelAction)
        #expect(StationShortcuts.shortcut(.defaultAction, quickKeysShown: true) == nil)
        #expect(StationShortcuts.shortcut(.cancelAction, quickKeysShown: true) == nil)

        let (session, dir) = try session(model: .sds200)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = QuickKeysPanelController()
        #expect(!controller.presence.isPopoverShown)
        let popover = controller.makePopover(for: session)
        #expect(controller.presence.isPopoverShown)
        _ = try #require(controller.detachableWindow(for: popover))
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        #expect(!controller.presence.isPopoverShown, "torn off: the station's shortcuts are back")
        _ = controller.makePopover(for: session)
        #expect(controller.presence.isPopoverShown)
        controller.closeAll()
        #expect(!controller.presence.isPopoverShown)
    }

    /// I1 root cause (found on the app): a key a monitor consumes must go no further. Both monitors
    /// installed `self?.handle(event) ?? event`, whose optional chaining turns a consumed (nil) result
    /// back into the event, so AppKit dispatched every key anyway: the station's entry field got the
    /// pop-over's digits and its Save button the pop-over's Return. Their installed closures now go through
    /// `LocalKeyMonitor.forward`, which keeps nil as nil.
    @Test func aConsumedKeyGoesNoFurther() throws {
        _ = NSApplication.shared
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let four = try key("4", keyCode: 21, window: window)
        #expect(LocalKeyMonitor.forward(four, to: { _ in nil }) == nil, "consumed stays consumed")
        #expect(LocalKeyMonitor.forward(four, to: { $0 }) === four)
        #expect(LocalKeyMonitor.forward(four, to: nil) === four, "a monitor whose view is gone passes")

        var pressed: [FrontPanelKey] = []
        let stationMonitor = KeyboardShortcuts.MonitorView()
        stationMonitor.router = KeyboardRouter(map: KeyMap().resolved(for: .sds200))
        stationMonitor.press = { pressed.append($0) }
        window.contentView?.addSubview(stationMonitor)
        defer { stationMonitor.removeFromSuperview() }
        #expect(LocalKeyMonitor.forward(four, to: stationMonitor.handle) == nil, "the station's pressed key")
        #expect(pressed == [.digit4])

        var commands: [QuickKeysKeyCommand] = []
        let own = QuickKeysKeyMonitor.MonitorView()
        own.isKey = { _ in true }
        own.perform = { commands.append($0) }
        window.contentView?.addSubview(own)
        defer { own.removeFromSuperview() }
        #expect(LocalKeyMonitor.forward(four, to: own.handle) == nil, "the keypad's digit")
        #expect(commands == [.digit(4)])
    }

    /// Fix round 2: the closures the app installs as local monitors (`monitorBody`, what
    /// `viewDidMoveToWindow` hands `NSEvent.addLocalMonitorForEvents`) keep a consumed key consumed and
    /// pass the rest. Putting back `self?.handle(event) ?? event` there fails this.
    @Test func theInstalledMonitorsKeepAConsumedKeyConsumed() throws {
        _ = NSApplication.shared
        let station = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                                backing: .buffered, defer: false)
        station.isReleasedWhenClosed = false
        let panel = QuickKeysPanelController.makePanel(content: NSViewController(nibName: nil, bundle: nil), title: "Test")
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))

        var pressed: [FrontPanelKey] = []
        let stationMonitor = KeyboardShortcuts.MonitorView()
        stationMonitor.router = KeyboardRouter(map: KeyMap().resolved(for: .sds200))
        stationMonitor.press = { pressed.append($0) }
        station.contentView?.addSubview(stationMonitor)  // installs its monitor

        var commands: [QuickKeysKeyCommand] = []
        let own = QuickKeysKeyMonitor.MonitorView()
        own.isKey = { _ in true }
        own.perform = { commands.append($0) }
        panel.contentView?.addSubview(own)  // installs its monitor
        defer {
            stationMonitor.removeFromSuperview(); own.removeFromSuperview()
            station.close(); panel.close()
        }
        #expect(stationMonitor.isMonitoring && own.isMonitoring, "both installed in their windows")

        let stationFour = try key("4", keyCode: 21, window: station)
        #expect(stationMonitor.monitorBody(stationFour) == nil, "the pressed scanner key goes no further")
        #expect(pressed == [.digit4])
        let stationX = try key("x", keyCode: 7, window: station)
        #expect(stationMonitor.monitorBody(stationX) === stationX, "an unmapped key goes on")

        let panelFour = try key("4", keyCode: 21, window: panel)
        #expect(own.monitorBody(panelFour) == nil, "the keypad's digit goes no further")
        #expect(commands == [.digit(4)])
        let panelA = try key("a", keyCode: 0, window: panel)
        #expect(own.monitorBody(panelA) === panelA)
        #expect(pressed == [.digit4], "the panel's digit never reached the scanner")
    }

    /// Fix round 2: the monitor hands the routing its real control focus on the attached path: with a
    /// pop-over control focused, Space addressed to the station window is swallowed, never the tile's
    /// toggle; with none focused, it toggles.
    @Test func theAttachedPathUsesTheControlFocus() throws {
        _ = NSApplication.shared
        let station = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                                backing: .buffered, defer: false)
        station.isReleasedWhenClosed = false
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        station.addChildWindow(child, ordered: .above)
        let focus = ControlFocus()
        var commands: [QuickKeysKeyCommand] = []
        let own = QuickKeysKeyMonitor.MonitorView()
        own.isKey = { _ in true }
        own.isOnScreen = { _ in true }
        own.controlFocus = focus
        own.perform = { commands.append($0) }
        child.contentView?.addSubview(own)
        defer { own.removeFromSuperview(); station.removeChildWindow(child); child.close(); station.close() }

        let space = try key(" ", keyCode: 49, window: station)
        let id = UUID()
        focus.set(id, focused: true)
        #expect(own.monitorBody(space) == nil, "swallowed")
        #expect(commands.isEmpty, "a focused control's Space never toggles the tile")
        focus.set(id, focused: false)
        #expect(own.monitorBody(space) == nil)
        #expect(commands == [.toggle])
    }

    /// I3 (M12): the station window closing (its red button, ⌘W, Disconnect) closes the pop-over and the
    /// panel and the model, whatever the SwiftUI view does.
    @Test func closingTheStationWindowClosesEverything() throws {
        _ = NSApplication.shared
        let (session, dir) = try session(model: .sds200)
        defer { try? FileManager.default.removeItem(at: dir) }
        let station = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                               backing: .buffered, defer: false)
        station.isReleasedWhenClosed = false
        let button = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        station.contentView?.addSubview(button)
        let controller = QuickKeysPanelController()
        controller.anchorFound(button)
        let popover = controller.makePopover(for: session)
        let panel = try #require(controller.detachableWindow(for: popover))
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        #expect(session.quickKeys.isOpen && controller.panel != nil)
        station.close()
        #expect(!session.quickKeys.isOpen, "the model closed with the station window")
        #expect(controller.panel == nil && !panel.isVisible && !controller.isPopoverShown)
    }
}
#endif
