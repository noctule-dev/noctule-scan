// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

// `noctule`'s line-in commands, launched as a subprocess (Plan 19). Every launch gets the
// kill-switch (`NOCTULE_NO_USB_DETECTION=1`), so no audio input is listed or opened, and runs in a
// temporary directory, where `noctule` finds no `config/dev-scanner.env`. Nothing here reaches Core
// Audio or the microphone permission request. All names and values are fictional.

/// Connects to the jack at `path` (waiting for its socket for at most `limit` seconds) and returns
/// when each of the first `reads` reads that brought audio returned, or those within `limit`
/// seconds. Blocks the calling thread (a dispatch thread, not a cooperative one).
private func jackArrivals(_ path: String, reads: Int, limit: Double) -> [ContinuousClock.Instant] {
    let deadline = ContinuousClock.now + .milliseconds(Int(limit * 1000))
    var fd: Int32 = -1
    while fd < 0, ContinuousClock.now < deadline {
        let candidate = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 {
            fd = candidate
        } else {
            Darwin.close(candidate)
            Thread.sleep(forTimeInterval: 0.05)  // off the cooperative pool: a dispatch thread
        }
    }
    guard fd >= 0 else { return [] }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var arrivals: [ContinuousClock.Instant] = []
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while arrivals.count < reads, ContinuousClock.now < deadline {
        let count = recv(fd, &buffer, buffer.count, 0)
        if count > 0 { arrivals.append(.now) } else if count == 0 { break }
    }
    return arrivals
}

