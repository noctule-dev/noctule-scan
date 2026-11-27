// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation

/// A stage of an `MSM,1` reboot.
public enum MockRebootPhase: Sendable, Equatable {
    /// `MSM,OK` went out; the scanner is now silent.
    case began
    /// The reboot finished; control answers again.
    case finished
}

/// The SDS200's UDP control protocol (port 50536 semantics) on a loopback port, answering from a
/// `MockScenario` at the `MockClock`'s current moment. Replies end in `\r`, as on hardware.
///
/// - `MDL` → `MDL,SDS200`; `VER` → `VER,Version 1.26.01` (from the scenario).
/// - `VOL`/`SQL` get and set, stateful, in SDS200 ranges (0-29, 0-19): `OK`, or `NG` out of range
///   (an assumed form: hardware rejection is untried).
/// - `GSI` → `GSI,<XML>,\r<?xml ...` for the current moment; `STS` → the 17-line display.
/// - `KEY,<code>,P` → `KEY,OK` (`NG` for an unknown code or mode); `M` enters the menu (`MockMenu`),
///   where `GSI`/`PSI`/`STS` show the menu screen. `MSI` → the current menu screen as XML (a bare
///   `TypeError` outside a menu); `MSV,,<value>` → `MSV,OK` or `MSV,NG`.
/// - `PSI,<ms>` → `PSI,OK`, then a `PSI,<XML>,` push every `<ms>` to the sender's address
///   (per client address); `PSI,0` → `PSI,OK` and stops that address's pushes.
/// - `MSM,1` → `MSM,OK`, then silence for `rebootDuration` (hardware: about 10.5-12.7 s on fw
///   1.26.01), dropping every PSI subscription; the reboot handler hears `.began` and `.finished`.
/// - `GLT`, `FQK`, `SQK`, `DQK` → the fictional Favorites tree and its quick keys (`MockFavorites`, whose
///   assumptions are listed there); a `GLT` reply comes in pages of at most `gltPageSize` elements, one
///   datagram each; a set to `FQK` or `SQK` answers after `quickKeySetDelay`
///   (hardware: about 0.8 s), faults and `replyDelays` applying as to any command.
/// - Anything else → `ERR` (on the SDS200; a personality's `silentCommands` get no reply).
///
/// The command handling is a peer-neutral control core that a byte-stream front end shares (the
/// mock SDS150); what differs between models is a `MockPersonality` (`.sds200` here, reporting the
/// scenario's model and firmware).
///
/// Faults: `setDropFaults` drops the next datagrams of one command (the request is logged and
/// ignored, or carried out with its reply withheld), or answers them `<NAME>,NG` without carrying
/// them out (`reject`). `replyDelays[<command>]` holds that command's
/// reply back (real time, like the RTSP delays); the command takes effect at once.
///
/// Every datagram is logged in `receivedCommands`, even while silent (rebooting, or
/// `setAnswering(false)`). Binds 127.0.0.1 only: the real protocol has no authentication.
public actor MockControlServer {
    private let core: ControlCore
    private let endpoint: UDPControlEndpoint

    /// `personality` supplies everything but `MDL` and `VER`, which report the scenario's `model`
    /// and `firmware` (an SDS200's unless the scenario says otherwise).
    public init(scenario: MockScenario, clock: MockClock, rebootDuration: Duration = .seconds(10),
                replyDelays: [String: Duration] = [:], personality: MockPersonality = .sds200,
                quickKeySetDelay: Duration = .milliseconds(800), gltPageSize: Int = MockFavorites.defaultGLTPageSize) {
        core = ControlCore(scenario: scenario, clock: clock, rebootDuration: rebootDuration, replyDelays: replyDelays,
                           personality: personality.reporting(scenario), quickKeySetDelay: quickKeySetDelay,
                           gltPageSize: gltPageSize)
        endpoint = UDPControlEndpoint(core: core)
    }

    /// Binds 127.0.0.1:`port` (0 picks an ephemeral port) and returns the bound port.
    public func start(port: UInt16 = 0) async throws -> UInt16 { try endpoint.start(port: port) }

    /// Stops answering, cancels every push, and closes the socket. Datagrams already received
    /// are logged in `receivedCommands` (and answered, if answering) before the socket closes.
    public func stop() async { endpoint.stop() }

    /// Every command received, without the trailing `\r`, oldest first.
    public var receivedCommands: [String] { core.sync { $0.log } }
    public var volume: Int { core.sync { $0.volume } }
    public var squelch: Int { core.sync { $0.squelch } }
    /// PSI pushes sent, across all subscribers.
    public var pushesSent: Int { core.sync { $0.pushesSent } }
    /// Client addresses with an active `PSI` subscription.
    public var activeSubscribers: Int { core.sync { $0.subscribers.count } }
    /// False while `setAnswering(false)` holds (e.g. a hung network stack).
    public var isAnswering: Bool { core.sync { $0.answering } }
    public var isRebooting: Bool { core.sync { $0.rebooting } }
    /// True while a menu screen is showing.
    public var isInMenu: Bool { core.sync { $0.menu.isActive } }
    /// Titles of the screens from the top menu down; empty outside a menu.
    public var menuPath: [String] { core.sync { $0.menu.path } }
    /// Every state change the menu carried out, oldest first.
    public var menuActions: [String] { core.sync { $0.menu.actions } }

    /// The Favorites tree and its quick-key states as they are now.
    public var favorites: MockFavorites { core.sync { $0.favorites } }

    /// Replaces the Favorites tree (tests move keys, rename and remove rows).
    public func setFavorites(_ favorites: MockFavorites) { core.sync { $0.favorites = favorites } }

    /// Arms the drop faults: the next `count` datagrams named `request` are logged and ignored, and
    /// the next `count` named `reply` are carried out but get no reply. Each clears itself.
    public func setDropFaults(reply: String?, request: String?, count: Int, reject: String? = nil) {
        core.sync {
            $0.dropReply = reply?.uppercased(); $0.dropReplyRemaining = count
            $0.dropRequest = request?.uppercased(); $0.dropRequestRemaining = count
            $0.rejectName = reject?.uppercased(); $0.rejectRemaining = count
        }
    }

    /// While false, every datagram is logged and nothing is sent (replies and pushes).
    public func setAnswering(_ answering: Bool) { core.sync { $0.answering = answering } }

    /// Pushes stop `seconds` after each subscription starts (the subscription stays, and PSI is
    /// still acknowledged); nil turns it off.
    public func setStallPSIAfter(_ seconds: Double?) { core.sync { $0.stallAfter = seconds } }

    /// Awaited when an `MSM,1` reboot begins (after `MSM,OK`, while silent) and when it finishes;
    /// control answers again only after the `.finished` call returns, so a composed mock can reset
    /// its audio server first.
    public func setRebootHandler(_ handler: (@Sendable (MockRebootPhase) async -> Void)?) {
        core.sync { $0.rebootHandler = handler }
    }

    /// Called (on the server's queue) with every command received, silent or not.
    public func setCommandObserver(_ observer: (@Sendable (String) -> Void)?) {
        core.sync { $0.commandObserver = observer }
    }

    /// Ends every PSI subscription and any reboot in progress, leaves the menu (restoring its
    /// values), and answers again, as after a power cycle. Settings (VOL, SQL) persist.
    public func powerCycle() { core.powerCycle() }

    /// Ends every PSI subscription (a reboot or power cycle forgets them).
    public func dropSubscriptions() { core.sync { $0.cancelSubscriptions() } }
}

