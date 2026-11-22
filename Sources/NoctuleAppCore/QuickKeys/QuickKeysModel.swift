// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import NoctuleKit

/// One tile of the keypad: a Favorites List from `GLT,FL` with its state from `FQK`.
public struct QuickKeyListItem: Sendable, Equatable, Identifiable {
    public var index: UInt32
    public var name: String
    /// The list's quick key; nil for a list without one (no tile state, nothing to switch).
    public var key: Int?
    public var monitored: Bool
    /// From this open's `FQK`; nil before it, or for a list without a key. `.none` is a key `GLT`
    /// shows but `FQK` reports as 0 (design §3.2).
    public var state: QuickKeyState?
    /// How many systems the list has, once its structure is known (read, or from the cache).
    public var systemCount: Int?

    public var id: UInt32 { index }

    public init(index: UInt32, name: String, key: Int?, monitored: Bool, state: QuickKeyState?, systemCount: Int?) {
        self.index = index
        self.name = name
        self.key = key
        self.monitored = monitored
        self.state = state
        self.systemCount = systemCount
    }
}

/// One list's systems, with their departments and sites, as the pop-over shows them.
public struct QuickKeyListTree: Sendable, Equatable {
    public enum Freshness: Sendable, Equatable {
        /// A structure from the cache, or one being re-read (a key pattern changed, the scanner left a
        /// menu, the pop-over reopened): shown without states, nothing switchable.
        case checking
        /// The user opened the list before it was read this open: it jumped the queue.
        case loading
        /// Structure and states read since this open.
        case fresh
    }

    public struct ChildRow: Sendable, Equatable {
        public var index: UInt32
        public var name: String
        public var kind: FavoritesChild.Kind
        public var key: Int?
        public var avoided: Bool
        /// From this open's `DQK`, only while the tree is `.fresh`; nil when unread or not addressable
        /// (no key here, or none on the system or the list).
        public var state: QuickKeyState?

        public init(index: UInt32, name: String, kind: FavoritesChild.Kind, key: Int?, avoided: Bool,
                    state: QuickKeyState?) {
            self.index = index
            self.name = name
            self.kind = kind
            self.key = key
            self.avoided = avoided
            self.state = state
        }
    }

    public struct SystemRow: Sendable, Equatable {
        public var index: UInt32
        public var name: String
        public var type: String
        public var key: Int?
        public var avoided: Bool
        /// From this open's `SQK`, only while the tree is `.fresh`; nil when unread or not addressable.
        public var state: QuickKeyState?
        /// Departments, then sites, in `GLT` order.
        public var children: [ChildRow]

        public var isConventional: Bool { type == "Conventional" }

        public init(index: UInt32, name: String, type: String, key: Int?, avoided: Bool, state: QuickKeyState?,
                    children: [ChildRow]) {
            self.index = index
            self.name = name
            self.type = type
            self.key = key
            self.avoided = avoided
            self.state = state
            self.children = children
        }
    }

    public var systems: [SystemRow]
    public var freshness: Freshness
    /// Why the list's latest read failed, while it isn't `.fresh` (it is read again by itself): kept until it
    /// reads, leaves the keypad, or the pop-over closes or the session goes. Nil when `.fresh`.
    public var readError: String?

    public init(systems: [SystemRow], freshness: Freshness, readError: String? = nil) {
        self.systems = systems
        self.freshness = freshness
        self.readError = readError
    }
}

/// What the scanner is scanning now, matched to the tree by `Index` (design §3.4), never by quick key.
/// A level with no match is nil; the levels above it keep theirs.
public struct QuickKeyScanning: Sendable, Equatable {
    public var list: UInt32?
    public var system: UInt32?
    /// A department, else a site, of `system`.
    public var child: UInt32?

    public init(list: UInt32? = nil, system: UInt32? = nil, child: UInt32? = nil) {
        self.list = list
        self.system = system
        self.child = child
    }
}

/// One switchable row of the pop-over: a list's tile, a system, or a department or site, by `Index`.
public enum QuickKeyRow: Hashable, Sendable {
    case list(UInt32)
    case system(list: UInt32, system: UInt32)
    case child(list: UInt32, system: UInt32, child: UInt32)

    /// The list the row belongs to.
    public var list: UInt32 {
        switch self {
        case .list(let index): index
        case .system(let list, _): list
        case .child(let list, _, _): list
        }
    }
}

/// What a row's switch shows and whether a click on it is taken (design §5.4). Only `.on` and `.off` switch.
public enum QuickKeySwitchState: Equatable, Sendable {
    case on, off
    /// Not read since this open (the keypad or the list's tree hasn't arrived, or the pop-over is closed).
    case unknown
    /// Its tree is from the cache or being re-read (a key pattern changed, the scanner left a menu), or the
    /// keypad is being read again: nothing in it switches until the read is done.
    case checking
    /// The row, its list or its system has no quick key: the radio scans it whenever its parents are on.
    case noQuickKey
    /// A key `GLT` shows but the scanner reports as 0 (design §3.2): "The scanner doesn't report this key's state."
    case unreported
    /// A department or site of a system whose key another system in the list shares (`S<n>`): `DQK` can't
    /// tell those systems apart. Its state is still shown in the tree.
    case sharedSystemKey(Int)
    /// A system, department or site of a list whose key another list shares (`F<k>`): `SQK,<k>` and
    /// `DQK,<k>,<s>` can't tell those lists apart (final review I1). Its state is still shown in the tree. The
    /// lists' tiles still switch (`FQK` addresses the key itself; every list holding it changes together).
    case sharedListKey(Int)
    /// A system, department or site of a list read since this open while another list on the keypad isn't yet
    /// (design §10 "Late replies"): a late reply that landed on this list can be caught only once its true owner is
    /// read, so no tree row switches until every list has been read. Its state is still shown. Tiles aren't held.
    case checkingOtherLists
    /// The scanner is in a menu: "The scanner is in a menu".
    case inMenu
    /// The session isn't connected: the last lists and trees are shown read-only.
    case unavailable
    /// A change to this row's scope is under way.
    case busy
}

