// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization
import Testing
import NoctuleMockScanner

/// Holds every cooperative thread of the process for a moment, as a slow runner's busy test
/// process does, and lets them go together. Briefly: spinners that ran for seconds starved the rest
/// of the process under background priority, the dispatch thread meant to release them included
/// (local sweep).
private final class PoolHog: Sendable {
    private let running = Atomic(0)
    private let released = Atomic(false)
    let deadline: ContinuousClock.Instant

    init(holdingFor limit: Duration) { deadline = .now + limit }

    /// Spins (holding its cooperative thread) until released or the deadline.
    func spin() {
        running.add(1, ordering: .sequentiallyConsistent)
        while !released.load(ordering: .sequentiallyConsistent), ContinuousClock.now < deadline {}
    }

    /// On a dispatch thread: whether `count` spinners are running within `seconds`.
    func waitUntilRunning(_ count: Int, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while running.load(ordering: .sequentiallyConsistent) < count, Date() < deadline {
            usleep(1_000)  // off the cooperative pool: a dispatch thread, by design (it is what isn't held)
        }
        return running.load(ordering: .sequentiallyConsistent) >= count
    }

    func release() { released.store(true, ordering: .sequentiallyConsistent) }
}

@Suite(.timeLimit(.minutes(1))) struct FakeRTSPServerPoolTests {
    /// The in-process fake answers on its own queue, never waiting for a cooperative thread. When it
    /// took three pool hops per request, a slow runner's busy integration process held its OPTIONS
    /// reply past `noctule listen`'s 3 s request timeout (`ListenIntegrationTests`, flake hunt run
    /// 44979282952: "the scanner's audio server didn't answer OPTIONS").
    ///
    /// Every cooperative thread is held for at most 0.6 s. The answer must come while they are still
    /// held; when the spinners can't all start at once (other tests hold threads), or the request
    /// can't go out with time to spare, nothing is judged.
    @Test func answersWhileEveryCooperativeThreadIsBusy() async throws {
        let server = FakeRTSPServer()
        let port = try await server.start()
        let strict = ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1"
        let width = strict ? 1 : ProcessInfo.processInfo.activeProcessorCount
        let hog = PoolHog(holdingFor: .milliseconds(600))
        let raw = try RawRTSP(port: port)
        let (judged, reply, inTime): (Bool, String?, Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                defer { hog.release() }
                guard hog.waitUntilRunning(width, within: 0.2), ContinuousClock.now.duration(to: hog.deadline) > .milliseconds(300) else {
                    continuation.resume(returning: (false, nil, false))
                    return
                }
                let reply = raw.blockingExchange("OPTIONS rtsp://127.0.0.1:\(port)/ RTSP/1.0\r\nCSeq: 1\r\n\r\n")
                continuation.resume(returning: (true, reply, ContinuousClock.now < hog.deadline))
            }
            for _ in 0..<width { Task.detached { hog.spin() } }
        }
        raw.close()
        await server.stop()
        guard judged else { print("answersWhileEveryCooperativeThreadIsBusy: the pool wasn't held in time; not judged"); return }
        #expect(reply?.hasPrefix("RTSP/1.0 200") == true, "\(reply ?? "no answer within 2 s")")
        #expect(inTime, "answered only after the cooperative threads were let go")
    }
}
