// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization
import Testing
import NoctuleMockScanner

/// Holds every cooperative thread of the process for a moment, as a slow runner's busy test
/// process does, and lets them go together.
private final class PoolHog: Sendable {
    private let running = Atomic(0)
    private let released = Atomic(false)

    /// Spins (holding its cooperative thread) until released, for at most `limit`.
    func spin(upTo limit: Duration) {
        running.add(1, ordering: .sequentiallyConsistent)
        let deadline = ContinuousClock.now + limit
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
    @Test func answersWhileEveryCooperativeThreadIsBusy() async throws {
        let server = FakeRTSPServer()
        let port = try await server.start()
        let strict = ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1"
        let width = strict ? 1 : ProcessInfo.processInfo.activeProcessorCount
        let hog = PoolHog()
        let (held, reply): (Bool, String?) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let held = hog.waitUntilRunning(width, within: 2)
                // RawRTSP gives up after 2 s without an answer.
                let reply = held ? (try? RawRTSP(port: port))?.blockingExchange(
                    "OPTIONS rtsp://127.0.0.1:\(port)/ RTSP/1.0\r\nCSeq: 1\r\n\r\n") : nil
                hog.release()
                continuation.resume(returning: (held, reply))
            }
            for _ in 0..<width { Task.detached { hog.spin(upTo: .seconds(5)) } }
        }
        await server.stop()
        // Other tests in this process may hold threads too, so the spinners can't always all start;
        // then nothing is judged.
        guard held else { print("answersWhileEveryCooperativeThreadIsBusy: the pool wasn't held; not judged"); return }
        #expect(reply?.hasPrefix("RTSP/1.0 200") == true, "\(reply ?? "no answer within 2 s")")
    }
}
