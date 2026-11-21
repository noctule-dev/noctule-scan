// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleStore

/// How `--audio-input`'s value matched the system's inputs.
public enum AudioInputResolution: Equatable, Sendable {
    /// One input, by its UID or its name.
    case input(uid: String, name: String)
    /// Nothing matched, and no inputs are listed at all (the kill-switch): the value is kept as the UID.
    case savedAsID(String)
    case notFound(String)
    /// Several inputs have this name.
    case ambiguous(String, uids: [String])
}

/// Why `--station` (or its absence) didn't pick a station.
public enum StationLookupError: Error, Equatable, CustomStringConvertible {
    case noStations
    case notFound(name: String, names: [String])
    case ambiguous(names: [String])

    public var description: String {
        switch self {
        case .noStations:
            "no stations; add one with 'noctule station add --name N --host H'"
        case .notFound(let name, let names):
            "no station named \"\(name)\"; stations: \(names.joined(separator: ", "))"
        case .ambiguous(let names):
            "more than one station; pick one with --station: \(names.joined(separator: ", "))"
        }
    }
}

/// Where one `log` line goes.
public enum LogOutput: Equatable, Sendable {
    case stdout(String)
    case stderr(String)
}

/// Paths, station lookup, and output formatting for `noctule station`, `log`, and `hits`.
public enum StationCLI {
    // MARK: Paths

