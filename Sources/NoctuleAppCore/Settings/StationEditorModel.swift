// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import NoctuleKit
import NoctuleStore

/// The result of "Test connection".
public enum ConnectionTest: Equatable, Sendable {
    case ok(model: String, firmware: String)
    case noAnswer(String)
    case failed(String)
}

/// A save or update found no station with this id: it was deleted meanwhile, and it is not
/// re-created.
public struct StationNoLongerExists: Error, Equatable, Sendable, CustomStringConvertible {
    public var id: UUID
    public init(id: UUID) { self.id = id }
    public var description: String { "This station no longer exists." }
}

/// `save()` refuses a draft with problems.
public struct StationValidationError: Error, Equatable, Sendable {
    public var issues: [String]
}

/// Add or edit one station: validation, duplicate names, "Test connection", key-map conflicts.
///
/// `issues` is computed from `draft` and the other stations read once by `load()` (call it when
/// the editor opens; before it, only `validate()` problems show). `testConnection()` sends `MDL`
/// and `VER` only, on a fresh client that it always disconnects: never `PSI`, `STS`, `GCS`, `KEY`
/// or RTSP.
///
/// **A USB station** (SDS150 design §7.1) has no host, ports or reconnect wait to edit (they stay
/// as they were); its port is `usbPort`, kept in the device settings (`StationDeviceSettings`),
/// nil for Automatic. `usbStatus` says which port it would open, from `SerialPort.resolve` on the
/// ports `refreshPorts()` last listed: a saved port that isn't there never falls back to a listed
/// one. `ports` defaults to `FixedSerialPortListing.empty`; only the app shell passes the
/// system's listing (`SessionEnvironment.serialPorts`, behind the kill-switch), so nothing built
/// by a test can find a real scanner by itself. Test Connection over USB opens the resolved port
/// only, and not while the station's own window holds it (`isOpenElsewhere`).
///
/// **A USB station's audio input** (line-in design §5.1, §6.1) is `audioInput` (a Core Audio UID,
/// nil for None) and `audioInputChannel`, kept in the device settings beside the port
/// (`audioInputDevice`, `audioInputName`, `audioInputChannel`). `audioInputs` is what the init's
/// listing lists, read again with `refreshPorts()`; `audioInputOptions` is the popup's rows.
/// `save()` writes the port and the input in one device-settings write before the station, and
/// clears the input of a network station; `lineInChanged` then says whether one of the three keys
/// changed (the caller tells the registry, `SessionRegistry.lineInChanged`). The listing defaults
/// to `FixedAudioInputListing.empty`; only the app shell passes the system's, behind the
/// kill-switch.
@MainActor @Observable
public final class StationEditorModel {
    public var draft: Station
    /// The model the last successful `testConnection()` reported. `draft.connection.modelOverride`
    /// stays the user's choice.
    public private(set) var detectedModel: ScannerModel?
    /// The Uniden ports `refreshPorts()` last listed (nothing opened to learn them).
    public private(set) var foundPorts: [SerialPortInfo] = []
    /// The draft's saved port, nil for Automatic (the only port found). `load()` reads it from the
    /// device settings; `save()` writes it there for a USB station.
    public var usbPort: String?
    /// True when the last `save()` changed the saved port (the caller then tells the registry,
    /// `SessionRegistry.deviceSettingsChanged`).
    public private(set) var savedPortChanged = false
    /// The audio inputs `refreshPorts()` last listed (nothing opened to learn them).
    public private(set) var audioInputs: [AudioInputDevice] = []
    /// The draft's audio input (a Core Audio UID), nil for None. `load()` reads it from the device
    /// settings; `save()` writes it there for a USB station and clears it for any other.
    public var audioInput: String?
    /// The channel of `audioInput`; a mono device ignores it. Both when none was saved.
    public var audioInputChannel: LineInChannel = .both
    /// True when the last `save()` changed one of the three input keys (the caller then tells the
    /// registry, `SessionRegistry.lineInChanged`).
    public private(set) var lineInChanged = false
    private var others: [Station] = []
    /// What other stations' device settings name as their input, read by `load()`.
    private var othersInputs: [(station: String, uid: String, channel: LineInChannel)] = []
    /// Opened with no station ("Add"): `save()` stores the whole draft. Otherwise it updates.
    private let isNew: Bool
    /// The station as the editor was opened with it: `save()` writes only the fields that differ.
    private let original: Station
    /// The saved port as `load()` (or the last `save()`) found it: `save()` writes the port only
    /// when `usbPort` differs, so a device-settings read that failed at load never clears it.
    private var loadedUSBPort: String?
    /// A port change written by a `save()` whose station write then failed: the next save that
    /// works still reports it in `savedPortChanged`.
    private var portChangePending = false
    /// The input as `load()` (or the last `save()`) found it, as the device settings hold it: the
    /// name is kept for showing a missing input and written back as it was.
    private var loadedInput = InputKeys()
    /// An input change written by a `save()` whose station write then failed.
    private var inputChangePending = false
    /// The present input `audioInput` names on behalf of a saved one that moved (see
    /// `savedInputFallback`), while the user hasn't chosen another.
    private var fallbackApplied: String?
    private let audioInputListing: any AudioInputListing
    private let settings: any SettingsStore
    private let ports: any SerialPortListing
    private let makeTransport: @Sendable (String, UInt16) -> any ScannerTransport
    private let makeSerialTransport: @Sendable (String) -> (any ScannerTransport)?
    private let commandTimeout: Duration
    private let isOpenElsewhere: @MainActor (UUID) -> Bool

