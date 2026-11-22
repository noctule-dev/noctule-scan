// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Faults the mock can inject (`MockSDS200.setFaults(_:)`, or `--fault` on the executable).
public struct MockFaults: Sendable, Equatable {
    /// PSI pushes stop this many seconds after each subscription starts (PSI is still acked).
    public var stallPSIAfter: Double?
    /// The next GET_PARAMETER (keepalive) after this is set gets this status (e.g. 454), once.
    public var keepaliveStatus: Int?
    /// RTP stops this many seconds after each PLAY (the session itself stays up).
    public var dropAudioAfter: Double?
    /// SETUP answers 503 until `powerCycle()` or an `MSM,1` reboot: the owner's ProScan
    /// experience of audio dead until a power cycle (design §8.1). That an `MSM,1` reboot clears
    /// it is the mock's assumption, untested on hardware (protocol notes §8.8).
    public var wedgeAudio: Bool
    /// The worst case seen on hardware: when the audio server wedges, UDP control stops
    /// answering too, until `powerCycle()` (so `MSM,1` can't help).
    public var wedgeTakesControlDown: Bool
    /// Command name, e.g. "KEY": the command is carried out and its reply is not sent. Fires for the
    /// next `dropCount` matching datagrams, then clears itself (in the control server; this
    /// property keeps the value it was set to).
    public var dropNextReply: String?
    /// Command name: the datagram is logged and otherwise ignored, for the next `dropCount`
    /// matching datagrams. Shares `dropCount` with `dropNextReply`.
    public var dropNextRequest: String?
    /// How many matching datagrams each drop fault covers before it clears.
    public var dropCount: Int
    /// Command name (test-only, no CLI flag): the next `dropCount` matching datagrams are logged,
    /// not carried out, and answered `<NAME>,NG`; then it clears itself, like the drop faults. How
    /// hardware rejects an `MSV` is untried (design §4.4); this stands in for it.
    public var rejectNext: String?
    /// Serial mock only (`MockSerialScanner`): this many seconds after `start()` (or after the
    /// `setFaults(_:)` that sets it) the port closes, as when the cable is pulled. Real time, like
    /// the other timed faults.
    public var unplugAfter: Double?
    /// Serial mock only: this many seconds after that unplug a new port appears behind the same
    /// link path (without one, no client could find it; the executable requires `--serial-link`).
    public var replugAfter: Double?
    /// Serial mock only: `unplugAfter` counts from the first subscribing `PSI` (any but `PSI,0`)
    /// the mock receives, not from `start()`, so a test's "connected, then the cable goes" doesn't
    /// depend on how quickly the client got going (`--fault unplug-after-psi=N[:M]`). Once only,
    /// like `unplugAfter`.
    public var unplugCountsFromFirstPSI: Bool
    /// Serial mock only: replies and pushes are written 7 bytes at a time.
    public var splitWrites: Bool
    /// Serial mock with a line-out only (`MockLineOut`): the jack carries only its idle hiss,
    /// whatever the scanner is receiving, as when the cable or the scanner's volume is wrong.
    /// Takes effect at once.
    public var lineOutSilent: Bool
    /// Serial mock only, test-only (no CLI flag): when a subscribed client next sends `PSI,0`, the
    /// mock writes one push to it just before it handles the `PSI,0`, so that push is on the wire
    /// ahead of the `PSI,OK`, as a push in flight at the stop would be; then it clears itself. A
    /// test fault, not a claim about hardware.
    public var pushBeforeStop: Bool

