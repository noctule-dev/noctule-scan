// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import SwiftUI

/// The pop-over's words (design §5.5, the plan's Global Constraints: exact copy).
enum QuickKeysText {
    static let toolbarLabel = "Quick Keys"
    static let toolbarHelp = "Turn Favorites Lists, systems and departments on and off"
    static let title = "Favorites quick keys"
    static let searchPrompt = "Find a name or number"
    static let scanThisList = "Scan this list"
    static let notMonitoredTag = "Not monitored"
    static let noQuickKeyTag = "no quick key"
    static let siteTag = "site"
    static let avoidedTag = "Avoided"
    static let sharedTag = "shared"
    static let unreportedHelp = "The scanner doesn't report this key's state."
    static let inMenuHelp = "The scanner is in a menu"
    static let notMonitoredLine = "Not monitored. Turn it on in Select Lists to Monitor on the scanner or in Sentinel."
    /// The model's own words, so `errorLine` always recognises them (Task 8 QA m3).
    static let unconfirmed = QuickKeysModel.unconfirmedMessage
    static let notAnswering = "The scanner isn't answering"
    static let checking = "Checking…"
    /// A tree row's help, and the status line, while the first lists read wait for the rest (`.checkingOtherLists`).
    static let checkingOtherLists = "Checking the other lists…"
    static let noQuickKeyTitle = "No quick key"
    static let treeHint = "Choose › on a list to see its systems."
    static let noMatch = "No match"

    /// A department's or site's help when its system's key is shared (`.sharedSystemKey`).
    static func sharedSystemKeyHelp(systemKey: Int) -> String {
        "Systems S\(systemKey) share a quick key, so their departments can't be switched separately here."
    }

    /// A system's, department's or site's help when its list's key is shared (`.sharedListKey`).
    static func sharedListKeyHelp(listKey: Int) -> String {
        "Lists F\(listKey) share a quick key, so their systems can't be switched separately here."
    }

    /// The help a switch or tile carries for its state; nil when there is nothing to explain.
    static func help(for state: QuickKeySwitchState) -> String? {
        switch state {
        case .unreported: unreportedHelp
        case .sharedSystemKey(let key): sharedSystemKeyHelp(systemKey: key)
        case .sharedListKey(let key): sharedListKeyHelp(listKey: key)
        case .inMenu: inMenuHelp
        case .checking: checking
        case .checkingOtherLists: checkingOtherLists
        case .on, .off, .unknown, .busy, .noQuickKey, .unavailable: nil
        }
    }

    /// The "shared" tag's help: `count` rows hold quick key `tag` and switch together.
    static func sharingHelp(count: Int, tag: String) -> String {
        "\(count) items share quick key \(tag); they switch together."
    }

    /// A row's key as the radio names it: `F` for a list, `S` for a system, `D` for a department or site.
    static func keyTag(_ row: QuickKeyRow, key: Int) -> String {
        switch row {
        case .list: "F\(key)"
        case .system: "S\(key)"
        case .child: "D\(key)"
        }
    }

    /// The tree's header detail: "3 systems, 2 on"; just "3 systems" before the states are read.
    static func headerDetail(systems: Int, on: Int?) -> String {
        let count = systems == 1 ? "1 system" : "\(systems) systems"
        guard let on else { return count }
        return "\(count), \(on) on"
    }

    static func tileAccessibilityLabel(name: String, key: Int?) -> String {
        guard let key else { return name }
        return "\(name), quick key \(key)"
    }

    /// A toggle's accessibility value: on or off; nil with no state read.
    static func accessibilityValue(isOn: Bool?) -> String? {
        isOn.map { $0 ? "on" : "off" }
    }

    static func cornerButtonLabel(name: String) -> String { "Show systems in \(name)" }

    /// The tile's corner button: "3 ›", or "›" before the list's systems are known.
    static func cornerButtonTitle(systemCount: Int?) -> String {
        systemCount.map { "\($0) ›" } ?? "›"
    }

    /// The one line at the top: an unconfirmed change, or a set its check stopped, first (as the model's
    /// `lastError`), then a scanner that isn't answering; nil otherwise (another failed read retries by itself).
    static func errorLine(lastError: String?, isScannerAnswering: Bool) -> String? {
        if let lastError, [unconfirmed, QuickKeysModel.listChangedMessage, QuickKeysModel.checkUnansweredMessage]
            .contains(lastError) { return lastError }
        if !isScannerAnswering { return notAnswering }
        return nil
    }

