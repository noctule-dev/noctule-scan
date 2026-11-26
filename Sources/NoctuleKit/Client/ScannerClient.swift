// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization

public enum ScannerClientError: Error, Equatable {
    case notConnected
    case timeout(command: String)
    case rejected(command: String, response: String)
    case unexpectedResponse(command: String)
    case invalidArgument(String)
    /// The caller's `onlyIf` said no once the request held the slot: nothing was sent.
    case withheld(command: String)
}

/// One pushed `ScannerInfo` and when the client received it.
public struct PushUpdate: Sendable {
    public var info: ScannerInfo
    /// When the client's router took the `PSI` response off the transport, before any further
    /// hop (the actor, the stream buffer, the consumer). Use it to line pushes up with audio.
    public var receivedAt: ContinuousClock.Instant

    public init(info: ScannerInfo, receivedAt: ContinuousClock.Instant) {
        self.info = info; self.receivedAt = receivedAt
    }
}

/// Talks to one scanner over a `ScannerTransport`.
///
/// Routing: one request is in flight at a time; later callers queue in FIFO order. A response
/// satisfies the pending request when its `command` equals the request's name, except
/// `.xml(command: "PSI", …)`, which always goes to the push stream, stamped with the instant the
/// router took it off the transport (`PushUpdate.receivedAt`). Anything else is dropped.
/// A request with no matching response within `commandTimeout` throws `timeout` and frees the slot.
/// Responses are matched to requests by command name only (the protocol has no request IDs), so
/// a late reply after a timeout can satisfy the next request with the same name.
///
/// **Decided at the slot** (`onlyIf`). A request can wait for the slot for up to a command timeout (behind a
/// read whose reply was lost), and what made its caller send it may have changed meanwhile. A request given
/// `onlyIf` evaluates it once it holds the slot, in the task that writes it, just before the write, and writes
/// nothing unless it returns true: it then throws `withheld` and frees the slot at once. Nothing in the client
/// suspends between that call and the transport's `send`, but that `send` is one hop onto the transport's actor,
/// which can wait when that actor or the thread pool is busy: a caller that clears its flag (synchronously, from
/// any thread) before the guard runs sends nothing; one that clears it after can still see the bytes go out a
/// moment later. State-changing commands that a user's action
/// sends take one (`setListKey`, `setSystemKey`, `setDepartmentKey`, `press`, `setMenuValue`).
///
/// If the transport's `responses` stream ends without `disconnect()`, the client tears down to
/// the disconnected state (no `PSI,0`, since the link is gone): pending and queued requests and
/// later calls throw `notConnected`, and `connect()` can reconnect.
///
/// **The push keep-alive** (`startPush(interval:keepAlive:onKeepAliveFailure:)`;
/// `ModelProfile.pushKeepAlive`). It is one of two kinds (`PushKeepAlive.Action`): a command
/// (the SDS150's `KAL`), or a renewal, the subscription's own `PSI,<ms>` written again, exactly as
/// that push wrote it. Every rule below holds for both. While that push is the active one, a loop
/// writes the keep-alive with no reply awaited: the first no sooner than one interval
/// after the `PSI` was written, and each next one no sooner than one interval after the previous
/// write returned, so two are never closer than an interval (a loop that wakes late is late, and
/// never catches up). Each write takes the request slot like a request, so it waits behind a
/// request in flight (until its reply or its timeout) and behind requests queued before it, and
/// is never written while a reply is pending; it holds the slot only while it writes. Once it
/// holds the slot the loop checks, on the actor, that it hasn't been cancelled and that its push
/// is still the active one on a connected client. Every end of the push (`stopPush()`,
/// `disconnect()`, a consumer cancel or drop, a `PSI` rejection, a newer push, transport end)
/// cancels it at once, and every path that then writes `PSI,0` or closes the transport
/// (`stopPush`, `disconnect`, a consumer cancel's `PSI,0`, transport end's close) first awaits
/// every loop not yet ended, an older push's included, so a keep-alive already on its way is
/// written before that `PSI,0` or close, and none after: no keep-alive follows its push's `PSI,0`,
/// and none is written once `disconnect()` has returned. So a `stopPush()` that comes while a
/// keep-alive waits for the slot writes its `PSI,0` once the slot frees (after the pending reply
/// or timeout), and that keep-alive writes nothing. A keep-alive write that throws ends that
/// push's keep-alive: the loop hands the error to `onKeepAliveFailure` once on its way out, and it
/// is never resent or retried; nothing else changes (a link that went away ends `responses` as
/// always). A reply to it (the SDS150 sent none in 240 s of `KAL`s) is an unmatched line and
/// dropped like any other; a renewal's `PSI,OK` is absorbed as the first `PSI`'s is.
///
/// **A rejected renewal is not a rejected first `PSI`.** A `PSI` rejection ends the push (no
/// `PSI,0`: no subscription exists) unless the active push's keep-alive is a renewal and one has
/// been written (or begun: part of it may be with the scanner) for it. Then the rejection is the
/// renewal's and the earlier subscription is still running, so the push stays, and its stop still
/// writes `PSI,0`; that push's renewals end, as after a failed write, and `onKeepAliveFailure`
/// gets `PushRenewalRefused()`, from the actor. A push's keep-alive failures, a failed write and a
/// refused renewal alike, are reported once in all, however many come. A newer push writes its
/// `PSI` only after an older push's renewal already being written has landed, so the scanner never
/// ends on the older rate; a renewal still waiting for the slot holds it up not at all (it writes
/// nothing once it gets the slot), nor does a `KAL` (which changes no rate, and may still land after
/// the newer `PSI`, as it always could).
public actor ScannerClient {
    private enum State {
        case disconnected
        case connecting(Task<Void, any Error>)
        case connected
        case disconnecting(Task<Void, Never>)
    }

    /// The request currently holding the slot. Acts as a one-shot mailbox: a response (or
    /// failure) may arrive before the requester starts waiting, and is kept until it does.
    private struct Pending {
        let id: UInt64
        let name: String
        var result: Result<ScannerResponse, any Error>?
        var continuation: CheckedContinuation<ScannerResponse, any Error>?
        var resolved = false
        let sentAt = ContinuousClock.now
    }

    private let transport: any ScannerTransport
    private let commandTimeout: Duration
    private var state: State = .disconnected
    private var routerTask: Task<Void, Never>?
    private var routerGeneration: UInt64 = 0

    private var slotBusy = false
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: Pending?
    private var nextRequestID: UInt64 = 0
    /// When the last `PSI` push arrived, for the command trace's gaps.
    private var lastPushAt: ContinuousClock.Instant?

    /// The active push stream's input. `startPush` and `startPushUpdates` both install one; only
    /// the element type differs (the plain info, or the timestamped update).
    private struct PushSink: Sendable {
        let yield: @Sendable (PushUpdate) -> Void
        let finish: @Sendable () -> Void
    }

    private var push: PushSink?
    private var pushGeneration: UInt64 = 0
    /// The best-effort `PSI,0` sent after a consumer cancelled or dropped the push stream.
    /// `startPush` and `disconnect` wait for it so it can't overtake a newer `PSI` or a close.
    private var pushStopping: Task<Void, Never>?
    /// Keep-alive loops not yet ended, by push generation: the active push's, and any that an end
    /// of their push cancelled but that may still be finishing a write. Each removes itself when
    /// it ends; a stop awaits them all before its `PSI,0` or close.
    private var keepAliveLoops: [UInt64: Task<Void, Never>] = [:]
    /// The active push's renewal, when its keep-alive renews the subscription: whether a renewal
    /// has been begun (after which a `PSI` rejection is the renewal's, not the first `PSI`'s), and
    /// the push's failure report, shared with its loop. Cleared by every end of the push.
    private var renewal: (generation: UInt64, begun: Bool, failure: KeepAliveFailureReport)?
    /// The pushes whose renewal is being written right now (past the slot's checks, in the
    /// transport's `send`): what a newer push waits for before its `PSI`.
    private var renewalsBeingWritten: Set<UInt64> = []
    /// Push starts waiting for an older push's renewal to land: that push has been finished, but
    /// its subscription still runs on the scanner, so a `disconnect()` meanwhile writes `PSI,0`.
    private var startsAwaitingRenewals = 0

    /// Hands a push's keep-alive failure to `onKeepAliveFailure` at most once, whether it comes
    /// from its loop (a write that threw) or the router (a refused renewal).
    private final class KeepAliveFailureReport: Sendable {
        private let handler: (@Sendable (any Error) -> Void)?
        private let reported = Mutex(false)

        init(_ handler: (@Sendable (any Error) -> Void)?) { self.handler = handler }

        func report(_ error: any Error) {
            let first = reported.withLock { reported in
                defer { reported = true }
                return !reported
            }
            if first { handler?(error) }
        }
    }

    /// How a keep-alive loop waits for its next write: sleeps until the instant (production), or,
    /// in tests, wakes late on purpose. Throws when the loop is cancelled.
    typealias KeepAliveSleep = @Sendable (ContinuousClock.Instant) async throws -> Void

    static let keepAliveSleep: KeepAliveSleep = { try await Task.sleep(until: $0, clock: .continuous) }

    private let sleepUntil: KeepAliveSleep

    public init(transport: any ScannerTransport, commandTimeout: Duration = .seconds(2)) {
        self.init(transport: transport, commandTimeout: commandTimeout, keepAliveSleep: Self.keepAliveSleep)
    }

    init(transport: any ScannerTransport, commandTimeout: Duration = .seconds(2), keepAliveSleep: @escaping KeepAliveSleep) {
        sleepUntil = keepAliveSleep
        self.transport = transport
        self.commandTimeout = commandTimeout
    }

    // MARK: Connection

    public func connect() async throws {
        // Loop because every await below is a suspension point where another caller may
        // have changed the state.
        while true {
            switch state {
            case .connected:
                return
            case .connecting(let opening):
                try await opening.value
                if case .connected = state { return }
                throw ScannerClientError.notConnected
            case .disconnecting(let teardown):
                await teardown.value
                continue
            case .disconnected:
                break
            }
            let transport = self.transport
            let opening = Task { try await transport.open() }
            state = .connecting(opening)
            do {
                try await opening.value
            } catch {
                if case .connecting = state { state = .disconnected }
                throw error
            }
            // A disconnect() while opening wins.
            guard case .connecting = state else { throw ScannerClientError.notConnected }
            state = .connected
            routerGeneration += 1
            let generation = routerGeneration
            let responses = transport.responses
            routerTask = Task { [weak self] in
                for await response in responses {
                    // Stamp before the hop onto the actor, which may be busy.
                    let receivedAt = ContinuousClock.now
                    guard let self else { return }
                    await self.route(response, receivedAt: receivedAt)
                }
                await self?.responsesEnded(generation: generation)
            }
            return
        }
    }

    /// Stops an active push (best effort, errors ignored), fails any in-flight request,
    /// finishes the push stream, and closes the transport.
    public func disconnect() async {
        var opening: Task<Void, any Error>?
        switch state {
        case .disconnected:
            return
        case .disconnecting(let teardown):
            await teardown.value
            return
        case .connecting(let task):
            opening = task
        case .connected:
            break
        }
        let pushWasActive = push != nil || startsAwaitingRenewals > 0
        finishPush()
        let loops = endingKeepAlives
        resolvePending(.failure(ScannerClientError.notConnected))
        routerTask?.cancel()
        routerTask = nil

        let transport = self.transport
        let stopping = pushStopping
        let teardown = Task {
            await stopping?.value
            // A keep-alive still being written goes before `PSI,0` and the close, never after.
            for loop in loops { await loop.value }
            if let opening {
                // Let a half-finished open complete before closing; never send on it.
                _ = try? await opening.value
            } else if pushWasActive, let stop = try? ScannerCommand("PSI", "0") {
                CommandTrace.log("send PSI,0")
                try? await transport.send(stop)
            }
            await transport.close()
        }
        state = .disconnecting(teardown)
        await teardown.value
        if case .disconnecting = state { state = .disconnected }
    }

    private var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: Requests

    /// Sends `command` and waits for its reply (see the type's comment). With `onlyIf`, it is written only if
    /// `onlyIf` returns true once the request holds the slot; else nothing is sent and it throws `withheld`.
    public func send(_ command: ScannerCommand,
                     onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws -> ScannerResponse {
        guard isConnected else { throw ScannerClientError.notConnected }
        await acquireSlot()
        defer { releaseSlot() }
        try Task.checkCancellation()
        guard isConnected else { throw ScannerClientError.notConnected }

        nextRequestID += 1
        let id = nextRequestID
        pending = Pending(id: id, name: command.name)
        defer { if pending?.id == id { pending = nil } }

        let transport = self.transport
        let timeout = commandTimeout
        let sentAt = ContinuousClock.now
        let response = try await withThrowingTaskGroup(of: ScannerResponse.self) { group in
            group.addTask {
                // Decided here, holding the slot: nothing in the client suspends between it and the transport's
                // `send` (one hop onto the transport's actor, which then writes).
                if let proceed, !proceed() {
                    CommandTrace.log("withheld \(command.name) at the slot")
                    throw ScannerClientError.withheld(command: command.name)
                }
                CommandTrace.log("send \(CommandTrace.describe(command))")
                try await transport.send(command)
                return try await self.awaitReply(id: id)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                CommandTrace.log("timeout \(command.name) after \(CommandTrace.milliseconds(since: sentAt)) ms")
                throw ScannerClientError.timeout(command: command.name)
            }
            // Leaving the scope cancels the loser; awaitReply's cancellation handler resolves
            // the mailbox, so the group never waits on a suspended continuation.
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ScannerClientError.timeout(command: command.name)
            }
            return first
        }
        if case .rejected(let text) = response.status {
            throw ScannerClientError.rejected(command: command.name, response: text)
        }
        return response
    }

    public func modelInfo() async throws -> (reported: String, model: ScannerModel?) {
        let reported = try await firstField(of: ScannerCommand("MDL"))
        return (reported, ScannerModel(reported: reported))
    }

    public func firmwareVersion() async throws -> String {
        var text = try await firstField(of: ScannerCommand("VER"))
        if text.hasPrefix("Version ") { text.removeFirst("Version ".count) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func volume() async throws -> Int { try await level(of: ScannerCommand("VOL")) }
    public func setVolume(_ level: Int) async throws { try await expectOK(ScannerCommand("VOL", String(level))) }
    public func squelch() async throws -> Int { try await level(of: ScannerCommand("SQL")) }
    public func setSquelch(_ level: Int) async throws { try await expectOK(ScannerCommand("SQL", String(level))) }

    public func scannerInfo() async throws -> ScannerInfo {
        let command = try ScannerCommand("GSI")
        guard case .xml(_, let root) = try await send(command), let info = try? ScannerInfo(xml: root) else {
            throw ScannerClientError.unexpectedResponse(command: command.name)
        }
        return info
    }

    /// `MSI`: the current menu screen as data. A `TypeError` screen is a valid answer, not a failure.
    public func menuScreen() async throws -> MenuScreen {
        let command = try ScannerCommand("MSI")
        guard case .xml(_, let root) = try await send(command), let screen = try? MenuScreen(xml: root) else {
            throw ScannerClientError.unexpectedResponse(command: command.name)
        }
        return screen
    }

    /// `MSV,,<value>` (the reserved field left empty): on a list, an item index; on an entry
    /// screen, the whole text. Never sent with a comma, CR or LF in the value. A state-changing
    /// command: callers must not resend it after a timeout. `onlyIf`: see `send(_:onlyIf:)`.
    public func setMenuValue(_ value: String, onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        try await expectOK(ScannerCommand("MSV", "", value), onlyIf: proceed)
    }

    public func displayStatus() async throws -> DisplayStatus {
        let command = try ScannerCommand("STS")
        guard case .fields(_, let fields) = try await send(command),
              let status = try? DisplayStatus(fields: fields)
        else { throw ScannerClientError.unexpectedResponse(command: command.name) }
        return status
    }

    /// The battery and charger state from `GCS` (SDS150).
    public func chargeStatus() async throws -> ChargeStatus {
        let command = try ScannerCommand("GCS")
        guard case .fields(_, let fields) = try await send(command),
              let status = try? ChargeStatus(fields: fields)
        else { throw ScannerClientError.unexpectedResponse(command: command.name) }
        return status
    }

    // MARK: Favorites quick keys (Plan 20)

    /// `GLT,FL`: the Favorites Lists, without the built-in entries.
    public func favoritesLists() async throws -> [FavoritesList] {
        try favoritesXML(try await favoritesDocument("FL"), "GLT", FavoritesXML.lists)
    }

    /// `GLT,SYS,<list index>`.
    public func favoritesSystems(inList index: UInt32) async throws -> [FavoritesSystem] {
        try favoritesXML(try await favoritesDocument("SYS", index), "GLT", FavoritesXML.systems)
    }

    /// `GLT,DEPT,<system index>`, without the built-in `Unknown`.
    public func favoritesDepartments(inSystem index: UInt32) async throws -> [FavoritesChild] {
        try favoritesXML(try await favoritesDocument("DEPT", index), "GLT", FavoritesXML.departments)
    }

    /// `GLT,SITE,<system index>`.
    public func favoritesSites(inSystem index: UInt32) async throws -> [FavoritesChild] {
        try favoritesXML(try await favoritesDocument("SITE", index), "GLT", FavoritesXML.sites)
    }

    /// `FQK`: the states of the list quick keys.
    public func listKeyStates() async throws -> QuickKeyStates {
        try await keyStates(try ScannerCommand("FQK"))
    }

    /// `SQK,<list key>`: the states of the system quick keys of that list.
    public func systemKeyStates(listKey: Int) async throws -> QuickKeyStates {
        try await keyStates(try ScannerCommand("SQK", String(try checkedKey(listKey))))
    }

    /// `DQK,<list key>,<system key>`: the states of the department quick keys of that system.
    public func departmentKeyStates(listKey: Int, systemKey: Int) async throws -> QuickKeyStates {
        try await keyStates(try ScannerCommand("DQK", String(try checkedKey(listKey)), String(try checkedKey(systemKey))))
    }

    /// `FQK` with 100 values, "0" everywhere but `key`. A state-changing command: never resent, even
    /// after a timeout (a lost reply looks like a lost request; re-read to see whether it took effect).
    /// A key outside 0 to 99 throws `invalidArgument` before anything is sent. `onlyIf`: see `send(_:onlyIf:)`.
    public func setListKey(_ key: Int, on: Bool, onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        let values = QuickKeyStates.setting(try checkedKey(key), on: on)
        try await expectOK(try ScannerCommand("FQK", arguments: values), onlyIf: proceed)
    }

    /// `SQK,<list key>` with 100 values. Same rules as `setListKey`.
    public func setSystemKey(_ key: Int, inList listKey: Int, on: Bool,
                             onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        let values = QuickKeyStates.setting(try checkedKey(key), on: on)
        try await expectOK(try ScannerCommand("SQK", arguments: [String(try checkedKey(listKey))] + values),
                           onlyIf: proceed)
    }

    /// `DQK,<list key>,<system key>` with 100 values. Same rules as `setListKey`.
    public func setDepartmentKey(_ key: Int, inList listKey: Int, system systemKey: Int, on: Bool,
                                 onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        let values = QuickKeyStates.setting(try checkedKey(key), on: on)
        let prefix = [String(try checkedKey(listKey)), String(try checkedKey(systemKey))]
        try await expectOK(try ScannerCommand("DQK", arguments: prefix + values), onlyIf: proceed)
    }

    // MARK: BCD436HP menu and hold commands

    /// `MNU,TOP,`: opens the top menu. State-changing: never resent, even after a timeout (re-read `GSI`
    /// to see whether it took effect). Only for a model whose profile enters menus this way, never an
    /// SDS model. `onlyIf`: see `send(_:onlyIf:)`.
    public func openMenu(onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        try await expectOK(try ScannerCommand("MNU", "TOP", ""), onlyIf: proceed)
    }

    /// `MSB,,`: back one menu level. Same rules as `openMenu`; outside a menu the scanner answers `NG`
    /// (`rejected`).
    public func menuBack(onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        try await expectOK(try ScannerCommand("MSB", "", ""), onlyIf: proceed)
    }

    /// `MSB,,RETURN_PREVOUS_MODE` (Uniden's spelling): leaves the menu. Same rules as `menuBack`.
    public func leaveMenu(onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        try await expectOK(try ScannerCommand("MSB", "", "RETURN_PREVOUS_MODE"), onlyIf: proceed)
    }

    /// `HLD,…` for a target: holds on it (or releases it). Same rules as `openMenu`; only for a model
    /// whose profile supports it, never an SDS model.
    public func hold(_ target: HoldTarget, onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        try await expectOK(try target.command, onlyIf: proceed)
    }

    private func checkedKey(_ key: Int) throws -> Int {
        guard (0...99).contains(key) else {
            throw ScannerClientError.invalidArgument("a quick key is 0 to 99, got \(key)")
        }
        return key
    }

    private func favoritesDocument(_ kind: String, _ index: UInt32? = nil) async throws -> XMLNode {
        let command = try ScannerCommand("GLT", arguments: [kind] + (index.map { [String($0)] } ?? []))
        guard case .xml(_, let root) = try await send(command), root.name == "GLT" else {
            throw ScannerClientError.unexpectedResponse(command: command.name)
        }
        return root
    }

    private func favoritesXML<T>(_ root: XMLNode, _ command: String, _ parse: (XMLNode) throws -> T) throws -> T {
        do { return try parse(root) } catch { throw ScannerClientError.unexpectedResponse(command: command) }
    }

    private func keyStates(_ command: ScannerCommand) async throws -> QuickKeyStates {
        guard case .fields(_, let fields) = try await send(command), let states = QuickKeyStates(fields: fields) else {
            throw ScannerClientError.unexpectedResponse(command: command.name)
        }
        return states
    }

    /// `KEY,<key>,P`. A state-changing command: never resent. `onlyIf`: see `send(_:onlyIf:)`.
    public func press(_ key: FrontPanelKey, onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        try await expectOK(ScannerCommand("KEY", key.rawValue, "P"), onlyIf: proceed)
    }

    private func firstField(of command: ScannerCommand) async throws -> String {
        guard case .fields(_, let fields) = try await send(command), let first = fields.first else {
            throw ScannerClientError.unexpectedResponse(command: command.name)
        }
        return first
    }

    private func level(of command: ScannerCommand) async throws -> Int {
        let text = try await firstField(of: command)
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
            throw ScannerClientError.unexpectedResponse(command: command.name)
        }
        return value
    }

    private func expectOK(_ command: ScannerCommand, onlyIf proceed: (@Sendable () -> Bool)? = nil) async throws {
        guard try await send(command, onlyIf: proceed).status == .ok else {
            throw ScannerClientError.unexpectedResponse(command: command.name)
        }
    }

    // MARK: Push

    /// Sends `PSI,<ms>` without waiting for an acknowledgement and returns the pushed status.
    /// The stream keeps the newest 64 updates if the consumer falls behind, and finishes on
    /// `stopPush()`, `disconnect()`, a `PSI` rejection, a new `startPush` or `startPushUpdates`,
    /// or transport end.
    /// If the consumer cancels its iteration or drops the stream, the client finishes the push
    /// and sends `PSI,0` (best effort), so a later `disconnect()` doesn't send it again.
    /// With `keepAlive` (a model's `ModelProfile.pushKeepAlive`), its command, or for a renewal
    /// this push's own `PSI,<ms>`, is written every interval while this push is the active one
    /// (see "The push keep-alive"); nil sends nothing but `PSI`, as before. `onKeepAliveFailure`
    /// gets the error of a keep-alive write that threw (from the keep-alive's task) or
    /// `PushRenewalRefused()` (from the actor's), once in all; that push's keep-alive then ends.
    /// Throws `invalidArgument` for an interval (either) under 1 ms.
    public func startPush(interval: Duration = .milliseconds(500), keepAlive: PushKeepAlive? = nil,
                          onKeepAliveFailure: (@Sendable (any Error) -> Void)? = nil) async throws -> AsyncStream<ScannerInfo> {
        try await startPushStream(interval: interval, keepAlive: keepAlive, onKeepAliveFailure: onKeepAliveFailure) { $0.info }
    }

    /// Like `startPush` (same `PSI` subscription, keep-alive, buffering, and stop rules; starting
    /// either replaces the other), but each update carries the instant the router received it.
    public func startPushUpdates(interval: Duration = .milliseconds(500), keepAlive: PushKeepAlive? = nil,
                                 onKeepAliveFailure: (@Sendable (any Error) -> Void)? = nil) async throws -> AsyncStream<PushUpdate> {
        try await startPushStream(interval: interval, keepAlive: keepAlive, onKeepAliveFailure: onKeepAliveFailure) { $0 }
    }

    private func startPushStream<Element: Sendable>(
        interval: Duration, keepAlive: PushKeepAlive?, onKeepAliveFailure: (@Sendable (any Error) -> Void)?,
        transform: @escaping @Sendable (PushUpdate) -> Element
    ) async throws -> AsyncStream<Element> {
        guard interval >= .milliseconds(1) else {
            throw ScannerClientError.invalidArgument("push interval must be at least 1 ms, got \(interval)")
        }
        if let keepAlive, keepAlive.interval < .milliseconds(1) {
            throw ScannerClientError.invalidArgument("keep-alive interval must be at least 1 ms, got \(keepAlive.interval)")
        }
        let ms = interval.components.seconds * 1000 + interval.components.attoseconds / 1_000_000_000_000_000
        let command = try ScannerCommand("PSI", String(ms))
        // A renewal writes exactly the `PSI` this push writes.
        let keepAliveCommand = try keepAlive.map { keepAlive -> ScannerCommand in
            switch keepAlive.action {
            case .command(let name): try ScannerCommand(name)
            case .renewSubscription: command
            }
        }
        guard isConnected else { throw ScannerClientError.notConnected }
        while true {
            if let stopping = pushStopping {
                // Let an earlier stream's PSI,0 go out first, so it can't stop this push.
                await stopping.value
                guard isConnected else { throw ScannerClientError.notConnected }
            }
            finishPush()
            // An older renewal already being written lands before this `PSI`, never after it (it
            // would put the scanner back on the older rate). Then look again: a stop or another
            // push may have come meanwhile.
            let renewals = keepAliveLoops.filter { renewalsBeingWritten.contains($0.key) }.map(\.value)
            guard !renewals.isEmpty else { break }
            startsAwaitingRenewals += 1
            for loop in renewals { await loop.value }
            startsAwaitingRenewals -= 1
            guard isConnected else { throw ScannerClientError.notConnected }
        }
        let (stream, continuation) = AsyncStream.makeStream(
            of: Element.self, bufferingPolicy: .bufferingNewest(64))
        push = PushSink(yield: { continuation.yield(transform($0)) }, finish: { continuation.finish() })
        pushGeneration += 1
        let generation = pushGeneration
        continuation.onTermination = { [weak self] termination in
            // .finished comes from our own finishPush(); only a consumer cancel or drop is news.
            guard case .cancelled = termination, let self else { return }
            Task { await self.pushConsumerCancelled(generation: generation) }
        }
        CommandTrace.log("send \(CommandTrace.describe(command))")
        do {
            try await transport.send(command)
        } catch {
            // Only tear down our own stream, not one a concurrent startPush installed meanwhile.
            if pushGeneration == generation { finishPush() }
            throw error
        }
        // Counted from the `PSI`; only while this push is still the active one (a stop, a
        // consumer cancel or a newer push may have come while it was written).
        if let keepAlive, let keepAliveCommand, pushGeneration == generation, push != nil, isConnected {
            let failure = KeepAliveFailureReport(onKeepAliveFailure)
            if keepAlive.action == .renewSubscription { renewal = (generation, false, failure) }
            startKeepAlive(keepAliveCommand, every: keepAlive.interval, from: .now, generation: generation,
                           failure: failure)
        }
        return stream
    }

    /// Sends `PSI,0` and finishes the push stream. A keep-alive write still on its way is
    /// written first; none follows.
    public func stopPush() async throws {
        guard isConnected else { throw ScannerClientError.notConnected }
        finishPush()
        let loops = endingKeepAlives
        guard !loops.isEmpty else {
            CommandTrace.log("send PSI,0")
            try await transport.send(ScannerCommand("PSI", "0"))
            return
        }
        // As `pushStopping`, so a `startPush` meanwhile waits for this `PSI,0` instead of being
        // stopped by it.
        let transport = self.transport
        let previous = pushStopping
        let stop = Task { () -> Result<Void, any Error> in
            await previous?.value
            for loop in loops { await loop.value }
            do {
                CommandTrace.log("send PSI,0")
                try await transport.send(ScannerCommand("PSI", "0"))
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        pushStopping = Task { _ = await stop.value }
        try await stop.value.get()
    }

    /// Finishes the push stream and cancels its keep-alive (which then writes nothing more,
    /// though a write already on its way completes: see `endingKeepAlives`).
    private func finishPush() {
        push?.finish()
        push = nil
        renewal = nil
        for loop in keepAliveLoops.values { loop.cancel() }
    }

    /// The keep-alive loops not yet ended, all cancelled once `finishPush()` has run: what a stop
    /// awaits before it writes `PSI,0` or closes the transport.
    private var endingKeepAlives: [Task<Void, Never>] { Array(keepAliveLoops.values) }

    /// The keep-alive loop of push `generation`. It holds the client only while a write is being
    /// made (its wait for the request slot included), never across its sleep, so a client let go
    /// of without `disconnect()` stops it. A write that threw is handed to `failure` as the loop
    /// ends (which reports it unless the push has already reported a refused renewal).
    private func startKeepAlive(_ command: ScannerCommand, every interval: Duration,
                                from start: ContinuousClock.Instant, generation: UInt64,
                                failure: KeepAliveFailureReport) {
        let sleepUntil = self.sleepUntil
        keepAliveLoops[generation] = Task { [weak self] in
            var due = start + interval
            writing: while true {
                do {
                    try await sleepUntil(due)
                } catch {
                    break  // Cancelled: the push ended.
                }
                guard let client = self else { break }
                switch await client.writeKeepAlive(command, generation: generation) {
                case .written:
                    // The next one a whole interval after this write, however late this one was.
                    due = ContinuousClock.now + interval
                case .ended:
                    break writing
                case .failed(let error):
                    failure.report(error)
                    break writing
                }
            }
            await self?.keepAliveEnded(generation: generation)
        }
    }

    private enum KeepAliveWrite {
        case written
        /// The push has ended (or the loop was cancelled, or the client disconnected): nothing written.
        case ended
        /// The write threw; never retried.
        case failed(any Error)
    }

    /// One keep-alive write, made holding the request slot, so it never goes out while a reply is
    /// pending. Once the slot is held (other requests may have run meanwhile), it writes only if
    /// push `generation` is still the active one on a connected client and its loop (the calling
    /// task) hasn't been cancelled.
    private func writeKeepAlive(_ command: ScannerCommand, generation: UInt64) async -> KeepAliveWrite {
        await acquireSlot()
        defer { releaseSlot() }
        guard !Task.isCancelled, isConnected, push != nil, generation == pushGeneration else { return .ended }
        // Marked before the write: a rejection that arrives while it is on its way is the renewal's.
        if renewal?.generation == generation {
            renewal?.begun = true
            renewalsBeingWritten.insert(generation)
        }
        defer { renewalsBeingWritten.remove(generation) }
        CommandTrace.log("send \(CommandTrace.describe(command)) (keep-alive)")
        do {
            try await transport.send(command)
            return .written
        } catch {
            return .failed(error)
        }
    }

    private func keepAliveEnded(generation: UInt64) {
        keepAliveLoops[generation] = nil
    }

    /// The consumer cancelled or dropped push stream `generation`. If it is still the active
    /// push, finish it and send `PSI,0`; a newer push or a teardown already handled it otherwise.
    private func pushConsumerCancelled(generation: UInt64) {
        guard generation == pushGeneration, push != nil, isConnected else { return }
        finishPush()
        let loops = endingKeepAlives
        let transport = self.transport
        let previous = pushStopping
        pushStopping = Task {
            await previous?.value
            // A keep-alive still being written goes first; none follows the `PSI,0`.
            for loop in loops { await loop.value }
            guard let stop = try? ScannerCommand("PSI", "0") else { return }
            CommandTrace.log("send PSI,0")
            try? await transport.send(stop)
        }
    }

    // MARK: Routing

    private func route(_ response: ScannerResponse, receivedAt: ContinuousClock.Instant) {
        if case .xml("PSI", let root) = response {
            if CommandTrace.isOn {
                let gap = lastPushAt.map { CommandTrace.milliseconds(since: $0) }
                CommandTrace.log("push after \(gap.map(String.init) ?? "-") ms since previous push")
            }
            lastPushAt = .now
            if let info = try? ScannerInfo(xml: root) { push?.yield(PushUpdate(info: info, receivedAt: receivedAt)) }
            return
        }
        if response.command == "PSI", case .rejected = response.status {
            if push != nil, let renewal, renewal.generation == pushGeneration, renewal.begun {
                // The renewal's: the earlier subscription still runs, so the push stays (its stop
                // writes `PSI,0`), and only its renewals end.
                keepAliveLoops[renewal.generation]?.cancel()
                renewal.failure.report(PushRenewalRefused())
            } else {
                finishPush()
            }
        }
        guard let current = pending, current.name == response.command else {
            CommandTrace.log("unmatched \(response.command) \(CommandTrace.shape(response))")
            return
        }
        CommandTrace.log("reply \(response.command) \(CommandTrace.shape(response)) after \(CommandTrace.milliseconds(since: current.sentAt)) ms")
        resolvePending(.success(response), id: current.id)
    }

    /// The transport's stream ended without `disconnect()`: the link is gone, so tear down
    /// without sending `PSI,0`. Queued requests see the non-connected state and throw.
    private func responsesEnded(generation: UInt64) async {
        guard generation == routerGeneration, isConnected else { return }
        finishPush()
        let loops = endingKeepAlives
        resolvePending(.failure(ScannerClientError.notConnected))
        routerTask = nil
        let transport = self.transport
        let teardown = Task {
            for loop in loops { await loop.value }
            await transport.close()
        }
        state = .disconnecting(teardown)
        await teardown.value
        if case .disconnecting = state { state = .disconnected }
    }

    private func resolvePending(_ result: Result<ScannerResponse, any Error>, id: UInt64? = nil) {
        guard var current = pending, id == nil || current.id == id, !current.resolved else { return }
        current.resolved = true
        if let continuation = current.continuation {
            current.continuation = nil
            continuation.resume(with: result)
        } else {
            current.result = result
        }
        pending = current
    }

    private func awaitReply(id: UInt64) async throws -> ScannerResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ScannerResponse, any Error>) in
                guard var current = pending, current.id == id else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let result = current.result {
                    current.result = nil
                    pending = current
                    continuation.resume(with: result)
                } else {
                    current.continuation = continuation
                    pending = current
                }
            }
        } onCancel: {
            Task { await self.resolvePending(.failure(CancellationError()), id: id) }
        }
    }

    // MARK: Slot

    /// Requests (and keep-alive writes) waiting for the slot, the one holding it not counted. For tests: one that
    /// holds the slot with a read the mock never answers can wait for another request to queue behind it.
    var requestsWaitingForTheSlot: Int { slotWaiters.count }

    private func acquireSlot() async {
        guard slotBusy else {
            slotBusy = true
            return
        }
        // Ownership is handed over directly by releaseSlot, so slotBusy stays true.
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            slotBusy = false
        } else {
            slotWaiters.removeFirst().resume()
        }
    }
}