/// Who a command came from, and so where its reply and that peer's `PSI` pushes go.
enum ControlPeer: Hashable, Sendable {
    /// A UDP client, by address (`UDPControlEndpoint`'s key).
    case udp(key: String)
    /// The one byte stream (a serial line).
    case stream
}

/// The control protocol's state and command handling, confined to `queue`. Commands arrive through
/// `receive(_:from:)`; replies and pushes leave through `sendToPeer`, which the front end sets.
/// What differs by model is `personality`.
///
/// **Assumptions, not hardware:** an out-of-range `VOL`/`SQL` set answers `<NAME>,NG` and changes
/// nothing, on every model. Each model's other assumptions are listed on `MockPersonality` (the
/// push lifetime and what restarts it among them), the menu's on `MockMenu`.
final class ControlCore: @unchecked Sendable {
    struct Subscriber {
        var peer: ControlPeer
        var timer: DispatchSourceTimer
        var started: ContinuousClock.Instant
        /// Scenario time (the mock's clock) the push lifetime counts from: the `PSI`, or the latest
        /// command in `personality.pushLifetimeRestarts` from this peer.
        var lifetimeFrom: Double
    }

    let scenario: MockScenario
    let clock: MockClock
    let rebootDuration: Duration
    let replyDelays: [String: Duration]
    let personality: MockPersonality
    /// How long an `FQK` or `SQK` set holds back its reply (zero under `--no-delays` and in most tests).
    let quickKeySetDelay: Duration
    /// The most elements one page of a `GLT` reply holds.
    let gltPageSize: Int
    /// Every command, reply, push and timer runs here; front ends read on it too.
    let queue = DispatchQueue(label: "NoctuleMockScanner.MockControlServer")
    /// Sends a reply or push to a peer; called on `queue`. Set by the front end before it starts.
    var sendToPeer: @Sendable (Data, ControlPeer) -> Void = { _, _ in }

