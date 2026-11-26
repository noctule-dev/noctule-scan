// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

public enum MockScannerArgumentsError: Error, Equatable {
    case unknownOption(String)
    case missingValue(String)
    case invalidValue(option: String, value: String)
    /// Options that don't go together, with the reason.
    case usage(String)
}

/// The scanner the executable imitates (`--model`).
public enum MockScannerModel: String, Sendable, Equatable {
    case sds200
    case sds150
    case sds100
    case bcd436hp

    public var personality: MockPersonality {
        switch self {
        case .sds200: .sds200
        case .sds150: .sds150
        case .sds100: .sds100
        case .bcd436hp: .bcd436hp
        }
    }
}

/// The `noctule-mock-scanner` command line. Defaults imitate the hardware: a 120 s reconnect
/// cooldown, a 10 s `MSM,1` reboot, and realistic RTSP reply delays.
public struct MockScannerArguments: Sendable, Equatable {
    /// `default`, `weather`, or a path to a scenario JSON file.
    public var scenario = "default"
    public var udpPort: UInt16 = 0
    public var rtspPort: UInt16 = 0
    public var faults = MockFaults.none
    public var cooldownSeconds = 120.0
    public var cooldownAfter = MockCooldownAfter.any
    public var rebootSeconds = 10.0
    public var wedgeMode = MockWedgeMode.timeout
    public var realisticDelays = true
    /// Scenario time to start at, in seconds.
    public var startAt = 0.0
    /// Log every control command and RTSP request to stderr.
    public var verbose = false
    public var help = false
    public var model = MockScannerModel.sds200
    /// Serve on a pseudo-terminal (`MockSerialScanner`) instead of UDP and RTSP.
    public var serial = false
    /// A symlink to the pty, kept across an unplug and replug.
    public var serialLink: String?
    /// What `MDL` reports in place of the model's own name (serial only).
    public var mdlName: String?
    /// Seconds after which a subscription's pushes stop, in place of the 183 s of the SDS150 and
    /// SDS100 (serial handhelds only); nil keeps the personality's.
    public var pushLifetime: Double?
    /// `--kal-after-expiry`: whether a `KAL` after the pushes stopped starts them again
    /// (`restarts`, true) or does nothing (`ignored`, false), in place of the personality's (serial
    /// SDS150 only); nil keeps the personality's (restarts).
    public var keepAliveRevivesStoppedPushes: Bool?
    /// `--line-out`: the path of a Unix-domain socket the scanner's headphone jack is served on
    /// (serial only; `MockLineOut`).
    public var lineOut: String?
    /// `--line-out-channel`: which channel of the jack carries the audio.
    public var lineOutChannel = LineInChannel.both
    private var lineOutChannelGiven = false
    /// `--glt-page-size`: the most elements one page of a `GLT` reply holds; nil keeps
    /// `MockFavorites.defaultGLTPageSize`.
    public var gltPageSize: Int?

    public init() {}

