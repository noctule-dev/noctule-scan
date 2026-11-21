// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import Foundation
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI
import UniformTypeIdentifiers

/// One station's hit log window (`WindowGroup` "hitlog", the value is the station's id).
///
/// It opens its own `HitLog` reader on `<settings>/Stations/<uuid>/hits.sqlite` (SQLite in WAL
/// mode takes concurrent readers; it never takes the station's runner lock), so the log can be
/// browsed while the station is not connected. While the station's session is open, a change to
/// its recent hits reloads the table (`HitLogModel.hitsChanged`, debounced), and the toolbar's
/// Logging toggle is bound to that session. Closing the window stops playback and closes the
/// reader. The scanner's keyboard shortcuts never reach this window: the key monitor acts only on
/// events for its own station window.
struct HitLogWindow: View {
    let stationID: UUID?
    let registry: SessionRegistry
    let settings: any SettingsStore
    let settingsDirectory: URL

    @State private var model: HitLogModel?
    @State private var problem: String?
    @State private var playback = WAVPlayback()

    var body: some View {
        Group {
            if stationID == nil {
                NoStationView()
            } else if let model {
                HitLogContent(model: model, session: stationID.flatMap { registry.session(for: $0) },
                              playback: playback)
            } else if let problem {
                ContentUnavailableView("Can't Open the Hit Log", systemImage: "exclamationmark.triangle",
                                       description: Text(problem))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 820, minHeight: 420)
        .navigationTitle("Hit Log")
        .navigationSubtitle(model?.station.name ?? "")
        .task(id: stationID) { await run() }
    }

    private func run() async {
        guard let stationID else { return }
        let station: Station
        do {
            guard let found = try await settings.stations().first(where: { $0.id == stationID }) else {
                problem = "This station no longer exists."
                return
            }
            station = found
        } catch {
            problem = (error as? SettingsStoreError)?.description ?? error.localizedDescription
            return
        }
        let url = StationSession.hitLogURL(settingsDirectory: settingsDirectory, stationID: stationID)
        let log: HitLog
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            log = try HitLog(url: url)
        } catch {
            problem = "Can't open \(url.path): \(error)"
            return
        }
        let model = HitLogModel(station: station, log: log, settings: settings,
                                trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        await model.reload()
        self.model = model
        // Hold the reader until the window goes away (the task is cancelled then).
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        playback.stop()
        await log.close()
    }
}

/// A sidebar entry: every hit, one day, the built-in "Only new", or a saved filter.
enum HitLogSidebarItem: Hashable {
    case all
    case day(Date)
    case onlyNew
    case saved(UUID)

    /// The filter and session day to show for this entry. The search text in force is kept,
    /// except that a saved filter brings its own.
    func apply(current: HitFilter, saved: [HitFilter]) -> (filter: HitFilter, session: Date?) {
        var base = HitFilter()
        base.text = current.text
        switch self {
        case .all: return (base, nil)
        case .day(let day): return (base, day)
        case .onlyNew:
            base.onlyNew = true
            return (base, nil)
        case .saved(let id):
            guard let filter = saved.first(where: { $0.id == id }) else { return (base, nil) }
            return (filter, nil)
        }
    }
}

/// The window's content once the log is open: sidebar, table, inspector and toolbar.
struct HitLogContent: View {
    @Bindable var model: HitLogModel
    let session: StationSession?
    let playback: WAVPlayback

    @SceneStorage("hitlog.columns.groups") private var groupColumns = TableColumnCustomization<HitRow>()
    @SceneStorage("hitlog.columns.transmissions") private var transmissionColumns = TableColumnCustomization<HitRow>()
    @State private var groupSort = [KeyPathComparator(\HitRow.last, order: .reverse)]
    @State private var transmissionSort = [KeyPathComparator(\HitRow.first, order: .reverse)]
    @State private var sidebar: HitLogSidebarItem? = .all
    @State private var showInspector = true
    @State private var pendingDelete: Set<String>?
    @State private var confirmReset = false
    @State private var namingFilter = false
    @State private var filterName = ""
    @State private var alert: (title: String, message: String)?

