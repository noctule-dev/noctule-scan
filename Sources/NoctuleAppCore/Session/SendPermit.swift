// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization

/// Whether a state-changing command a user's action sends is still wanted when it reaches the scanner
/// client's request slot (`ScannerClient.send(_:onlyIf:)`, flaky-sweep review I2, 2026-11-22). The command can
/// wait there for up to a command timeout, behind a read whose reply was lost, while the main actor runs on:
/// whatever makes the action stale meanwhile (the Quick Keys pop-over closing, the scanner entering a menu, a
/// detach, a stop) revokes its permit, synchronously, and the client then writes nothing. Revoking is final.
final class SendPermit: Sendable {
    private let granted = Mutex(true)

    func revoke() {
        granted.withLock { $0 = false }
    }

    var isGranted: Bool {
        granted.withLock { $0 }
    }

    /// The guard to hand `ScannerClient` (`onlyIf`).
    var check: @Sendable () -> Bool {
        { [self] in isGranted }
    }
}
