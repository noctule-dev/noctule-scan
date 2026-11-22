// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
@testable import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI
import Testing
@testable import NoctuleScan

/// The monitor end to end: a key-down that `NSApp.sendEvent` dispatches to the view's window
/// (local monitors run there) goes through `KeyRouting` to `press`; `handle` says whether it was
/// consumed. Other windows' events, text fields, and a view out of its window are left alone.
/// The window claims to be key (a test process can't become active).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct KeyboardMonitorTests {
    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    struct Harness {
        let window: KeyWindow
        let view: KeyboardShortcuts.MonitorView
    }

    private func makeHarness(focus: ControlFocus? = nil,
                             _ pressed: @escaping @MainActor (FrontPanelKey) -> Void) -> Harness {
        _ = NSApplication.shared
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = KeyboardShortcuts.MonitorView()
        view.controlFocus = focus
        view.router = KeyboardRouter(map: KeyMap().resolved(for: .sds200))
        view.press = pressed
        window.contentView?.addSubview(view)
        return Harness(window: window, view: view)
    }

    private func key(_ characters: String, keyCode: UInt16, windowNumber: Int) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: keyCode))
    }

    /// Dispatches the event through the app, as AppKit does for a real key-down.
    private func send(_ characters: String, keyCode: UInt16, windowNumber: Int) throws {
        NSApp.sendEvent(try key(characters, keyCode: keyCode, windowNumber: windowNumber))
    }

    @Test func digitKeyPressesThroughTheMonitor() throws {
        var pressed: [FrontPanelKey] = []
        let h = makeHarness { pressed.append($0) }
        defer { h.view.removeFromSuperview(); h.window.close() }
        try send("4", keyCode: 21, windowNumber: h.window.windowNumber)
        #expect(pressed == [.digit4], "the installed monitor pressed it")
        #expect(h.view.handle(try key("4", keyCode: 21, windowNumber: h.window.windowNumber)) == nil, "consumed")
        #expect(pressed == [.digit4, .digit4])
        #expect(h.view.handle(try key("x", keyCode: 7, windowNumber: h.window.windowNumber)) != nil, "unmapped: passed on")
        #expect(pressed == [.digit4, .digit4])
    }

    @Test func ignoresTextFieldsAndOtherWindows() throws {
        var pressed: [FrontPanelKey] = []
        let h = makeHarness { pressed.append($0) }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { h.view.removeFromSuperview(); h.window.close(); other.close() }
        #expect(h.view.handle(try key("4", keyCode: 21, windowNumber: other.windowNumber)) != nil, "another window's key")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        h.window.contentView?.addSubview(field)
        #expect(h.window.makeFirstResponder(field))
        #expect(h.view.handle(try key("4", keyCode: 21, windowNumber: h.window.windowNumber)) != nil, "typing in a text field")
        #expect(pressed.isEmpty)
    }

    /// QA (Task 12): with a slider, toggle or list focused, ←/→/space/↩ operate it, not the scanner.
    @Test func focusedControlsKeepTheirKeys() throws {
        var pressed: [FrontPanelKey] = []
        let focus = ControlFocus()
        let h = makeHarness(focus: focus) { pressed.append($0) }
        defer { h.view.removeFromSuperview(); h.window.close() }
        let right = try key("\u{F703}", keyCode: 124, windowNumber: h.window.windowNumber)

        // An AppKit control that takes keys.
        let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        h.window.contentView?.addSubview(slider)
        #expect(h.window.makeFirstResponder(slider))
        #expect(h.view.handle(right) != nil, "the slider gets →")
        #expect(h.window.makeFirstResponder(nil))
        #expect(h.view.handle(right) == nil, "nothing focused: → scrolls the scanner")
        #expect(pressed == [.scrollRight])

        // A SwiftUI control reporting its focus.
        let id = UUID()
        focus.set(id, focused: true)
        #expect(h.view.handle(right) != nil)
        #expect(h.view.handle(try key(" ", keyCode: 49, windowNumber: h.window.windowNumber)) != nil)
        focus.set(id, focused: false)
        #expect(h.view.handle(right) == nil)
        #expect(pressed == [.scrollRight, .scrollRight])
    }

    /// QA (Task 13, I1): views AppKit makes first responder on an ordinary click, and that
    /// nothing takes back, must not switch the scanner keys off: a SwiftUI `List`'s outline view,
    /// a selectable `Text`'s text-interaction view, or any plain view that accepts first responder.
    @Test func stickyRespondersDontBlockScannerKeys() throws {
        var pressed: [FrontPanelKey] = []
        let h = makeHarness { pressed.append($0) }
        defer { h.view.removeFromSuperview(); h.window.close() }
        let right = try key("\u{F703}", keyCode: 124, windowNumber: h.window.windowNumber)

        struct Sticky: View {
            var body: some View {
                VStack {
                    List(0..<3, id: \.self) { Text("Row \($0)") }.frame(height: 80)
                    Text("Fire Dispatch").textSelection(.enabled)
                }
            }
        }
        let host = NSHostingView(rootView: Sticky())
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 140)
        h.window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(host)
        let outline = try #require(views.first { $0 is NSTableView }, "a SwiftUI List is an AppKit table")
        let candidates = [outline] + views.filter { $0 !== outline && $0.acceptsFirstResponder && !($0 is NSControl) }
        final class PlainResponder: NSView { override var acceptsFirstResponder: Bool { true } }
        let plain = PlainResponder(frame: .zero)
        h.window.contentView?.addSubview(plain)

        var checked = 0
        for view in candidates + [plain] where h.window.makeFirstResponder(view) {
            checked += 1
            #expect(h.view.handle(right) == nil, "\(type(of: view)) as first responder blocked the scanner keys")
        }
        #expect(checked >= 2, "the outline view and the plain responder at least")
        #expect(pressed.count == checked)
    }

    // MARK: The Mac-style menu (Plan 6 Task 5)

    private let router = KeyboardRouter(map: KeyMap().resolved(for: .sds200))

    private func decide(_ chord: KeyChord?, macMenu: Bool, isRepeat: Bool = false, focusElsewhere: Bool = false,
                        menuChords: Set<KeyChord> = []) -> KeyRouting.Decision {
        KeyRouting.decide(chord: chord, router: router, isRepeat: isRepeat, focusElsewhere: focusElsewhere,
                          menuChords: menuChords, macMenuActive: macMenu)
    }

    @Test func macMenuTakesArrowsReturnAndEscape() throws {
        let up = try #require(KeyChord("↑")), down = try #require(KeyChord("↓")), ret = try #require(KeyChord("↩"))
        let esc = KeyRouting.escape
        #expect(decide(up, macMenu: true) == .menu(.moveUp))
        #expect(decide(down, macMenu: true) == .menu(.moveDown))
        #expect(decide(ret, macMenu: true) == .menu(.activate))
        #expect(decide(esc, macMenu: true) == .menu(.back))
        // Outside the Mac-style menu: today's decisions.
        #expect(decide(up, macMenu: false) == .pass)
        #expect(decide(down, macMenu: false) == .pass)
        #expect(decide(ret, macMenu: false) == .press(.enterYes))
        #expect(decide(esc, macMenu: false) == .pass)
        #expect(KeyRouting.decide(chord: ret, router: router, isRepeat: false, focusElsewhere: false, menuChords: [])
                == .press(.enterYes), "the default is false")

        // Through the installed monitor: the window's MacMenuKeys gets the command, Esc included.
        var commands: [MacMenuCommand] = []
        var pressed: [FrontPanelKey] = []
        let keys = MacMenuKeys()
        let h = makeHarness { pressed.append($0) }
        defer { h.view.removeFromSuperview(); h.window.close() }
        h.view.menuKeys = keys
        let escape = try key("\u{1B}", keyCode: 53, windowNumber: h.window.windowNumber)
        let returnKey = try key("\r", keyCode: 36, windowNumber: h.window.windowNumber)
        #expect(h.view.handle(escape) != nil, "no handler: Esc keeps its usual meaning")
        #expect(h.view.handle(returnKey) == nil)
        #expect(pressed == [.enterYes])
        keys.handler = { commands.append($0) }
        #expect(keys.isActive)
        #expect(h.view.handle(escape) == nil)
        #expect(h.view.handle(returnKey) == nil)
        #expect(h.view.handle(try key("\u{F700}", keyCode: 126, windowNumber: h.window.windowNumber)) == nil)
        #expect(commands == [.back, .activate, .moveUp])
        #expect(pressed == [.enterYes], "nothing pressed on the scanner while the menu has the keys")
        keys.handler = nil
        #expect(!keys.isActive)
    }

    @Test func macMenuSwallowsOtherScannerKeys() throws {
        let avoid = try #require(KeyChord("a"))
        #expect(decide(avoid, macMenu: true) == .swallow, "Avoid would leave the menu on the scanner")
        #expect(decide(KeyChord(key: "→"), macMenu: true) == .swallow)
        #expect(decide(KeyChord(key: "4"), macMenu: true) == .swallow)
        #expect(decide(avoid, macMenu: false) == .press(.avoid))
    }

    @Test func macMenuPassesMenuEquivalentsAndUnmapped() throws {
        let quit = try #require(KeyChord("⌘q"))
        #expect(decide(quit, macMenu: true, menuChords: [quit]) == .pass)
        #expect(decide(KeyChord(key: "x"), macMenu: true) == .pass)
        #expect(decide(nil, macMenu: true) == .pass)
        #expect(decide(KeyChord(key: "↑", modifiers: [.command]), macMenu: true) == .pass, "only the bare keys are the menu's")
    }

    @Test func textFieldFocusWins() throws {
        #expect(decide(KeyChord(key: "↩"), macMenu: true, focusElsewhere: true) == .pass)
        #expect(decide(KeyRouting.escape, macMenu: true, focusElsewhere: true) == .pass)
        #expect(decide(KeyChord(key: "↓"), macMenu: true, focusElsewhere: true) == .pass)
    }

    @Test func onlyArrowsRepeatInMacMenu() throws {
        #expect(decide(KeyChord(key: "↑"), macMenu: true, isRepeat: true) == .menu(.moveUp))
        #expect(decide(KeyChord(key: "↓"), macMenu: true, isRepeat: true) == .menu(.moveDown))
        #expect(decide(KeyChord(key: "↩"), macMenu: true, isRepeat: true) == .swallow)
        #expect(decide(KeyRouting.escape, macMenu: true, isRepeat: true) == .swallow)
        #expect(decide(KeyChord(key: "a"), macMenu: true, isRepeat: true) == .swallow)
    }

    // MARK: Fail closed while the Mac-style menu shows (final review M1)

    private func decideShowing(_ chord: KeyChord?, isRepeat: Bool = false, focusElsewhere: Bool = false,
                               menuChords: Set<KeyChord> = [], handler: Bool = false) -> KeyRouting.Decision {
        KeyRouting.decide(chord: chord, router: router, isRepeat: isRepeat, focusElsewhere: focusElsewhere,
                          menuChords: menuChords, macMenuActive: handler, macMenuShowing: true)
    }

    /// The Mac-style view shows and the scanner is in a menu, but no handler is installed (the menu
    /// content not read yet, or a handler lost): a mapped chord is swallowed, never pressed as a raw
    /// key (Return would be `KEY,E,P` with no destructive check, Avoid would act on the scanner).
    @Test func macMenuShowingWithoutAHandlerSwallowsScannerKeys() throws {
        let ret = KeyChord(key: "↩"), avoid = KeyChord(key: "a"), right = KeyChord(key: "→")
        #expect(decideShowing(ret) == .swallow)
        #expect(decideShowing(avoid) == .swallow)
        #expect(decideShowing(right) == .swallow)
        #expect(decideShowing(KeyChord(key: "4")) == .swallow)
        #expect(decideShowing(right, isRepeat: true) == .swallow)
        // Unmapped chords, menu key equivalents and a focused text field still pass.
        #expect(decideShowing(KeyChord(key: "x")) == .pass)
        #expect(decideShowing(KeyRouting.escape) == .pass)
        #expect(decideShowing(nil) == .pass)
        let quit = try #require(KeyChord("⌘q"))
        #expect(decideShowing(quit, menuChords: [quit]) == .pass)
        #expect(decideShowing(ret, focusElsewhere: true) == .pass)
        // With a handler: as before.
        #expect(decideShowing(ret, handler: true) == .menu(.activate))
        #expect(decideShowing(KeyChord(key: "↑"), handler: true) == .menu(.moveUp))
        #expect(decideShowing(avoid, handler: true) == .swallow)
        // Not showing (the Scanner view, or no menu): keys are pressed, as by design.
        #expect(KeyRouting.decide(chord: ret, router: router, isRepeat: false, focusElsewhere: false, menuChords: [],
                                  macMenuActive: false, macMenuShowing: false) == .press(.enterYes))

        // Through the monitor: asked at event time.
        var pressed: [FrontPanelKey] = []
        let h = makeHarness { pressed.append($0) }
        defer { h.view.removeFromSuperview(); h.window.close() }
        final class Showing { var value = true }
        let showing = Showing()
        h.view.menuKeys = MacMenuKeys()
        h.view.macMenuShowing = { showing.value }
        let returnKey = try key("\r", keyCode: 36, windowNumber: h.window.windowNumber)
        #expect(h.view.handle(returnKey) == nil, "consumed")
        #expect(h.view.handle(try key("a", keyCode: 0, windowNumber: h.window.windowNumber)) == nil)
        #expect(pressed.isEmpty, "nothing pressed while the menu shows without a handler")
        showing.value = false
        #expect(h.view.handle(returnKey) == nil)
        #expect(pressed == [.enterYes])
    }

    /// The menu's handler comes back after an entry screen whose field had focus: list, entry
    /// (field focused, handler off), list (handler on, and ↑ ↓ ↩ Esc are the menu's).
    @Test func theHandlerReturnsAfterAnEntryScreen() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let environment = SessionEnvironment(
            settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
            recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
            cooldownStore: InMemoryRTSPCooldownStore(), cooldown: .milliseconds(300))
        var station = Station()
        station.name = "Test Station"
        let session = StationSession(station: station, environment: environment)  // never started
        let list = try MenuScreen(xml: NoctuleKit.XMLNode.parse(Data(
            (#"<MSI Name="Lists" Index="4293060002" MenuType="TypeSelect" Selected="0">"#
             + (0..<3).map { #"<MenuItem Name="List \#($0)" Index="\#($0)" />"# }.joined() + "</MSI>").utf8)))
        let entry = try MenuScreen(xml: NoctuleKit.XMLNode.parse(Data(
            (#"<MSI Name="Edit Name" Index="4293060020" MenuType="TypeInput" Value="Custom 3">"#
             + #"<MenuInput MaxLength="64" EnableKeys="ABCabc123 " /></MSI>"#).utf8)))
        let keys = MacMenuKeys()
        let focus = ControlFocus()
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = container
        let host = NSHostingView(rootView: MacMenuView(session: session)
            .environment(\.macMenuKeys, keys).environment(\.controlFocus, focus))
        host.frame = container.bounds
        container.addSubview(host)
        var pressed: [FrontPanelKey] = []
        let monitor = KeyboardShortcuts.MonitorView()
        monitor.router = router
        monitor.controlFocus = focus
        monitor.menuKeys = keys
        monitor.macMenuShowing = { true }
        monitor.press = { pressed.append($0) }
        container.addSubview(monitor)
        defer { monitor.removeFromSuperview(); host.removeFromSuperview(); window.close() }

        @MainActor func settle(until condition: @MainActor () -> Bool) async throws {
            for _ in 0..<100 where !condition() {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        session.menu.show(.list(list), title: "Lists", menuIndex: list.menuIndex)
        try await settle { keys.isActive }
        #expect(keys.isActive, "the list installs the handler")

        session.menu.show(.entry(entry), title: "Edit Name", menuIndex: entry.menuIndex)
        try await settle { window.firstResponder is NSText && !keys.isActive }
        #expect(window.firstResponder is NSText, "the entry field takes focus")
        #expect(!keys.isActive, "the field has its own Return and Esc")

        session.menu.show(.list(list), title: "Lists", menuIndex: list.menuIndex)
        try await settle { keys.isActive }
        #expect(keys.isActive, "the list installs the handler again")
        let focusElsewhere = KeyboardShortcuts.MonitorView.focusElsewhere(in: window, controls: focus)
        #expect(!focusElsewhere, "the gone field's focus doesn't linger: \(String(describing: window.firstResponder))")
        for (chord, command) in [(KeyChord(key: "↑"), MacMenuCommand.moveUp), (KeyChord(key: "↓"), .moveDown),
                                 (KeyChord(key: "↩"), .activate), (KeyRouting.escape, .back)] {
            #expect(KeyRouting.decide(chord: chord, router: router, isRepeat: false, focusElsewhere: focusElsewhere,
                                      menuChords: [], macMenuActive: keys.isActive, macMenuShowing: true) == .menu(command),
                    "\(chord)")
        }
        // Through the monitor: ↓ is the menu's (a local move; nothing is pressed or sent).
        #expect(monitor.handle(try key("\u{F701}", keyCode: 125, windowNumber: window.windowNumber)) == nil)
        #expect(pressed.isEmpty)
        session.menu.show(nil, title: nil, menuIndex: nil)
    }

    @Test func removedFromItsWindowStopsListening() throws {
        var pressed: [FrontPanelKey] = []
        let h = makeHarness { pressed.append($0) }
        defer { h.window.close() }
        h.view.removeFromSuperview()
        try send("4", keyCode: 21, windowNumber: h.window.windowNumber)
        #expect(pressed.isEmpty, "the monitor went away with the window")
    }
}
#endif