    public static let usage = """
        usage: noctule-mock-scanner [--scenario default|weather|PATH] [--udp-port P] [--rtsp-port P]
                                    [--fault stall-psi=N|keepalive=454|drop-audio=N|wedge-audio|wedge-control
                                               |drop-reply=NAME[:N]|drop-request=NAME[:N]]...
                                    [--cooldown-seconds S] [--cooldown-after any|unclean]
                                    [--reboot-seconds S] [--wedge-mode timeout|refuse]
                                    [--no-delays] [--glt-page-size N] [--start-at S] [--verbose]
               noctule-mock-scanner --serial [--model sds200|sds150|sds100|bcd436hp] [--serial-link PATH] [--mdl-name NAME]
                                    [--push-lifetime S] [--kal-after-expiry restarts|ignored]
                                    [--line-out PATH [--line-out-channel left|right|both]]
                                    [--scenario default|weather|PATH] [--glt-page-size N] [--start-at S]
                                    [--verbose]
                                    [--fault unplug=N[:M]|unplug-after-psi=N[:M]|split-writes|stall-psi=N|line-out-silent
                                               |drop-reply=NAME[:N]|drop-request=NAME[:N]]...

        A mock SDS200 on 127.0.0.1: UDP control, RTSP audio (a synthetic tone per transmission), and the
        hardware's hazards. It prints `udp-port=P` and `rtsp-port=P`, runs until Ctrl-C, then prints
        `leaked-sessions=N` (RTSP sessions that never got a TEARDOWN). Ports default to ephemeral ones.

        With --serial, a mock scanner on a pseudo-terminal instead (an SDS150, SDS100 or BCD436HP on USB with --model
        sds150, sds100 or bcd436hp), and no UDP or RTSP server. It prints `serial-port=PATH` (the link, with --serial-link), runs until
        Ctrl-C, then prints `active-subscriptions=N` (anything but 0: a client left a PSI running).

          --scenario           built-in `default` (fictional trunk traffic) or `weather`, or a JSON file
          --model              sds200 (default), sds150, sds100 or bcd436hp; the handhelds have no network port, so they need
                               --serial
          --serial             serve on a pseudo-terminal
          --serial-link PATH   a symlink to the pty that stays put across an unplug and replug; a symlink
                               already there is replaced, anything else is an error
          --mdl-name NAME      what MDL reports (say SDS150GBT, the form Uniden's spec gives)
          --push-lifetime S    --model sds150, sds100 or bcd436hp only: PSI pushes stop S s (a positive number) after
                               the PSI or the latest KAL (SDS150) or PSI (SDS100, BCD436HP), in place of the 183 s
                               seen on hardware (KAL kept the SDS150 pushing for an hour, a repeated PSI
                               the SDS100; that each restarts the full count is assumed); the
                               subscription stays until PSI,0
          --kal-after-expiry   --model sds150 only: what a KAL does once the pushes have stopped:
                               `restarts` them (default; assumed, never tried on hardware) or is
                               `ignored`, so only a new PSI starts them again
          --line-out PATH      --serial only: serve the scanner's headphone jack on a Unix-domain stream
                               socket at PATH (printed as `line-out=PATH`; removed on Ctrl-C): stereo
                               little-endian Float32 at 48 kHz, one client at a time, audio made while
                               nobody is connected discarded. The scenario's tone sounds during each
                               transmission at a peak of VOL / 8 (so VOL 8 and up clips) over white noise
                               at -52 dBFS, and the noise alone between them; `VOL,n` changes the level
                               at once. Assumed, not measured: the level curve and the stereo layout
          --line-out-channel   left, right or both (default): the channel of the jack that carries the
                               audio (the tone and the noise); the other is zero. Needs --line-out
          --fault line-out-silent  the jack carries only its noise, whatever the scanner receives (needs
                               --line-out)
          --fault unplug=N[:M] the pty closes N s after start, as when the cable is pulled; with M, a new
                               one appears M s later behind --serial-link
          --fault unplug-after-psi=N[:M]  as unplug=N[:M], but N counts from the first subscribing
                               PSI the mock receives (a client that has connected and got going)
          --fault split-writes replies are written 7 bytes at a time
          --fault stall-psi=N  PSI pushes stop N s after each subscription
          --fault keepalive=C  the next keepalive (GET_PARAMETER) gets status C, once
          --fault drop-audio=N RTP stops N s after each PLAY
          --fault wedge-audio  SETUP answers 503 until a reboot (MSM,1) or restart of the mock
          --fault wedge-control  when the audio server wedges, UDP control goes silent too
          --fault drop-reply=NAME[:N]    the next N (default 1) control commands NAME (say KEY) are carried
                               out, but get no reply
          --fault drop-request=NAME[:N]  the next N control commands NAME are logged and ignored
          --cooldown-seconds   reconnect hazard: a new RTSP connection within S s of the last close
                               wedges the audio server (default 120, as measured on hardware)
          --cooldown-after     which closes start that window: `any` (default, as on hardware) or
                               `unclean` (not a close after an answered TEARDOWN; the owner's
                               theory, for testing the app's clean-close cooldown)
          --reboot-seconds     how long MSM,1 keeps the mock silent (default 10)
          --wedge-mode         what the wedged server does with connections (default timeout)
          --no-delays          answer RTSP and quick-key sets at once instead of with the hardware's delays
          --glt-page-size N    the most elements one page of a GLT reply holds (default 4; the hardware
                               pages by size, 6-13 elements a page seen)
        """

