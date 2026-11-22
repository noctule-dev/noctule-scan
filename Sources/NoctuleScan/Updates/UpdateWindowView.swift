// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import SwiftUI

/// The Software Update window's content (update-check design §6.1, §6.3): an update with its
/// notes and Skip This Version, Later and Download…, or a check's other answer with one OK.
/// Return is Download… (or OK); Later is the cancel action (Esc).
struct UpdateWindowView: View {
    let result: UpdateCheckResult
    let skip: (AppVersion) -> Void
    let download: (URL) -> Void
    let close: () -> Void

    static let width: CGFloat = 520

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 12) {
                if case .updateAvailable(let offer) = result {
                    update(offer)
                } else if let message = UpdateText.message(for: result) {
                    Text(message.title).font(.headline)
                    Text(message.body).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(UpdateText.okButton, action: close).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: Self.width)
    }

    @ViewBuilder private func update(_ offer: UpdateOffer) -> some View {
        Text(UpdateText.headline).font(.headline)
        Text(UpdateText.available(offer)).fixedSize(horizontal: false, vertical: true)
        Text(UpdateText.notesLabel).font(.subheadline).bold()
        ScrollView {
            Text(UpdateText.notes(offer.release.notes))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(height: 150)
        .background(Color(nsColor: .textBackgroundColor))
        .border(Color(nsColor: .separatorColor))
        HStack {
            Button(UpdateText.skipButton) {
                skip(offer.release.version)
                close()
            }
            Spacer()
            Button(UpdateText.laterButton, action: close).keyboardShortcut(.cancelAction)
            Button(UpdateText.downloadButton) {
                download(offer.release.page)
                close()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
#endif
