// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Turns the byte stream from a serial scanner into `ScannerResponse` values. Serial has no
/// datagram boundaries, so replies are cut into lines at `\r` or `\n`, and an XML document
/// (opened by a `NAME,<XML>,` line) is collected until its root element closes. A document with a
/// `<Footer>` is one page of a longer reply (every `GLT` reply over serial, seen on the SDS150 and the
/// SDS100 on 2026-11-19: a long one in several documents back to back, each with its own `GLT,<XML>,`
/// line), put together with the rest by number (`XMLFragmentSequences`, as over the network) and
/// handed on whole once its last page (`EOT="1"`) arrives; a document with none (`GSI`, `PSI`, `MSI`)
/// is handed on as it is. Never throws: anything malformed, stale, or oversized is dropped and the
/// assembler goes on with the next line.
public struct SerialResponseAssembler {
    private struct Document {
        var command: String
        var text = ""
        var bytes = 0
        var lines = 0
        var started: ContinuousClock.Instant
        var rootName: String?
        /// Set when the document is too big or has a bad line: its lines are skipped up to its end.
        var discarding = false
    }

    private static let xmlMarker = ",<XML>,"

    private let now: @Sendable () -> ContinuousClock.Instant
    private let maxDocumentAge: Duration
    private let maxDocumentBytes: Int
    private let maxLineBytes: Int
    private var line: [UInt8] = []
    private var lineTooLong = false
    private var document: Document?
    private var pages: XMLFragmentSequences

    public init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        maxDocumentAge: Duration = .seconds(10),
        maxDocumentBytes: Int = 4_194_304,
        maxLineBytes: Int = 65_536,
        maxFragments: Int = 256
    ) {
        self.now = now
        self.maxDocumentAge = maxDocumentAge
        self.maxDocumentBytes = maxDocumentBytes
        self.maxLineBytes = maxLineBytes
        pages = XMLFragmentSequences(maxAge: maxDocumentAge, maxBytes: maxDocumentBytes, maxFragments: maxFragments)
    }

    /// Feeds the next bytes read from the port, split anywhere, and returns the responses
    /// they complete.
    public mutating func ingest(_ bytes: Data) -> [ScannerResponse] {
        let current = now()
        if let open = document, current - open.started > maxDocumentAge {
            CommandTrace.log("serial: dropped \(open.command) document: older than \(maxDocumentAge)")
            document = nil
            dropPages(of: open.command, "older than \(maxDocumentAge)")
        }
        for command in pages.dropExpired(at: current) {
            CommandTrace.log("serial: dropped \(command) pages: older than \(maxDocumentAge)")
        }

        var responses: [ScannerResponse] = []
        for byte in bytes {
            if byte == 0x0D || byte == 0x0A {
                if !lineTooLong, !line.isEmpty {
                    handle(String(scannerBytes: Data(line)), at: current, into: &responses)
                }
                line.removeAll(keepingCapacity: true)
                lineTooLong = false
            } else if !lineTooLong {
                line.append(byte)
                if line.count > maxLineBytes {
                    lineTooLong = true
                    line.removeAll(keepingCapacity: true)
                    document?.discarding = true
                    CommandTrace.log("serial: line too long (over \(maxLineBytes) bytes)\(document.map { " in a \($0.command) document" } ?? "")")
                }
            }
        }
        return responses
    }

    private mutating func handle(_ raw: String, at current: ContinuousClock.Instant, into responses: inout [ScannerResponse]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let marker = text.range(of: Self.xmlMarker, options: .backwards), marker.upperBound == text.endIndex {
            let command = text[..<marker.lowerBound].uppercased()
            if !command.isEmpty, !command.contains("<") {
                if let open = document {
                    CommandTrace.log("serial: dropped open \(open.command) document (\(open.bytes) bytes, \(open.lines) lines) for a new \(command) document")
                    dropPages(of: open.command, "a page cut off by a new \(command) document")
                }
                document = Document(command: command, started: current)
                return
            }
        }
        guard var open = document else {
            if let response = ResponseLineParser.parse(text) { responses.append(response) }
            return
        }
        document = nil

        open.bytes += text.utf8.count + 1
        open.lines += 1
        if open.bytes > maxDocumentBytes {
            if !open.discarding { CommandTrace.log("serial: dropped \(open.command) document: too big (over \(maxDocumentBytes) bytes)") }
            open.discarding = true
            open.text = ""
        }
        if !open.discarding { open.text += text + "\n" }

        var isEnd = false
        if let root = open.rootName {
            isEnd = text.hasSuffix("</\(root)>")
        } else if text.hasPrefix("<"), !text.hasPrefix("<?"), !text.hasPrefix("<!") {
            let name = text.dropFirst().prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }
            open.rootName = String(name)
            isEnd = text.hasSuffix("/>") || text.hasSuffix("</\(name)>")
        }

        guard isEnd else {
            document = open
            return
        }
        guard !open.discarding else {
            dropPages(of: open.command, "a page too big or with a line too long")
            return
        }
        guard let root = try? XMLNode.parse(Data(open.text.utf8)) else {
            CommandTrace.log("serial: dropped \(open.command) document: XML didn't parse (\(open.bytes) bytes)")
            dropPages(of: open.command, "a page that didn't parse")
            return
        }
        switch pages.add(root, bytes: open.bytes, for: open.command, at: current) {
        case .document(let whole): responses.append(.xml(command: open.command, root: whole))
        case .pending: break
        case .dropped(let reason): CommandTrace.log("serial: dropped \(open.command) pages: \(reason)")
        }
    }

    /// Drops `command`'s open page sequence, if any, because a document of that command was lost here (the rest
    /// of its reply can't be whole), and says why.
    private mutating func dropPages(of command: String, _ reason: String) {
        if pages.drop(command) { CommandTrace.log("serial: dropped \(command) pages: \(reason)") }
    }
}