    public static func parse(_ arguments: [String]) throws -> MockScannerArguments {
        var result = MockScannerArguments()
        var rest = arguments[...]
        func value(_ option: String) throws -> String {
            guard let next = rest.popFirst() else { throw MockScannerArgumentsError.missingValue(option) }
            return next
        }
        func port(_ option: String) throws -> UInt16 {
            let text = try value(option)
            guard let port = UInt16(text) else { throw MockScannerArgumentsError.invalidValue(option: option, value: text) }
            return port
        }
        func seconds(_ option: String) throws -> Double {
            let text = try value(option)
            guard let seconds = Double(text), seconds >= 0, seconds.isFinite else {
                throw MockScannerArgumentsError.invalidValue(option: option, value: text)
            }
            return seconds
        }
        /// A path or name: not empty, and (for NAME) no comma or line break, which would split a reply.
        func text(_ option: String, forbidding forbidden: String = "") throws -> String {
            let text = try value(option)
            guard !text.isEmpty, !text.contains(where: { forbidden.contains($0) }) else {
                throw MockScannerArgumentsError.invalidValue(option: option, value: text)
            }
            return text
        }
        var networkPort: String?
        while let option = rest.popFirst() {
            switch option {
            case "--scenario": result.scenario = try value(option)
            case "--udp-port", "--rtsp-port":
                let number = try port(option)
                if option == "--udp-port" { result.udpPort = number } else { result.rtspPort = number }
                networkPort = networkPort ?? option
            case "--model":
                let text = try value(option)
                guard let model = MockScannerModel(rawValue: text) else {
                    throw MockScannerArgumentsError.invalidValue(option: option, value: text)
                }
                result.model = model
            case "--serial": result.serial = true
            case "--serial-link": result.serialLink = try text(option)
            case "--mdl-name": result.mdlName = try text(option, forbidding: ",\r\n")
            case "--line-out": result.lineOut = try text(option)
            case "--line-out-channel":
                let text = try value(option)
                guard let channel = LineInChannel(rawValue: text) else {
                    throw MockScannerArgumentsError.invalidValue(option: option, value: text)
                }
                result.lineOutChannel = channel
                result.lineOutChannelGiven = true
            case "--push-lifetime":
                let text = try value(option)
                guard let seconds = Double(text), seconds > 0, seconds.isFinite else {
                    throw MockScannerArgumentsError.invalidValue(option: option, value: text)
                }
                result.pushLifetime = seconds
            case "--kal-after-expiry":
                let text = try value(option)
                switch text {
                case "restarts": result.keepAliveRevivesStoppedPushes = true
                case "ignored": result.keepAliveRevivesStoppedPushes = false
                default: throw MockScannerArgumentsError.invalidValue(option: option, value: text)
                }
            case "--cooldown-seconds": result.cooldownSeconds = try seconds(option)
            case "--cooldown-after":
                let text = try value(option)
                guard let after = MockCooldownAfter(rawValue: text) else {
                    throw MockScannerArgumentsError.invalidValue(option: option, value: text)
                }
                result.cooldownAfter = after
            case "--reboot-seconds": result.rebootSeconds = try seconds(option)
            case "--start-at": result.startAt = try seconds(option)
            case "--no-delays": result.realisticDelays = false
            case "--glt-page-size":
                let text = try value(option)
                guard let size = Int(text), size >= 1 else {
                    throw MockScannerArgumentsError.invalidValue(option: option, value: text)
                }
                result.gltPageSize = size
            case "--verbose": result.verbose = true
            case "--help", "-h": result.help = true
            case "--wedge-mode":
                let text = try value(option)
                guard let mode = MockWedgeMode(rawValue: text) else {
                    throw MockScannerArgumentsError.invalidValue(option: option, value: text)
                }
                result.wedgeMode = mode
            case "--fault":
                let text = try value(option)
                try result.addFault(text)
            default:
                throw MockScannerArgumentsError.unknownOption(option)
            }
        }
        if !result.help { try result.checkCombination(networkPort: networkPort) }
        return result
    }

    /// The serial options need `--serial`, and `--serial` serves no network port.
    private func checkCombination(networkPort: String?) throws {
        func misuse(_ reason: String) -> MockScannerArgumentsError { .usage(reason) }
        if lineOut != nil, !serial { throw misuse("--line-out needs --serial") }
        if model != .sds200, !serial {
            throw misuse("the \(model.rawValue.uppercased()) has no network port: add --serial")
        }
        if lineOut == nil {
            if lineOutChannelGiven { throw misuse("--line-out-channel needs --line-out") }
            if faults.lineOutSilent { throw misuse("--fault line-out-silent needs --line-out") }
        }
        if serial {
            if let networkPort { throw misuse("--serial serves no network ports: drop \(networkPort)") }
            if faults.replugAfter != nil, serialLink == nil {
                let form = faults.unplugCountsFromFirstPSI ? "unplug-after-psi" : "unplug"
                throw misuse("--fault \(form)=N:M (replug) needs --serial-link")
            }
            if pushLifetime != nil, model == .sds200 {
                throw misuse("--push-lifetime needs --model sds150, sds100 or bcd436hp (the SDS200 has no push lifetime)")
            }
            if keepAliveRevivesStoppedPushes != nil, model == .sds200 {
                throw misuse("--kal-after-expiry needs --model sds150 (the mock's SDS200 has no push lifetime and answers KAL with ERR)")
            }
            if keepAliveRevivesStoppedPushes != nil, model == .sds100 {
                throw misuse("--kal-after-expiry needs --model sds150 (the SDS100 answers KAL with ERR)")
            }
            if keepAliveRevivesStoppedPushes != nil, model == .bcd436hp {
                throw misuse("--kal-after-expiry needs --model sds150 (the BCD436HP answers KAL with ERR)")
            }
            return
        }
        if serialLink != nil { throw misuse("--serial-link needs --serial") }
        if mdlName != nil { throw misuse("--mdl-name needs --serial") }
        if pushLifetime != nil { throw misuse("--push-lifetime needs --serial") }
        if keepAliveRevivesStoppedPushes != nil { throw misuse("--kal-after-expiry needs --serial") }
        if faults.unplugAfter != nil { throw misuse("--fault unplug needs --serial") }
        if faults.splitWrites { throw misuse("--fault split-writes needs --serial") }
    }

