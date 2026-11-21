// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// Sends front-panel key presses one at a time, in order, and drops presses beyond a bound so fast
/// input (key repeat, scroll) can't flood the UDP channel.
///
/// Capacity rule: at most `maxQueued` presses are pending at once, counting the one being sent.
/// `enqueue` returns false (and drops the press) when that many are pending. A failed send sets
/// `lastError` and the queue carries on.
public actor KeyPressQueue {
    public let maxQueued: Int
    public private(set) var lastError: String?
    private let send: @Sendable (FrontPanelKey) async throws -> Void
    private var pending: [FrontPanelKey] = []   // includes the press in flight (first element)
    private var running = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(maxQueued: Int = 8, send: @escaping @Sendable (FrontPanelKey) async throws -> Void) {
        self.maxQueued = maxQueued
        self.send = send
    }

    public func enqueue(_ key: FrontPanelKey) -> Bool {
        guard pending.count < maxQueued else { return false }
        pending.append(key)
        if !running {
            running = true
            Task { await self.run() }
        }
        return true
    }

    /// Returns when nothing is pending or in flight.
    public func drain() async {
        if pending.isEmpty && !running { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func run() async {
        while let key = pending.first {
            do { try await send(key); lastError = nil } catch { lastError = String(describing: error) }
            pending.removeFirst()
        }
        running = false
        let waiters = drainWaiters
        drainWaiters = []
        for w in waiters { w.resume() }
    }
}