    /// `~/Library/Application Support/NoctuleScan/`: `stations.json`, `device.json`, `app.json`,
    /// and `Stations/<uuid>/hits.sqlite`.
    public static var defaultSettingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoctuleScan", isDirectory: true)
    }

    /// `~/Music/Noctule Scan/`; each station records into `<root>/<station name>/`.
    public static var defaultRecordingsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Noctule Scan", isDirectory: true)
    }

    /// `--settings-dir`, else the default.
    public static func settingsDirectory(_ flag: String?) -> URL {
        flag.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultSettingsDirectory
    }

    /// `--recordings`, else the default.
    public static func recordingsRoot(_ flag: String?) -> URL {
        flag.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultRecordingsRoot
    }

    /// `<settings>/Stations/<uuid>/hits.sqlite`.
    public static func hitLogURL(settingsDirectory: URL, stationID: UUID) -> URL {
        settingsDirectory.appendingPathComponent("Stations", isDirectory: true)
            .appendingPathComponent(stationID.uuidString, isDirectory: true)
            .appendingPathComponent("hits.sqlite")
    }

    // MARK: Parsing

    /// `every`, `new`, or `never`.
    public static func parseSaveAudio(_ text: String) -> SaveAudio? {
        switch text {
        case "every": .everyTransmission
        case "new": .onlyNew
        case "never": .never
        default: nil
        }
    }

    public static func saveAudioName(_ value: SaveAudio) -> String {
        switch value {
        case .everyTransmission: "every"
        case .onlyNew: "new"
        case .never: "never"
        }
    }

    /// `YYYY-MM-DD` as midnight in `timeZone`; nil for anything else, or a date that doesn't exist.
    public static func parseDay(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: y, month: m, day: d)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return date
    }

    // MARK: Stations

    /// A new station from `station add`'s flags (name and host trimmed; unset flags keep the
    /// model's defaults).
    public static func makeStation(_ options: StationAddOptions) -> Station {
        var station = Station()
        station.name = options.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.usb {
            station.connection.transport = .usbSerial
        } else {
            station.connection.host = options.host.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let p = options.udpPort { station.connection.udpPort = p }
        if let p = options.rtspPort { station.connection.rtspPort = p }
        if let s = options.saveAudio { station.recording.saveAudio = s }
        if let s = options.reconnectCooldown { station.connection.reconnectCooldownSeconds = s }
        return station
    }

    /// The device-only settings a new USB station needs: its `--serial-port`, trimmed, and its line-in
    /// (`audioInput`, how `--audio-input` resolved, with `--audio-channel`; no channel given saves none,
    /// which reads as both). Nil when it is not a USB station or has neither (nothing to store).
    public static func deviceSettings(for station: Station, options: StationAddOptions,
                                      audioInput: AudioInputResolution? = nil) -> StationDeviceSettings? {
        guard options.usb else { return nil }
        var device = StationDeviceSettings(stationID: station.id)
        if let port = options.serialPort?.trimmingCharacters(in: .whitespacesAndNewlines), !port.isEmpty {
            device.usbPort = port
        }
        switch audioInput {
        case .input(let uid, let name):
            device.audioInputDevice = uid
            device.audioInputName = name
            device.audioInputChannel = options.audioChannel
        case .savedAsID(let id):
            device.audioInputDevice = id
            device.audioInputName = id
            device.audioInputChannel = options.audioChannel
        case .notFound, .ambiguous, nil:
            break
        }
        return device.usbPort == nil && device.audioInputDevice == nil ? nil : device
    }

    // MARK: Audio inputs (`--audio-input`)

    /// A UID that is listed wins; else the one input with that name (ignoring case and surrounding
    /// spaces); several are ambiguous. With nothing matching, `listingAvailable` false (no inputs are
    /// listed, as under the kill-switch) keeps the value as a UID, and otherwise it is not found.
    public static func resolveAudioInput(_ value: String, inputs: [AudioInputDevice],
                                         listingAvailable: Bool) -> AudioInputResolution {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byID = inputs.first(where: { $0.uid == value }) { return .input(uid: byID.uid, name: byID.name) }
        let named = inputs.filter { $0.name.compare(value, options: .caseInsensitive) == .orderedSame }
        if named.count == 1 { return .input(uid: named[0].uid, name: named[0].name) }
        if named.count > 1 { return .ambiguous(value, uids: named.map(\.uid)) }
        return listingAvailable ? .notFound(value) : .savedAsID(value)
    }

    /// Why `resolution` can't be saved (the refusal's text, without a prefix), or nil.
    public static func audioInputProblem(_ resolution: AudioInputResolution) -> String? {
        switch resolution {
        case .input, .savedAsID: nil
        case .notFound(let value): "no audio input named \"\(value)\"; run noctule audio-inputs"
        case .ambiguous(let value, let uids): "\"\(value)\" names more than one audio input (\(uids.joined(separator: ", "))); give its ID"
        }
    }

    /// The note printed when a value was saved as an ID with no input to check it against, or nil.
    public static func audioInputNote(_ resolution: AudioInputResolution) -> String? {
        guard case .savedAsID(let id) = resolution else { return nil }
        return "station: saved \"\(id)\" as an audio input ID (no inputs are listed)"
    }

    /// `line-in <name> (<channel>)`, as `station add` and `station list` show it.
    public static func lineInText(_ lineIn: LineInConfig) -> String {
        "line-in \(lineIn.deviceName) (\(lineIn.channel.rawValue))"
    }

    /// What `station add` did.
    public enum AddResult: Equatable, Sendable {
        /// Saved; the line to print, and notes for stderr.
        case added(line: String, notes: [String])
        /// The station can't be added (`Station.validate()`, a duplicate name): exit 1.
        case invalid([String])
        /// `--audio-input` can't be used (not found, ambiguous): a usage error, exit 64, nothing saved.
        case refused([String])
    }

    /// `station add`: resolves `--audio-input` against `inputs` (`listingAvailable` false when none can
    /// be listed), checks the station, and saves. The device settings (the port and the line-in) go in
    /// before the station: a station saved without the port it was given would let `log` use whatever
    /// Uniden port is plugged in, and one without its input would record nothing until it was edited.
    public static func add(_ options: StationAddOptions, existing: [Station], store: any SettingsStore,
                           inputs: [AudioInputDevice], listingAvailable: Bool) async throws -> AddResult {
        let resolution = options.audioInput.map {
            resolveAudioInput($0, inputs: inputs, listingAvailable: listingAvailable)
        }
        if let resolution, let problem = audioInputProblem(resolution) { return .refused([problem]) }
        let station = makeStation(options)
        let problems = addProblems(station, existing: existing)
        guard problems.isEmpty else { return .invalid(problems) }
        let device = deviceSettings(for: station, options: options, audioInput: resolution)
        if let device { try await store.saveDeviceSettings(device) }
        try await store.save(station)
        return .added(line: addedLine(station, usbPort: device?.usbPort, lineIn: device?.lineIn),
                      notes: resolution.flatMap(audioInputNote).map { [$0] } ?? [])
    }

    /// `station add`'s confirmation: a network station's host and ports, or `USB`, the port
    /// (`usbPort`, when one was given) and the line-in (when one was) for a USB station.
    public static func addedLine(_ station: Station, usbPort: String?, lineIn: LineInConfig? = nil) -> String {
        let save = "save audio: \(saveAudioName(station.recording.saveAudio))"
        if station.connection.transport == .usbSerial {
            let input = lineIn.map { ", \(lineInText($0))" } ?? ""
            return "added station \"\(station.name)\" (USB\(usbPort.map { " \($0)" } ?? ""), \(save)\(input))"
        }
        return "added station \"\(station.name)\" (\(station.connection.host ?? "-"), udp \(station.connection.udpPort), "
            + "rtsp \(station.connection.rtspPort), \(save))"
    }

    /// Why `station` can't be added: `Station.validate()`'s issues, then a duplicate name
    /// (case-insensitive). Empty means it can.
    public static func addProblems(_ station: Station, existing: [Station]) -> [String] {
        var problems = station.validate().map(issueText)
        if let other = self.station(named: station.name, in: existing) {
            problems.append(Station.duplicateNameMessage(existingName: other.name))
        }
        return problems
    }

    public static func issueText(_ issue: StationIssue) -> String {
        switch issue {
        case .emptyName: issue.message + " (--name)"
        case .missingHost: issue.message + " (--host)"
        case .invalidReconnectCooldown: issue.message + " (--reconnect-cooldown)"
        case .invalidMinimumDuration, .invalidMaxTransmission: issue.message
        }
    }

    /// The station whose name matches `name`, ignoring case and surrounding spaces.
    public static func station(named name: String, in stations: [Station]) -> Station? {
        Station.firstNamed(name, in: stations)
    }

    /// `--station` by name (case-insensitive); without it, the last used station, else the only one.
    public static func resolve(name: String?, stations: [Station], lastID: UUID?) -> Result<Station, StationLookupError> {
        guard !stations.isEmpty else { return .failure(.noStations) }
        let names = stations.map(\.name)
        if let name {
            if let match = station(named: name, in: stations) { return .success(match) }
            return .failure(.notFound(name: name, names: names))
        }
        if let lastID, let last = stations.first(where: { $0.id == lastID }) { return .success(last) }
        if stations.count == 1 { return .success(stations[0]) }
        return .failure(.ambiguous(names: names))
    }

    /// One line per station; `*` marks the last used one. A reconnect wait other than the
    /// default 120 s shows as `reconnect wait S s` (the editor's label). A USB station shows `USB`, or
    /// `USB <path>` when `usbPorts` (the stations' `StationDeviceSettings.usbPort`) holds its port, where
    /// a network station shows its host and ports; it shows no reconnect wait, which it doesn't use.
    /// `lineIns` (the stations' `StationDeviceSettings.lineIn`) adds `line-in <name> (<channel>)` after
    /// the port.
    public static func listLines(_ stations: [Station], lastID: UUID?, usbPorts: [UUID: String] = [:],
                                 lineIns: [UUID: LineInConfig] = [:]) -> [String] {
        guard !stations.isEmpty else { return ["no stations"] }
        return stations.map { s in
            let mark = s.id == lastID ? "*" : " "
            if s.connection.transport == .usbSerial {
                let port = usbPorts[s.id].map { " \($0)" } ?? ""
                let input = lineIns[s.id].map { "  \(lineInText($0))" } ?? ""
                return "\(mark) \(s.name)  USB\(port)\(input)  save audio: \(saveAudioName(s.recording.saveAudio))"
            }
            return "\(mark) \(s.name)  \(s.connection.host ?? "-")  udp \(s.connection.udpPort)"
                + "  rtsp \(s.connection.rtspPort)  save audio: \(saveAudioName(s.recording.saveAudio))"
                + (s.connection.reconnectCooldownSeconds == 120 ? "" : "  reconnect wait \(s.connection.reconnectCooldownSeconds) s")
        }
    }

    // MARK: log lines

    /// `TG<id> <channel>`, `<freq %.4f>MHz <channel>`, the channel alone, or `?`. A blank channel
    /// is left out.
    public static func sourceLabel(key: HitKey, channel: String?) -> String {
        let name = channel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix: String? = if let tg = key.talkgroupID {
            "TG\(tg)"
        } else if let f = key.frequencyMHz {
            String(format: "%.4fMHz", f)
        } else {
            nil
        }
        switch (prefix, name.isEmpty) {
        case (let p?, true): return p
        case (let p?, false): return "\(p) \(name)"
        case (nil, false): return name
        case (nil, true): return "?"
        }
    }

    /// Local `HH:MM:SS` (truncated to the second).
    public static func clockTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// `HH:MM:SS  + TG9 Lakeview Fire`, plus `  (new)` when new. The time is the hit's start.
    public static func startLine(_ hit: LoggedHit, timeZone: TimeZone = .current) -> String {
        "\(clockTime(hit.hit.startedAt, timeZone: timeZone))  + \(sourceLabel(key: hit.hit.key, channel: hit.hit.channel))"
            + (hit.isNew ? "  (new)" : "")
    }

    /// `HH:MM:SS  - TG9 Lakeview Fire  2.3 s`, plus `  → <file name>` when recorded, or
    /// `  → (no audio: <error>)` when the recording failed. The time is the hit's end.
    public static func endLine(_ hit: LoggedHit, timeZone: TimeZone = .current) -> String {
        let h = hit.hit
        let end = h.endedAt ?? h.startedAt
        var line = "\(clockTime(end, timeZone: timeZone))  - \(sourceLabel(key: h.key, channel: h.channel))"
            + "  " + String(format: "%.1f s", max(0, end.timeIntervalSince(h.startedAt)))
        if let audio = audioText(hit) { line += "  → " + audio }
        return line
    }

    /// The recording's file name, `(no audio: <error>)`, or nil.
    private static func audioText(_ hit: LoggedHit) -> String? {
        if let path = hit.audioPath { return URL(fileURLWithPath: path).lastPathComponent }
        if let error = hit.audioError { return "(no audio: \(error))" }
        return nil
    }

    public static func warningLine(_ text: String) -> String { "warning: \(text)" }

    /// The `log` line for a failed station-lock acquisition.
    public static func lockErrorLine(_ error: StationLockError, stationName: String) -> String {
        switch error {
        case .inUse(let pid):
            let who = pid.map { " (pid \($0))" } ?? ""
            return "log: \(stationName) is open in another Noctule Scan process\(who)"
        case .unavailable(let reason):
            return "log: can't lock \"\(stationName)\": \(reason)"
        }
    }

    /// Printed when a stop signal arrives while `log` is already closing.
    public static let stillClosingLine = "log: still closing the scanner session…"

    /// Printed once after a USB station's first `log: connected …` line.
    public static let noAudioOverUSBLine = "log: no audio over USB"

    /// Printed once after a USB station's first `log: connected …` line when the station has a
    /// line-in, in place of `noAudioOverUSBLine`: `audio: line-in <name> (<channel>)`.
    public static func lineInLine(_ config: LineInConfig) -> String { "audio: \(lineInText(config))" }

    /// The line `log` prints once after a USB station's first connect: its line-in, or no audio
    /// over USB. Nil for a line-in under the kill-switch (`lineInDisabled`, known before the run):
    /// the runner's `audio input disabled by …` warning alone says the station has no audio this
    /// run. A permission denial is learned only once the input is opened, so there the line comes
    /// first and the denied warning after it.
    public static func usbAudioLine(lineIn: LineInConfig?, lineInDisabled: Bool) -> String? {
        guard let lineIn else { return noAudioOverUSBLine }
        return lineInDisabled ? nil : lineInLine(lineIn)
    }

    /// The warning for a hit during which the line-in clipped: the channel's name, or the hit's source label when it has none.
    public static func clippedLine(_ hit: LoggedHit) -> String {
        let name = hit.hit.channel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = name.isEmpty ? sourceLabel(key: hit.hit.key, channel: nil) : name
        return warningLine("the audio input clipped during \"\(label)\"; turn the scanner's volume down")
    }

    /// What `log` prints in place of the runner's `lineInDeniedMessage` (which names the app): the
    /// terminal is what the system asks about.
    public static let terminalDeniedLine = warningLine(terminalDeniedText)

    /// Why a line-in can't be opened from the command line: the terminal is what the system asks
    /// about. `log` warns with it; `listen --station` fails with it.
    public static let terminalDeniedText =
        "this terminal isn't allowed to use audio input. Allow it in System Settings › Privacy & Security › Microphone."

    /// Printed after `log: scanner disconnected. …` when the runner is going to wait for the
    /// scanner and resume by itself (`StationRunner.willResume`).
    public static let waitingForScannerLine = "log: waiting for the scanner…"

    /// What `log` prints for a runner event: hits to stdout, status and warnings to stderr,
    /// nothing for recording results (the end line shows them), line-in states or `.stopped`. A
    /// clipped hit and the line-in's denied warning are warnings of their own.
    /// `reconnect`: a `.connected` that follows an earlier one (a USB station's scanner came back).
    public static func eventOutput(_ event: RunnerEvent, reconnect: Bool = false, timeZone: TimeZone = .current) -> LogOutput? {
        switch event {
        case .connected(let model, let firmware):
            reconnect ? .stderr("log: reconnected \(model) \(firmware)") : .stderr("log: connected to \(model) (firmware \(firmware))")
        case .disconnected(let hint): .stderr("log: scanner disconnected. \(hint)")
        case .audio(let state): ListenFormat.stateLine(state).map(LogOutput.stderr)
        case .hitStarted(let hit): .stdout(startLine(hit, timeZone: timeZone))
        case .hitEnded(let hit): .stdout(endLine(hit, timeZone: timeZone))
        case .warning(let text):
            .stderr(text == StationRunner.lineInDeniedMessage ? terminalDeniedLine : warningLine(text))
        case .clipped(let hit): .stderr(clippedLine(hit))
        case .recording, .lineIn, .stopped: nil
        }
    }

    /// The line for a `log` whose station couldn't start: a busy port says so on its own (as `info`
    /// does), a USB station with no port gives the hint, anything else the error.
    public static func startFailureLine(_ error: any Error, stationName: String) -> String {
        if let failure = CLIFormat.serialOpenFailure(error) { return failure.line }
        if case StationTransportError.scannerNotFound(let hint) = error {
            return "log: couldn't start \"\(stationName)\": \(hint)"
        }
        return "log: couldn't start \"\(stationName)\": \(error)"
    }

    // MARK: hits tables

    private static func left(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    private static func right(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    /// Local `yyyy-MM-dd HH:mm:ss`.
    private static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// One row per transmission, in the given order. Columns (fixed widths, two spaces apart):
    /// new mark (`*`), STARTED (19), DURATION (8, right; `open` for an open hit), SOURCE (32),
    /// SYSTEM (24), AUDIO (file name, `(no audio: <error>)`, or `-`). `["no hits"]` when empty.
    public static func transmissionsTable(_ hits: [LoggedHit], timeZone: TimeZone = .current) -> [String] {
        guard !hits.isEmpty else { return ["no hits"] }
        func row(_ mark: String, _ started: String, _ duration: String, _ source: String, _ system: String, _ audio: String) -> String {
            [mark, left(started, 19), right(duration, 8), left(source, 32), left(system, 24), audio].joined(separator: "  ")
        }
        var lines = [row(" ", "STARTED", "DURATION", "SOURCE", "SYSTEM", "AUDIO")]
        for logged in hits {
            let h = logged.hit
            let duration = h.endedAt.map { String(format: "%.1f s", max(0, $0.timeIntervalSince(h.startedAt))) } ?? "open"
            lines.append(row(logged.isNew ? "*" : " ", stamp(h.startedAt, timeZone: timeZone), duration,
                             sourceLabel(key: h.key, channel: h.channel), h.system ?? "-", audioText(logged) ?? "-"))
        }
        return lines
    }

    /// One row per talkgroup or channel, in the given order. Columns (fixed widths, two spaces
    /// apart): new mark (`*`), SOURCE (32), SYSTEM (24), HITS (5, right), TALK TIME (10, right),
    /// LAST SEEN (19), RSSI (max, or `-`). `["no hits"]` when empty.
    public static func groupsTable(_ groups: [HitGroup], timeZone: TimeZone = .current) -> [String] {
        guard !groups.isEmpty else { return ["no hits"] }
        func row(_ mark: String, _ source: String, _ system: String, _ hits: String, _ talk: String, _ last: String, _ rssi: String) -> String {
            [mark, left(source, 32), left(system, 24), right(hits, 5), right(talk, 10), left(last, 19), rssi].joined(separator: "  ")
        }
        var lines = [row(" ", "SOURCE", "SYSTEM", "HITS", "TALK TIME", "LAST SEEN", "RSSI")]
        for g in groups {
            // `HitGroup.label` falls back to "TG <id>" or "<freq> MHz" when no channel name was
            // seen; the source label already shows those.
            let fallbacks = [g.key.talkgroupID.map { "TG \($0)" }, g.key.frequencyMHz.map { String(format: "%.4f MHz", $0) }]
            let channel = fallbacks.contains(g.label) ? nil : g.label
            lines.append(row(g.isNew ? "*" : " ", sourceLabel(key: g.key, channel: channel), g.key.system ?? "-",
                             String(g.hits), String(format: "%.1f s", g.talkTime), stamp(g.lastSeen, timeZone: timeZone),
                             g.rssiMax.map(String.init) ?? "-"))
        }
        return lines
    }
}