/// The Favorites quick keys for one session, as UI-free state (design
/// `docs/specs/2026-11-18-quick-keys-design.md` §5.4). Built like `MenuModel`.
///
/// **One command at a time.** Everything goes through the attached client (`control`, the runner's
/// `control()`) from one loop, so this model never has two commands in flight: `GLT`, `FQK`, `SQK` and
/// `DQK` reads, and the one set of each `toggle`. Nothing is sent unless the model is both attached and
/// open. After a failed read the background reads (the keypad, a list, the polls) rest for `pollInterval`;
/// two timeouts in a row set `isScannerAnswering` false (true again on the next answer).
///
/// **Late replies** (final review C1; design §10). Replies are matched to requests by command name only
/// (`ScannerClient`), so a reply that comes after its read gave up answers the next read of the same name.
/// After a timeout no background step goes for `pollInterval`, even across a close and reopen (`quietUntil`),
/// so a reply that late usually finds no read of its name and is dropped. A list whose read failed anywhere
/// isn't `.fresh`: it is read again in full after the rest, before any other list the first time, from
/// `GLT,SYS`. `FavoritesXML` refuses a `GLT` document holding another kind. What content alone can't tell
/// apart, a late `GLT` reply landing on a read of the same kind for another parent (the SDS200's UDP can
/// do it), is caught by **ownership**: every `Index` in the tree is unique across the whole tree [hw,
/// 2026-11-19], so each system belongs to one list and each department or site to one system. A reply
/// **conflicts**, and is refused, when it names an item another parent is known to hold (`checkOwnership`):
/// - a department or site held by another system of the same list: an earlier system of the read under way, or
///   one the list's last failed read this open had taken (`lastFailedRows`). Both are fresh: the reply is the
///   stray, and the read fails as any other ("The scanner's reply to GLT,DEPT belonged to another system.");
/// - one held by another system in the list's own known structure (the cache, or a read since re-checked): it may
///   be stale (a department moved), so the list is read again first, after the rest, with no failure counted,
///   and from then on this open checked against that refused read instead (`doubtedStructure`): a second read
///   that agrees is taken;
/// - a system held by another list, or a department or site held by a system of another list. If that list's
///   claim is fresh (read since this open), the reply may be the stray or that list may hold one: this read
///   fails, and that list is re-checked too. If it isn't fresh, it may be stale (the radio was reprogrammed): that
///   list is asked to settle it, at most once per open (`settledOnce`): it is re-checked first and this list read
///   again right after it, after the rest, with no failure counted. During that **settle re-read** (`settling`)
///   other lists' claims that aren't fresh don't count, and the ones its fresh reply contradicts are dropped from
///   their lists' structures once it succeeds, so crossing or rotated claims settle; nothing is skipped after that
///   read ends, whatever its outcome. If that list is failing to read, or was already asked this open, this read
///   fails instead. The skip covers every list's claim that isn't fresh, not only the asker's (a rotation needs
///   it; the controller kept it in fix round 3), and it leaves one window: a list B read this open and re-checked
///   since (by a conflict or a moved key, not a menu exit) whose read's timeout the in-place retry absorbed (so its
///   success cleared `gltTimedOut`) can have that read's late reply land on another list's settle re-read; it is
///   accepted there, B's claim is dropped, and no hold covers it. The pre-set check is then what stands between it
///   and a set.
/// A stray whose true owner hasn't been read yet can't be caught when it lands, only when the owner is read;
/// so **no tree row switches until every list on the keypad has been read** since this open or the last menu
/// exit (`.checkingOtherLists`, `isCheckingOtherLists`), except a list that has failed at least twice in a row.
/// And a list with a `GLT` read unanswered since its last good read, even one the in-place retry absorbed, holds
/// every tree switch until its own read succeeds, whether or not it was read this open (`gltTimedOut`): that reply
/// may still be on its way. Tiles aren't held. With that, a `GLT`
/// read that times out is **retried once in place** (`readStructure`): a late reply that answers the retry
/// is its own scope's, and one that lands elsewhere is caught. `FQK`, `SQK` and `DQK` reads aren't: a late
/// one can only mislead the display, since no set's keys come from a state, and the pattern check below
/// drops one whose pattern differs. **Not caught:** a late `GLT` reply with no items (a system with no
/// departments, an empty `GLT,SITE`) carries no index, so it can still answer another scope's read of its kind:
/// that scope then shows no rows until its next read, and nothing switchable comes of it. A list whose cached
/// claim no read settles (its own read keeps failing) keeps the list now holding that item from loading until it
/// reads. A late reply from a read that then succeeded (its timeout cleared when it read), or from a list that
/// fails only by refusals, can still land where nothing claims it once the switches are on. For those the
/// pre-set check (see Switching) is what stands between a stray and a set.
///
/// **A list that keeps failing** (2026-11-19: on the owner's SDS150 one list's `GLT` was refused on every
/// read, so the retry-first rule read it again and again and no list after it ever loaded). Only the first
/// retry goes before any other list, the one the user has just opened included (so a late reply to the failed
/// read can't land on that list's `GLT,SYS`). If it fails too, the list goes behind every other queued list (a list
/// the user then opens goes ahead of everything, as always) and is read again after them, and again, until
/// it reads (a menu exit's full re-read puts it last too, unless shown). Only an unanswered or refused or
/// unusable read counts, and a success, `close()` or `detach()` resets the count, so a new open or
/// connection starts with the first retry again. Its error stays on its tree (`QuickKeyListTree.readError`)
/// until it reads, leaves the keypad, or the states are dropped (`close()`, `detach()`); `lastError` holds
/// only the keypad's, the polls' and the changes' errors, and a list read never clears one of those.
///
/// **The loop**, while open and attached, one step at a time:
/// 1. The keypad: `GLT,FL` then `FQK`, before anything else on every open; `lists` is published,
///    then `trees` (from the cache or the last open, `.checking`, no states). Every list is queued:
///    the shown list (if not yet read), then the scanning one, then the keyed lists by key, then the
///    unkeyed ones in `GLT` order.
/// 2. Every `pollInterval`: `FQK`, then, for the shown list once it is `.fresh`, its `SQK` and the
///    `DQK` of each of its keyed systems.
/// 3. Otherwise the next queued list (one that failed once goes first, see above): `GLT,SYS`, each
///    system's `GLT,DEPT` (and `GLT,SITE` unless it is conventional), then, for a keyed list, `SQK` and
///    each keyed system's `DQK`. Then the list is `.fresh`, and the cache is rewritten.
///
/// **Key patterns.** Each state scope (`FQK`; `SQK` by list key; `DQK` by list and system key) keeps
/// the pattern of existing keys from its first read since its tree loaded. A poll that differs is read
/// again once (a late reply to another scope, design §5.4 Switching 4); if it still differs, the
/// structure changed: for `FQK` the keypad is read again and every list whose key changed is
/// re-checked; for `SQK`/`DQK` the list goes `.checking` and is read again first.
///
/// **Freshness.** A tree's rows carry states only while it is `.fresh`; `.checking` and `.loading`
/// show none. Leaving a menu (`statusArrived`, `isMenu` true then false) marks every tree `.checking`
/// and reads the keypad and every list again. `close()` and `detach()` stop all reads and drop every
/// state; the structure stays, `.checking`. Detached, the last keypad and trees of this session stay,
/// read-only (an open then shows them, not an empty keypad); from disk only trees load.
///
/// **Switching** (`toggle`, design §5.4 "Switching"). A click asks for the opposite of the row's shown
/// state and is taken only while `switchState` is `.on` or `.off`; nothing else (an open, a poll, a menu
/// exit, a reconnect) ever sets a key. It marks the row's scope (the keypad, a list's systems, a system's
/// departments and sites) `.busy`, refusing further clicks there, and waits its turn in the loop, after the
/// step under way (a poll, a list read) and before any other: so a set and a read never overlap, and the
/// set never goes out between a poll's reads. When its turn comes the row is checked again (still `.on` or
/// `.off`, the same keys). A system's or a child's set then **proves its own address** (`proveAddress`, the
/// controller's rulings, 2026-11-19): `GLT,FL` (it must hold the list, with the row's list key), `GLT,SYS,<list>`
/// (the system, with its key), then the **decisive scope twice with a fence between and after**: for a system
/// `GLT,FL`, `GLT,SYS,<list>` again (the system with its key, and the same systems as the first), `GLT,FL`; for a
/// department or site `GLT,DEPT` or `GLT,SITE,<system>` (the child with its key, and exactly the system's known
/// children of that kind), `GLT,FL`, the same again (the same children), `GLT,FL`. Every `Index` is unique, so a
/// reply of the right kind holding the element can only describe it, and the kinds alternate, so a reply out of
/// place usually meets a read of another kind and is refused. **What still defeats the check on its own** (the
/// minimum, worked out in fix round 3; design §10): when the row is wrong (the element really belongs to another
/// parent T), both decisive reads must be answered by late replies of T's decisive read (`GLT,DEPT|SITE,T`, or
/// `GLT,SYS` of the list that really holds the system), each arriving while its read is pending and before that
/// read's own reply, and both own replies must be lost or come only after the last fence: two late replies plus
/// two losses (the two late replies being what one read of T leaves when its first try and its in-place retry
/// both time out). A pure persistent shift of every reply by the same amount needs a shift of 4 for a system's set
/// (four outstanding replies, `FL`, `SYS`, `FL`, `SYS`, the second and fourth from T's list) and 5 for a child's
/// (`FL`, `SYS`, `DEPT|SITE` of T, `FL`, `DEPT|SITE` of T): an earlier check's replies, all late together. One
/// late reply plus one loss, or a shift of 2 (which defeated the first, single-read check), is refused. With the
/// ownership guard and the full-pass hold on, a wrong row must get past those first. Anything else sends nothing:
/// a reply that doesn't prove the address re-checks the list ("The list changed on the scanner; nothing was
/// sent."), and a read unanswered or refused leaves it ("The scanner didn't answer; nothing was sent."). These
/// reads aren't retried in place. A tile's set needs no check: its address, the list key from `GLT,FL`, is global.
/// After the check, the row is checked again, and exactly one set naming only that key is sent (`setListKey`,
/// `setSystemKey` or `setDepartmentKey`: "0", leave alone, for every other key), and it is **never resent**. The set
/// is **decided at the request slot** (flaky-sweep review I2, 2026-11-22): it can wait there behind another reader's
/// command (the display's `STS`, the menu's `GSI`) for up to a command timeout, so it carries a `SendPermit` that
/// every stop of the run (`close()`, `detach()`) and a menu (`isInMenu` turning true) revoke synchronously, and the
/// client writes it only if the permit still holds once it has the slot (`ScannerClient.send(_:onlyIf:)`). Withheld,
/// nothing was sent: no error, no re-read. What remains is the moment between that check and the write, with no
/// suspension between them. Its reply
/// can be `OK`, `NG`, nothing (a timeout), or a stray (a late reply to an earlier read of the same command,
/// which answers by name): anything but `OK` leaves the outcome unknown, and `lastError` says "The scanner
/// didn't confirm the change". Either way the scope is then read again and shows what the scanner holds.
/// That confirming read, like every poll, takes a reply only if it is 100 values whose pattern of existing
/// keys is the scope's (design §5.4 Switching 4); one that isn't (another scope's late values, or the set's
/// own late `OK` or `NG`) is dropped and the scope read once more. A pattern that still differs means the
/// structure changed: the keypad, or the list, is re-checked as after a poll. If the re-read fails, the
/// scope's states are dropped (its rows `.unknown`, not switchable) until a read succeeds: the next poll
/// for the keypad and the shown list, a re-check for any other list. The change error stays until the next
/// accepted click, `open()` or `close()`, and shows ahead of a read error.
@MainActor @Observable
public final class QuickKeysModel {
    /// The keypad, in `GLT` order; read on every open (never from the cache), empty until then.
    public private(set) var lists: [QuickKeyListItem] = []
    /// Trees by list index. A list with no known structure has none until it is read (or shown).
    public private(set) var trees: [UInt32: QuickKeyListTree] = [:]
    /// The list the pop-over has open ("n ›"); its states are polled.
    public private(set) var shownList: UInt32?
    public private(set) var scanning = QuickKeyScanning()
    public private(set) var isScannerAnswering = true
    /// The latest failed read of the keypad, a poll or a change's re-read, or a change the scanner didn't
    /// confirm, for the pop-over; a read error is cleared by the next successful read of those kinds. A list's
    /// failed read is on its tree instead (`QuickKeyListTree.readError`). Read errors are sentences: "The
    /// scanner didn't answer FQK.", "The scanner refused FQK.", "The scanner's reply to FQK couldn't be read."
    public private(set) var lastError: String?
    /// Between `open()` and `close()`.
    public private(set) var isOpen = false
    /// Between `attach` and `detach`: the session is connected and the model can read.
    public private(set) var isAttached = false
    /// Open and reading, with a list on the keypad not yet read since this open or the last menu exit (and not
    /// failing twice in a row, unless one of its `GLT` reads went unanswered): tree rows wait for it
    /// (`.checkingOtherLists`), and the pop-over says "Checking the other lists…".
    public private(set) var isCheckingOtherLists = false
    /// The latest push, or the session's menu model (`menuReadChanged(_:)`), says the scanner is in a
    /// menu: nothing switches.
    public private(set) var isInMenu = false
    /// The scopes with a `toggle` queued or under way: their rows are `.busy`.
    private var busyScopes: Set<Scope> = []