    // Queue-confined state.
    var log: [String] = []
    var volume = 2
    var squelch = 1
    /// `Property F`: On after a `KEY,F,P` until the next `KEY` of any code is handled (assumed).
    var functionOn = false
    var pushesSent = 0
    var subscribers: [ControlPeer: Subscriber] = [:]
    var answering = true
    var rebooting = false
    var stallAfter: Double?
    /// `MockFaults.pushBeforeStop`: one push to a subscribed peer just before its next `PSI,0`.
    var pushBeforeStop = false
    var rebootHandler: (@Sendable (MockRebootPhase) async -> Void)?
    var commandObserver: (@Sendable (String) -> Void)?
    /// Called once, at the next subscribing `PSI` (any but `PSI,0`), then cleared: the serial
    /// mock's `unplug-after-psi` starts its clock here.
    var nextSubscription: (@Sendable () -> Void)?
    var menu = MockMenu()
    /// The BCD436HP's holds, `"<LEVEL>:<index>"` (`SYS`, `DEPT`, `TGID`, `CFREQ`).
    var holds: Set<String> = []
    /// A single `KEY,A|B,P` press waiting out the 2 s pause before it holds (BCD436HP).
    var pendingHold: (key: String, item: String, pressedAt: Double)?
    /// How long a single System or Department press waits before it holds (hardware: 2 s).
    static let holdPause = 2.0
    /// Two presses this close count as a double-press. Assumed: 0.5 s (hardware: at least 95 ms).
    static let doublePressWindow = 0.5
    var favorites = MockFavorites.default
    var dropReply: String?
    var dropReplyRemaining = 0
    var dropRequest: String?
    var dropRequestRemaining = 0
    var rejectName: String?
    var rejectRemaining = 0
    // Set while `receive` runs, for `reply`.
    private var suppressReply = false
    private var replyDelay: Duration?
    private var rebootGeneration = 0
    /// Bumped by `forgetPeers()`: a reply held back by a delay goes out only if it hasn't changed.
    private var peerGeneration = 0

    init(scenario: MockScenario, clock: MockClock, rebootDuration: Duration, replyDelays: [String: Duration] = [:],
         personality: MockPersonality = .sds200, quickKeySetDelay: Duration = .zero,
         gltPageSize: Int = MockFavorites.defaultGLTPageSize) {
        self.quickKeySetDelay = quickKeySetDelay
        self.gltPageSize = gltPageSize
        self.scenario = scenario
        self.clock = clock
        self.rebootDuration = rebootDuration
        self.replyDelays = replyDelays
        self.personality = personality
    }

