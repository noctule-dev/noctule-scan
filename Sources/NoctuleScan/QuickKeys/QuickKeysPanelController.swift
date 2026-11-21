// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import SwiftUI

/// One station window's Quick Keys pop-over and its tear-off (design §5.5 "Opening"): an `NSPopover`
/// under the toolbar button that, dragged away, becomes a floating panel (`detachableWindow(for:)`)
/// which stays open until closed. One of each per station window; the toolbar button brings an open
/// panel to the front rather than opening another.
///
/// **The model's hold.** Showing the pop-over opens the session's `QuickKeysModel` (`open()`: the keypad
/// is read, then the trees); it stays open through a tear-off, and closes (`close()`: reads stop) once
/// neither the pop-over nor the panel is left. The station window calls `closeAll()` when it goes away
/// or its session changes, so a stopped session's model (left open by the stop, Task 7) never stays open.
@MainActor final class QuickKeysPanelController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private(set) var popover: NSPopover? {
        didSet { presence.isPopoverShown = popover != nil }
    }
    /// Whether the pop-over is attached, for the station window's views (`StationShortcuts`).
    let presence = QuickKeysPresence()
    private(set) var panel: NSPanel?
    /// The session whose model is open, or was last.
    private var session: StationSession?
    /// Shared by the pop-over and its panel, so a tear-off keeps the ten, highlight and search.
    let state = QuickKeysViewState()
    /// The toolbar button's view, the pop-over's anchor (`anchorFound(_:)`).
    private(set) weak var anchor: NSView?
    /// The station window being watched for its close.
    private weak var stationWindow: NSWindow?
    private var stationCloseObserver: (any NSObjectProtocol)?
    /// When the pop-over last closed: a click on the toolbar button closes a transient pop-over on mouse
    /// down, and its action must not open it again at once.
    private var closedAt: ContinuousClock.Instant?
    /// The panel's first key-ness cleared its first responder.
    private var panelFocusSettled = false

    /// The pop-over is shown on the station window (not torn off): the station window's key monitor
    /// presses nothing meanwhile (`KeyboardShortcuts.stepsAside`).
    var isPopoverShown: Bool { popover != nil }

    /// The toolbar button's view is in its window: the pop-over points at it, and the station window's
    /// close (its close button, ⌘W, Disconnect) closes the pop-over, the panel and the model.
    func anchorFound(_ view: NSView) {
        anchor = view
        guard let window = view.window, window !== stationWindow else { return }
        if let stationCloseObserver { NotificationCenter.default.removeObserver(stationCloseObserver) }
        stationWindow = window
        stationCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
    }

    /// The toolbar button: brings a torn-off panel forward, closes a shown pop-over, else shows it.
    func toggle(session: StationSession) {
        if let panel, self.session === session {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        if let popover {
            popover.performClose(nil)
            return
        }
        if let closedAt, closedAt.duration(to: .now) < .milliseconds(300) { return }
        guard let anchor, anchor.window != nil else { return }
        let popover = makePopover(for: session)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // Its keys are its own: make its window key, with nothing (not the search field) focused.
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            window.makeFirstResponder(nil)
        }
    }

    /// A new pop-over on `session`'s model, opened (not shown: `toggle` shows it).
    func makePopover(for session: StationSession) -> NSPopover {
        if self.session !== session { closeAll() }
        self.session = session
        if panel == nil { state.reset() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hosting(session, close: { [weak self, weak popover] in
            guard let popover, self?.popover === popover else { return }
            popover.performClose(nil)
        })
        self.popover = popover
        session.quickKeys.open()
        return popover
    }

    /// Closes the pop-over and the panel, and the model with them.
    func closeAll() {
        let popover = self.popover
        let panel = self.panel
        self.popover = nil
        self.panel = nil
        popover?.close()
        panel?.close()
        session?.quickKeys.close()
        session = nil
    }

    // MARK: NSPopoverDelegate

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    /// The tear-off: the floating panel the pop-over becomes when dragged away (one per station window).
    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        if let panel { return panel }
        guard let session else { return nil }
        let panel = Self.makePanel(content: hosting(session), title: "\(QuickKeysText.toolbarLabel) — \(session.station.name)")
        if let size = popover.contentViewController?.view.fittingSize, size.width > 0, size.height > 0 {
            panel.setContentSize(size)
        }
        panel.delegate = self
        panelFocusSettled = false
        self.panel = panel
        return panel
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        closedAt = .now
        closeModelIfUnused()
    }

    // MARK: NSWindowDelegate

    /// The first time the panel is key, nothing has focus: its keys are the keypad's, not the search
    /// field's, which AppKit would otherwise focus as the window's first key view.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, !panelFocusSettled else { return }
        panelFocusSettled = true
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === panel else { return }
        panel = nil
        closeModelIfUnused()
    }

    // MARK: Parts

    /// A floating utility panel that stays open until closed.
    static func makePanel(content: NSViewController, title: String) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: QuickKeysPopover.width, height: 600),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.contentViewController = content
        panel.title = title
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func hosting(_ session: StationSession, close: (@MainActor () -> Void)? = nil) -> NSViewController {
        let controller = NSHostingController(rootView: QuickKeysPopover(session: session, state: state, close: close))
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private func closeModelIfUnused() {
        guard popover == nil, panel == nil else { return }
        session?.quickKeys.close()
        state.reset()
    }
}

