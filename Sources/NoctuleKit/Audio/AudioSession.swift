// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// One decoded RTP packet: 16-bit PCM at 8 kHz mono.
public struct AudioChunk: Sendable {
    public var samples: [Int16]
    public var rtpTimestamp: UInt32
    public var sequence: UInt16
    public var receivedAt: ContinuousClock.Instant
    /// The RTP stream's SSRC. A change means a new stream (the scanner restarted it).
    public var ssrc: UInt32
    /// Packets the sequence tracker counted missing immediately before this one (a forward
    /// sequence gap within the same SSRC), or 0. Packets that arrive late (reordered or stale)
    /// or twice are never yielded, so a gap reported here is never filled afterwards.
    public var lostBefore: Int
    /// True when the sequence restarted at this chunk (a new SSRC, a jump of more than 3000, or
    /// a run of stale packets; see `RTPSequenceTracker`) after earlier chunks: how much audio is
    /// missing before it is unknown, and `lostBefore` is 0. False for the session's first chunk.
    public var discontinuity: Bool

    public init(samples: [Int16], rtpTimestamp: UInt32, sequence: UInt16, receivedAt: ContinuousClock.Instant,
                ssrc: UInt32 = 0, lostBefore: Int = 0, discontinuity: Bool = false) {
        self.samples = samples; self.rtpTimestamp = rtpTimestamp; self.sequence = sequence; self.receivedAt = receivedAt
        self.ssrc = ssrc; self.lostBefore = lostBefore
        self.discontinuity = discontinuity
    }
}

public enum AudioSessionState: Sendable, Equatable {
    case idle, starting, streaming, recovering(attempt: Int), failed(String), stopped
}

/// What the owner can do about a `failed` session, from a control-channel probe at failure time.
public enum RestartHint: Sendable, Equatable {
    /// The scanner still answers on the control channel, so a remote restart (`MSM,1`) can work.
    /// Offer it, and only after explicit user confirmation.
    case canRestart
    /// The control channel is silent too: the scanner's network stack is hung. Only a power cycle helps.
    case powerCycleNeeded
}

public enum AudioSessionError: Error, Equatable, Sendable {
    /// The scanner's SDP offered a payload type other than 0 (PCMU).
    case unsupportedPayloadType(Int)
    /// `start()` was called on a session that has already started (or stopped).
    case alreadyStarted
    /// `stop()` ran while `start()` was in progress.
    case stopped
}

/// What `AudioSession` hands its RTSP client factory for each new connection.
public struct RTSPClientOptions: Sendable {
    public var host: String
    public var port: UInt16
    public var requestTimeout: Duration
    public var cooldownPolicy: RTSPCooldownPolicy
    public var cooldownStore: any RTSPCooldownStore

    public init(host: String, port: UInt16, requestTimeout: Duration, cooldownPolicy: RTSPCooldownPolicy,
                cooldownStore: any RTSPCooldownStore) {
        self.host = host; self.port = port; self.requestTimeout = requestTimeout
        self.cooldownPolicy = cooldownPolicy; self.cooldownStore = cooldownStore
    }

    /// A symmetric policy: the same `reconnectCooldown` after every close.
    public init(host: String, port: UInt16, requestTimeout: Duration, reconnectCooldown: Duration,
                cooldownStore: any RTSPCooldownStore) {
        self.init(host: host, port: port, requestTimeout: requestTimeout,
                  cooldownPolicy: .symmetric(reconnectCooldown), cooldownStore: cooldownStore)
    }

    /// `cooldownPolicy.full`; setting it makes the policy symmetric. Prefer `cooldownPolicy`:
    /// a factory that builds its client from this alone loses the clean-close value.
    public var reconnectCooldown: Duration {
        get { cooldownPolicy.full }
        set { cooldownPolicy = .symmetric(newValue) }
    }
}

public struct AudioSessionConfig: Sendable {
    public var keepaliveInterval: Duration = .seconds(15)
    /// Recover if no packet arrives for this long while streaming. nil (the default) disables it:
    /// whether the SDS200 stops sending while squelch is closed is unmeasured (protocol notes §8.6).
    public var stallTimeout: Duration? = nil
    public var maxRecoveryAttempts: Int = 2
    /// The reconnect cooldown, by how the last close went (`RTSPCooldownPolicy`). Every client the
    /// session builds gets it, and recovery waits by it.
    public var cooldownPolicy: RTSPCooldownPolicy = .standard
    public var requestTimeout: Duration = .seconds(3)
    /// Shared by every RTSP client the session builds. The CLI and app pass a `FileRTSPCooldownStore`.
    public var cooldownStore: any RTSPCooldownStore = InMemoryRTSPCooldownStore.shared
    /// The pause between closing the RTSP connection and closing the RTP receiver.
    public var rtpCloseDelay: Duration = .milliseconds(500)
    /// Asked once each time the session enters `failed`: does the scanner still answer on the
    /// control channel (e.g. `ScannerRestartMonitor.isAnswering`)? Never touches RTSP port 554.
    /// nil (the default) leaves `restartHint` nil (unknown).
    public var probe: (@Sendable () async -> Bool)? = nil