    func sync<T>(_ body: (ControlCore) -> T) -> T { queue.sync { body(self) } }

    /// On `queue`: cancels every push and any reboot in progress, as when the front end stops.
    func halt() {
        forgetPeers()
        rebootGeneration += 1
        rebooting = false
    }

    /// On `queue`: ends every subscription and drops every reply still held back by a reply delay,
    /// as when the link to every peer goes away (a serial unplug).
    func forgetPeers() {
        cancelSubscriptions()
        peerGeneration += 1
    }

    func powerCycle() {
        queue.sync {
            cancelSubscriptions()
            rebootGeneration += 1
            rebooting = false
            answering = true
            menu = MockMenu()
            holds = []
            pendingHold = nil
        }
    }

    func cancelSubscriptions() {
        for subscriber in subscribers.values { subscriber.timer.cancel() }
        subscribers.removeAll()
    }

    // MARK: Receiving

    /// Handles one command (without its terminator) from `peer`. Call on `queue`.
    func receive(_ command: String, from peer: ControlPeer) {
        log.append(command)
        commandObserver?(command)
        if let subscribed = nextSubscription, command.uppercased().hasPrefix("PSI,"), command.uppercased() != "PSI,0" {
            nextSubscription = nil
            subscribed()
        }
        guard answering, !rebooting else { return }
        let parts = command.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let name = parts[0].uppercased()
        let args = Array(parts.dropFirst())
        if dropRequestRemaining > 0, dropRequest == name {
            dropRequestRemaining -= 1
            return
        }
        if rejectRemaining > 0, rejectName == name {
            rejectRemaining -= 1
            reply("\(name),NG", to: peer)
            return
        }
        if dropReplyRemaining > 0, dropReply == name {
            dropReplyRemaining -= 1
            suppressReply = true
        }
        replyDelay = replyDelays[name]
        defer {
            suppressReply = false
            replyDelay = nil
        }
        if personality.pushLifetimeRestarts.contains(name), let subscriber = subscribers[peer],
           personality.keepAliveRevivesStoppedPushes || !lifetimeIsOver(subscriber) {
            subscribers[peer]?.lifetimeFrom = clock.now
        }
        switch (name, args.count) {
        case ("MDL", 0):
            reply("MDL,\(personality.reportedModel)", to: peer)
        case ("VER", 0):
            reply("VER,\(personality.firmware)", to: peer)
        case ("VOL", 0):
            reply("VOL,\(volume)", to: peer)
        case ("VOL", 1):
            if let level = Int(args[0]), personality.clampsLevels || personality.volumeRange.contains(level) {
                volume = min(max(level, personality.volumeRange.lowerBound), personality.volumeRange.upperBound)
                reply("VOL,OK", to: peer)
            } else {
                reply("VOL,NG", to: peer)
            }
        case ("SQL", 0):
            reply("SQL,\(squelch)", to: peer)
        case ("SQL", 1):
            if let level = Int(args[0]), personality.clampsLevels || personality.squelchRange.contains(level) {
                squelch = min(max(level, personality.squelchRange.lowerBound), personality.squelchRange.upperBound)
                reply("SQL,OK", to: peer)
            } else {
                reply("SQL,NG", to: peer)
            }
        case ("GSI", 0):
            reply(xml("GSI", scannerInfoXML()), to: peer)
        case ("MSI", 0):
            reply(xml("MSI", menu.msiXML(footer: personality.xmlFooter, lineBreak: personality.xmlLineBreak)), to: peer)
        case ("MSV", 2...) where args[0].isEmpty:
            reply(menu.setValue(args.dropFirst().joined(separator: ",")) ? "MSV,OK" : "MSV,NG", to: peer)
        case ("STS", 0) where menu.isActive:
            let narrow = personality.displayForm == .bcd436hp
            reply(menu.statusFields(columns: narrow ? 24 : 30, glyphBytes: personality.displayGlyphBytes) + Data("\r".utf8),
                  to: peer)
        case ("STS", 0):
            let now = clock.now
            if personality.displayForm == .bcd436hp {
                reply(MockScreens.bcdDisplay(scenario.moment(at: now), scenario: scenario, seconds: now,
                                             glyphBytes: personality.displayGlyphBytes) + Data("\r".utf8), to: peer)
                return
            }
            let screen = MockScreens.display(scenario.moment(at: now), scenario: scenario, volume: volume,
                                             squelch: squelch, seconds: now, glyphBytes: personality.displayGlyphBytes)
            reply(screen + Data("\r".utf8), to: peer)
        case ("MNU", _) where personality.bcdCommands:
            if args.count == 2, args[0] == "TOP", args[1].isEmpty {
                menu.enterTop()
                reply("MNU,OK", to: peer)
            } else {
                reply("MNU,NG", to: peer)
            }
        case ("MSB", 2) where personality.bcdCommands && args[0].isEmpty:
            let done: Bool
            switch args[1] {
            case "": done = menu.back()
            case "RETURN_PREVOUS_MODE": done = menu.leave()
            default: done = false
            }
            reply(done ? "MSB,OK" : "MSB,NG", to: peer)
        case ("MSB", _) where personality.bcdCommands:
            reply("MSB,NG", to: peer)
        case ("HLD", 3) where personality.bcdCommands:
            settleHolds()
            let match = MockScreens.holdLevels.first { $0.level == args[0] }
            guard let match, !args[1].isEmpty,
                  MockScreens.shows(plainScannerInfoXML(), tag: match.tag, index: args[1],
                                    lineBreak: personality.xmlLineBreak) else {
                reply("HLD,NG", to: peer)
                return
            }
            toggleHold("\(match.level):\(args[1])")
            reply("HLD,OK", to: peer)
        case ("KEY", 2) where personality.bcdCommands && !menu.isActive && ["A", "B", "C"].contains(args[0].uppercased())
            && args[1].uppercased() == "P":
            pressHoldKey(args[0].uppercased())
            reply("KEY,OK", to: peer)
        case ("KEY", 2):
            let known = Set(["M", "F", "L", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "E",
                             ">", "<", "^", "V", "Q", "Y", "A", "B", "C", "Z", "T", "R"])
            guard known.contains(args[0].uppercased()), !personality.missingKeys.contains(args[0].uppercased()),
                  args[1].uppercased() == "P" else {
                reply("KEY,NG", to: peer)
                return
            }
            _ = menu.key(args[0])
            functionOn = args[0].uppercased() == "F"
            reply("KEY,OK", to: peer)
        case ("PSI", 1):
            guard let ms = Int(args[0]), ms >= 0 else {
                reply("PSI,NG", to: peer)
                return
            }
            if ms == 0, pushBeforeStop, subscribers[peer] != nil {
                pushBeforeStop = false
                push(to: peer)
            }
            reply("PSI,OK", to: peer)
            subscribe(peer, intervalMS: ms)
        case ("MSM", 1) where args[0] == "1":
            guard personality.restartReboots else {
                reply("MSM,NG", to: peer)
                return
            }
            reply("MSM,OK", to: peer)
            beginReboot()
        case ("GCS", 0):
            guard let line = personality.chargeStatusReply else {
                reply("ERR", to: peer)
                return
            }
            reply(line, to: peer, terminator: "\n")
        case ("GLT", _), ("FQK", _), ("SQK", _), ("DQK", _):
            guard let answer = favorites.reply(to: name, args: args, lineBreak: personality.xmlLineBreak,
                                               pageSize: gltPageSize) else {
                reply("ERR", to: peer)
                return
            }
            if answer.delayed, quickKeySetDelay > .zero { replyDelay = max(replyDelay ?? .zero, quickKeySetDelay) }
            // A `GLT` reply's pages go out back to back, each on its own (a datagram, or a write).
            for text in answer.replies { reply(text, to: peer) }
        case _ where personality.silentCommands.contains(name):
            break  // Taken with no reply at all (`KAL` on the SDS150).
        default:
            reply("ERR", to: peer)
        }
    }