    @ObservationIgnored let cacheURL: URL?
    /// How often an open model polls the states (design §5.4: about 2 s).
    @ObservationIgnored let pollInterval: Duration
    /// The longest the loop sleeps when idle, so `showList` and a menu exit are picked up promptly.
    static let idleTick: Duration = .milliseconds(50)

    private enum Scope: Hashable {
        case lists
        case systems(listKey: Int)
        case children(QuickKeyPair)
    }

    private enum KeypadRead {
        /// On open and after a menu: every list is re-checked.
        case all
        /// After `FQK`'s pattern changed: lists whose key changed are re-checked, new ones queued.
        case changedKeys
    }

    private enum ReadFailure: Error {
        /// Closed, detached, or a newer run: stop quietly.
        case gone
        /// No client (the runner's stop began).
        case noClient
        case unanswered(String)
        /// It answered, just not usefully: what the pop-over says, and the error itself for the trace.
        case failed(message: String, detail: String)
    }

    /// A `GLT` reply naming an item another parent holds (see the type's comment): `item` belongs to `owner`
    /// (a list for `GLT,SYS`, a system for `GLT,DEPT`/`GLT,SITE`), which is, or is in, list `ownerList`.
    private struct Conflict: Error {
        /// Where the other claim comes from.
        enum Source {
            /// An earlier system of the read under way.
            case pass
            /// A system the same list's last failed or refused read this open had taken (`lastFailedRows`).
            case lastFailedRead
            /// The same list's known structure (the cache, or a read since re-checked), not yet doubted this open.
            case ownStructure
            /// Another list's known structure.
            case otherList
        }

        let request: String
        let parent: UInt32
        let item: UInt32
        let owner: UInt32
        let ownerList: UInt32
        let source: Source
        /// The claim was read since this open (or by the read under way) and not re-checked since.
        let fresh: Bool

        var message: String {
            "The scanner's reply to \(request) belonged to another \(request == "GLT,SYS" ? "list" : "system")."
        }

        /// For the trace: indexes only, never names.
        var detail: String { "\(request) for \(parent) refused: item \(item) belongs to \(owner)" }
    }

    private enum PollResult {
        case value(QuickKeyStates)
        case changed
    }

    @ObservationIgnored private var control: (@Sendable () async -> ScannerClient?)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retired: [Task<Void, Never>] = []
    /// The known structure by list index (stateless): what the cache holds.
    @ObservationIgnored private var structure: [UInt32: QuickKeyListTree]
    @ObservationIgnored private var freshness: [UInt32: QuickKeyListTree.Freshness] = [:]
    /// `GLT,FL` of this open.
    @ObservationIgnored private var favorites: [FavoritesList] = []
    @ObservationIgnored private var listStates: QuickKeyStates?
    @ObservationIgnored private var systemStates: [Int: QuickKeyStates] = [:]
    @ObservationIgnored private var childStates: [QuickKeyPair: QuickKeyStates] = [:]
    @ObservationIgnored private var baselines: [Scope: Set<Int>] = [:]
    /// Pending keypad read (tracked: while one is pending, no row switches).
    private var keypadRead: KeypadRead?
    /// Bumped by each menu exit's request for a full re-read, so a keypad read under way is dropped.
    @ObservationIgnored private var keypadRequest = 0
    /// The list whose full read is under way.
    @ObservationIgnored private var readingList: UInt32?
    @ObservationIgnored private var queue: [UInt32] = []
    /// Bumped whenever a list is re-checked, so a read of it already under way is dropped.
    @ObservationIgnored private var epochs: [UInt32: Int] = [:]
    @ObservationIgnored private var nextPoll: ContinuousClock.Instant?
    @ObservationIgnored private var restUntil: ContinuousClock.Instant?
    /// After a timeout: no background read until then, whatever run is going (a stopped run's late reply
    /// can still come), so the late reply finds no read of its name.
    @ObservationIgnored private var quietUntil: ContinuousClock.Instant?
    @ObservationIgnored private var timeoutsInARow = 0
    /// A list whose read failed once: read again before any other list, so the next `GLT,SYS` is its own.
    @ObservationIgnored private var retryFirst: UInt32?
    /// Each list's failed reads in a row (a read that succeeds, a close or a detach resets it): after the second,
    /// the list goes behind every other queued list, so one that always fails never starves the rest.
    @ObservationIgnored private var failures: [UInt32: Int] = [:]
    /// Why each list's latest read failed, until it reads, leaves the keypad, or the states are dropped
    /// (`QuickKeyListTree.readError`).
    @ObservationIgnored private var listErrors: [UInt32: String] = [:]
    /// The lists read in full since this open or the last menu exit (another re-check doesn't take one out): until
    /// every list on the keypad is here, or failing, no tree row switches (`isCheckingOtherLists`).
    @ObservationIgnored private var readThisOpen: Set<UInt32> = []
    /// Lists with a `GLT` read unanswered this open (even once, the in-place retry answered or not) and no successful
    /// read since: a reply to it may still be on its way, so they hold every tree switch, read this open or not, failing
    /// or not (`updateFullPass`).
    @ObservationIgnored private var gltTimedOut: Set<UInt32> = []
    /// Per list, the systems its last failed or refused read this open had taken (and, after a refusal for its own
    /// structure, the refused system as read): claims, as fresh as the read under way, for its next read.
    @ObservationIgnored private var lastFailedRows: [UInt32: [QuickKeyListTree.SystemRow]] = [:]
    /// Lists whose own known structure a read has contradicted once this open: their later reads aren't checked against
    /// it, only against their own pass and `lastFailedRows`, so a department that really moved is taken on a second
    /// read that agrees with the first.
    @ObservationIgnored private var doubtedStructure: Set<UInt32> = []
    /// Lists asked to settle a claim this open: a list is asked at most once per open.
    @ObservationIgnored private var settledOnce: Set<UInt32> = []
    /// Lists whose next read is a settle re-read: during it, other lists' claims that aren't fresh don't count, and the
    /// ones its fresh reply contradicts are dropped once it succeeds (nothing is skipped after that read).
    @ObservationIgnored private var settling: Set<UInt32> = []
    @ObservationIgnored private var lastInfo: ScannerInfo?
    /// What `session.menu`'s own reads last said (`menuReadChanged(_:)`); false until attached.
    @ObservationIgnored private var menuReadInMenu = false
    /// The latest failed read of the keypad, a poll or a change's re-read (cleared by the next good one of
    /// those, never by a list read) and the latest unconfirmed change (cleared by the next accepted click,
    /// `open()` or `close()`); `lastError` shows the change error first.
    @ObservationIgnored private var readError: String?
    @ObservationIgnored private var changeError: String?
    /// Clicks waiting for the loop, oldest first.
    @ObservationIgnored private var actions: [Action] = []
    /// The permit of the set waiting for (or holding) the client's request slot; revoked by every stop of the run and
    /// by a menu, so a set still queued then writes nothing.
    @ObservationIgnored private var setPermit: SendPermit?
    /// The loop's idle sleep, cancelled to wake it for a click.
    @ObservationIgnored private var sleeper: Task<Void, Never>?

    /// The error a change the scanner didn't confirm leaves (`lastError`); the pop-over shows it by this text.
    public nonisolated static let unconfirmedMessage = "The scanner didn't confirm the change"
    /// A set its pre-set check stopped because a reply didn't prove the row's address (`lastError`).
    /// How a refused read's message starts (`read`).
    private nonisolated static let refusedPrefix = "The scanner refused"
    public nonisolated static let listChangedMessage = "The list changed on the scanner; nothing was sent."
    /// A set its pre-set check stopped because a read went unanswered or was refused (`lastError`).
    public nonisolated static let checkUnansweredMessage = "The scanner didn't answer; nothing was sent."

    /// Test-only: false turns off the ownership check and the full-pass hold, so a test can show the pre-set check
    /// stands on its own. Always true in the product.
    @ObservationIgnored var structureGuardsOn = true

    /// The keys one set names: the scope it changes and the key in it.
    private enum Address: Equatable {
        case list(key: Int)
        case system(listKey: Int, key: Int)
        case child(QuickKeyPair, key: Int)

        var scope: Scope {
            switch self {
            case .list: .lists
            case .system(let listKey, _): .systems(listKey: listKey)
            case .child(let pair, _): .children(pair)
            }
        }
    }

