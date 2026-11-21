// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
@testable import NoctuleMockScanner

@Suite(.timeLimit(.minutes(1))) struct MockScannerArgumentsTests {
    @Test func defaultsMatchTheHardware() throws {
        let args = try MockScannerArguments.parse([])
        #expect(args.scenario == "default")
        #expect(args.udpPort == 0 && args.rtspPort == 0)
        #expect(args.faults == .none)
        #expect(args.cooldownSeconds == 120)
        #expect(args.rebootSeconds == 10)
        #expect(args.wedgeMode == .timeout)
        #expect(args.realisticDelays)
        #expect(args.cooldownAfter == .any)
        let options = args.options(log: nil)
        #expect(options.reconnectCooldown == .seconds(120))
        #expect(options.cooldownAfter == .any)
        #expect(options.rebootDuration == .seconds(10))
        #expect(options.replyDelays == MockSDS200.Options.realisticReplyDelays)
        #expect(options.replyDelays["SETUP"] == .milliseconds(500))
        #expect(!options.clock.isStepped)
        #expect(try args.loadScenario() == .default)
        #expect(!MockScannerArguments.usage.isEmpty)
    }

    @Test func parsesEveryOption() throws {
        let args = try MockScannerArguments.parse([
            "--scenario", "weather", "--udp-port", "50536", "--rtsp-port", "8554", "--cooldown-seconds", "1.5",
            "--reboot-seconds", "2", "--wedge-mode", "refuse", "--no-delays", "--start-at", "9", "--verbose",
        ])
        #expect(args.scenario == "weather")
        #expect(args.udpPort == 50536 && args.rtspPort == 8554)
        #expect(args.cooldownSeconds == 1.5)
        #expect(args.rebootSeconds == 2)
        #expect(args.wedgeMode == .refuse)
        #expect(!args.realisticDelays)
        #expect(args.startAt == 9)
        #expect(args.verbose)
        let options = args.options(log: nil)
        #expect(options.reconnectCooldown == .milliseconds(1500))
        #expect(options.replyDelays.isEmpty)
        #expect(options.wedgeMode == .refuse)
        #expect(options.udpPort == 50536 && options.rtspPort == 8554)
        #expect(options.clock.now >= 9)
        #expect(try args.loadScenario() == .weather)
        #expect(try MockScannerArguments.parse(["--help"]).help)
        #expect(try MockScannerArguments.parse(["-h"]).help)
    }

    @Test func parsesFaults() throws {
        let args = try MockScannerArguments.parse([
            "--fault", "stall-psi=2", "--fault", "keepalive=454", "--fault", "drop-audio=3.5",
            "--fault", "wedge-audio", "--fault", "wedge-control",
        ])
        #expect(args.faults == MockFaults(stallPSIAfter: 2, keepaliveStatus: 454, dropAudioAfter: 3.5,
                                          wedgeAudio: true, wedgeTakesControlDown: true))
    }

    @Test func parsesDropFaults() throws {
        var args = try MockScannerArguments.parse(["--fault", "drop-reply=KEY"])
        #expect(args.faults == MockFaults(dropNextReply: "KEY"))
        #expect(args.faults.dropCount == 1)
        args = try MockScannerArguments.parse(["--fault", "drop-request=MSV"])
        #expect(args.faults == MockFaults(dropNextRequest: "MSV"))
        args = try MockScannerArguments.parse(["--fault", "drop-request=MSI:2"])
        #expect(args.faults == MockFaults(dropNextRequest: "MSI", dropCount: 2))
        args = try MockScannerArguments.parse(["--fault", "drop-reply=KEY:3", "--fault", "wedge-audio"])
        #expect(args.faults == MockFaults(wedgeAudio: true, dropNextReply: "KEY", dropCount: 3))
    }

    @Test func rejectsBadDropFaults() {
        for bad in ["drop-reply", "drop-reply=", "drop-reply=:2", "drop-reply=KEY:0", "drop-request=MSI:-1",
                    "drop-request=MSI:x", "drop-request=MSI:", "drop-request=MSI:2:3"] {
            #expect(throws: MockScannerArgumentsError.invalidValue(option: "--fault", value: bad), "\(bad)") {
                try MockScannerArguments.parse(["--fault", bad])
            }
        }
    }

    @Test func scenarioPathLoadsAFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "mock-scenario-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var custom = MockScenario.default
        custom.transmissions = Array(custom.transmissions.prefix(1))
        try JSONEncoder().encode(custom).write(to: url)
        let args = try MockScannerArguments.parse(["--scenario", url.path])
        #expect(try args.loadScenario() == custom)
    }

    @Test func rejectsBadArguments() {
        #expect(throws: MockScannerArgumentsError.unknownOption("--bogus")) { try MockScannerArguments.parse(["--bogus"]) }
        #expect(throws: MockScannerArgumentsError.missingValue("--udp-port")) { try MockScannerArguments.parse(["--udp-port"]) }
        #expect(throws: MockScannerArgumentsError.invalidValue(option: "--udp-port", value: "abc")) {
            try MockScannerArguments.parse(["--udp-port", "abc"])
        }
        #expect(throws: MockScannerArgumentsError.invalidValue(option: "--fault", value: "melt")) {
            try MockScannerArguments.parse(["--fault", "melt"])
        }
        #expect(throws: MockScannerArgumentsError.invalidValue(option: "--fault", value: "keepalive=x")) {
            try MockScannerArguments.parse(["--fault", "keepalive=x"])
        }
        #expect(throws: MockScannerArgumentsError.invalidValue(option: "--wedge-mode", value: "explode")) {
            try MockScannerArguments.parse(["--wedge-mode", "explode"])
        }
        #expect(throws: MockScannerArgumentsError.invalidValue(option: "--cooldown-seconds", value: "-1")) {
            try MockScannerArguments.parse(["--cooldown-seconds", "-1"])
        }
        #expect(throws: MockScannerArgumentsError.invalidValue(option: "--cooldown-after", value: "clean")) {
            try MockScannerArguments.parse(["--cooldown-after", "clean"])
        }
        #expect(throws: MockScannerArgumentsError.missingValue("--cooldown-after")) {
            try MockScannerArguments.parse(["--cooldown-after"])
        }
    }

    // MARK: Serial (the SDS150 on a pseudo-terminal)

    @Test func networkByDefault() throws {
        let args = try MockScannerArguments.parse([])
        #expect(args.model == .sds200)
        #expect(!args.serial)
        #expect(args.serialLink == nil)
        #expect(args.mdlName == nil)
        #expect(args.personality == .sds200)
        #expect(try MockScannerArguments.parse(["--model", "sds200"]).model == .sds200)
    }

    @Test func parsesSerialOptions() throws {
        let args = try MockScannerArguments.parse([
            "--model", "sds150", "--serial", "--serial-link", "/tmp/x", "--fault", "unplug=5:3", "--fault", "split-writes",
        ])
        #expect(args.model == .sds150)
        #expect(args.serial)
        #expect(args.serialLink == "/tmp/x")
        #expect(args.faults == MockFaults(unplugAfter: 5, replugAfter: 3, splitWrites: true))
        #expect(args.personality == .sds150)

        let named = try MockScannerArguments.parse(["--model", "sds150", "--serial", "--mdl-name", "SDS150GBT",
                                                    "--fault", "unplug=2.5", "--fault", "drop-reply=KEY"])
        #expect(named.mdlName == "SDS150GBT")
        #expect(named.personality.reportedModel == "SDS150GBT")
        #expect(named.personality.firmware == MockPersonality.sds150.firmware)
        #expect(named.faults == MockFaults(dropNextReply: "KEY", unplugAfter: 2.5))

        // An SDS200 personality on a pty is allowed.
        let sds200 = try MockScannerArguments.parse(["--serial"])
        #expect(sds200.serial && sds200.model == .sds200)
        #expect(sds200.personality == .sds200)
        #expect(MockScannerArguments.usage.contains("--serial-link"))
        #expect(MockScannerArguments.usage.contains("split-writes"))
    }

    @Test func rejectsSerialMisuse() {
        let cases: [([String], MockScannerArgumentsError)] = [
            (["--model", "sds150"], .usage("the SDS150 has no network port: add --serial")),
            (["--model", "sds150", "--udp-port", "50536"], .usage("the SDS150 has no network port: add --serial")),
            (["--model", "sds150", "--serial", "--fault", "unplug=5:3"],
             .usage("--fault unplug=N:M (replug) needs --serial-link")),
            (["--fault", "unplug=5"], .usage("--fault unplug needs --serial")),
            (["--fault", "split-writes"], .usage("--fault split-writes needs --serial")),
            (["--serial-link", "/tmp/x"], .usage("--serial-link needs --serial")),
            (["--mdl-name", "SDS150GBT"], .usage("--mdl-name needs --serial")),
            (["--serial", "--udp-port", "50536"], .usage("--serial serves no network ports: drop --udp-port")),
            (["--serial", "--rtsp-port", "8554"], .usage("--serial serves no network ports: drop --rtsp-port")),
            (["--serial", "--udp-port", "0"], .usage("--serial serves no network ports: drop --udp-port")),
            (["--model", "bogus"], .invalidValue(option: "--model", value: "bogus")),
            (["--model", "SDS150"], .invalidValue(option: "--model", value: "SDS150")),
            (["--model"], .missingValue("--model")),
            (["--serial", "--serial-link"], .missingValue("--serial-link")),
            (["--serial", "--mdl-name", ""], .invalidValue(option: "--mdl-name", value: "")),
            (["--serial", "--mdl-name", "SDS,150"], .invalidValue(option: "--mdl-name", value: "SDS,150")),
            (["--serial", "--serial-link", ""], .invalidValue(option: "--serial-link", value: "")),
        ]
        for (arguments, error) in cases {
            #expect(throws: error, "\(arguments)") { try MockScannerArguments.parse(arguments) }
        }
        for bad in ["unplug", "unplug=", "unplug=x", "unplug=-1", "unplug=1:", "unplug=1:x", "unplug=1:-2",
                    "unplug=1:2:3", "unplug=:2", "split-writes=1"] {
            #expect(throws: MockScannerArgumentsError.invalidValue(option: "--fault", value: bad), "\(bad)") {
                try MockScannerArguments.parse(["--serial", "--serial-link", "/tmp/x", "--fault", bad])
            }
        }
    }

    /// `--push-lifetime S` replaces the SDS150's 183 s (serial SDS150 only, a positive number).
    @Test func parsesPushLifetime() throws {
        let args = try MockScannerArguments.parse(["--model", "sds150", "--serial", "--push-lifetime", "2.5"])
        #expect(args.pushLifetime == 2.5)
        #expect(args.personality.pushLifetime == 2.5)
        #expect(args.personality.pushLifetimeRestarts == MockPersonality.sds150.pushLifetimeRestarts)
        let plain = try MockScannerArguments.parse(["--model", "sds150", "--serial"])
        #expect(plain.pushLifetime == nil)
        #expect(plain.personality.pushLifetime == 183)
        #expect(MockScannerArguments.usage.contains("--push-lifetime"))

        let cases: [([String], MockScannerArgumentsError)] = [
            (["--push-lifetime", "5"], .usage("--push-lifetime needs --serial")),
            (["--serial", "--push-lifetime", "5"], .usage("--push-lifetime needs --model sds150 or sds100 (the SDS200 has no push lifetime)")),
            (["--model", "sds150", "--serial", "--push-lifetime", "0"], .invalidValue(option: "--push-lifetime", value: "0")),
            (["--model", "sds150", "--serial", "--push-lifetime", "-1"], .invalidValue(option: "--push-lifetime", value: "-1")),
            (["--model", "sds150", "--serial", "--push-lifetime", "x"], .invalidValue(option: "--push-lifetime", value: "x")),
            (["--model", "sds150", "--serial", "--push-lifetime", "inf"], .invalidValue(option: "--push-lifetime", value: "inf")),
            (["--model", "sds150", "--serial", "--push-lifetime"], .missingValue("--push-lifetime")),
        ]
        for (arguments, error) in cases {
            #expect(throws: error, "\(arguments)") { try MockScannerArguments.parse(arguments) }
        }
    }

    /// `--kal-after-expiry restarts|ignored` says what a `KAL` after the pushes stopped does
    /// (serial SDS150 only; default restarts, the assumption so far).
    @Test func parsesKALAfterExpiry() throws {
        let ignored = try MockScannerArguments.parse(["--model", "sds150", "--serial", "--kal-after-expiry", "ignored"])
        #expect(ignored.keepAliveRevivesStoppedPushes == false)
        #expect(ignored.personality.keepAliveRevivesStoppedPushes == false)
        let restarts = try MockScannerArguments.parse(["--model", "sds150", "--serial", "--kal-after-expiry", "restarts"])
        #expect(restarts.keepAliveRevivesStoppedPushes == true)
        #expect(restarts.personality.keepAliveRevivesStoppedPushes)
        let plain = try MockScannerArguments.parse(["--model", "sds150", "--serial"])
        #expect(plain.keepAliveRevivesStoppedPushes == nil)
        #expect(plain.personality.keepAliveRevivesStoppedPushes)
        #expect(MockPersonality.sds150.keepAliveRevivesStoppedPushes)
        #expect(MockScannerArguments.usage.contains("--kal-after-expiry"))

        let cases: [([String], MockScannerArgumentsError)] = [
            (["--kal-after-expiry", "ignored"], .usage("--kal-after-expiry needs --serial")),
            (["--serial", "--kal-after-expiry", "ignored"],
             .usage("--kal-after-expiry needs --model sds150 (the mock's SDS200 has no push lifetime and answers KAL with ERR)")),
            (["--model", "sds150", "--serial", "--kal-after-expiry", "sometimes"],
             .invalidValue(option: "--kal-after-expiry", value: "sometimes")),
            (["--model", "sds150", "--serial", "--kal-after-expiry"], .missingValue("--kal-after-expiry")),
        ]
        for (arguments, error) in cases {
            #expect(throws: error, "\(arguments)") { try MockScannerArguments.parse(arguments) }
        }
    }

    /// `--model sds100 --serial` (design §5.4): like the SDS150 it has no network port, and its
    /// push lifetime can be shortened; `--kal-after-expiry` is the SDS150's alone (it answers `KAL`
    /// with `ERR`).
    @Test func parsesTheSDS100() throws {
        let args = try MockScannerArguments.parse(["--model", "sds100", "--serial"])
        #expect(args.model == .sds100)
        #expect(args.serial)
        #expect(args.personality == .sds100)
        #expect(MockScannerModel.sds100.personality == .sds100)

        let short = try MockScannerArguments.parse(["--model", "sds100", "--serial", "--push-lifetime", "2.5"])
        #expect(short.personality.pushLifetime == 2.5)
        #expect(short.personality.pushLifetimeRestarts == [])
        #expect(try MockScannerArguments.parse(["--model", "sds100", "--serial"]).personality.pushLifetime == 183)

        let named = try MockScannerArguments.parse(["--model", "sds100", "--serial", "--mdl-name", "SDS100X"])
        #expect(named.personality.reportedModel == "SDS100X")
        #expect(named.personality.firmware == MockPersonality.sds100.firmware)

        #expect(MockScannerArguments.usage.contains("sds200|sds150|sds100"))

        let cases: [([String], MockScannerArgumentsError)] = [
            (["--model", "sds100"], .usage("the SDS100 has no network port: add --serial")),
            (["--model", "sds100", "--udp-port", "50536"], .usage("the SDS100 has no network port: add --serial")),
            (["--model", "sds100", "--serial", "--kal-after-expiry", "ignored"],
             .usage("--kal-after-expiry needs --model sds150 (the SDS100 answers KAL with ERR)")),
            (["--model", "sds100", "--serial", "--kal-after-expiry", "restarts"],
             .usage("--kal-after-expiry needs --model sds150 (the SDS100 answers KAL with ERR)")),
        ]
        for (arguments, error) in cases {
            #expect(throws: error, "\(arguments)") { try MockScannerArguments.parse(arguments) }
        }
    }

    @Test func parsesCooldownAfter() throws {
        let unclean = try MockScannerArguments.parse(["--cooldown-after", "unclean"])
        #expect(unclean.cooldownAfter == .unclean)
        #expect(unclean.options(log: nil).cooldownAfter == .unclean)
        #expect(try MockScannerArguments.parse(["--cooldown-after", "any"]).cooldownAfter == .any)
        #expect(MockScannerArguments.usage.contains("--cooldown-after"))
    }

    @Test func lineOutNeedsSerial() throws {
        #expect(throws: MockScannerArgumentsError.usage("--line-out needs --serial")) {
            try MockScannerArguments.parse(["--line-out", "/tmp/jack.sock"])
        }
        #expect(throws: MockScannerArgumentsError.usage("--line-out needs --serial")) {
            try MockScannerArguments.parse(["--model", "sds200", "--line-out", "/tmp/jack.sock", "--fault", "line-out-silent"])
        }
        #expect(throws: MockScannerArgumentsError.missingValue("--line-out")) {
            try MockScannerArguments.parse(["--serial", "--line-out"])
        }
        #expect(throws: MockScannerArgumentsError.invalidValue(option: "--line-out", value: "")) {
            try MockScannerArguments.parse(["--serial", "--line-out", ""])
        }
        let args = try MockScannerArguments.parse(["--serial", "--line-out", "/tmp/jack.sock"])
        #expect(args.lineOut == "/tmp/jack.sock")
        #expect(args.lineOutChannel == .both)
        #expect(try MockScannerArguments.parse(["--serial"]).lineOut == nil)
        #expect(MockScannerArguments.usage.contains("--line-out PATH"))
    }

    @Test func lineOutChannelParses() throws {
        for (text, channel) in [("left", LineInChannel.left), ("right", .right), ("both", .both)] {
            let args = try MockScannerArguments.parse(["--serial", "--line-out", "/tmp/j", "--line-out-channel", text])
            #expect(args.lineOutChannel == channel)
        }
        #expect(throws: MockScannerArgumentsError.invalidValue(option: "--line-out-channel", value: "middle")) {
            try MockScannerArguments.parse(["--serial", "--line-out", "/tmp/j", "--line-out-channel", "middle"])
        }
        #expect(throws: MockScannerArgumentsError.missingValue("--line-out-channel")) {
            try MockScannerArguments.parse(["--serial", "--line-out", "/tmp/j", "--line-out-channel"])
        }
        #expect(throws: MockScannerArgumentsError.usage("--line-out-channel needs --line-out")) {
            try MockScannerArguments.parse(["--serial", "--line-out-channel", "left"])
        }
        #expect(MockScannerArguments.usage.contains("--line-out-channel left|right|both"))
    }

    @Test func lineOutSilentFault() throws {
        let args = try MockScannerArguments.parse(["--serial", "--line-out", "/tmp/j", "--fault", "line-out-silent"])
        #expect(args.faults.lineOutSilent)
        #expect(!(try MockScannerArguments.parse(["--serial", "--line-out", "/tmp/j"])).faults.lineOutSilent)
        #expect(MockFaults.none.lineOutSilent == false)
        #expect(throws: MockScannerArgumentsError.usage("--fault line-out-silent needs --line-out")) {
            try MockScannerArguments.parse(["--serial", "--fault", "line-out-silent"])
        }
        #expect(throws: MockScannerArgumentsError.invalidValue(option: "--fault", value: "line-out-silent=3")) {
            try MockScannerArguments.parse(["--serial", "--line-out", "/tmp/j", "--fault", "line-out-silent=3"])
        }
        #expect(MockScannerArguments.usage.contains("line-out-silent"))
    }

    /// `--glt-page-size N` (any mock): the most elements a `GLT` page holds, in place of the default 4.
    @Test func parsesGLTPageSize() throws {
        #expect(try MockScannerArguments.parse([]).gltPageSize == nil)
        #expect(try MockScannerArguments.parse([]).options(log: nil).gltPageSize == MockFavorites.defaultGLTPageSize)
        let network = try MockScannerArguments.parse(["--glt-page-size", "2"])
        #expect(network.gltPageSize == 2)
        #expect(network.options(log: nil).gltPageSize == 2)
        #expect(try MockScannerArguments.parse(["--model", "sds150", "--serial", "--glt-page-size", "1"]).gltPageSize == 1)
        for bad in ["0", "-1", "x", "2.5"] {
            #expect(throws: MockScannerArgumentsError.invalidValue(option: "--glt-page-size", value: bad)) {
                try MockScannerArguments.parse(["--glt-page-size", bad])
            }
        }
        #expect(MockScannerArguments.usage.contains("--glt-page-size"))
    }
}
