// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
@testable import NoctuleCLICore

private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

@Suite struct WatchLoopTests {
    @Test func deadlineIsAtLeastFiveSecondsOrThreeIntervals() {
        #expect(WatchLoop.deadline(forInterval: .milliseconds(500)) == .seconds(5))
        #expect(WatchLoop.deadline(forInterval: .milliseconds(1)) == .seconds(5))
        #expect(WatchLoop.deadline(forInterval: .seconds(3)) == .seconds(9))
        #expect(WatchLoop.deadline(forInterval: .milliseconds(1700)) == .milliseconds(5100))
    }

    @Test func stallMessageNamesHostPortAndSeconds() {
        #expect(WatchLoop.stallMessage(host: "127.0.0.1", port: 50536, deadline: .seconds(5))
            == "no PSI updates from 127.0.0.1:50536 for 5 s")
        #expect(WatchLoop.stallMessage(host: "h", port: 1, deadline: .milliseconds(5100))
            == "no PSI updates from h:1 for 5.1 s")
    }

    @Test func stopsWhenCountIsReached() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        for i in 0..<5 { continuation.yield(i) }
        let seen = Counter()
        let outcome = await WatchLoop.run(stream, count: 3, deadline: .seconds(2)) { _ in seen.increment() }
        #expect(outcome == .countReached)
        #expect(seen.count == 3)
    }

    @Test func reportsStreamEndingBeforeCount() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        continuation.yield(1); continuation.yield(2); continuation.finish()
        let seen = Counter()
        let outcome = await WatchLoop.run(stream, count: 5, deadline: .seconds(2)) { _ in seen.increment() }
        #expect(outcome == .streamEnded(updates: 2))
        #expect(seen.count == 2)
    }

    @Test func reportsStreamEndingWithNoCount() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        continuation.finish()
        let outcome = await WatchLoop.run(stream, count: nil, deadline: .seconds(2)) { _ in }
        #expect(outcome == .streamEnded(updates: 0))
    }

    @Test func stallsWhenUpdatesStopAndCancelsTheConsumer() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        let dropped = Counter()
        continuation.onTermination = { termination in
            if case .cancelled = termination { dropped.increment() }
        }
        continuation.yield(1); continuation.yield(2)
        let seen = Counter()
        let start = ContinuousClock.now
        let outcome = await WatchLoop.run(stream, count: 10, deadline: .milliseconds(200)) { _ in seen.increment() }
        let elapsed = ContinuousClock.now - start
        #expect(outcome == .stalled(updates: 2))
        #expect(seen.count == 2)
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(2))
        #expect(dropped.count == 1)
        continuation.finish()
    }

    @Test func stallsWithNoUpdatesAtAll() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        let start = ContinuousClock.now
        let outcome = await WatchLoop.run(stream, count: nil, deadline: .milliseconds(200)) { _ in }
        #expect(outcome == .stalled(updates: 0))
        #expect(ContinuousClock.now - start < .seconds(2))
        continuation.finish()
    }

    @Test func eachUpdateResetsTheDeadline() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        // 12 updates 50 ms apart take ~600 ms, past one 400 ms deadline, but no gap comes near it.
        let producer = Task {
            for i in 0..<12 {
                try? await Task.sleep(for: .milliseconds(50))
                continuation.yield(i)
            }
        }
        let seen = Counter()
        let outcome = await WatchLoop.run(stream, count: 12, deadline: .milliseconds(400)) { _ in seen.increment() }
        #expect(outcome == .countReached)
        #expect(seen.count == 12)
        producer.cancel()
        continuation.finish()
    }
}
