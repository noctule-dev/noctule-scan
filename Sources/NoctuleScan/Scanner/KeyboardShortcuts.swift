// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import NoctuleKit
import SwiftUI

/// Key events to `KeyChord`s, in the `KeyMap` spelling ("4", "a", "↩", "←", "space", "F1", "⌘4").
enum KeyEventMapping {
    /// Keys named by key code rather than by the character they type.
    private static let named: [UInt16: String] = [
        36: "↩", 76: "↩",  // return, keypad enter
        49: "space",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// The chord for a key-down. `characters` is what the key types with no modifiers applied
    /// (`NSEvent.characters(byApplyingModifiers: [])`), so ⇧4 is "4" with ⇧, not "$". Returns nil
    /// for keys a key map can't name (tab, escape, delete, other function keys), which then keep
    /// their usual meaning.
    static func chord(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> KeyChord? {
        let mods = keyModifiers(modifiers)
        if let name = named[keyCode] { return KeyChord(key: name, modifiers: mods) }
        guard let characters, characters.count == 1, let scalar = characters.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F,
              !(0xF700...0xF8FF).contains(scalar.value)  // AppKit's function-key range
        else { return nil }
        return KeyChord(key: characters.lowercased(), modifiers: mods)
    }

    static func keyModifiers(_ flags: NSEvent.ModifierFlags) -> Set<KeyModifier> {
        var mods: Set<KeyModifier> = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        return mods
    }

    /// Every key equivalent in `menu` and its submenus. An upper-case equivalent implies ⇧.
    static func menuChords(in menu: NSMenu) -> Set<KeyChord> {
        var chords: Set<KeyChord> = []
        for item in menu.items {
            if let submenu = item.submenu { chords.formUnion(menuChords(in: submenu)) }
            let equivalent = item.keyEquivalent
            guard !equivalent.isEmpty else { continue }
            var mods = keyModifiers(item.keyEquivalentModifierMask)
            if equivalent != equivalent.lowercased() { mods.insert(.shift) }
            chords.insert(KeyChord(key: equivalent.lowercased(), modifiers: mods))
        }
        return chords
    }
}

/// What the scanner window does with a key-down.
///
/// The rule, in order:
/// 1. A control that consumes the keys has keyboard focus: pass, so typing in a text field never
///    presses keys and ←/→/space/↩ operate a focused slider, toggle, button or menu. That is: the
///    window's first responder is a text view (`NSText`, the field editor) or an AppKit control
///    (`NSControl`) other than a table or outline view, or a SwiftUI control reports its focus
///    through `ControlFocus` (`.tracksKeyboardFocus()`; SwiftUI's own controls aren't AppKit
///    views, so the first responder can't show their focus). Sticky responders that AppKit
///    makes first responder on an ordinary click and that nothing takes back (a SwiftUI `List`'s
///    outline view, a selectable `Text`'s text-interaction view, any other plain view) don't
///    count, or the scanner keys would stop after a click until the user pressed Tab.
/// 2. The chord isn't in the station's key map: pass.
/// 3. The chord is also a key equivalent in the app's menus (⌘Q, ⌘W, ⌘, …): pass, so the menu
///    wins even if a key map names it.
/// 4. A key repeat (held key): only the scroll keys repeat (the session's queue caps a burst at 8);
///    any other repeat is swallowed, since the scanner's own keys don't repeat.
/// 5. Otherwise press the mapped key.
///
/// While the Mac-style menu has the keys (`macMenuActive`, `MacMenuKeys`), after rules 1 and 3 the
/// bare ↑, ↓, ↩ and Esc are the menu's commands (only ↑/↓ repeat; a repeated ↩ or Esc is
/// swallowed), any other chord the key map maps is swallowed (Avoid would leave the menu on the
/// scanner), and unmapped chords pass.
///
/// While the Mac-style view shows and the scanner is in a menu (`macMenuShowing`) but no handler
/// is installed (the menu not read yet, pushes stalled, or a handler lost), it fails closed: after
/// rules 1 and 3 every chord the key map maps is swallowed, never pressed as a raw key (↩ would be
/// `KEY,E,P` with no destructive check, on the scanner's highlight). The Scanner view never sets it.
enum KeyRouting {
    enum Decision: Equatable {
        /// Let AppKit handle the event as usual.
        case pass
        /// Consume the event and do nothing.
        case swallow
        /// Consume the event and press this key.
        case press(FrontPanelKey)
        /// Consume the event and give this command to the Mac-style menu.
        case menu(MacMenuCommand)
    }

    /// Escape, which `KeyEventMapping` leaves unnamed (a key map can't name it); the monitor
    /// passes this chord for it so the Mac-style menu can take it.
    static let escape = KeyChord(key: "⎋")

    private static let macMenuCommands: [KeyChord: MacMenuCommand] = [
        KeyChord(key: "↑"): .moveUp, KeyChord(key: "↓"): .moveDown, KeyChord(key: "↩"): .activate, escape: .back,
    ]

    static func decide(chord: KeyChord?, router: KeyboardRouter, isRepeat: Bool, focusElsewhere: Bool,
                       menuChords: Set<KeyChord>, macMenuActive: Bool = false, macMenuShowing: Bool = false) -> Decision {
        guard !focusElsewhere, let chord else { return .pass }
        if macMenuActive || macMenuShowing {
            guard !menuChords.contains(chord) else { return .pass }
            if macMenuActive, let command = macMenuCommands[chord] {
                if isRepeat && command != .moveUp && command != .moveDown { return .swallow }
                return .menu(command)
            }
            return router.key(for: chord) == nil ? .pass : .swallow
        }
        guard let key = router.key(for: chord) else { return .pass }
        guard !menuChords.contains(chord) else { return .pass }
        if isRepeat && key != .scrollLeft && key != .scrollRight { return .swallow }
        return .press(key)
    }
}

/// The body of an `NSEvent` local monitor that forwards to a view's `handle`. Not
/// `self?.handle(event) ?? event`: optional chaining flattens the result, so a consumed event (nil) would
/// come back as the event and AppKit would dispatch it anyway (LESSONS.md 2026-11-18).
enum LocalKeyMonitor {
    /// `handler`'s answer (nil: consumed), or the event untouched when there is no handler (the view is gone).
    static func forward(_ event: NSEvent, to handler: ((NSEvent) -> NSEvent?)?) -> NSEvent? {
        guard let handler else { return event }
        return handler(event)
    }
}

/// Which SwiftUI controls in a window have keyboard focus (Full Keyboard Access, or a click on a
/// control that takes focus). Controls report through `.tracksKeyboardFocus()`; the key monitor
/// reads `isActive` at event time.
@MainActor final class ControlFocus {
    private var focused: Set<UUID> = []
    var isActive: Bool { !focused.isEmpty }
    func set(_ id: UUID, focused isFocused: Bool) {
        if isFocused { focused.insert(id) } else { focused.remove(id) }
    }
}

extension EnvironmentValues {
    @Entry var controlFocus: ControlFocus? = nil
    @Entry var macMenuKeys: MacMenuKeys? = nil
}

private struct TracksKeyboardFocus: ViewModifier {
    @Environment(\.controlFocus) private var tracker
    @FocusState private var isFocused: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: isFocused) { _, now in tracker?.set(id, focused: now) }
            .onDisappear { tracker?.set(id, focused: false) }
    }
}

