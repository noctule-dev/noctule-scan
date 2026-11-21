// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization
import Testing

// The `noctule` CLI against the `noctule-mock-scanner` executable, both launched as subprocesses
// on loopback (ephemeral ports). Every wait is bounded, and every subprocess is interrupted (then
// killed if needed) on every path.

private func le32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
}

private func le16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

/// Sends `PSI,<interval>` to the mock's UDP port on 127.0.0.1 and returns when each of the first
/// `count` pushes arrived, or those that came within `limit` seconds; then `PSI,0`. Blocks the
/// calling thread (a dispatch thread, not a cooperative one).
private func pushArrivals(port: UInt16, interval: Int, count: Int, limit: Double) -> [ContinuousClock.Instant] {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return [] }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return [] }
    func sendLine(_ text: String) { _ = Array((text + "\r").utf8).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) } }
    sendLine("PSI,\(interval)")
    defer { sendLine("PSI,0") }
    var arrivals: [ContinuousClock.Instant] = []
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let deadline = ContinuousClock.now + .milliseconds(Int(limit * 1000))
    while arrivals.count < count, ContinuousClock.now < deadline {
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else { continue }
        let text = String(decoding: buffer[0..<received], as: UTF8.self)
        if text.hasPrefix("PSI,"), !text.hasPrefix("PSI,OK") { arrivals.append(.now) }
    }
    return arrivals
}

