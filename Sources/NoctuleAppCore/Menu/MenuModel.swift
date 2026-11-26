// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import NoctuleKit

/// What the menu area shows (remote menus design §5.3).
public enum MenuContent: Equatable, Sendable {
    /// A `TypeSelect` screen with at least one item.
    case list(MenuScreen)
    /// A `TypeInput` screen with its input rules.
    case entry(MenuScreen)
    /// Anything else while the scanner is in a menu (`TypeError`, `TypeLocation`, a garbled or
    /// unanswered `MSI`): draw `StationSession.display`, the mirrored scanner text.
    case mirrored
}

/// Why a menu action did nothing, or didn't finish as asked.
public enum MenuActionError: Error, Equatable, Sendable {
    case notConnected, notInMenu, busy
    /// The re-check before `MSV` didn't match what the caller acted on; nothing was sent.
    case menuChanged
    /// A destructive item without `confirmedDestructive`; nothing was sent.
    case needsConfirmation(itemName: String)
    /// Empty, too long, a disallowed character, a comma, CR or LF; nothing was sent.
    case invalidValue
    /// The scanner answered something other than OK (the screen was re-read).
    case rejected(String)
    /// A command or the reads around it went unanswered; state was re-read where possible. The
    /// command is never resent: it may or may not have taken effect.
    case noAnswer
}

/// The scanner's menu for one session, as UI-free state and actions (design §4.6, §5.1, §5.3-§5.5).
/// `StationSession` owns it (`menu`); the Mac-style view and later the MCP module call it.
///
/// **State.** `content` is nil unless the session is connected and the scanner says (`GSI`) it is
/// in a menu. It is set only from the model's own reads, never straight from a push: a read is
/// `GSI`, then, in a menu, `MSI` (each tried `readTries` times). An `MSI` that stays unanswered
/// while `GSI` still shows the screen the current list or entry was read on (same title, menu
/// index and screen kind) keeps that content, so a lost reply doesn't throw away what the user is
/// doing (`isScannerAnswering` turns false); otherwise, and for an `MSI` answered with something
/// that isn't a list or entry (or that doesn't parse), it reads as `.mirrored`. Reads happen
/// after every action, when a push's menu summary (in or out, title, index, screen kind) differs
/// from the last read's, and every `refreshInterval` while in a menu, never while an action is in
/// flight. A read whose `GSI` goes unanswered leaves `content` as it was, and is tried again after
/// `refreshInterval`.
///
/// **Actions** each send at most one state-changing command (`KEY`, `MSV`, `MNU` or `MSB`) and never
/// resend it.
/// Each throws `.notConnected` unless attached, `.notInMenu` unless `content` is non-nil (`enter`
/// and `refresh` excepted), and `.busy` while another action runs; `isBusy` covers the whole action,
/// its re-read included. The destructive and value checks come before any traffic; `choose` and
/// `setValue` re-read `MSI` and send only if the screen still matches; `enter` and `exit` read
/// `GSI` first and send only if the scanner isn't (enter) or is (exit) in a menu. After the
/// command: the display is told to re-read (`onCommandReply`, on every path where a command went
/// out), then the screen is re-read; OK returns the new content, a non-OK reply throws
/// `.rejected`, no reply (or an OK whose re-read went unanswered) throws `.noAnswer`.
///
/// **Lifecycle.** `attach(control:)` on `.connected`; `detach()` on any other phase (stop,
/// suspend, a restart, a failed run) clears `content` and the breadcrumb, cancels the refresh
/// loop and makes every action in flight throw `.notConnected` at its next step, so nothing more
/// is sent. That includes a `KEY`, `MSV`, `MNU` or `MSB` already waiting for the client's request
/// slot (behind another reader's command, for up to a command timeout): each carries its run's `SendPermit`,
/// which `detach()` revokes, and the client writes it only if the permit still holds once it has
/// the slot (`ScannerClient.send(_:onlyIf:)`; flaky-sweep review I2, 2026-11-22). The client
/// comes only from `control` (the runner's `control()`, nil once its stop begins).
@MainActor @Observable
public final class MenuModel {
    /// nil: the scanner is not in a menu (or the session isn't connected).
    public private(set) var content: MenuContent?
    /// Trimmed titles seen on the way down, ending with the current one; the top menu is `Menu`.
    public private(set) var breadcrumb: [String] = []
    /// An action or its re-read is in flight.
    public private(set) var isBusy = false
    /// The latest action's error; cleared when the next action starts. A refusal for `.busy` isn't
    /// recorded (it would hide the outcome of the action that is running).
    public private(set) var lastError: MenuActionError?
    public var isInMenu: Bool { content != nil }
    /// False once a read (a refresh's, an action's re-check or re-read) went unanswered after its
    /// retries, design §5.5's "scanner isn't answering"; true again after any answered read, and on detach.
    public private(set) var isScannerAnswering = true

