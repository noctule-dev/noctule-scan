// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public struct RTSPHeader: Sendable, Equatable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct RTSPRequest: Sendable, Equatable {
    public var method: String
    public var url: String
    public var cseq: Int
    public var headers: [RTSPHeader]

    public init(method: String, url: String, cseq: Int, headers: [RTSPHeader] = []) {
        self.method = method; self.url = url; self.cseq = cseq; self.headers = headers
    }

    public init(method: String, url: String, cseq: Int, headers: [(String, String)]) {
        self.init(method: method, url: url, cseq: cseq,
                  headers: headers.map { RTSPHeader(name: $0.0, value: $0.1) })
    }

    public var encoded: Data {
        // CSeq, User-Agent, then the method's own headers: the order of the exchange that works
        // on the SDS200 (protocol notes §6).
        var text = "\(method) \(url) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: NoctuleScan\r\n"
        for h in headers { text += "\(h.name): \(h.value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }
}

public struct RTSPSession: Sendable, Equatable {
    public var id: String
    public var timeoutSeconds: Int?
    public init(id: String, timeoutSeconds: Int?) { self.id = id; self.timeoutSeconds = timeoutSeconds }
}

public struct RTSPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var reason: String
    /// Keys are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, reason: String, headers: [String: String], body: Data) {
        self.statusCode = statusCode; self.reason = reason; self.headers = headers; self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var cseq: Int? { header("cseq").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// Parses `Session: 1234;timeout=60`.
    public var session: RTSPSession? {
        guard let raw = header("session") else { return nil }
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        let id = parts[0].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        var timeout: Int?
        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "timeout" {
                timeout = Int(kv[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return RTSPSession(id: id, timeoutSeconds: timeout)
    }
}

public struct RTSPResponseParser {
    public private(set) var protocolError: String?
    private var buffer = Data()
    private static let terminator = Data("\r\n\r\n".utf8)

    public init() {}

    /// Appends `data` and returns every complete response now available.
    /// After a malformed status line, `protocolError` is set and parsing stops.
    public mutating func feed(_ data: Data) -> [RTSPResponse] {
        guard protocolError == nil else { return [] }
        buffer.append(data)
        var out: [RTSPResponse] = []
        while let range = buffer.range(of: Self.terminator) {
            let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst()
            let sp = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard sp.count >= 2, sp[0].hasPrefix("RTSP/"), let code = Int(sp[1]) else {
                protocolError = "malformed status line: \(statusLine)"
                buffer.removeAll()
                return out
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
            let length = headers["content-length"].flatMap { Int($0) } ?? 0
            let bodyStart = range.upperBound
            guard length >= 0 else {
                protocolError = "invalid Content-Length"
                buffer.removeAll()
                return out
            }
            guard buffer.endIndex - bodyStart >= length else { break }
            let body = Data(buffer[bodyStart..<(bodyStart + length)])
            buffer = Data(buffer[(bodyStart + length)...])
            out.append(RTSPResponse(statusCode: code, reason: sp.count > 2 ? String(sp[2]) : "",
                                    headers: headers, body: body))
        }
        return out
    }
}

public enum RTSPError: Error, Equatable {
    case malformed(String)
    case unexpectedStatus(Int, String)
    case cseqMismatch(expected: Int, got: Int?)
    case noSession
    case timeout(method: String)
    case closed
    /// The request was abandoned because `RTSPClient.teardown()` pre-empted it.
    case preempted
    /// `connect()` refused to open a connection: the last one to this server closed less than
    /// the client's `cooldownPolicy` requires after it. `remaining` is how much longer to wait.
    case cooldown(remaining: Duration)
    /// `connect()` refused to open a connection because the cooldown store couldn't lock its
    /// record (so it can't tell whether connecting is safe). The reason says why.
    case cooldownStoreUnavailable(String)
}