    private struct Action {
        let row: QuickKeyRow
        let address: Address
        /// What the click asks for: true is on.
        let on: Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    /// `cacheURL` is the station's `quick-keys.json` (nil keeps no cache); it is read here, once.
    /// `pollInterval` is short in tests.
    public init(cacheURL: URL?, pollInterval: Duration = .seconds(2)) {
        self.cacheURL = cacheURL
        self.pollInterval = pollInterval
        structure = cacheURL.flatMap(QuickKeysCache.load(from:)) ?? [:]
    }

    // MARK: Session wiring

    /// Starts following the scanner through `control` (the runner's `control()`); reads begin if open.
    func attach(control: @escaping @Sendable () async -> ScannerClient?) {
        detach()
        self.control = control
        isAttached = true
        if isOpen { startRun() }
    }

    /// Stops following: every read stops and every state is dropped (the structure stays, `.checking`).
    func detach() {
        control = nil
        if isAttached { isAttached = false }
        stopRun()
        dropStates()
        isScannerAnswering = true
        timeoutsInARow = 0
        lastInfo = nil
        menuReadInMenu = false
        if isInMenu { isInMenu = false }
        if scanning != QuickKeyScanning() { scanning = QuickKeyScanning() }
    }

    /// Waits for every stopped loop to end, so nothing is sent after the session's `PSI,0`.
    func quiesce() async {
        while !retired.isEmpty {
            let tasks = retired
            retired = []
            for task in tasks { await task.value }
        }
    }

    /// Each push (`runner.liveStatus`): "scanning now", and a menu exit re-checks every tree.
    func statusArrived(_ info: ScannerInfo) {
        guard control != nil else { return }
        lastInfo = info
        updateScanning()
        updateInMenu()
    }

    /// `session.menu`'s own reads (`MenuModel.isInMenu`), which can see a menu before a push does (design
    /// §5.4: "`session.menu.isInMenu`, or the last push says so"). Only while attached.
    func menuReadChanged(_ inMenu: Bool) {
        guard control != nil else { return }
        menuReadInMenu = inMenu
        updateInMenu()
    }

    /// In a menu while either source says so; leaving it (both say out) re-checks every tree.
    private func updateInMenu() {
        let wasInMenu = isInMenu
        let inMenu = (lastInfo?.isMenu ?? false) || menuReadInMenu
        // A set still waiting for the slot is withheld: nothing switches in a menu.
        if inMenu { revokeSetPermit() }
        if inMenu != wasInMenu { isInMenu = inMenu }
        if wasInMenu, !inMenu, isOpen { recheckAll() }
    }

    // MARK: Pop-over

    /// The pop-over (or its panel) shows: the keypad is read first, then every list in the background.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        setChangeError(nil)
        if !trees.isEmpty { trees = [:] }
        if control != nil {
            // The keypad is read before anything is shown.
            favorites = []
            if !lists.isEmpty { lists = [] }
            updateScanning()
            startRun()
        } else {
            // Offline: this session's last keypad (if any) and the known structure, read-only, every row
            // `.unavailable`, until the session connects; then a fresh keypad replaces them.
            updateScanning()
            for index in structure.keys { freshness[index] = .checking }
            publishTrees()
        }
    }

    /// The pop-over hides: reads stop and every state is dropped.
    public func close() {
        guard isOpen else { return }
        isOpen = false
        stopRun()
        dropStates()
        setChangeError(nil)
        if shownList != nil { shownList = nil }
    }

    /// The tree closes (focus moved to another tile, design §5.5): the polls stop reading that list's `SQK` and
    /// `DQK`; nothing else changes.
    public func hideList() {
        if shownList != nil { shownList = nil }
    }

    /// The user opens a list (the "n ›"). One not yet read this open jumps the queue and shows `.loading`.
    public func showList(_ index: UInt32) {
        if shownList != index { shownList = index }
        guard isOpen, freshness[index] != .fresh else { return }
        freshness[index] = .loading
        publishTree(index)
        // The list being read now arrives next anyway.
        if readingList != index, favorites.contains(where: { $0.index == index }) {
            queue.removeAll { $0 == index }
            queue.insert(index, at: 0)
            wakeLoop()
        }
    }

    // MARK: Switching

    /// What `row`'s switch shows, and whether a click on it is taken (only `.on` and `.off`).
    public func switchState(for row: QuickKeyRow) -> QuickKeySwitchState {
        let (state, address) = evaluate(row)
        if let address, state == .on || state == .off, busyScopes.contains(address.scope) { return .busy }
        return state
    }

    /// How many rows hold `row`'s key in its scope (lists on the keypad, systems of its list, departments
    /// and sites of its system), counting itself; 1 for a row without a key. They are one switch on the
    /// scanner and change together.
    public func sharing(for row: QuickKeyRow) -> Int {
        switch row {
        case .list(let index):
            guard let key = lists.first(where: { $0.index == index })?.key else { return 1 }
            return lists.filter { $0.key == key }.count
        case .system(let list, let index):
            guard let systems = trees[list]?.systems,
                  let key = systems.first(where: { $0.index == index })?.key else { return 1 }
            return systems.filter { $0.key == key }.count
        case .child(let list, let system, let index):
            guard let children = trees[list]?.systems.first(where: { $0.index == system })?.children,
                  let key = children.first(where: { $0.index == index })?.key else { return 1 }
            return children.filter { $0.key == key }.count
        }
    }

    /// A click on `row`: asks the scanner for the opposite of its shown state, with one set naming only its
    /// key, then reads its scope again (see the type's comment). Refused, with nothing sent, unless the
    /// row is `.on` or `.off`. Returns once the change and its re-read are done (or dropped).
    public func toggle(_ row: QuickKeyRow) async {
        let (state, address) = evaluate(row)
        guard state == .on || state == .off, let address, !busyScopes.contains(address.scope),
              isOpen, task != nil else { return }
        busyScopes.insert(address.scope)
        setChangeError(nil)
        await withCheckedContinuation { continuation in
            actions.append(Action(row: row, address: address, on: state == .off, continuation: continuation))
            wakeLoop()
        }
    }

    /// The row's state and the keys a set would name, from what is published (`lists`, `trees`) and the
    /// connection, menu and keypad flags; `busy` aside.
    private func evaluate(_ row: QuickKeyRow) -> (state: QuickKeySwitchState, address: Address?) {
        guard isAttached else { return (.unavailable, nil) }
        if isInMenu { return (.inMenu, nil) }
        guard let list = lists.first(where: { $0.index == row.list }) else { return (.unknown, nil) }
        // The keypad is being read again (on open, after a menu, or after `FQK`'s pattern changed): a list's
        // key may have moved, and every address below starts with one.
        if keypadRead != nil { return (.checking, nil) }
        let systemIndex: UInt32
        switch row {
        case .list:
            guard let key = list.key else { return (.noQuickKey, nil) }
            return (Self.shown(list.state), .list(key: key))
        case .system(_, let index), .child(_, let index, _):
            systemIndex = index
        }
        guard let tree = trees[row.list] else { return (.unknown, nil) }
        switch tree.freshness {
        case .checking: return (.checking, nil)
        case .loading: return (.unknown, nil)
        case .fresh: break
        }
        guard let system = tree.systems.first(where: { $0.index == systemIndex }) else { return (.unknown, nil) }
        // A row that would switch waits for every list to be read (a stray on it is caught only then).
        func held(_ state: QuickKeySwitchState, _ address: Address) -> (QuickKeySwitchState, Address?) {
            guard state == .on || state == .off else { return (state, address) }
            return isCheckingOtherLists ? (.checkingOtherLists, nil) : (state, address)
        }
        guard case .child(_, _, let childIndex) = row else {
            guard let listKey = list.key, let key = system.key else { return (.noQuickKey, nil) }
            if sharesKey(list) { return (.sharedListKey(listKey), nil) }
            return held(Self.shown(system.state), .system(listKey: listKey, key: key))
        }
        guard let child = system.children.first(where: { $0.index == childIndex }) else { return (.unknown, nil) }
        guard let listKey = list.key, let systemKey = system.key, let key = child.key else { return (.noQuickKey, nil) }
        if sharesKey(list) { return (.sharedListKey(listKey), nil) }
        if tree.systems.contains(where: { $0.index != system.index && $0.key == systemKey }) {
            return (.sharedSystemKey(systemKey), nil)
        }
        return held(Self.shown(child.state), .child(QuickKeyPair(list: listKey, system: systemKey), key: key))
    }

    /// Another list on the keypad holds `list`'s key.
    private func sharesKey(_ list: QuickKeyListItem) -> Bool {
        guard let key = list.key else { return false }
        return lists.contains { $0.index != list.index && $0.key == key }
    }

    private static func shown(_ state: QuickKeyState?) -> QuickKeySwitchState {
        switch state {
        case .some(.on): .on
        case .some(.off): .off
        case .some(.none): .unreported
        case nil: .unknown
        }
    }

