// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

// The tests in this target wait for tools, scripts and `noctule` without holding one of Swift
// concurrency's cooperative threads (IntegrationSupport.swift, "Waiting in these tests"). When they
// held them, the target froze for up to two minutes on the 3-core CI runner and its real-time tests
// failed together (LESSONS.md 2026-11-21).

@Suite(.timeLimit(.minutes(1))) struct CooperativePoolTests {
    /// How long each tool runs, and how late the test's own short sleep may end. A `run` that waited
    /// by blocking would hold every pool thread for a whole tool, so the sleep would end at least
    /// `toolSeconds` late; one that suspends leaves it late only by the machine's load, which was
    /// 0.46–1.55 s on the CI runner in the parallel step (runs 44950610736 to 44964839734), so the
    /// bound sits between, with about 3.5 s of room above the worst seen and 3 s below broken.
    static let toolSeconds = 8.0
    static let lateBound = Duration.seconds(5)

    /// More runs at once than the pool has threads (one per core), each `toolSeconds` long, leave
    /// the pool free: this test's own 50 ms sleep, begun while they start, ends on time.
    @Test func waitingForAToolLeavesThePoolFree() async throws {
        let runs = ProcessInfo.processInfo.activeProcessorCount + 1
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<runs {
                group.addTask { try await run(URL(fileURLWithPath: "/bin/sleep"), [String(Self.toolSeconds)]).status }
            }
            let asleep = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(50))
            let late = ContinuousClock.now - asleep - .milliseconds(50)
            print("CooperativePoolTests: a 50 ms sleep ended \(late) late while \(runs) tools ran")  // in CI logs, pass or fail
            #expect(late < Self.lateBound,
                    "a 50 ms sleep ended \(late) late while \(runs) tools of \(Self.toolSeconds) s ran (\(runs - 1) cores)")
            for try await status in group { #expect(status == 0) }
        }
    }

    /// A test whose time limit has fired is cancelled; its cleanup still waits for the tools it
    /// runs (an `hdiutil detach`, a mock's exit report) instead of killing them at once and
    /// reporting them stuck (review I1).
    @Test func aCancelledTestStillWaitsForItsTool() async throws {
        let cleanup = Task { () -> (status: Int32, seconds: Double) in
            try? await Task.sleep(for: .seconds(60))  // ends at the cancel below
            #expect(Task.isCancelled)
            let start = Date()
            let result = try await run(URL(fileURLWithPath: "/bin/sleep"), ["1"])
            return (result.status, Date().timeIntervalSince(start))
        }
        cleanup.cancel()
        let result = try await cleanup.value
        #expect(result.status == 0, "the tool was killed: status \(result.status)")
        #expect(result.seconds >= 0.9, "the wait ended after \(result.seconds) s, before the tool")
    }

    /// Text one of the checks below needs, a cheap filter before the expression.
    private static let tokens = ["waitUntilExit(", "readDataToEndOfFile(", ".readToEnd(", "readData(", "read(upToCount:",
                                 "availableData", "sleep(", "poll(", "waitpid(", "recv(", "recvfrom(", "accept(",
                                 "DispatchSemaphore(", "DispatchGroup(",
                                 ".wait()", ".wait(timeout:", ".sync(execute:", "RunLoop"]

    /// Whether a line of code (comments and strings taken out) holds a blocking call.
    static func blocks(_ code: String) -> Bool {
        guard tokens.contains(where: { code.contains($0) }) else { return false }
        // A declaration (`func accept(`) isn't a call.
        let code = code.contains("func ") ? code.replacing(/func\s+\w+\(/, with: "func (") : code
        return code.contains(blocking)
    }

    /// The checks below, in a line of code, with comments and string literals taken out. A
    /// `sync { }` on a serial queue used as a lock (the mocks' `core.sync`) is a short critical
    /// section, not a wait, and isn't flagged; `sync(execute:)`, a semaphore's or group's
    /// `wait()`, and a run loop's `run` are.
    private static var blocking: Regex<AnyRegexOutput> { try! Regex(
        #"waitUntilExit\(|readDataToEndOfFile\(|\.readToEnd\(|readData\(|read\(upToCount:|availableData\b|"#
        + #"Thread\.sleep\(|(^|[^.\w]|Darwin\.)(usleep|sleep|nanosleep|poll|waitpid|recv|recvfrom|accept)\(|DispatchSemaphore\(|"#
        + #"DispatchGroup\(|\.wait\(\)|\.wait\(timeout:|\.sync\(execute:|RunLoop\.(current|main)\.run"#) }

    /// Strips string literals (single-line, raw and multi-line) and comments (line and block)
    /// from Swift source, line by line, keeping line numbers.
    static func codeLines(_ source: String) -> [String] {
        var inBlockComment = false, inMultilineString = false
        return source.components(separatedBy: "\n").map { line in
            // Fast paths (the scan runs on a cooperative thread too): a line with nothing to strip,
            // or one wholly inside a block comment or a multi-line string.
            if inBlockComment, !line.contains("*/") { return "" }
            if inMultilineString, !line.contains("\"\"\"") { return "" }
            if !inBlockComment, !inMultilineString, !line.contains(where: { $0 == "\"" || $0 == "/" || $0 == "#" }) {
                return line
            }
            var code = ""
            var rest = Substring(line)
            while !rest.isEmpty {
                if inBlockComment {
                    guard let end = rest.range(of: "*/") else { rest = ""; break }
                    rest = rest[end.upperBound...]; inBlockComment = false
                } else if inMultilineString {
                    guard let end = rest.range(of: "\"\"\"") else { rest = ""; break }
                    rest = rest[end.upperBound...]; inMultilineString = false
                } else if rest.hasPrefix("//") {
                    rest = ""
                } else if rest.hasPrefix("/*") {
                    rest = rest.dropFirst(2); inBlockComment = true
                } else if rest.hasPrefix("\"\"\"") || rest.hasPrefix("#\"\"\"") {
                    rest = rest.drop { $0 == "#" }.dropFirst(3); inMultilineString = true
                } else if rest.hasPrefix("#\"") {
                    guard let end = rest.dropFirst(2).range(of: "\"#") else { rest = ""; break }
                    rest = rest[end.upperBound...]; code += "\"\""
                } else if rest.hasPrefix("\"") {
                    var index = rest.index(after: rest.startIndex)
                    while index < rest.endIndex, rest[index] != "\"" {
                        if rest[index] == "\\" { index = rest.index(after: index) }
                        if index < rest.endIndex { index = rest.index(after: index) }
                    }
                    rest = index < rest.endIndex ? rest[rest.index(after: index)...] : ""
                    code += "\"\""
                } else {
                    code.append(rest.removeFirst())
                }
            }
            return code
        }
    }

    /// The marker that allows a blocking call on its line: the call runs off the cooperative pool
    /// (on a `Thread` of its own, a dispatch queue, a pipe's readability handler) or blocks only
    /// for an instant by design. Put it on the line itself, with a word on why.
    static let allowMarker = "// off the cooperative pool"

    /// No test, in any test target, waits by blocking its thread: Swift Testing runs them all on
    /// the cooperative pool (one thread per core, three on the CI runner), and one test's blocking
    /// wait stalls every other test and fake in its process (LESSONS.md 2026-11-21, 2026-11-22).
    /// A deliberate blocking call carries `allowMarker` on its line.
    @Test func noTestWaitsByBlockingItsThread() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        let walker = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        let files = walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "CooperativePoolTests.swift" }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.components(separatedBy: "\n")
            for (index, code) in Self.codeLines(source).enumerated() where Self.blocks(code) {
                guard !lines[index].contains(Self.allowMarker) else { continue }
                let target = file.deletingLastPathComponent().lastPathComponent
                offenders.append("\(target)/\(file.lastPathComponent):\(index + 1): \(lines[index].trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(files.count > 50, "found only \(files.count) test files under \(tests.path)")
        #expect(offenders.isEmpty, "blocking waits on a cooperative thread:\n\(offenders.joined(separator: "\n"))")
    }

    /// The scan's own cases: it sees blocking calls in code and not in comments or strings.
    @Test func theScanSeesCodeOnly() {
        let flagged = [
            "_ = poll(nil, 0, 20)", "usleep(20_000)", "sleep(1)", "nanosleep(&t, nil)", "p.waitUntilExit()",
            "let d = h.availableData", "Thread.sleep(forTimeInterval: 1)", "s.wait()", "g.wait(timeout: .now() + 1)",
            "waitpid(pid, &s, 0)", "let all = try h.readToEnd()",
            "_ = Darwin.poll(&d, 1, 10)", "Darwin.usleep(5)", "q.sync(execute: work)", "RunLoop.current.run(until: d)",
            "let n = recv(fd, &b, 64, 0)", "let c = Darwin.accept(fd, nil, nil)",
        ]
        let clean = [
            "try await Task.sleep(for: .seconds(1))", "let x = 1  // usleep(1)", "/* poll( */ let y = 2",
            #"let s = "proc.wait()""#, ##"let r = #"sleep(1)"#"##, "func snooze() {}", "let asleep = now",
            "core.sync { $0.log }", "state.sync(with: x)", "case .wait(let remaining):", "return .wait(.seconds(7))",
            "await Self.wait(up: limit) { done }", "func readToEnd(_ fd: Int32) async -> Data",
            "func accept(within limit: Duration) async -> Int32? {",
        ]
        for line in flagged { #expect(Self.blocks(Self.codeLines(line)[0]), "missed: \(line)") }
        for line in clean { #expect(!Self.blocks(Self.codeLines(line)[0]), "flagged: \(line)") }
        let multiline = Self.codeLines("let s = \"\"\"\nproc.wait()\n\"\"\"\n/*\nusleep(1)\n*/\nusleep(1)")
        #expect(multiline.map(Self.blocks) == [false, false, false, false, false, false, true])
    }
}
