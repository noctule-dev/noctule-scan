// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleStore

public enum CLICommand: Equatable, Sendable {
    case info, status, display
    /// One `MSI` (read-only): the menu screen the scanner describes, every item with its index.
    case menu
    /// The Favorites tree with its quick-key states (read-only).
    case quickKeys
    case watch(interval: Duration, count: Int?)
    /// Stream the scanner's audio: play it (unless `play` is false), optionally record WAV to
    /// `record`, and stop after `seconds` (nil: until Ctrl-C or failure). `station` is `--station`:
    /// a network station gives its address and reconnect wait, a USB station its line-in (its audio
    /// input alone, with no scanner traffic); `meter` (`--meter`, a line-in station only) draws a
    /// text level meter on stderr.
    case listen(record: String?, seconds: Int?, play: Bool, station: String? = nil, meter: Bool = false)
    /// Restart the scanner (`MSM,1`). `confirmed` is `--yes`; without it the CLI asks first.
    case restart(confirmed: Bool)
    /// List the Uniden serial ports found. Sends nothing.
    case ports
    /// List the system's audio inputs (`NOCTULE_NO_USB_DETECTION` lists none). Opens none.
    case audioInputs
    /// Manage stations (`station add|list|remove`).
    case station(StationAction)
    /// Run a station and log its hits: `station` is `--station` (nil: the last used, or the only
    /// one); stop after `seconds` (nil: until a stop signal).
    case log(station: String?, seconds: Int?)
    /// List a station's hits, or export them as CSV.
    case hits(HitsOptions)
}

public enum StationAction: Equatable, Sendable {
    case add(StationAddOptions)
    case list
    case remove(name: String)
}

/// `station add`. `name` and `host` are "" when their flag is missing; `Station.validate()`
/// reports that.
public struct StationAddOptions: Equatable, Sendable {
    public var name: String
    public var host: String
    public var udpPort: UInt16?
    public var rtspPort: UInt16?
    public var saveAudio: SaveAudio?
    /// `--reconnect-cooldown S`: the clean-close reconnect wait, 0…120 s (default 120).
    public var reconnectCooldown: Int?
    /// `--usb`: a station for a scanner on a USB serial port (no host or network ports).
    public var usb: Bool
    /// `--serial-port PATH` (with `--usb`): the port to open; nil lets the station find its scanner.
    public var serialPort: String?
    /// `--audio-input NAME|UID` (with `--usb`): the line-in's audio input, matched against the system's
    /// listing by `StationCLI.resolveAudioInput`.
    public var audioInput: String?
    /// `--audio-channel left|right|both` (with `--audio-input`); nil saves none (reads as both).
    public var audioChannel: LineInChannel?

    public init(name: String, host: String, udpPort: UInt16? = nil, rtspPort: UInt16? = nil, saveAudio: SaveAudio? = nil,
                reconnectCooldown: Int? = nil, usb: Bool = false, serialPort: String? = nil,
                audioInput: String? = nil, audioChannel: LineInChannel? = nil) {
        self.name = name; self.host = host; self.udpPort = udpPort; self.rtspPort = rtspPort; self.saveAudio = saveAudio
        self.reconnectCooldown = reconnectCooldown
        self.usb = usb; self.serialPort = serialPort
        self.audioInput = audioInput; self.audioChannel = audioChannel
    }
}

public struct HitsOptions: Equatable, Sendable {
    public var station: String?
    /// `--groups`: one row per talkgroup or channel instead of one per transmission.
    public var groups: Bool
    /// `--new`: only new hits (or groups).
    public var onlyNew: Bool
    /// `--since YYYY-MM-DD`, as local midnight.
    public var since: Date?
    /// `--csv`: `HitLog.exportCSV` to stdout.
    public var csv: Bool

    public init(station: String? = nil, groups: Bool = false, onlyNew: Bool = false, since: Date? = nil, csv: Bool = false) {
        self.station = station; self.groups = groups; self.onlyNew = onlyNew; self.since = since; self.csv = csv
    }
}

/// Which USB serial port `--serial` means: `--serial` alone is `.auto` (`SCANNER_SERIAL`, else the one
/// Uniden port found), `--serial /path` is that path.
public enum SerialSelection: Equatable, Sendable { case auto, path(String) }

