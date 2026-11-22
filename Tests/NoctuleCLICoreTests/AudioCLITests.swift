// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
@testable import NoctuleCLICore

@Suite(.timeLimit(.minutes(3))) struct ListenArgumentsTests {
    @Test func listenDefaults() throws {
        let a = try CLIArguments.parse(["listen"])
        #expect(a == CLIInvocation(command: .listen(record: nil, seconds: nil, play: true)))
    }
    @Test func listenFlags() throws {
        let a = try CLIArguments.parse(["listen", "--record", "/tmp/x.wav", "--seconds", "10", "--no-play",
                                        "--host", "127.0.0.1", "--rtsp-port", "8554"])
        #expect(a.command == .listen(record: "/tmp/x.wav", seconds: 10, play: false))
        #expect(a.host == "127.0.0.1" && a.rtspPort == 8554)
    }
    @Test func listenTestingFlags() throws {
        let a = try CLIArguments.parse(["listen", "--cooldown-seconds", "0.3", "--cooldown-store", "/tmp/c.json"])
        #expect(a.cooldownSeconds == 0.3 && a.cooldownStore == "/tmp/c.json")
        #expect(try CLIArguments.parse(["listen", "--cooldown-seconds", "0"]).cooldownSeconds == 0)
    }
    /// A huge value would overflow the millisecond conversion in main.swift (a trap), so parsing
    /// clamps it to a day.
    @Test func cooldownSecondsClampedToADay() throws {
        #expect(try CLIArguments.parse(["listen", "--cooldown-seconds", "1e12"]).cooldownSeconds == 86_400)
        #expect(try CLIArguments.parse(["listen", "--cooldown-seconds", "86401"]).cooldownSeconds == 86_400)
        #expect(try CLIArguments.parse(["listen", "--cooldown-seconds", "86400"]).cooldownSeconds == 86_400)
        #expect(try CLIArguments.parse(["listen", "--cooldown-seconds", "120"]).cooldownSeconds == 120)
    }
    @Test func restartParsing() throws {
        #expect(try CLIArguments.parse(["restart"]).command == .restart(confirmed: false))
        let a = try CLIArguments.parse(["restart", "--yes", "--host", "h", "--cooldown-store", "/tmp/c.json"])
        #expect(a.command == .restart(confirmed: true) && a.host == "h" && a.cooldownStore == "/tmp/c.json")
    }
    @Test func rejectsBadAudioInput() {
        for bad in [["listen", "--seconds", "0"], ["listen", "--seconds", "-1"], ["listen", "--seconds", "x"],
                    ["listen", "--seconds"], ["listen", "--record"], ["listen", "--rtsp-port", "70000"],
                    ["listen", "--cooldown-seconds", "-1"], ["listen", "--cooldown-seconds", "nan"],
                    ["listen", "--cooldown-seconds", "inf"], ["listen", "--yes"], ["listen", "--count", "2"],
                    ["info", "--no-play"], ["info", "--record", "x"], ["info", "--seconds", "1"],
                    ["info", "--rtsp-port", "1"], ["watch", "--cooldown-seconds", "1"], ["status", "--yes"],
                    ["restart", "--no-play"], ["restart", "--seconds", "1"], ["restart", "--rtsp-port", "1"],
                    ["restart", "--interval", "5"]] {
            #expect(throws: CLIUsageError.self, "\(bad)") { try CLIArguments.parse(bad) }
        }
    }
    @Test func usageMentionsAudioCommands() {
        #expect(CLIUsageError.usage.contains("noctule listen"))
        #expect(CLIUsageError.usage.contains("noctule restart [--yes]"))
    }
}

@Suite(.timeLimit(.minutes(3))) struct AudioTargetTests {
    private func withConfig(_ text: String?, _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "noctule-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if let text {
            try text.write(to: root.appending(path: "config/dev-scanner.env"), atomically: true, encoding: .utf8)
        }
        try body(root.standardizedFileURL)
    }

    @Test func prefersScannerIPOverHostName() throws {
        try withConfig("SCANNER_HOST=scanner.example.lan\nSCANNER_IP=192.0.2.10\nSCANNER_UDP_PORT=6000\nSCANNER_RTSP_PORT=8554\n") { dir in
            let t = resolveAudioTarget(invocation: CLIInvocation(command: .restart(confirmed: false)), searchingFrom: dir)
            #expect(t == AudioTarget(host: "192.0.2.10", rtspPort: 8554, controlPort: 6000))
        }
    }
    @Test func fallsBackToHostName() throws {
        try withConfig("SCANNER_HOST=scanner.example.lan\n") { dir in
            let t = resolveAudioTarget(invocation: CLIInvocation(command: .restart(confirmed: false)), searchingFrom: dir)
            #expect(t == AudioTarget(host: "scanner.example.lan", rtspPort: 554, controlPort: 50536))
        }
    }
    @Test func hostFlagWinsAndFlagsOverridePorts() throws {
        try withConfig("SCANNER_IP=192.0.2.10\nSCANNER_RTSP_PORT=8554\n") { dir in
            let inv = CLIInvocation(command: .listen(record: nil, seconds: nil, play: true), host: "127.0.0.1")
            #expect(resolveAudioTarget(invocation: inv, searchingFrom: dir)
                    == AudioTarget(host: "127.0.0.1", rtspPort: 8554, controlPort: 50536))
            var flags = inv
            flags.rtspPort = 9000; flags.port = 7000
            #expect(resolveAudioTarget(invocation: flags, searchingFrom: dir)
                    == AudioTarget(host: "127.0.0.1", rtspPort: 9000, controlPort: 7000))
        }
        try withConfig(nil) { dir in
            let inv = CLIInvocation(command: .listen(record: nil, seconds: nil, play: true), host: "127.0.0.1")
            #expect(resolveAudioTarget(invocation: inv, searchingFrom: dir)
                    == AudioTarget(host: "127.0.0.1", rtspPort: 554, controlPort: 50536))
            #expect(resolveAudioTarget(invocation: CLIInvocation(command: .restart(confirmed: true)), searchingFrom: dir) == nil)
        }
    }
}

