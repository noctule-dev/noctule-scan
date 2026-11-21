// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import NoctuleKit

public enum MockSerialScannerError: Error, Equatable {
    /// Something that isn't a symlink is at the link path; the mock leaves it alone.
    case linkPathOccupied(String)
    /// The link couldn't be made (or a stale one removed).
    case linkFailed(String)
    /// `stop()` has run; a stopped mock can't be plugged in again.
    case stopped
}

/// A mock scanner on a pseudo-terminal, standing in for an SDS150 on USB serial (SDS150 design §6),
/// or with `.sds100`'s answers an SDS100 (SDS100 design §5.4):
/// the control core the UDP mock uses (`ControlCore`, with `.sds150`'s answers by default) behind a
/// byte-stream front end. A client opens the path `start()` returns as it would
/// `/dev/cu.usbmodem…`. There is no audio, no RTSP and no reconnect hazard.
///
/// - Commands are cut from the byte stream at `\r` (a `\n` also ends one; blank lines are skipped),
///   however the client's writes split or join them. Replies and pushes go out whole, in order,
///   each with one write (7 bytes per write with `MockFaults.splitWrites`).
/// - `MDL` and `VER` come from the personality, not the scenario, so a changed `reportedModel`
///   (`--mdl-name`) is what the client sees.
/// - `linkPath`: a symlink the mock makes to the current pty's slave, so one path survives an
///   unplug and replug (a new pty is a new `/dev/ttysNNN`). A symlink already there (a crashed run's,
///   or an unplugged mock's) is replaced; anything else there fails `start()`/`replug()` with
///   `.linkPathOccupied` and is never touched. The link is removed only while it still points at
///   this mock's pty.
/// - `unplug()` (or `MockFaults.unplugAfter`) removes the link and closes the pty: the client reads
///   end of file, as when the cable is pulled. `replug()` (or `replugAfter`) opens a new pty behind
///   the same link. The scenario runs on through both, on the same clock.
/// - Faults: `dropNextReply`, `dropNextRequest`, `rejectNext` and `stallPSIAfter` as on the UDP
///   mock, plus `unplugAfter`/`replugAfter` (real time, like the UDP mock's timed faults),
///   `splitWrites`, and `pushBeforeStop` (test-only: one push written just before the next `PSI,0`
///   is handled, so it is on the wire ahead of that `PSI,OK`).
///
/// - `lineOut`: the scanner's headphone jack (`MockLineOut`), served on a Unix-domain socket at its
///   path from `start()` until `stop()`, whatever the port does: an unplug of the USB cable leaves it
///   playing. `VOL,n` changes its level at once, and `MockFaults.lineOutSilent` silences it.
///
/// With `.sds150`'s answers a subscription's pushes stop 183 s of scenario time after its `PSI`
/// (seen on hardware) unless a `KAL` restarts the count (`KAL` every 60 s kept the real unit
/// pushing for an hour; that each one restarts the full count is assumed, `MockPersonality` lists the push
/// lifetime's assumptions), and `KAL` gets no reply (spec, and seen on hardware).
///
/// With `.sds100`'s answers the pushes stop 183 s after the latest `PSI` and there is no `KAL`
/// (`ERR`, seen on hardware): sending the same `PSI` again on the open port keeps them going (seen
/// for 240 s at 60 s apart; that each one restarts the full count is assumed) and adds no second
/// subscription, so `activeSubscribers` stays 1. The SDS100's other assumptions (the level ranges'
/// `NG`, the XML form, `GCS` and `KAL` as `ERR`, `MSM,1` as `MSM,NG`, one column per icon glyph)
/// are listed on `MockPersonality`.
///
/// **Assumptions, not hardware** (besides `MockPersonality`'s and `MockMenu`'s): an unplug ends
/// every `PSI` subscription, as losing power would, while the menu, `VOL` and `SQL` carry on (a
/// handheld runs on its battery); a reply held back by `replyDelays` when the port closes is never
/// sent; pushes keep coming while no client has the port open (what the scanner does when the Mac
/// closes the port is unknown, §3.3), and wait in the port for the next one; the scanner never puts
/// a push inside another reply.
///
/// `activeSubscribers` after `stop()` is the count at the moment of the stop (anything but 0 means
/// a client left a `PSI` running).
public actor MockSerialScanner {
    public nonisolated let scenario: MockScenario
    public nonisolated let clock: MockClock
    public nonisolated let personality: MockPersonality
    public nonisolated let linkPath: String?

    private let core: ControlCore
    private let endpoint: StreamControlEndpoint
    private let lineOut: MockLineOut?
    private let lineOutSilent: MockLineOutFlag
    private var faults = MockFaults.none
    private var log: (@Sendable (String) -> Void)?

    private enum Phase {
        case idle
        case plugged(PseudoTerminal, reader: Task<Void, Never>)
        case unplugged
        case stopped
    }

    private var phase = Phase.idle
    private var stoppedSubscribers: Int?
    private var faultTask: Task<Void, Never>?
    // Plugging and unplugging await, so they take turns (a timed fault can race a test's call).
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `lineOut` names the socket path and channel of the headphone jack; nil has none.
    public init(scenario: MockScenario, clock: MockClock, personality: MockPersonality = .sds150,
                linkPath: String? = nil, replyDelays: [String: Duration] = [:],
                lineOut: (path: String, channel: LineInChannel)? = nil,
                quickKeySetDelay: Duration = .milliseconds(800),
                gltPageSize: Int = MockFavorites.defaultGLTPageSize) {
        self.scenario = scenario
        self.clock = clock
        self.personality = personality
        self.linkPath = linkPath
        core = ControlCore(scenario: scenario, clock: clock, rebootDuration: .seconds(10), replyDelays: replyDelays,
                           personality: personality, quickKeySetDelay: quickKeySetDelay, gltPageSize: gltPageSize)
        endpoint = StreamControlEndpoint(core: core)
        let silent = MockLineOutFlag(), control = core
        lineOutSilent = silent
        self.lineOut = lineOut.map {
            MockLineOut(path: $0.path, channel: $0.channel, scenario: scenario, clock: clock,
                        volume: { control.sync { $0.volume } }, silent: { silent.isSet })
        }
    }

    /// Opens the pty (and makes the link) and returns the port's path: `linkPath` when given, else
    /// the pty's slave path. Arms the timed faults. Once started, it does what `replug()` does.
    public func start() async throws -> String {
        await takeTurn()
        let first: Bool
        switch phase {
        case .idle: first = true
        case .stopped, .plugged, .unplugged: first = false
        }
        guard first else {
            endTurn()
            return try await replug()
        }
        defer { endTurn() }
        try lineOut?.start()
        let path: String
        do { path = try plugIn() } catch {
            lineOut?.stop()
            throw error
        }
        armTimedFaults()
        return path
    }

    /// Unplugs, if plugged in, and stops for good: no thread, task or descriptor of the mock's
    /// outlives it. `activeSubscribers` keeps the count at this moment.
    public func stop() async {
        faultTask?.cancel()
        await takeTurn()
        if case .stopped = phase {
            endTurn()
            return
        }
        let ended = await unplugNow()
        stoppedSubscribers = ended ?? core.sync { $0.subscribers.count }
        core.sync { $0.halt() }
        lineOut?.stop()
        phase = .stopped
        endTurn()
        await faultTask?.value
        faultTask = nil
    }

    /// Removes the link and closes the pty, ending every `PSI` subscription. Does nothing when not
    /// plugged in.
    public func unplug() async {
        await takeTurn()
        defer { endTurn() }
        if await unplugNow() != nil { log?("mock: unplugged (the serial port closed)") }
    }

    /// A new pty behind the same `linkPath`; returns the port's path (the new slave's without a
    /// link). Returns the current path when already plugged in.
    public func replug() async throws -> String {
        await takeTurn()
        defer { endTurn() }
        switch phase {
        case .stopped: throw MockSerialScannerError.stopped
        case .plugged(let terminal, _): return linkPath ?? terminal.slavePath
        case .idle, .unplugged: break
        }
        let path = try plugIn()
        log?("mock: plugged in again: \(path)")
        return path
    }

    /// Takes effect at once; the timed faults are armed again only when they change (from now).
    public func setFaults(_ faults: MockFaults) async {
        let previous = self.faults
        self.faults = faults
        lineOutSilent.set(faults.lineOutSilent)
        let endpoint = self.endpoint
        core.sync { core in
            core.dropReply = faults.dropNextReply?.uppercased()
            core.dropRequest = faults.dropNextRequest?.uppercased()
            core.rejectName = faults.rejectNext?.uppercased()
            core.dropReplyRemaining = max(1, faults.dropCount)
            core.dropRequestRemaining = max(1, faults.dropCount)
            core.rejectRemaining = max(1, faults.dropCount)
            core.stallAfter = faults.stallPSIAfter
            core.pushBeforeStop = faults.pushBeforeStop
            endpoint.splitWrites = faults.splitWrites
        }
        let timed = previous.unplugAfter != faults.unplugAfter || previous.replugAfter != faults.replugAfter
        if timed, case .plugged = phase { armTimedFaults() }
    }

    /// The Favorites tree and its quick-key states as they are now.
    public var favorites: MockFavorites { core.sync { $0.favorites } }

    /// Replaces the Favorites tree (tests move keys, rename and remove rows).
    public func setFavorites(_ favorites: MockFavorites) { core.sync { $0.favorites = favorites } }

    /// Called (on the core's queue) with every command received.
    public func setCommandObserver(_ observer: (@Sendable (String) -> Void)?) {
        core.sync { $0.commandObserver = observer }
    }

    /// Receives one line per unplug and replug.
    public func setLog(_ log: (@Sendable (String) -> Void)?) { self.log = log }

    /// Every command received, without its terminator, oldest first.
    public var receivedCommands: [String] { core.sync { $0.log } }
    /// `PSI` subscriptions running; after `stop()`, those running when it was called.
    public var activeSubscribers: Int { stoppedSubscribers ?? core.sync { $0.subscribers.count } }
    /// The socket path of the headphone jack, if the mock has one.
    public nonisolated var lineOutPath: String? { lineOut?.path }
    public var isPluggedIn: Bool {
        if case .plugged = phase { return true }
        return false
    }
    /// PSI pushes sent, across every pty.
    public var pushesSent: Int { core.sync { $0.pushesSent } }
    public var volume: Int { core.sync { $0.volume } }
    public var squelch: Int { core.sync { $0.squelch } }
    /// True while a menu screen is showing.
    public var isInMenu: Bool { core.sync { $0.menu.isActive } }
    /// Titles of the screens from the top menu down; empty outside a menu.
    public var menuPath: [String] { core.sync { $0.menu.path } }
    /// Every state change the menu carried out, oldest first.
    public var menuActions: [String] { core.sync { $0.menu.actions } }
    /// The most bytes any one write to the port has held (7 with `splitWrites`), for tests.
    var largestWrite: Int { endpoint.sync { $0.largestWrite } }

    // MARK: Plugging

    /// With the turn held and not plugged in: a new pty, the link to it, and its reader.
    private func plugIn() throws -> String {
        let terminal = try PseudoTerminal()
        if let linkPath {
            do {
                try Self.makeLink(linkPath, to: terminal.slavePath)
            } catch {
                terminal.close()
                throw error
            }
        }
        let core = self.core, endpoint = self.endpoint
        core.sync { _ in endpoint.attach(terminal) }
        // One task feeds the core in order; the stream finishes when the pty closes.
        let reader = Task.detached {
            for await chunk in terminal.received {
                core.queue.async { endpoint.ingest(chunk) }
            }
        }
        phase = .plugged(terminal, reader: reader)
        return linkPath ?? terminal.slavePath
    }

    /// With the turn held: removes the link, closes the pty, hands the core whatever the client
    /// wrote before that, then ends every subscription. Returns how many there were, or nil when
    /// not plugged in.
    @discardableResult
    private func unplugNow() async -> Int? {
        guard case .plugged(let terminal, let reader) = phase else { return nil }
        // While the pty is open no other pty can have its slave path, so a link that names it is ours.
        if let linkPath { Self.removeLink(linkPath, ifPointingAt: terminal.slavePath) }
        terminal.close()
        await reader.value
        let endpoint = self.endpoint
        let ended = core.sync { core in
            let count = core.subscribers.count
            endpoint.detach()
            core.forgetPeers()
            return count
        }
        phase = .unplugged
        return ended
    }

    private func armTimedFaults() {
        faultTask?.cancel()
        faultTask = nil
        guard let unplugAfter = faults.unplugAfter else { return }
        let replugAfter = faults.replugAfter
        faultTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Int((unplugAfter * 1000).rounded())))
                await self?.unplugByFault()
                guard let replugAfter else { return }
                try await Task.sleep(for: .milliseconds(Int((replugAfter * 1000).rounded())))
                await self?.replugByFault()
            } catch {
                // Cancelled: a stop or new faults.
            }
        }
    }

    private func unplugByFault() async {
        guard !Task.isCancelled else { return }
        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled else { return }
        if await unplugNow() != nil { log?("mock: unplugged (the serial port closed)") }
    }

    private func replugByFault() async {
        guard !Task.isCancelled else { return }
        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled, case .unplugged = phase else { return }
        do {
            let path = try plugIn()
            log?("mock: plugged in again: \(path)")
        } catch {
            log?("mock: couldn't plug in again: \(error)")
        }
    }

    private func takeTurn() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the turn to the next waiter, if any (it stays taken), else frees it.
    private func endTurn() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: The link

    /// Points `path` at `target`, replacing a symlink already there; anything else there is refused.
    static func makeLink(_ path: String, to target: String) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFLNK else { throw MockSerialScannerError.linkPathOccupied(path) }
            guard unlink(path) == 0 || errno == ENOENT else {
                throw MockSerialScannerError.linkFailed("unlink \(path): \(String(cString: strerror(errno)))")
            }
        }
        guard symlink(target, path) == 0 else {
            throw MockSerialScannerError.linkFailed("symlink \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Removes `path` only if it is a symlink to `target`.
    static func removeLink(_ path: String, ifPointingAt target: String) {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
              destination == target else { return }
        unlink(path)
    }
}

/// The byte-stream front end: the current pty's bytes, cut into commands for a `ControlCore` (one
/// `ControlPeer.stream` peer), and the core's replies and pushes written back to it. Confined to the
/// core's queue.
final class StreamControlEndpoint: @unchecked Sendable {
    /// Bytes per write with `splitWrites`.
    static let splitSize = 7

    private let core: ControlCore
    private var terminal: PseudoTerminal?
    /// The start of a command whose terminator hasn't arrived yet.
    private var partial: [UInt8] = []
    var splitWrites = false
    private(set) var largestWrite = 0

    init(core: ControlCore) {
        self.core = core
        core.sendToPeer = { [weak self] data, peer in self?.send(data, to: peer) }
    }

    func sync<T>(_ body: (StreamControlEndpoint) -> T) -> T { core.queue.sync { body(self) } }

    /// On the queue: the pty replies and pushes go to from now on.
    func attach(_ terminal: PseudoTerminal) {
        self.terminal = terminal
        partial = []
    }

    /// On the queue: nothing more is read or written (a pending half command is lost with the pty).
    func detach() {
        terminal = nil
        partial = []
    }

    /// On the queue: bytes from the client.
    func ingest(_ data: Data) {
        guard terminal != nil else { return }
        for byte in data {
            guard byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n") else {
                partial.append(byte)
                continue
            }
            let command = String(decoding: partial, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            partial.removeAll(keepingCapacity: true)
            if !command.isEmpty { core.receive(command, from: .stream) }
        }
    }

    /// On the queue. A no-op while unplugged, and for a peer that isn't the stream.
    private func send(_ data: Data, to peer: ControlPeer) {
        guard case .stream = peer, let terminal else { return }
        guard splitWrites else {
            largestWrite = max(largestWrite, data.count)
            terminal.write(data)
            return
        }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: Self.splitSize, limitedBy: data.endIndex) ?? data.endIndex
            largestWrite = max(largestWrite, end - start)
            terminal.write(Data(data[start..<end]))
            start = end
        }
    }
}
