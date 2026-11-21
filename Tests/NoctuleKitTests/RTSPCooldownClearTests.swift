// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

@Test func inMemoryClearForgetsOnlyThatHost() async {
    let store = InMemoryRTSPCooldownStore()
    await store.recordClosed(host: "192.0.2.10", at: Date(timeIntervalSince1970: 1_000))
    await store.recordClosed(host: "192.0.2.11", at: Date(timeIntervalSince1970: 2_000))
    await store.clear(host: "192.0.2.10")
    #expect(await store.lastClosed(host: "192.0.2.10") == nil)
    #expect(await store.lastClosed(host: "192.0.2.11") != nil)
    await store.clear(host: "192.0.2.99")  // unknown host: no effect
}

@Test func fileStoreClearPersistsAndKeepsOtherHosts() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-clear-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("cooldown.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = FileRTSPCooldownStore(url: url)
    await store.recordClosed(host: "192.0.2.10", at: Date(timeIntervalSince1970: 1_000))
    await store.recordClosed(host: "192.0.2.11", at: Date(timeIntervalSince1970: 2_000))
    await store.clear(host: "192.0.2.10")
    #expect(await store.lastClosed(host: "192.0.2.10") == nil)
    // A second instance on the same file (another process) sees the clear.
    let other = FileRTSPCooldownStore(url: url)
    #expect(await other.lastClosed(host: "192.0.2.10") == nil)
    #expect(await other.lastClosed(host: "192.0.2.11") != nil)
    // After a clear, an older close time can be recorded again.
    await store.recordClosed(host: "192.0.2.10", at: Date(timeIntervalSince1970: 500))
    #expect(await store.lastClosed(host: "192.0.2.10") == Date(timeIntervalSince1970: 500))
}

@Test func fileStoreClearWithNoFileIsHarmless() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-missing-\(UUID().uuidString).json")
    let store = FileRTSPCooldownStore(url: url)
    await store.clear(host: "192.0.2.10")
    #expect(await store.lastClosed(host: "192.0.2.10") == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