public struct CLIInvocation: Equatable, Sendable {
    public var command: CLICommand
    public var host: String?
    public var port: UInt16?
    /// `--rtsp-port`: the RTSP audio server's TCP port (listen only).
    public var rtspPort: UInt16?
    /// `--cooldown-seconds` (testing only, with a private `--cooldown-store`): the *full* RTSP
    /// reconnect cooldown, after an unclean close, default 120 s. Clamped
    /// to at most 86400 (a day) at parse time, so converting it to milliseconds can't overflow.
    public var cooldownSeconds: Double?
    /// `--cooldown-store` (testing only): the cooldown record file, default
    /// `FileRTSPCooldownStore.defaultURL`.
    public var cooldownStore: String?
    /// `--reconnect-cooldown S` (listen): the wait after a clean close, 0…120 s (default 120),
    /// clamped to the full value. Every other close waits the full value.
    public var reconnectCooldown: Int?
    /// `--settings-dir` (station, log, hits, listen): the settings directory, default
    /// `StationCLI.defaultSettingsDirectory`. Hit logs live under it too.
    public var settingsDir: String?
    /// `--recordings` (log): the recordings root, default `StationCLI.defaultRecordingsRoot`.
    public var recordings: String?
    /// `--serial [PATH]` (info, status, display, watch; listen and restart parse it only to refuse it,
    /// `CLIArguments.serialProblem`): talk to a USB scanner instead of the network one.
    public var serial: SerialSelection?

    public init(command: CLICommand, host: String? = nil, port: UInt16? = nil, rtspPort: UInt16? = nil,
                cooldownSeconds: Double? = nil, cooldownStore: String? = nil, reconnectCooldown: Int? = nil,
                settingsDir: String? = nil, recordings: String? = nil, serial: SerialSelection? = nil) {
        self.command = command; self.host = host; self.port = port; self.rtspPort = rtspPort
        self.cooldownSeconds = cooldownSeconds; self.cooldownStore = cooldownStore
        self.reconnectCooldown = reconnectCooldown
        self.settingsDir = settingsDir; self.recordings = recordings
        self.serial = serial
    }
}

public struct CLIUsageError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public static let usage = """
        usage: noctule <info|status|display|menu|quick-keys|watch|listen|restart|ports|audio-inputs|station|log|hits> [--host H] [--port P]
                      [--serial [PATH]]
               noctule watch [--interval MS] [--count N]
               noctule listen [--record PATH] [--seconds N] [--no-play] [--rtsp-port P] [--reconnect-cooldown S]
               noctule listen --station N [--meter] [--record PATH] [--seconds N] [--no-play]
               noctule restart [--yes]
               noctule ports
               noctule audio-inputs
               noctule station add --name N --host H [--udp-port P] [--rtsp-port P] [--save-audio every|new|never]
                                   [--reconnect-cooldown S]
               noctule station add --name N --usb [--serial-port PATH] [--audio-input NAME|ID [--audio-channel left|right|both]]
               noctule station list
               noctule station remove --name N
               noctule log [--station N] [--seconds S] [--recordings DIR]
               noctule hits [--station N] [--groups] [--new] [--since YYYY-MM-DD] [--csv]
               (--serial takes a USB scanner's port instead of --host and --port, on info, status, display, and watch)
               (station, log, hits, and listen --station also take --settings-dir DIR)
        """
    public var description: String { "\(message)\n\(Self.usage)" }
}

public enum CLIArguments {
    /// Why `--cooldown-seconds` can't be used, or nil. It is for tests against the mock only, so
    /// (as with the app's `NOCTULE_COOLDOWN_SECONDS`) it needs a `--cooldown-store` that isn't the
    /// shared record (`sharedStore`, compared after resolving symlinks): a shortened cooldown never
    /// reaches the store the real scanner's runs use.
    public static func cooldownOverrideProblem(_ invocation: CLIInvocation,
                                               sharedStore: URL = FileRTSPCooldownStore.defaultURL) -> String? {
        guard invocation.cooldownSeconds != nil else { return nil }
        if let path = invocation.cooldownStore, !FileRTSPCooldownStore.samePath(URL(fileURLWithPath: path), sharedStore) { return nil }
        return "--cooldown-seconds is for tests against the mock only: it needs a private --cooldown-store, not the shared record"
    }

    /// The largest `--cooldown-seconds` accepted (a day); larger values are clamped to it.
    public static let maxCooldownSeconds: Double = 86_400

