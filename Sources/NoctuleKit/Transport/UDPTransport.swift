// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Network
import Synchronization

public enum UDPTransportError: Error, Equatable {
    case notOpen
    case invalidPort
    case openFailed(String)
    case openTimedOut
}

/// A scanner connection over UDP (Network.framework).
///
/// Every received datagram goes through one `UDPDatagramAssembler`, which reassembles XML
/// documents the scanner splits across datagrams. `responses` is a fresh stream per `open()`;
/// it finishes on `close()` or when the connection reaches a terminal state (`.failed`,
/// `.cancelled`). Transient errors don't end it and don't fail `send`: POSIX ECONNREFUSED,
/// EHOSTUNREACH, ENETUNREACH, and EHOSTDOWN (ICMP replies, reported on the next send or receive),
/// or a path that's briefly unavailable (`.waiting`). A scanner over a VPN can blip and come back.
public actor UDPTransport: ScannerTransport {
    public let host: String
    public let port: UInt16

    private struct Link {
        let connection: NWConnection
        let continuation: AsyncStream<ScannerResponse>.Continuation
        let receiver: Task<Void, Never>
    }

    private static let openTimeout: Duration = .seconds(5)

    private nonisolated let currentResponses: Mutex<AsyncStream<ScannerResponse>>
    private let queue = DispatchQueue(label: "NoctuleKit.UDPTransport")
    private var link: Link?
    private var generation: UInt64 = 0
    private var assembler = UDPDatagramAssembler()

    public init(host: String, port: UInt16 = 50536) {
        self.host = host
        self.port = port
        let (finished, continuation) = AsyncStream.makeStream(of: ScannerResponse.self)
        continuation.finish()
        currentResponses = Mutex(finished)
    }

    public nonisolated var responses: AsyncStream<ScannerResponse> {
        currentResponses.withLock { $0 }
    }

    /// Starts a connection and waits (up to 5 s) for it to become ready. UDP has no handshake,
    /// so "ready" only means a local path exists; it says nothing about the scanner.
    public func open() async throws {
        await close()
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw UDPTransportError.invalidPort
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        let (responses, continuation) = AsyncStream.makeStream(of: ScannerResponse.self)
        let (states, stateSink) = AsyncStream.makeStream(of: NWConnection.State.self)
        connection.stateUpdateHandler = { state in
            stateSink.yield(state)
            switch state {
            case .failed, .cancelled:
                continuation.finish()
                stateSink.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)

        do {
            try await Self.waitUntilReady(states)
        } catch {
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.finish()
            throw error
        }

        generation += 1
        let generation = self.generation
        assembler = UDPDatagramAssembler()
        let receiver = Task { [weak self] in
            while !Task.isCancelled {
                let (data, error) = await Self.receiveMessage(on: connection)
                guard let self else { return }
                if let data, !data.isEmpty { await self.deliver(data, generation: generation) }
                switch connection.state {
                case .failed, .cancelled:
                    // On cancel a pending receive completes with no data and either no error
                    // or ECANCELED; only the state says the connection is gone.
                    return
                default:
                    if error != nil || data == nil {
                        // Not terminal (e.g. ECONNREFUSED from an ICMP reply, see isTransient):
                        // keep listening, without spinning, and keep `responses` open.
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
        }
        link = Link(connection: connection, continuation: continuation, receiver: receiver)
        currentResponses.withLock { $0 = responses }
    }

    /// Writes one datagram. Returns when Network.framework has processed it, or throws
    /// `CancellationError` promptly if the calling task is cancelled first. Transient errors
    /// (see `isTransient`) don't throw: the datagram is lost and the caller's request times out.
    public func send(_ command: ScannerCommand) async throws {
        guard let link else { throw UDPTransportError.notOpen }
        if command.name == "GSI" || command.name == "MSI" || command.name == "GLT" || (command.name == "PSI" && command.arguments.first != "0") {
            assembler.expectXML(for: command.name)
        }
        let connection = link.connection
        let once = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                once.install(continuation)
                connection.send(content: command.wireBytes, completion: .contentProcessed { error in
                    // A transient error means this datagram is lost; the request just times out.
                    if let error, !Self.isTransient(error) {
                        once.resume(.failure(error))
                    } else {
                        once.resume(.success(()))
                    }
                })
            }
        } onCancel: {
            once.resume(.failure(CancellationError()))
        }
    }

    public func close() async {
        guard let link else { return }
        self.link = nil
        generation += 1
        link.continuation.finish()
        link.receiver.cancel()
        link.connection.cancel()
    }

    private func deliver(_ datagram: Data, generation: UInt64) {
        guard generation == self.generation, let link else { return }
        for response in assembler.feed(datagram) {
            link.continuation.yield(response)
        }
    }

    /// Errors that mean "this datagram didn't arrive", not "the connection is gone". An ICMP
    /// reply to an earlier datagram is reported as ECONNREFUSED (port closed) or an unreachable
    /// error on whichever send or receive completes next; a scanner over a VPN can blip this way.
    nonisolated static func isTransient(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return [.ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN].contains(code)
    }

    private static func waitUntilReady(_ states: AsyncStream<NWConnection.State>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in states {
                    switch state {
                    case .ready: return
                    case .failed(let error): throw UDPTransportError.openFailed(String(describing: error))
                    case .cancelled: throw UDPTransportError.openFailed("cancelled")
                    default: continue
                    }
                }
                throw UDPTransportError.openFailed("connection ended")
            }
            group.addTask {
                try await Task.sleep(for: openTimeout)
                throw UDPTransportError.openTimedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static func receiveMessage(on connection: NWConnection) async -> (Data?, NWError?) {
        await withCheckedContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                continuation.resume(returning: (data, error))
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of completion or cancellation comes first.
/// Either may happen before the continuation is installed; the result is then kept for it.
private final class ResumeOnce: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var result: Result<Void, any Error>?
        var done = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let pending: Result<Void, any Error>? = state.withLock { state in
            if let result = state.result {
                state.result = nil
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func resume(_ result: Result<Void, any Error>) {
        let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
            guard !state.done else { return nil }
            state.done = true
            if let continuation = state.continuation {
                state.continuation = nil
                return continuation
            }
            state.result = result
            return nil
        }
        continuation?.resume(with: result)
    }
}
