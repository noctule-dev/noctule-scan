// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI

/// Add or edit a station (a sheet over the picker): name, connection type (Network or USB;
/// Bluetooth shown but not supported yet), the scanner model (detected, or overridden), and Test
/// Connection (`MDL` and `VER` only, on a fresh client) with its result inline. Problems show under
/// the form and keep Save disabled.
///
/// A network station has its host, UDP and RTSP ports, and the reconnect wait after a clean
/// disconnect (0…120 s; saving it never restarts an open session). A USB station (SDS150 design
/// §7.1) has a Scanner row instead, saying which port it would open or what to do, refreshed once
/// a second from the registry's port listing (opened by nothing), and a Port picker (Automatic, or
/// one port) only when several ports are found or a port is saved (`EditorRows`).
///
/// A USB station also has an Audio section (line-in design §6.1): its input (None, the Mac's
/// inputs from the registry's listing, read with the ports, and a saved one that isn't there as
/// `<name> (not connected)`), the Channel, a live Line-in level meter (`registry.previewLevels`,
/// started by a `.task` and cancelled when the sheet or the input goes), the note on setting the
/// level, and the note when another station uses the same input.
///
/// Save goes through `StationEditorModel.save()` (a USB station's port in its device settings,
/// then only the station fields this sheet changed) and then `StationDirectory.reloadAndApply()`: an open
/// window on the station follows a rename at once, and a rename or connection change (other than
/// the reconnect wait alone) restarts its session through the cooldown gate. A changed saved port
/// then goes to `SessionRegistry.deviceSettingsChanged`, which replaces an open session, and a
/// changed input to `SessionRegistry.lineInChanged`, which swaps an open session's line-in and
/// keeps its scanner session (both after the save: each start reads the device settings).
struct StationEditorView: View {
    let directory: StationDirectory
    let registry: SessionRegistry
    /// Called with the saved station, or nil on Cancel.
    let done: (Station?) -> Void
    private let isNew: Bool

    @State private var model: StationEditorModel
    @State private var udpText: String
    @State private var rtspText: String
    @State private var testing = false
    @State private var testResult: ConnectionTest?
    @State private var saving = false
    @State private var saveProblem: String?
    /// Problems show once the user has edited something or tried to save (a new station's empty
    /// name isn't an error yet); an existing station shows them at once.
    @State private var showProblems: Bool
    /// The Audio section's meter.
    @State private var meter = LineInMeterState()

