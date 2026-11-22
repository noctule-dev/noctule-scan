// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (⌘,): General (where settings live; export and import) and Stations (one
/// station's recording rules, recordings folder, display color mode and key map).
struct SettingsView: View {
    let directory: StationDirectory
    let settings: any SettingsStore
    let registry: SessionRegistry
    let recordingsRoot: URL
    let updates: UpdateChecker
    @State private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettingsTab(directory: directory, settings: settings, updates: updates)
            }
            Tab("Stations", systemImage: "antenna.radiowaves.left.and.right", value: "stations") {
                StationsSettingsTab(directory: directory, settings: settings, registry: registry,
                                    recordingsRoot: recordingsRoot)
            }
        }
        .task { await directory.reload() }
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    let directory: StationDirectory
    let updates: UpdateChecker
    @State private var model: AppSettingsModel
    @State private var pendingImport: PendingImport?
    @State private var message: SettingsMessage?

    init(directory: StationDirectory, settings: any SettingsStore, updates: UpdateChecker) {
        self.directory = directory
        self.updates = updates
        _model = State(initialValue: AppSettingsModel(settings: settings))
    }

    var body: some View {
        Form {
            Section {
                Picker("Keep settings", selection: .constant(StorageLocation.local)) {
                    ForEach(model.locations, id: \.location) { location in
                        Text(GeneralText.title(location)).tag(location.location).disabled(!location.available)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Storage")
            } footer: {
                Text("Stations, their settings and key maps. Hit logs and recordings always stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Back up or move to another Mac") {
                    HStack {
                        Button("Export Settings…") { export() }
                        Button("Import Settings…") { chooseImport() }
                    }
                }
            } header: {
                Text("Export and Import")
            } footer: {
                Text("The file holds every station and its settings, but not hit logs, recordings or this Mac's recordings folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(UpdateText.automaticToggle, isOn: Binding(
                    get: { updates.checksAutomatically },
                    set: { on in Task { await updates.setChecksAutomatically(on) } }))
                LabeledContent(UpdateText.lastChecked(updates.lastChecked, now: .now)) {
                    Button("Check Now") { Task { await updates.checkNow() } }
                        .disabled(updates.isChecking)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(UpdateText.settingsFooter)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 560)
        .sheet(item: $pendingImport) { pending in
            ImportOptionsSheet(pending: pending) { replace in
                pendingImport = nil
                if let replace { runImport(pending.data, replaceExisting: replace) }
            }
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
               presenting: message) { _ in
            Button("OK") { message = nil }
        } message: { message in
            Text(message.body)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = GeneralText.exportFileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await model.exportSettings()
                try data.write(to: url, options: .atomic)
            } catch {
                message = SettingsMessage(title: "Couldn't export the settings", body: GeneralText.describe(error))
            }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingImport = PendingImport(fileName: url.lastPathComponent, data: try Data(contentsOf: url))
        } catch {
            message = SettingsMessage(title: "Couldn't read the file", body: error.localizedDescription)
        }
    }

    private func runImport(_ data: Data, replaceExisting: Bool) {
        Task {
            do {
                let count = try await model.importSettings(data, replaceExisting: replaceExisting)
                await directory.reloadAndApply()
                message = SettingsMessage(title: StationText.importSummary(count), body: "")
            } catch is DecodingError {
                message = SettingsMessage(title: "Couldn't import the settings", body: GeneralText.notAnExport)
            } catch {
                await directory.reloadAndApply()
                message = SettingsMessage(title: "Couldn't import the settings", body: GeneralText.describe(error))
            }
        }
    }
}

struct PendingImport: Identifiable {
    let id = UUID()
    let fileName: String
    let data: Data
}

struct SettingsMessage {
    let title: String
    let body: String
}

/// Asks whether stations with the same id replace the ones here; nil is Cancel.
private struct ImportOptionsSheet: View {
    let pending: PendingImport
    let done: (Bool?) -> Void
    @State private var replace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Settings from “\(pending.fileName)”").font(.headline)
            Toggle("Replace existing stations with the same id", isOn: $replace)
            Text(replace ? GeneralText.replaceOn : GeneralText.replaceOff)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Import") { done(replace) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

enum GeneralText {
    static let exportFileName = "Noctule Scan Settings.json"
    static let notAnExport = "That file isn't a Noctule Scan settings export."
    static let replaceOff = "A station that's already here is imported as a copy, so nothing here is overwritten."
    static let replaceOn = "A station that's already here is replaced by the one in the file. An open window on it reconnects."

    /// "On this Mac", or "iCloud — requires an Apple Developer Program membership".
    static func title(_ location: StorageLocationAvailability) -> String {
        let name = switch location.location {
        case .local: "On this Mac"
        case .iCloud: "iCloud"
        }
        guard !location.available, let reason = location.reason else { return name }
        return "\(name) — \(reason)"
    }

    static func describe(_ error: any Error) -> String {
        (error as? SettingsStoreError)?.description ?? error.localizedDescription
    }
}

// MARK: - Stations

struct StationsSettingsTab: View {
    let directory: StationDirectory
    let settings: any SettingsStore
    let registry: SessionRegistry
    let recordingsRoot: URL
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            List(directory.stations, id: \.id, selection: $selection) { station in
                Text(station.name)
            }
            .frame(width: 200)
            Divider()
            Group {
                if let station = directory.stations.first(where: { $0.id == selection }) {
                    StationSettingsPane(station: station, directory: directory, settings: settings,
                                        registry: registry, recordingsRoot: recordingsRoot)
                        .id(station.id)
                } else {
                    ContentUnavailableView(directory.stations.isEmpty ? "No Stations" : "No Station Selected",
                                           systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text(directory.stations.isEmpty
                                                             ? "Add a station in the Stations window (⌘O)."
                                                             : "Choose a station on the left."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 820, height: 640)
        .onAppear { pickDefault() }
        .onChange(of: directory.stations.map(\.id)) { _, _ in pickDefault() }
    }

    private func pickDefault() {
        guard selection == nil || !directory.stations.contains(where: { $0.id == selection }) else { return }
        selection = directory.stations.first { $0.id == directory.lastStationID }?.id ?? directory.stations.first?.id
    }
}

struct StationSettingsPane: View {
    let directory: StationDirectory
    let registry: SessionRegistry
    let recordingsRoot: URL
    @State private var model: StationSettingsModel
    @State private var minimumText: String
    @State private var daysText: String
    @FocusState private var focus: Field?

    private enum Field { case minimum, days }

    init(station: Station, directory: StationDirectory, settings: any SettingsStore, registry: SessionRegistry,
         recordingsRoot: URL) {
        self.directory = directory
        self.registry = registry
        self.recordingsRoot = recordingsRoot
        _model = State(initialValue: StationSettingsModel(station: station, settings: settings) { [directory] saved in
            directory.changed(saved)
        })
        _minimumText = State(initialValue: RecordingInput.format(seconds: station.recording.minimumDuration))
        _daysText = State(initialValue: String(station.recording.retentionDays ?? 30))
    }

    private var station: Station { model.station }
    private var session: StationSession? { registry.session(for: station.id) }

    /// The connected scanner's model, else the override, else SDS200: the defaults the key map shows.
    private var keyModel: ScannerModel { session?.model ?? station.connection.modelOverride ?? .sds200 }

    var body: some View {
        Form {
            if let problem = model.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            recordingSection
            Section {
                Picker("Display colors", selection: Binding(get: { station.appearance.colorMode },
                                                           set: { mode in Task { await model.setColorMode(mode) } })) {
                    Text("Color").tag(ColorMode.color)
                    Text("Black on White").tag(ColorMode.blackOnWhite)
                    Text("White on Black").tag(ColorMode.whiteOnBlack)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Display")
            } footer: {
                Text("Applies at once, without reconnecting.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                KeyMapEditor(rows: KeyMapEditing.rows(for: station.keyMap, model: keyModel),
                             set: { key, chord in Task { await model.setChord(chord, for: key, model: keyModel) } },
                             reset: { Task { await model.resetKeyMap() } })
            } header: {
                Text("Keyboard (\(keyModel.rawValue) defaults)")
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .onChange(of: directory.stations) { _, stations in
            if let fresh = stations.first(where: { $0.id == model.station.id }) { model.adopt(fresh) }
        }
        .onChange(of: focus) { old, _ in
            if old == .minimum { commitMinimum() }
            if old == .days { commitDays() }
        }
    }

    @ViewBuilder private var recordingSection: some View {
        Section {
            Picker("Save audio", selection: Binding(get: { station.recording.saveAudio },
                                                    set: { value in Task { await model.setSaveAudio(value) } })) {
                Text("Every transmission").tag(SaveAudio.everyTransmission)
                Text("Only new talkgroups and channels").tag(SaveAudio.onlyNew)
                Text("Never").tag(SaveAudio.never)
            }
            LabeledContent("Skip transmissions shorter than") {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        TextField("", text: $minimumText)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            .focused($focus, equals: .minimum)
                            .onSubmit(commitMinimum)
                        Text("s")
                    }
                    if RecordingInput.minimumLength(minimumText) == nil {
                        Text(RecordingInput.minimumLengthProblem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Picker("Keep recordings", selection: Binding(get: { station.recording.retentionDays == nil },
                                                         set: { forever in setForever(forever) })) {
                Text("Forever").tag(true)
                Text("For a number of days").tag(false)
            }
            if station.recording.retentionDays != nil {
                LabeledContent("Delete hits and recordings older than") {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            TextField("", text: $daysText)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                                .focused($focus, equals: .days)
                                .onSubmit(commitDays)
                            Text("days")
                        }
                        if RecordingInput.retentionDays(daysText) == nil {
                            Text(RecordingInput.retentionProblem).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            LabeledContent("Recordings folder") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(RecordingsFolderText.display(custom: model.device.recordingsFolder, root: recordingsRoot,
                                                      stationName: station.name))
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help(RecordingsFolderText.path(custom: model.device.recordingsFolder, root: recordingsRoot,
                                                        stationName: station.name))
                    HStack {
                        if model.device.recordingsFolder != nil {
                            Button("Use Default") { Task { await model.setRecordingsFolder(nil) } }
                        }
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }
            LabeledContent("Format", value: RecordingsFolderText.format)
        } header: {
            Text("Recording")
        } footer: {
            Text(RecordingsFolderText.footer(stationName: station.name, isOpen: session != nil))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commitMinimum() {
        guard let value = RecordingInput.minimumLength(minimumText) else { return }
        minimumText = RecordingInput.format(seconds: value)
        guard value != station.recording.minimumDuration else { return }
        Task { await model.setMinimumDuration(value) }
    }

    private func commitDays() {
        guard let days = RecordingInput.retentionDays(daysText) else { return }
        daysText = String(days)
        guard days != station.recording.retentionDays else { return }
        Task { await model.setRetentionDays(days) }
    }

    private func setForever(_ forever: Bool) {
        if forever {
            guard station.recording.retentionDays != nil else { return }
            Task { await model.setRetentionDays(nil) }
        } else {
            guard station.recording.retentionDays == nil else { return }
            let days = RecordingInput.retentionDays(daysText) ?? 30
            daysText = String(days)
            Task { await model.setRetentionDays(days) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where \(station.name)'s recordings go."
        panel.directoryURL = URL(fileURLWithPath: RecordingsFolderText.path(custom: model.device.recordingsFolder,
                                                                           root: recordingsRoot, stationName: station.name))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setRecordingsFolder(url.path) }
    }
}

/// The recordings folder and recording notes as Settings shows them.
enum RecordingsFolderText {
    static let format = "WAV, 16-bit, 8 kHz mono"

    /// The folder in use: the custom one, else `<root>/<sanitized station name>`.
    static func path(custom: String?, root: URL, stationName: String) -> String {
        if let custom, !custom.isEmpty { return custom }
        return root.appendingPathComponent(RecordingName.sanitizeFolderName(stationName), isDirectory: true).path
    }

    /// "~/Music/Noctule Scan/Home (default)" or the custom path, home abbreviated to "~".
    static func display(custom: String?, root: URL, stationName: String,
                        home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let full = path(custom: custom, root: root, stationName: stationName)
        let shown = abbreviate(full, home: home)
        return (custom?.isEmpty ?? true) ? "\(shown) (default)" : shown
    }

    static func abbreviate(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func footer(stationName: String, isOpen: Bool) -> String {
        if isOpen {
            return "\(stationName) is open: a change to these rules reconnects it, and audio returns after the scanner's 2-minute reconnect wait. A new folder is used from the next connection."
        }
        return "These apply the next time \(stationName) connects."
    }
}
#endif