    /// The flags each subcommand accepts (`station` is keyed by its action).
    private static let allowedFlags: [String: Set<String>] = {
        let control: Set<String> = ["--host", "--port"]
        // --serial is parsed on listen and restart too, so they refuse it with a reason (`serialProblem`).
        let serial = control.union(["--serial"])
        return [
            "info": serial, "status": serial, "display": serial, "menu": serial, "quick-keys": serial,
            "watch": serial.union(["--interval", "--count"]),
            "ports": [],
            "audio-inputs": [],
            "listen": serial.union(["--record", "--seconds", "--no-play", "--rtsp-port", "--cooldown-seconds", "--cooldown-store",
                                     "--reconnect-cooldown", "--station", "--meter", "--settings-dir"]),
            "restart": serial.union(["--yes", "--cooldown-store"]),
            "station add": ["--name", "--host", "--udp-port", "--rtsp-port", "--save-audio", "--reconnect-cooldown",
                            "--settings-dir", "--usb", "--serial-port", "--audio-input", "--audio-channel"],
            "station list": ["--settings-dir"],
            "station remove": ["--name", "--settings-dir"],
            "log": ["--station", "--seconds", "--settings-dir", "--recordings", "--cooldown-seconds", "--cooldown-store"],
            "hits": ["--station", "--groups", "--new", "--since", "--csv", "--settings-dir"],
        ]
    }()

    /// Non-nil when `--serial` is misused: with `--host` or `--port`, or on `listen` or `restart`.
    /// Exit 2, nothing sent. Nil without `--serial`.
    public static func serialProblem(_ invocation: CLIInvocation) -> String? {
        guard invocation.serial != nil else { return nil }
        if invocation.host != nil || invocation.port != nil { return "--serial can't be combined with --host or --port" }
        switch invocation.command {
        case .listen: return "listen: no audio over USB"
        case .restart: return "restart: not supported over USB"
        default: return nil
        }
    }

    /// Non-nil when `listen`'s `--station` or `--meter` is misused: `--station` with `--host` or
    /// `--rtsp-port` (the station gives the address), or `--meter` without `--station` (only a
    /// line-in has a meter). Exit 2, nothing read or opened. `--meter` on a network station is
    /// refused once the station is read (`ListenStation.plan`).
    public static func listenProblem(_ invocation: CLIInvocation) -> String? {
        guard case .listen(_, _, _, let station, let meter) = invocation.command else { return nil }
        if station != nil, invocation.host != nil || invocation.rtspPort != nil { return ListenStation.addressConflictLine }
        if meter, station == nil { return ListenStation.meterNeedsLineInLine }
        return nil
    }