    /// The serial mock's answers: the model's, with `--mdl-name` in place of its `MDL` name and
    /// `--push-lifetime` in place of its push lifetime, and `--kal-after-expiry` in place of what a
    /// late `KAL` does (SDS150 only).
    public var personality: MockPersonality {
        var personality = model.personality
        if let mdlName { personality.reportedModel = mdlName }
        if let pushLifetime { personality.pushLifetime = pushLifetime }
        if let keepAliveRevivesStoppedPushes { personality.keepAliveRevivesStoppedPushes = keepAliveRevivesStoppedPushes }
        return personality
    }

    private mutating func addFault(_ text: String) throws {
        let bad = MockScannerArgumentsError.invalidValue(option: "--fault", value: text)
        let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
        let number = parts.count == 2 ? Double(parts[1]) : nil
        switch (parts[0], parts.count) {
        case ("stall-psi", 2):
            guard let number, number >= 0 else { throw bad }
            faults.stallPSIAfter = number
        case ("drop-audio", 2):
            guard let number, number >= 0 else { throw bad }
            faults.dropAudioAfter = number
        case ("keepalive", 2):
            guard let code = Int(parts[1]), (100...599).contains(code) else { throw bad }
            faults.keepaliveStatus = code
        case ("wedge-audio", 1): faults.wedgeAudio = true
        case ("wedge-control", 1): faults.wedgeTakesControlDown = true
        case ("split-writes", 1): faults.splitWrites = true
        case ("line-out-silent", 1): faults.lineOutSilent = true
        case ("unplug", 2), ("unplug-after-psi", 2):
            // N or N:M (seconds, each at least 0).
            let pieces = parts[1].split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
            let seconds = pieces.compactMap { $0 }.filter { $0 >= 0 && $0.isFinite }
            guard (1...2).contains(pieces.count), seconds.count == pieces.count else { throw bad }
            faults.unplugAfter = seconds[0]
            faults.replugAfter = seconds.count == 2 ? seconds[1] : nil
            faults.unplugCountsFromFirstPSI = parts[0] == "unplug-after-psi"
        case ("drop-reply", 2), ("drop-request", 2):
            // NAME or NAME:N (N = how many datagrams, at least 1).
            let pieces = parts[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard (1...2).contains(pieces.count), !pieces[0].isEmpty, !pieces[0].contains(",") else { throw bad }
            if pieces.count == 2 {
                guard let count = Int(pieces[1]), count >= 1 else { throw bad }
                faults.dropCount = count
            }
            if parts[0] == "drop-reply" { faults.dropNextReply = pieces[0] } else { faults.dropNextRequest = pieces[0] }
        default: throw bad
        }
    }

    /// How long an `FQK` or `SQK` set holds back its reply: 0.8 s as on hardware, none with `--no-delays`.
    public var quickKeySetDelay: Duration { realisticDelays ? .milliseconds(800) : .zero }

    /// The bundled scenario named `scenario`, or the file at that path.
    public func loadScenario() throws -> MockScenario {
        if let url = MockScenario.bundledURL(scenario) { return try MockScenario.load(url) }
        return try MockScenario.load(URL(fileURLWithPath: scenario))
    }

    public func options(log: (@Sendable (String) -> Void)?) -> MockSDS200.Options {
        MockSDS200.Options(
            clock: .real(startingAt: startAt), udpPort: udpPort, rtspPort: rtspPort,
            reconnectCooldown: .milliseconds(Int((cooldownSeconds * 1000).rounded())), cooldownAfter: cooldownAfter,
            wedgeMode: wedgeMode,
            rebootDuration: .milliseconds(Int((rebootSeconds * 1000).rounded())),
            replyDelays: realisticDelays ? MockSDS200.Options.realisticReplyDelays : [:],
            quickKeySetDelay: quickKeySetDelay, gltPageSize: gltPageSize ?? MockFavorites.defaultGLTPageSize,
            verbose: verbose, log: log)
    }
}
