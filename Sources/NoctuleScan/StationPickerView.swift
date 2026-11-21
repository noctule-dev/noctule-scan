// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI

/// The station picker (design §12.1): the stored stations with their address and model, the last
/// one that connected marked; Add and Edit (the station editor in a sheet), Delete (after a
/// confirmation; the hit log and recordings are kept), and Connect (or double-click, or the
/// context menu), which opens the station's window. Every change goes through
/// `StationDirectory`, so open windows and sessions follow.
///
/// After a Connect it closes itself once that station's session reaches `.connected`
/// (`PickerAutoClose`: the latest Connect counts; selecting another station, a sheet or alert, a
/// failed connect, or that station's window closing before it connects keeps it open). It comes back from File › Open Station… (⌘O), the station
/// window's Stations and Disconnect buttons, and when the last station window closes.
///
/// At launch (once, `LaunchRoute`) it opens the last station that connected (`lastStationID`,
/// recorded by `SessionRegistry` on `.connected`) instead, if that station still exists, and
/// closes itself.
struct StationPickerView: View {
    let directory: StationDirectory
    let settings: any SettingsStore
    let registry: SessionRegistry
    let launch: LaunchRoute

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selection: UUID?
    @State private var editing: EditorTarget?
    @State private var confirmingDelete: Station?
    @State private var deleteProblem: String?
    @State private var autoClose = PickerAutoClose()
    /// USB stations' saved ports (`StationDeviceSettings.usbPort`), for their rows.
    @State private var usbPorts: [UUID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            HStack(spacing: 8) {
                ControlGroup {
                    Button { editing = .add } label: { Image(systemName: "plus") }
                        .help("Add a station")
                    Button { confirmingDelete = selectedStation } label: { Image(systemName: "minus") }
                        .help("Delete the selected station")
                        .disabled(selectedStation == nil)
                }
                .fixedSize()
                Button("Edit…") { if let selectedStation { editing = .edit(selectedStation) } }
                    .disabled(selectedStation == nil)
                Spacer()
                Button("Connect") { if let selection { connect(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedStation == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 300)
        .sheet(item: $editing) { target in
            StationEditorView(station: target.station, settings: settings, directory: directory,
                              registry: registry) { saved in
                editing = nil
                if let saved { selection = saved.id }
                Task { await loadUSBPorts() }
            }
        }
        .alert(deleteTitle, isPresented: Binding(get: { confirmingDelete != nil },
                                                 set: { if !$0 { confirmingDelete = nil } }),
               presenting: confirmingDelete) { station in
            Button("Delete", role: .destructive) { delete(station) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(PickerText.deleteMessage)
        }
        .alert("Couldn't delete the station", isPresented: Binding(get: { deleteProblem != nil },
                                                                   set: { if !$0 { deleteProblem = nil } })) {
            Button("OK") { deleteProblem = nil }
        } message: {
            Text(deleteProblem ?? "")
        }
        .task { await load() }
        .task(id: directory.stations) { await loadUSBPorts() }
        .onChange(of: directory.stations.map(\.id)) { _, ids in
            // A station added, deleted or imported: keep a valid selection.
            guard selection == nil || !ids.contains(selection!) else { return }
            selection = ids.first { $0 == directory.lastStationID } ?? ids.first
        }
        .onChange(of: selection) { _, id in autoClose.selectionChanged(id) }
        .onChange(of: awaitedSession) { _, awaited in
            guard let awaited else { return }
            guard editing == nil, confirmingDelete == nil, deleteProblem == nil else {
                autoClose.cancel()
                return
            }
            if autoClose.update(station: awaited.id, phase: awaited.phase) {
                dismissWindow(id: AppScene.picker)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await directory.reload() }
        }
    }

    @ViewBuilder private var content: some View {
        if let problem = directory.problem {
            ContentUnavailableView("Can't Read the Stations", systemImage: "exclamationmark.triangle",
                                   description: Text(problem))
        } else if directory.stations.isEmpty {
            ContentUnavailableView {
                Label("No Stations", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Add a station with your scanner's address on the network or over your VPN.")
            } actions: {
                Button("Add Station…") { editing = .add }
            }
        } else {
            List(directory.stations, id: \.id, selection: $selection) { station in
                StationPickerRow(station: station, usbPort: usbPorts[station.id],
                                 isLast: station.id == directory.lastStationID,
                                 connectedModel: connectedModel(station.id))
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let station = directory.stations.first(where: { $0.id == id }) {
                    Button("Connect") { connect(id) }
                    Button("Edit…") { editing = .edit(station) }
                    Divider()
                    Button("Delete…") { confirmingDelete = station }
                }
            } primaryAction: { ids in
                if let id = ids.first { connect(id) }
            }
        }
    }

    private var selectedStation: Station? {
        directory.stations.first { $0.id == selection }
    }

    private var deleteTitle: String {
        "Delete “\(confirmingDelete?.name ?? "")”?"
    }

    private func connectedModel(_ id: UUID) -> ScannerModel? {
        guard let session = registry.session(for: id), case .connected(let reported, _) = session.phase else { return nil }
        return ScannerModel(reported: reported)
    }

    /// The station a Connect is waiting on, with its session's phase (nil: not open yet).
    private var awaitedSession: AwaitedSession? {
        autoClose.awaiting.map { AwaitedSession(id: $0, phase: registry.session(for: $0)?.phase) }
    }

    /// Reads each USB station's saved port; one that can't be read shows as "USB".
    private func loadUSBPorts() async {
        var ports: [UUID: String] = [:]
        for station in directory.stations where station.connection.transport == .usbSerial {
            if let port = try? await settings.deviceSettings(for: station.id).usbPort { ports[station.id] = port }
        }
        usbPorts = ports
    }

    private func connect(_ id: UUID) {
        selection = id
        autoClose.connectRequested(id)
        openWindow(id: AppScene.station, value: id)
    }

    private func delete(_ station: Station) {
        Task {
            do {
                try await directory.delete(id: station.id)
                if selection == station.id { selection = directory.stations.first?.id }
            } catch {
                deleteProblem = (error as? SettingsStoreError)?.description ?? error.localizedDescription
            }
        }
    }

    private func load() async {
        // Routing is a launch-time decision: claim it even if loading fails, so a later reappearance
        // of the picker never jumps to a station window.
        let routeNow = launch.claim()
        guard await directory.reload() else { return }
        let stations = directory.stations
        if selection == nil {
            selection = stations.first { $0.id == directory.lastStationID }?.id ?? stations.first?.id
        }
        guard routeNow else { return }
        if let last = directory.lastStationID, stations.contains(where: { $0.id == last }) {
            openWindow(id: AppScene.station, value: last)
            dismissWindow(id: AppScene.picker)
        }
    }
}

/// What `PickerAutoClose` watches: the awaited station and its session's phase.
private struct AwaitedSession: Equatable {
    var id: UUID
    var phase: SessionPhase?
}

/// What the editor sheet is open for.
enum EditorTarget: Identifiable {
    case add
    case edit(Station)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let station): station.id.uuidString
        }
    }

    var station: Station? {
        if case .edit(let station) = self { return station }
        return nil
    }
}

enum PickerText {
    static let deleteMessage = "Its settings are removed from Noctule Scan. Its hit log and recordings are kept. If its window is open, the window closes and the connection stops."
    static let lastUsed = "Last used"
}

private struct StationPickerRow: View {
    let station: Station
    let usbPort: String?
    let isLast: Bool
    let connectedModel: ScannerModel?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(station.name).fontWeight(.medium)
                    if isLast {
                        Text(PickerText.lastUsed)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(StationText.address(station, usbPort: usbPort)) · \(StationText.model(station, connected: connectedModel))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
    }
}
#endif