    public static func parse(_ args: [String]) throws -> CLIInvocation {
        func fail(_ m: String) -> CLIUsageError { CLIUsageError(message: m) }
        var positional: [String] = []
        var seen: [String] = []
        var host: String?, port: UInt16?, interval: Int?, count: Int?
        var record: String?, seconds: Int?, noPlay = false, rtspPort: UInt16?, meter = false
        var cooldownSeconds: Double?, cooldownStore: String?, reconnectCooldown: Int?, yes = false
        var name: String?, udpPort: UInt16?, saveAudio: SaveAudio?, stationName: String?
        var settingsDir: String?, recordings: String?
        var groups = false, onlyNew = false, since: Date?, csv = false
        var serial: SerialSelection?, usb = false, serialPort: String?
        var audioInput: String?, audioChannel: LineInChannel?
        var rest = args[...]
        func value(_ flag: String) throws -> String {
            guard let v = rest.popFirst() else { throw fail("\(flag) needs a value") }
            return v
        }
        while let arg = rest.popFirst() {
            if arg.hasPrefix("--") { seen.append(arg) }
            switch arg {
            case "--host": host = try value(arg)
            case "--port":
                guard let p = UInt16(try value(arg)) else { throw fail("--port must be 0-65535") }
                port = p
            case "--interval":
                guard let v = Int(try value(arg)), v >= 1 else { throw fail("--interval must be a whole number of milliseconds, at least 1") }
                interval = v
            case "--count":
                guard let v = Int(try value(arg)), v >= 1 else { throw fail("--count must be a whole number, at least 1") }
                count = v
            case "--record": record = try value(arg)
            case "--seconds":
                guard let v = Int(try value(arg)), v >= 1 else { throw fail("--seconds must be a whole number, at least 1") }
                seconds = v
            case "--no-play": noPlay = true
            case "--meter": meter = true
            case "--rtsp-port":
                guard let p = UInt16(try value(arg)) else { throw fail("--rtsp-port must be 0-65535") }
                rtspPort = p
            case "--cooldown-seconds":
                guard let v = Double(try value(arg)), v.isFinite, v >= 0 else {
                    throw fail("--cooldown-seconds must be a number of seconds, at least 0")
                }
                cooldownSeconds = min(v, CLIArguments.maxCooldownSeconds)
            case "--cooldown-store": cooldownStore = try value(arg)
            case "--reconnect-cooldown":
                guard let v = Int(try value(arg)), StationConnection.reconnectCooldownRange.contains(v) else {
                    throw fail("--reconnect-cooldown must be a whole number of seconds, 0-120")
                }
                reconnectCooldown = v
            case "--yes": yes = true
            case "--name": name = try value(arg)
            case "--udp-port":
                guard let p = UInt16(try value(arg)) else { throw fail("--udp-port must be 0-65535") }
                udpPort = p
            case "--save-audio":
                let text = try value(arg)
                guard let v = StationCLI.parseSaveAudio(text) else { throw fail("--save-audio must be every, new, or never") }
                saveAudio = v
            case "--station": stationName = try value(arg)
            case "--settings-dir": settingsDir = try value(arg)
            case "--recordings": recordings = try value(arg)
            case "--groups": groups = true
            case "--new": onlyNew = true
            case "--since":
                let text = try value(arg)
                guard let day = StationCLI.parseDay(text) else { throw fail("--since must be a date, YYYY-MM-DD") }
                since = day
            case "--csv": csv = true
            case "--serial":
                // A path only when the next argument starts with "/"; anything else is not its value.
                if let next = rest.first, next.hasPrefix("/") {
                    serial = .path(next)
                    rest.removeFirst()
                } else {
                    serial = .auto
                }
            case "--usb": usb = true
            case "--serial-port": serialPort = try value(arg)
            case "--audio-input":
                let text = try value(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw fail("--audio-input needs an audio input's name or ID") }
                audioInput = text
            case "--audio-channel":
                guard let v = LineInChannel(rawValue: try value(arg)) else { throw fail("--audio-channel must be left, right, or both") }
                audioChannel = v
            case _ where arg.hasPrefix("--"): throw fail("unknown option '\(arg)'")
            default: positional.append(arg)
            }
        }
        guard let sub = positional.first else { throw fail("missing subcommand") }
        var key = sub
        if sub == "station" {
            guard positional.count >= 2 else { throw fail("station needs an action: add, list, or remove") }
            key = "station \(positional[1])"
            guard allowedFlags[key] != nil else { throw fail("unknown station action '\(positional[1])'") }
            if positional.count > 2 { throw fail("unexpected argument '\(positional[2])'") }
        } else if positional.count > 1 {
            throw fail("unexpected argument '\(positional[1])'")
        }
        guard let allowed = allowedFlags[key] else { throw fail("unknown subcommand '\(sub)'") }
        if let flag = seen.first(where: { !allowed.contains($0) }) {
            throw fail("\(flag) doesn't apply to \(key)")
        }
        let command: CLICommand
        switch key {
        case "ports": command = .ports
        case "audio-inputs": command = .audioInputs
        case "info": command = .info
        case "status": command = .status
        case "display": command = .display
        case "menu": command = .menu
        case "quick-keys": command = .quickKeys
        case "watch": command = .watch(interval: .milliseconds(interval ?? 500), count: count)
        case "listen": command = .listen(record: record, seconds: seconds, play: !noPlay, station: stationName, meter: meter)
        case "restart": command = .restart(confirmed: yes)
        case "station add":
            if usb {
                if let flag = seen.first(where: { ["--host", "--udp-port", "--rtsp-port", "--reconnect-cooldown"].contains($0) }) {
                    throw fail("--usb can't be combined with \(flag)")
                }
            } else if serialPort != nil {
                throw fail("--serial-port needs --usb")
            }
            if audioInput == nil, audioChannel != nil { throw fail("--audio-channel needs --audio-input") }
            if audioInput != nil, !usb { throw fail("--audio-input needs --usb") }
            command = .station(.add(StationAddOptions(name: name ?? "", host: host ?? "", udpPort: udpPort,
                                                      rtspPort: rtspPort, saveAudio: saveAudio,
                                                      reconnectCooldown: reconnectCooldown,
                                                      usb: usb, serialPort: serialPort,
                                                      audioInput: audioInput, audioChannel: audioChannel)))
        case "station list": command = .station(.list)
        case "station remove":
            guard let name else { throw fail("station remove needs --name") }
            command = .station(.remove(name: name))
        case "log": command = .log(station: stationName, seconds: seconds)
        case "hits":
            if csv, groups { throw fail("--csv exports transmissions; it can't be combined with --groups") }
            command = .hits(HitsOptions(station: stationName, groups: groups, onlyNew: onlyNew, since: since, csv: csv))
        default: throw fail("unknown subcommand '\(sub)'")
        }
        return CLIInvocation(command: command, host: host, port: port, rtspPort: rtspPort,
                             cooldownSeconds: cooldownSeconds, cooldownStore: cooldownStore,
                             reconnectCooldown: reconnectCooldown, settingsDir: settingsDir, recordings: recordings,
                             serial: serial)
    }
}