    public init(stallPSIAfter: Double? = nil, keepaliveStatus: Int? = nil, dropAudioAfter: Double? = nil,
                wedgeAudio: Bool = false, wedgeTakesControlDown: Bool = false,
                dropNextReply: String? = nil, dropNextRequest: String? = nil, dropCount: Int = 1,
                rejectNext: String? = nil, unplugAfter: Double? = nil, replugAfter: Double? = nil,
                unplugCountsFromFirstPSI: Bool = false,
                splitWrites: Bool = false, lineOutSilent: Bool = false, pushBeforeStop: Bool = false) {
        self.dropNextReply = dropNextReply; self.dropNextRequest = dropNextRequest; self.dropCount = dropCount
        self.rejectNext = rejectNext
        self.unplugAfter = unplugAfter; self.replugAfter = replugAfter; self.splitWrites = splitWrites
        self.unplugCountsFromFirstPSI = unplugCountsFromFirstPSI
        self.lineOutSilent = lineOutSilent
        self.pushBeforeStop = pushBeforeStop
        self.stallPSIAfter = stallPSIAfter; self.keepaliveStatus = keepaliveStatus
        self.dropAudioAfter = dropAudioAfter; self.wedgeAudio = wedgeAudio
        self.wedgeTakesControlDown = wedgeTakesControlDown
    }

    public static let none = MockFaults()
}

/// How the wedged audio server treats new connections. On hardware the TCP connect itself times
/// out. Loopback can't drop a SYN without root, so `.timeout` accepts the connection and never
/// answers (the client's first request times out), and `.refuse` resets it at once.
public enum MockWedgeMode: String, Sendable, Equatable {
    case timeout
    case refuse
}

/// Which closes of an RTSP connection start the mock's reconnect-hazard window.
public enum MockCooldownAfter: String, Sendable, Equatable {
    /// Every close, as measured on hardware (the default).
    case any
    /// Every close except a clean one: the client closed the connection after a 2xx TEARDOWN on
    /// it, with every request on it answered. Models the owner's theory that a controlled close is
    /// safe to follow at once (Plan 5); it is not evidence about the hardware.
    case unclean
}