@Suite(.timeLimit(.minutes(1))) struct MockScannerIntegrationTests {
    /// `quick-keys` over the network (design §5.3): the tree printed, and the mock's log holds
    /// `MDL` and reads only. Run from a temporary directory with the kill-switch, as the serial ones.
    @Test func quickKeysOverTheNetwork() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = try await MockScanner.launch(["--no-delays"])
        var run: (exited: Bool, status: Int32, stdout: String, stderr: String)?
        do {
            let process = try Subprocess(
                try noctuleBinary(), ["quick-keys", "--host", "127.0.0.1", "--port", String(mock.udpPort)],
                environment: ["NOCTULE_NO_USB_DETECTION": "1"], currentDirectory: directory)
            let exited = await process.waitForExit(within: 20)
            process.kill()
            let result = await process.finish()
            run = (exited, result.status, result.stdout, result.stderr)
        } catch {
            Issue.record(error)
        }
        let shutdown = await mock.shutdown()
        #expect(run?.exited == true && run?.status == 0, "\(run?.stderr ?? "no run")")
        #expect(run?.stdout.components(separatedBy: "\n").first == "F0    on   Mock Police", "\(run?.stdout ?? "")")
        #expect(shutdown.stdout.contains("leaked-sessions=0"), "\(shutdown.stdout)")
        let commands = SerialMock.commands(in: shutdown.stderr)
        #expect(commands.first == "MDL", "\(commands)")
        for command in commands.dropFirst() {
            #expect(["GLT,", "FQK", "SQK,", "DQK,"].contains { command.hasPrefix($0) }, "\(command)")
            #expect(command.split(separator: ",").count <= 3, "\(command)")
        }
        #expect(commands.dropFirst().sorted() == expectedQuickKeyReads, "\(commands)")
    }

    @Test func cliCommandsAgainstMockScanner() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = try await MockScanner.launch(["--cooldown-seconds", "1"])
        let control = ["--host", "127.0.0.1", "--port", String(mock.udpPort)]
        var shutdown: (exited: Bool, status: Int32, stdout: String, stderr: String)?
        do {
            let info = try await noctule(["info"] + control)
            #expect(info.exited && info.status == 0, "\(info.stderr)")
            #expect(info.stdout.contains("SDS200"), "\(info.stdout)")
            #expect(info.stdout.contains("1.26.01"), "\(info.stdout)")

            let status = try await noctule(["status"] + control)
            #expect(status.exited && status.status == 0, "\(status.stderr)")
            #expect(status.stdout.contains("Riverbend County P25"), "\(status.stdout)")

            let display = try await noctule(["display"] + control)
            #expect(display.exited && display.status == 0, "\(display.stderr)")
            #expect(display.stdout.contains("SYSTEM") && display.stdout.contains("CHANNEL"), "\(display.stdout)")

            let watch = try await noctule(["watch", "--count", "3"] + control)
            #expect(watch.exited && watch.status == 0, "\(watch.stderr)")
            #expect(watch.stdout.split(separator: "\n").count == 3, "\(watch.stdout)")

            let wav = directory.appending(path: "out.wav")
            let listen = try await noctule([
                "listen", "--no-play", "--seconds", "2", "--record", wav.path,
                "--rtsp-port", String(mock.rtspPort), "--cooldown-seconds", "1",
                "--cooldown-store", directory.appending(path: "cooldown.json").path,
            ] + control)
            #expect(listen.exited && listen.status == 0, "\(listen.stderr)")
            #expect(listen.stderr.contains("audio: streaming"), "\(listen.stderr)")
            #expect(listen.stdout.contains("packets "), "\(listen.stdout)")

            let data = try Data(contentsOf: wav)
            try #require(data.count >= 44)
            #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
            #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
            #expect(le16(data, at: 20) == 1 && le16(data, at: 22) == 1)
            #expect(le32(data, at: 24) == 8000 && le16(data, at: 34) == 16)
            let dataSize = Int(le32(data, at: 40))
            #expect(dataSize == data.count - 44)
            #expect(Int(le32(data, at: 4)) == dataSize + 36)
            #expect((25_600...38_400).contains(dataSize), "data size \(dataSize)")
        } catch {
            Issue.record(error)
        }
        shutdown = await mock.shutdown()
        let result = try #require(shutdown)
        #expect(result.exited && result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
        // watch always stops its push, and the mock never wedged.
        #expect(result.stderr.contains("control: PSI,500"), "\(result.stderr)")
        #expect(result.stderr.contains("control: PSI,0"), "\(result.stderr)")
        #expect(!result.stderr.contains("wedged"), "\(result.stderr)")
    }

    @Test func watchReportsStallAgainstMockScanner() async throws {
        let mock = try await MockScanner.launch(["--fault", "stall-psi=1"])
        do {
            let watch = try await noctule(["watch", "--count", "10", "--host", "127.0.0.1", "--port", String(mock.udpPort)])
            #expect(watch.exited && watch.status == 1, "\(watch.stderr)")
            #expect(watch.stderr.contains("no PSI updates from 127.0.0.1:\(mock.udpPort) for 5 s"), "\(watch.stderr)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0)
        #expect(result.stderr.contains("control: PSI,0"), "\(result.stderr)")
    }

    /// SIGTERM and SIGHUP (a closed terminal, `kill`, launchd) stop `listen` the same orderly
    /// way Ctrl-C does: TEARDOWN, the close recorded in the cooldown store, then exit 128 + signo.
    @Test(arguments: [(SIGTERM, Int32(143)), (SIGHUP, Int32(129))])
    func listenTearsDownOnTerminationSignal(_ signal: Int32, _ expectedStatus: Int32) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "cooldown.json")
        let mock = try await MockScanner.launch(["--cooldown-seconds", "1"])
        do {
            let listen = try Subprocess(try noctuleBinary(), [
                "listen", "--no-play", "--host", "127.0.0.1", "--port", String(mock.udpPort),
                "--rtsp-port", String(mock.rtspPort), "--cooldown-seconds", "1", "--cooldown-store", store.path,
            ])
            let streaming = await listen.waitForStderr(within: 15) { $0.contains("audio: streaming") }
            #expect(streaming, "\(listen.stderr)")
            listen.send(signal)
            let exited = await listen.waitForExit(within: 15)
            listen.kill()
            let result = await listen.finish()
            #expect(exited)
            #expect(result.status == expectedStatus, "\(result.status) \(result.stderr)")
            #expect(result.stdout.contains("packets "), "\(result.stdout)")
            let record = (try? String(contentsOf: store, encoding: .utf8)) ?? ""
            #expect(record.contains("127.0.0.1"), "cooldown store: \(record)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
    }

    /// `listen --reconnect-cooldown 0` against a mock that arms its hazard only after unclean
    /// closes: a second run right after a clean stop connects at once. Without the flag (the
    /// default, clamped to the 5 s mock-only full value) the next run waits, and is interrupted.
    @Test func listenReconnectCooldownAppliesAfterACleanClose() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "cooldown.json")
        let mock = try await MockScanner.launch(["--cooldown-seconds", "5", "--cooldown-after", "unclean", "--no-delays"])
        do {
            let base = ["listen", "--no-play", "--host", "127.0.0.1", "--port", String(mock.udpPort),
                        "--rtsp-port", String(mock.rtspPort), "--cooldown-seconds", "5", "--cooldown-store", store.path]
            for run in 1...2 {
                let result = try await noctule(base + ["--seconds", "1", "--reconnect-cooldown", "0"], limit: 20)
                #expect(result.exited && result.status == 0, "run \(run): \(result.stderr)")
                #expect(result.stderr.contains("audio: streaming"), "run \(run): \(result.stderr)")
                #expect(!result.stderr.contains("before reconnecting"), "run \(run): \(result.stderr)")
            }
            let third = try Subprocess(try noctuleBinary(), base)
            let waiting = await third.waitForStderr(within: 10) { $0.contains("before reconnecting (scanner cooldown)") }
            third.interrupt()
            let exited = await third.waitForExit(within: 10)
            third.kill()
            let result = await third.finish()
            #expect(waiting, "\(result.stderr)")
            #expect(exited && result.status == 130, "\(result.status) \(result.stderr)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
        #expect(!result.stderr.contains("wedged"), "\(result.stderr)")
    }

    /// `--cooldown-seconds` without a private `--cooldown-store` is refused before anything is
    /// sent (exit 2): a shortened cooldown never reaches the shared record.
    @Test func cooldownSecondsWithoutAPrivateStoreIsRefused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = try await MockScanner.launch([])
        do {
            let base = ["--host", "127.0.0.1", "--port", String(mock.udpPort), "--rtsp-port", String(mock.rtspPort)]
            let listen = try await noctule(["listen", "--no-play", "--seconds", "1", "--cooldown-seconds", "1"] + base)
            #expect(listen.exited && listen.status == 2, "\(listen.status) \(listen.stderr)")
            #expect(listen.stderr.contains("needs a private --cooldown-store"), "\(listen.stderr)")
            let log = try await noctule(["log", "--seconds", "1", "--cooldown-seconds", "1",
                                         "--settings-dir", directory.path])
            #expect(log.exited && log.status == 2, "\(log.status) \(log.stderr)")
            #expect(log.stderr.contains("needs a private --cooldown-store"), "\(log.stderr)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(!result.stderr.contains("control: "), "nothing sent: \(result.stderr)")
        #expect(!result.stderr.contains("rtsp: "), "nothing sent: \(result.stderr)")
    }

    /// A closed stderr pipe must not kill `listen` mid-session (SIGPIPE is ignored).
    @Test func listenSurvivesClosedStderr() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = try await MockScanner.launch(["--cooldown-seconds", "1"])
        do {
            let process = Process()
            process.executableURL = try noctuleBinary()
            process.arguments = [
                "listen", "--no-play", "--seconds", "2", "--host", "127.0.0.1", "--port", String(mock.udpPort),
                "--rtsp-port", String(mock.rtspPort), "--cooldown-seconds", "1",
                "--cooldown-store", directory.appending(path: "cooldown.json").path,
            ]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // Nobody reads stderr: the first state line hits a broken pipe.
            try errPipe.fileHandleForReading.close()
            let exited = await waitFor(15) { !process.isRunning }
            if !exited { Darwin.kill(process.processIdentifier, SIGKILL) }
            // Never `waitUntilExit()`: it blocks a cooperative thread (IntegrationSupport.swift).
            let gone = await waitFor(10) { !process.isRunning }
            #expect(exited)
            try #require(gone, "process \(process.processIdentifier) still running after SIGKILL")
            #expect(process.terminationReason == .exit && process.terminationStatus == 0,
                    "reason \(process.terminationReason.rawValue), status \(process.terminationStatus)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
    }

    /// `watch` stops its push (PSI,0) on SIGTERM too, and exits 143.
    @Test func watchStopsPushOnSigterm() async throws {
        let mock = try await MockScanner.launch([])
        do {
            let watch = try Subprocess(try noctuleBinary(), ["watch", "--host", "127.0.0.1", "--port", String(mock.udpPort)])
            let updating = await watch.waitForOutput(within: 10) { !$0.isEmpty }
            #expect(updating, "\(watch.stderr)")
            watch.send(SIGTERM)
            let exited = await watch.waitForExit(within: 10)
            watch.kill()
            let result = await watch.finish()
            #expect(exited)
            #expect(result.status == 143, "\(result.status) \(result.stderr)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0)
        #expect(result.stderr.contains("control: PSI,0"), "\(result.stderr)")
    }

    @Test func restartAgainstMockScanner() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = try await MockScanner.launch(["--reboot-seconds", "1"])
        do {
            let restart = try await noctule([
                "restart", "--yes", "--host", "127.0.0.1", "--port", String(mock.udpPort),
                "--cooldown-store", directory.appending(path: "cooldown.json").path,
            ])
            #expect(restart.exited && restart.status == 0, "\(restart.stdout) \(restart.stderr)")
            #expect(restart.stdout.contains(
                "restart: note: whether a restart revives a wedged audio server is unverified; if listen fails, power-cycle the scanner"),
                "\(restart.stdout)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0)
        #expect(result.stderr.contains("control: MSM,1"), "\(result.stderr)")
        #expect(result.stderr.contains("reboot finished"), "\(result.stderr)")
    }
}