    /// One click's turn in the loop: checked again, one set (never resent), then the confirming re-read.
    private func perform(_ action: Action, _ generation: Int) async {
        defer {
            busyScopes.remove(action.address.scope)
            action.continuation.resume()
        }
        // Still switchable (a menu, a re-check or a disconnect since the click drops it). The address check is
        // defence in depth: a moved key always passes through `.checking` first.
        func stillSwitchable() -> Bool {
            let (state, address) = evaluate(action.row)
            return (state == .on || state == .off) && address == action.address
        }
        guard stillSwitchable(), isAlive(generation), control != nil else { return }
        // The set proves its own address first (see the type's comment); nothing is sent unless it does.
        switch await proveAddress(action, generation) {
        case .proven:
            break
        case .gone:
            return
        case .unanswered:
            setChangeError(Self.checkUnansweredMessage)
            return
        case .changed:
            recheck(action.row.list)
            setChangeError(Self.listChangedMessage)
            return
        }
        // Checked again once the client is in hand, just before the set: a menu push may have come meanwhile.
        guard let control, let client = await control(), isAlive(generation), stillSwitchable() else { return }
        // And decided again once the set holds the client's slot: it may wait there for a command timeout behind
        // another reader's command, and a close, a detach or a menu meanwhile revokes this permit.
        let permit = SendPermit()
        setPermit = permit
        var confirmed = false
        let request = Self.traceName(action.address, on: action.on)
        do {
            defer { if setPermit === permit { setPermit = nil } }
            try await set(client, action.address, on: action.on, onlyIf: permit.check)
            confirmed = true
            CommandTrace.log("quickkeys: set \(request) -> OK")
        } catch ScannerClientError.withheld {
            // Nothing was sent, so nothing is unconfirmed and there is nothing to re-read.
            CommandTrace.log("quickkeys: set \(request) withheld at the slot; nothing sent")
            return
        } catch {
            CommandTrace.log("quickkeys: set \(request) -> \(error)")
            // NG, no reply, a stray reply, or the link going: whether it took effect is unknown. Never resent;
            // only the re-read says.
        }
        guard isAlive(generation) else { return }
        if !confirmed { setChangeError(Self.unconfirmedMessage) }
        let scope = action.address.scope
        do {
            let (name, op) = Self.reader(for: scope)
            switch try await scopeRead(scope, generation, name, op) {
            case .changed:
                if case .lists = scope {
                    if keypadRead == nil { keypadRead = .changedKeys }
                } else {
                    recheck(action.row.list)
                }
            case .value(let states):
                switch scope {
                case .lists:
                    listStates = states
                    publishLists()
                case .systems(let listKey):
                    systemStates[listKey] = states
                    publishTrees()
                case .children(let pair):
                    childStates[pair] = states
                    publishTrees()
                }
                setReadError(nil)
            }
        } catch {
            if case ReadFailure.gone = error { return }
            // Nothing says what the scope holds now (the set may or may not have taken effect): its rows show
            // no on/off and don't switch until a read succeeds. The poll reads the keypad and the shown list's
            // scopes; any other list is re-checked, so it is read again by itself.
            switch scope {
            case .lists:
                listStates = nil
                publishLists()
            case .systems(let listKey):
                systemStates[listKey] = nil
                publishTrees()
            case .children(let pair):
                childStates[pair] = nil
                publishTrees()
            }
            if scope != .lists, shownList != action.row.list { recheck(action.row.list) }
            failed(error, generation)
        }
    }

    private enum Proof {
        case proven
        /// Closed, detached, or a newer run.
        case gone
        /// A read of the check went unanswered or was refused.
        case unanswered
        /// A reply didn't prove the address: another kind, no such element, another key, other children.
        case changed
    }

    /// The pre-set check of a system's or a child's set (a tile's set needs none: its address, the list key, comes
    /// from `GLT,FL` and is global): `GLT,FL` (must hold the list, with the address's list key), `GLT,SYS,<list>` (must
    /// hold the system, with its key), for a department or site `GLT,DEPT|SITE,<system>` (must hold the child, with its
    /// key, and exactly the system's known children of that kind), then `GLT,FL` as a fence, the decisive read (the
    /// system's `GLT,SYS`, or the child's `GLT,DEPT|SITE`) again, which must agree with the first, and a closing
    /// `GLT,FL`. Every `Index` is unique, so a reply of the right kind holding the element can only describe it, and the
    /// kinds alternate; what still defeats the check on its own is in the type's comment (two late replies plus two
    /// losses). These reads aren't retried in place.
    private func proveAddress(_ action: Action, _ generation: Int) async -> Proof {
        let listIndex = action.row.list
        let systemIndex: UInt32
        var childIndex: UInt32?
        switch action.row {
        case .list: return .proven
        case .system(_, let system): systemIndex = system
        case .child(_, let system, let child):
            systemIndex = system
            childIndex = child
        }
        let keys: (list: Int, system: Int, child: Int?)
        switch action.address {
        case .list: return .proven
        case .system(let listKey, let key): keys = (listKey, key, nil)
        case .child(let pair, let key): keys = (pair.list, pair.system, key)
        }
        func changed(_ why: String) -> Proof {
            CommandTrace.log("quickkeys: set check on list \(listIndex), system \(systemIndex): \(why); nothing sent")
            return .changed
        }
        func fence() async throws {
            _ = try await read(generation, "GLT,FL") { try await $0.favoritesLists() }
        }
        do {
            let lists = try await read(generation, "GLT,FL") { try await $0.favoritesLists() }
            guard lists.first(where: { $0.index == listIndex })?.quickKey == keys.list else { return changed("GLT,FL") }
            func readSystems() async throws -> [FavoritesSystem]? {
                let systems = try await read(generation, "GLT,SYS") { try await $0.favoritesSystems(inList: listIndex) }
                return systems.first(where: { $0.index == systemIndex })?.quickKey == keys.system ? systems : nil
            }
            guard let systems = try await readSystems() else { return changed("GLT,SYS") }
            if let childIndex {
                let known = structure[listIndex]?.systems.first { $0.index == systemIndex }?.children ?? []
                guard let kind = known.first(where: { $0.index == childIndex })?.kind else { return changed("not known") }
                let name = kind == .department ? "GLT,DEPT" : "GLT,SITE"
                func readChildren() async throws -> Set<UInt32>? {
                    let children = try await read(generation, name) {
                        kind == .department ? try await $0.favoritesDepartments(inSystem: systemIndex)
                            : try await $0.favoritesSites(inSystem: systemIndex)
                    }
                    guard children.first(where: { $0.index == childIndex })?.quickKey == keys.child else { return nil }
                    return Set(children.map(\.index))
                }
                // The decisive scope, twice with a fence between: both replies must hold the child with its key, agree,
                // and equal the system's known children of that kind.
                guard let first = try await readChildren(),
                      first == Set(known.filter { $0.kind == kind }.map(\.index)) else { return changed(name) }
                try await fence()
                guard try await readChildren() == first else { return changed("\(name) again") }
            } else {
                // The decisive scope, twice with a fence between: both replies must hold the system with its key and
                // agree.
                try await fence()
                guard let again = try await readSystems(),
                      Set(again.map(\.index)) == Set(systems.map(\.index)) else { return changed("GLT,SYS again") }
            }
            try await fence()
            CommandTrace.log("quickkeys: set check on list \(listIndex), system \(systemIndex) passed")
            return .proven
        } catch {
            switch error as? ReadFailure {
            case .gone, .noClient, nil:
                return .gone
            case .unanswered(let name):
                CommandTrace.log("quickkeys: set check: \(name) unanswered; nothing sent")
                return .unanswered
            case .failed(let message, let detail):
                // A refusal is the scanner not answering the check; a reply it can't take (another kind) is a stray.
                if message.hasPrefix(Self.refusedPrefix) {
                    CommandTrace.log("quickkeys: set check: \(detail); nothing sent")
                    return .unanswered
                }
                return changed(detail)
            }
        }
    }

    /// A set as the trace names it: keys only, never a name.
    private static func traceName(_ address: Address, on: Bool) -> String {
        let state = on ? "on" : "off"
        switch address {
        case .list(let key): return "FQK key \(key) \(state)"
        case .system(let listKey, let key): return "SQK list key \(listKey), key \(key) \(state)"
        case .child(let pair, let key): return "DQK list key \(pair.list), system key \(pair.system), key \(key) \(state)"
        }
    }

    private func set(_ client: ScannerClient, _ address: Address, on: Bool,
                     onlyIf proceed: @escaping @Sendable () -> Bool) async throws {
        switch address {
        case .list(let key):
            try await client.setListKey(key, on: on, onlyIf: proceed)
        case .system(let listKey, let key):
            try await client.setSystemKey(key, inList: listKey, on: on, onlyIf: proceed)
        case .child(let pair, let key):
            try await client.setDepartmentKey(key, inList: pair.list, system: pair.system, on: on, onlyIf: proceed)
        }
    }

    /// The set waiting for (or holding) the client's slot, if any, writes nothing from now on.
    private func revokeSetPermit() {
        setPermit?.revoke()
        setPermit = nil
    }

    /// The read of a scope's states: `FQK`, `SQK,<list key>` or `DQK,<list key>,<system key>`.
    private static func reader(for scope: Scope) -> (String, @Sendable (ScannerClient) async throws -> QuickKeyStates) {
        switch scope {
        case .lists:
            ("FQK", { try await $0.listKeyStates() })
        case .systems(let listKey):
            ("SQK", { try await $0.systemKeyStates(listKey: listKey) })
        case .children(let pair):
            ("DQK", { try await $0.departmentKeyStates(listKey: pair.list, systemKey: pair.system) })
        }
    }

    // MARK: The loop

    /// A new run waits for every stopped one to end before its first read: a stopped run's read is
    /// never abandoned (cancelling it would free the client's slot before the scanner answered, and its
    /// late reply would answer the new run's read of the same command), so it is never two in flight.
    private func startRun() {
        stopRun()
        generation += 1
        let generation = self.generation
        keypadRead = .all
        resetPassState()
        // Each run waits for the ones before it, so awaiting the latest stopped run covers them all.
        let previous = retired
        retired = []
        task = Task { [weak self] in
            for run in previous { await run.value }
            await self?.run(generation)
        }
    }