    /// A list's failed read, under its tree's "Checking…" line: the model reads it again by itself. `reason` is
    /// the model's sentence ("The scanner refused GLT,SYS."), lower-cased after the colon.
    static func listReadError(_ reason: String) -> String {
        var reason = reason
        if reason.hasSuffix(".") { reason.removeLast() }
        if let first = reason.first { reason = first.lowercased() + reason.dropFirst() }
        return "Couldn't read this list: \(reason). Trying again."
    }

    /// The session's state while it isn't connected (the pop-over then shows what it has, read-only).
    static func sessionLine(phase: SessionPhase) -> String? {
        switch phase {
        case .connected: nil
        case .waitingForScanner: "Waiting for the scanner"
        case .connecting, .waitingForCooldown: "Connecting…"
        default: "Not connected"
        }
    }

    /// A segment's title: "0–9", "10–19" … "90–99".
    static func tenTitle(_ ten: QuickKeyPages.Ten) -> String {
        "\(ten.range.lowerBound)–\(ten.range.upperBound)"
    }

    /// A segment's count: "5/7 on" once the keypad's states are read, "7 lists" before; "—" for no lists.
    static func tenCaption(_ ten: QuickKeyPages.Ten, statesKnown: Bool) -> String {
        guard ten.listCount > 0 else { return "—" }
        if statesKnown { return "\(ten.onCount)/\(ten.listCount) on" }
        return ten.listCount == 1 ? "1 list" : "\(ten.listCount) lists"
    }
}

/// The station window's Quick Keys button.
enum QuickKeysToolbar {
    /// Shown only for a session whose model has quick keys (`StationSession.supportsQuickKeys`).
    @MainActor static func isShown(for session: StationSession?) -> Bool {
        session?.supportsQuickKeys == true
    }
}

/// What the pop-over (and its torn-off panel, which shares it) remembers between redraws: the ten shown,
/// the keyboard's highlighted key, the search, and which systems are expanded. Reset when the pop-over
/// opens afresh, kept through a tear-off.
@MainActor @Observable final class QuickKeysViewState {
    /// The ten shown; nil until the keypad first arrives (then the scanning ten, else the first with lists).
    var ten: Int?
    /// The key the keyboard highlighted (Space or Return toggles it, ⌘↓ shows its tree).
    var highlighted: Int?
    var search = ""
    /// The row the search found (highlighted in the tree and scrolled to).
    var searchHit: QuickKeyRow?
    var expanded: Set<UInt32> = []
    /// Bumped by ⌘F: the search field takes focus.
    var searchFocusRequest = 0
    @ObservationIgnored private var expansionSeededFor: UInt32?
    @ObservationIgnored private var typing = QuickKeyTyping()

    /// A digit typed on the keypad (`QuickKeyTyping`): jump to the key's ten and highlight it.
    func typed(_ digit: Int, at instant: ContinuousClock.Instant) {
        guard let key = typing.type(digit, at: instant) else { return }
        highlighted = key
        ten = key / 10
    }

    /// A digit typed on the keypad, with the tree following the focus: a key that isn't the shown list's closes it.
    func typed(_ digit: Int, at instant: ContinuousClock.Instant, lists: [QuickKeyListItem], in model: QuickKeysModel) {
        typed(digit, at: instant)
        guard let shown = model.shownList, let key = highlighted else { return }
        if lists.first(where: { $0.index == shown })?.key != key { model.hideList() }
    }

    /// A click (or Space, Return) on a list's tile: it takes the highlight, and the tree of any other list closes
    /// (design §5.5: the tree belongs to the focused tile). It never opens one.
    func clicked(_ item: QuickKeyListItem, in model: QuickKeysModel) {
        highlighted = item.key
        if let shown = model.shownList, shown != item.index { model.hideList() }
    }

    /// "n ›", ⌘↓ or a chip: the list's tree opens and its tile is the focused one; a list with no key has no tile,
    /// so nothing stays highlighted.
    func show(_ item: QuickKeyListItem, in model: QuickKeysModel) {
        highlighted = item.key
        model.showList(item.index)
    }

    /// A search hit: its list's ten and tile (a list without a key is in no ten), and the system holding
    /// it expanded. The caller shows the list (`QuickKeysModel.showList`).
    func jump(to row: QuickKeyRow, listKey: Int?) {
        highlighted = listKey
        if let listKey { ten = listKey / 10 }
        searchHit = row
        switch row {
        case .list: break
        case .system(_, let system), .child(_, let system, _): expanded.insert(system)
        }
    }

