// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleStore
import SwiftUI

/// The Mac app. Scenes: the station picker (`Window` "picker"), one window per station
/// (`WindowGroup` "station", the value is the station's id), one hit log per station
/// (`WindowGroup` "hitlog", the same value), and Settings. The picker is
/// the scene opened at launch; it routes straight to the window of the last station that
/// connected when that station still exists, and closes itself after a successful Connect
/// (`StationPickerView`). Closing the last station window brings it back (`StationWindow`,
/// except while quitting). Window restoration is off, so a launch always starts
/// from that rule rather than from whatever was open last time. Sessions live in the
/// `AppDelegate`'s `SessionRegistry`; the delegate also stops them on quit, sleep and signals.
@main
struct NoctuleScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Stations", id: AppScene.picker) {
            StationPickerView(directory: appDelegate.directory, settings: appDelegate.settings,
                              registry: appDelegate.registry, launch: appDelegate.launch)
        }
        .restorationBehavior(.disabled)
        // Tall enough for the station editor sheet (`EditorText.sheetHeight`) to fit inside it.
        .defaultSize(width: 520, height: 620)

        // Each station window is opened with `openWindow(id: AppScene.station, value: id)`.
        WindowGroup("Station", id: AppScene.station, for: UUID.self) { $stationID in
            StationWindow(stationID: stationID, registry: appDelegate.registry, settings: appDelegate.settings,
                          windows: appDelegate.stationWindows, presentsTestSheet: appDelegate.presentsTestSheet)
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 1160, height: 700)

        WindowGroup("Hit Log", id: AppScene.hitLog, for: UUID.self) { $stationID in
            HitLogWindow(stationID: stationID, registry: appDelegate.registry, settings: appDelegate.settings,
                         settingsDirectory: appDelegate.settingsDirectory)
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 1440, height: 680)

        Settings {
            SettingsView(directory: appDelegate.directory, settings: appDelegate.settings,
                         registry: appDelegate.registry, recordingsRoot: appDelegate.recordingsRoot)
        }
        .commands {
            FileCommands()
            // View › Show/Hide Sidebar (⌃⌘S) for the hit log's sidebar.
            SidebarCommands()
        }
    }
}

enum AppScene {
    static let picker = "picker"
    static let station = "station"
    static let hitLog = "hitlog"
}

/// What a station or hit-log window shows without a station id (none can be opened from the
/// menus, but a window could still be created without one).
struct NoStationView: View {
    var body: some View {
        ContentUnavailableView("No Station", systemImage: "antenna.radiowaves.left.and.right.slash",
                               description: Text("Open a station from the Stations window (Window › Stations)."))
            .frame(minWidth: 420, minHeight: 280)
    }
}

/// The window groups' automatic File › New items would open a station or hit-log window with
/// no station, so they are replaced by "Open Station…" (the picker). An empty replacement would
/// make SwiftUI drop the whole File menu, Close (⌘W) included.
struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Station…") { openWindow(id: AppScene.picker) }
                .keyboardShortcut("o")
        }
    }
}

#else
/// The app is macOS-only for now; this keeps the package building for other platforms.
@main enum NoctuleScanUnsupported {
    static func main() {}
}
#endif