    /// `NAME,<XML>,` and the document, in the personality's line form.
    private func xml(_ name: String, _ document: String) -> String { "\(name),<XML>,\r" + document }

    private func scannerInfoXML() -> String {
        if menu.isActive { return menu.scannerInfoXML(lineBreak: personality.xmlLineBreak) }
        settleHolds()
        return MockScreens.applyHolds(plainScannerInfoXML(), holds: holds, lineBreak: personality.xmlLineBreak)
    }

    /// The scan screen's `ScannerInfo` with nothing held.
    private func plainScannerInfoXML() -> String {
        let now = clock.now
        return MockScreens.scannerInfoXML(scenario.moment(at: now), scenario: scenario, volume: volume, squelch: squelch,
                                          lineBreak: personality.xmlLineBreak,
                                          idleForm: personality.idleForm, seconds: now,
                                          decimalRssi: personality.displayForm == .bcd436hp,
                                          functionOn: functionOn)
    }

    // MARK: Holds (BCD436HP)

    func toggleHold(_ item: String) {
        if !holds.insert(item).inserted { holds.remove(item) }
    }

    /// Carries out a single System or Department press whose 2 s pause has passed on the mock's clock.
    func settleHolds() {
        guard let pending = pendingHold, clock.now - pending.pressedAt >= Self.holdPause else { return }
        pendingHold = nil
        toggleHold(pending.item)
    }

