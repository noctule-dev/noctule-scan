// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

private func tempStore() -> InMemoryRTSPCooldownStore { InMemoryRTSPCooldownStore() }

@Test func remainingIsNilWithoutRecord() async {
    let r = await RTSPCooldownGate.remaining(store: tempStore(), host: "127.0.0.1", cooldown: .seconds(120))
    #expect(r == nil)
}

@Test func remainingCountsLatestKey() async throws {
    let store = tempStore()
    let keys = await RTSPClient.cooldownKeys(for: "localhost")
    try #require(keys.count >= 2)
    await store.recordClosed(host: keys[0], at: Date().addingTimeInterval(-100))
    await store.recordClosed(host: keys[1], at: Date().addingTimeInterval(-30))
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "localhost", cooldown: .seconds(120)))
    let seconds = Double(r.components.seconds) + Double(r.components.attoseconds) / 1e18
    #expect(abs(seconds - 90) <= 1)
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

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

@Test func gateUsesTheCleanValueAfterACleanClose() async throws {
    let store = tempStore()
    await store.recordClosed(host: "127.0.0.1", at: Date().addingTimeInterval(-10), clean: true)
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .seconds(30))
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "127.0.0.1", policy: policy))
    #expect(abs(seconds(r) - 20) <= 1, "\(r)")
    #expect(await RTSPCooldownGate.remaining(store: store, host: "127.0.0.1",
                                            policy: RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)) == nil)
}

@Test func gateUsesTheFullValueAfterAnUncleanClose() async throws {
    let store = tempStore()
    await store.recordClosed(host: "127.0.0.1", at: Date().addingTimeInterval(-10), clean: false)
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "127.0.0.1", policy: policy))
    #expect(abs(seconds(r) - 110) <= 1, "\(r)")
}

@Test func gateTakesTheLatestKeyAndItsFlag() async throws {
    let store = tempStore()
    let keys = await RTSPClient.cooldownKeys(for: "localhost")
    try #require(keys.count >= 2)
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    // Older unclean, later clean: the unclean one still holds the full cooldown (QA I2).
    await store.recordClosed(host: keys[0], at: Date().addingTimeInterval(-100), clean: false)
    await store.recordClosed(host: keys[1], at: Date().addingTimeInterval(-30), clean: true)
    let held = try #require(await RTSPCooldownGate.remaining(store: store, host: "localhost", policy: policy))
    #expect(abs(seconds(held) - 20) <= 1, "\(held)")
    // Equal times: unclean wins.
    let t = Date().addingTimeInterval(-30)
    await store.recordClosed(host: keys[0], at: t, clean: false)
    await store.recordClosed(host: keys[1], at: t, clean: true)
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "localhost", policy: policy))
    #expect(abs(seconds(r) - 90) <= 1, "\(r)")
}

@Test func gateWaitsTheFullCooldownAfterAnEarlierUncleanClose() async throws {
    let store = tempStore()
    let keys = await RTSPClient.cooldownKeys(for: "localhost")
    try #require(keys.count >= 2)
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    await store.recordClosed(host: keys[0], at: Date().addingTimeInterval(-1), clean: false)
    await store.recordClosed(host: keys[1], at: Date(), clean: true)
    let r = try #require(await RTSPCooldownGate.remaining(store: store, host: "localhost", policy: policy))
    #expect(abs(seconds(r) - 119) <= 1, "\(r)")
    // A clean close stamped in the future counts as an unclean close now.
    let other = tempStore()
    await other.recordClosed(host: "127.0.0.1", at: Date().addingTimeInterval(600), clean: true)
    let f = try #require(await RTSPCooldownGate.remaining(store: other, host: "127.0.0.1", policy: policy))
    #expect(abs(seconds(f) - 120) <= 1, "\(f)")
}
