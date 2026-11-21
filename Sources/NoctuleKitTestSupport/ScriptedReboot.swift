// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import Synchronization

/// A simulated scanner that reboots on `MSM,1`. Share one instance between the transports a
/// test hands out (one per `ScannerClient`), the way one real scanner serves every client.
///
/// Before `MSM,1` it answers `MDL`. After it, it replies to `MSM` with `msmReplies`, then ignores
/// the next `silentPolls` `MDL` requests (the scanner is rebooting), then answers again.
/// `msmCount` and `mdlCount` count what the scanner has received across all transports.
public final class ScriptedReboot: Sendable {
    private struct State {
        var msmSeen = 0
        var mdlSeen = 0
        var answerLeft = 0
        var silentLeft = 0
        var restarted = false
    }

    private let state = Mutex(State())
    private let answerPolls: Int
    private let silentPolls: Int
    private let msmReplies: [ScannerResponse]
    private let acceptsMSM: Bool

    /// - Parameters:
    ///   - answerPolls: how many `MDL` requests right after `MSM,1` are still answered.
    ///   - silentPolls: how many `MDL` requests after `MSM,1` go unanswered.
    ///   - msmReplies: what the scanner sends back for `MSM,1` (empty: it reboots before replying).
    public init(answerPolls: Int = 0, silentPolls: Int,
                msmReplies: [ScannerResponse] = [.fields(command: "MSM", fields: ["OK"])]) {
        self.answerPolls = answerPolls
        self.silentPolls = silentPolls
        self.msmReplies = msmReplies
        self.acceptsMSM = !msmReplies.contains { if case .rejected = $0.status { true } else { false } }
    }

    public var msmCount: Int { state.withLock { $0.msmSeen } }
    public var mdlCount: Int { state.withLock { $0.mdlSeen } }

    public func makeTransport() -> SimulatedScannerTransport {
        SimulatedScannerTransport { [self] command in
            switch command.name {
            case "MSM":
                state.withLock {
                    $0.msmSeen += 1
                    if acceptsMSM, !$0.restarted {
                        $0.restarted = true
                        $0.answerLeft = answerPolls
                        $0.silentLeft = silentPolls
                    }
                }
                return msmReplies
            case "MDL":
                let silent = state.withLock { s -> Bool in
                    s.mdlSeen += 1
                    if s.answerLeft > 0 { s.answerLeft -= 1; return false }
                    if s.silentLeft > 0 { s.silentLeft -= 1; return true }
                    return false
                }
                return silent ? [] : [.fields(command: "MDL", fields: ["SDS200"])]
            default:
                return []
            }
        }
    }
}