    /// - Parameters:
    ///   - ports: the Uniden serial ports a USB station with no saved port may use. Defaults to the
    ///     empty listing; the app passes `SessionEnvironment.serialPorts`.
    ///   - audioInputs: the audio inputs a USB station may listen to. Defaults to the empty listing;
    ///     the app passes the system's.
    ///   - makeSerialTransport: a USB station's transport on its resolved port; nil where there is
    ///     none (iOS), and Test Connection then says it isn't supported here.
    ///   - isOpenElsewhere: whether a window holds a session for the station (its port is then in
    ///     use, and Test Connection opens nothing).
    public init(station: Station?, settings: any SettingsStore,
                ports: any SerialPortListing = FixedSerialPortListing.empty,
                audioInputs: any AudioInputListing = FixedAudioInputListing.empty,
                makeTransport: @escaping @Sendable (String, UInt16) -> any ScannerTransport = { UDPTransport(host: $0, port: $1) },
                makeSerialTransport: @escaping @Sendable (String) -> (any ScannerTransport)? = StationEditorModel.defaultSerialTransport,
                commandTimeout: Duration = .seconds(2),
                isOpenElsewhere: @escaping @MainActor (UUID) -> Bool = { _ in false }) {
        self.draft = station ?? Station()
        self.isNew = station == nil
        self.original = station ?? Station()
        self.settings = settings
        self.ports = ports
        self.audioInputListing = audioInputs
        self.makeTransport = makeTransport
        self.makeSerialTransport = makeSerialTransport
        self.commandTimeout = commandTimeout
        self.isOpenElsewhere = isOpenElsewhere
    }

    /// `SerialTransport(path:)` on macOS; nil elsewhere (no serial transport).
    public nonisolated static let defaultSerialTransport: @Sendable (String) -> (any ScannerTransport)? = { path in
        #if os(macOS)
        return SerialTransport(path: path)
        #else
        return nil
        #endif
    }

    /// Set when `load()` couldn't read the stored stations (the duplicate-name check is then off
    /// until a later `load()` succeeds). `save()` re-reads for itself and throws instead.
    public private(set) var loadError: String?

    /// Reads the stored stations for the live duplicate-name check in `issues`, and an existing
    /// station's saved port (`usbPort`) from its device settings; then lists the ports.
    public func load() async {
        do {
            others = try await settings.stations()
            loadError = nil
        } catch {
            loadError = "can't read the stored stations: \(error.localizedDescription)"
        }
        if !isNew {
            do {
                let device = try await settings.deviceSettings(for: draft.id)
                loadedUSBPort = device.usbPort
                usbPort = device.usbPort
                loadedInput = InputKeys(device)
                audioInput = device.audioInputDevice
                audioInputChannel = device.audioInputChannel ?? .both
            } catch {
                loadError = loadError ?? "can't read this station's device settings: \(error.localizedDescription)"
            }
        }
        await loadOthersInputs()
        refreshPorts()
    }

    /// The inputs the other stations' device settings name, for `sharedInputNote`. A read that
    /// fails only leaves its station out: the note is advice.
    private func loadOthersInputs() async {
        var result: [(station: String, uid: String, channel: LineInChannel)] = []
        for other in others where other.id != draft.id {
            guard let device = try? await settings.deviceSettings(for: other.id),
                  let uid = device.audioInputDevice else { continue }
            result.append((other.name, uid, device.audioInputChannel ?? .both))
        }
        othersInputs = result
    }

