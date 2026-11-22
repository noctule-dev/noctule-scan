// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
import NoctuleKit
@testable import NoctuleAppCore

private actor Probe {
    var sent: [FrontPanelKey] = []
    var active = 0
    var maxActive = 0
    var gate: CheckedContinuation<Void, Never>?
    var blocking = false
    var entered: CheckedContinuation<Void, Never>?
    var didEnter = false

    func block() { blocking = true }
    func release() { blocking = false; gate?.resume(); gate = nil }
    func waitEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entered = $0 }
    }
    func run(_ k: FrontPanelKey) async {
        active += 1; maxActive = max(maxActive, active)
        didEnter = true; entered?.resume(); entered = nil
        if blocking { await withCheckedContinuation { gate = $0 } }
        else { await Task.yield() }
        sent.append(k)
        active -= 1
    }
}

private struct Boom: Error {}

@Suite(.timeLimit(.minutes(3))) struct KeyPressQueueTests {
    @Test func queueSendsInOrderOneAtATime() async throws {
        let p = Probe()
        let q = KeyPressQueue { await p.run($0) }
        let keys: [FrontPanelKey] = [.digit1, .digit2, .digit3, .menu, .avoid]
        for k in keys { #expect(await q.enqueue(k)) }
        await q.drain()
        #expect(await p.sent == keys)
        #expect(await p.maxActive == 1)
    }

    @Test func queueDropsBeyondEight() async throws {
        let p = Probe()
        await p.block()
        let q = KeyPressQueue { await p.run($0) }
        var accepted = 0, dropped = 0
        for _ in 0..<10 { if await q.enqueue(.scrollRight) { accepted += 1 } else { dropped += 1 } }
        #expect(accepted == 8)
        #expect(dropped == 2)
        await p.release()
        await q.drain()
        #expect(await p.sent.count == 8)
        // Room again after draining.
        #expect(await q.enqueue(.menu))
        await q.drain()
    }

    @Test func queueSurvivesSendError() async throws {
        let p = Probe()
        let q = KeyPressQueue { k in
            if k == .digit2 { throw Boom() }
            await p.run(k)
        }
        for k: FrontPanelKey in [.digit1, .digit2, .digit3] { #expect(await q.enqueue(k)) }
        await q.drain()
        #expect(await p.sent == [.digit1, .digit3])
        #expect(await q.lastError == nil)  // cleared by the later success
        #expect(await q.enqueue(.digit2))
        await q.drain()
        #expect(try #require(await q.lastError).contains("Boom"))
    }

    @Test func drainOnEmptyQueueReturns() async {
        let q = KeyPressQueue { _ in }
        await q.drain()
    }
}
