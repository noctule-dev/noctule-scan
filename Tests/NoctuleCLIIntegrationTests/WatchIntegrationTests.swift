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
            Thread.sleep(forTimeInterval: 0.2)
            let peer: sockaddr_in? = lock.withLock {
                guard let subscriber, pushLimit.map({ pushesSent < $0 }) ?? true else { return nil }
                pushesSent += 1
                return subscriber
            }
            if let peer { send(update, to: peer) }
        }
    }
}

/// A loopback UDP port with nothing listening: bind an ephemeral port, then close it.
func deadPort() throws -> UInt16 {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(sock) }
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

private func run(_ arguments: [String], fake: FakeScanner, interruptAfter: Double?) throws -> (status: Int32, stdout: String, stderr: String, timedOut: Bool, seconds: Double) {
    try run(arguments, port: fake.port, interruptAfter: interruptAfter)
}

/// Runs `noctule` against 127.0.0.1:`port`, killing it if it hasn't exited 10 s after start
/// (plus `interruptAfter`).
private func run(_ arguments: [String], port: UInt16, interruptAfter: Double?) throws -> (status: Int32, stdout: String, stderr: String, timedOut: Bool, seconds: Double) {
    let process = Process()
    process.executableURL = try noctuleBinary()
    process.arguments = arguments + ["--host", "127.0.0.1", "--port", String(port)]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let start = Date()
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    if let interruptAfter {
        Thread.sleep(forTimeInterval: interruptAfter)
        kill(process.processIdentifier, SIGINT)
    }
    let exited = waitFor(10) { !process.isRunning }
    if !exited { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    let seconds = Date().timeIntervalSince(start)
    let data = out.fileHandleForReading.availableData
    let errData = err.fileHandleForReading.availableData
    return (process.terminationStatus, String(decoding: data, as: UTF8.self),
            String(decoding: errData, as: UTF8.self), !exited, seconds)
}

@Suite(.timeLimit(.minutes(1))) struct WatchIntegrationTests {
    @Test func sigintSendsPSIStopAndExits130() throws {
        let fake = try FakeScanner()
        defer { fake.stop() }
        let result = try run(["watch"], fake: fake, interruptAfter: 1.0)
        #expect(!result.timedOut)
        #expect(result.status == 130)
        _ = waitFor(2) { fake.received.contains("PSI,0") }
        let log = fake.received.filter { $0.hasPrefix("PSI") }
        #expect(log.first == "PSI,500")
        #expect(log.last == "PSI,0")
        #expect(result.stdout.contains("X / -"))
        #expect(!result.stderr.contains("ended after"))
        #expect(result.stderr.isEmpty)
    }

    @Test func countReachedSendsPSIStopAndExits0() throws {
        let fake = try FakeScanner()
        defer { fake.stop() }
        let result = try run(["watch", "--count", "3"], fake: fake, interruptAfter: nil)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        _ = waitFor(2) { fake.received.contains("PSI,0") }
        let log = fake.received.filter { $0.hasPrefix("PSI") }
        #expect(log.first == "PSI,500")
        #expect(log.last == "PSI,0")
        #expect(result.stdout.split(separator: "\n").count == 3)
    }

    @Test func unreachableScannerExitsNonZeroQuickly() throws {
        let port = try deadPort()
        let result = try run(["watch"], port: port, interruptAfter: nil)
        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(result.status != 130)
        #expect(result.seconds < 10)
        #expect(result.stderr.contains("127.0.0.1:\(port)"))
        #expect(result.stdout.isEmpty)
    }

    @Test func stalledPushesReportStallSendPSIStopAndExit1() throws {
        let fake = try FakeScanner(pushLimit: 2)
        defer { fake.stop() }
        let result = try run(["watch", "--count", "10"], fake: fake, interruptAfter: nil)
        #expect(!result.timedOut)
        #expect(result.status == 1)
        #expect(result.seconds < 10)
        #expect(result.stderr.contains("no PSI updates from 127.0.0.1:\(fake.port) for 5 s"))
        #expect(result.stdout.split(separator: "\n").count == 2)
        _ = waitFor(2) { fake.received.contains("PSI,0") }
        let log = fake.received.filter { $0.hasPrefix("PSI") }
        #expect(log.first == "PSI,500")
        #expect(log.last == "PSI,0")
        #expect(log.filter { $0 == "PSI,0" }.count == 1)
    }
}