    /// While in a menu and idle, the screen is re-read this often (panel changes show up).
    static let refreshInterval: Duration = .seconds(2)
    /// Each read (`GSI`, `MSI`) is tried this many times. State-changing commands are tried once.
    static let readTries = 2
    /// How often the refresh loop re-checks its schedule.
    static let refreshTick: Duration = .milliseconds(100)

    /// The menu item names that need a confirmation (`ModelProfile.destructiveMenuItems`).
    @ObservationIgnored var destructiveItems: DestructiveMenuItems
    /// How this model enters, goes back and leaves a menu (`ModelProfile.menuNavigation`): by keys
    /// (`KEY,M,P`, `KEY,L,P`) or by its menu commands (`MNU`, `MSB`). Only which one command is sent
    /// differs; every guard around it is the same.
    @ObservationIgnored var navigation: MenuNavigation = .keys
    /// Called after each command's reply, or its timeout (`StationSession.noteMenuCommandReply`).
    @ObservationIgnored var onCommandReply: (@MainActor () -> Void)?
    /// Called each time `isInMenu` changes, detach included (`StationSession` tells its quick keys).
    @ObservationIgnored var onInMenuChanged: (@MainActor (Bool) -> Void)?

    /// The current run's client source; a new generation per attach, so a stale action can tell.
    private struct Link {
        let control: @Sendable () async -> ScannerClient?
        let generation: Int
        /// Revoked by `detach()`: a command of this run still waiting for the slot then writes nothing.
        let permit = SendPermit()
    }

    /// The part of `ScannerInfo` that says which menu screen is showing.
    private struct Signature: Equatable {
        var isMenu = false
        var title: String?
        var index: String?
        var kind: MenuScreenKind?

        static let outside = Signature()

        init() {}
        init(_ info: ScannerInfo) {
            guard info.isMenu else { return }
            isMenu = true
            title = info.menuTitle
            index = info.menuIndex
            kind = info.menuScreenKind
        }
    }

    private struct Snapshot {
        let info: ScannerInfo
        let content: MenuContent?
        /// The `MSI` went unanswered on the same screen, and `content` is what was already shown.
        var kept = false
    }

    @ObservationIgnored private var link: Link?
    /// Between `attach` and `detach` (tests: a stop detaches before its first await).
    var isAttached: Bool { link != nil }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The cancelled loop of the last detach, for `quiesce()`.
    @ObservationIgnored private var retiredRefresh: Task<Void, Never>?
    /// The breadcrumb with each screen's menu index (matched first, as titles can change and repeat).
    @ObservationIgnored private var path: [(title: String, index: String?)] = []
    @ObservationIgnored private var pushed: Signature?
    @ObservationIgnored private var lastRead = Signature.outside
    /// The pushed summary the last background read was for: a summary that stays different from
    /// what `GSI` says (a stale push) brings one read forward, not one per tick.
    @ObservationIgnored private var hintServed: Signature?
    @ObservationIgnored private var lastAttempt: ContinuousClock.Instant?
    @ObservationIgnored private var lastAttemptFailed = false
    /// Bumped by every read and action, so a background read that an action overtook is dropped.
    @ObservationIgnored private var readSequence = 0

    init(destructiveItems: DestructiveMenuItems = ModelProfile.profile(for: .sds200).destructiveMenuItems) {
        self.destructiveItems = destructiveItems
    }

    /// True for an item the model's list marks destructive (trimmed, case-insensitive).
    public func isDestructive(_ itemName: String) -> Bool {
        destructiveItems.contains(itemName)
    }

    // MARK: Session wiring

