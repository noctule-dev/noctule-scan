// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI

/// One station's window. Its task runs from appear to disappear: it looks the station up, opens
/// its shared session (`registry.open`), holds it while the window is shown, and releases it when
/// the window goes away (SwiftUI cancels the task on disappear), so the last window on a station
/// stops its session (`PSI,0`, TEARDOWN).
///
/// The window shows whatever session the registry holds for its station, so it follows an edit:
/// a rename or connection change (the registry swaps in a fresh session; the title updates at
/// once) and a key map or color change (applied to the running session). When the station is
/// deleted (the registry drops it), the window closes; it then releases nothing, since its
/// reference went with the station. Its content is `StationContentView`, showing the scanner
/// view or the Mac-style view per the toolbar's segmented control. A switch is saved to the
/// station's `preferredView` straight through the settings store (`StationViewPreference`); it
/// never goes through `registry.stationsChanged`, so it never restarts the session.
///
/// The status bar's Stations button opens the picker and leaves the session running; Disconnect
/// closes this window (releasing the session) and opens the picker. When the last station window
/// closes, however it closes, the picker opens (`StationWindowTracker`), except while quitting. Only
/// windows that showed a station count: one with no station or a missing station doesn't.
struct StationWindow: View {
    let stationID: UUID?
    let registry: SessionRegistry
    let settings: any SettingsStore
    /// The station windows showing a station; the last one to close opens the Stations window.
    let windows: StationWindowTracker
    /// Test-only (`NOCTULE_TEST_PRESENT_SHEET`): present a sheet once the session is open.
    var presentsTestSheet = false

    @State private var testSheet = false
    /// This window's key in `windows`.
    @State private var windowKey = UUID()
    /// The window took a reference with `registry.open` and still holds it.
    @State private var holding = false
    @State private var problem: String?
    @State private var view: PreferredView = .scanner
    @State private var saveTask: Task<Void, Never>?
    @State private var saveProblem: String?
    /// This window's Quick Keys pop-over and its torn-off panel (one of each per station window).
    @State private var quickKeys = QuickKeysPanelController()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// The registry's current session for this station, once this window has opened it.
    private var session: StationSession? {
        guard holding, let stationID else { return nil }
        return registry.session(for: stationID)
    }

    var body: some View {
        Group {
            if stationID == nil {
                NoStationView()
            } else if let session {
                StationContentView(session: session, view: view,
                                   openHitLog: { openWindow(id: AppScene.hitLog, value: session.station.id) },
                                   showStations: { openWindow(id: AppScene.picker) },
                                   disconnect: disconnect,
                                   quickKeysShown: { [quickKeys] in quickKeys.isPopoverShown })
                    .environment(\.quickKeysPopoverShown, quickKeys.presence.isPopoverShown)
            } else if let problem {
                Text(problem).foregroundStyle(.secondary).padding()
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .navigationTitle(session?.station.name ?? "Station")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: viewSelection) {
                    Label("Scanner", systemImage: "rectangle.grid.3x2").tag(PreferredView.scanner)
                    Label("Mac-style", systemImage: "text.below.photo").tag(PreferredView.macStyle)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .disabled(session == nil)
                .help("Switch between the scanner's front panel and the Mac-style view")
            }
            if QuickKeysToolbar.isShown(for: session) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let session { quickKeys.toggle(session: session) }
                    } label: {
                        Label(QuickKeysText.toolbarLabel, systemImage: "square.grid.3x2")
                    }
                    .labelStyle(.titleAndIcon)
                    .help(QuickKeysText.toolbarHelp)
                    .background(QuickKeysAnchor { [quickKeys] view in quickKeys.anchorFound(view) })
                }
            }
        }
        .alert("Couldn't save the view choice", isPresented: Binding(get: { saveProblem != nil },
                                                                     set: { if !$0 { saveProblem = nil } })) {
            Button("OK") { saveProblem = nil }
        } message: {
            Text(saveProblem ?? "")
        }
        .task(id: stationID) { await run() }
        .onChange(of: session.map(ObjectIdentifier.init)) { _, _ in
            // A new session (an edit restarted it) or none: the old model must not stay open.
            quickKeys.closeAll()
        }
        .onChange(of: QuickKeysToolbar.isShown(for: session)) { _, shown in
            if !shown { quickKeys.closeAll() }
        }
        .onDisappear {
            quickKeys.closeAll()
            // Counted only if it showed a station (`run()`), so an empty window never reopens the picker.
            if windows.closed(windowKey) { openWindow(id: AppScene.picker) }
        }
        .sheet(isPresented: $testSheet) {
            Text("Test sheet (NOCTULE_TEST_PRESENT_SHEET)")
                .padding(40)
                .onAppear { fputs("NoctuleScan: test sheet presented\n", stderr) }
        }
        .onChange(of: holding && session == nil) { _, gone in
            // The station was deleted (or the app is quitting): the registry already let go.
            guard gone else { return }
            holding = false
            dismiss()
        }
    }

    /// The status bar's Disconnect: closes this window (its task's cancellation releases the
    /// session: `PSI,0`, TEARDOWN, once no other window holds it) and shows the Stations window.
    private func disconnect() {
        dismiss()
        openWindow(id: AppScene.picker)
    }

    /// Switches at once and saves in the background, one save after another so the last choice wins.
    private var viewSelection: Binding<PreferredView> {
        Binding(get: { view }, set: { choice in
            guard choice != view, let stationID else { return }
            view = choice
            let previous = saveTask
            let settings = self.settings
            saveTask = Task {
                await previous?.value
                do {
                    try await StationViewPreference.save(choice, stationID: stationID, in: settings)
                } catch {
                    saveProblem = StationViewPreference.failureMessage(error)
                }
            }
        })
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
            problem = "\(error)"
            return
        }
        guard !Task.isCancelled else { return }
        view = station.preferredView
        _ = registry.open(station)
        holding = true
        windows.showing(windowKey)
        if presentsTestSheet { testSheet = true }
        // Hold the session until the window disappears (the task is cancelled then).
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        // Not if the station was deleted meanwhile: that reference is gone, and a later window on a
        // re-imported station must not lose its own.
        guard holding else { return }
        holding = false
        await registry.release(stationID)
    }
}


/// Saves a station's view choice without touching anything else in it.
enum StationViewPreference {
    /// Sets only `preferredView`, in one atomic read-modify-write in the store (so edits saved
    /// meanwhile, such as a rename, are kept). Does nothing if the station is gone.
    static func save(_ view: PreferredView, stationID: UUID, in settings: any SettingsStore) async throws {
        try await settings.update(id: stationID) { $0.preferredView = view }
    }

    /// The alert's text for a failed save: what happened, then the store's reason.
    static func failureMessage(_ error: any Error) -> String {
        let reason = (error as? SettingsStoreError)?.description ?? error.localizedDescription
        return "This window keeps the view you chose, but it won't be remembered next time. \(reason)"
    }
}
#endif