    /// `KEY,A|B|C,P`: Channel toggles at once; System and Department toggle at once on a second
    /// press inside the double-press window, else after the 2 s pause. A press names the item the
    /// moment shows; with none shown it does nothing.
    private func pressHoldKey(_ key: String) {
        settleHolds()
        let (level, tag) = key == "A" ? ("SYS", "System") : ("DEPT", "Department")
        let xml = plainScannerInfoXML()
        let lineBreak = personality.xmlLineBreak
        if key == "C" {
            if let index = MockScreens.shownIndex(xml, tag: "TGID", lineBreak: lineBreak) {
                toggleHold("TGID:\(index)")
            } else if let index = MockScreens.shownIndex(xml, tag: "ConvFrequency", lineBreak: lineBreak) {
                toggleHold("CFREQ:\(index)")
            }
            return
        }
        guard let index = MockScreens.shownIndex(xml, tag: tag, lineBreak: lineBreak) else { return }
        let item = "\(level):\(index)"
        if let pending = pendingHold, pending.key == key, clock.now - pending.pressedAt <= Self.doublePressWindow {
            pendingHold = nil
            toggleHold(item)
        } else {
            pendingHold = (key, item, clock.now)
        }
    }

    // MARK: Push

    private func subscribe(_ peer: ControlPeer, intervalMS: Int) {
        subscribers.removeValue(forKey: peer)?.timer.cancel()
        guard intervalMS > 0 else { return }
        // Strict: the scanner pushes at the interval asked for, and so must the mock when its
        // timers would be coalesced (a throttled process, the CI runner: a 50 ms timer fired about
        // every 200 ms there, a quarter of the pushes; LESSONS.md 2026-11-20).
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = DispatchTimeInterval.milliseconds(intervalMS)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.push(to: peer) }
        subscribers[peer] = Subscriber(peer: peer, timer: timer, started: .now, lifetimeFrom: clock.now)
        timer.resume()
    }

    /// Whether `subscriber`'s pushes have stopped for good: the model's push lifetime has run out
    /// on the scenario clock since its `PSI` or the latest restart.
    private func lifetimeIsOver(_ subscriber: Subscriber) -> Bool {
        guard let lifetime = personality.pushLifetime else { return false }
        return clock.now - subscriber.lifetimeFrom > lifetime
    }

    private func push(to peer: ControlPeer) {
        guard let subscriber = subscribers[peer], answering, !rebooting else { return }
        if let stallAfter, subscriber.started.duration(to: .now) > .milliseconds(Int(stallAfter * 1000)) { return }
        // The model's push lifetime, on the scenario clock: the subscription stays, its pushes stop.
        if lifetimeIsOver(subscriber) { return }
        pushesSent += 1
        reply(xml("PSI", scannerInfoXML()), to: subscriber.peer)
    }

    // MARK: Reboot

    private func beginReboot() {
        rebooting = true
        menu = MockMenu()
        cancelSubscriptions()
        rebootGeneration += 1
        let generation = rebootGeneration
        let handler = rebootHandler
        let duration = rebootDuration
        Task { [weak self] in
            await handler?(.began)
            try? await Task.sleep(for: duration)
            guard let self, self.sync({ $0.rebootGeneration == generation && $0.rebooting }) else { return }
            await handler?(.finished)
            self.sync { core in
                if core.rebootGeneration == generation { core.rebooting = false }
            }
        }
    }

    // MARK: Sending

    /// `GCS` ends in `\n`; every other reply in `\r`.
    private func reply(_ text: String, to peer: ControlPeer, terminator: String = "\r") {
        reply(Data((text + terminator).utf8), to: peer)
    }

    /// Sends `data`, unless a drop fault withholds this reply, after the command's reply delay.
    private func reply(_ data: Data, to peer: ControlPeer) {
        guard !suppressReply else { return }
        guard let delay = replyDelay, delay > .zero else {
            sendToPeer(data, peer)
            return
        }
        let generation = peerGeneration
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay / .milliseconds(1)))) { [weak self] in
            // Not to a peer that has gone since (a new pty is a new link); a no-op once stopped.
            guard let self, self.peerGeneration == generation else { return }
            self.sendToPeer(data, peer)
        }
    }
}

