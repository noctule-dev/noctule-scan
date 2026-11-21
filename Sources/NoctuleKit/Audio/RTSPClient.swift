// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization

/// An RTSP control connection (TCP over a plain BSD socket, `TCPStream`) to the scanner's audio
/// server. Network.framework sending the same bytes hung the SDS200 (LESSONS.md, 2026-11-08), so
/// this mirrors the proven Python client, including its close: on every graceful close of an
/// open connection, wait `closeLinger`, `shutdown(SHUT_WR)`, drain until EOF (at most 1 s), then
/// `close()`.
///
/// One request is in flight at a time; later callers queue in FIFO order. Every request carries
/// `CSeq` (counting up from 1 per client) and, after SETUP, `Session`. Replies are matched by CSeq:
///
/// - A reply with the pending request's CSeq answers it. A non-2xx status throws `unexpectedStatus`;
///   the connection stays usable.
/// - No reply within `requestTimeout` throws `.timeout(method:)`. The connection stays usable (so a
///   session can still be torn down), and a late reply to that CSeq is dropped when it arrives.
/// - A reply with any other CSeq throws `.cseqMismatch`, and an unparseable reply throws
///   `.malformed`. Both are protocol errors: the connection is closed.
/// - If the server closes the connection or it fails, the pending request throws `.closed`.
///
/// `teardown()` pre-empts: an in-flight request fails at once with `.preempted`. After a protocol
/// error, a TCP close, or `close()`, every request throws `.closed` until `connect()` opens a new
/// connection (`teardown()` still reconnects briefly to end a session; see there). Before the first `connect()`, requests throw `.closed`.
///
/// **Always call `close()`** when done, on every path (errors, cancellation, SIGINT). Dropping
/// the client without it sends no TEARDOWN, so the scanner may keep streaming to a dead port, and
/// records no close in `cooldownStore`, so the next connection can come too soon and hang the
/// SDS200's audio server (protocol notes §6).
///
/// **Clean closes.** Each recorded close carries whether it was clean (`RTSPCooldownPolicy`): only
/// `close()` of a connection this client opened, on which a SETUP issued a session, every
/// TEARDOWN got a 2xx reply and every request got a reply, with nothing left to tear down.
/// Failed connects, connections the server closed or that failed, protocol errors, a request
/// that timed out or was abandoned, a connection that never had a session, and a teardown's
/// reconnect are all unclean, so the next connect waits `cooldownPolicy.full`. The client's own
/// record of its closes keeps the latest unclean close apart, so a clean close never hides it.
public actor RTSPClient {
    public let host: String
    public let port: UInt16
    public let path: String
    public let requestTimeout: Duration
    public private(set) var sessionID: String?
    /// The `timeout=` the latest SETUP reply's `Session` header gave, if any.
    public private(set) var sessionTimeoutSeconds: Int?
    /// The IP literal of the connected server (no brackets, no scope), used as the authority of
    /// every request URL instead of `host`. Set by `connect()`.
    public private(set) var remoteAddress: String?
    /// The status code of every TEARDOWN reply received, oldest first. `teardown()` never throws,
    /// so this is how a caller (or a hardware test) checks that the server acknowledged it.
    public private(set) var teardownStatuses: [Int] = []
    /// The minimum gap between one TCP connection to the server closing and the next opening:
    /// `cooldownPolicy.full` after an unclean close, `afterCleanClose` after a clean one.
    public let cooldownPolicy: RTSPCooldownPolicy
    /// Whether the latest close this client recorded was clean (see `RTSPCooldownPolicy`), or nil
    /// if it has recorded none. Set when the close is begun, before the store has it.
    public private(set) var lastCloseWasClean: Bool?
    public let cooldownStore: any RTSPCooldownStore
    /// Session ids that `teardown()` could not end: their TEARDOWN went unanswered (timed out, or
    /// was pre-empted by another teardown) on an open connection, or the connection died and
    /// reconnecting was not allowed (cooldown) or failed. Only an answered TEARDOWN (any status)
    /// counts as done. A later connection may retry them with `teardown(sessionIDs:)` (which
    /// `AudioSession` does after OPTIONS). The scanner may need a restart; callers should surface this.
    public private(set) var unreleasedSessions: [String] = []

    private struct Link {
        let stream: TCPStream
        let receiver: Task<Void, Never>
        /// The server's IP literal, used as the request authority.
        let address: String
        /// Every cooldown key this connection leased (`cooldownKeys()` plus `address`); its close
        /// is recorded under each, which also clears the lease.
        let keys: [String]
    }

    /// Closes this client has made (when, and whether clean), by cooldown key, so its own
    /// cooldown never depends on the store's write having landed.
    private var localCloses: [String: RTSPCloseHistory] = [:]
    /// Whether a SETUP reply on the current connection issued a session (a connection that never
    /// had one never closes clean: the "health-check connection" hang, LESSONS.md 2026-11-08).
    private var linkHadSession = false
    /// Whether a TEARDOWN on the current connection got a non-2xx reply, or any request on it
    /// went unanswered (timed out, or was cancelled or pre-empted before its reply). An answered
    /// non-2xx reply to anything but TEARDOWN (a keepalive 454) doesn't count.
    private var linkExchangeFailed = false
    /// Whether OPTIONS has been answered on the current connection.
    private var optionsSent = false
    /// The connect attempt in flight, shared by every concurrent `connect()`.
    private var connecting: (id: UInt64, task: Task<Void, any Error>)?
    private var nextConnectAttempt: UInt64 = 0
    /// Socket closes and store writes, chained so they happen in order; `connect()` and
    /// `close()` wait for them.
    private var recording: Task<Void, Never>?

    private enum State {
        /// Never connected, or closed by `close()`.
        case idle
        case open(Link)
        /// Closed by the server, a network failure, or a protocol error.
        case dead
    }

    /// The request currently holding the slot. A one-shot mailbox: the reply (or failure) may
    /// arrive before the requester starts waiting, and is kept until it does.
    private struct Pending {
        let cseq: Int
        let method: String
        /// A reply with this CSeq arrived (even if the requester has stopped waiting).
        var replied = false
        var result: Result<RTSPResponse, any Error>?
        var continuation: CheckedContinuation<RTSPResponse, any Error>?
        var resolved = false
    }

    private var state: State = .idle
    /// Bumped by every successful connect and by `close()`, so stale receivers and
    /// half-finished connects can tell they've been superseded.
    private var generation: UInt64 = 0
    private var parser = RTSPResponseParser()
    private var nextCSeq = 0
    private var pending: Pending?
    /// CSeq → method of requests that timed out, were cancelled, or were pre-empted before a
    /// reply arrived. Their late replies are dropped, except that a SETUP's session is kept.
    private var abandoned: [Int: String] = [:]
    /// Every session id the server has issued that hasn't been torn down yet: the current
    /// `sessionID`, plus any from SETUP replies whose caller gave up (timeout or cancellation).
    private var heldSessions: [String] = []
    private var base: String?

    private var slotBusy = false
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    /// How long every graceful close of an open connection waits before `shutdown(SHUT_WR)`,
    /// as the proven reference client does (0.5 s), whether or not a TEARDOWN was answered.
    public let closeLinger: Duration

    public init(host: String, port: UInt16 = 554, path: String = "/au:scanner.au",
                requestTimeout: Duration = .seconds(3), cooldownPolicy: RTSPCooldownPolicy = .standard,
                cooldownStore: any RTSPCooldownStore = InMemoryRTSPCooldownStore.shared,
                closeLinger: Duration = .milliseconds(500)) {
        self.host = host; self.port = port; self.path = path; self.requestTimeout = requestTimeout
        self.cooldownPolicy = cooldownPolicy; self.cooldownStore = cooldownStore
        self.closeLinger = closeLinger
    }

    /// The same `reconnectCooldown` after every close, clean or not (`RTSPCooldownPolicy.symmetric`).
    public init(host: String, port: UInt16 = 554, path: String = "/au:scanner.au",
                requestTimeout: Duration = .seconds(3), reconnectCooldown: Duration,
                cooldownStore: any RTSPCooldownStore = InMemoryRTSPCooldownStore.shared,
                closeLinger: Duration = .milliseconds(500)) {
        self.init(host: host, port: port, path: path, requestTimeout: requestTimeout,
                  cooldownPolicy: .symmetric(reconnectCooldown), cooldownStore: cooldownStore,
                  closeLinger: closeLinger)
    }

    /// `rtsp://<host>[:<port>]<path>`, omitting the port when it is the RTSP default 554.
    static func requestURL(host: String, port: UInt16, path: String) -> String {
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return port == 554 ? "rtsp://\(hostPart)\(path)" : "rtsp://\(hostPart):\(port)\(path)"
    }

    /// Uses `remoteAddress`, never a DNS name, matching the request shape that works on the SDS200
    /// (protocol notes §6; LESSONS.md, 2026-11-08).
    private var describeURL: String { Self.requestURL(host: remoteAddress ?? host, port: port, path: path) }
    private var controlBase: String { base ?? describeURL + "/" }

    private var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    // MARK: Connection

    /// Opens the TCP connection (a BSD socket; non-blocking connect bounded by `requestTimeout`)
    /// and records the connected IP in `remoteAddress`.
    /// Throws `.timeout(method: "CONNECT")` if the server doesn't answer in time, or `.closed` if
    /// the connection is refused, unreachable, or `close()` is called meanwhile.
    /// Throws `.cooldown(remaining:)`, without opening a socket, if any connection to this server
    /// (per `cooldownStore`, or this client's own record) closed too recently by
    /// `cooldownPolicy.remaining(after:)` (the full value since the latest unclean close, and the
    /// latest close's own wait; a clean close never hides an unclean one), or another live process
    /// holds the server's lease. The check and the lease are one atomic `cooldownStore.claim`, so
    /// two processes can't both pass it. Throws `.cooldownStoreUnavailable` if the store can't
    /// lock its record (it then can't vouch that connecting is safe). Every connection's close,
    /// including failed attempts and connections that died, is recorded there, after the socket
    /// is closed. A connection still closing is waited for first, so two never overlap.
    ///
    /// Single-flight: a `connect()` that arrives while another (or `teardown()`'s reconnect) is
    /// in progress waits for that attempt and shares its outcome, so concurrent callers never
    /// open more than one TCP connection. Cancelling the caller that started the attempt
    /// cancels it for everyone waiting on it.
    public func connect() async throws {
        _ = try await connectSharingAttempt()
    }

    /// Joins the connect attempt in flight, or starts one. Returns true only if this call
    /// started the attempt that opened the connection.
    private func connectSharingAttempt() async throws -> Bool {
        if isOpen { return false }
        if let inFlight = connecting {
            try await inFlight.task.value
            return false
        }
        nextConnectAttempt += 1
        let id = nextConnectAttempt
        let task = Task {
            do {
                try await self.openConnection()
                self.finishConnectAttempt(id)
            } catch {
                self.finishConnectAttempt(id)
                throw error
            }
        }
        connecting = (id, task)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        return true
    }

    private func finishConnectAttempt(_ id: UInt64) {
        if connecting?.id == id { connecting = nil }
    }

    /// One connection attempt; only `connectSharingAttempt()` calls it.
    private func openConnection() async throws {
        if isOpen { return }
        guard port != 0 else { throw RTSPError.closed }
        await recording?.value
        // Checked before any socket exists: a connection opened too soon after the last one
        // closed hangs the SDS200's audio server (protocol notes §6). The store's check and the
        // crash lease are one atomic claim, so another process can't slip in between; if this
        // process dies without recording the close, the next process treats the connection as
        // closed when it finds the lease (or as open while this process lives). Every close of
        // this attempt (`noteClosed`, `closeStream`) clears it.
        let keys = await cooldownKeys()
        if let remaining = localCooldownRemaining(keys: keys) { throw RTSPError.cooldown(remaining: remaining) }
        switch await cooldownStore.claim(hosts: keys, pid: getpid(), policy: cooldownPolicy) {
        case .claimed: break
        case .wait(let remaining): throw RTSPError.cooldown(remaining: remaining)
        case .unavailable(let reason): throw RTSPError.cooldownStoreUnavailable(reason)
        }
        if isOpen { return }
        let startGeneration = generation
        let stream: TCPStream
        do {
            stream = try await TCPStream.connect(host: host, port: port, timeout: requestTimeout)
        } catch {
            noteClosed(keys)  // the attempt may have reached the server
            await recording?.value
            switch error {
            case POSIXSocketError.connectTimedOut: throw RTSPError.timeout(method: "CONNECT")
            case is CancellationError: throw error
            default: throw RTSPError.closed
            }
        }
        // The IP actually connected to becomes the URL authority (see `describeURL`).
        let literal = stream.remoteAddress
        var leased = keys
        if !keys.contains(literal) {
            // Resolution gave a different address than the connect used: lease it too.
            await cooldownStore.recordOpened(host: literal, at: Date(), pid: getpid())
            leased.append(literal)
        }
        // Another connect() finished first, or close() ran meanwhile.
        guard !isOpen, generation == startGeneration else {
            closeStream(stream, keys: leased, linger: closeLinger)
            if isOpen { return }
            throw RTSPError.closed
        }
        generation += 1
        let generation = self.generation
        remoteAddress = literal
        optionsSent = false
        parser = RTSPResponseParser()
        abandoned = [:]
        base = nil
        let incoming = stream.incoming
        let receiver = Task { [weak self] in
            for await data in incoming {
                guard let self else { return }
                await self.deliver(data, generation: generation)
            }
            await self?.connectionEnded(generation: generation)
        }
        linkHadSession = false
        linkExchangeFailed = false
        state = .open(Link(stream: stream, receiver: receiver, address: literal, keys: leased))
    }

    /// Tears down any session (best effort), waiting for every teardown worker to finish (so
    /// `unreleasedSessions` is final), then closes the connection gracefully (see the type's
    /// notes) and records the close in `cooldownStore` before returning, as clean only if
    /// `isCleanClose` (see `RTSPCooldownPolicy`).
    public func close() async {
        await teardown()
        // Every worker is bounded internally (each wait and request by `requestTimeout`). Waiting
        // for them all means `unreleasedSessions` is final when close() returns.
        while let worker = teardownWorkers.values.first { await worker.value }
        generation += 1
        if case .open(let link) = state { closeLink(link, clean: isCleanClose) }
        state = .idle
        resolvePending(.failure(RTSPError.closed))
        // The socket is closed, and the close visible to other clients sharing the store.
        await recording?.value
    }

    // MARK: RTSP methods

    /// OPTIONS to the aggregate URL; returns the methods in the reply's `Public` header.
    /// `describe()` sends it first automatically if this connection hasn't yet: OPTIONS, then
    /// DESCRIBE, is the sequence the SDS200 answers reliably (protocol notes §6).
    public func options() async throws -> [String] {
        guard isOpen else { throw RTSPError.closed }
        let response = try await request("OPTIONS", url: describeURL, headers: [])
        optionsSent = true
        return (response.header("public") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// DESCRIBE with `Accept: application/sdp`, preceded by OPTIONS on a fresh connection. `base` is the reply's `Content-Base`, or the
    /// request URL plus "/" if there is none; PLAY, GET_PARAMETER, and TEARDOWN go to it.
    public func describe() async throws -> (base: String, sdp: SDPAudioDescription) {
        guard isOpen else { throw RTSPError.closed }
        if !optionsSent { _ = try await options() }
        let url = describeURL
        let response = try await request("DESCRIBE", url: url, headers: [("Accept", "application/sdp")])
        let sdp = try SDPAudioDescription.parse(String(decoding: response.body, as: UTF8.self))
        let contentBase = response.header("content-base").flatMap { $0.isEmpty ? nil : $0 }
        let base = contentBase ?? url + "/"
        self.base = base
        return (base, sdp)
    }

    /// SETUP with `Transport: RTP/AVP;unicast;client_port=<clientPort>`. Stores and returns the
    /// session id; throws `.noSession` if the reply has none. If the caller gives up (timeout or
    /// cancellation) after the request went out, a late reply's session is still remembered so
    /// `teardown()` ends it.
    public func setup(controlURL: String, clientPort: UInt16) async throws -> String {
        guard isOpen else { throw RTSPError.closed }
        let response = try await request(
            "SETUP", url: controlURL, headers: [("Transport", "RTP/AVP;unicast;client_port=\(clientPort)")])
        guard let session = response.session else { throw RTSPError.noSession }
        sessionID = session.id
        sessionTimeoutSeconds = session.timeoutSeconds
        return session.id
    }

    /// PLAY with `Session` and `Range: npt=0.000-`. The session is read when the request gets
    /// its turn, so a PLAY queued behind a `teardown()` throws `.noSession` instead of going out.
    public func play() async throws {
        guard isOpen else { throw RTSPError.closed }
        guard sessionID != nil else { throw RTSPError.noSession }
        _ = try await request("PLAY", url: controlBase, headers: [("Range", "npt=0.000-")], session: .current)
    }

    /// GET_PARAMETER with the session, to keep it alive. Like `play()`, it reads the session
    /// when it gets its turn.
    public func keepalive() async throws {
        guard isOpen else { throw RTSPError.closed }
        guard sessionID != nil else { throw RTSPError.noSession }
        _ = try await request("GET_PARAMETER", url: controlBase, headers: [], session: .current)
    }

    /// Best effort: sends TEARDOWN for every session the server has issued (normally just
    /// `sessionID`, plus any from a SETUP whose caller gave up), once each. Clears `sessionID`
    /// at once and never throws. The work runs in its own task, so it still happens when the
    /// caller is cancelled; the wait lasts at most 4 × `requestTimeout`.
    ///
    /// - A request in flight fails at once with `.preempted` (its late reply is dropped), and
    ///   TEARDOWN goes ahead of any queued requests, which then see no session.
    /// - If a SETUP was abandoned and its reply hasn't arrived, waits for it (at most
    ///   `requestTimeout`) so its session can be torn down too.
    /// - RTSP sessions outlive their TCP connection. If the connection is dead, or dies before
    ///   TEARDOWN gets a reply, this reconnects once (bounded by `requestTimeout`), sends
    ///   TEARDOWN there, and closes that connection again; ordinary requests still throw `.closed`.
    ///   That reconnect obeys `cooldownPolicy` like any other (the dead connection's close was
    ///   unclean, so the full value): inside it (or if the reconnect fails) no connection is
    ///   opened and the ids go to `unreleasedSessions`. Every close involved is unclean.
    /// - A TEARDOWN that times out (or is pre-empted by another teardown) on a connection that is
    ///   still open is not resent there: its id goes to `unreleasedSessions`.
    public func teardown() async {
        if let id = sessionID { holdSession(id) }
        sessionID = nil
        guard !heldSessions.isEmpty || hasOutstandingSetup else { return }
        if isOpen, let current = pending, !current.resolved {
            linkExchangeFailed = true  // pre-empted before its reply
            abandoned[current.cseq] = current.method
            resolvePending(.failure(RTSPError.preempted))
        }
        let url = controlBase
        nextWorkerID += 1
        let id = nextWorkerID
        let worker = Task {
            await self.tearDownHeldSessions(url: url)
            self.teardownWorkers[id] = nil
        }
        teardownWorkers[id] = worker
        await Self.wait(for: worker, atMost: requestTimeout * 4)
    }

    /// Teardown workers still running (`teardown()` stops waiting after 4 × `requestTimeout`;
    /// `close()` waits for them all).
    private var teardownWorkers: [UInt64: Task<Void, Never>] = [:]
    private var nextWorkerID: UInt64 = 0

    /// Sends TEARDOWN, on the open connection, for session ids left over from an earlier
    /// connection (e.g. another client's `unreleasedSessions`), one at a time, each bounded by
    /// `requestTimeout`. If this connection hasn't sent OPTIONS yet, it sends OPTIONS first (and
    /// `describe()` won't repeat it): a TEARDOWN is never the first request on a connection, since
    /// that shape is unproven on the SDS200. If OPTIONS fails, no TEARDOWN is sent and it returns []. Returns the ids the server answered, with any status (recorded in
    /// `teardownStatuses`), which also leaves this client's `unreleasedSessions`. An unanswered
    /// one (timeout) is not returned; if the connection dies or the caller is cancelled, it stops.
    /// Never reconnects: without an open connection it sends nothing and returns [].
    public func teardown(sessionIDs ids: [String]) async -> [String] {
        guard isOpen, !ids.isEmpty else { return [] }
        if !optionsSent {
            do { _ = try await options() } catch { return [] }
        }
        let url = controlBase
        var done: [String] = []
        for id in ids {
            do {
                let response = try await request("TEARDOWN", url: url, headers: [], session: .id(id))
                teardownStatuses.append(response.statusCode)
                done.append(id)
            } catch RTSPError.unexpectedStatus(let code, _) {
                teardownStatuses.append(code)
                linkExchangeFailed = true
                done.append(id)
            } catch {
                linkExchangeFailed = true
                if error is CancellationError || !isOpen { break }
            }
        }
        unreleasedSessions.removeAll { done.contains($0) }
        return done
    }

    private var hasOutstandingSetup: Bool { isOpen && abandoned.values.contains("SETUP") }

    /// Whether closing the open connection now would be a clean close: a session was set up on
    /// it, every TEARDOWN sent on it got a 2xx reply, every request on it was answered (none is
    /// still waiting for its reply), and nothing is left to tear down (no held or current
    /// session, no SETUP whose reply might still issue one, no unreleased session).
    /// Only `close()` asks; every other close (the server's, a failure, a protocol error, a
    /// failed or superseded connect, a teardown's reconnect) is unclean.
    private var isCleanClose: Bool {
        isOpen && linkHadSession && !linkExchangeFailed && !hasUnansweredRequest && sessionID == nil
            && heldSessions.isEmpty && !hasOutstandingSetup && unreleasedSessions.isEmpty
    }

    /// A request has gone out and its reply hasn't arrived.
    private var hasUnansweredRequest: Bool {
        guard let pending else { return false }
        return !pending.replied
    }

    private func markUnreleased(_ ids: [String]) {
        for id in ids where !unreleasedSessions.contains(id) { unreleasedSessions.append(id) }
    }

    // MARK: Reconnect cooldown

    /// The keys `RTSPClient` files `host`'s cooldown and lease under: the host itself if it is an
    /// IP literal, otherwise the addresses it resolves to (bounded at 2 s) plus the name. Callers
    /// that read the cooldown store directly (e.g. a CLI waiting before it starts) must check
    /// every key.
    public static func cooldownKeys(for host: String) async -> [String] {
        Array(await RTPReceiver.addresses(for: host)).sorted()
    }

    /// The cooldown keys for this client's `host` (see `cooldownKeys(for:)`).
    private func cooldownKeys() async -> [String] { await Self.cooldownKeys(for: host) }

    /// How much longer `connect()` must wait by this client's own closes (which never depend on
    /// a store write having landed), or nil. The store is checked by `claim`.
    private func localCooldownRemaining(keys: [String]) -> Duration? {
        var merged: RTSPCloseHistory?
        for key in keys { merged = RTSPCloseHistory.merged(merged, localCloses[key]) }
        guard let merged else { return nil }
        return cooldownPolicy.remaining(after: merged)
    }

    /// Records that a connection attempt to the server (by each of `keys`) ended now, uncleanly
    /// (it never got as far as a session); its socket is already closed.
    private func noteClosed(_ keys: [String]) {
        let now = Date()
        lastCloseWasClean = false
        for key in keys { noteLocalClose(key, at: now, clean: false) }
        let previous = recording
        let store = cooldownStore
        recording = Task {
            await previous?.value
            for key in keys { await store.recordClosed(host: key, at: now, clean: false) }
        }
    }

    /// Closes `link`'s socket gracefully in the background, lingering `closeLinger` first (on
    /// every close of an open connection, as the reference client does), then records the close,
    /// as clean only if `clean` (only `close()` passes true, from `isCleanClose`).
    private func closeLink(_ link: Link, clean: Bool = false) {
        link.receiver.cancel()
        closeStream(link.stream, keys: link.keys, linger: closeLinger, clean: clean)
    }

    /// Closes `stream` (chained after earlier closes), then records the close time, taken after
    /// the socket is closed, and `clean`, under each of `keys`, locally and in `cooldownStore`
    /// (which clears this process's lease on each).
    private func closeStream(_ stream: TCPStream, keys: [String], linger: Duration, clean: Bool = false) {
        lastCloseWasClean = clean
        let previous = recording
        let store = cooldownStore
        recording = Task {
            await previous?.value
            await stream.close(linger: linger)
            let now = Date()
            for key in keys {
                self.noteLocalClose(key, at: now, clean: clean)
                await store.recordClosed(host: key, at: now, clean: clean)
            }
        }
    }

    private func noteLocalClose(_ key: String, at date: Date, clean: Bool) {
        localCloses[key] = RTSPCloseHistory(RTSPCloseRecord(at: date, clean: clean)).merged(with: localCloses[key])
    }

    private func holdSession(_ id: String) {
        if !heldSessions.contains(id) { heldSessions.append(id) }
    }

    private func tearDownHeldSessions(url: String) async {
        let deadline = ContinuousClock.now + requestTimeout
        while hasOutstandingSetup, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        // Take the list, so a concurrent teardown() never sends the same id twice.
        var remaining = heldSessions
        heldSessions = []
        if isOpen {
            while let id = remaining.first {
                if await sendTeardown(id: id, url: url) { remaining.removeFirst() } else { break }
            }
        }
        if !remaining.isEmpty { await reconnectAndTearDown(ids: remaining, url: url) }
    }

    /// Sends one TEARDOWN. Returns false only if the connection died before a reply, so the
    /// caller should try again on a fresh connection. Any other failure on a still-open
    /// connection (a timeout, or being pre-empted by another teardown) is not resent on this
    /// connection, and the id goes to `unreleasedSessions` rather than counting as done.
    private func sendTeardown(id: String, url: String) async -> Bool {
        do {
            let response = try await request("TEARDOWN", url: url, headers: [], session: .id(id), preempting: true)
            teardownStatuses.append(response.statusCode)
            return true
        } catch RTSPError.unexpectedStatus(let code, _) {
            teardownStatuses.append(code)
            linkExchangeFailed = true
            return true
        } catch {
            guard isOpen else { return false }
            linkExchangeFailed = true
            markUnreleased([id])
            return true
        }
    }

    private func reconnectAndTearDown(ids: [String], url: String) async {
        let opened: Bool
        do {
            opened = try await connectSharingAttempt()
        } catch {
            // Inside the cooldown (or unreachable): never force a connection. Report instead.
            markUnreleased(ids)
            return
        }
        let generation = self.generation
        for (index, id) in ids.enumerated() {
            guard await sendTeardown(id: id, url: url) else {
                markUnreleased(Array(ids[index...]))
                break
            }
        }
        // Leave the client dead, unless the connection was a caller's own connect() (which this
        // joined or found open) or something else has reconnected meanwhile.
        guard opened, generation == self.generation, case .open = state else { return }
        self.generation += 1
        markDead(RTSPError.closed)
    }

    // MARK: Requests

    private enum SessionHeader {
        case none
        /// The current `sessionID`, read once the request has the slot; `.noSession` if nil.
        case current
        case id(String)
    }

    private func request(
        _ method: String, url: String, headers: [(String, String)],
        session: SessionHeader = .none, preempting: Bool = false
    ) async throws -> RTSPResponse {
        guard isOpen else { throw RTSPError.closed }
        await acquireSlot(first: preempting)
        defer { releaseSlot() }
        guard case .open(let link) = state else { throw RTSPError.closed }
        try Task.checkCancellation()

        var headers = headers
        switch session {
        case .none: break
        case .current:
            guard let id = sessionID else { throw RTSPError.noSession }
            headers.insert(("Session", id), at: 0)
        case .id(let id):
            headers.insert(("Session", id), at: 0)
        }

        nextCSeq += 1
        let cseq = nextCSeq
        let generation = self.generation
        pending = Pending(cseq: cseq, method: method)
        defer { if pending?.cseq == cseq { pending = nil } }

        let bytes = RTSPRequest(method: method, url: url, cseq: cseq, headers: headers).encoded
        let stream = link.stream
        let timeout = requestTimeout
        let response: RTSPResponse
        do {
            response = try await withThrowingTaskGroup(of: RTSPResponse.self) { group in
                group.addTask {
                    try await stream.send(bytes)
                    return try await self.awaitReply(cseq: cseq)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw RTSPError.timeout(method: method)
                }
                // Leaving the scope cancels the loser; awaitReply's cancellation handler resolves
                // the mailbox, so the group never waits on a suspended continuation.
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw RTSPError.timeout(method: method) }
                return first
            }
        } catch let error as RTSPError {
            if case .timeout = error {
                abandon(cseq: cseq, method: method)
                if generation == self.generation { linkExchangeFailed = true }
            }
            throw error
        } catch is CancellationError {
            abandon(cseq: cseq, method: method)
            if generation == self.generation { linkExchangeFailed = true }
            throw CancellationError()
        } catch {
            // The send failed: the connection is gone.
            if generation == self.generation { markDead(RTSPError.closed) }
            throw RTSPError.closed
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RTSPError.unexpectedStatus(response.statusCode, response.reason)
        }
        return response
    }

    /// The requester stopped waiting. Unless the reply already arrived, remember the CSeq so the
    /// late reply is dropped (and, for SETUP, its session kept).
    private func abandon(cseq: Int, method: String) {
        if let current = pending, current.cseq == cseq, current.replied { return }
        abandoned[cseq] = method
    }

    private func deliver(_ data: Data, generation: UInt64) {
        guard generation == self.generation, isOpen else { return }
        for response in parser.feed(data) {
            route(response)
            guard isOpen else { return }
        }
        if let problem = parser.protocolError { markDead(RTSPError.malformed(problem)) }
    }

    private func route(_ response: RTSPResponse) {
        let cseq = response.cseq
        let method = cseq.flatMap { abandoned[$0] } ?? (pending.flatMap { $0.cseq == cseq ? $0.method : nil })
        // Whoever is (or isn't) waiting, a session the server issued must be torn down later.
        if method == "SETUP", (200..<300).contains(response.statusCode), let session = response.session {
            holdSession(session.id)
            linkHadSession = true
        }
        if let cseq, abandoned.removeValue(forKey: cseq) != nil { return }
        // Nothing is waiting: an unsolicited reply. Ignore it.
        guard var current = pending else { return }
        if response.cseq == current.cseq {
            // Mark it even if the requester is already giving up (cancelled), so it doesn't
            // record the CSeq as abandoned and leave teardown() waiting for a reply that came.
            current.replied = true
            pending = current
            resolvePending(.success(response))
        } else if !current.resolved {
            markDead(RTSPError.cseqMismatch(expected: current.cseq, got: response.cseq))
        }
    }

    private func connectionEnded(generation: UInt64) {
        guard generation == self.generation, isOpen else { return }
        markDead(RTSPError.closed)
    }

    /// Closes the connection after a failure; the pending request gets `error`, later ones `.closed`.
    private func markDead(_ error: RTSPError) {
        if case .open(let link) = state { closeLink(link) }
        state = .dead
        resolvePending(.failure(error))
    }

    private func resolvePending(_ result: Result<RTSPResponse, any Error>, cseq: Int? = nil) {
        guard var current = pending, cseq == nil || current.cseq == cseq, !current.resolved else { return }
        current.resolved = true
        if let continuation = current.continuation {
            current.continuation = nil
            continuation.resume(with: result)
        } else {
            current.result = result
        }
        pending = current
    }

    private func awaitReply(cseq: Int) async throws -> RTSPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTSPResponse, any Error>) in
                guard var current = pending, current.cseq == cseq else {
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
            Task { await self.resolvePending(.failure(CancellationError()), cseq: cseq) }
        }
    }

    // MARK: Slot

    /// `first` jumps the queue (TEARDOWN pre-empting queued requests).
    private func acquireSlot(first: Bool = false) async {
        guard slotBusy else {
            slotBusy = true
            return
        }
        // Ownership is handed over directly by releaseSlot, so slotBusy stays true.
        await withCheckedContinuation { continuation in
            if first { slotWaiters.insert(continuation, at: 0) } else { slotWaiters.append(continuation) }
        }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            slotBusy = false
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    // MARK: Helpers

    /// Waits for `task` to finish, but at most `limit`. Ignores the caller's cancellation,
    /// so a cancelled caller still gets the bounded wait (and `task` is never cancelled).
    private static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
        let once = OneShot<Void>()
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            once.install(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.resume(.success(()))
            }
            Task {
                await task.value
                timer.cancel()
                once.resume(.success(()))
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever result comes first. A result that arrives
/// before the continuation is installed is kept for it.
private final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, any Error>?
        var done = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let pending: Result<Value, any Error>? = state.withLock { state in
            if let result = state.result {
                state.result = nil
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func resume(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            guard !state.done else { return nil }
            state.done = true
            if let continuation = state.continuation {
                state.continuation = nil
                return continuation
            }
            state.result = result
            return nil
        }
        continuation?.resume(with: result)
    }
}