    /// Starts following the scanner through `control` (the runner's `control()`), with the refresh loop.
    func attach(control: @escaping @Sendable () async -> ScannerClient?) {
        detach()
        generation += 1
        let generation = self.generation
        link = Link(control: control, generation: generation)
        refreshTask = Task { [weak self] in await self?.refreshLoop(generation) }
    }

    /// Stops following: clears the menu state and the loop; actions in flight throw `.notConnected`.
    func detach() {
        generation += 1
        link?.permit.revoke()
        link = nil
        if let refreshTask {
            refreshTask.cancel()
            retiredRefresh = refreshTask
        }
        refreshTask = nil
        isBusy = false
        isScannerAnswering = true
        show(nil, title: nil, menuIndex: nil)
        pushed = nil
        hintServed = nil
        lastRead = .outside
        lastAttempt = nil
        lastAttemptFailed = false
    }

    /// Waits for the last detached refresh loop to end, so it sends nothing after the session's `PSI,0`.
    func quiesce() async {
        await retiredRefresh?.value
        retiredRefresh = nil
    }

    /// Each push (`runner.liveStatus`): a change of menu screen brings a read forward.
    func statusArrived(_ info: ScannerInfo) {
        guard link != nil else { return }
        pushed = Signature(info)
    }

    /// Sets `content` and the breadcrumb (nil leaves the menu). The model's reads come through
    /// here; tests use it to put an unconnected model on a screen.
    func show(_ content: MenuContent?, title: String?, menuIndex: String?) {
        let wasInMenu = isInMenu
        defer { if isInMenu != wasInMenu { onInMenuChanged?(isInMenu) } }
        guard let content else {
            if self.content != nil { self.content = nil }
            path = []
            if !breadcrumb.isEmpty { breadcrumb = [] }
            return
        }
        if self.content != content { self.content = content }
        if let title {
            visit(title: Self.breadcrumbTitle(title), index: menuIndex)
        }
        let titles = path.map(\.title)
        if breadcrumb != titles { breadcrumb = titles }
    }