extension View {
    /// Reports this control's keyboard focus to the window's `ControlFocus`, so the scanner's
    /// keyboard shortcuts step aside while it has focus.
    func tracksKeyboardFocus() -> some View { modifier(TracksKeyboardFocus()) }
}

/// Installs an `NSEvent` local key-down monitor for as long as this view is in a window, and
/// acts only on events for that window while it is key. Each event goes through `KeyRouting`.
/// Events for any other window (the Quick Keys pop-over's, its torn-off panel) are left alone, and
/// while `stepsAside` says so (the Quick Keys pop-over shows on this window) it acts on none at all.
struct KeyboardShortcuts: NSViewRepresentable {
    let router: KeyboardRouter
    let controlFocus: ControlFocus
    /// The window's Mac-style menu keys; asked first while it has a handler.
    var menuKeys: MacMenuKeys? = nil
    /// Asked at event time: the Mac-style view shows and the scanner is in a menu (`KeyRouting`).
    var macMenuShowing: @MainActor () -> Bool = { false }
    /// Asked at event time: the window's Quick Keys pop-over shows, so no key goes to the scanner.
    var stepsAside: @MainActor () -> Bool = { false }
    let press: @MainActor (FrontPanelKey) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.router = router
        view.controlFocus = controlFocus
        view.menuKeys = menuKeys
        view.macMenuShowing = macMenuShowing
        view.stepsAside = stepsAside
        view.press = press
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    final class MonitorView: NSView {
        var router = KeyboardRouter(map: [:])
        var press: @MainActor (FrontPanelKey) -> Void = { _ in }
        var controlFocus: ControlFocus?
        var menuKeys: MacMenuKeys?
        var macMenuShowing: @MainActor () -> Bool = { false }
        var stepsAside: @MainActor () -> Bool = { false }
        private var monitor: Any?
        /// The closure installed as the local monitor (`viewDidMoveToWindow`), and the one tests call: a
        /// key `handle` consumes (nil) must stay consumed. Never `self?.handle(event) ?? event` here:
        /// optional chaining flattens nil back into the event (LESSONS.md 2026-11-18).
        private(set) lazy var monitorBody: @MainActor (NSEvent) -> NSEvent? = { [weak self] event in
            LocalKeyMonitor.forward(event, to: self?.handle)
        }
        /// A monitor is installed (the view is in a window).
        var isMonitoring: Bool { monitor != nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: monitorBody)
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The monitor body: nil when the event was consumed.
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.isKeyWindow, !stepsAside() else { return event }
            let chord = KeyEventMapping.chord(characters: event.characters(byApplyingModifiers: []),
                                              keyCode: event.keyCode, modifiers: event.modifierFlags)
                ?? (event.keyCode == Self.escapeKeyCode
                    ? KeyChord(key: KeyRouting.escape.key, modifiers: KeyEventMapping.keyModifiers(event.modifierFlags))
                    : nil)
            let menuChords = NSApp.mainMenu.map(KeyEventMapping.menuChords(in:)) ?? []
            switch KeyRouting.decide(chord: chord, router: router, isRepeat: event.isARepeat,
                                     focusElsewhere: Self.focusElsewhere(in: window, controls: controlFocus),
                                     menuChords: menuChords, macMenuActive: menuKeys?.isActive ?? false,
                                     macMenuShowing: macMenuShowing()) {
            case .pass: return event
            case .swallow: return nil
            case .press(let key):
                press(key)
                return nil
            case .menu(let command):
                menuKeys?.handler?(command)
                return nil
            }
        }

        private static let escapeKeyCode: UInt16 = 53

        /// Rule 1 of `KeyRouting`: a text view, an AppKit control that consumes keys (not a
        /// table or outline view), or a tracked SwiftUI control has focus.
        static func focusElsewhere(in window: NSWindow, controls: ControlFocus?) -> Bool {
            if controls?.isActive == true { return true }
            guard let responder = window.firstResponder else { return false }
            if responder is NSText { return true }
            return responder is NSControl && !(responder is NSTableView)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
