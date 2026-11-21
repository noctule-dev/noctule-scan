// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Network

/// A loopback RTSP server (TCP on 127.0.0.1) that mimics the scanner's audio server.
///
/// `.scannerLike` answers OPTIONS with a `Public` method list, DESCRIBE with the real response shape, SETUP with
/// `Session: 1234ABCD` (no timeout, like the SDS200) and the scanner's Transport shape, and every
/// other method with 200. With `uniqueSessionIDs`, each SETUP issues a new id instead.
///
/// With a `FakeRTPSender` attached (`attach(_:)`), an answered PLAY starts the sender streaming to
/// that session's `client_port`, and an answered TEARDOWN of the streaming session stops it, as
/// the scanner does. A connection that closes without TEARDOWN leaves the sender streaming.
/// A `Script` can override any method's answer. The server accepts any number of connections
/// over its lifetime (one after another, or at once) and logs every request it receives.
///
/// `Behavior` (all off by default) makes it closer to the SDS200, for `MockSDS200`: per-method
/// reply delays, the reconnect hazard (a connection opened within `reconnectCooldown` of the
/// previous close wedges the server until `powerCycle()`; with `cooldownAfter: .unclean`, a clean
/// close doesn't start that window), and scanner-style sessions (numeric
/// ids, a new SSRC and server port per session that the attached sender then uses, `RTP-Info` on
/// PLAY, and 454 for a session the server doesn't know).
public actor FakeRTSPServer {
    /// SDS200-like behavior beyond the script. Everything is off by default.
    public struct Behavior: Sendable, Equatable {
        /// How long the server waits before sending a normal reply, by method.
        public var replyDelays: [String: Duration]
        /// When set, a TCP connection accepted within this long of the previous connection's
        /// close wedges the server (protocol notes §6), until `powerCycle()` or `powerUp()`.
        public var reconnectCooldown: Duration?
        /// Which closes start the hazard window. With `.unclean`, a connection the client closed
        /// (FIN) after a 2xx TEARDOWN on it, with no non-2xx TEARDOWN and every request on it
        /// answered, doesn't; every other close does, and a clean close never clears the window an
        /// earlier unclean one started. This models the owner's theory (Plan 5), not the hardware.
        public var cooldownAfter: MockCooldownAfter
        /// What a wedged server does with connections (see `MockWedgeMode`).
        public var wedgeMode: MockWedgeMode
        /// Numeric session ids, per-session SSRC and server port, `RTP-Info`, and 454 for
        /// PLAY / GET_PARAMETER / TEARDOWN naming a session the server doesn't hold.
        public var scannerSessions: Bool

        public init(replyDelays: [String: Duration] = [:], reconnectCooldown: Duration? = nil,
                    cooldownAfter: MockCooldownAfter = .any,
                    wedgeMode: MockWedgeMode = .timeout, scannerSessions: Bool = false) {
            self.replyDelays = replyDelays; self.reconnectCooldown = reconnectCooldown
            self.cooldownAfter = cooldownAfter
            self.wedgeMode = wedgeMode; self.scannerSessions = scannerSessions
        }
    }

    /// Things the server reports to `setEventHandler(_:)`.
    public enum Event: Sendable, Equatable {
        /// The reconnect hazard (or `wedge()`) wedged the server.
        case wedged
        /// PLAY was answered and the attached sender started streaming for this session.
        case played(session: String)
        /// TEARDOWN of a session the server held was answered.
        case tornDown(session: String)
        /// A request arrived (before any reply), wedged or not.
        case request(method: String)
    }

    /// Overrides for `.scannerLike` answers. The first rule whose method matches a request wins;
    /// a `once` rule is used up by its first match, an `always` rule applies to every match.
    public struct Script: Sendable, Equatable {
        public enum Action: Sendable, Equatable {
            /// Reply with this status code (CSeq only, no other headers).
            case status(Int)
            /// Record the request and never reply.
            case silence
            /// Record the request and close the TCP connection without replying.
            case close
            /// Reply normally, but with `CSeq` + 100.
            case wrongCSeq
            /// Reply normally, after this long.
            case delay(Duration)
        }

        public struct Rule: Sendable, Equatable {
            public var method: String
            public var action: Action
            public var once: Bool
            public init(method: String, action: Action, once: Bool = false) {
                self.method = method; self.action = action; self.once = once
            }
        }

        public var rules: [Rule]

        public init(rules: [Rule] = []) { self.rules = rules }

        public static let scannerLike = Script()

        public func status(method: String, code: Int, once: Bool = false) -> Script {
            adding(Rule(method: method, action: .status(code), once: once))
        }
        public func silence(method: String, once: Bool = false) -> Script {
            adding(Rule(method: method, action: .silence, once: once))
        }
        public func closeOn(method: String, once: Bool = false) -> Script {
            adding(Rule(method: method, action: .close, once: once))
        }
        public func wrongCSeq(method: String, once: Bool = false) -> Script {
            adding(Rule(method: method, action: .wrongCSeq, once: once))
        }
        public func delay(method: String, seconds: Double, once: Bool = false) -> Script {
            adding(Rule(method: method, action: .delay(.milliseconds(Int(seconds * 1000))), once: once))
        }

        private func adding(_ rule: Rule) -> Script {
            var copy = self
            copy.rules.append(rule)
            return copy
        }
    }

    public static let host = "127.0.0.1"
    public static let sessionID = "1234ABCD"
    public static let serverPort = 56002
    public static let ssrc: UInt32 = 1_234_567_890
    /// The scanner's DESCRIBE body (157 bytes), with documentation-safe addresses.
    public static let describeSDP =
        "v=0\r\no=- 0000000000 0000000000 IN IP4 127.0.0.1\r\ns=scanner.au\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\na=sdplang:en\r\na=control:*\r\nm=audio 0 RTP/AVP 0\r\na=control:trackID=1\r\n"

    /// Every request method received, in arrival order, across all connections.
    public private(set) var receivedMethods: [String] = []
    /// The full text (request line, headers, blank line) of every request, in arrival order.
    public private(set) var receivedRequests: [String] = []
    /// How many TCP connections have been accepted.
    public private(set) var acceptedConnections = 0
    /// When each TCP connection was accepted, in order.
    public private(set) var connectionsAcceptedAt: [ContinuousClock.Instant] = []
    /// Every session id a SETUP reply has issued, in order.
    public private(set) var issuedSessionIDs: [String] = []

    /// The `Session` header of every TEARDOWN received, in order.
    public var teardownSessionIDs: [String] {
        receivedRequests.filter { $0.hasPrefix("TEARDOWN ") }.compactMap { text in
            text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("session:") }
                .map { String($0.dropFirst("session:".count)).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// How a client connection ended, seen from the server.
    public enum ConnectionEnd: Sendable, Equatable {
        /// The client closed gracefully: the receive completed with no error (FIN).
        case fin
        /// The receive failed (ECONNRESET for an RST), with this description.
        case failed(String)
        /// The server closed it (a `close` rule, or `stop()`).
        case closedByServer
    }

    /// Every finished connection, in the order they ended, with when.
    public private(set) var connectionEnds: [(end: ConnectionEnd, at: ContinuousClock.Instant)] = []
    /// When each reply was handed to the network, in order, by request method.
    public private(set) var replies: [(method: String, at: ContinuousClock.Instant)] = []

    /// True while wedged: requests get no reply, and new connections are held unanswered
    /// (`.timeout`) or reset (`.refuse`).
    public private(set) var isWedged = false
    /// How many times the server has wedged.
    public private(set) var wedgeCount = 0
    /// True between `powerDown()` and `powerUp()`: new connections are reset at once.
    public private(set) var isPoweredDown = false
    /// Connections accepted while wedged or powered down (held or reset, never served).
    public private(set) var unservedConnections = 0
    /// When the latest served connection ended.
    public private(set) var lastConnectionClosedAt: ContinuousClock.Instant?
    /// Sessions issued and not yet torn down (or forgotten by `powerDown()`).
    public private(set) var liveSessions: [String] = []
    /// Sessions a power cycle or reboot dropped without a TEARDOWN.
    public private(set) var forgottenSessions: [String] = []
    /// The SSRC each session's SETUP reply advertised (scanner sessions).
    public private(set) var sessionSSRCs: [String: UInt32] = [:]

    /// Sessions that never got a TEARDOWN: everything still live. A client that always tears
    /// down leaves this empty when it's done.
    public var leakedSessions: [String] { liveSessions }

    /// The script's remaining rules (once rules disappear as they're used).
    public var currentScript: Script { Script(rules: rules) }

    public let behavior: Behavior
    private var rules: [Script.Rule]
    private let uniqueSessionIDs: Bool
    private var eventHandler: (@Sendable (Event) -> Void)?
    /// Connections accepted while wedged in `.timeout` mode: open, never read or answered.
    private var heldConnections: [NWConnection] = []
    /// Session id → the server port its SETUP reply advertised (scanner sessions).
    private var sessionServerPorts: [String: Int] = [:]
    /// Session id → the starting sequence and RTP time its PLAY reply advertised.
    private var playStarts: [String: (sequence: UInt16, timestamp: UInt32)] = [:]
    private let sdp: String
    private var sender: FakeRTPSender?
    /// Session id → the `client_port` its SETUP asked for.
    private var sessionPorts: [String: UInt16] = [:]
    /// The session the attached sender is streaming for.
    private var streamingSession: String?
    private var listener: NWListener?
    private var cancelledSignal: AsyncStream<Void>?
    private var connections: [Int: NWConnection] = [:]
    /// Per served connection: what decides whether its close was clean (`Behavior.cooldownAfter`).
    private var exchanges: [Int: Exchange] = [:]
    private var nextConnectionID = 0
    private let queue = DispatchQueue(label: "NoctuleMockScanner.FakeRTSPServer")

    /// `sdp` is the DESCRIBE body (default `describeSDP`, payload type 0).
    public init(script: Script = .scannerLike, uniqueSessionIDs: Bool = false, sdp: String = FakeRTSPServer.describeSDP,
                behavior: Behavior = Behavior()) {
        rules = script.rules
        self.uniqueSessionIDs = uniqueSessionIDs
        self.sdp = sdp
        self.behavior = behavior
    }

    /// Receives `Event`s (called on the server's actor; hop elsewhere for anything slow).
    public func setEventHandler(_ handler: (@Sendable (Event) -> Void)?) {
        eventHandler = handler
    }

    /// Wedges the server now, as the reconnect hazard does.
    public func wedge() {
        guard !isWedged else { return }
        isWedged = true
        wedgeCount += 1
        eventHandler?(.wedged)
    }

    /// The audio server goes away (power off, or a reboot starting): every connection closes,
    /// sessions are forgotten, the sender stops, and new connections are reset until `powerUp()`.
    public func powerDown() async {
        isPoweredDown = true
        for (id, connection) in connections {
            connection.forceCancel()
            connections[id] = nil
            connectionEnds.append((.closedByServer, .now))
        }
        for connection in heldConnections { connection.forceCancel() }
        heldConnections.removeAll()
        forgottenSessions += liveSessions
        liveSessions.removeAll()
        sessionPorts.removeAll()
        playStarts.removeAll()
        streamingSession = nil
        await sender?.stop()
    }

    /// The audio server comes back fresh: not wedged, no close on record, no sessions.
    public func powerUp() {
        isPoweredDown = false
        isWedged = false
        lastConnectionClosedAt = nil
        for connection in heldConnections { connection.forceCancel() }
        heldConnections.removeAll()
    }

    /// `powerDown()` then `powerUp()`.
    public func powerCycle() async {
        await powerDown()
        powerUp()
    }

    /// Replaces the script's remaining rules, e.g. to make later requests fail.
    public func replaceScript(_ script: Script) {
        rules = script.rules
    }

    /// Streams RTP with `sender` while a session is playing (see the type's notes).
    public func attach(_ sender: FakeRTPSender) {
        self.sender = sender
    }

    /// Starts listening on 127.0.0.1 and returns the bound port once ready.
    ///
    /// The port is picked at random from 20000–44999, outside the macOS ephemeral range
    /// (49152–65535), retrying if it's taken. A listener on an ephemeral port can land on the
    /// local port of a client socket that just closed and is in TIME_WAIT; connecting to it
    /// then sits in `.waiting(EADDRINUSE)` (see LESSONS.md).
    public func start() async throws -> UInt16 {
        try await start(port: 0)
    }

    /// Starts listening on 127.0.0.1:`port`; 0 picks a random port as `start()` describes.
    public func start(port requested: UInt16) async throws -> UInt16 {
        if let port = listener?.port?.rawValue { return port }
        if requested != 0 { return try await listen(on: requested) }
        var lastError: any Error = NWError.posix(.EADDRINUSE)
        for _ in 0..<32 {
            let port = UInt16.random(in: 20000...44999)
            do {
                return try await listen(on: port)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Starts a listener on `port` and waits (at most 1 s) for it to be ready.
    private func listen(on port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(Self.host), port: endpointPort)
        let listener = try NWListener(using: parameters)
        let (states, sink) = AsyncStream.makeStream(of: NWListener.State.self)
        let (cancelled, cancelledSink) = AsyncStream.makeStream(of: Void.self)
        listener.stateUpdateHandler = { state in
            sink.yield(state)
            if case .cancelled = state {
                sink.finish()
                cancelledSink.finish()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        listener.start(queue: queue)

        do {
            let ready = try await withThrowingTaskGroup(of: UInt16.self) { group in
                group.addTask {
                    for await state in states {
                        switch state {
                        case .ready:
                            if let port = listener.port?.rawValue { return port }
                        case .failed(let error): throw error
                        case .waiting(let error): throw error
                        case .cancelled: throw CancellationError()
                        default: continue
                        }
                    }
                    throw CancellationError()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    throw NWError.posix(.ETIMEDOUT)
                }
                defer { group.cancelAll() }
                guard let port = try await group.next() else { throw NWError.posix(.ETIMEDOUT) }
                return port
            }
            self.listener = listener
            cancelledSignal = cancelled
            return ready
        } catch {
            listener.newConnectionHandler = nil
            listener.cancel()
            throw error
        }
    }

    /// Stops listening and closes every connection. Waits (at most 1 s) until the listener
    /// reports `.cancelled`, so the port is closed when this returns.
    public func stop() async {
        for connection in connections.values {
            connection.cancel()
            connectionEnds.append((.closedByServer, .now))
        }
        connections.removeAll()
        for connection in heldConnections { connection.forceCancel() }
        heldConnections.removeAll()
        guard let listener else { return }
        self.listener = nil
        let cancelled = cancelledSignal ?? AsyncStream { $0.finish() }
        listener.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in cancelled {} }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard listener != nil else { connection.cancel(); return }
        acceptedConnections += 1
        connectionsAcceptedAt.append(.now)
        // The SDS200 hazard: a new connection soon after the previous one closed hangs its audio
        // server until a power cycle (protocol notes §6). Loopback can't drop a SYN, so a wedged
        // `.timeout` server holds the connection open and never answers (the client times out on
        // its first request), and `.refuse` resets it at once.
        if !isWedged, !isPoweredDown, let cooldown = behavior.reconnectCooldown,
           let last = lastConnectionClosedAt, last.duration(to: .now) < cooldown {
            wedge()
        }
        if isPoweredDown || (isWedged && behavior.wedgeMode == .refuse) {
            unservedConnections += 1
            connection.start(queue: queue)
            connection.forceCancel()
            return
        }
        if isWedged {
            unservedConnections += 1
            heldConnections.append(connection)
            connection.start(queue: queue)
            return
        }
        nextConnectionID += 1
        let id = nextConnectionID
        connections[id] = connection
        exchanges[id] = Exchange()
        connection.start(queue: queue)
        Task { await self.serve(connection, id: id) }
    }

    private func serve(_ connection: NWConnection, id: Int) async {
        var buffer = Data()
        while connections[id] != nil {
            let (data, isComplete, error) = await Self.receive(on: connection)
            if let data { buffer.append(data) }
            while let request = Self.takeRequest(from: &buffer) {
                if !handle(request, id: id, on: connection) {
                    if connections[id] != nil { connectionEnds.append((.closedByServer, .now)) }
                    drop(connection, id: id)
                    return
                }
            }
            if let error {
                if connections[id] != nil { connectionEnds.append((.failed(String(describing: error)), .now)) }
                break
            }
            if isComplete {
                if connections[id] != nil { connectionEnds.append((.fin, .now)) }
                drop(connection, id: id, byClient: true)
                return
            }
        }
        drop(connection, id: id)
    }

    /// Forgets `connection`. Its close starts the hazard window unless `cooldownAfter` is
    /// `.unclean` and the client closed it (`byClient`) after a clean exchange.
    private func drop(_ connection: NWConnection, id: Int, byClient: Bool = false) {
        if connections[id] != nil {
            let clean = byClient && exchanges[id]?.isClean == true
            if behavior.cooldownAfter == .any || !clean { lastConnectionClosedAt = .now }
        }
        connection.cancel()
        connections[id] = nil
        exchanges[id] = nil
    }

    /// What a connection's requests and replies have been, for `Behavior.cooldownAfter`.
    private struct Exchange {
        /// Requests received and not yet answered.
        var unanswered = 0
        var teardownAnswered2xx = false
        var teardownAnsweredOther = false
        /// A reply with the wrong CSeq: the client sees a protocol error.
        var badReply = false

        var isClean: Bool { unanswered == 0 && teardownAnswered2xx && !teardownAnsweredOther && !badReply }
    }

    private struct Request {
        var text: String
        var method: String
        var cseq: Int
        var headers: [String: String]
    }

    /// Removes one complete request (head plus any Content-Length body) from `buffer`.
    private static func takeRequest(from buffer: inout Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: buffer[buffer.startIndex..<end.upperBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyLength = headers["content-length"].flatMap { Int($0) } ?? 0
        guard buffer.endIndex - end.upperBound >= bodyLength else { return nil }
        buffer = Data(buffer[(end.upperBound + bodyLength)...])
        let method = String(requestLine.split(separator: " ").first ?? "")
        let cseq = headers["cseq"].flatMap { Int($0) } ?? 0
        return Request(text: text, method: method, cseq: cseq, headers: headers)
    }

    /// Records and answers one request. Returns false if the connection should close.
    private func handle(_ request: Request, id: Int, on connection: NWConnection) -> Bool {
        receivedMethods.append(request.method)
        receivedRequests.append(request.text)
        exchanges[id]?.unanswered += 1
        eventHandler?(.request(method: request.method))
        // A wedged server reads but never answers.
        if isWedged { return true }
        var action: Script.Action?
        if let index = rules.firstIndex(where: { $0.method == request.method }) {
            action = rules[index].action
            if rules[index].once { rules.remove(at: index) }
        }
        switch action {
        case .silence:
            return true
        case .close:
            return false
        case .status(let code):
            replies.append((request.method, .now))
            noteAnswered(request.method, status: code, id: id)
            send("RTSP/1.0 \(code) \(Self.reason(for: code))\r\nCSeq: \(request.cseq)\r\n\r\n", on: connection)
        case .wrongCSeq:
            replies.append((request.method, .now))
            noteAnswered(request.method, status: 200, id: id)
            exchanges[id]?.badReply = true
            send(normalResponse(to: request, cseq: request.cseq + 100), on: connection)
        case .delay(let wait):
            let reply = normalResponse(to: request, cseq: request.cseq)
            let method = request.method
            Task {
                try? await Task.sleep(for: wait)
                self.sendDelayed(reply, method: method, id: id, on: connection)
            }
        case nil:
            if behavior.scannerSessions, ["PLAY", "GET_PARAMETER", "TEARDOWN"].contains(request.method),
               !(request.headers["session"].map(liveSessions.contains) ?? false) {
                replies.append((request.method, .now))
                noteAnswered(request.method, status: 454, id: id)
                send("RTSP/1.0 454 \(Self.reason(for: 454))\r\nCSeq: \(request.cseq)\r\n\r\n", on: connection)
                return true
            }
            let reply = normalResponse(to: request, cseq: request.cseq)
            if let wait = behavior.replyDelays[request.method], wait > .zero {
                Task {
                    try? await Task.sleep(for: wait)
                    self.sendNormal(reply, for: request, id: id, on: connection)
                }
            } else {
                sendNormal(reply, for: request, id: id, on: connection)
            }
        }
        return true
    }

    /// Sends a normal reply (unless the server wedged or lost the connection meanwhile) and
    /// applies its side effects.
    private func sendNormal(_ reply: String, for request: Request, id: Int, on connection: NWConnection) {
        guard !isWedged, !isPoweredDown, connections.values.contains(where: { $0 === connection }) else { return }
        replies.append((request.method, .now))
        noteAnswered(request.method, status: 200, id: id)
        send(reply, on: connection)
        answered(request)
    }

    /// Side effects of a normal (200) answer: session bookkeeping and the attached sender.
    private func answered(_ request: Request) {
        let session = request.headers["session"]
        switch request.method {
        case "PLAY":
            guard let session, let port = sessionPorts[session], let sender else { return }
            streamingSession = session
            let ssrc = sessionSSRCs[session]
            let start = playStarts[session]
            let handler = eventHandler
            Task {
                await sender.start(toPort: port, ssrc: ssrc, sequence: start?.sequence, timestamp: start?.timestamp)
                handler?(.played(session: session))
            }
        case "TEARDOWN":
            guard let session else { return }
            if let index = liveSessions.firstIndex(of: session) {
                liveSessions.remove(at: index)
                eventHandler?(.tornDown(session: session))
            }
            guard session == streamingSession, let sender else { return }
            streamingSession = nil
            Task { await sender.stop() }
        default:
            break
        }
    }

    private func issueSessionID(clientPort: UInt16?) -> String {
        var id = uniqueSessionIDs
            ? String(format: "%08X", 0x1234_ABCD &+ UInt32(issuedSessionIDs.count))
            : Self.sessionID
        if behavior.scannerSessions {
            // Numeric ids (the SDS200's shape), and a fresh SSRC and server port per session.
            repeat { id = String(UInt32.random(in: 10_000_000...4_000_000_000)) } while issuedSessionIDs.contains(id)
            sessionSSRCs[id] = UInt32.random(in: 1...UInt32.max)
            sessionServerPorts[id] = 56000 + 2 * Int.random(in: 0..<500)
        }
        issuedSessionIDs.append(id)
        liveSessions.append(id)
        if let clientPort { sessionPorts[id] = clientPort }
        return id
    }

    private func normalResponse(to request: Request, cseq: Int) -> String {
        switch request.method {
        case "OPTIONS":
            return "RTSP/1.0 200 OK\r\n"
                + "CSeq: \(cseq)\r\n"
                + "Public: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY, GET_PARAMETER\r\n\r\n"
        case "DESCRIBE":
            return "RTSP/1.0 200 OK\r\n"
                + "Cache-Control: no-cache\r\n"
                + "CSeq: \(cseq)\r\n"
                + "Server: Scanner Audio Server 0.0.1\r\n"
                + "Content-Base: rtsp://\(Self.host)/au:scanner.au/\r\n"
                + "Content-Length: \(sdp.utf8.count)\r\n"
                + "Content-Type: application/sdp\r\n\r\n"
                + sdp
        case "SETUP":
            // The SDS200's shape (fw 1.26.01): no ;timeout=, and Transport echoes the client port
            // with source, server_port, and ssrc added.
            let transport = request.headers["transport"] ?? ""
            var clientPort = ""
            var port: UInt16?
            if let range = transport.range(of: "client_port=") {
                let value = transport[range.upperBound...].prefix { $0.isNumber }
                port = UInt16(value)
                if let port { clientPort = "client_port=\(port);" }
            }
            let session = issueSessionID(clientPort: port)
            let serverPort = sessionServerPorts[session] ?? Self.serverPort
            let ssrc = sessionSSRCs[session] ?? Self.ssrc
            return "RTSP/1.0 200 OK\r\n"
                + "CSeq: \(cseq)\r\n"
                + "Session: \(session)\r\n"
                + "Transport: RTP/AVP;unicast;\(clientPort)source=\(Self.host);server_port=\(serverPort);ssrc=\(ssrc)\r\n\r\n"
        case "PLAY" where behavior.scannerSessions:
            let session = request.headers["session"] ?? ""
            let start = (sequence: UInt16.random(in: 0...UInt16.max), timestamp: UInt32.random(in: 0...UInt32.max))
            playStarts[session] = start
            return "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: \(session)\r\n"
                + "RTP-Info: url=rtsp://\(Self.host)/au:scanner.au/trackID=1;seq=\(start.sequence);rtptime=\(start.timestamp)\r\n\r\n"
        default:
            let session = request.headers["session"] ?? Self.sessionID
            return "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: \(session)\r\n\r\n"
        }
    }

    private static func reason(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 454: "Session Not Found"
        case 455: "Method Not Valid in This State"
        case 461: "Unsupported Transport"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }

    private func sendDelayed(_ text: String, method: String, id: Int, on connection: NWConnection) {
        replies.append((method, .now))
        noteAnswered(method, status: 200, id: id)
        send(text, on: connection)
    }

    /// A reply with `status` to a `method` request went out on connection `id`.
    private func noteAnswered(_ method: String, status: Int, id: Int) {
        guard var exchange = exchanges[id] else { return }
        exchange.unanswered -= 1
        if method == "TEARDOWN" {
            if (200..<300).contains(status) { exchange.teardownAnswered2xx = true } else { exchange.teardownAnsweredOther = true }
        }
        exchanges[id] = exchange
    }

    private func send(_ text: String, on connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    private static func receive(on connection: NWConnection) async -> (Data?, Bool, NWError?) {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                continuation.resume(returning: (data, isComplete, error))
            }
        }
    }
}
