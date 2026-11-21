// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import NoctuleKit
import SwiftUI

/// What the keyboard asks of the Mac-style menu (`KeyRouting`): ↑, ↓, ↩ and Esc.
enum MacMenuCommand: Equatable { case moveUp, moveDown, activate, back }

/// Per window: set while the Mac-style menu is on screen and its entry field doesn't have focus.
/// The key monitor asks it first (`KeyRouting.decide(…, macMenuActive:)`).
@MainActor final class MacMenuKeys {
    var handler: ((MacMenuCommand) -> Void)?
    var isActive: Bool { handler != nil }
}

/// The Mac-style menu's local state: the list's selection, the entry's draft, and an "are you
/// sure?" waiting for an answer. `sync(with:)` follows `MenuModel.content`.
@MainActor @Observable final class MacMenuState {
    /// The selected item's `Index` on a list screen. The scanner's `Selected` on a new screen; a
    /// re-read of the same menu keeps a selection moved locally unless that item is gone.
    var selection: Int?
    /// The entry screen's text: its `Value` on a new entry screen (or when the same screen comes
    /// back with another `Value`), kept across re-reads of it.
    var draft = ""
    /// Set when an action threw `.needsConfirmation`; cleared whenever the content changes.
    var pendingConfirmation: PendingConfirmation?

    struct PendingConfirmation: Equatable {
        /// The name the confirmation shows (`.needsConfirmation(itemName:)`'s value).
        var itemName: String
        /// The list item and screen to choose again; nil for Enter on a mirrored screen.
        var item: MenuScreen.Item?
        var screen: MenuScreen?
    }

    @ObservationIgnored private var lastContent: MenuContent?

    func sync(with content: MenuContent?) {
        let previous = lastContent
        lastContent = content
        if content != previous { pendingConfirmation = nil }
        switch content {
        case .list(let screen):
            let sameMenu = Self.isSameScreen(previous, screen, list: true)
            let kept = selection.map { index in screen.items.contains { $0.index == index } } ?? false
            if !(sameMenu && kept) { selection = Self.scannerSelection(screen) }
            draft = ""
        case .entry(let screen):
            // A new entry screen, or this one with another value (changed on the radio, or by a
            // save whose reply was lost): start from the scanner's value. Otherwise keep the typing.
            if !Self.isSameScreen(previous, screen, list: false) || Self.value(previous) != screen.value {
                draft = screen.value ?? ""
            }
            selection = nil
        case .mirrored, nil:
            selection = nil
            draft = ""
        }
    }

    /// Moves the selection `delta` rows (not indexes: `MSI` omits items), clamped, no wrap.
    func move(_ delta: Int, in screen: MenuScreen) {
        guard !screen.items.isEmpty else { return }
        let row = selection.flatMap { index in screen.items.firstIndex { $0.index == index } }
        guard let row else {
            selection = screen.items[delta < 0 ? screen.items.count - 1 : 0].index
            return
        }
        selection = screen.items[min(max(row + delta, 0), screen.items.count - 1)].index
    }

    /// Sets the draft through `MenuInput.sanitize`. Typing is accepted while an action is in
    /// flight; only a submit is refused then (`MacMenuActions`).
    func setDraft(_ text: String, rules: MenuScreen.InputRules) {
        draft = MenuInput.sanitize(text, rules: rules)
    }

    private static func isSameScreen(_ previous: MenuContent?, _ screen: MenuScreen, list: Bool) -> Bool {
        let earlier: MenuScreen? = switch previous {
        case .list(let s) where list: s
        case .entry(let s) where !list: s
        default: nil
        }
        guard let index = screen.menuIndex, let earlier else { return false }
        return earlier.menuIndex == index
    }

    private static func value(_ content: MenuContent?) -> String? {
        if case .entry(let screen) = content { return screen.value }
        return nil
    }

    /// The scanner's `Selected` when it is a listed item, else the first item.
    private static func scannerSelection(_ screen: MenuScreen) -> Int? {
        if let selected = screen.selectedIndex, screen.items.contains(where: { $0.index == selected }) {
            return selected
        }
        return screen.items.first?.index
    }
}

