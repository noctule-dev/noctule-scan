// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

/// A connection to a scanner that sends encoded commands and delivers fully assembled responses.
///
/// Contract every implementation must honor:
/// - `send(_:)` returns promptly (it hands the bytes off and doesn't wait for a reply), or, if
///   it can block, it honors task cancellation by throwing `CancellationError` promptly.
/// - `responses` is a fresh stream for each `open()`. Read it after `open()` returns; a stream
///   obtained earlier belongs to the previous connection.
/// - `responses` delivers every response the scanner sends, solicited or not, in arrival order,
///   and finishes when the transport is closed or fails terminally. Transient errors (a lost
///   datagram, an ICMP blip) don't finish it.
/// - A closed transport can be opened again.
public protocol ScannerTransport: Sendable {
    func open() async throws
    func send(_ command: ScannerCommand) async throws
    var responses: AsyncStream<ScannerResponse> { get }
    func close() async
}