    /// The top menu (a title spelling MENU, ignoring case, spaces and punctuation) is `Menu`;
    /// any other title is trimmed.
    static func breadcrumbTitle(_ raw: String) -> String {
        let letters = raw.filter { $0.isLetter || $0.isNumber }.uppercased()
        return letters == "MENU" ? "Menu" : raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func visit(title: String, index: String?) {
        if title == "Menu" {
            path = [(title, index)]
        } else if let index, let at = path.lastIndex(where: { $0.index == index }) {
            path.removeSubrange((at + 1)...)
            path[at].title = title
        } else if let at = path.lastIndex(where: { $0.title == title }) {
            path.removeSubrange((at + 1)...)
            path[at].index = index
        } else {
            path.append((title, index))
        }
    }

    // MARK: Actions

    /// Enters the menu (`KEY,M,P`, or `MNU,TOP,` where the model has menu commands). Reads `GSI`
    /// first: if the scanner is already in a menu it only re-reads (nothing is sent). Throws
    /// `.noAnswer`, sending nothing, if that read goes unanswered.
    @discardableResult
    public func enter() async throws -> MenuContent? {
        try await perform(inMenu: false) { link in
            let info = try await self.readInfo(link)
            if info.isMenu {
                let snapshot = try await self.snapshot(link, info)
                self.apply(snapshot)
                return snapshot.content
            }
            return try await self.command(link) { client, permit in
                switch self.navigation {
                case .keys: try await client.press(.menu, onlyIf: permit)
                case .menuCommands: try await client.openMenu(onlyIf: permit)
                }
            }
        }
    }

    /// Opens, chooses or toggles `item` of `screen` with one `MSV,,<index>`, after an `MSI`
    /// re-check: the scanner must still show a list with the same menu index and an item with the
    /// same index and name, or nothing is sent (`.menuChanged`, and `content` shows what was read).
    /// A destructive item throws `.needsConfirmation` unless `confirmedDestructive`.
    @discardableResult
    public func choose(_ item: MenuScreen.Item, on screen: MenuScreen,
                       confirmedDestructive: Bool = false) async throws -> MenuContent? {
        try await perform(inMenu: true) { link in
            if self.isDestructive(item.name) && !confirmedDestructive {
                throw MenuActionError.needsConfirmation(itemName: item.name)
            }
            let current = try await self.recheck(link)
            guard current.kind == .select, let menuIndex = screen.menuIndex, current.menuIndex == menuIndex,
                  current.items.contains(where: { $0.index == item.index && $0.name == item.name }) else {
                try await self.rereadAfterMismatch(link)
                throw MenuActionError.menuChanged
            }
            return try await self.command(link) { try await $0.setMenuValue(String(item.index), onlyIf: $1) }
        }
    }

    /// Saves `text` on the entry `screen` with one `MSV,,<text>`. Throws `.invalidValue`, sending
    /// nothing, unless `MenuInput.isValid(text, rules:)` holds for `screen`'s rules and again for the
    /// rules of the screen the `MSI` re-check reads (which must be an entry with the same menu
    /// index and the same `value`, or `.menuChanged`: a value changed on the radio, or by an
    /// earlier save whose reply was lost, isn't overwritten unseen).
    @discardableResult
    public func setValue(_ text: String, on screen: MenuScreen) async throws -> MenuContent? {
        try await perform(inMenu: true) { link in
            guard MenuInput.isValid(text, rules: screen.input ?? MenuScreen.InputRules()) else {
                throw MenuActionError.invalidValue
            }
            let current = try await self.recheck(link)
            guard current.kind == .input, let menuIndex = screen.menuIndex, current.menuIndex == menuIndex,
                  current.value == screen.value else {
                try await self.rereadAfterMismatch(link)
                throw MenuActionError.menuChanged
            }
            // The scanner's own rules, as just read, decide: never the caller's copy of them.
            guard MenuInput.isValid(text, rules: current.input ?? MenuScreen.InputRules()) else {
                self.show(Self.content(for: current), title: current.title, menuIndex: current.menuIndex)
                throw MenuActionError.invalidValue
            }
            return try await self.command(link) { try await $0.setMenuValue(text, onlyIf: $1) }
        }
    }

    /// Up one level (`KEY,M,P`, or `MSB,,`); on an entry screen it cancels without saving.
    @discardableResult
    public func back() async throws -> MenuContent? {
        try await perform(inMenu: true) { link in
            try await self.command(link) { client, permit in
                switch self.navigation {
                case .keys: try await client.press(.menu, onlyIf: permit)
                case .menuCommands: try await client.menuBack(onlyIf: permit)
                }
            }
        }
    }

    /// Leaves the menu from any depth (`KEY,L,P`, or `MSB,,RETURN_PREVOUS_MODE`); scanning resumes.
    /// Reads `GSI` first, since outside a menu that key is Avoid and `content` can lag the scanner
    /// (the radio's panel left the menu, or an earlier Exit took effect but its replies were lost):
    /// if the scanner is no longer in a menu nothing is sent, `content` turns nil and nil is
    /// returned. Throws `.noAnswer`, sending nothing, if that read goes unanswered.
    @discardableResult
    public func exit() async throws -> MenuContent? {
        try await perform(inMenu: true) { link in
            let info = try await self.readInfo(link)
            guard info.isMenu else {
                self.apply(Snapshot(info: info, content: nil))
                return nil
            }
            return try await self.command(link) { client, permit in
                switch self.navigation {
                case .keys: try await client.press(.avoid, onlyIf: permit)
                case .menuCommands: try await client.leaveMenu(onlyIf: permit)
                }
            }
        }
    }

    /// One front-panel key, for mirrored screens. `.enterYes` always reads `STS` first (unanswered:
    /// `.noAnswer`, nothing sent). When the highlighted row (an `:On`/`:Off` suffix stripped) is
    /// destructive: without `confirmedDestructive` it throws `.needsConfirmation(itemName:)`; with
    /// it, it sends only if `confirmedItemName` names that row (trimmed, ignoring case), else throws
    /// `.menuChanged` (nothing sent, screen re-read). A harmless row, or any other key, is sent
    /// whatever the flags. The radio's panel can still move the highlight between that `STS` and
    /// `KEY,E,P`; that window is accepted, like the `MSI`-to-`MSV` window (design §5.4).
    @discardableResult
    public func press(_ key: FrontPanelKey, confirmedDestructive: Bool = false,
                      confirmedItemName: String? = nil) async throws -> MenuContent? {
        try await perform(inMenu: true) { link in
            if key == .enterYes {
                // A fresh STS, not the session's display, which lags a key reply by 150 ms or more.
                guard let status = try await self.read(link, { try await $0.displayStatus() }) else {
                    throw MenuActionError.noAnswer
                }
                if let name = Self.highlightedRowName(status), self.isDestructive(name) {
                    guard confirmedDestructive else { throw MenuActionError.needsConfirmation(itemName: name) }
                    guard let confirmed = confirmedItemName,
                          Self.itemName(row: confirmed).lowercased() == name.lowercased() else {
                        try await self.rereadAfterMismatch(link)
                        throw MenuActionError.menuChanged
                    }
                }
            }
            return try await self.command(link) { try await $0.press(key, onlyIf: $1) }
        }
    }

    /// Re-reads the screen (`GSI`, then `MSI` in a menu); sends nothing that changes state. Works
    /// in a menu or not (nil: not in one). Throws `.noAnswer` if `GSI` goes unanswered.
    @discardableResult
    public func refresh() async throws -> MenuContent? {
        try await perform(inMenu: nil) { link in
            let snapshot = try await self.fetch(link)
            self.apply(snapshot)
            return snapshot.content
        }
    }

    // MARK: Action plumbing

    /// Runs one action: the connection, menu and busy checks, `isBusy` for the whole body (released
    /// on every exit unless a detach already did), and `lastError`. `inMenu`: true requires a menu,
    /// false requires none but lets the body decide, nil accepts either.
    private func perform(inMenu: Bool?, _ body: (Link) async throws -> MenuContent?) async throws -> MenuContent? {
        let started = generation
        do {
            guard let link else { throw MenuActionError.notConnected }
            if inMenu == true, content == nil { throw MenuActionError.notInMenu }
            guard !isBusy else { throw MenuActionError.busy }
            isBusy = true
            lastError = nil
            readSequence += 1
            defer {
                if isAlive(link) {
                    isBusy = false
                    lastAttempt = .now
                }
            }
            do {
                return try await body(link)
            } catch let error as MenuActionError {
                throw error
            } catch {
                throw MenuActionError.noAnswer
            }
        } catch let error as MenuActionError {
            // Not over a later run's state: a stale action unwinding after a re-attach stays quiet.
            if error != .busy, generation == started || link == nil { lastError = error }
            throw error
        }
    }

    private func isAlive(_ link: Link) -> Bool {
        self.link?.generation == link.generation
    }

    /// The run's client, or `.notConnected` once detached or the runner's stop began.
    private func client(_ link: Link) async throws -> ScannerClient {
        guard isAlive(link) else { throw MenuActionError.notConnected }
        let client = await link.control()
        guard let client, isAlive(link) else { throw MenuActionError.notConnected }
        return client
    }

    /// How a state-changing command ended.
    enum CommandReply: Equatable {
        case ok, rejected(String), unanswered, gone
        /// Refused before anything was sent (an argument with a comma, CR or LF).
        case refused
        /// Withheld at the client's slot: the run detached while the command waited, and nothing was sent.
        case withheld
    }

    /// The `CommandReply` for an error the command threw.
    static func commandReply(to error: any Error) -> CommandReply {
        switch error {
        // `ScannerCommand` refuses the argument as it builds the command, before the client sends.
        case is ScannerCommandError: return .refused
        case let error as ScannerClientError:
            switch error {
            case .invalidArgument: return .refused
            case .rejected(_, let response): return .rejected(response)
            case .unexpectedResponse(let command): return .rejected("unexpected reply to \(command)")
            case .timeout: return .unanswered
            case .notConnected: return .gone
            case .withheld: return .withheld
            }
        default: return .unanswered  // cancelled: whether it went out is unknown
        }
    }

    /// Sends the action's one state-changing command, never resent, then re-reads the screen. A
    /// command refused before sending throws `.invalidValue`, with no display nudge and no re-read.
    /// `send` hands its `onlyIf` (the run's permit) to the client, so a command still waiting for the slot when
    /// the model detaches is withheld: then nothing went out, so no display nudge and no re-read.
    private func command(_ link: Link,
                         _ send: (ScannerClient, @escaping @Sendable () -> Bool) async throws -> Void) async throws -> MenuContent? {
        let client = try await client(link)
        let reply: CommandReply
        do {
            try await send(client, link.permit.check)
            reply = .ok
        } catch {
            reply = Self.commandReply(to: error)
        }
        if reply == .refused { throw MenuActionError.invalidValue }
        if reply == .withheld { throw MenuActionError.notConnected }
        onCommandReply?()
        guard isAlive(link), reply != .gone else { throw MenuActionError.notConnected }

        let after: MenuContent?
        let rereadAnswered: Bool
        do {
            let snapshot = try await fetch(link)
            apply(snapshot)
            after = snapshot.content
            // Kept: the screen's MSI went unanswered and its old content stays.
            rereadAnswered = !snapshot.kept
        } catch MenuActionError.notConnected {
            throw MenuActionError.notConnected
        } catch {
            // Unanswered re-read: content stays as it was; the refresh loop keeps trying.
            after = content
            rereadAnswered = false
        }
        // An OK whose outcome no read confirmed is reported as unanswered.
        if !rereadAnswered, reply == .ok { throw MenuActionError.noAnswer }
        switch reply {
        case .ok: return after
        case .rejected(let response): throw MenuActionError.rejected(response)
        case .unanswered: throw MenuActionError.noAnswer
        case .gone: throw MenuActionError.notConnected
        case .refused: throw MenuActionError.invalidValue  // thrown above, before the nudge
        case .withheld: throw MenuActionError.notConnected  // thrown above, before the nudge
        }
    }

    /// The `MSI` re-check before an `MSV`. Unanswered or garbled: nothing is sent (`.noAnswer`).
    private func recheck(_ link: Link) async throws -> MenuScreen {
        guard case .value(let screen) = try await readScreen(link) else { throw MenuActionError.noAnswer }
        return screen
    }

    /// After a failed re-check: show what the scanner says now (best effort).
    private func rereadAfterMismatch(_ link: Link) async throws {
        do {
            apply(try await fetch(link))
        } catch MenuActionError.notConnected {
            throw MenuActionError.notConnected
        } catch {
            // Unanswered: content stays; the refresh loop keeps trying.
        }
    }

    // MARK: Reads

    /// `GSI`, then `MSI` when in a menu. Throws `.noAnswer` when `GSI` goes unanswered.
    private func fetch(_ link: Link) async throws -> Snapshot {
        try await snapshot(link, try await readInfo(link))
    }

    /// The screen for a `GSI` answer: nil outside a menu; in one, what `MSI` says. An unanswered
    /// `MSI` keeps the current list or entry when `GSI` still shows the screen it was read on
    /// (`kept`); with no such content (a new screen, a first read) it is `.mirrored`, as is an
    /// `MSI` answered with anything but a list or entry, or with something that doesn't parse.
    private func snapshot(_ link: Link, _ info: ScannerInfo) async throws -> Snapshot {
        guard info.isMenu else { return Snapshot(info: info, content: nil) }
        switch try await readScreen(link) {
        case .value(let screen):
            return Snapshot(info: info, content: Self.content(for: screen))
        case .garbled:
            return Snapshot(info: info, content: .mirrored)
        case .unanswered:
            if Signature(info) == lastRead, let content, content != .mirrored {
                return Snapshot(info: info, content: content, kept: true)
            }
            return Snapshot(info: info, content: .mirrored)
        }
    }

    private func readInfo(_ link: Link) async throws -> ScannerInfo {
        guard let info = try await read(link, { try await $0.scannerInfo() }) else { throw MenuActionError.noAnswer }
        return info
    }

    /// `MSI`.
    private func readScreen(_ link: Link) async throws -> ReadResult<MenuScreen> {
        try await readResult(link) { try await $0.menuScreen() }
    }

    /// One read (`GSI`, `STS`), tried `readTries` times; nil when every try went unanswered or
    /// garbled (then `isScannerAnswering` turns false; any answer turns it true again).
    private func read<Value: Sendable>(_ link: Link, _ op: (ScannerClient) async throws -> Value) async throws -> Value? {
        guard case .value(let value) = try await readResult(link, op) else { return nil }
        return value
    }

    private enum ReadResult<Value> {
        case value(Value)
        /// Every try timed out (or the read was cancelled).
        case unanswered
        /// At least one try was answered, but not with what was asked for.
        case garbled
    }

    /// `read(_:_:)`, telling an unanswered read from a garbled one.
    private func readResult<Value: Sendable>(_ link: Link, _ op: (ScannerClient) async throws -> Value) async throws -> ReadResult<Value> {
        var garbled = false
        for _ in 0..<Self.readTries {
            let client = try await client(link)
            do {
                let value = try await op(client)
                guard isAlive(link) else { throw MenuActionError.notConnected }
                isScannerAnswering = true
                return .value(value)
            } catch let error as MenuActionError {
                throw error
            } catch {
                guard isAlive(link), error as? ScannerClientError != .notConnected else {
                    throw MenuActionError.notConnected
                }
                if Task.isCancelled { return .unanswered }
                if case .timeout = error as? ScannerClientError {} else { garbled = true }
            }
        }
        isScannerAnswering = false
        return garbled ? .garbled : .unanswered
    }

    /// A list with items, or an entry whose rules give both `MaxLength` and `EnableKeys` (the
    /// shapes verified on hardware, design §4.6); anything else is `.mirrored`.
    static func content(for screen: MenuScreen?) -> MenuContent {
        guard let screen else { return .mirrored }
        switch screen.kind {
        case .select where !screen.items.isEmpty: return .list(screen)
        case .input where screen.input?.maxLength != nil && screen.input?.allowedCharacters != nil: return .entry(screen)
        default: return .mirrored
        }
    }

    private func apply(_ snapshot: Snapshot) {
        lastRead = Signature(snapshot.info)
        guard snapshot.info.isMenu else {
            show(nil, title: nil, menuIndex: nil)
            return
        }
        show(snapshot.content ?? .mirrored, title: snapshot.info.menuTitle, menuIndex: snapshot.info.menuIndex)
    }

    /// The fully highlighted row of a mirrored display, trimmed, without an `:On`/`:Off` suffix.
    static func highlightedRowName(_ display: DisplayModel?) -> String? {
        guard let row = display?.rows.first(where: { !$0.segments.isEmpty && $0.segments.allSatisfy(\.highlighted) })
        else { return nil }
        return itemName(row: row.segments.map(\.text).joined())
    }

    /// The same rule on a raw `STS` read: the line whose mask is `*` in every column of its text.
    static func highlightedRowName(_ status: DisplayStatus) -> String? {
        let line = status.lines.first { line in
            let mask = Array(line.highlightMask)
            return !line.text.isEmpty && mask.count >= line.text.count && mask.prefix(line.text.count).allSatisfy { $0 == "*" }
        }
        return line.map { itemName(row: $0.text) }
    }

    private static func itemName(row: String) -> String {
        var text = row.trimmingCharacters(in: .whitespaces)
        for suffix in [":on", ":off"] where text.lowercased().hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Refresh loop

    /// Reads only. While idle: at once when a push's menu summary differs from the last read's (no
    /// sooner than `refreshInterval` after a failed read), and every `refreshInterval` in a menu.
    private func refreshLoop(_ generation: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.refreshTick)
            guard !Task.isCancelled, let link, link.generation == generation else { return }
            guard !isBusy else { continue }
            let now = ContinuousClock.now
            let rested = lastAttempt.map { $0.duration(to: now) >= Self.refreshInterval } ?? true
            let differs = pushed.map { $0 != lastRead } ?? false
            let hinted = differs && (pushed != hintServed || (lastAttemptFailed && rested))
            guard hinted || (content != nil && rested) else { continue }
            await backgroundRead(link)
        }
    }

    private func backgroundRead(_ link: Link) async {
        readSequence += 1
        let sequence = readSequence
        hintServed = pushed
        do {
            let snapshot = try await fetch(link)
            guard isAlive(link), readSequence == sequence, !isBusy else { return }
            apply(snapshot)
            lastAttempt = .now
            lastAttemptFailed = false
        } catch {
            guard isAlive(link), readSequence == sequence else { return }
            lastAttempt = .now
            lastAttemptFailed = true
        }
    }
}