    /// The first expansion of a list's tree, once its systems are known; a search hit's system stays open.
    func seedExpansion(list: UInt32, systems: [UInt32], scanning: UInt32?) {
        guard expansionSeededFor != list, !systems.isEmpty else { return }
        expansionSeededFor = list
        var open = QuickKeyTreeExpansion.initial(systems: systems, scanning: scanning)
        switch searchHit {
        case .system(let hitList, let system)? where hitList == list: open.insert(system)
        case .child(let hitList, let system, _)? where hitList == list: open.insert(system)
        default: break
        }
        expanded = open
    }

    func reset() {
        ten = nil
        highlighted = nil
        search = ""
        searchHit = nil
        expanded = []
        expansionSeededFor = nil
        typing = QuickKeyTyping()
    }
}

/// The Quick Keys pop-over (design §5.5), also the content of its torn-off panel: the search, the error
/// line, the tens, the keypad of the shown ten, the page dots, the lists without a quick key, and the
/// open list's tree. Its keys (digits, Space, Return, ⌘↓, ⌘F) and two-finger swipes are its own
/// (`QuickKeysKeyMonitor`), never the scanner's.
struct QuickKeysPopover: View {
    let session: StationSession
    @Bindable var state: QuickKeysViewState
    /// Closes the attached pop-over (Esc); nil in the torn-off panel.
    var close: (@MainActor () -> Void)? = nil

    @FocusState private var searchFocused: Bool
    /// Its controls' keyboard focus (`.tracksKeyboardFocus()`): a focused one keeps Space and Return.
    @State private var controlFocus = ControlFocus()

    static let width: CGFloat = 560
    static let treeHeight: CGFloat = 290