    public init(keepaliveInterval: Duration = .seconds(15), stallTimeout: Duration? = nil,
                maxRecoveryAttempts: Int = 2, cooldownPolicy: RTSPCooldownPolicy = .standard,
                requestTimeout: Duration = .seconds(3),
                cooldownStore: any RTSPCooldownStore = InMemoryRTSPCooldownStore.shared,
                rtpCloseDelay: Duration = .milliseconds(500),
                probe: (@Sendable () async -> Bool)? = nil) {
        self.probe = probe
        self.keepaliveInterval = keepaliveInterval; self.stallTimeout = stallTimeout
        self.maxRecoveryAttempts = maxRecoveryAttempts; self.cooldownPolicy = cooldownPolicy
        self.requestTimeout = requestTimeout; self.cooldownStore = cooldownStore
        self.rtpCloseDelay = rtpCloseDelay
    }

    /// A symmetric policy: the same `reconnectCooldown` after every close.
    public init(keepaliveInterval: Duration = .seconds(15), stallTimeout: Duration? = nil,
                maxRecoveryAttempts: Int = 2, reconnectCooldown: Duration,
                requestTimeout: Duration = .seconds(3),
                cooldownStore: any RTSPCooldownStore = InMemoryRTSPCooldownStore.shared,
                rtpCloseDelay: Duration = .milliseconds(500),
                probe: (@Sendable () async -> Bool)? = nil) {
        self.init(keepaliveInterval: keepaliveInterval, stallTimeout: stallTimeout,
                  maxRecoveryAttempts: maxRecoveryAttempts, cooldownPolicy: .symmetric(reconnectCooldown),
                  requestTimeout: requestTimeout, cooldownStore: cooldownStore,
                  rtpCloseDelay: rtpCloseDelay, probe: probe)
    }

    /// `cooldownPolicy.full`; setting it makes the policy symmetric.
    public var reconnectCooldown: Duration {
        get { cooldownPolicy.full }
        set { cooldownPolicy = .symmetric(newValue) }
    }
}

public struct AudioStats: Sendable, Equatable {
    public var packets = 0
    /// Net network loss: sequence numbers counted missing at a gap, minus those that later
    /// arrived late (up to 64 behind). Not what playback missed; see `playoutGaps`.
    public var lost = 0
    public var duplicates = 0
    public var reordered = 0
    public var droppedMalformed = 0
    public var droppedWrongSource = 0
    public var droppedWrongPayloadType = 0
    public var recoveries = 0
    /// Chunks the chunk stream discarded because the consumer fell more than 250 behind.
    public var droppedChunks = 0
    /// Packets 65 … 3000 behind the newest, too late to place: counted here, never yielded.
    public var stale = 0
    /// The sum of yielded chunks' `lostBefore`: packets missing from the audio the consumer got.
    /// Late (reordered, stale) arrivals don't reduce it.
    public var playoutGaps = 0

    public init() {}
}