@Suite(.timeLimit(.minutes(3))) struct ListenFormatTests {
    @Test func stateLines() {
        #expect(ListenFormat.stateLine(.streaming) == "audio: streaming")
        #expect(ListenFormat.stateLine(.recovering(attempt: 1)) == "audio: recovering (attempt 1)")
        #expect(ListenFormat.stateLine(.failed("gone")) == "audio: failed: gone")
        for quiet: AudioSessionState in [.idle, .starting, .stopped] {
            #expect(ListenFormat.stateLine(quiet) == nil)
        }
    }
    @Test func statsAndWaiting() {
        var stats = AudioStats()
        stats.packets = 250; stats.lost = 2; stats.recoveries = 1
        #expect(ListenFormat.statsLine(stats) == "packets 250  lost 2  recoveries 1")
        #expect(ListenFormat.waitingLine(remaining: .milliseconds(83_200))
                == "audio: waiting 84 s before reconnecting (scanner cooldown)")
        #expect(ListenFormat.waitingLine(remaining: .milliseconds(300))
                == "audio: waiting 1 s before reconnecting (scanner cooldown)")
    }
    @Test func hintsAndUnreleased() {
        #expect(ListenFormat.hintLine(.canRestart)
                == "audio: the scanner's audio isn't responding; run 'noctule restart' to restart it")
        #expect(ListenFormat.hintLine(.powerCycleNeeded) == "audio: Scanner not responding on the network. Power-cycle it.")
        #expect(ListenFormat.unreleasedLine(count: 2)
                == "audio: 2 session(s) could not be closed; the scanner may need a restart")
    }
    @Test func startFailureIsPlain() {
        #expect(ListenFormat.startFailure(RTSPError.closed, host: "192.0.2.10", port: 554)
                == "audio: failed: couldn't connect to the scanner's audio server at 192.0.2.10:554")
        #expect(ListenFormat.startFailure(RTSPError.timeout(method: "CONNECT"), host: "192.0.2.10", port: 554)
                == "audio: failed: couldn't connect to the scanner's audio server at 192.0.2.10:554")
        #expect(ListenFormat.startFailure(RTSPError.timeout(method: "DESCRIBE"), host: "192.0.2.10", port: 554)
                == "audio: failed: the scanner's audio server didn't answer DESCRIBE")
        #expect(ListenFormat.startFailure(AudioSessionError.unsupportedPayloadType(8), host: "h", port: 554)
                == "audio: failed: the scanner's audio uses an unsupported format (RTP payload type 8)")
        #expect(ListenFormat.startFailure(RTSPError.unexpectedStatus(454, "Session Not Found"), host: "h", port: 554)
                == "audio: failed: the scanner's audio server answered 454 Session Not Found")
    }
}

@Suite(.timeLimit(.minutes(3))) struct RestartFormatTests {
    @Test func promptAndConfirmation() {
        #expect(RestartFormat.prompt(host: "192.0.2.10") == "Restart the scanner at 192.0.2.10? [y/N] ")
        for yes in ["y", "Y", "yes", " YES \n"] { #expect(RestartFormat.isConfirmation(yes), "\(yes)") }
        for no in [nil, "", "n", "no", "yep", "sure"] { #expect(!RestartFormat.isConfirmation(no), "\(String(describing: no))") }
    }
    @Test func outcomes() {
        let ok = RestartFormat.outcome(.restarted, seconds: 12.34, timeoutSeconds: 90)
        #expect(ok.success && ok.line == "restart: the scanner is back after 12.3 s")
        let rejected = RestartFormat.outcome(.notAccepted("MSM,NG"), seconds: 0.1, timeoutSeconds: 90)
        #expect(!rejected.success && rejected.line == "restart: the scanner refused the restart (MSM,NG)")
        let gone = RestartFormat.outcome(.didNotComeBack, seconds: 90, timeoutSeconds: 90)
        #expect(!gone.success
                && gone.line == "restart: the scanner didn't answer within 90 s after the restart; it may need a power cycle")
    }
    @Test func revivalCaveat() {
        #expect(RestartFormat.unverifiedRevivalNote
                == "restart: note: whether a restart revives a wedged audio server is unverified; if listen fails, power-cycle the scanner")
    }
}