    private var model: QuickKeysModel { session.quickKeys }
    private var pages: QuickKeyPages { QuickKeyPages(lists: model.lists, scanningList: model.scanning.list) }
    private var currentTen: Int { state.ten ?? pages.initialTen() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            Divider()
            statusLines
            tens
            keypad
            pager
            unkeyedLists
            treeArea
        }
        .frame(width: Self.width)
        .environment(\.controlFocus, controlFocus)
        .background(QuickKeysKeyMonitor(perform: perform, swipe: step, controlFocus: controlFocus, close: close))
        .onChange(of: model.lists.count, initial: true) { _, count in
            if state.ten == nil, count > 0 { state.ten = pages.initialTen() }
        }
        .onChange(of: expansionSeed, initial: true) { _, _ in seedExpansion() }
        .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: state.search) { _, text in search(text) }
    }

    // MARK: Parts

    private var bar: some View {
        HStack(spacing: 8) {
            Text(QuickKeysText.title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if !state.search.isEmpty, state.searchHit == nil {
                Text(QuickKeysText.noMatch).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField(QuickKeysText.searchPrompt, text: $state.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit { search(state.search) }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(width: 180)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(QuickKeyColors.offBorder, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var statusLines: some View {
        if let line = QuickKeysText.errorLine(lastError: model.lastError, isScannerAnswering: model.isScannerAnswering) {
            Label(line, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        } else if let line = QuickKeysText.sessionLine(phase: session.phase) {
            Label(line, systemImage: "bolt.horizontal.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        } else if model.isInMenu {
            Label(QuickKeysText.inMenuHelp, systemImage: "list.bullet.rectangle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        } else if model.isCheckingOtherLists {
            Label(QuickKeysText.checkingOtherLists, systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
    }

    /// The tens, as a segmented control: each segment's count, a green ● on the scanning ten, and a ten
    /// with no lists disabled.
    private var tens: some View {
        let statesKnown = model.lists.contains { $0.key != nil && $0.state != nil }
        return HStack(spacing: 2) {
            ForEach(pages.tens) { ten in
                let selected = ten.index == currentTen
                Button {
                    state.ten = ten.index
                } label: {
                    VStack(spacing: 1) {
                        Text(QuickKeysText.tenTitle(ten))
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        HStack(spacing: 2) {
                            if ten.holdsScanning { Text("●").foregroundStyle(QuickKeyColors.scanning) }
                            Text(QuickKeysText.tenCaption(ten, statesKnown: statesKnown))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(selected ? Color.primary.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tracksKeyboardFocus()
                .disabled(!ten.isEnabled)
                .opacity(ten.isEnabled ? 1 : 0.3)
                .accessibilityLabel("Quick keys \(QuickKeysText.tenTitle(ten)), \(QuickKeysText.tenCaption(ten, statesKnown: statesKnown))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(QuickKeyColors.offFill, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(QuickKeyColors.offBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var keypad: some View {
        let slots = pages.slots(inTen: currentTen)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 5), spacing: 9) {
            ForEach(0..<10, id: \.self) { slot in
                let key = currentTen * 10 + slot
                if let item = slots[slot] {
                    QuickKeyTile(item: item, state: model.switchState(for: .list(item.index)),
                                 isScanning: model.scanning.list == item.index,
                                 isShown: model.shownList == item.index,
                                 isHighlighted: state.highlighted == key,
                                 sharing: model.sharing(for: .list(item.index)),
                                 toggle: { state.clicked(item, in: model); toggle(.list(item.index)) },
                                 showTree: { state.show(item, in: model) })
                } else {
                    QuickKeyPlaceholderTile(key: key)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// ‹ and › step to the next ten with lists, skipping empty ones; a dot per ten.
    private var pager: some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 18, height: 16) }
                .buttonStyle(.borderless)
                .tracksKeyboardFocus()
                .disabled(pages.previous(before: currentTen) == nil)
                .accessibilityLabel("Previous ten")
            HStack(spacing: 6) {
                ForEach(pages.tens) { ten in
                    Circle()
                        .fill(ten.index == currentTen ? Color.primary : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .opacity(ten.isEnabled ? 1 : 0.3)
                }
            }
            .accessibilityHidden(true)
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 16) }
                .buttonStyle(.borderless)
                .tracksKeyboardFocus()
                .disabled(pages.next(after: currentTen) == nil)
                .accessibilityLabel("Next ten")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    /// Lists with no quick key, after the keypad: read-only, their trees still shown.
    @ViewBuilder
    private var unkeyedLists: some View {
        let unkeyed = model.lists.filter { $0.key == nil }
        if !unkeyed.isEmpty {
            HStack(spacing: 6) {
                Text(QuickKeysText.noQuickKeyTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(unkeyed) { item in
                    Button {
                        state.show(item, in: model)
                    } label: {
                        Text("\(item.name) \(QuickKeysText.cornerButtonTitle(systemCount: item.systemCount))")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tracksKeyboardFocus()
                    .accessibilityLabel(QuickKeysText.cornerButtonLabel(name: item.name))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var treeArea: some View {
        Group {
            if let shown = model.shownList, let item = model.lists.first(where: { $0.index == shown }) {
                QuickKeyTreePanel(model: model, list: item, state: state)
            } else {
                Text(QuickKeysText.treeHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(QuickKeyColors.offBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .frame(height: Self.treeHeight)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: Actions

    private func toggle(_ row: QuickKeyRow) {
        Task { await model.toggle(row) }
    }

    /// One ten forward (1) or back (-1), skipping empty tens.
    private func step(_ direction: Int) {
        let target = direction > 0 ? pages.next(after: currentTen) : pages.previous(before: currentTen)
        if let target { state.ten = target }
    }

    private func perform(_ command: QuickKeysKeyCommand) {
        switch command {
        case .digit(let digit): state.typed(digit, at: .now, lists: model.lists, in: model)
        case .toggle:
            if let item = highlightedItem { state.clicked(item, in: model); toggle(.list(item.index)) }
        case .showTree:
            if let item = highlightedItem { state.show(item, in: model) }
        case .find: state.searchFocusRequest += 1
        case .swallow: break
        }
    }

    private var highlightedItem: QuickKeyListItem? {
        guard let key = state.highlighted else { return nil }
        return model.lists.first { $0.key == key }
    }

    private func search(_ text: String) {
        guard let row = QuickKeyPages.search(text, in: model) else {
            state.searchHit = nil
            return
        }
        guard row != state.searchHit || model.shownList != row.list else { return }
        state.jump(to: row, listKey: model.lists.first { $0.index == row.list }?.key)
        model.showList(row.list)
    }

    /// Changes when the shown list's systems first become known.
    private var expansionSeed: [UInt32] {
        guard let shown = model.shownList else { return [] }
        return [shown] + (model.trees[shown]?.systems.map(\.index) ?? [])
    }

    private func seedExpansion() {
        guard let shown = model.shownList, let tree = model.trees[shown] else { return }
        state.seedExpansion(list: shown, systems: tree.systems.map(\.index),
                            scanning: model.scanning.list == shown ? model.scanning.system : nil)
    }
}
#endif