/// One audio stream from the scanner: RTSP control (`RTSPClient`) plus RTP reception
/// (`RTPReceiver`), decoded to 16-bit PCM chunks, kept alive, and recovered after a failure.
///
/// **Start sequence** (`start()`, and each recovery attempt): bind an `RTPReceiver` whose expected
/// source is the scanner's IP literal (bound before connecting, so a local bind failure never
/// costs a TCP connection and its cooldown), connect, `describe()` (which sends OPTIONS first),
/// require payload type 0, SETUP `base + control` with the receiver's port, PLAY. If the connected
/// IP differs from the receiver's expected source (a host name), the receiver is rebound to the
/// connected literal before SETUP. `start()` returns the chunk stream once PLAY is answered.
/// The initial start never waits out a reconnect cooldown: it fails with `RTSPError.cooldown`.
///
/// **States:** `idle` → `starting` → `streaming`. A keepalive failure (timeout, `.closed`,
/// non-2xx including 454), or, when `stallTimeout` is set, no packet for that long, moves
/// `streaming` → `recovering(attempt: 1)`. Each attempt: close the RTSP client (best-effort
/// TEARDOWN), wait `rtpCloseDelay`, close the receiver, wait out `cooldownPolicy` after the last
/// recorded closes (its clean-close value only after a clean close, and never less than the full
/// value since the last unclean one; read from the cooldown store; `nextAttemptAt` says when), then
/// run the start sequence on a fresh client and receiver. Success → `streaming` (the chunk stream
/// continues; `stats.recoveries` counts it). A failed attempt → `recovering(attempt: n + 1)`; after
/// `maxRecoveryAttempts` failures → `failed(AudioSession.gaveUpMessage)` and the chunk stream
/// finishes. A keepalive that fails with `RTSPError.preempted` means someone tore the session
/// down deliberately: the session stops instead of recovering. A failed initial start →
/// `failed(<reason>)` and `start()` throws. `stop()` → `stopped` from any state.
///
/// **Ordering:** the RTSP connection always closes before the RTP receiver, `rtpCloseDelay`
/// (0.5 s) apart, as the proven reference client does (see `RTPReceiver`).
///
/// **Unreleased sessions:** if a client's TEARDOWN couldn't go out (e.g. the connection died and
/// reconnecting was inside the cooldown), its session ids are collected in `unreleasedSessions`.
/// The next connection this session opens (a recovery attempt, after the cooldown) sends
/// OPTIONS, then TEARDOWN for each of them, then DESCRIBE, and drops every id the scanner answers (any
/// status). While the list is non-empty the scanner may need a restart; callers should say so.
///
/// **Factory:** `makeRTSP` builds each RTSP client from `RTSPClientOptions` (host, port, and the
/// config's request timeout, cooldown policy, and cooldown store). Custom factories must pass
/// those through (`cooldownPolicy`, not the symmetric `reconnectCooldown` shim) so every client
/// honors the same cooldown.
public actor AudioSession {
    public static let gaveUpMessage = "Scanner audio isn't responding. Power-cycle the scanner if it doesn't recover."

    public static let defaultMakeRTSP: @Sendable (RTSPClientOptions) -> RTSPClient = { options in
        RTSPClient(host: options.host, port: options.port, requestTimeout: options.requestTimeout,
                   cooldownPolicy: options.cooldownPolicy, cooldownStore: options.cooldownStore)
    }

    public let host: String
    public let rtspPort: UInt16
    public let config: AudioSessionConfig
    public private(set) var state: AudioSessionState = .idle
    /// While `recovering`, when the next attempt may connect (the cooldown's end); otherwise nil.
    public private(set) var nextAttemptAt: ContinuousClock.Instant?
    /// Session ids some client couldn't tear down. Non-empty means the scanner may need a restart.
    public private(set) var unreleasedSessions: [String] = []
    /// Set (just before `state` becomes `failed`) from `config.probe`; nil in every other state,
    /// or when no probe is configured. Restarting is never automatic: a UI shows the restart
    /// action for `.canRestart` and asks the user to confirm.
    public private(set) var restartHint: RestartHint?
    /// Every state change, starting with `idle`. Buffered; meant for one consumer. Finishes after `stopped`.
    public nonisolated let states: AsyncStream<AudioSessionState>

    private let makeRTSP: @Sendable (RTSPClientOptions) -> RTSPClient
    private let statesContinuation: AsyncStream<AudioSessionState>.Continuation
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?

    private var rtsp: RTSPClient?
    private var receiver: RTPReceiver?
    private var receiverPort: UInt16 = 0
    /// The scanner's IP literal, from the latest connection.
    private var scannerAddress: String?

    private var started = false
    private var stopping = false
    private var stopTask: Task<Void, Never>?
    private var startTask: Task<Void, any Error>?
    private var recoveryTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var packetTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    /// Bumped whenever the client/receiver pair is released, so stale loops know.
    private var generation: UInt64 = 0

    private var tracker = RTPSequenceTracker()
    private var currentSSRC: UInt32?
    /// Whether any chunk has gone to the stream, so a later sequence restart is a discontinuity.
    private var hasYielded = false
    private var lastPacketAt = ContinuousClock.now
    /// Counts from released trackers and receivers, plus session-level ones.
    private var totals = AudioStats()

    public init(host: String, rtspPort: UInt16 = 554, config: AudioSessionConfig = .init(),
                makeRTSP: @escaping @Sendable (RTSPClientOptions) -> RTSPClient = AudioSession.defaultMakeRTSP) {
        self.host = host; self.rtspPort = rtspPort; self.config = config; self.makeRTSP = makeRTSP
        let (stream, continuation) = AsyncStream.makeStream(of: AudioSessionState.self)
        states = stream
        statesContinuation = continuation
        continuation.yield(.idle)
    }

    /// Totals across every connection and receiver this session has used.
    public var stats: AudioStats {
        get async {
            var stats = totals
            stats.lost += tracker.lost
            stats.duplicates += tracker.duplicates
            stats.reordered += tracker.reordered
            stats.stale += tracker.stale
            if let receiver {
                stats.droppedMalformed += await receiver.droppedMalformed
                stats.droppedWrongSource += await receiver.droppedWrongSource
            }
            return stats
        }
    }

    // MARK: Start and stop

    /// Runs the start sequence and returns the decoded chunks (buffering the newest 250, 10 s).
    /// Throws `AudioSessionError.alreadyStarted` if called twice, `.stopped` if `stop()` ran
    /// meanwhile, `.unsupportedPayloadType` if the SDP isn't PCMU, or the RTSP error. Cancelling
    /// the caller stops the session.
    public func start() async throws -> AsyncStream<AudioChunk> {
        guard !started else { throw AudioSessionError.alreadyStarted }
        started = true
        guard !stopping else { throw AudioSessionError.stopped }
        setState(.starting)
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(250))
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.stop() }
        }
        chunkContinuation = continuation

        let task = Task { try await self.establish() }
        startTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            startTask = nil
            if stopping { throw AudioSessionError.stopped }
            if error is CancellationError {
                await stop()
                throw error
            }
            await release()
            if !stopping {
                await enterFailed(Self.startFailureMessage(error))
                finishChunks()
            }
            throw error
        }
        startTask = nil
        guard !stopping else { throw AudioSessionError.stopped }
        setState(.streaming)
        startLoops()
        return stream
    }

    /// Stops from any state: cancels the loops and any start or recovery, closes the RTSP client
    /// (one TEARDOWN), waits `rtpCloseDelay`, closes the receiver, then `stopped`, and finishes
    /// both streams. Idempotent; concurrent calls share one teardown.
    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
    }

    private func performStop() async {
        stopping = true
        let start = startTask, recovery = recoveryTask
        let loops = [keepaliveTask, packetTask, stallTask]
        start?.cancel()
        recovery?.cancel()
        for loop in loops { loop?.cancel() }
        // Each finishes promptly once cancelled (every RTSP request and wait honors cancellation).
        _ = await start?.result
        await recovery?.value
        for loop in loops { await loop?.value }
        await release()
        nextAttemptAt = nil
        setState(.stopped)
        finishChunks()
        statesContinuation.finish()
    }

    // MARK: Start sequence

    private func checkLive() throws {
        if stopping || Task.isCancelled { throw CancellationError() }
    }

    /// Binds a receiver, connects a fresh client, and runs DESCRIBE / SETUP / PLAY. Both are
    /// stored on `self` as soon as they exist, so `release()` always finds them.
    private func establish() async throws {
        try checkLive()
        let expected = scannerAddress ?? host
        let receiver = RTPReceiver(expectedSourceHost: expected)
        self.receiver = receiver
        receiverPort = try await receiver.bind()
        try checkLive()

        // Step order: bind, connect, [OPTIONS, leftover TEARDOWNs], DESCRIBE (OPTIONS first if not
        // yet sent on this connection), SETUP, PLAY. OPTIONS goes out exactly once per connection.
        let client = makeRTSP(RTSPClientOptions(
            host: host, port: rtspPort, requestTimeout: config.requestTimeout,
            cooldownPolicy: config.cooldownPolicy, cooldownStore: config.cooldownStore))
        rtsp = client
        try await client.connect()
        try checkLive()
        let remote = await client.remoteAddress ?? host
        scannerAddress = remote
        if IPAddressText.normalized(expected) != IPAddressText.normalized(remote) {
            // A host name: filter on the address actually connected to.
            let rebound = RTPReceiver(expectedSourceHost: remote)
            self.receiver = rebound
            await receiver.close()
            receiverPort = try await rebound.bind()
            try checkLive()
        }

        // Sessions an earlier client couldn't end: tear them down on this connection, after
        // OPTIONS (which teardown(sessionIDs:) sends first) and before DESCRIBE. Any answer clears an id; unanswered ones stay for the next connection.
        if !unreleasedSessions.isEmpty {
            let done = await client.teardown(sessionIDs: unreleasedSessions)
            unreleasedSessions.removeAll { done.contains($0) }
            try checkLive()
        }

        let (base, sdp) = try await client.describe()
        guard sdp.payloadType == 0 else { throw AudioSessionError.unsupportedPayloadType(sdp.payloadType) }
        try checkLive()
        let control = sdp.control ?? "trackID=1"
        let controlURL = control.lowercased().hasPrefix("rtsp://") ? control : base + control
        _ = try await client.setup(controlURL: controlURL, clientPort: receiverPort)
        try checkLive()
        try await client.play()
        try checkLive()
        lastPacketAt = .now
    }

    private static func startFailureMessage(_ error: any Error) -> String {
        switch error {
        case AudioSessionError.unsupportedPayloadType(let type):
            "Scanner audio uses an unsupported format (RTP payload type \(type))."
        case RTSPError.cooldown(let remaining):
            "Scanner audio was used moments ago. Try again in \(Int(remaining.seconds.rounded(.up))) s."
        default:
            "Couldn't start scanner audio: \(error)"
        }
    }

    // MARK: Loops

    private func startLoops() {
        guard let client = rtsp, let receiver else { return }
        let generation = self.generation
        let interval = config.keepaliveInterval
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                do {
                    try await client.keepalive()
                } catch {
                    if Task.isCancelled { return }
                    await self?.keepaliveFailed(error, generation: generation)
                    return
                }
            }
        }
        let packets = receiver.packets
        packetTask = Task { [weak self] in
            for await packet in packets {
                guard let self else { return }
                await self.handle(packet, generation: generation)
            }
        }
        if let timeout = config.stallTimeout {
            let tick = max(timeout / 4, .milliseconds(10))
            stallTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: tick) } catch { return }
                    guard let self else { return }
                    if await self.checkStall(timeout: timeout, generation: generation) { return }
                }
            }
        }
    }

    private func handle(_ received: ReceivedRTP, generation: UInt64) {
        guard generation == self.generation else { return }
        lastPacketAt = received.receivedAt
        let packet = received.packet
        guard packet.payloadType == 0 else {
            totals.droppedWrongPayloadType += 1
            return
        }
        totals.packets += 1
        if currentSSRC != packet.ssrc {
            // A new stream (new SSRC) starts its sequence afresh.
            if currentSSRC != nil { retireTracker() }
            currentSSRC = packet.ssrc
        }
        var lostBefore = 0
        var discontinuity = false
        switch tracker.observe(packet.sequence) {
        // A late (reordered or stale) packet's slot was already reported in an earlier chunk's
        // `lostBefore`; yielding it now would play it out of order and shift recordings.
        // It still counts in `stats.reordered` or `stats.stale`.
        case .duplicate, .reordered, .stale: return
        case .gap(let missing): lostBefore = missing
        case .inOrder: break
        case .first: discontinuity = hasYielded
        }
        let result = chunkContinuation?.yield(AudioChunk(
            samples: MuLaw.decode(packet.payload), rtpTimestamp: packet.timestamp,
            sequence: packet.sequence, receivedAt: received.receivedAt,
            ssrc: packet.ssrc, lostBefore: lostBefore, discontinuity: discontinuity))
        switch result {
        case .enqueued: break
        case .dropped: totals.droppedChunks += 1
        case .terminated, nil: return
        @unknown default: break
        }
        hasYielded = true
        totals.playoutGaps += lostBefore
    }

    private func retireTracker() {
        totals.lost += tracker.lost
        totals.duplicates += tracker.duplicates
        totals.reordered += tracker.reordered
        totals.stale += tracker.stale
        tracker.reset()
        currentSSRC = nil
    }

    private func keepaliveFailed(_ error: any Error, generation: UInt64) {
        guard generation == self.generation, state == .streaming, !stopping else { return }
        if error is CancellationError { return }
        if case RTSPError.preempted = error {
            // A deliberate teardown, not a fault: stop rather than reconnect.
            Task { await self.stop() }
            return
        }
        beginRecovery()
    }

    /// Returns true if it started a recovery (or the loop is stale), so the stall loop ends.
    private func checkStall(timeout: Duration, generation: UInt64) -> Bool {
        guard generation == self.generation, state == .streaming, !stopping else { return true }
        guard ContinuousClock.now - lastPacketAt >= timeout else { return false }
        beginRecovery()
        return true
    }

    // MARK: Recovery

    private func beginRecovery() {
        guard recoveryTask == nil, !stopping else { return }
        keepaliveTask?.cancel(); keepaliveTask = nil
        stallTask?.cancel(); stallTask = nil
        packetTask?.cancel(); packetTask = nil
        recoveryTask = Task { await self.recover() }
    }

    private func recover() async {
        defer { recoveryTask = nil }
        var attempt = 0
        while true {
            attempt += 1
            guard attempt <= config.maxRecoveryAttempts else {
                await release()
                guard !stopping else { return }
                nextAttemptAt = nil
                await enterFailed(Self.gaveUpMessage)
                finishChunks()
                return
            }
            setState(.recovering(attempt: attempt))
            await release()
            guard !stopping, !Task.isCancelled else { return }
            do {
                try await waitOutCooldown()
                try await establishRetryingOnCooldown()
            } catch {
                if stopping || Task.isCancelled { return }
                continue
            }
            guard !stopping else { return }
            nextAttemptAt = nil
            totals.recoveries += 1
            setState(.streaming)
            startLoops()
            return
        }
    }

    /// Sleeps until `cooldownPolicy`'s wait has passed since the latest close recorded in the
    /// cooldown store for the scanner, publishing the end in `nextAttemptAt`.
    private func waitOutCooldown() async throws {
        let remaining = await cooldownRemaining()
        let until = ContinuousClock.now + remaining
        nextAttemptAt = until
        try await Task.sleep(until: until, clock: .continuous)
    }

    /// The store and our clock can disagree by a hair; if the client still refuses with
    /// `.cooldown`, wait what it says (at most twice) rather than count a failed attempt.
    private func establishRetryingOnCooldown() async throws {
        var retries = 0
        while true {
            do {
                try await establish()
                return
            } catch RTSPError.cooldown(let remaining) where retries < 2 {
                retries += 1
                await release()
                let until = ContinuousClock.now + remaining + .milliseconds(10)
                nextAttemptAt = until
                try await Task.sleep(until: until, clock: .continuous)
            }
        }
    }

    /// What's left of `config.cooldownPolicy`'s wait after the closes recorded for the scanner
    /// (`RTSPCooldownPolicy.remaining(after:)`: a clean close never hides an unclean one).
    private func cooldownRemaining() async -> Duration {
        guard config.cooldownPolicy.full > .zero else { return .zero }
        var keys = await RTPReceiver.addresses(for: host)
        if let scannerAddress { keys.insert(scannerAddress) }
        var merged: RTSPCloseHistory?
        for key in keys {
            merged = RTSPCloseHistory.merged(merged, await config.cooldownStore.closeHistory(host: key))
        }
        guard let merged, let remaining = config.cooldownPolicy.remaining(after: merged) else { return .zero }
        return remaining + .milliseconds(10)
    }

    // MARK: Release

    /// Closes the current client and receiver (RTSP first, then `rtpCloseDelay`, then RTP).
    /// Calls are chained, so a second caller returns only after everything is closed.
    private func release() async {
        let previous = releaseTask
        let task = Task {
            await previous?.value
            await self.releaseNow()
        }
        releaseTask = task
        await task.value
    }

    private func releaseNow() async {
        generation += 1
        let client = rtsp, receiver = self.receiver
        rtsp = nil
        self.receiver = nil
        if let client {
            await client.close()
            for id in await client.unreleasedSessions where !unreleasedSessions.contains(id) {
                unreleasedSessions.append(id)
            }
        }
        if let receiver {
            if client != nil { try? await Task.sleep(for: config.rtpCloseDelay) }
            await receiver.close()
            totals.droppedMalformed += await receiver.droppedMalformed
            totals.droppedWrongSource += await receiver.droppedWrongSource
        }
        retireTracker()
    }

    // MARK: Helpers

    /// Asks the probe (if any) whether the control channel still answers, records the hint,
    /// and only then publishes `failed`, so observers of the state can read the hint at once.
    private func enterFailed(_ message: String) async {
        var hint: RestartHint?
        if let probe = config.probe {
            hint = await probe() ? .canRestart : .powerCycleNeeded
        }
        guard !stopping else { return }
        restartHint = hint
        setState(.failed(message))
    }

    private func setState(_ new: AudioSessionState) {
        guard new != state else { return }
        if case .failed = new {} else { restartHint = nil }
        state = new
        statesContinuation.yield(new)
    }

    private func finishChunks() {
        chunkContinuation?.finish()
        chunkContinuation = nil
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