    /// Stops scheduling reads. A read under way finishes (its result is dropped: the generation moved on);
    /// `quiesce()` waits for it.
    private func stopRun() {
        generation += 1
        // A set already waiting for the client's slot writes nothing (`perform`).
        revokeSetPermit()
        if let task { retired.append(task) }
        task = nil
        keypadRead = nil
        queue = []
        nextPoll = nil
        restUntil = nil
        // Clicks still waiting send nothing; one under way finishes a command already written and stops (`perform`).
        let waiting = actions
        actions = []
        for action in waiting {
            busyScopes.remove(action.address.scope)
            action.continuation.resume()
        }
        wakeLoop()
    }

    private func isAlive(_ generation: Int) -> Bool {
        self.generation == generation && isOpen && control != nil
    }

    private func run(_ generation: Int) async {
        while isAlive(generation) {
            let now = ContinuousClock.now
            let rests = [restUntil, quietUntil].compactMap { $0 }.filter { now < $0 }
            let resting = !rests.isEmpty
            if !actions.isEmpty {
                // A click goes first, after the step under way: never between a poll's reads.
                await perform(actions.removeFirst(), generation)
            } else if let reason = keypadRead, !resting {
                await readKeypad(reason, generation)
            } else if let due = nextPoll, now >= due, !resting {
                await poll(generation)
                if isAlive(generation) { nextPoll = .now + pollInterval }
            } else if keypadRead == nil, !resting, let next = nextList() {
                await readList(next, generation)
            } else {
                var wait = Self.idleTick
                if let due = nextPoll { wait = min(wait, now.duration(to: due)) }
                for rest in rests { wait = min(wait, now.duration(to: rest)) }
                let pause = max(wait, .milliseconds(1))
                let sleeper = Task { _ = try? await Task.sleep(for: pause) }
                self.sleeper = sleeper
                await sleeper.value
                if self.sleeper == sleeper { self.sleeper = nil }
            }
        }
    }

    /// The next list to read: one whose read failed once first, else the queue's order.
    private func nextList() -> UInt32? {
        if let retryFirst, queue.contains(retryFirst) { return retryFirst }
        return queue.first
    }

    /// Ends the loop's idle sleep at once (a click, a list shown).
    private func wakeLoop() {
        sleeper?.cancel()
    }

    private func readKeypad(_ reason: KeypadRead, _ generation: Int) async {
        let request = keypadRequest
        let read: [FavoritesList]
        let states: QuickKeyStates
        do {
            read = try await readStructure(generation, "GLT,FL") { try await $0.favoritesLists() }
            states = try await self.read(generation, "FQK") { try await $0.listKeyStates() }
        } catch {
            if case ReadFailure.gone = error { return }
            failed(error, generation)
            return
        }
        // A menu exit meanwhile asked for a full re-read (`keypadRead` is now `.all`): this read may
        // predate the menu's edits, so it is dropped and the loop reads the keypad again.
        guard isAlive(generation), keypadRequest == request else { return }
        let previous = favorites
        favorites = read
        listStates = states
        baselines[.lists] = states.existingKeys
        keypadRead = nil
        setReadError(nil)
        let present = Set(read.map(\.index))
        structure = structure.filter { present.contains($0.key) }
        freshness = freshness.filter { present.contains($0.key) }
        listErrors = listErrors.filter { present.contains($0.key) }
        failures = failures.filter { present.contains($0.key) }
        queue.removeAll { !present.contains($0) }
        switch reason {
        case .all:
            // "Since this open" starts again: no state, no pattern, every list re-checked.
            systemStates = [:]
            childStates = [:]
            baselines = [.lists: states.existingKeys]
            for index in present {
                epochs[index, default: 0] += 1
                if freshness[index] == .loading {
                    continue
                } else if structure[index] != nil {
                    freshness[index] = .checking
                } else {
                    freshness[index] = nil
                }
            }
            queue = ordered(present)
        case .changedKeys:
            let before = Dictionary(previous.map { ($0.index, $0.quickKey) }, uniquingKeysWith: { first, _ in first })
            for list in read {
                if let old = before[list.index] {
                    if old != list.quickKey { recheck(list.index) }
                } else if !queue.contains(list.index) {
                    queue.append(list.index)
                }
            }
        }
        publishLists()
        publishTrees()
        updateScanning()
        updateFullPass()
        if nextPoll == nil { nextPoll = .now + pollInterval }
    }

    private func readList(_ index: UInt32, _ generation: Int) async {
        queue.removeAll { $0 == index }
        if retryFirst == index { retryFirst = nil }
        guard let list = favorites.first(where: { $0.index == index }) else { return }
        let epoch = epochs[index, default: 0]
        readingList = index
        defer { if readingList == index { readingList = nil } }
        var rows: [QuickKeyListTree.SystemRow] = []
        /// The system being read, as read so far: what a refusal for the list's own structure keeps.
        var candidate: QuickKeyListTree.SystemRow?
        var listKeyStates: QuickKeyStates?
        var keyedStates: [QuickKeyPair: QuickKeyStates] = [:]
        func row(_ system: FavoritesSystem, _ children: [FavoritesChild]) -> QuickKeyListTree.SystemRow {
            QuickKeyListTree.SystemRow(
                index: system.index, name: system.name, type: system.type, key: system.quickKey,
                avoided: system.avoided, state: nil,
                children: children.map {
                    QuickKeyListTree.ChildRow(index: $0.index, name: $0.name, kind: $0.kind, key: $0.quickKey,
                                              avoided: $0.avoided, state: nil)
                })
        }
        // A settle re-read (another list asked this one to settle its claim): its fresh reply wins over other lists'
        // claims that aren't fresh, and drops the ones it contradicts once it succeeds.
        let settleRead = settling.remove(index) != nil
        var contradicted: [Contradicted] = []
        func check(_ request: String, _ items: [UInt32], parent: UInt32) throws {
            try checkOwnership(request, of: items, parent: parent, list: index, rows: rows, settleRead: settleRead,
                               contradicted: &contradicted)
        }
        do {
            let systems = try await readStructure(generation, "GLT,SYS", list: index) {
                try await $0.favoritesSystems(inList: index)
            }
            try check("GLT,SYS", systems.map(\.index), parent: index)
            for system in systems {
                var children = try await readStructure(generation, "GLT,DEPT", list: index) {
                    try await $0.favoritesDepartments(inSystem: system.index)
                }
                candidate = row(system, children)
                try check("GLT,DEPT", children.map(\.index), parent: system.index)
                if !system.isConventional {
                    let sites = try await readStructure(generation, "GLT,SITE", list: index) {
                        try await $0.favoritesSites(inSystem: system.index)
                    }
                    candidate = row(system, children + sites)
                    try check("GLT,SITE", sites.map(\.index), parent: system.index)
                    children += sites
                }
                rows.append(row(system, children))
                candidate = nil
            }
            // `SQK` and `DQK` are addressed by keys: a list (or system) without one has no states to read.
            if let listKey = list.quickKey {
                listKeyStates = try await read(generation, "SQK") { try await $0.systemKeyStates(listKey: listKey) }
                for systemKey in Self.uniqueKeys(rows) {
                    let pair = QuickKeyPair(list: listKey, system: systemKey)
                    keyedStates[pair] = try await read(generation, "DQK") {
                        try await $0.departmentKeyStates(listKey: listKey, systemKey: systemKey)
                    }
                }
            }
        } catch {
            if case ReadFailure.gone = error { return }
            var error = error
            if let conflict = error as? Conflict {
                CommandTrace.log("quickkeys: \(conflict.detail)")
                switch conflict.source {
                case .pass, .lastFailedRead:
                    // This list's own fresh claim: the reply is a stray, and the read fails as any other.
                    break
                case .ownStructure:
                    // The list's own structure may be stale (a department moved): read it again, once, checked
                    // against this read rather than that structure.
                    doubt(index, keeping: rows + [candidate].compactMap { $0 }, generation)
                    return
                case .otherList:
                    // Another list's claim. A fresh one may be the stray, so that list is checked again too and this
                    // read fails. One that may be stale (never settled yet this open: `checkOwnership` drops it after)
                    // is settled by reading that list again first, unless that list is failing to read (nothing would
                    // settle it): then this read fails.
                    let owner = conflict.ownerList
                    if conflict.fresh {
                        recheck(owner)
                    } else if self.failures[owner, default: 0] == 0, !settledOnce.contains(owner) {
                        lastFailedRows[index] = rows
                        settle(conflict, rereading: index, generation)
                        return
                    }
                }
                error = ReadFailure.failed(message: conflict.message, detail: conflict.detail)
            }
            // Not `.fresh`: read again in full after the rest, before any other list the first time (see the
            // type's comment), behind every other queued list after that. Only the scanner's own failures count:
            // not a missing client (nothing was sent), nor a read re-checked meanwhile (it is queued again anyway).
            var failures = self.failures[index, default: 0]
            switch error as? ReadFailure {
            case .unanswered(let name):
                if epochs[index, default: 0] == epoch { failures += 1 }
                if name.hasPrefix("GLT") { gltTimedOut.insert(index) }
                lastFailedRows[index] = rows
            case .failed:
                if epochs[index, default: 0] == epoch { failures += 1 }
                lastFailedRows[index] = rows
            case .gone, .noClient, nil:
                break
            }
            self.failures[index] = failures
            if failures <= 1 {
                if epochs[index, default: 0] == epoch, !queue.contains(index) { queue.insert(index, at: 0) }
                retryFirst = index
            } else {
                // Even over a re-check that put it first meanwhile (the ruling: the second failure goes last).
                queue.removeAll { $0 == index }
                queue.append(index)
                CommandTrace.log("quickkeys: list \(index) failed \(failures) times in a row, read after the others")
            }
            failed(error, generation, list: index)
            updateFullPass()
            return
        }
        // Re-checked meanwhile (a menu exit, a changed key): it is queued again, so this read is stale.
        guard isAlive(generation), epochs[index, default: 0] == epoch else {
            CommandTrace.log("quickkeys: list \(index) stale, dropped")
            return
        }
        CommandTrace.log("quickkeys: list \(index) read done (\(rows.count) systems)")
        structure[index] = QuickKeyListTree(systems: rows, freshness: .checking)
        freshness[index] = .fresh
        failures[index] = nil
        listErrors[index] = nil
        lastFailedRows[index] = nil
        gltTimedOut.remove(index)
        readThisOpen.insert(index)
        updateFullPass()
        // A settle re-read's fresh reply replaces the claims it contradicted in other lists' structures.
        for drop in contradicted { dropClaim(drop) }
        if let listKey = list.quickKey, let listKeyStates {
            systemStates[listKey] = listKeyStates
            baselines[.systems(listKey: listKey)] = listKeyStates.existingKeys
        }
        for (pair, states) in keyedStates {
            childStates[pair] = states
            baselines[.children(pair)] = states.existingKeys
        }
        publishTree(index)
        publishLists()
        updateScanning()
        saveCache()
    }

