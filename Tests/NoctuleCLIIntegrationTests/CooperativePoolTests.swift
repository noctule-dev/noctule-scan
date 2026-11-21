// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

// The tests in this target wait for tools, scripts and `noctule` without holding one of Swift
// concurrency's cooperative threads (IntegrationSupport.swift, "Waiting in these tests"). When they
// held them, the target froze for up to two minutes on the 3-core CI runner and its real-time tests
// failed together (LESSONS.md 2026-11-21).

@Suite(.timeLimit(.minutes(1))) struct CooperativePoolTests {
    /// More runs at once than the pool has threads (one per core), each two seconds long, leave the
    /// pool free: this test's own 50 ms sleep, begun while they start, ends on time. A `run` that
    /// waited by blocking (`Thread.sleep`, `waitUntilExit()`) would take every thread for the two
    /// seconds, and the sleep would end only after them.
    @Test func waitingForAToolLeavesThePoolFree() async throws {
        let runs = ProcessInfo.processInfo.activeProcessorCount + 1
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<runs {
                group.addTask { try await run(URL(fileURLWithPath: "/bin/sleep"), ["2"]).status }
            }
            let asleep = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(50))
            let late = ContinuousClock.now - asleep - .milliseconds(50)
            #expect(late < .seconds(1), "a 50 ms sleep ended \(late) late while \(runs) tools ran (\(runs - 1) cores)")
            for try await status in group { #expect(status == 0) }
        }
    }

    /// No test here waits by blocking its thread. A blocking call may stay only on a thread of its
    /// own (a fake's loop, a dispatch queue), marked on its line with `// off the cooperative pool`.
    @Test func noTestWaitsByBlockingItsThread() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let blocking = ["waitUntilExit(", "readDataToEndOfFile(", "readToEnd(", "Thread.sleep(", "usleep(",
                        "DispatchSemaphore(", "DispatchGroup(", ".wait("]
        var offenders: [String] = []
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "CooperativePoolTests.swift" }
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !line.contains("// off the cooperative pool") else { continue }
                if blocking.contains(where: { code.contains($0) }) {
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(code)")
                }
            }
        }
        #expect(files.count > 10, "found only \(files.count) test files in \(directory.path)")
        #expect(offenders.isEmpty, "blocking waits on a cooperative thread:\n\(offenders.joined(separator: "\n"))")
    }
}
