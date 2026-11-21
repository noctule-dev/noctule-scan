// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import NoctuleKit
import Testing
@testable import NoctuleMockScanner

struct TimedOut: Error {}

/// Runs `body`, failing with `TimedOut` after `limit`, so no test can hang.
func within<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimedOut()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimedOut() }
        return first
    }
}

/// Polls `condition` every 10 ms until it holds, or throws `TimedOut` after `limit`.
func eventually(_ limit: Duration = .seconds(3), _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await within(limit) {
        while !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
    }
}

/// One raw RTSP exchange over a plain blocking BSD socket (2 s receive timeout), for checking the
/// mock's exact reply bytes and for misbehaving on purpose (e.g. closing without TEARDOWN).
final class RawRTSP {
    let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
    }

    /// Sends `request` and returns the full reply (head and body), or nil on timeout or close.
    func exchange(_ request: String) -> String? {
        let bytes = Array(request.utf8)
        guard send(fd, bytes, bytes.count, 0) == bytes.count else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<end.upperBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if data.count - end.upperBound >= length { return String(decoding: data, as: UTF8.self) }
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    /// Sends `request` without waiting for a reply.
    func sendOnly(_ request: String) {
        let bytes = Array(request.utf8)
        _ = Darwin.send(fd, bytes, bytes.count, 0)
    }

    func close() { Darwin.close(fd) }
}

/// Header names of an RTSP reply, in order.
func headerNames(_ reply: String) -> [String] {
    let head = reply.components(separatedBy: "\r\n\r\n").first ?? ""
    return head.components(separatedBy: "\r\n").dropFirst().compactMap { line in
        line.firstIndex(of: ":").map { String(line[..<$0]) }
    }
}

/// The value of header `name` (case-insensitive) in an RTSP reply.
func header(_ name: String, in reply: String) -> String? {
    let head = reply.components(separatedBy: "\r\n\r\n").first ?? ""
    for line in head.components(separatedBy: "\r\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        if line[..<colon].lowercased() == name.lowercased() {
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

/// Starts a mock on a stepped clock (at `time`), connects a `ScannerClient` over `UDPTransport`,
/// runs `body` (bounded by `limit`), and in every path disconnects the client and stops the mock.
/// Fails the test if the mock saw an RTSP session without a TEARDOWN.
func withMock(
    at time: Double = 0, scenario: MockScenario = .default, faults: MockFaults = .none,
    replyDelays: [String: Duration] = [:], rebootDuration: Duration = .seconds(10), commandTimeout: Duration = .milliseconds(700),
    limit: Duration = .seconds(10),
    _ body: @escaping @Sendable (MockSDS200, ScannerClient) async throws -> Void
) async throws {
    let options = MockSDS200.Options(clock: .stepped(at: time), rebootDuration: rebootDuration, replyDelays: replyDelays)
    let mock = MockSDS200(scenario: scenario, faults: faults, options: options)
    let ports = try await mock.start()
    let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort),
                               commandTimeout: commandTimeout)
    var failure: (any Error)?
    do {
        try await client.connect()
        try await within(limit) { try await body(mock, client) }
    } catch {
        failure = error
    }
    await client.disconnect()
    await mock.stop()
    #expect(await mock.leakedSessions.isEmpty)
    if let failure { throw failure }
}
