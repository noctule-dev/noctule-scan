// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

private func tempStore() -> InMemoryRTSPCooldownStore { InMemoryRTSPCooldownStore() }

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// The gate counts from its own now, which a slow runner reaches a while after the test stamped its
/// closes: the remaining time is at most `expected` (as of `stamped`) and at least `expected` less the
/// time that has passed since. A fixed second each way failed on a runner VM (run 45019776194).
private func expectRemaining(_ r: Duration, _ expected: Double, since stamped: Date,
                             sourceLocation: SourceLocation = #_sourceLocation) {
    let elapsed = Date().timeIntervalSince(stamped)
    #expect(seconds(r) <= expected + 0.05 && seconds(r) >= expected - elapsed - 0.05,
            "\(r) remaining, \(expected) s expected as of \(elapsed) s ago", sourceLocation: sourceLocation)
}

@Test func remainingIsNilWithoutRecord() async {
    let r = await RTSPCooldownGate.remaining(store: tempStore(), host: "127.0.0.1", cooldown: .seconds(120))
    #expect(r == nil)
}

@Test func remainingCountsLatestKey() async throws {
    let store = tempStore()
    let keys = await RTSPClient.cooldownKeys(for: "localhost")
    try #require(keys.count >= 2)
    let now = Date()
    await store.recordClosed(host: keys[0], at: now.addingTimeInterval(-100))
    await store.recordClosed(host: keys[1], at: now.addingTimeInterval(-30))
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "localhost", cooldown: .seconds(120)))
    expectRemaining(r, 90, since: now)
}

@Test func zeroCooldownIsNil() async {
    let store = tempStore()
    await store.recordClosed(host: "127.0.0.1", at: Date())
    #expect(await RTSPCooldownGate.remaining(store: store, host: "127.0.0.1", cooldown: .zero) == nil)
}

@Test func waitOutStopsWhenInterrupted() async {
    let start = ContinuousClock.now
    let finished = await RTSPCooldownGate.waitOut(.seconds(30), isInterrupted: { ContinuousClock.now - start > .milliseconds(300) })
    #expect(finished == false)
    #expect(ContinuousClock.now - start < .seconds(5))
}

// MARK: Policy (Plan 5 Task 1)


@Test func gateUsesTheCleanValueAfterACleanClose() async throws {
    let now = Date()
    let store = tempStore()
    await store.recordClosed(host: "127.0.0.1", at: now.addingTimeInterval(-10), clean: true)
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .seconds(30))
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "127.0.0.1", policy: policy))
    expectRemaining(r, 20, since: now)
    #expect(await RTSPCooldownGate.remaining(store: store, host: "127.0.0.1",
                                            policy: RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)) == nil)
}

@Test func gateUsesTheFullValueAfterAnUncleanClose() async throws {
    let now = Date()
    let store = tempStore()
    await store.recordClosed(host: "127.0.0.1", at: now.addingTimeInterval(-10), clean: false)
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "127.0.0.1", policy: policy))
    expectRemaining(r, 110, since: now)
}

@Test func gateTakesTheLatestKeyAndItsFlag() async throws {
    let now = Date()
    let store = tempStore()
    let keys = await RTSPClient.cooldownKeys(for: "localhost")
    try #require(keys.count >= 2)
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    // Older unclean, later clean: the unclean one still holds the full cooldown (QA I2).
    await store.recordClosed(host: keys[0], at: now.addingTimeInterval(-100), clean: false)
    await store.recordClosed(host: keys[1], at: now.addingTimeInterval(-30), clean: true)
    let held = try #require(await RTSPCooldownGate.remaining(store: store, host: "localhost", policy: policy))
    expectRemaining(held, 20, since: now)
    // Equal times: unclean wins.
    let t = now.addingTimeInterval(-30)
    await store.recordClosed(host: keys[0], at: t, clean: false)
    await store.recordClosed(host: keys[1], at: t, clean: true)
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "localhost", policy: policy))
    expectRemaining(r, 90, since: now)
}

@Test func gateWaitsTheFullCooldownAfterAnEarlierUncleanClose() async throws {
    let now = Date()
    let store = tempStore()
    let keys = await RTSPClient.cooldownKeys(for: "localhost")
    try #require(keys.count >= 2)
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    await store.recordClosed(host: keys[0], at: now.addingTimeInterval(-1), clean: false)
    await store.recordClosed(host: keys[1], at: now, clean: true)
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "localhost", policy: policy))
    expectRemaining(r, 119, since: now)
    // A clean close stamped in the future counts as an unclean close now.
    let other = tempStore()
    await other.recordClosed(host: "127.0.0.1", at: now.addingTimeInterval(600), clean: true)
    let asked = Date()
    let f = try #require(await RTSPCooldownGate.remaining(store: other, host: "127.0.0.1", policy: policy))
    expectRemaining(f, 120, since: asked)
}
