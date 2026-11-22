// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// What the person chose about update checks, kept in `app.json` beside the last station.
public struct UpdatePreferences: Equatable, Sendable {
    /// "Check for updates automatically" (`app.json` key `checkForUpdates`). On by default.
    public var checkAutomatically: Bool = true
    /// When the last check ended (`lastUpdateCheck`), nil if none has.
    public var lastChecked: Date? = nil
    /// The version the person chose to skip (`skippedUpdateVersion`), nil if none.
    public var skippedVersion: String? = nil

    public init() {}
}

/// Where update preferences live. Best effort like the rest of `app.json`: a failure to read
/// gives the defaults, and a save never throws.
public protocol UpdatePreferencesStore: Sendable {
    func updatePreferences() async -> UpdatePreferences
    func saveUpdatePreferences(_ preferences: UpdatePreferences) async
}

/// Update preferences held in memory, for tests and for stores with no file.
public actor InMemoryUpdatePreferences: UpdatePreferencesStore {
    private var preferences: UpdatePreferences

    public init(_ initial: UpdatePreferences = .init()) { preferences = initial }

    public func updatePreferences() async -> UpdatePreferences { preferences }
    public func saveUpdatePreferences(_ preferences: UpdatePreferences) async { self.preferences = preferences }
}