@Suite(.timeLimit(.minutes(1))) struct LineInCLIIntegrationTests {
    /// Runs `noctule` in a temporary directory with the kill-switch (plus `extra`) to completion.
    private func run(_ arguments: [String], extra: [String: String] = [:]) async throws
        -> (exited: Bool, status: Int32, stdout: String, stderr: String) {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let environment = ["NOCTULE_NO_USB_DETECTION": "1"].merging(extra) { _, new in new }
        let process = try Subprocess(try noctuleBinary(), arguments, environment: environment, currentDirectory: dir)
        let exited = await process.waitForExit(within: 20)
        process.kill()
        let result = await process.finish()
        return (exited, result.status, result.stdout, result.stderr)
    }

    @Test func audioInputsUnderTheKillSwitchListsNone() async throws {
        let result = try await run(["audio-inputs"])
        #expect(result.exited)
        #expect(result.status == 0)
        #expect(result.stdout == "No audio inputs found.\n")
        #expect(result.stderr.isEmpty)
    }

    @Test func audioInputsTakesNoHostFlag() async throws {
        let result = try await run(["audio-inputs", "--host", "x"])
        #expect(result.exited)
        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("--host doesn't apply to audio-inputs"))
    }

    @Test func audioInputsSaysWhenTheTestStreamIsInEffect() async throws {
        let result = try await run(["audio-inputs"], extra: ["NOCTULE_TEST_LINE_IN": "/tmp/fictional-jack.sock"])
        #expect(result.status == 0)
        #expect(result.stdout == "No audio inputs found.\n")
        #expect(result.stderr.contains(
            "noctule: test override: NOCTULE_TEST_LINE_IN=/tmp/fictional-jack.sock (in place of the line-in device)"))
    }

    // MARK: station add

    /// Runs `noctule` with the kill-switch and `--settings-dir <settings>`.
    private func station(_ arguments: [String], settings: URL) async throws
        -> (exited: Bool, status: Int32, stdout: String, stderr: String) {
        try await run(arguments + ["--settings-dir", settings.path])
    }

    private func settingsDirectory() throws -> URL {
        let dir = try temporaryDirectory().appending(path: "settings")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func stationAddUnderTheKillSwitchSavesAnID() async throws {
        let settings = try settingsDirectory()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let add = try await station(["station", "add", "--name", "Line", "--usb", "--serial-port", "/tmp/fictional-port",
                                     "--audio-input", "UID-9", "--audio-channel", "right"], settings: settings)
        #expect(add.exited && add.status == 0, "\(add.stdout) \(add.stderr)")
        #expect(add.stderr.contains("station: saved \"UID-9\" as an audio input ID (no inputs are listed)"))
        #expect(add.stdout == "added station \"Line\" (USB /tmp/fictional-port, save audio: every, line-in UID-9 (right))\n")
        let device = try String(contentsOf: settings.appending(path: "device.json"), encoding: .utf8)
        #expect(device.contains("\"audioInputDevice\" : \"UID-9\""), "\(device)")
        #expect(device.contains("\"audioInputChannel\" : \"right\""), "\(device)")
        // JSON escapes the slashes of a path, so look for the key and the name, not the text between.
        #expect(device.contains("\"usbPort\"") && device.contains("fictional-port"), "\(device)")
        let list = try await station(["station", "list"], settings: settings)
        #expect(list.status == 0)
        #expect(list.stdout == "  Line  USB /tmp/fictional-port  line-in UID-9 (right)  save audio: every\n", "\(list.stdout)")
    }

    @Test func stationAddWithoutAChannelSavesNone() async throws {
        let settings = try settingsDirectory()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let add = try await station(["station", "add", "--name", "Line", "--usb", "--audio-input", "UID-9"], settings: settings)
        #expect(add.status == 0, "\(add.stdout) \(add.stderr)")
        let device = try String(contentsOf: settings.appending(path: "device.json"), encoding: .utf8)
        #expect(device.contains("\"audioInputDevice\" : \"UID-9\"") && !device.contains("audioInputChannel"), "\(device)")
        let list = try await station(["station", "list"], settings: settings)
        #expect(list.stdout == "  Line  USB  line-in UID-9 (both)  save audio: every\n", "\(list.stdout)")
    }

    @Test func stationAddAudioInputRefusalsExit64AndSaveNothing() async throws {
        let settings = try settingsDirectory()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let network = try await station(["station", "add", "--name", "Net", "--host", "127.0.0.1", "--audio-input", "UID-9"],
                                        settings: settings)
        #expect(network.status == 64)
        #expect(network.stderr.contains("--audio-input needs --usb"))
        let channel = try await station(["station", "add", "--name", "Line", "--usb", "--audio-channel", "left"], settings: settings)
        #expect(channel.status == 64)
        #expect(channel.stderr.contains("--audio-channel needs --audio-input"))
        let middle = try await station(["station", "add", "--name", "Line", "--usb", "--audio-input", "UID-9",
                                        "--audio-channel", "middle"], settings: settings)
        #expect(middle.status == 64)
        #expect(!FileManager.default.fileExists(atPath: settings.appending(path: "stations.json").path))
        #expect(!FileManager.default.fileExists(atPath: settings.appending(path: "device.json").path))
    }

    // MARK: log

    /// One transmission on a conventional channel, 0.5 s in; the scenario loops.
    private static let logScenario = """
        {
          "model": "SDS150",
          "firmware": "1.01.02",
          "loop": true,
          "mode": "trunk",
          "idle": { "system": "Lakeview County", "site": "Lakeview Simulcast", "frequencyMHz": 851.0125,
                    "modulation": "NFM", "rssi": -999 },
          "transmissions": [
            { "at": 0.5, "duration": 1.5, "system": "Lakeview County", "department": "Lakeview Public Works",
              "channel": "County Roads", "tgid": "3301", "unitID": "6101", "frequencyMHz": 851.2375,
              "modulation": "NFM", "toneOrCode": "NAC 2A1h", "rssi": -62, "programmed": true, "toneHz": 440 }
          ]
        }
        """

    /// A test's directories: the mock's link, settings, recordings and scenario in a temporary
    /// directory, and the mock's headphone jack in a short directory of its own (a Unix-domain
    /// socket's path holds 103 bytes; LESSONS.md 2026-11-17). Removed by `cleanUp()`.
    private struct LogRig {
        let root: URL
        let jackRoot: URL
        var link: URL { root.appending(path: "port") }
        var settings: URL { root.appending(path: "settings") }
        var recordings: URL { root.appending(path: "recordings") }
        var cooldownStore: URL { root.appending(path: "cooldown.json") }
        var scenario: URL { root.appending(path: "scenario.json") }
        var jack: URL { jackRoot.appending(path: "jack.sock") }
        var decoy: URL { root.appending(path: "decoy-port") }

        init() throws {
            root = try temporaryDirectory()
            jackRoot = FileManager.default.temporaryDirectory.appending(path: "nl-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: jackRoot, withIntermediateDirectories: true)
            try LineInCLIIntegrationTests.logScenario.write(to: scenario, atomically: true, encoding: .utf8)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: jackRoot)
        }

        /// The kill-switch and a decoy port listing; `lineIn` adds the test stream.
        func environment(lineIn: Bool) -> [String: String] {
            var environment = ["NOCTULE_NO_USB_DETECTION": "1", "NOCTULE_TEST_SERIAL_PORTS": decoy.path]
            if lineIn { environment["NOCTULE_TEST_LINE_IN"] = jack.path }
            return environment
        }

        var logFlags: [String] {
            ["--settings-dir", settings.path, "--recordings", recordings.path,
             "--cooldown-seconds", "1", "--cooldown-store", cooldownStore.path]
        }

        func files() -> [String] {
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        }

        /// Every `.wav` under the recordings folder.
        func wavs() -> [URL] {
            (FileManager.default.enumerator(at: recordings, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "wav" }
        }

        /// Runs `noctule` in the rig's directory to completion (killed after `limit` seconds).
        func noctule(_ arguments: [String], lineIn: Bool, limit: Double = 30) async throws
            -> (exited: Bool, status: Int32, stdout: String, stderr: String) {
            let process = try Subprocess(try noctuleBinary(), arguments, environment: environment(lineIn: lineIn),
                                         currentDirectory: root)
            let exited = await process.waitForExit(within: limit)
            process.kill()
            let result = await process.finish()
            return (exited, result.status, result.stdout, result.stderr)
        }

        /// Starts `noctule` in the rig's directory and returns at once.
        func start(_ arguments: [String], lineIn: Bool) throws -> Subprocess {
            try Subprocess(try noctuleBinary(), arguments, environment: environment(lineIn: lineIn), currentDirectory: root)
        }

        /// `listen --station "Test Handheld" --no-play --settings-dir <settings>` plus `extra`.
        func listenArguments(_ extra: [String]) -> [String] {
            ["listen", "--station", "Test Handheld", "--no-play", "--settings-dir", settings.path] + extra
        }

        /// Adds the USB station "Test Handheld" on `port` with the audio input `fictional-input-1`
        /// (saved as an ID: the kill-switch lists no inputs).
        func addLineInStation(port: String) async throws {
            let add = try await noctule(["station", "add", "--name", "Test Handheld", "--usb", "--serial-port", port,
                                         "--audio-input", "fictional-input-1", "--settings-dir", settings.path],
                                        lineIn: false)
            #expect(add.exited && add.status == 0, "\(add.stdout) \(add.stderr)")
        }
    }

    /// `log` on a USB station with a line-in: the one `audio: line-in` line in place of `no audio
    /// over USB`, a WAV for each recorded hit that its end line names, nothing about the RTSP
    /// cooldown, and a subscription closed with `PSI,0`. The mock's headphone jack stands in for the
    /// device (`NOCTULE_TEST_LINE_IN`, honoured with the kill-switch), so `LineInSupport.factory`
    /// runs its `.testStream` case. The scenario loops every 2.5 s from a random phase, so the first
    /// hit may already be on air when the input starts streaming and the last may be cut off by the
    /// stop: either can fall under the station's minimum duration and go unrecorded (no file, no
    /// `→`), as the product means it to. Every hit between them is whole and must be recorded, and 6 s
    /// always holds one.
    @Test func logRecordsALineInHit() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let mock = try await SerialMock.launch(link: rig.link, ["--scenario", rig.scenario.path, "--line-out", rig.jack.path])
        do {
            try await rig.addLineInStation(port: mock.port)
            let log = try await rig.noctule(["log", "--seconds", "6"] + rig.logFlags, lineIn: true)
            #expect(log.exited && log.status == 0, "\(log.status) \(log.stdout) \(log.stderr)")
            #expect(log.stderr.contains("noctule: test override: NOCTULE_TEST_LINE_IN=\(rig.jack.path) (in place of the line-in device)"),
                    "\(log.stderr)")
            #expect(log.stderr.contains("log: connected to SDS150 (firmware 1.01.02)\naudio: line-in fictional-input-1 (both)\n"),
                    "\(log.stderr)")
            #expect(!log.stderr.contains("no audio over USB"), "\(log.stderr)")
            #expect(!log.stderr.contains("disabled by"), "\(log.stderr)")
            let starts = log.stdout.components(separatedBy: "\n").filter { $0.contains("  + ") }
            let ends = log.stdout.components(separatedBy: "\n").filter { $0.contains("  - ") }
            #expect(!starts.isEmpty && starts.count == ends.count, "\(log.stdout)")
            #expect(ends.allSatisfy { $0.contains("TG3301 County Roads") }, "\(log.stdout)")
            // Recorded hits name a WAV (never `(no audio: …)`), and there is at least one.
            let recorded = ends.filter { $0.contains("  → ") }
            #expect(!recorded.isEmpty, "no recorded hit: \(log.stdout)")
            #expect(recorded.allSatisfy { $0.hasSuffix(".wav") }, "\(log.stdout)")
            // Only the first and the last hit may go unrecorded.
            for (index, line) in ends.enumerated() where !line.contains("  → ") {
                #expect(index == 0 || index == ends.count - 1, "hit \(index + 1) of \(ends.count) unrecorded: \(log.stdout)")
            }
            let wavs = rig.wavs()
            #expect(wavs.count == recorded.count, "\(wavs.map(\.lastPathComponent)) \(log.stdout)")
            for wav in wavs {
                let data = try Data(contentsOf: wav)
                #expect(data.count > 44, "\(wav.lastPathComponent)")
                #expect(recorded.contains { $0.hasSuffix("  → " + wav.lastPathComponent) }, "\(wav.lastPathComponent) \(log.stdout)")
            }
            #expect(!rig.files().contains { $0.contains("cooldown") }, "\(rig.files())")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.first == "MDL" && mock.commands.last == "PSI,0", "\(mock.commands)")
        #expect(!mock.commands.contains { $0.hasPrefix("MSM") || $0.hasPrefix("POF") || $0.hasPrefix("KEY") }, "\(mock.commands)")
    }

    /// The same station under the kill-switch with no test stream: the saved input is never
    /// opened (`LineInSupport.factory`'s `.disabled` case), `log` says so, logs the hits with no
    /// audio, and exits 0.
    @Test func logUnderTheKillSwitchWarns() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let mock = try await SerialMock.launch(link: rig.link, ["--scenario", rig.scenario.path])
        do {
            try await rig.addLineInStation(port: mock.port)
            let log = try await rig.noctule(["log", "--seconds", "4"] + rig.logFlags, lineIn: false)
            #expect(log.exited && log.status == 0, "\(log.status) \(log.stdout) \(log.stderr)")
            #expect(log.stderr.components(separatedBy: "\n")
                .filter { $0 == "warning: audio input disabled by NOCTULE_NO_USB_DETECTION" }.count == 1, "\(log.stderr)")
            // The warning alone: no `audio: line-in` line for an input this run won't open.
            #expect(!log.stderr.contains("audio: line-in"), "\(log.stderr)")
            #expect(!log.stderr.contains("no audio over USB"), "\(log.stderr)")
            #expect(!log.stderr.contains("test override"), "\(log.stderr)")
            let ends = log.stdout.components(separatedBy: "\n").filter { $0.contains("  - ") }
            #expect(!ends.isEmpty, "\(log.stdout)")
            #expect(!log.stdout.contains("→"), "\(log.stdout)")
            #expect(rig.wavs().isEmpty, "\(rig.files())")
            #expect(!rig.files().contains { $0.contains("cooldown") }, "\(rig.files())")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.first == "MDL" && mock.commands.last == "PSI,0", "\(mock.commands)")
    }

    // MARK: listen --station

    /// The line `listen` prints while the input streams, and while it is missing.
    private static let streamingLine = "audio: line-in fictional-input-1 (both)"
    private static let waitingLine = "audio: line-in \"fictional-input-1\" isn't connected; waiting"

    /// A WAV's data size in bytes, after checking that its header is whole (the file was closed).
    private func closedWAVDataSize(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            Issue.record("\(url.lastPathComponent) holds \(data.count) bytes, no whole header", sourceLocation: sourceLocation)
            return 0
        }
        func le32(_ offset: Int) -> Int {
            data[offset..<offset + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        }
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF", sourceLocation: sourceLocation)
        #expect(le32(24) == 8000, sourceLocation: sourceLocation)
        let size = le32(40)
        #expect(size == data.count - 44, "data size \(size), file \(data.count)", sourceLocation: sourceLocation)
        #expect(le32(4) == size + 36, sourceLocation: sourceLocation)
        return size
    }

    /// `listen --station` on a line-in station plays and records the input alone: the scanner's port
    /// is never opened (the mock hears nothing), no station lock, hit log or cooldown record is
    /// made, and the WAV holds the run's three seconds of 16-bit 8 kHz audio.
    /// The mock's headphone jack writes each 20 ms block as it falls due even when its thread
    /// would wake late (a throttled process, as on the CI runner, LESSONS.md 2026-11-20): run under
    /// `taskpolicy -c utility`, its audio still comes every block (a median gap of 20 ms between
    /// reads), not once per late wakeup (37 to 43 ms with the `usleep` it had).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: taskpolicyPath), "no \(taskpolicyPath) to throttle the mock"))
    func theJackKeepsItsPaceWhenTheMockIsThrottled() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let mock = try await SerialMock.launch(
            link: rig.link, ["--scenario", rig.scenario.path, "--line-out", rig.jack.path], throttled: true)
        let jack = rig.jack.path
        let arrivals = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: jackArrivals(jack, reads: 40, limit: 10)) }
        }
        await mock.shutdown()
        try #require(arrivals.count == 40, "\(arrivals.count) reads with audio in 10 s")
        let gaps = zip(arrivals, arrivals.dropFirst()).map { $1 - $0 }.sorted()
        let median = gaps[gaps.count / 2]
        #expect(median <= .milliseconds(30), "median gap \(median) between reads of the jack; gaps \(gaps)")
    }

    @Test func listenRecordsALineIn() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let mock = try await SerialMock.launch(link: rig.link, ["--scenario", rig.scenario.path, "--line-out", rig.jack.path])
        do {
            try await rig.addLineInStation(port: mock.port)
            let wav = rig.root.appending(path: "out.wav")
            // The recording is held to the times seen here, not to a fixed 3 s: `--seconds` counts
            // from the start, so a slow start (a throttled process, the CI runner) leaves less to
            // record (LESSONS.md 2026-11-20). Each time is seen at or after its event, which only
            // lowers the floor below and raises the ceiling.
            let launched = ContinuousClock.now
            let process = try rig.start(rig.listenArguments(["--seconds", "3", "--record", wav.path]), lineIn: true)
            _ = await process.waitForStderr(within: 15) { $0.contains(Self.streamingLine) }
            let streamingSeen = ContinuousClock.now
            let exited = await process.waitForExit(within: 30)
            let exitSeen = ContinuousClock.now
            process.kill()
            let result = await process.finish()
            let listen = (exited: exited, status: result.status, stdout: result.stdout, stderr: result.stderr)
            #expect(listen.exited && listen.status == 0, "\(listen.status) \(listen.stderr)")
            #expect(listen.stderr.contains("\(Self.streamingLine)\n"), "\(listen.stderr)")
            #expect(!listen.stderr.contains("isn't connected"), "\(listen.stderr)")
            #expect(!listen.stderr.contains("line-in ▇") && !listen.stderr.contains("line-in ·"), "no meter without --meter")
            #expect(listen.stdout.isEmpty, "\(listen.stdout)")
            let size = try closedWAVDataSize(wav)
            // 16000 bytes a second (16-bit 8 kHz mono): what streamed until the stop 3 s after the
            // start, give or take 0.5 s, and never more than the run lasted.
            func bytes(_ duration: Duration) -> Int { Int(Double(duration / .milliseconds(1)) * 16) }
            let streamed = launched + .seconds(3) - streamingSeen
            #expect(size >= bytes(streamed - .milliseconds(500)), "data size \(size): streamed \(streamed)")
            #expect(size <= bytes(exitSeen - launched), "data size \(size): the run lasted \(exitSeen - launched)")
            let files = rig.files()
            #expect(!files.contains { $0.contains("cooldown") || $0 == "runner.lock" || $0.hasPrefix("hits.sqlite") }, "\(files)")
            try? FileManager.default.removeItem(at: wav)
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.isEmpty, "listen sent the scanner \(mock.commands)")
    }

    /// `listen --station` beside a `log` on the same station: `log` holds the station lock and the
    /// serial port, and `listen` needs neither (Ruling P2: the `log` runs without the test stream, so
    /// the mock's one headphone-jack client is `listen`'s).
    @Test func listenTakesNoStationLock() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let mock = try await SerialMock.launch(link: rig.link, ["--scenario", rig.scenario.path, "--line-out", rig.jack.path])
        do {
            try await rig.addLineInStation(port: mock.port)
            let log = try rig.start(["log"] + rig.logFlags, lineIn: false)
            let connected = await log.waitForStderr(within: 15) { $0.contains("log: connected to SDS150") }
            #expect(connected, "\(log.stderr)")
            let listen = try await rig.noctule(rig.listenArguments(["--seconds", "2"]), lineIn: true)
            #expect(listen.exited && listen.status == 0, "\(listen.status) \(listen.stderr)")
            #expect(listen.stderr.contains("\(Self.streamingLine)\n"), "\(listen.stderr)")
            #expect(!listen.stderr.contains("is open in another Noctule Scan process"), "\(listen.stderr)")
            #expect(!listen.stderr.contains("in use by another program"), "\(listen.stderr)")
            #expect(log.isRunning, "\(log.stderr)")
            log.interrupt()
            let logExited = await log.waitForExit(within: 15)
            log.kill()
            let logResult = await log.finish()
            #expect(logExited && logResult.status == 130, "\(logResult.status) \(logResult.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        // Only the log's connection: one MDL, and its subscription ended.
        #expect(mock.commands.filter { $0 == "MDL" }.count == 1, "\(mock.commands)")
        #expect(mock.commands.last == "PSI,0", "\(mock.commands)")
    }

    /// The input isn't there when `listen` starts, comes, goes (unplugged mid-run) and comes back:
    /// `listen` waits each time, records again by itself, and draws no meter line while it waits.
    @Test func listenWaitsForAMissingInput() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        try await rig.addLineInStation(port: rig.link.path)
        let wav = rig.root.appending(path: "out.wav")
        let listen = try rig.start(rig.listenArguments(["--meter", "--record", wav.path]), lineIn: true)
        func count(_ line: String) -> Int { listen.stderr.components(separatedBy: "\n").filter { $0 == line }.count }
        var mocks: [SerialMock] = []
        do {
            #expect(await listen.waitForStderr(within: 10) { $0.contains(Self.waitingLine) }, "\(listen.stderr)")
            #expect(listen.isRunning)
            mocks.append(try await SerialMock.launch(link: rig.link, ["--scenario", rig.scenario.path, "--line-out", rig.jack.path]))
            #expect(await listen.waitForStderr(within: 10) { $0.contains(Self.streamingLine) }, "\(listen.stderr)")
            try await Task.sleep(for: .seconds(1.5))
            await mocks[0].shutdown()  // the input goes away mid-run
            #expect(await listen.waitForStderr(within: 10) { _ in count(Self.waitingLine) == 2 }, "\(listen.stderr)")
            try await Task.sleep(for: .seconds(2.2))  // two meter periods with the input missing
            mocks.append(try await SerialMock.launch(link: rig.link, ["--scenario", rig.scenario.path, "--line-out", rig.jack.path]))
            #expect(await listen.waitForStderr(within: 10) { _ in count(Self.streamingLine) == 2 }, "\(listen.stderr)")
            try await Task.sleep(for: .seconds(1.5))
            #expect(listen.isRunning, "\(listen.stderr)")
        } catch {
            Issue.record(error)
        }
        listen.interrupt()
        let exited = await listen.waitForExit(within: 10)
        listen.kill()
        let result = await listen.finish()
        if mocks.count == 2 { await mocks[1].shutdown() } else if mocks.count == 1, mocks[0].process.isRunning { await mocks[0].shutdown() }
        #expect(exited && result.status == 130, "\(result.status) \(result.stderr)")
        // No meter line between the second unplug and the input's return: no stale bar.
        let lines = result.stderr.components(separatedBy: "\n")
        if let gone = lines.lastIndex(of: Self.waitingLine), let back = lines.lastIndex(of: Self.streamingLine), gone < back {
            #expect(!lines[gone..<back].contains { $0.hasPrefix("line-in ") }, "\(lines[gone..<back])")
        } else {
            Issue.record("expected a waiting line, then a streaming line: \(result.stderr)")
        }
        #expect(lines.contains { $0.hasPrefix("line-in ") && $0.contains(" dBFS") }, "a meter line while streaming")
        // Audio from both spells: at least 2 s of the about 3 s streamed.
        if FileManager.default.fileExists(atPath: wav.path) {
            let size = try closedWAVDataSize(wav)
            #expect(size >= 32_000, "data size \(size)")
        } else {
            Issue.record("no recording at \(wav.path)")
        }
        #expect(mocks.allSatisfy { $0.commands.isEmpty }, "\(mocks.map(\.commands))")
        try? FileManager.default.removeItem(at: wav)
    }

    /// With stderr a pipe, the meter is one plain line a second, never redrawn with `\r`.
    @Test func meterPipedIsOneLineASecond() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let mock = try await SerialMock.launch(link: rig.link, ["--scenario", rig.scenario.path, "--line-out", rig.jack.path])
        do {
            try await rig.addLineInStation(port: mock.port)
            let listen = try await rig.noctule(rig.listenArguments(["--meter", "--seconds", "3"]), lineIn: true)
            #expect(listen.exited && listen.status == 0, "\(listen.status) \(listen.stderr)")
            #expect(!listen.stderr.contains("\r"), "\(listen.stderr.debugDescription)")
            #expect(!listen.stderr.contains("\u{1B}"), "\(listen.stderr.debugDescription)")
            let meters = listen.stderr.components(separatedBy: "\n").filter { $0.hasPrefix("line-in ") }
            #expect((2...4).contains(meters.count), "\(meters)")
            #expect(meters.allSatisfy { $0.contains(" peak ") && $0.contains(" dBFS") && $0.contains("|") }, "\(meters)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.isEmpty, "\(mock.commands)")
    }

    /// The kill-switch with an input saved in the station and no test stream: nothing is opened,
    /// `listen` exits 1 with the reason, and `--record` leaves no file (the input never streamed).
    @Test func listenUnderTheKillSwitchExits1() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        try await rig.addLineInStation(port: rig.link.path)
        let wav = rig.root.appending(path: "out.wav")
        let listen = try await rig.noctule(rig.listenArguments(["--meter", "--seconds", "5", "--record", wav.path]),
                                           lineIn: false, limit: 10)
        #expect(listen.exited && listen.status == 1, "\(listen.status) \(listen.stderr)")
        #expect(!FileManager.default.fileExists(atPath: wav.path), "an empty recording was left at \(wav.path)")
        try? FileManager.default.removeItem(at: wav)
        #expect(listen.stderr.contains("audio input disabled by NOCTULE_NO_USB_DETECTION"), "\(listen.stderr)")
        #expect(!listen.stderr.contains(Self.streamingLine) && !listen.stderr.contains("test override"), "\(listen.stderr)")
        #expect(!listen.stderr.contains("line-in ▇") && !listen.stderr.contains("line-in ·"), "\(listen.stderr)")
    }

    /// The data size a WAV's header gives as it stands (the writer patches it at each flush), or nil
    /// while the file has no whole header.
    private func headerDataSize(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url), data.count >= 44 else { return nil }
        return data[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    }

    /// Ctrl-C stops `listen` with 130, after the WAV is closed: it holds every sample up to the
    /// signal. The writer flushes once a second (patching the header's data size) and keeps the rest
    /// in memory until `close()`. The test watches the header for a flush, reads the size half a
    /// second later, then sends the signal: a run that closes the WAV ends with more than that (half
    /// a second of audio came after the flush), and one that skipped the close leaves exactly that
    /// size (the flush task is cancelled as the stop begins, so no flush comes after the signal).
    /// No margin depends on how fast the run starts or stops.
    @Test func listenStopsOnSIGINT() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let mock = try await SerialMock.launch(link: rig.link, ["--scenario", rig.scenario.path, "--line-out", rig.jack.path])
        let wav = rig.root.appending(path: "out.wav")
        do {
            try await rig.addLineInStation(port: mock.port)
            let listen = try rig.start(rig.listenArguments(["--record", wav.path]), lineIn: true)
            #expect(await listen.waitForStderr(within: 10) { $0.contains(Self.streamingLine) }, "\(listen.stderr)")
            // Wait for a flush that wrote audio: the header's size grows.
            let first = headerDataSize(wav) ?? 0
            let deadline = ContinuousClock.now + .seconds(5)
            var flushed: ContinuousClock.Instant?
            while ContinuousClock.now < deadline {
                if let size = headerDataSize(wav), size > first { flushed = .now; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(flushed != nil, "no flush seen in 5 s: \(listen.stderr)")
            if let flushed { try await Task.sleep(until: flushed + .milliseconds(500)) }
            let before = headerDataSize(wav) ?? 0
            listen.interrupt()
            let exited = await listen.waitForExit(within: 10)
            listen.kill()
            let result = await listen.finish()
            #expect(exited && result.status == 130, "\(result.status) \(result.stderr)")
            let lowered = result.stderr.lowercased()
            #expect(!lowered.contains("failed") && !lowered.contains("error"), "\(result.stderr)")
            let size = try closedWAVDataSize(wav)
            // At least one more 320-sample chunk (640 bytes) than the last flush before the signal.
            #expect(size >= before + 640, "data size \(size), \(before) at the last flush before the signal")
        } catch {
            Issue.record(error)
        }
        try? FileManager.default.removeItem(at: wav)
        await mock.shutdown()
        #expect(mock.commands.isEmpty, "\(mock.commands)")
    }

    /// A USB station with no audio input has nothing to listen to.
    @Test func listenStationWithoutAnInputExits1() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let add = try await rig.noctule(["station", "add", "--name", "Test Handheld", "--usb", "--serial-port", rig.link.path,
                                         "--settings-dir", rig.settings.path], lineIn: false)
        #expect(add.status == 0, "\(add.stderr)")
        let listen = try await rig.noctule(rig.listenArguments(["--seconds", "2"]), lineIn: true, limit: 10)
        #expect(listen.exited && listen.status == 1, "\(listen.status) \(listen.stderr)")
        #expect(listen.stderr.contains("listen: Test Handheld has no audio input\n"), "\(listen.stderr)")
        let missing = try await rig.noctule(["listen", "--station", "Nobody", "--no-play", "--settings-dir", rig.settings.path],
                                            lineIn: true, limit: 10)
        #expect(missing.status == 1, "\(missing.stderr)")
        #expect(missing.stderr.contains("listen: no station named \"Nobody\""), "\(missing.stderr)")
    }

    /// `--station` and an address, or `--meter` with no line-in station, are refused before anything is read.
    @Test func listenStationRefusalsExit2() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let host = try await rig.noctule(rig.listenArguments(["--host", "127.0.0.1"]), lineIn: false, limit: 10)
        #expect(host.status == 2, "\(host.stderr)")
        #expect(host.stderr.contains("listen: --station can't be combined with --host or --rtsp-port"), "\(host.stderr)")
        let meter = try await rig.noctule(["listen", "--meter", "--no-play", "--host", "127.0.0.1"], lineIn: false, limit: 10)
        #expect(meter.status == 2, "\(meter.stderr)")
        #expect(meter.stderr.contains("listen: --meter needs a line-in station"), "\(meter.stderr)")
    }

    /// A network station gives `listen` its host, RTSP port and reconnect wait. Against the network
    /// mock (hazard only after unclean closes) with a private cooldown store: a station whose wait is
    /// 0 connects again at once after a clean stop; one with the default waits the (mock-only) full value.
    @Test func listenStationPicksTheNetworkAddress() async throws {
        let rig = try LogRig()
        defer { rig.cleanUp() }
        let mock = try await MockScanner.launch(["--cooldown-seconds", "3", "--cooldown-after", "unclean", "--no-delays"])
        do {
            for (name, wait) in [("Test Base", ["--reconnect-cooldown", "0"]), ("Test Base Two", [])] {
                let add = try await rig.noctule(["station", "add", "--name", name, "--host", "127.0.0.1",
                                                 "--udp-port", String(mock.udpPort), "--rtsp-port", String(mock.rtspPort),
                                                 "--settings-dir", rig.settings.path] + wait, lineIn: false)
                #expect(add.status == 0, "\(add.stderr)")
            }
            func listen(_ name: String) async throws -> (exited: Bool, status: Int32, stdout: String, stderr: String) {
                try await rig.noctule(["listen", "--station", name, "--no-play", "--seconds", "1", "--settings-dir", rig.settings.path,
                                       "--cooldown-seconds", "3", "--cooldown-store", rig.cooldownStore.path], lineIn: false)
            }
            let first = try await listen("Test Base")
            #expect(first.status == 0 && first.stderr.contains("audio: streaming"), "\(first.status) \(first.stderr)")
            #expect(first.stdout.contains("packets "), "\(first.stdout)")
            let second = try await listen("Test Base")
            #expect(second.status == 0 && second.stderr.contains("audio: streaming"), "\(second.status) \(second.stderr)")
            #expect(!second.stderr.contains("waiting"), "the station's 0 s wait: \(second.stderr)")
            let third = try await listen("Test Base Two")
            #expect(third.status == 0 && third.stderr.contains("audio: streaming"), "\(third.status) \(third.stderr)")
            #expect(third.stderr.contains("before reconnecting (scanner cooldown)"), "\(third.stderr)")
            let record = (try? String(contentsOf: rig.cooldownStore, encoding: .utf8)) ?? ""
            #expect(record.contains("127.0.0.1"), "cooldown store: \(record)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.stderr.components(separatedBy: "\n").filter { $0 == "rtsp: TEARDOWN" }.count == 3, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
    }
}