    /// A `GLT` read, retried once in place after a timeout, with no rest between (see the type's comment): a late
    /// reply to the first try that answers the retry is the same scope's answer, and one that lands on another
    /// parent's read is refused by `checkOwnership`. A second timeout fails the step as any read.
    /// A timeout is recorded against `list` (`gltTimedOut`) even when the retry is answered: the first try's reply may
    /// still come, after this read is done.
    private func readStructure<Value: Sendable>(_ generation: Int, _ name: String, list: UInt32? = nil,
                                                _ op: (ScannerClient) async throws -> Value) async throws -> Value {
        do {
            return try await read(generation, name, op)
        } catch ReadFailure.unanswered {
            CommandTrace.log("quickkeys: \(name) unanswered, read again in place")
            if let list {
                gltTimedOut.insert(list)
                updateFullPass()
            }
            return try await read(generation, name, op)
        }
    }

    /// A claim of another list that a settle re-read's fresh reply contradicted: `item` (a system if `isSystem`, else a
    /// department or site) in `list`'s structure.
    private struct Contradicted {
        let list: UInt32
        let item: UInt32
        let isSystem: Bool
    }

    /// Removes a contradicted claim from that list's known structure (it is read again by itself before it is fresh).
    private func dropClaim(_ drop: Contradicted) {
        guard var tree = structure[drop.list] else { return }
        if drop.isSystem {
            tree.systems.removeAll { $0.index == drop.item }
        } else {
            for at in tree.systems.indices { tree.systems[at].children.removeAll { $0.index == drop.item } }
        }
        structure[drop.list] = tree
        CommandTrace.log("quickkeys: list \(drop.list)'s claim on item \(drop.item) dropped by a settle re-read")
        publishTree(drop.list)
    }

    /// Throws a `Conflict` if any of `items`, read for `parent` (list `list`'s `GLT,SYS`, or a system's
    /// `GLT,DEPT`/`GLT,SITE`), is held by another parent (see the type's comment). For a department or site, within
    /// the list the first of these that knows the item decides: an earlier system of the read under way (`rows`), the
    /// list's last failed read this open (`lastFailedRows`), the list's known structure (unless doubted). Then every
    /// other list's known structure, except, in a settle re-read, a claim that isn't fresh (recorded in
    /// `contradicted`, to be dropped if the read succeeds).
    private func checkOwnership(_ request: String, of items: [UInt32], parent: UInt32, list: UInt32,
                                rows: [QuickKeyListTree.SystemRow], settleRead: Bool,
                                contradicted: inout [Contradicted]) throws {
        func holder(of item: UInt32, in systems: [QuickKeyListTree.SystemRow]) -> UInt32? {
            systems.first { $0.children.contains { $0.index == item } }?.index
        }
        func conflict(_ item: UInt32, _ owner: UInt32, _ ownerList: UInt32, _ source: Conflict.Source,
                      fresh: Bool) -> Conflict {
            Conflict(request: request, parent: parent, item: item, owner: owner, ownerList: ownerList, source: source,
                     fresh: fresh)
        }
        guard structureGuardsOn else { return }
        let isSystems = request == "GLT,SYS"
        for item in items {
            if !isSystems {
                if let owner = holder(of: item, in: rows) {
                    if owner != parent { throw conflict(item, owner, list, .pass, fresh: true) }
                } else if let owner = holder(of: item, in: lastFailedRows[list] ?? []) {
                    if owner != parent { throw conflict(item, owner, list, .lastFailedRead, fresh: true) }
                } else if !doubtedStructure.contains(list),
                          let owner = holder(of: item, in: structure[list]?.systems ?? []), owner != parent {
                    throw conflict(item, owner, list, .ownStructure, fresh: false)
                }
            }
            for (other, tree) in structure where other != list {
                let owner = isSystems ? (tree.systems.contains { $0.index == item } ? other : nil)
                    : holder(of: item, in: tree.systems)
                guard let owner, owner != parent else { continue }
                let fresh = freshness[other] == .fresh
                // In a settle re-read, a claim that isn't fresh gives way to this fresh reply, and is dropped if the
                // read succeeds (QA I1; crossing and rotated cached claims settle this way).
                if !fresh, settleRead {
                    contradicted.append(Contradicted(list: other, item: item, isSystem: isSystems))
                    continue
                }
                throw conflict(item, owner, other, .otherList, fresh: fresh)
            }
        }
    }

    /// A conflict with a claim that may be stale: the claiming list is re-checked first and `index` read again
    /// right after it, after the rest (the reply may still be a stray whose own reply is on its way), with no
    /// failure counted.
    private func settle(_ conflict: Conflict, rereading index: UInt32, _ generation: Int) {
        guard isAlive(generation) else { return }
        settledOnce.insert(conflict.ownerList)
        settling.insert(conflict.ownerList)
        recheck(conflict.ownerList)
        queue.removeAll { $0 == index }
        queue.insert(index, at: min(1, queue.count))
        restUntil = .now + pollInterval
    }

    /// A reply that contradicts the list's own structure (the cache, or a read since re-checked): the list is read
    /// again first, after the rest, with no failure counted, and from then on this open checked against `kept` (this
    /// read's systems and the one refused) instead of that structure, so a second read that agrees is taken.
    private func doubt(_ index: UInt32, keeping kept: [QuickKeyListTree.SystemRow], _ generation: Int) {
        guard isAlive(generation) else { return }
        doubtedStructure.insert(index)
        lastFailedRows[index] = kept
        queue.removeAll { $0 == index }
        queue.insert(index, at: 0)
        restUntil = .now + pollInterval
    }

    /// "Since this open" starts again for the full pass and the claims a pass keeps (a run starts, the states drop).
    private func resetPassState() {
        readThisOpen = []
        gltTimedOut = []
        lastFailedRows = [:]
        doubtedStructure = []
        settledOnce = []
        settling = []
        updateFullPass()
    }

    /// `isCheckingOtherLists` from what this open has read: some list on the keypad hasn't been read yet (since this
    /// open or the last menu exit) and either isn't failing (two failures in a row or more) or has had a `GLT` read go
    /// unanswered since its last good read, whose reply may still come (QA I2).
    private func updateFullPass() {
        let waiting = structureGuardsOn && isOpen && control != nil && favorites.contains {
            gltTimedOut.contains($0.index) || (!readThisOpen.contains($0.index) && failures[$0.index, default: 0] < 2)
        }
        if isCheckingOtherLists != waiting { isCheckingOtherLists = waiting }
    }

    private func poll(_ generation: Int) async {
        do {
            switch try await scopeRead(.lists, generation, "FQK", { try await $0.listKeyStates() }) {
            case .changed:
                if keypadRead == nil { keypadRead = .changedKeys }
                return
            case .value(let states):
                listStates = states
                publishLists()
            }
            guard let shown = shownList, freshness[shown] == .fresh,
                  let listKey = favorites.first(where: { $0.index == shown })?.quickKey else {
                setReadError(nil)
                return
            }
            switch try await scopeRead(.systems(listKey: listKey), generation, "SQK", {
                try await $0.systemKeyStates(listKey: listKey)
            }) {
            case .changed:
                recheck(shown)
                return
            case .value(let states):
                systemStates[listKey] = states
            }
            for systemKey in Self.uniqueKeys(structure[shown]?.systems ?? []) {
                let pair = QuickKeyPair(list: listKey, system: systemKey)
                switch try await scopeRead(.children(pair), generation, "DQK", {
                    try await $0.departmentKeyStates(listKey: listKey, systemKey: systemKey)
                }) {
                case .changed:
                    recheck(shown)
                    return
                case .value(let states):
                    childStates[pair] = states
                }
            }
            setReadError(nil)
            publishTree(shown)
        } catch {
            if case ReadFailure.gone = error { return }
            failed(error, generation)
        }
    }