/// The toolbar button's view, for the pop-over to point at.
struct QuickKeysAnchor: NSViewRepresentable {
    let found: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.found = found
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) { view.found = found }

    final class AnchorView: NSView {
        var found: @MainActor (NSView) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { found(self) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Whether a station window's Quick Keys pop-over is attached, observed by its views.
@MainActor @Observable final class QuickKeysPresence {
    var isPopoverShown = false
}

extension EnvironmentValues {
    /// The station window's Quick Keys pop-over is attached (`QuickKeysPresence`).
    @Entry var quickKeysPopoverShown: Bool = false
}

/// The station window's keyboard shortcuts while its Quick Keys pop-over shows. The attached pop-over never
/// becomes the key window (AppKit addresses its keys to the station window), and its monitor consumes the keys
/// it takes (`LocalKeyMonitor.forward`), so none should reach these shortcuts. As a backstop, should a key ever
/// get past that monitor, every shortcut that could reach the scanner (the Mac-style menu's Save, Open and
/// Cancel) is off meanwhile (LESSONS.md 2026-11-18).
enum StationShortcuts {
    static func shortcut(_ shortcut: KeyboardShortcut, quickKeysShown: Bool) -> KeyboardShortcut? {
        quickKeysShown ? nil : shortcut
    }
}

// MARK: Keys and swipes

/// What a key does in the pop-over or its panel.
enum QuickKeysKeyCommand: Equatable {
    /// A digit: jump to its key (`QuickKeyTyping`) and highlight it.
    case digit(Int)
    /// Space or Return: toggle the highlighted tile.
    case toggle
    /// ⌘↓: show the highlighted list's tree.
    case showTree
    /// ⌘F: the search field.
    case find
    /// A held Space, Return or ⌘↓: taken, and nothing done (one action per press).
    case swallow
}

/// The pop-over's keys (design §5.5 "Keyboard"). Anything else (⌘W, Esc, Tab, letters) is left to AppKit.
enum QuickKeysKeyRouting {
    static func decide(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       isRepeat: Bool) -> QuickKeysKeyCommand? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if mods == [.command] {
            if keyCode == 125 { return isRepeat ? .swallow : .showTree }
            if characters?.lowercased() == "f" { return .find }
            return nil
        }
        guard mods.isEmpty else { return nil }
        switch keyCode {
        case 49, 36, 76: return isRepeat ? .swallow : .toggle  // space, return, keypad enter
        default: break
        }
        guard let characters, characters.count == 1, let digit = Int(characters), (0...9).contains(digit) else {
            return nil
        }
        return .digit(digit)
    }
}

extension QuickKeysKeyRouting {
    /// What the attached pop-over does with a key AppKit addressed to the station window.
    enum AttachedDecision: Equatable {
        case perform(QuickKeysKeyCommand)
        /// Esc: the pop-over closes.
        case close
        /// A menu key equivalent (⌘Q, ⌘W, …): the menus take it.
        case pass
        /// Anything else: dropped, so it can't reach a control in the station window (an arrow on a
        /// focused volume slider, Esc on a menu's Cancel, Return on a menu entry field) or the scanner.
        case swallow
    }

    /// While the pop-over is attached, every key is its own (design §5.5: "keys go to it, never to the
    /// scanner"). Space and Return while one of its controls has focus are swallowed, never the tile's.
    static func attached(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool,
                         menuChords: Set<KeyChord>, controlFocused: Bool) -> AttachedDecision {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if keyCode == 53, mods.isEmpty { return .close }
        if let command = decide(characters: characters, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat) {
            if controlFocused, command == .toggle { return .swallow }
            return .perform(command)
        }
        if let chord = KeyEventMapping.chord(characters: characters, keyCode: keyCode, modifiers: modifiers),
           menuChords.contains(chord) { return .pass }
        return .swallow
    }
}

/// A two-finger horizontal swipe on the trackpad: one ten per gesture, left for the next, right for the
/// previous. A mostly vertical scroll isn't one, and momentum after the fingers lift is ignored.
struct QuickKeysSwipe {
    static let threshold: CGFloat = 30

    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var fired = false

    /// 1 for the next ten, -1 for the previous, nil for nothing (yet).
    mutating func scroll(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase) -> Int? {
        if phase.contains(.began) {
            dx = deltaX
            dy = deltaY
            fired = false
            return nil
        }
        if phase.contains(.changed) {
            dx += deltaX
            dy += deltaY
            guard !fired, abs(dx) >= Self.threshold, abs(dx) > abs(dy) * 1.5 else { return nil }
            fired = true
            return dx < 0 ? 1 : -1
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            dx = 0
            dy = 0
            fired = false
        }
        return nil
    }
}

/// The pop-over's (or panel's) own key and swipe monitor: it acts only on events for its own window while
/// that window is key, and never while a text field (the search) has focus. The station window's monitor
/// acts only for the station window, so these keys never reach the scanner.
struct QuickKeysKeyMonitor: NSViewRepresentable {
    let perform: @MainActor (QuickKeysKeyCommand) -> Void
    let swipe: @MainActor (Int) -> Void
    /// The pop-over's (or panel's) SwiftUI controls report their keyboard focus here.
    let controlFocus: ControlFocus
    /// Esc on the attached pop-over.
    var close: (@MainActor () -> Void)?

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.perform = perform
        view.swipe = swipe
        view.controlFocus = controlFocus
        view.close = close ?? {}
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    final class MonitorView: NSView {
        var perform: @MainActor (QuickKeysKeyCommand) -> Void = { _ in }
        var swipe: @MainActor (Int) -> Void = { _ in }
        /// Whether `window` is key (a test window can't become key).
        var isKey: @MainActor (NSWindow) -> Bool = { $0.isKeyWindow }
        /// Whether the pop-over's window is on screen (a test window isn't).
        var isOnScreen: @MainActor (NSWindow) -> Bool = { $0.isVisible }
        var controlFocus: ControlFocus?
        var close: @MainActor () -> Void = {}
        /// The app's menu key equivalents, which pass even while the pop-over is attached.
        var menuChords: @MainActor () -> Set<KeyChord> = { NSApp.mainMenu.map(KeyEventMapping.menuChords(in:)) ?? [] }
        private var monitor: Any?
        /// The closure installed as the local monitor (`viewDidMoveToWindow`), and the one tests call: a
        /// key `handle` consumes (nil) must stay consumed. Never `self?.handle(event) ?? event` here:
        /// optional chaining flattens nil back into the event (LESSONS.md 2026-11-18).
        private(set) lazy var monitorBody: @MainActor (NSEvent) -> NSEvent? = { [weak self] event in
            LocalKeyMonitor.forward(event, to: self?.handle)
        }
        /// A monitor is installed (the view is in a window).
        var isMonitoring: Bool { monitor != nil }
        private var swipes = QuickKeysSwipe()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel], handler: monitorBody)
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The monitor body: nil when the event was consumed.
        ///
        /// - Its own window (the panel, or the pop-over once its search field has focus): a focused field
        ///   or control keeps every key (Space and Return on a button or switch included); otherwise its
        ///   commands are taken and the rest passes.
        /// - The attached pop-over's parent (the station window): AppKit addresses the pop-over's keys there
        ///   although the pop-over's window reports key. While the pop-over shows, every key is the
        ///   pop-over's (`QuickKeysKeyRouting.attached`); the station window's monitor steps aside
        ///   (`KeyboardShortcuts.stepsAside`). Scrolls over the station window stay the station window's.
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, let target = event.window else { return event }
            if event.type == .scrollWheel {
                guard target === window else { return event }
                if let step = swipes.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                            phase: event.phase) {
                    swipe(step)
                }
                return event
            }
            guard event.type == .keyDown else { return event }
            if target === window {
                guard isKey(window),
                      !KeyboardShortcuts.MonitorView.focusElsewhere(in: window, controls: controlFocus),
                      let command = QuickKeysKeyRouting.decide(characters: event.charactersIgnoringModifiers,
                                                               keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                               isRepeat: event.isARepeat) else { return event }
                perform(command)
                return nil
            }
            guard let parent = window.parent, target === parent, isOnScreen(window) else { return event }
            switch QuickKeysKeyRouting.attached(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                                                modifiers: event.modifierFlags, isRepeat: event.isARepeat,
                                                menuChords: menuChords(),
                                                controlFocused: controlFocus?.isActive == true) {
            case .perform(let command):
                perform(command)
                return nil
            case .close:
                close()
                return nil
            case .pass:
                return event
            case .swallow:
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