/// A mock SDS200 for development and tests: UDP control (`MockControlServer`), the RTSP audio
/// server (`FakeRTSPServer` with SDS200 behavior), and RTP (`FakeRTPSender`), all on loopback and
/// all driven by one `MockScenario` on one `MockClock`.
///
/// It imitates what was measured on fw 1.26.01 (protocol notes §2, §4-§6):
/// - RTSP replies in the scanner's shapes, with configurable delays (`Options.replyDelays`; zero by
///   default for unit tests, `realisticReplyDelays` in the executable). The same dictionary delays
///   UDP control replies by command name (`"MSV"`, `"KEY"`): the command takes effect at once, only
///   its reply is late.
/// - RTP at 25 packets/s, 320-byte PCMU, timestamp step 320, a new SSRC per session (advertised in
///   SETUP). While a transmission is active the payload is a sine tone at its `toneHz`; between
///   transmissions the stream carries digital silence. Whether the real stream is continuous or
///   squelch-gated is still undetermined (protocol notes §6 and §8.6: every capture had a signal),
///   so the mock keeps it continuous, which is what every capture showed.
/// - **The reconnect hazard:** a TCP connection to the RTSP port opened within
///   `Options.reconnectCooldown` (default 120 s, as on hardware) of the previous close wedges the
///   audio server until `powerCycle()` or an `MSM,1` reboot. With `Options.cooldownAfter` `.unclean`,
///   a clean close (a 2xx TEARDOWN, every request answered, closed by the client) doesn't start
///   that window. With `wedgeTakesControlDown`, control
///   goes silent too, until `powerCycle()`. **Assumption:** that `MSM,1` revives a wedged audio
///   server (554 dead, control alive) is untested on hardware (protocol notes §8.8); on the real
///   scanner only a power cycle is proven to.
/// - `MSM,1`: `MSM,OK`, silence for `Options.rebootDuration`, then a fresh audio server.
/// - Remote menus (`MockMenu`): `KEY,M,P` opens a fictional menu tree that `STS`, `GSI`/`PSI`, `MSI`
///   and `MSV` show and drive, as measured on fw 1.26.01 (design: remote menus §4); its assumptions
///   are listed on `MockMenu`. `powerCycle()` and `MSM,1` leave the menu and restore its values.
///
/// `leakedSessions` lists RTSP sessions that never got a TEARDOWN (sessions a reboot or power
/// cycle dropped don't count). Well-behaved clients leave it empty.
public actor MockSDS200 {
    public struct Options: Sendable {
        /// Scenario time (`.stepped` in tests).
        public var clock: MockClock
        /// 0 picks an ephemeral port.
        public var udpPort: UInt16
        /// 0 picks a random port in 20000-44999.
        public var rtspPort: UInt16
        public var reconnectCooldown: Duration
        /// Which closes start the hazard window (`.any`, as on hardware, by default).
        public var cooldownAfter: MockCooldownAfter
        public var wedgeMode: MockWedgeMode
        /// How long `MSM,1` keeps the scanner silent (hardware: about 10.5-12.7 s).
        public var rebootDuration: Duration
        public var replyDelays: [String: Duration]
        /// How long an `FQK` or `SQK` set holds back its reply (hardware: 0.75-0.87 s); zero under `--no-delays`.
        public var quickKeySetDelay: Duration
        /// The most elements one page of a `GLT` reply holds (`MockFavorites.defaultGLTPageSize`).
        public var gltPageSize: Int
        /// Also log every control command (`control: <cmd>`) and RTSP request (`rtsp: <method>`).
        public var verbose: Bool
        /// Receives one line per notable event (wedge, reboot, power cycle, sessions).
        public var log: (@Sendable (String) -> Void)?

        public init(clock: MockClock = .real(), udpPort: UInt16 = 0, rtspPort: UInt16 = 0,
                    reconnectCooldown: Duration = .seconds(120), cooldownAfter: MockCooldownAfter = .any,
                    wedgeMode: MockWedgeMode = .timeout,
                    rebootDuration: Duration = .seconds(10), replyDelays: [String: Duration] = [:],
                    quickKeySetDelay: Duration = .milliseconds(800),
                    gltPageSize: Int = MockFavorites.defaultGLTPageSize,
                    verbose: Bool = false, log: (@Sendable (String) -> Void)? = nil) {
            self.clock = clock; self.udpPort = udpPort; self.rtspPort = rtspPort
            self.reconnectCooldown = reconnectCooldown; self.cooldownAfter = cooldownAfter
            self.wedgeMode = wedgeMode
            self.rebootDuration = rebootDuration; self.replyDelays = replyDelays
            self.quickKeySetDelay = quickKeySetDelay
            self.gltPageSize = gltPageSize
            self.verbose = verbose; self.log = log
        }

        /// Reply times measured on fw 1.26.01 (protocol notes §6): OPTIONS ~0.05 s, DESCRIBE
        /// 0.25-0.5 s, SETUP and PLAY ~0.5 s each, GET_PARAMETER ~0.03 s, TEARDOWN ~0.17 s.
        public static let realisticReplyDelays: [String: Duration] = [
            "OPTIONS": .milliseconds(50), "DESCRIBE": .milliseconds(300), "SETUP": .milliseconds(500),
            "PLAY": .milliseconds(500), "GET_PARAMETER": .milliseconds(30), "TEARDOWN": .milliseconds(170),
        ]
    }

    public let scenario: MockScenario
    public let options: Options
    public nonisolated let control: MockControlServer
    public nonisolated let rtsp: FakeRTSPServer
    public nonisolated let sender: FakeRTPSender
    /// The active faults. Change them with `setFaults(_:)`.
    public private(set) var faults: MockFaults

    private var started = false
    private var stoppedLeaks: [String]?

    public init(scenario: MockScenario, faults: MockFaults = .none, options: Options = .init()) {
        self.scenario = scenario
        self.options = options
        self.faults = faults
        control = MockControlServer(scenario: scenario, clock: options.clock, rebootDuration: options.rebootDuration,
                                    replyDelays: options.replyDelays, personality: .sds200,
                                    quickKeySetDelay: options.quickKeySetDelay, gltPageSize: options.gltPageSize)
        rtsp = FakeRTSPServer(uniqueSessionIDs: true, behavior: FakeRTSPServer.Behavior(
            replyDelays: options.replyDelays, reconnectCooldown: options.reconnectCooldown,
            cooldownAfter: options.cooldownAfter, wedgeMode: options.wedgeMode, scannerSessions: true))
        sender = FakeRTPSender()
    }

    /// The Favorites tree and its quick-key states as they are now.
    public var favorites: MockFavorites { get async { await control.favorites } }

    /// Replaces the Favorites tree (tests move keys, rename and remove rows).
    public func setFavorites(_ favorites: MockFavorites) async { await control.setFavorites(favorites) }

    public nonisolated var clock: MockClock { options.clock }

    /// Starts control and audio and returns their ports.
    public func start() async throws -> (udpPort: UInt16, rtspPort: UInt16) {
        let scenario = self.scenario, clock = options.clock, payloadBytes = sender.payloadBytes
        await sender.setPayloadSource { index in
            MockAudio.payload(scenario.moment(at: clock.now), packetIndex: index, bytes: payloadBytes)
        }
        await rtsp.attach(sender)
        await rtsp.setEventHandler { [weak self] event in
            Task { await self?.handle(event) }
        }
        await control.setRebootHandler { [weak self] phase in
            await self?.reboot(phase)
        }
        if options.verbose, let log = options.log {
            await control.setCommandObserver { log("control: \($0)") }
        }
        let udpPort = try await control.start(port: options.udpPort)
        let rtspPort: UInt16
        do {
            rtspPort = try await rtsp.start(port: options.rtspPort)
        } catch {
            await control.stop()
            throw error
        }
        started = true
        await apply(faults, replacing: .none)
        await armDropFaults()
        return (udpPort, rtspPort)
    }

    /// Stops everything. `leakedSessions` keeps the sessions still open at this moment.
    public func stop() async {
        guard stoppedLeaks == nil else { return }
        stoppedLeaks = await rtsp.leakedSessions
        if let leaked = stoppedLeaks, !leaked.isEmpty {
            options.log?("mock: \(leaked.count) RTSP session(s) never got a TEARDOWN: \(leaked.joined(separator: ", "))")
        }
        await control.stop()
        await rtsp.stop()
        await sender.shutdown()
    }

    /// Power off and on: clears any wedge (and `wedgeAudio`), drops sessions and PSI
    /// subscriptions, and brings control back if it was down. Instant, for tests.
    public func powerCycle() async {
        await control.powerCycle()
        await rtsp.powerCycle()
        await sender.stop()
        let previous = faults
        faults.wedgeAudio = false
        await apply(faults, replacing: previous)
        options.log?("mock: power cycled")
    }

    public func setFaults(_ faults: MockFaults) async {
        let previous = self.faults
        self.faults = faults
        guard started else { return }
        await apply(faults, replacing: previous)
        await armDropFaults()
    }

    /// True while a menu screen is showing.
    public var isInMenu: Bool { get async { await control.isInMenu } }
    /// Titles of the screens from the top menu down; `[]` outside a menu.
    public var menuPath: [String] { get async { await control.menuPath } }
    /// Every state change the menu carried out, in order: `toggle <item> <On|Off>`,
    /// `set <screen> <value>`, `run <action>`.
    public var menuActions: [String] { get async { await control.menuActions } }

    /// True while the audio server is wedged (reconnect hazard).
    public var isAudioWedged: Bool { get async { await rtsp.isWedged } }
    /// False while control is down (`wedgeTakesControlDown`) or rebooting.
    public var isControlAnswering: Bool {
        get async {
            let answering = await control.isAnswering
            let rebooting = await control.isRebooting
            return answering && !rebooting
        }
    }
    /// How many times the audio server has wedged.
    public var wedgeCount: Int { get async { await rtsp.wedgeCount } }
    /// Sessions without a TEARDOWN: live ones while running, and as of `stop()` afterwards.
    public var leakedSessions: [String] {
        get async {
            if let stoppedLeaks { return stoppedLeaks }
            return await rtsp.leakedSessions
        }
    }

    // MARK: Faults

    /// Arms the drop faults from `faults`. Only `start()` and `setFaults(_:)` do, so a power cycle or
    /// reboot doesn't re-arm one that has fired.
    private func armDropFaults() async {
        await control.setDropFaults(reply: faults.dropNextReply, request: faults.dropNextRequest,
                                    count: max(1, faults.dropCount), reject: faults.rejectNext)
    }

    private func apply(_ new: MockFaults, replacing old: MockFaults) async {
        await control.setStallPSIAfter(new.stallPSIAfter)
        var script = FakeRTSPServer.Script()
        if new.wedgeAudio { script = script.status(method: "SETUP", code: 503) }
        if let status = new.keepaliveStatus {
            // Once per setting: arm it when it changes, and keep an unused one armed.
            let armed = await rtsp.currentScript.rules.contains { $0.method == "GET_PARAMETER" && $0.once }
            if armed || status != old.keepaliveStatus {
                script = script.status(method: "GET_PARAMETER", code: status, once: true)
            }
        }
        await rtsp.replaceScript(script)
        if old.wedgeTakesControlDown, !new.wedgeTakesControlDown { await control.setAnswering(true) }
        if new.wedgeTakesControlDown, !old.wedgeTakesControlDown, await rtsp.isWedged { await control.setAnswering(false) }
    }

    // MARK: Events

    private func handle(_ event: FakeRTSPServer.Event) async {
        switch event {
        case .wedged:
            options.log?("mock: audio server wedged (a connection opened within the reconnect cooldown); power-cycle or MSM,1 to clear")
            if faults.wedgeTakesControlDown {
                await control.setAnswering(false)
                options.log?("mock: control is down too (wedge-control fault); power-cycle to clear")
            }
        case .played(let session):
            options.log?("mock: session \(session) playing")
            guard let after = faults.dropAudioAfter else { return }
            let stream = await sender.streamsStarted
            let sender = self.sender
            Task {
                try? await Task.sleep(for: .milliseconds(Int(after * 1000)))
                if await sender.streamsStarted == stream { await sender.pause() }
            }
        case .tornDown(let session):
            options.log?("mock: session \(session) torn down")
        case .request(let method):
            if options.verbose { options.log?("rtsp: \(method)") }
        }
    }

    private func reboot(_ phase: MockRebootPhase) async {
        switch phase {
        case .began:
            options.log?("mock: MSM,1 accepted; rebooting")
            await rtsp.powerDown()
            await sender.stop()
        case .finished:
            await rtsp.powerUp()
            let previous = faults
            faults.wedgeAudio = false
            await apply(faults, replacing: previous)
            options.log?("mock: reboot finished")
        }
    }
}

