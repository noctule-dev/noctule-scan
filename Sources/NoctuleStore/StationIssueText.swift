// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

// The wording for station problems, shared by the `noctule station add` command and the app's
// station editor so the two never drift apart.

extension StationIssue {
    /// A short sentence fragment describing the problem, without any command-line flag names.
    public var message: String {
        switch self {
        case .emptyName: "the station needs a name"
        case .missingHost: "the station needs a host"
        case .invalidMinimumDuration: "the minimum recording length must be 0-60 s"
        case .invalidMaxTransmission: "the longest transmission must be 10-3600 s"
        case .invalidReconnectCooldown: "the reconnect wait must be 0-120 s"
        }
    }
}

extension Station {
    /// The text for a name that's already taken by `existingName`.
    public static func duplicateNameMessage(existingName: String) -> String {
        "a station named \"\(existingName)\" already exists"
    }

    /// The station in `stations` whose name matches `name`, ignoring case and surrounding spaces.
    /// `excluding` skips one station by id (the one being edited).
    public static func firstNamed(_ name: String, in stations: [Station], excluding id: UUID? = nil) -> Station? {
        let wanted = normalizedName(name)
        guard !wanted.isEmpty else { return nil }
        return stations.first { $0.id != id && normalizedName($0.name) == wanted }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