/// The push regression test, in a suite of its own so that a workflow can run it apart from the
/// rest: it measures a throttled mock's pace (LESSONS.md 2026-11-20).
@Suite(.timeLimit(.minutes(1))) struct ThrottledMockPushTests {
    /// The mock pushes at the interval the client asked for even when its timers wake late (a
    /// throttled process, as on the CI runner, LESSONS.md 2026-11-20), as the scanner does: run
    /// under `taskpolicy -c utility`, `PSI,50` still brings a push about every 50 ms, not one per
    /// coalesced wakeup. Without the strict timer the pushes come in bursts (gaps of 5–27 ms)
    /// between stalls of about 180 ms, so the median gap can look right; the mean over the run,
    /// about 95 ms then, can't.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: taskpolicyPath), "no \(taskpolicyPath) to throttle the mock"))
    func pushesKeepTheirIntervalWhenTheMockIsThrottled() async throws {
        let mock = try await MockScanner.launch(["--no-delays"], throttled: true)
        let arrivals = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: pushArrivals(port: mock.udpPort, interval: 50, count: 20, limit: 10))
            }
        }
        // `PSI,0` went out as the reads ended; wait for the mock to log it before stopping it, since
        // the mock takes the stop on another queue and could take it first.
        _ = await mock.process.waitForStderr(within: 10) { $0.contains("control: PSI,0") }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0, "\(result.stderr)")
        #expect(result.stderr.contains("control: PSI,0"), "\(result.stderr)")
        try #require(arrivals.count == 20, "\(arrivals.count) pushes in 10 s")
        let gaps = zip(arrivals, arrivals.dropFirst()).map { $1 - $0 }.sorted()
        let mean = (arrivals[arrivals.count - 1] - arrivals[0]) / (arrivals.count - 1)
        #expect(mean <= .milliseconds(75), "mean gap \(mean) between PSI,50 pushes; gaps \(gaps)")
    }
}