    private var sortOrder: Binding<[KeyPathComparator<HitRow>]> {
        model.layout == .groups ? $groupSort : $transmissionSort
    }

    private var rows: [HitRow] {
        HitRow.rows(model).sorted(using: model.layout == .groups ? groupSort : transmissionSort)
    }

    var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 280)
        } detail: {
            table
                .inspector(isPresented: $showInspector) {
                    HitInspector(model: model, playback: playback, showInFinder: { showInFinder(model.selection) })
                        .inspectorColumnWidth(min: 240, ideal: 250, max: 420)
                }
        }
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search TG, frequency, name")
        .onChange(of: session?.recentHits) { model.hitsChanged() }
        // A rename (or filter, or counts reset) saved in another window: the session is replaced
        // with the new station value, and any window becoming key re-reads the store.
        .onChange(of: session?.station) { Task { await model.refreshStation() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.refreshStation() }
        }
        .onChange(of: sidebar) { _, item in apply(item ?? .all) }
        .confirmationDialog(HitLogText.deleteConfirmation(rows: pendingDelete?.count ?? 0),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let rows = pendingDelete { delete(rows) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .confirmationDialog("Reset hit counts?", isPresented: $confirmReset) {
            Button("Reset Counts", role: .destructive) { resetCounts() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hits and talk time count again from now. Transmissions and recordings are kept.")
        }
        .alert("Save Filter", isPresented: $namingFilter) {
            TextField("Name", text: $filterName)
            Button("Save") { saveFilter() }
                .disabled(filterName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current filter and search under this name.")
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK") { alert = nil }
        } message: {
            Text(alert?.message ?? "")
        }
    }

    // MARK: Sidebar

    private var sidebarList: some View {
        List(selection: $sidebar) {
            Section("Sessions") {
                Label("All", systemImage: "tray.full").tag(HitLogSidebarItem.all)
                ForEach(model.sessions, id: \.day) { session in
                    Label(HitLogText.session(session.day), systemImage: "calendar")
                        .badge(session.count)
                        .tag(HitLogSidebarItem.day(session.day))
                }
            }
            Section("Filters") {
                Label("Only New", systemImage: "sparkles").tag(HitLogSidebarItem.onlyNew)
                ForEach(model.station.savedFilters, id: \.id) { filter in
                    Label(filter.name, systemImage: "line.3.horizontal.decrease.circle")
                        .tag(HitLogSidebarItem.saved(filter.id))
                        .contextMenu {
                            Button("Delete Filter", role: .destructive) { deleteFilter(filter.id) }
                        }
                }
                Button {
                    filterName = ""
                    namingFilter = true
                } label: {
                    Label("Save Current Filter…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    private func apply(_ item: HitLogSidebarItem) {
        let (filter, day) = item.apply(current: model.filter, saved: model.station.savedFilters)
        model.selectedSession = day
        model.filter = filter
        if (filter.text ?? "") != model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
            model.searchText = filter.text ?? ""
        }
    }

    // MARK: Table

    private var table: some View {
        HitTable(rows: rows, layout: model.layout, selection: $model.selection, sortOrder: sortOrder,
                 groupColumns: $groupColumns, transmissionColumns: $transmissionColumns)
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty {
                    Button("Play All in Order") { playAll(ids) }
                    Button("Show in Finder") { showInFinder(ids) }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = ids }
                }
            } primaryAction: { ids in
                playAll(ids)
            }
            .onDeleteCommand { if !model.selection.isEmpty { pendingDelete = model.selection } }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(model.searchText.isEmpty ? "No Hits" : "No Matches",
                                           systemImage: "waveform",
                                           description: Text(model.searchText.isEmpty
                                                             ? "Transmissions are logged here while the station is open."
                                                             : "Nothing matches the search."))
                }
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Layout", selection: $model.layout) {
                Text("By Talkgroup").tag(HitLogLayout.groups)
                Text("Every Transmission").tag(HitLogLayout.transmissions)
            }
            .pickerStyle(.segmented)
            .help("One row per talkgroup or frequency, or one row per transmission")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { session?.loggingPaused ?? false },
                                 set: { session?.loggingPaused = $0 })) {
                Label("Pause Logging", systemImage: "pause.circle")
            }
            .toggleStyle(.button)
            .disabled(session == nil)
            .help(session == nil ? "Logging runs while the station's window is open"
                                 : "Pause or resume logging and recording for this station")
            Button("Export CSV…", systemImage: "square.and.arrow.up") { exportCSV() }
                .help("Export the rows matching the current filter as CSV")
            Button("Reset Counts…", systemImage: "arrow.counterclockwise") { confirmReset = true }
                .help("Start hit counts and talk time again from now")
            Button("Delete…", systemImage: "trash") { pendingDelete = model.selection }
                .disabled(model.selection.isEmpty)
                .help("Delete the selected rows and move their recordings to the Trash")
            Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
                .help(showInspector ? "Hide the inspector" : "Show the inspector")
        }
    }

    // MARK: Actions

    private func playAll(_ ids: Set<String>) {
        Task {
            let hits = await model.loggedHits(forRows: ids)
            let items = hits.compactMap { t in t.audioPath.map { WAVPlayback.Item(id: t.hit.id, url: URL(fileURLWithPath: $0)) } }
            if !items.isEmpty { playback.playAll(items) }
        }
    }

    private func showInFinder(_ ids: Set<String>) {
        Task {
            let urls = await model.loggedHits(forRows: ids)
                .compactMap(\.audioPath)
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
            if urls.isEmpty {
                alert = ("No Recordings", "The selected rows have no recordings on disk.")
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }

    private func delete(_ rows: Set<String>) {
        Task {
            // A transmission still on air is left alone: its recording is still being written.
            let hits = await model.loggedHits(forRows: rows)
            let ids = hits.filter { $0.hit.endedAt != nil }.map(\.hit.id)
            if ids.isEmpty {
                if !hits.isEmpty {
                    alert = hits.count == 1
                        ? ("That transmission is still on air.", "Delete it once it has ended; its recording is still being written.")
                        : ("Those transmissions are still on air.", "Delete them once they have ended; their recordings are still being written.")
                }
                return
            }
            playback.stop(ifAnyOf: Set(ids))
            do {
                try await model.delete(ids)
            } catch let error as HitLogTrashError {
                alert = ("Some Recordings Weren't Moved to the Trash",
                         "The rows were deleted, but \(error.failures.count) recording(s) couldn't be moved to the Trash: "
                         + error.failures.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent) (\($0.error.localizedDescription))" }
                             .joined(separator: "; "))
            } catch {
                alert = ("Couldn't Delete the Rows", "\(error)")
            }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = HitLogText.csvFileName(stationName: model.station.name)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let csv = try await model.exportCSV()
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                alert = ("Couldn't Export the Hit Log", "\(error)")
            }
        }
    }

    private func resetCounts() {
        Task {
            do { try await model.resetCounts() } catch { alert = ("Couldn't Reset the Counts", message(error)) }
        }
    }

    private func saveFilter() {
        let name = filterName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await model.saveFilter(named: name)
                if let added = model.station.savedFilters.last { sidebar = .saved(added.id) }
            } catch {
                alert = ("Couldn't Save the Filter", message(error))
            }
        }
    }

    private func deleteFilter(_ id: UUID) {
        if sidebar == .saved(id) { sidebar = .all }
        Task {
            do { try await model.deleteFilter(id) } catch { alert = ("Couldn't Delete the Filter", message(error)) }
        }
    }

    private func message(_ error: any Error) -> String {
        (error as? SettingsStoreError)?.description ?? (error as? StationNoLongerExists)?.description
            ?? error.localizedDescription
    }
}
#endif