/// The mock's synthetic audio: a sine tone during a transmission, digital silence otherwise.
enum MockAudio {
    static let sampleRate = 8000.0
    static let amplitude = 8000.0

    /// One packet's PCMU payload. The phase runs on from packet to packet within a stream.
    static func payload(_ moment: MockMoment, packetIndex: Int, bytes: Int) -> Data {
        guard case .transmission(_, let transmission) = moment, transmission.toneHz > 0 else {
            return Data(repeating: encode(0), count: bytes)
        }
        let step = 2 * Double.pi * transmission.toneHz / sampleRate
        let first = packetIndex * bytes
        return Data((0..<bytes).map { i in
            encode(Int16(amplitude * sin(step * Double(first + i))))
        })
    }

    /// ITU-T G.711 µ-law encoding (bias 132, clip 32635), the inverse of `MuLaw.decode`.
    static func encode(_ sample: Int16) -> UInt8 {
        var value = Int(sample)
        let sign: UInt8 = value < 0 ? 0x80 : 0
        if value < 0 { value = -value }
        value = min(value, 32635) + 132
        var exponent = 7
        var mask = 0x4000
        while exponent > 0, value & mask == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (value >> (exponent + 3)) & 0x0F
        return ~(sign | UInt8(exponent << 4) | UInt8(mantissa))
    }
}
