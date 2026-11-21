// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import Synchronization

public enum SimulatedScannerTransportError: Error, Equatable {
    case notOpen
}

/// An in-memory scanner for tests. Each sent command is recorded and answered by `reply`.
///
/// Replies and `emit(_:)` responses go through one FIFO pump task, never from inside `send`,
/// so they arrive asynchronously (possibly before or after `send` returns to its caller, as on
/// a real network) and always in order. Each `open()` starts a fresh `responses` stream, so a
/// closed transport can be reopened.
public actor SimulatedScannerTransport: ScannerTransport {
    private nonisolated let currentResponses: Mutex<AsyncStream<ScannerResponse>>
    private var outbox: AsyncStream<[ScannerResponse]>.Continuation?
    private let reply: @Sendable (ScannerCommand) -> [ScannerResponse]
    public private(set) var sentCommands: [ScannerCommand] = []
    public private(set) var openCount = 0

    public nonisolated var responses: AsyncStream<ScannerResponse> {
        currentResponses.withLock { $0 }
    }

    public init(reply: @escaping @Sendable (ScannerCommand) -> [ScannerResponse]) {
        self.reply = reply
        let (finished, continuation) = AsyncStream.makeStream(of: ScannerResponse.self)
        continuation.finish()
        currentResponses = Mutex(finished)
    }

    public func open() async throws {
        outbox?.finish()
        let (responses, delivery) = AsyncStream.makeStream(of: ScannerResponse.self)
        let (batches, outbox) = AsyncStream.makeStream(of: [ScannerResponse].self)
        currentResponses.withLock { $0 = responses }
        self.outbox = outbox
        openCount += 1
        Task {
            for await batch in batches {
                await Task.yield()
                for response in batch { delivery.yield(response) }
            }
            delivery.finish()
        }
    }

    public func send(_ command: ScannerCommand) async throws {
        guard let outbox else { throw SimulatedScannerTransportError.notOpen }
        sentCommands.append(command)
        let replies = reply(command)
        if !replies.isEmpty { outbox.yield(replies) }
    }

    /// Injects an unsolicited response, such as a `PSI` push.
    public func emit(_ response: ScannerResponse) {
        outbox?.yield([response])
    }

    /// Ends the current `responses` stream as if the connection failed, without `close()`.
    /// Later sends throw `notOpen` until the transport is opened again.
    public func finishResponses() {
        outbox?.finish()
        outbox = nil
    }

    public func close() async {
        outbox?.finish()
        outbox = nil
    }

    /// A simulated SDS200 on firmware 1.24.00, answering from recorded captures.
    public static func sds200() -> SimulatedScannerTransport {
        let gsi = sds200GSIResponse()
        var assembler = UDPDatagramAssembler()
        let sts = assembler.feed(fixture("sts-trunk-sds200-1.24.00.txt"))
        precondition(sts.count == 1, "STS fixture should assemble into one response")
        return SimulatedScannerTransport { command in
            switch command.name {
            case "MDL": [.fields(command: "MDL", fields: ["SDS200"])]
            case "VER": [.fields(command: "VER", fields: ["Version 1.24.00"])]
            case "VOL": [.fields(command: "VOL", fields: [command.arguments.isEmpty ? "2" : "OK"])]
            case "SQL": [.fields(command: "SQL", fields: [command.arguments.isEmpty ? "1" : "OK"])]
            case "GSI": [gsi]
            case "STS": sts
            case "KEY": [.fields(command: "KEY", fields: ["OK"])]
            case "PSI": []
            default: [.fields(command: command.name, fields: ["ERR"])]
            }
        }
    }

    /// The recorded SDS200 `GSI` reply, assembled the way the network transport would.
    public static func sds200GSIResponse() -> ScannerResponse {
        var assembler = UDPDatagramAssembler()
        let gsi = assembler.feed(Data("GSI,<XML>,".utf8) + fixture("gsi-trunk-sds200-1.24.00.xml"))
        precondition(gsi.count == 1, "GSI fixture should assemble into one response")
        return gsi[0]
    }
}
