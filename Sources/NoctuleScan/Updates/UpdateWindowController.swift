// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import SwiftUI

/// The one Software Update window (update-check design §6.1): a normal window, never a modal
/// alert (a modal would hold up quit), reused for every result and refreshed with the newest.
///
/// **Focus.** A manual check activates the app and makes the window key: the person just asked.
/// An automatic one only orders it in front of the app's windows, neither activating the app nor
/// making the window key, so Return and Esc keep going to the station window (and its scanner)
/// until the person clicks this one. The close button, like Esc, is Later: it closes and saves nothing.
@MainActor final class UpdateWindowController: NSWindowController {
    /// Skip This Version; set by the owner of the checker.
    var skip: (AppVersion) -> Void = { _ in }
    private var hosting: NSHostingController<UpdateWindowView>?

    convenience init() { self.init(window: nil) }

    func show(_ result: UpdateCheckResult, trigger: UpdateCheckTrigger) {
        let view = UpdateWindowView(
            result: result,
            skip: { [weak self] version in self?.skip(version) },
            download: { page in NSWorkspace.shared.open(page) },
            close: { [weak self] in self?.window?.performClose(nil) })
        let window: NSWindow
        if let existing = self.window, let hosting {
            hosting.rootView = view
            window = existing
        } else {
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = [.preferredContentSize]
            let created = UpdateWindow(contentRect: NSRect(x: 0, y: 0, width: UpdateWindowView.width, height: 200),
                                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.contentViewController = controller
            created.title = UpdateText.windowTitle
            created.isReleasedWhenClosed = false
            // Sized to the content before centring, so the first show is centred at its real size.
            created.setContentSize(controller.view.fittingSize)
            created.center()
            hosting = controller
            self.window = created
            window = created
        }
        if trigger == .manual {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }
}

/// Esc closes the window when nothing in it takes the key (the OK-only messages have no Later).
private final class UpdateWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
#endif
