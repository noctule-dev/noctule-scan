// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import Synchronization
import Testing

/// Stops `source`, failing the test if `stop()` hasn't returned within `limit`. A `stop()` that
/// hangs then fails its test in a second, rather than holding the whole run past its time limit
/// (an awaited `stop()` can't be cancelled out of). Shared by the line-in sources' tests.
func stopWithin(
    _ source: some LineInSource, _ limit: Duration = .seconds(1),
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let returned = Mutex(false)
    Task {
        await source.stop()
        returned.withLock { $0 = true }
    }
    let deadline = ContinuousClock.now + limit
    while !returned.withLock({ $0 }) {
        if ContinuousClock.now >= deadline {
            Issue.record("timed out waiting for stop() to return", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
