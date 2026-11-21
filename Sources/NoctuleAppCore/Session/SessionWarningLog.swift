// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// The line the app writes to stderr for each session warning (`SessionEnvironment.onWarning`), so
/// a run launched from Terminal keeps a record of what the window showed:
/// `NoctuleScan: HH:mm:ss warning: <station>: <text>`, in local time.
public enum SessionWarningLog {
    public static func line(station: String, text: String, at date: Date = Date(),
                            timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return "NoctuleScan: \(formatter.string(from: date)) warning: \(station): \(text)"
    }
}