/// The UDP front end: a loopback socket whose datagrams feed a `ControlCore`, each client address a
/// `ControlPeer.udp` peer. Confined to the core's queue.
final class UDPControlEndpoint: @unchecked Sendable {
    private let core: ControlCore
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    /// Each client's address, by its peer key.
    private var addresses: [String: sockaddr_in] = [:]

    init(core: ControlCore) {
        self.core = core
        core.sendToPeer = { [weak self] data, peer in self?.send(data, to: peer) }
    }

    func start(port: UInt16) throws -> UInt16 {
        try core.queue.sync {
            if fd >= 0 { return boundPort() }
            let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else { throw POSIXError(.EMFILE) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
                Darwin.close(sock)
                throw POSIXError(code)
            }
            let flags = fcntl(sock, F_GETFL)
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
            fd = sock
            let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: core.queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { Darwin.close(sock) }
            self.source = source
            source.resume()
            return boundPort()
        }
    }

    func stop() {
        core.queue.sync {
            // Log datagrams already in the socket buffer first: a client's last command (say a
            // `PSI,0` sent just before the test stops the mock) has been delivered on loopback
            // but may not have woken the read source yet, and closing the socket would drop it.
            readAvailable()
            core.halt()
            source?.cancel()
            source = nil
            fd = -1
        }
    }

    private func boundPort() -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func key(_ address: sockaddr_in) -> String {
        "\(address.sin_addr.s_addr):\(address.sin_port)"
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { return }
            let key = Self.key(peer)
            addresses[key] = peer
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                let command = line.trimmingCharacters(in: .whitespaces)
                if !command.isEmpty { core.receive(command, from: .udp(key: key)) }
            }
        }
    }

    /// On the core's queue. A no-op once stopped, and for a peer that isn't a UDP client.
    private func send(_ data: Data, to peer: ControlPeer) {
        guard fd >= 0, case .udp(let key) = peer, var address = addresses[key] else { return }
        let bytes = [UInt8](data)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