    init(station: Station?, settings: any SettingsStore, directory: StationDirectory, registry: SessionRegistry,
         done: @escaping (Station?) -> Void) {
        let model = StationEditorModel(station: station, settings: settings, ports: registry.serialPorts,
                                       audioInputs: registry.audioInputs,
                                       isOpenElsewhere: { [registry] id in registry.session(for: id) != nil })
        if station == nil { model.draft.name = "" }
        _model = State(initialValue: model)
        _udpText = State(initialValue: String(model.draft.connection.udpPort))
        _rtspText = State(initialValue: String(model.draft.connection.rtspPort))
        self.isNew = station == nil
        _showProblems = State(initialValue: station != nil)
        self.directory = directory
        self.registry = registry
        self.done = done
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Station" : "Edit Station")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Name", text: $model.draft.name, prompt: Text("Home Scanner"))
                }
                Section {
                    Picker("Connection", selection: $model.draft.connection.transport) {
                        Text("Network").tag(TransportKind.network)
                        Text("USB").tag(TransportKind.usbSerial)
                        Text("Bluetooth — not supported yet").tag(TransportKind.bluetooth).disabled(true)
                    }
                    if rows.contains(.address) {
                        TextField("Address", text: hostBinding, prompt: Text("IP address or host name"))
                    }
                    if rows.contains(.controlPort) {
                        TextField("Control port (UDP)", text: $udpText)
                            .onChange(of: udpText) { _, text in
                                if let port = StationText.port(text) { model.draft.connection.udpPort = port }
                                testResult = nil
                            }
                    }
                    if rows.contains(.audioPort) {
                        TextField("Audio port (RTSP)", text: $rtspText)
                            .onChange(of: rtspText) { _, text in
                                if let port = StationText.port(text) { model.draft.connection.rtspPort = port }
                            }
                    }
                    if rows.contains(.reconnectWait) {
                        LabeledContent("Reconnect wait") {
                            HStack(spacing: 6) {
                                TextField("Reconnect wait", value: $model.draft.connection.reconnectCooldownSeconds,
                                          format: .number)
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 48)
                                Text("s").foregroundStyle(.secondary)
                                Stepper("Reconnect wait", value: $model.draft.connection.reconnectCooldownSeconds,
                                        in: StationConnection.reconnectCooldownRange)
                                    .labelsHidden()
                            }
                        }
                    }
                    if rows.contains(.scanner) {
                        LabeledContent("Scanner") {
                            Text(StationText.usbStatusText(model.usbStatus))
                                .foregroundStyle(usbPortResolves ? .primary : .secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if rows.contains(.port) {
                        Picker("Port", selection: $model.usbPort) {
                            Text("Automatic").tag(String?.none)
                            ForEach(EditorRows.portChoices(found: model.foundPorts, saved: model.usbPort), id: \.path) { choice in
                                Text(choice.label).tag(Optional(choice.path))
                            }
                        }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    if rows.contains(.reconnectWait) {
                        Text(EditorText.reconnectWaitFootnote)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.draft.connection.transport == .usbSerial {
                    audioSection
                }
                Section {
                    Picker("Scanner model", selection: $model.draft.connection.modelOverride) {
                        Text("Detect automatically").tag(ScannerModel?.none)
                        Divider()
                        ForEach(ScannerModel.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(Optional(m))
                        }
                    }
                    LabeledContent("Detected") {
                        if let detected = model.detectedModel {
                            Label(detected.rawValue, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Test the connection to detect the model").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if let override = model.draft.connection.modelOverride, let detected = model.detectedModel,
                       override != detected {
                        Text("The scanner reports \(detected.rawValue); Noctule Scan will treat it as \(override.rawValue).")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button("Test Connection") { test() }
                            .disabled(testing || !canTest)
                        if testing {
                            ProgressView().controlSize(.small)
                            Text("Asking the scanner…").foregroundStyle(.secondary)
                        } else if let testResult {
                            ConnectionTestResultView(result: testResult)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if (showProblems && !problems.isEmpty) || saveProblem != nil {
                    Section {
                        ForEach(showProblems ? problems : [], id: \.self) { problem in
                            Label(EditorText.sentence(problem), systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red)
                        }
                        if let saveProblem {
                            Label(saveProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Station" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((showProblems && !problems.isEmpty) || saving)
            }
            .padding(16)
        }
        // A fixed height that fits inside the picker's default size; the form scrolls if needed.
        .frame(width: 500, height: EditorText.sheetHeight)
        .task { await model.load() }
        // While USB shows: list the ports once a second (nothing is opened), so the Scanner row
        // follows a cable plugged in or pulled out.
        .task(id: model.draft.connection.transport) {
            guard model.draft.connection.transport == .usbSerial else { return }
            while !Task.isCancelled {
                model.refreshPorts()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // The Audio section's meter, for the input and channel chosen: the open session's readings
        // when it runs that input, else a short-lived capture of the editor's own; cancelled when
        // the choice changes or the sheet closes.
        .task(id: previewConfig) {
            meter = LineInMeterState()
            guard let config = previewConfig else { return }
            let preview = registry.previewLevels(stationID: model.draft.id, config: config)
            defer { preview.cancel() }
            for await level in preview.levels {
                meter.take(level)
            }
        }
        .onChange(of: model.draft.connection.transport) { _, _ in testResult = nil }
        .onChange(of: model.usbPort) { _, _ in testResult = nil }
        .onChange(of: model.draft) { _, _ in showProblems = true }
        .onChange(of: udpText) { _, _ in showProblems = true }
        .onChange(of: rtspText) { _, _ in showProblems = true }
    }

    /// A USB station's Audio section (line-in design §6.1).
    private var audioSection: some View {
        Section {
            Picker("Audio input", selection: $model.audioInput) {
                ForEach(Array(model.audioInputOptions.enumerated()), id: \.offset) { _, option in
                    Text(option.title).tag(option.uid)
                }
            }
            if model.audioInput != nil {
                Picker("Channel", selection: $model.audioInputChannel) {
                    ForEach(LineInChannel.allCases, id: \.self) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Line-in level") {
                    LineInMeterView(level: meter.level, peakHold: meter.peakHold, clipLatched: meter.clipLatched,
                                    clearClip: { meter.clearClip() })
                        .frame(width: 220)
                }
            }
        } header: {
            Text("Audio")
        } footer: {
            if model.audioInput != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(EditorText.lineInNote)
                    if let shared = model.sharedInputNote {
                        Text(shared).foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The input the Audio section's meter reads: a USB station's chosen input, else none.
    private var previewConfig: LineInConfig? {
        model.draft.connection.transport == .usbSerial ? model.lineInConfig : nil
    }

    private var hostBinding: Binding<String> {
        Binding(get: { model.draft.connection.host ?? "" }, set: { text in
            model.draft.connection.host = text.isEmpty ? nil : text
            testResult = nil
        })
    }

    private var hostIsEmpty: Bool {
        (model.draft.connection.host ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The Connection rows for the transport chosen.
    private var rows: [EditorRow] {
        EditorRows.visible(for: model.draft.connection.transport, portCount: model.foundPorts.count,
                           savedPort: model.usbPort != nil)
    }

    private var usbPortResolves: Bool {
        if case .found = model.usbStatus { return true }
        return false
    }

    /// Test Connection needs a host and control port (network), or a port that resolves (USB).
    private var canTest: Bool {
        switch model.draft.connection.transport {
        case .network: !hostIsEmpty && udpPortProblem == nil
        case .usbSerial: usbPortResolves
        case .bluetooth: false
        }
    }

    private var udpPortProblem: String? {
        StationText.port(udpText) == nil ? EditorText.portProblem("control port") : nil
    }

    private var rtspPortProblem: String? {
        StationText.port(rtspText) == nil ? EditorText.portProblem("audio port") : nil
    }

    /// The model's issues (name, host, duplicate name), then the port fields (a network station's
    /// only: a USB station doesn't show them), then a load error.
    private var problems: [String] {
        let ports = model.draft.connection.transport == .network ? [udpPortProblem, rtspPortProblem] : []
        return model.issues + (ports + [model.loadError]).compactMap { $0 }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            let result = await model.testConnection()
            testResult = result
            testing = false
        }
    }

    private func save() {
        showProblems = true
        guard problems.isEmpty else { return }
        saving = true
        saveProblem = nil
        Task {
            defer { saving = false }
            do {
                let saved = try await model.save()
                await directory.reloadAndApply()
                // After the station's own change: an open session then restarts on the new port.
                if model.savedPortChanged { registry.deviceSettingsChanged(saved.id) }
                // And the input: an open session swaps its line-in, keeping the scanner session.
                if model.lineInChanged {
                    registry.lineInChanged(saved.id, to: saved.connection.transport == .usbSerial ? model.lineInConfig : nil)
                }
                done(saved)
            } catch let error as StationValidationError {
                saveProblem = error.issues.map(EditorText.sentence).joined(separator: " ")
            } catch {
                saveProblem = (error as? SettingsStoreError)?.description
                    ?? (error as? StationNoLongerExists)?.description
                    ?? error.localizedDescription
            }
        }
    }
}

/// The inline result of Test Connection.
struct ConnectionTestResultView: View {
    let result: ConnectionTest

    var body: some View {
        switch result {
        case .ok(let model, let firmware):
            Label(EditorText.testOK(model: model, firmware: firmware), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .noAnswer(let message), .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One of the Connection section's rows.
enum EditorRow: Equatable {
    case address, controlPort, audioPort, reconnectWait
    /// A USB station's port, found or not, in words (`StationText.usbStatusText`).
    case scanner
    /// A USB station's port picker: Automatic, or one port.
    case port
}

/// Which Connection rows show (SDS150 design §7.1).
enum EditorRows {
    /// A network station: address, the two ports and the reconnect wait. A USB station: the Scanner
    /// row, and the Port picker only when there is a choice to make (more than one port found) or
    /// a port is saved (so it can be set back to Automatic). Bluetooth isn't supported: none.
    static func visible(for transport: TransportKind, portCount: Int, savedPort: Bool) -> [EditorRow] {
        switch transport {
        case .network: [.address, .controlPort, .audioPort, .reconnectWait]
        case .usbSerial: portCount > 1 || savedPort ? [.scanner, .port] : [.scanner]
        case .bluetooth: []
        }
    }

    /// One port the Port picker offers.
    struct PortChoice: Equatable {
        var path: String
        var label: String
    }

    /// The found ports, each as `usbStatusText(.found)`; then a saved port that isn't among them
    /// (a link, or a port not plugged in), so the picker can show what is saved.
    static func portChoices(found: [SerialPortInfo], saved: String?) -> [PortChoice] {
        var choices = found.map { PortChoice(path: $0.path, label: StationText.usbStatusText(.found($0))) }
        if let saved, !found.contains(where: { $0.path == saved }) {
            choices.append(PortChoice(path: saved, label: "\(saved) (saved)"))
        }
        return choices
    }
}

enum EditorText {
    /// The editor sheet's height; the picker's default height leaves room for it.
    static let sheetHeight: CGFloat = 560
    static func testOK(model: String, firmware: String) -> String {
        "Connected: \(model), firmware \(firmware)"
    }

    /// Under the Audio section's input (line-in design §6.1).
    static let lineInNote = "Connect the scanner's headphone jack to this input. Set the level in the station "
        + "window with the scanner's volume: during a transmission the peaks should sit in the marked band "
        + "and CLIP should never light."

    /// Under the connection section's Reconnect wait (Plan 5: the owner's setting).
    static let reconnectWaitFootnote = "The reconnect wait applies after a clean disconnect. Crashes and dropped "
        + "connections always wait 120 s. Below 120 s, the SDS200 may need a power cycle if its audio server hangs."

    static func portProblem(_ name: String) -> String {
        "the \(name) must be a number from 1 to 65535"
    }

    /// The model's lower-case fragments as sentences: "the station needs a name" → "The station needs a name."
    static func sentence(_ fragment: String) -> String {
        guard let first = fragment.first else { return fragment }
        let body = first.uppercased() + fragment.dropFirst()
        return body.hasSuffix(".") ? body : body + "."
    }
}
#endif