    // MARK: USB

    /// Lists the Uniden ports again (`ports`; nothing is opened). The editor calls it about once a
    /// second while it shows a USB station.
    public func refreshPorts() {
        foundPorts = ports.unidenPorts()
        audioInputs = audioInputListing.inputs()
        reconcileFallback()
    }

    /// The present input standing in for the saved one (line-in design §5.1, as the runner does):
    /// when no present input has the saved UID but exactly one has the saved name. The saved UID
    /// stays as it was until the user edits the input.
    private var savedInputFallback: AudioInputDevice? {
        guard let uid = loadedInput.uid, let name = loadedInput.name,
              !audioInputs.contains(where: { $0.uid == uid }) else { return nil }
        let named = audioInputs.filter { $0.name == name }
        return named.count == 1 ? named[0] : nil
    }

    /// Keeps `audioInput` on the stand-in while the user hasn't chosen otherwise, and back on the
    /// saved UID when the stand-in goes away.
    private func reconcileFallback() {
        let stand = savedInputFallback
        if let applied = fallbackApplied, audioInput == applied, stand?.uid != applied {
            audioInput = loadedInput.uid
            fallbackApplied = nil
        }
        if let stand, audioInput == loadedInput.uid {
            audioInput = stand.uid
            fallbackApplied = stand.uid
        }
    }

    // MARK: Audio input

    /// The audio popup's rows: None, each input present, then the saved input when it isn't
    /// present (named as it was when chosen).
    public var audioInputOptions: [(uid: String?, title: String)] {
        var rows: [(uid: String?, title: String)] = [(nil, "None (no audio)")]
        rows += audioInputs.map { (uid: $0.uid, title: $0.name) }
        if let saved = loadedInput.uid, !audioInputs.contains(where: { $0.uid == saved }),
           savedInputFallback == nil {
            rows.append((saved, "\(loadedInput.name ?? saved) (not connected)"))
        }
        return rows
    }

    /// The input the draft names, with the name to show: the listed device's, else the saved one's.
    public var lineInConfig: LineInConfig? {
        guard let uid = audioInput else { return nil }
        return LineInConfig(deviceUID: uid, deviceName: currentInputName ?? uid, channel: audioInputChannel)
    }

    private var currentInputName: String? {
        guard let uid = audioInput else { return nil }
        if let device = audioInputs.first(where: { $0.uid == uid }) { return device.name }
        return uid == loadedInput.uid ? loadedInput.name : nil
    }

    /// `<station> also uses this input (<channel>).` when another station's saved input is this
    /// one on a channel that overlaps (Both overlaps every channel). With several, the first by
    /// name.
    public var sharedInputNote: String? {
        guard let uid = audioInput else { return nil }
        let mine = audioInputChannel
        let sharing = othersInputs.filter {
            $0.uid == uid && ($0.channel == mine || $0.channel == .both || mine == .both)
        }
        guard let other = sharing.min(by: { $0.station.localizedStandardCompare($1.station) == .orderedAscending })
        else { return nil }
        return "\(other.station) also uses this input (\(other.channel.title))."
    }

    /// The three device-settings keys of an input, as they are stored: no device means no name and
    /// no channel, and a stored device with no channel reads as Both.
    private struct InputKeys: Equatable {
        var uid: String?
        var name: String?
        var channel: LineInChannel?
        init() {}
        init(_ device: StationDeviceSettings) {
            uid = device.audioInputDevice
            name = device.audioInputName
            channel = device.audioInputDevice == nil ? nil : (device.audioInputChannel ?? .both)
        }
    }

    /// What a USB station's port comes to.
    public enum USBStatus: Equatable, Sendable {
        /// The port it would open: a listed one, or the saved path (described by the listing if
        /// listed there, else by its path alone).
        case found(SerialPortInfo)
        /// The saved port isn't there; no listed port is used in its place.
        case savedPortMissing(String)
        /// Nothing saved and no port listed.
        case noneFound
        /// Nothing saved and several ports listed: the user picks one.
        case choose([SerialPortInfo])
    }

