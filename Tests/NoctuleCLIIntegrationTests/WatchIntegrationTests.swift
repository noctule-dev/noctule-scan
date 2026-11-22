// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Testing

/// A loopback UDP fake scanner (BSD sockets on a background thread). Logs every datagram,
/// acknowledges PSI, and pushes a GSI-style update every 200 ms until `PSI,0`, or until it has
/// sent `pushLimit` updates, after which it goes quiet (still logging and acknowledging).
private final class FakeScanner: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var log: [String] = []
    private var subscriber: sockaddr_in?
    private var running = true
    private let pushLimit: Int?
    private var pushesSent = 0

    init(pushLimit: Int? = nil) throws {
        self.pushLimit = pushLimit
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        fd = sock
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Threads of its own, never the cooperative pool's: their blocking waits stall no test.
        Thread.detachNewThread { [self] in receiveLoop() }
        Thread.detachNewThread { [self] in pushLoop() }
    }

    var received: [String] { lock.withLock { log } }

    func stop() {
        lock.withLock { running = false }
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func send(_ text: String, to peer: sockaddr_in) {
        var peer = peer
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 65535)
        while isRunning {
            var peer = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLen)
                }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buffer[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lock.withLock {
                log.append(text)
                if text.hasPrefix("PSI,") { subscriber = text == "PSI,0" ? nil : peer }
            }
            send(text.split(separator: ",").first.map { "\($0),OK\r" } ?? "", to: peer)
        }
        close(fd)
    }

    private func pushLoop() {
        let update = "PSI,<XML>,\r\n<ScannerInfo Mode=\"Trunk Scan\"><System Name=\"X\"/></ScannerInfo>"
        while isRunning {
            Thread.sleep(forTimeInterval: 0.2)  // off the cooperative pool: its own thread
            let peer: sockaddr_in? = lock.withLock {
                guard let subscriber, pushLimit.map({ pushesSent < $0 }) ?? true else { return nil }
                pushesSent += 1
                return subscriber
            }
            if let peer { send(update, to: peer) }
        }
    }
}

/// A loopback UDP port that never answers: a socket bound to it and held, never read, until the
/// test process exits. Binding a port and closing it again (as this helper used to) left the port
/// free for a mock starting at the same moment to bind and answer: CI run 44958491347 saw
/// `StationEditorModelTests.testConnectionNoAnswer` (in another target) get `.ok(SDS200)` from such
/// a port; here the mock scanners are launched concurrently too. A
/// datagram to a held port is queued and ignored, so a request times out, as it would at a closed
/// port (where an ICMP refusal also ends in a timeout).
func silentUDPPort() throws -> UInt16 {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)  // held until the process exits: see above
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
    }
    return UInt16(bigEndian: addr.sin_port)
}

private func run(_ arguments: [String], fake: FakeScanner, interruptOnFirstUpdate: Bool) async throws -> (status: Int32, stdout: String, stderr: String, timedOut: Bool, seconds: Double) {
    try await run(arguments, port: fake.port, interruptOnFirstUpdate: interruptOnFirstUpdate)
}

/// Runs `noctule` against 127.0.0.1:`port`, killing it if it hasn't exited 10 s after start (or
/// after its interrupt). `interruptOnFirstUpdate` sends SIGINT once the first update is printed
/// (waiting at most 10 s), not after a fixed time, which a busy machine can outlast. Every wait
/// suspends (IntegrationSupport.swift, "Waiting in these tests").
private func run(_ arguments: [String], port: UInt16, interruptOnFirstUpdate: Bool = false) async throws -> (status: Int32, stdout: String, stderr: String, timedOut: Bool, seconds: Double) {
    let start = Date()
    let process = try Subprocess(try noctuleBinary(), arguments + ["--host", "127.0.0.1", "--port", String(port)], environment: noctuleTestEnvironment)
    if interruptOnFirstUpdate {
        _ = await process.waitForOutput(within: 10) { $0.contains("\n") }
        process.interrupt()
    }
    let exited = await process.waitForExit(within: 10)
    process.kill()
    let result = await process.finish()
    let seconds = Date().timeIntervalSince(start)
    return (result.status, result.stdout, result.stderr, !exited, seconds)
}

@Suite(.timeLimit(.minutes(1))) struct WatchIntegrationTests {
    @Test func sigintSendsPSIStopAndExits130() async throws {
        let fake = try FakeScanner()
        defer { fake.stop() }
        let result = try await run(["watch"], fake: fake, interruptOnFirstUpdate: true)
        #expect(!result.timedOut)
        #expect(result.status == 130)
        _ = await waitFor(2) { fake.received.contains("PSI,0") }
        let log = fake.received.filter { $0.hasPrefix("PSI") }
        #expect(log.first == "PSI,500")
        #expect(log.last == "PSI,0")
        #expect(result.stdout.contains("X / -"))
        #expect(!result.stderr.contains("ended after"))
        #expect(result.stderr.isEmpty)
    }

    @Test func countReachedSendsPSIStopAndExits0() async throws {
        let fake = try FakeScanner()
        defer { fake.stop() }
        let result = try await run(["watch", "--count", "3"], fake: fake, interruptOnFirstUpdate: false)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        _ = await waitFor(2) { fake.received.contains("PSI,0") }
        let log = fake.received.filter { $0.hasPrefix("PSI") }
        #expect(log.first == "PSI,500")
        #expect(log.last == "PSI,0")
        #expect(result.stdout.split(separator: "\n").count == 3)
    }

    @Test func unreachableScannerExitsNonZeroQuickly() async throws {
        let port = try silentUDPPort()
        let result = try await run(["watch"], port: port)
        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(result.status != 130)
        #expect(result.seconds < 10)
        #expect(result.stderr.contains("127.0.0.1:\(port)"))
        #expect(result.stdout.isEmpty)
    }

    @Test func stalledPushesReportStallSendPSIStopAndExit1() async throws {
        let fake = try FakeScanner(pushLimit: 2)
        defer { fake.stop() }
        let result = try await run(["watch", "--count", "10"], fake: fake, interruptOnFirstUpdate: false)
        #expect(!result.timedOut)
        #expect(result.status == 1)
        #expect(result.seconds < 10)
        #expect(result.stderr.contains("no PSI updates from 127.0.0.1:\(fake.port) for 5 s"))
        #expect(result.stdout.split(separator: "\n").count == 2)
        _ = await waitFor(2) { fake.received.contains("PSI,0") }
        let log = fake.received.filter { $0.hasPrefix("PSI") }
        #expect(log.first == "PSI,500")
        #expect(log.last == "PSI,0")
        #expect(log.filter { $0 == "PSI,0" }.count == 1)
    }
}
