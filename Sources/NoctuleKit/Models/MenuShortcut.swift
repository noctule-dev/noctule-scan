// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

/// A front-panel key that opens a menu screen by a checked menu walk instead of a `KEY` press
/// (Plan 24, design §5.3): Services (`T`) and Range (`R`).
public enum MenuShortcut: String, Sendable, CaseIterable {
    case serviceTypes, range

    public init?(key: FrontPanelKey) {
        switch key {
        case .serviceType: self = .serviceTypes
        case .range: self = .range
        default: return nil
        }
    }

    public var key: FrontPanelKey {
        switch self {
        case .serviceTypes: .serviceType
        case .range: .range
        }
    }
}

/// One step of a walk: on the menu screen titled `screen`, highlight and open the item named `item`.
public struct MenuStep: Sendable, Equatable {
    public let screen: String
    public let item: String

    public init(screen: String, item: String) {
        self.screen = screen
        self.item = item
    }
}

/// The menu items to open, in order, to reach `destination` (a static value of a model's profile).
public struct MenuPath: Sendable, Equatable {
    /// The most steps any path may have.
    public static let maxSteps = 3

    public let steps: [MenuStep]
    public let destination: String

    public init(steps: [MenuStep], destination: String) {
        precondition((1...Self.maxSteps).contains(steps.count), "a menu path has 1 to \(Self.maxSteps) steps")
        self.steps = steps
        self.destination = destination
    }

    /// Menu › Select Service Types (design §5.3).
    public static let serviceTypes = MenuPath(
        steps: [MenuStep(screen: "Menu", item: "Select Service Types")], destination: "Select Service Types")

    /// Menu › Set Your Location › Set Range (design §5.3).
    public static let range = MenuPath(
        steps: [MenuStep(screen: "Menu", item: "Set Your Location"),
                MenuStep(screen: "Set Your Location", item: "Set Range")],
        destination: "Set Range")
}