    /// `SerialPort.resolve` on `usbPort` and the ports `refreshPorts()` last listed (a saved path
    /// is looked for with a `stat`, never opened).
    public var usbStatus: USBStatus {
        let saved = Self.trimmedPort(usbPort)
        switch SerialPort.resolve(configured: saved, ports: foundPorts,
                                  exists: { FileManager.default.fileExists(atPath: $0) }) {
        case .found(let path, let info):
            return .found(info ?? SerialPortInfo(path: path, productName: nil, vendorID: 0, productID: 0,
                                                 serialNumber: nil))
        case .noneFound:
            return saved.map(USBStatus.savedPortMissing) ?? .noneFound
        case .severalFound(let list):
            return .choose(list)
        }
    }

    private static func trimmedPort(_ port: String?) -> String? {
        guard let port, !port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return port
    }

    /// `Station.validate()`'s problems, then a duplicate name (case-insensitive, ignoring this
    /// station) against the stations `load()` last read.
    public var issues: [String] { issues(against: others) }

    private func issues(against stations: [Station]) -> [String] {
        var result = draft.validate().map(\.message)
        if let other = Station.firstNamed(draft.name, in: stations, excluding: draft.id) {
            result.append(Station.duplicateNameMessage(existingName: other.name))
        }
        return result
    }

    /// Chords assigned to more than one key, for the model in force (override, else detected, else SDS200).
    public var keyConflicts: [KeyChord: [FrontPanelKey]] {
        let model = draft.connection.modelOverride ?? detectedModel ?? .sds200
        return KeyboardRouter(map: draft.keyMap.resolved(for: model)).conflicts
    }

    public func testConnection() async -> ConnectionTest {
        switch draft.connection.transport {
        case .network: return await testNetworkConnection()
        case .usbSerial: return await testUSBConnection()
        case .bluetooth: return .failed(StationSession.notSupportedHereMessage)
        }
    }

    private func testNetworkConnection() async -> ConnectionTest {
        let host = (draft.connection.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return .failed(StationSession.noAddressMessage(stationName: draft.name)) }
        let port = draft.connection.udpPort
        let client = ScannerClient(transport: makeTransport(host, port), commandTimeout: commandTimeout)
        let result: ConnectionTest
        var model: ScannerModel?
        do {
            try await client.connect()
            let info = try await client.modelInfo()
            let firmware = try await client.firmwareVersion()
            model = info.model
            result = .ok(model: info.reported, firmware: firmware)
        } catch ScannerClientError.timeout {
            result = .noAnswer(StationSession.noAnswerMessage(host: host, port: port))
        } catch ScannerClientError.rejected(let command, _) {
            result = .failed("The scanner refused \(command).")
        } catch ScannerClientError.unexpectedResponse(let command) {
            result = .failed("The scanner answered but didn't understand \(command).")
        } catch {
            result = .failed("Couldn't talk to the scanner: \(error.localizedDescription)")
        }
        await client.disconnect()
        detectedModel = model
        return result
    }

    /// Saves the draft. Re-reads the stored stations first (so a missing `load()` or another window
    /// can't let a duplicate through) and throws if they can't be read. Throws
    /// `StationValidationError` while the draft has problems.
    ///
    /// A new station (the editor was opened with none) is saved whole. An existing one gets only the
    /// editor's fields (name, connection, recording, key map, appearance) that the draft changed
    /// since the editor opened, through `SettingsStore.update`, so a view choice, saved filter,
    /// counts reset, or a Settings change (key map, color mode, recording rules) made elsewhere
    /// meanwhile is kept. Returns the station as stored. Throws `StationNoLongerExists` if the
    /// station was deleted while being edited.
    ///
    /// A USB station's port and audio input are written before the station, to its device settings,
    /// when `usbPort` or the input differ from what was loaded (the other device fields are kept);
    /// `savedPortChanged` and `lineInChanged` then say whether the stored port or one of the input's
    /// three keys changed (counting a change written by an earlier save whose station write
    /// failed). A station that isn't USB gets its input cleared, and its port left as it was.
    /// Switching between Network and USB is a connection
    /// change like any other (an open session restarts); the host, ports and reconnect wait stay as
    /// they were.
    public func save() async throws -> Station {
        savedPortChanged = false
        lineInChanged = false
        let current = try await settings.stations()
        others = current
        loadError = nil
        let problems = issues(against: current)
        guard problems.isEmpty else { throw StationValidationError(issues: problems) }
        // The port and the input first, as `noctule station add` does: a station write that then
        // fails leaves at most a stray port, never a USB station stored without its port (Automatic).
        try await saveDeviceFields(for: draft.id)
        let saved: Station
        if isNew {
            try await settings.save(draft)
            saved = draft
        } else {
            let edited = draft
            let original = original
            guard let updated = try await settings.update(id: edited.id, { station in
                if edited.name != original.name { station.name = edited.name }
                if edited.connection != original.connection { station.connection = edited.connection }
                if edited.recording != original.recording { station.recording = edited.recording }
                if edited.keyMap != original.keyMap { station.keyMap = edited.keyMap }
                if edited.appearance != original.appearance { station.appearance = edited.appearance }
            }) else { throw StationNoLongerExists(id: edited.id) }
            saved = updated
        }
        savedPortChanged = portChangePending
        portChangePending = false
        lineInChanged = inputChangePending
        inputChangePending = false
        return saved
    }

