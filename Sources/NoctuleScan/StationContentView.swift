// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI

/// A station window's content around its view: the problem banner, the scanner view or the
/// Mac-style view (`view`), the recent-hits sidebar ("Active now" in the Mac-style view), the
/// status bar (with the Stations and Disconnect buttons), and the station's key map on the
/// keyboard in either view (↑, ↓, ↩ and Esc go to the Mac-style menu while it shows; in the
/// Mac-style view no mapped key is pressed while the scanner is in a menu).
struct StationContentView: View {
    let session: StationSession
    let view: PreferredView
    let openHitLog: () -> Void
    /// The status bar's Stations button: shows the picker, leaves the session running.
    let showStations: () -> Void
    /// The status bar's Disconnect button: closes this window and shows the picker.
    let disconnect: () -> Void
    /// The window's Quick Keys pop-over shows: no key goes to the scanner meanwhile.
    var quickKeysShown: @MainActor () -> Bool = { false }

    @State private var controlFocus = ControlFocus()
    /// The Mac-style menu's hold on ↑, ↓, ↩ and Esc while it is on screen.
    @State private var menuKeys = MacMenuKeys()

    var body: some View {
        VStack(spacing: 0) {
            if ScannerProblemBanner.content(for: session) != nil {
                ScannerProblemBanner(session: session, disconnect: disconnect)
                Divider()
            }
            HStack(spacing: 0) {
                Group {
                    switch view {
                    case .scanner: ScannerView(session: session)
                    case .macStyle: MacStyleView(session: session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                RecentHitsList(hits: session.recentHits, showsActiveNow: view == .macStyle, openHitLog: openHitLog)
                    .frame(width: RecentHitsList.width)
                    .background(.background.secondary)
            }
            Divider()
            ScannerStatusBar(session: session, showStations: showStations, disconnect: disconnect)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(.bar)
        }
        .environment(\.controlFocus, controlFocus)
        .environment(\.macMenuKeys, menuKeys)
        .background(KeyboardShortcuts(router: KeyboardRouter(map: session.station.keyMap.resolved(for: session.model)),
                                      controlFocus: controlFocus, menuKeys: menuKeys,
                                      macMenuShowing: { [session, view] in
                                          view == .macStyle && (session.menu.isInMenu || session.info?.isMenu == true)
                                      },
                                      stepsAside: quickKeysShown) { session.press($0) })
    }
}
#endif
