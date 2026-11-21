// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

/// True when `NOCTULE_CI_RUNNER` is set and not empty: both workflows (`ci.yml` and `release.yml`) set it on their runner.
public func isCIRunner(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    !(environment["NOCTULE_CI_RUNNER"] ?? "").isEmpty
}

extension Trait where Self == ConditionTrait {
    /// Skips a test on the CI runner only, for a known flake that passes on a developer's Mac.
    public static func skippedOnCIRunner(_ reason: Comment) -> Self {
        .disabled(if: isCIRunner(), reason)
    }
}