    /// Writes the port and the audio input to the station's device settings when they differ from
    /// what was loaded (read-modify-write: the other device fields, such as the recordings folder,
    /// are kept). Only a USB station has either; any other station's input is cleared.
    private func saveDeviceFields(for id: UUID) async throws {
        let isUSB = draft.connection.transport == .usbSerial
        let port = isUSB ? Self.trimmedPort(usbPort) : loadedUSBPort
        var input = InputKeys()
        if isUSB, let uid = audioInput {
            if uid == fallbackApplied {
                // The stand-in for the saved input: the saved UID and name stay.
                input = loadedInput
            } else {
                input.uid = uid
                input.name = currentInputName
            }
            input.channel = audioInputChannel
        }
        let portDiffers = port != loadedUSBPort
        let inputDiffers = input != loadedInput
        guard portDiffers || inputDiffers else { return }
        var device = try await settings.deviceSettings(for: id)
        let storedInput = InputKeys(device)
        let portChanged = device.usbPort != port
        var inputChanged = false
        device.usbPort = port
        if inputDiffers {
            inputChanged = storedInput != input
            device.audioInputDevice = input.uid
            device.audioInputName = input.name
            device.audioInputChannel = input.channel
        }
        try await settings.saveDeviceSettings(device)
        loadedUSBPort = port
        if input.uid != loadedInput.uid { fallbackApplied = nil }
        loadedInput = input
        reconcileFallback()
        if portChanged { portChangePending = true }
        if inputChanged { inputChangePending = true }
    }

    // MARK: Test Connection over USB

    /// The station's port as `usbStatus` resolves it; nothing found, or the station's own window
    /// holding the port, fails with nothing opened. Then `MDL` and `VER` on a fresh client over
    /// the serial transport, always disconnected.
    private func testUSBConnection() async -> ConnectionTest {
        let path: String
        switch usbStatus {
        case .found(let info): path = info.path
        case let status: return .failed(StationText.usbStatusText(status))
        }
        guard !isOpenElsewhere(draft.id) else {
            return .failed("Disconnect \(draft.name) first: its window is using the scanner.")
        }
        guard let transport = makeSerialTransport(path) else { return .failed(StationSession.notSupportedHereMessage) }
        let client = ScannerClient(transport: transport, commandTimeout: commandTimeout)
        let result: ConnectionTest
        var model: ScannerModel?
        do {
            try await client.connect()
            let info = try await client.modelInfo()
            let firmware = try await client.firmwareVersion()
            model = info.model
            result = .ok(model: info.reported, firmware: firmware)
        } catch ScannerClientError.timeout {
            result = .noAnswer(StationSession.noAnswerUSBMessage(port: path))
        } catch ScannerClientError.rejected(let command, _) {
            result = .failed("The scanner refused \(command).")
        } catch ScannerClientError.unexpectedResponse(let command) {
            result = .failed("The scanner answered but didn't understand \(command).")
        } catch {
            result = .failed(Self.serialFailure(error, path: path))
        }
        await client.disconnect()
        detectedModel = model
        return result
    }

    /// The words for a serial open or I/O failure: a busy port as the session says it, a port gone
    /// since it was resolved as the none-found hint.
    private static func serialFailure(_ error: any Error, path: String) -> String {
        #if os(macOS)
        switch error as? SerialTransportError {
        case .busy(let busy): return StationSession.busyPortMessage(busy)
        case .noSuchPort: return SerialPort.noneFoundHint
        default: break
        }
        #endif
        return "Couldn't talk to the scanner: \(error.localizedDescription)"
    }
}

extension LineInChannel {
    /// The channel as the editor and its note name it.
    public var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .both: "Both"
        }
    }
}