/// The Mac-style menu's words.
enum MacMenuText {
    static let pausedNote = "Scanning is paused while the scanner is in a menu."
    static let mirroredNote = "The scanner doesn't describe this screen. It is shown as the scanner draws it."
    static let notAnsweringNote = "The scanner isn't answering."
    static let moreItemsHint = "Some items appear only in the Scanner view."
    static let listKeys = "↑ ↓ · Return or double-click · Esc back"
    static let entryKeys = "Return saves to the scanner · Esc cancels"
    static let mirroredKeys = "↑ ↓ scroll · Return enters · Esc back"

    /// The screen's title, trimmed (the top menu is `Menu`); else the breadcrumb's last; else `Menu`.
    static func title(_ content: MenuContent?, breadcrumb: [String]) -> String {
        let raw: String? = switch content {
        case .list(let screen), .entry(let screen): screen.title
        case .mirrored, nil: nil
        }
        if let raw {
            let letters = raw.filter { $0.isLetter || $0.isNumber }.uppercased()
            if letters == "MENU" { return "Menu" }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return breadcrumb.last ?? "Menu"
    }

    /// "Menu › Display Options"; nil for a single element (the title says it).
    static func breadcrumbText(_ breadcrumb: [String]) -> String? {
        breadcrumb.count > 1 ? breadcrumb.joined(separator: " › ") : nil
    }

    /// "Toggle" when the item has a value (an on/off row), else "Open".
    static func activateTitle(_ item: MenuScreen.Item?) -> String {
        item?.value == nil ? "Open" : "Toggle"
    }

    /// `AddedInformation`, trimmed; nil when blank.
    static func unit(_ rules: MenuScreen.InputRules) -> String? {
        let text = rules.addedInformation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// "8 of 64 characters"; nil without a `MaxLength`.
    static func counter(_ draft: String, rules: MenuScreen.InputRules) -> String? {
        rules.maxLength.map { "\(draft.count) of \($0) characters" }
    }

    static func confirmationMessage(itemName: String) -> String {
        "“\(itemName)” can't be undone from here. Send it to the scanner?"
    }

    /// The error line for an action's failure; nil for those that need no words.
    static func errorMessage(_ error: MenuActionError) -> String? {
        switch error {
        case .menuChanged: "The menu changed on the scanner. Nothing was sent."
        case .noAnswer: "The scanner didn't answer. Check the menu before trying again."
        case .rejected: "The scanner refused that."
        case .invalidValue: "That value isn't allowed here."
        case .busy, .needsConfirmation, .notInMenu, .notConnected: nil
        }
    }

    /// The one line above the footer: the scanner not answering (design §5.5) wins over the last
    /// action's error, which may be older.
    static func statusLine(lastError: MenuActionError?, isScannerAnswering: Bool) -> String? {
        if !isScannerAnswering { return notAnsweringNote }
        return lastError.flatMap(errorMessage)
    }

    /// The standing hint under a list: the radio's screen shows more item rows (non-blank, the
    /// underlined title not counted) than `MSI` listed, and the list is short enough (under nine)
    /// that the screen shows all of it.
    static func showsMoreItemsHint(displayRows: [DisplayRow]?, itemCount: Int) -> Bool {
        guard let displayRows, itemCount < 9 else { return false }
        let itemRows = displayRows.filter { row in
            !row.segments.contains(where: \.underlined)
                && !row.segments.map(\.text).joined().trimmingCharacters(in: .whitespaces).isEmpty
        }
        return itemRows.count > itemCount
    }
}

/// The Mac-style menu's actions, each in response to one click or key press: one `MenuModel` call,
/// so at most one state-changing command, never resent. A `.needsConfirmation` becomes the inline
/// confirmation; `.busy` is ignored (the controls are disabled then); other errors show through
/// `MenuModel.lastError`.
///
/// **Key repeats.** A held Return or Esc reaches SwiftUI's default and cancel buttons (and a text
/// field's submit) once per repeat whenever the key monitor stands aside (a control has focus), so
/// a held key would toggle an item again and again. Every action that can send ignores an
/// activation that comes from a key-repeat event (`isKeyRepeat`), except the scroll keys, which
/// repeat as they do in the Scanner view's key monitor ("only the scroll keys repeat"). Moving the
/// local selection sends nothing and may repeat. Each entry point returns the action's task (nil:
/// nothing was started), for tests.
@MainActor struct MacMenuActions {
    let menu: MenuModel
    let state: MacMenuState
    /// True while the event being handled is a key-down repeat.
    var isKeyRepeat: @MainActor () -> Bool = MacMenuActions.currentEventIsKeyRepeat

    /// `NSApp.currentEvent` is a held key's repeat.
    static func currentEventIsKeyRepeat() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    @discardableResult
    func perform(_ command: MacMenuCommand) -> Task<Void, Never>? {
        guard !menu.isBusy else { return nil }
        if state.pendingConfirmation != nil {
            // Return and Esc answer the confirmation with its default, Cancel; arrows do nothing.
            if command == .activate || command == .back { state.pendingConfirmation = nil }
            return nil
        }
        switch menu.content {
        case .list(let screen):
            switch command {
            case .moveUp: state.move(-1, in: screen)
            case .moveDown: state.move(1, in: screen)
            case .activate: return activateSelection(on: screen)
            case .back: return back()
            }
        case .entry(let screen):
            switch command {
            case .activate: return save(on: screen)
            case .back: return back()
            case .moveUp, .moveDown: break
            }
        case .mirrored:
            switch command {
            case .moveUp: return press(.scrollLeft)
            case .moveDown: return press(.scrollRight)
            case .activate: return press(.enterYes)
            case .back: return back()
            }
        case nil:
            break
        }
        return nil
    }

    /// The Menu button (`KEY,M,P` unless the scanner is already in a menu).
    @discardableResult
    func enter() -> Task<Void, Never>? { run { try await menu.enter() } }

    @discardableResult
    func activateSelection(on screen: MenuScreen) -> Task<Void, Never>? {
        guard let item = screen.items.first(where: { $0.index == state.selection }) else { return nil }
        return choose(item, on: screen)
    }

    @discardableResult
    func choose(_ item: MenuScreen.Item, on screen: MenuScreen) -> Task<Void, Never>? {
        run(pending: { .init(itemName: $0, item: item, screen: screen) }) {
            try await menu.choose(item, on: screen)
        }
    }

    @discardableResult
    func save(on screen: MenuScreen) -> Task<Void, Never>? {
        let text = state.draft
        guard MenuInput.isValid(text, rules: screen.input ?? MenuScreen.InputRules()) else { return nil }
        return run { try await menu.setValue(text, on: screen) }
    }

    @discardableResult
    func press(_ key: FrontPanelKey) -> Task<Void, Never>? {
        let scroll = key == .scrollLeft || key == .scrollRight
        return run(allowsRepeat: scroll, pending: { .init(itemName: $0, item: nil, screen: nil) }) {
            try await menu.press(key)
        }
    }

    @discardableResult
    func back() -> Task<Void, Never>? { run { try await menu.back() } }

    @discardableResult
    func exit() -> Task<Void, Never>? { run { try await menu.exit() } }

    /// Send to Scanner: the confirmed action, once, carrying the name it showed. A key repeat
    /// neither sends nor answers it.
    @discardableResult
    func confirm() -> Task<Void, Never>? {
        guard !isKeyRepeat(), !menu.isBusy, let pending = state.pendingConfirmation else { return nil }
        state.pendingConfirmation = nil
        if let item = pending.item, let screen = pending.screen {
            return run { try await menu.choose(item, on: screen, confirmedDestructive: true) }
        }
        return run { try await menu.press(.enterYes, confirmedDestructive: true, confirmedItemName: pending.itemName) }
    }

    func cancelConfirmation() { state.pendingConfirmation = nil }

    /// Runs one action, unless one is in flight or this is a key repeat (`allowsRepeat`: the scroll
    /// keys). A `.needsConfirmation` asks first, unless the content changed meanwhile.
    private func run(allowsRepeat: Bool = false, pending: ((String) -> MacMenuState.PendingConfirmation)? = nil,
                     _ action: @escaping @MainActor () async throws -> MenuContent?) -> Task<Void, Never>? {
        guard !menu.isBusy, allowsRepeat || !isKeyRepeat() else { return nil }
        state.pendingConfirmation = nil
        let started = menu.content
        return Task { @MainActor in
            do {
                _ = try await action()
            } catch MenuActionError.needsConfirmation(let name) {
                if let pending, menu.content == started { state.pendingConfirmation = pending(name) }
            } catch {
                // Shown through `menu.lastError` (or not at all: `.busy`).
            }
        }
    }
}

/// The scanner's menu in the Mac-style view (remote menus design §5.3-§5.5, mockup option A): a
/// list as a native list, an entry as a text field, anything else as the mirrored scanner text.
/// It renders what `MenuModel` describes and calls it only on a click or key press.
struct MacMenuView: View {
    let session: StationSession

    @Environment(\.macMenuKeys) private var keys
    /// The window's Quick Keys pop-over shows: its keys must not reach these buttons (`StationShortcuts`).
    @Environment(\.quickKeysPopoverShown) private var quickKeysShown
    @State private var state = MacMenuState()
    @State private var shown = false
    /// The entry field has keyboard focus (it reports it; `MenuEntryField`).
    @State private var fieldFocused = false

    private var menu: MenuModel { session.menu }
    private var actions: MacMenuActions { MacMenuActions(menu: menu, state: state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(MacMenuText.breadcrumbText(menu.breadcrumb) ?? " ")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(MacMenuText.title(menu.content, breadcrumb: menu.breadcrumb))
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            switch menu.content {
            case .list(let screen): listBody(screen)
            case .entry(let screen): entryBody(screen)
            case .mirrored, nil: mirroredBody
            }
            if let line = MacMenuText.statusLine(lastError: menu.lastError, isScannerAnswering: menu.isScannerAnswering) {
                Label(line, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if let pending = state.pendingConfirmation {
                confirmation(pending)
            } else {
                footer
            }
            Text(MacMenuText.pausedNote)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .onAppear {
            shown = true
            state.sync(with: menu.content)
            installKeys()
        }
        .onDisappear {
            shown = false
            keys?.handler = nil
        }
        .onChange(of: menu.content) { _, content in state.sync(with: content) }
        .onChange(of: fieldFocused) { _, focused in
            // The field takes its own Return and Esc; the monitor stands aside anyway (focus).
            if focused { keys?.handler = nil } else { installKeys() }
        }
    }

    private func installKeys() {
        guard shown, !fieldFocused else { return }
        let actions = self.actions
        keys?.handler = { actions.perform($0) }
    }

    // MARK: List

    private static let rowHeight: CGFloat = 28

    private func listBody(_ screen: MenuScreen) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(screen.items) { item in
                            row(item, on: screen)
                                .id(item.index)
                        }
                    }
                }
                .frame(height: CGFloat(min(max(screen.items.count, 1), 10)) * Self.rowHeight)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .onAppear { if let selection = state.selection { proxy.scrollTo(selection) } }
                .onChange(of: state.selection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
            if MacMenuText.showsMoreItemsHint(displayRows: session.display?.isMenu == true ? session.display?.rows : nil,
                                              itemCount: screen.items.count) {
                Text(MacMenuText.moreItemsHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ item: MenuScreen.Item, on screen: MenuScreen) -> some View {
        let selected = state.selection == item.index
        return HStack {
            Text(item.name)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let value = item.value {
                let on = value.caseInsensitiveCompare("On") == .orderedSame
                Text(value)
                    .fontWeight(on ? .semibold : .regular)
                    .foregroundStyle(selected ? Color.white : (on ? Color.green : Color.secondary))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !menu.isBusy, state.pendingConfirmation == nil else { return }
            state.selection = item.index
            actions.choose(item, on: screen)
        }
        .simultaneousGesture(TapGesture().onEnded {
            guard !menu.isBusy, state.pendingConfirmation == nil else { return }
            state.selection = item.index
        })
        .opacity(menu.isBusy ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Entry

    private func entryBody(_ screen: MenuScreen) -> some View {
        let rules = screen.input ?? MenuScreen.InputRules()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // AppKit, so the field always shows the sanitized draft (a SwiftUI `TextField`
                // keeps showing refused characters). Never disabled, which would drop its focus:
                // typing goes on while busy, and only Save and Return are refused then.
                MenuEntryField(text: state.draft, rules: rules,
                               onChange: { state.setDraft($0, rules: rules) },
                               onSubmit: { actions.save(on: screen) },
                               onCancel: { actions.back() },
                               onFocusChange: { fieldFocused = $0 })
                    .frame(maxWidth: 380)
                if let unit = MacMenuText.unit(rules) {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
            if let counter = MacMenuText.counter(state.draft, rules: rules) {
                Text(counter).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Mirrored

    private var mirroredBody: some View {
        let palette = DisplayPalette.factory(model: session.model, mode: session.station.appearance.colorMode)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(palette.background))
                if let display = session.display {
                    DisplayRowsView(display: display, palette: palette)
                }
            }
            .frame(width: DisplayView.screenWidth, height: DisplayView.screenHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanner display")
            HStack(spacing: 8) {
                ForEach(Array([FrontPanelKey.soft1, .soft2, .soft3].enumerated()), id: \.offset) { index, key in
                    let softKey = session.display?.softKeys.first(where: { $0.key == key })
                    Button { actions.press(key) } label: {
                        Text(DisplayView.softKeyTitle(softKey)).frame(minWidth: 70)
                    }
                    .disabled(menu.isBusy)
                    .tracksKeyboardFocus()
                    .help("Soft key \(index + 1)")
                }
            }
            .frame(width: DisplayView.screenWidth)
            Text(MacMenuText.mirroredNote)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Footer and confirmation

    private var footer: some View {
        HStack(spacing: 8) {
            if case .entry(let screen) = menu.content {
                Button("Cancel") { actions.back() }
                    .keyboardShortcut(StationShortcuts.shortcut(.cancelAction, quickKeysShown: quickKeysShown))
                    .tracksKeyboardFocus()
                Spacer(minLength: 8)
                Text(MacMenuText.entryKeys).font(.callout).foregroundStyle(.secondary)
                Button("Save") { actions.save(on: screen) }
                    .keyboardShortcut(StationShortcuts.shortcut(.defaultAction, quickKeysShown: quickKeysShown))
                    .disabled(menu.isBusy || !MenuInput.isValid(state.draft, rules: screen.input ?? MenuScreen.InputRules()))
                    .tracksKeyboardFocus()
            } else {
                Button { actions.back() } label: { Label("Back", systemImage: "chevron.left") }
                    .tracksKeyboardFocus()
                Button("Exit Menu") { actions.exit() }
                    .tracksKeyboardFocus()
                Spacer(minLength: 8)
                if case .list(let screen) = menu.content {
                    Text(MacMenuText.listKeys).font(.callout).foregroundStyle(.secondary)
                    let item = screen.items.first { $0.index == state.selection }
                    Button(MacMenuText.activateTitle(item)) { actions.activateSelection(on: screen) }
                        .keyboardShortcut(StationShortcuts.shortcut(.defaultAction, quickKeysShown: quickKeysShown))
                        .disabled(menu.isBusy || item == nil)
                        .tracksKeyboardFocus()
                } else {
                    Text(MacMenuText.mirroredKeys).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(menu.isBusy)
        .lineLimit(1)
    }

    private func confirmation(_ pending: MacMenuState.PendingConfirmation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(MacMenuText.confirmationMessage(itemName: pending.itemName))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // The default (Return); Esc cancels too, through the menu keys.
            Button("Cancel") { actions.cancelConfirmation() }
                .keyboardShortcut(StationShortcuts.shortcut(.defaultAction, quickKeysShown: quickKeysShown))
                .tracksKeyboardFocus()
            Button("Send to Scanner", role: .destructive) { actions.confirm() }
                .tracksKeyboardFocus()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .disabled(menu.isBusy)
    }
}
#endif