    /// One read of a scope's states (a poll, or a change's confirming re-read). A reply is taken only if
    /// it is 100 values with the pattern of existing keys of the scope's first read since its tree loaded;
    /// one that isn't (a late reply to another scope's read, or a set's late `OK` or `NG`, which answer by
    /// command name) is dropped and the scope read once more. `.changed` when the pattern still differs.
    private func scopeRead(_ scope: Scope, _ generation: Int, _ name: String,
                           _ op: (ScannerClient) async throws -> QuickKeyStates) async throws -> PollResult {
        for attempt in 1...2 {
            let states: QuickKeyStates
            do {
                states = try await read(generation, name, op)
            } catch ReadFailure.failed where attempt == 1 {
                continue
            }
            guard let baseline = baselines[scope] else {
                baselines[scope] = states.existingKeys
                return .value(states)
            }
            if states.existingKeys == baseline { return .value(states) }
        }
        return .changed
    }

    /// One read through the attached client, not retried here (only `readStructure` retries, a `GLT` read once; see
    /// the type's comment): a timeout throws `unanswered` and starts the quiet time, even for a stopped run.
    private func read<Value: Sendable>(_ generation: Int, _ name: String,
                                       _ op: (ScannerClient) async throws -> Value) async throws -> Value {
        guard isAlive(generation), let control else { throw ReadFailure.gone }
        guard let client = await control() else {
            guard isAlive(generation) else { throw ReadFailure.gone }
            throw ReadFailure.noClient
        }
        guard isAlive(generation) else { throw ReadFailure.gone }
        do {
            let value = try await op(client)
            guard isAlive(generation) else { throw ReadFailure.gone }
            answered()
            return value
        } catch let failure as ReadFailure {
            throw failure
        } catch {
            if case .timeout = error as? ScannerClientError {
                // Its reply may still come, and would answer the next read of its name.
                quietUntil = .now + pollInterval
                guard isAlive(generation) else { throw ReadFailure.gone }
                timeoutsInARow += 1
                if timeoutsInARow >= 2 { isScannerAnswering = false }
                throw ReadFailure.unanswered(name)
            }
            guard isAlive(generation) else { throw ReadFailure.gone }
            if error as? ScannerClientError == .notConnected { throw ReadFailure.noClient }
            // It answered, just not usefully.
            answered()
            let message = if case .rejected = error as? ScannerClientError {
                "\(Self.refusedPrefix) \(name)."
            } else {
                "The scanner's reply to \(name) couldn't be read."
            }
            throw ReadFailure.failed(message: message, detail: "Couldn't read \(name) from the scanner: \(error)")
        }
    }

    private func answered() {
        timeoutsInARow = 0
        isScannerAnswering = true
    }

    /// A failed step of the current run: report it and rest the background reads for one poll interval.
    /// A stopped run's failure touches nothing. A list read's error goes on that list's tree (`list`), any
    /// other on `lastError`.
    private func failed(_ error: any Error, _ generation: Int, list: UInt32? = nil) {
        guard isAlive(generation) else { return }
        restUntil = .now + pollInterval
        switch error as? ReadFailure {
        case .unanswered(let name): CommandTrace.log("quickkeys: \(name) failed: unanswered")
        case .failed(_, let detail): CommandTrace.log("quickkeys: step failed: \(detail)")
        case .gone, .noClient: CommandTrace.log("quickkeys: step failed: \(error)")
        case nil: CommandTrace.log("quickkeys: step failed: \(type(of: error))")
        }
        let message: String?
        switch error as? ReadFailure {
        case .unanswered(let name): message = "The scanner didn't answer \(name)."
        case .failed(let failure, _): message = failure
        case .gone, .noClient, nil: message = nil
        }
        guard let message else { return }
        if let list {
            listErrors[list] = message
            publishTree(list)
        } else {
            setReadError(message)
        }
    }

    private func setReadError(_ message: String?) {
        readError = message
        publishError()
    }

    private func setChangeError(_ message: String?) {
        changeError = message
        publishError()
    }

    /// An unconfirmed change is shown ahead of a read error, so "didn't confirm" is never hidden by its own
    /// re-read failing (`isScannerAnswering` still says the scanner went quiet).
    private func publishError() {
        let shown = changeError ?? readError
        if lastError != shown { lastError = shown }
    }

    // MARK: Re-checks

    /// The list's structure is read again, first, before anything in it shows a state.
    private func recheck(_ index: UInt32) {
        epochs[index, default: 0] += 1
        freshness[index] = structure[index] != nil ? .checking : .loading
        queue.removeAll { $0 == index }
        queue.insert(index, at: 0)
        publishTree(index)
    }

    /// After a menu: every tree `.checking` at once, then the keypad and every list read again.
    private func recheckAll() {
        // Every list, not only those with a tree: a first read under way is stale too.
        for index in Set(freshness.keys).union(favorites.map(\.index)) { epochs[index, default: 0] += 1 }
        for index in freshness.keys {
            freshness[index] = structure[index] != nil ? .checking : .loading
        }
        keypadRead = .all
        keypadRequest += 1
        // The menus may have edited Favorites: tree switches wait for every list again.
        readThisOpen = []
        updateFullPass()
        publishTrees()
    }

    /// The shown list if unread, the scanning list, the keyed lists by key, then the unkeyed ones; a list
    /// that has failed more than once in a row (a menu exit re-reads every list) goes last unless shown.
    private func ordered(_ indexes: Set<UInt32>) -> [UInt32] {
        var result: [UInt32] = []
        if let shown = shownList, indexes.contains(shown) { result.append(shown) }
        if let scanned = lastInfo?.monitorList?.index, indexes.contains(scanned), !result.contains(scanned) {
            result.append(scanned)
        }
        let rest = favorites.filter { indexes.contains($0.index) && !result.contains($0.index) }
        let keyed = rest.enumerated().filter { $0.element.quickKey != nil }
            .sorted { ($0.element.quickKey!, $0.offset) < ($1.element.quickKey!, $1.offset) }
            .map(\.element.index)
        let order = result + keyed + rest.filter { $0.quickKey == nil }.map(\.index)
        let failing: (UInt32) -> Bool = { [failures, shownList] in $0 != shownList && failures[$0, default: 0] > 1 }
        return order.filter { !failing($0) } + order.filter(failing)
    }

    private static func uniqueKeys(_ systems: [QuickKeyListTree.SystemRow]) -> [Int] {
        var seen = Set<Int>()
        return systems.compactMap(\.key).filter { seen.insert($0).inserted }
    }

    // MARK: Publishing

    /// Every state is dropped and every tree goes back to its structure, `.checking`.
    private func dropStates() {
        listStates = nil
        systemStates = [:]
        childStates = [:]
        baselines = [:]
        listErrors = [:]
        failures = [:]
        resetPassState()
        freshness = freshness.filter { structure[$0.key] != nil }.mapValues { _ in .checking }
        publishLists()
        publishTrees()
    }

    private func publishLists() {
        let items = favorites.map { list in
            QuickKeyListItem(
                index: list.index, name: list.name, key: list.quickKey, monitored: list.monitored,
                state: list.quickKey.flatMap { key in listStates.map { $0[key] } },
                systemCount: structure[list.index]?.systems.count)
        }
        if lists != items { lists = items }
    }

    private func publishTrees() {
        for index in Set(trees.keys).union(freshness.keys) { publishTree(index) }
    }

    /// `trees[index]` from the structure, with states only when `.fresh`.
    private func publishTree(_ index: UInt32) {
        guard let state = freshness[index] else {
            if trees[index] != nil { trees[index] = nil }
            return
        }
        var systems = structure[index]?.systems ?? []
        if state == .fresh, let listKey = favorites.first(where: { $0.index == index })?.quickKey {
            for s in systems.indices {
                guard let systemKey = systems[s].key else { continue }
                systems[s].state = systemStates[listKey]?[systemKey]
                let children = childStates[QuickKeyPair(list: listKey, system: systemKey)]
                for c in systems[s].children.indices {
                    systems[s].children[c].state = systems[s].children[c].key.flatMap { key in children.map { $0[key] } }
                }
            }
        }
        let tree = QuickKeyListTree(systems: systems, freshness: state,
                                    readError: state == .fresh ? nil : listErrors[index])
        if trees[index] != tree { trees[index] = tree }
    }

    private func updateScanning() {
        var now = QuickKeyScanning()
        if let info = lastInfo, let list = info.monitorList?.index, favorites.contains(where: { $0.index == list }) {
            now.list = list
            if let index = info.system?.index, let system = structure[list]?.systems.first(where: { $0.index == index }) {
                now.system = index
                func child(_ item: NamedItem?, _ kind: FavoritesChild.Kind) -> UInt32? {
                    guard let index = item?.index,
                          system.children.contains(where: { $0.kind == kind && $0.index == index }) else { return nil }
                    return index
                }
                now.child = child(info.department, .department) ?? child(info.site, .site)
            }
        }
        if scanning != now { scanning = now }
    }

    private func saveCache() {
        guard let cacheURL else { return }
        try? QuickKeysCache.save(structure, to: cacheURL)
    }
}
