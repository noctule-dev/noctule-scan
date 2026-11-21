// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Network
import Synchronization
import Testing
import NoctuleDevConfig
@testable import NoctuleKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct TimedOut: Error {}

/// Runs `body`, failing with `TimedOut` after `limit` so no test can hang on the network.
private func within<T: Sendable>(
    _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
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

/// A fake scanner: a UDP listener on 127.0.0.1 that answers each datagram via `answer`.
private final class FakeUDPScanner: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeUDPScanner")
    private let received = Mutex<[String]>([])
    private let answer: @Sendable (String) -> [String]

    init(answer: @escaping @Sendable (String) -> [String]) throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.answer = answer
    }

    var commands: [String] { received.withLock { $0 } }

    /// Starts listening and returns the bound port once the listener is ready.
    func start() async throws -> UInt16 {
        let (states, continuation) = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { continuation.yield($0) }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
        let listener = self.listener
        return try await within(.seconds(2)) {
            for await state in states {
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { throw TimedOut() }
                    return port
                case .failed(let error): throw error
                case .cancelled: throw CancellationError()
                default: continue
                }
            }
            throw CancellationError()
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data {
                let text = String(decoding: data, as: UTF8.self)
                self.received.withLock { $0.append(text) }
                for reply in self.answer(text) {
                    connection.send(content: Data(reply.utf8), completion: .idempotent)
                }
            }
            self.receive(on: connection)
        }
    }

    func stop() { listener.cancel() }
}

private let fragment1 = #"GSI,<XML>,<?xml version="1.0" encoding="utf-8"?><ScannerInfo Mode="Trunk Scan"><System Name="Loopback System"/><Footer No="1" EOT="0"/></ScannerInfo>"#
private let fragment2 = #"<?xml version="1.0" encoding="utf-8"?><ScannerInfo><Department Name="Loopback Dept"/><Footer No="2" EOT="1"/></ScannerInfo>"#
private let pushed = #"PSI,<XML>,<?xml version="1.0" encoding="utf-8"?><ScannerInfo Mode="Pushed"/>"#

private func sds200Answer(_ text: String) -> [String] {
    switch text {
    case "MDL\r": ["MDL,SDS200\r"]
    case "GSI\r": [fragment1, fragment2]
    case "PSI,250\r": [pushed]
    default: []
    }
}

/// A loopback UDP port with nothing listening: bind a listener, read its port, and cancel it.
private func unusedPort() async throws -> UInt16 {
    let scanner = try FakeUDPScanner { _ in [] }
    let port = try await scanner.start()
    scanner.stop()
    return port
}

/// An `MSI` answer with no `MSI,<XML>,` prefix: only `send` telling the assembler to expect
/// an `MSI` document makes it attributable.
private let bareMSI = #"<?xml version="1.0" encoding="utf-8"?><MSI Name="Set Range" Index="4293050176" MenuType="TypeInput" Value="30.0" ><MenuInput MaxLength="5" AddedInformation="          (mile)" EnableKeys="0123456789." /><Footer No="1" EOT="1"/></MSI>"#

/// A `GLT` answer with no `GLT,<XML>,` prefix, as `bareMSI` is for `MSI`.
private let bareGLT = #"<?xml version="1.0" encoding="utf-8"?><GLT><DEPT Index="200" Name="Lakeview Fire" Q_Key="0" /><Footer No="1" EOT="1"/></GLT>"#

@Suite struct UDPTransportTests {
    @Test func loopbackGLTReassemblesBareDocument() async throws {
        let scanner = try FakeUDPScanner { $0 == "GLT,DEPT,101\r" ? [bareGLT] : [] }
        defer { scanner.stop() }
        let port = try await scanner.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: port), commandTimeout: .seconds(1))
        try await within(.seconds(5)) {
            try await client.connect()
            let departments = try await client.favoritesDepartments(inSystem: 101)
            #expect(departments.map(\.index) == [200])
            await client.disconnect()
        }
    }

    @Test func loopbackRoundTrip() async throws {
        let scanner = try FakeUDPScanner(answer: sds200Answer)
        defer { scanner.stop() }
        let port = try await scanner.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: port), commandTimeout: .seconds(1))
        try await within(.seconds(5)) {
            try await client.connect()
            #expect(try await client.modelInfo().model == .sds200)
            let info = try await client.scannerInfo()
            #expect(info.system?.name == "Loopback System")
            #expect(info.department?.name == "Loopback Dept")
            await client.disconnect()
        }
        #expect(scanner.commands == ["MDL\r", "GSI\r"])
    }

    @Test func loopbackMenuScreenReassemblesBareDocument() async throws {
        let scanner = try FakeUDPScanner { $0 == "MSI\r" ? [bareMSI] : [] }
        defer { scanner.stop() }
        let port = try await scanner.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: port), commandTimeout: .seconds(1))
        try await within(.seconds(5)) {
            try await client.connect()
            let screen = try await client.menuScreen()
            #expect(screen.title == "Set Range")
            #expect(screen.kind == .input)
            #expect(screen.input?.maxLength == 5)
            await client.disconnect()
        }
        #expect(scanner.commands == ["MSI\r"])
    }

    @Test func loopbackPushReachesPushStream() async throws {
        let scanner = try FakeUDPScanner(answer: sds200Answer)
        defer { scanner.stop() }
        let port = try await scanner.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: port), commandTimeout: .seconds(1))
        try await within(.seconds(5)) {
            try await client.connect()
            let pushes = try await client.startPush(interval: .milliseconds(250))
            var iterator = pushes.makeAsyncIterator()
            let first = await iterator.next()
            #expect(first?.mode == "Pushed")
            await client.disconnect()
        }
        try await within(.seconds(2)) {
            while scanner.commands.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(scanner.commands == ["PSI,250\r", "PSI,0\r"])
    }

    @Test func unreachableScannerTimesOut() async throws {
        let port = try await unusedPort()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: port), commandTimeout: .milliseconds(200))
        let start = ContinuousClock.now
        try await within(.seconds(3)) {
            try await client.connect()
            await #expect(throws: ScannerClientError.timeout(command: "MDL")) { _ = try await client.modelInfo() }
            // A transient ICMP error must not end the transport: a second request also times out.
            await #expect(throws: ScannerClientError.timeout(command: "MDL")) { _ = try await client.modelInfo() }
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        await client.disconnect()
    }

    /// Back-to-back sends to a closed port: the ICMP reply to one datagram can fail the next send
    /// with ECONNREFUSED (when no receive consumes it first). That must not escape as a raw
    /// NWError; the datagram is just lost and the request times out.
    @Test func unreachableScannerBurstTimesOut() async throws {
        let port = try await unusedPort()
        let transport = UDPTransport(host: "127.0.0.1", port: port)
        let client = ScannerClient(transport: transport, commandTimeout: .milliseconds(200))
        let start = ContinuousClock.now
        try await within(.seconds(5)) {
            try await client.connect()
            for _ in 0..<20 {
                let failures = await withTaskGroup(of: String?.self) { group in
                    for _ in 0..<16 {
                        group.addTask {
                            do { try await transport.send(ScannerCommand("STS")); return nil }
                            catch { return String(describing: error) }
                        }
                    }
                    return await group.reduce(into: [String]()) { list, failure in if let failure { list.append(failure) } }
                }
                #expect(failures.isEmpty, "raw send errors escaped: \(failures)")
            }
            let model = Task { try await client.modelInfo() }
            _ = try await client.startPush(interval: .milliseconds(500))
            try await client.stopPush()
            await #expect(throws: ScannerClientError.timeout(command: "MDL")) { _ = try await model.value }
            await #expect(throws: ScannerClientError.timeout(command: "MDL")) { _ = try await client.modelInfo() }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        await client.disconnect()
    }

    @Test func closeFinishesResponsesAndReopenGivesFreshStream() async throws {
        let scanner = try FakeUDPScanner(answer: sds200Answer)
        defer { scanner.stop() }
        let port = try await scanner.start()
        let transport = UDPTransport(host: "127.0.0.1", port: port)
        try await within(.seconds(5)) {
            try await transport.open()
            let first = transport.responses
            await transport.close()
            var firstIterator = first.makeAsyncIterator()
            #expect(await firstIterator.next() == nil)
            await #expect(throws: UDPTransportError.notOpen) { try await transport.send(ScannerCommand("MDL")) }

            try await transport.open()
            var iterator = transport.responses.makeAsyncIterator()
            try await transport.send(ScannerCommand("MDL"))
            #expect(await iterator.next() == .fields(command: "MDL", fields: ["SDS200"]))
            await transport.close()
            #expect(await iterator.next() == nil)
        }
    }

    @Test func parsesDevConfig() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dev-scanner.env")
        try Data("# c\nSCANNER_HOST=\nSCANNER_IP=192.0.2.10\n".utf8).write(to: file)
        let config = try DevScannerConfig.load(from: file)
        #expect(config.host == "192.0.2.10")
        #expect(config.port == 50536)
    }

    @Test func devConfigPrefersHostAndReadsPort() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dev-scanner.env")
        try Data("""
            SCANNER_MODEL=SDS200
              # indented comment

            SCANNER_HOST = scanner.example.lan\r
            SCANNER_IP=192.0.2.10
            SCANNER_UDP_PORT=50537
            """.utf8).write(to: file)
        #expect(try DevScannerConfig.load(from: file) == DevScannerConfig(host: "scanner.example.lan", port: 50537))
    }

    @Test func devConfigRejectsMissingHostAndBadPort() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dev-scanner.env")
        try Data("SCANNER_HOST=\n".utf8).write(to: file)
        #expect(throws: DevScannerConfigError.missingHost) { try DevScannerConfig.load(from: file) }
        try Data("SCANNER_IP=192.0.2.10\nSCANNER_UDP_PORT=70000\n".utf8).write(to: file)
        #expect(throws: DevScannerConfigError.invalidPort("70000")) { try DevScannerConfig.load(from: file) }
    }

    @Test func devConfigReadsRTSPPort() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dev-scanner.env")
        try Data("SCANNER_IP=192.0.2.10\nSCANNER_RTSP_PORT = 8554\n".utf8).write(to: file)
        #expect(try DevScannerConfig.load(from: file)
            == DevScannerConfig(host: "192.0.2.10", port: 50536, rtspPort: 8554))
    }

    @Test func devConfigRTSPPortDefaultsTo554() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dev-scanner.env")
        try Data("SCANNER_IP=192.0.2.10\n".utf8).write(to: file)
        #expect(try DevScannerConfig.load(from: file).rtspPort == 554)
        try Data("SCANNER_IP=192.0.2.10\nSCANNER_RTSP_PORT=\n".utf8).write(to: file)
        #expect(try DevScannerConfig.load(from: file).rtspPort == 554)
    }

    @Test func devConfigRejectsBadRTSPPort() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dev-scanner.env")
        for bad in ["0", "70000", "rtsp"] {
            try Data("SCANNER_IP=192.0.2.10\nSCANNER_RTSP_PORT=\(bad)\n".utf8).write(to: file)
            #expect(throws: DevScannerConfigError.invalidPort(bad)) { try DevScannerConfig.load(from: file) }
        }
    }

    @Test func devConfigDefaultURLWalksUp() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let deep = root.appendingPathComponent("Tests/NoctuleKitTests")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let env = config.appendingPathComponent("dev-scanner.env")
        try Data("SCANNER_IP=192.0.2.10\n".utf8).write(to: env)

        let source = deep.appendingPathComponent("HardwareTests.swift")
        #expect(DevScannerConfig.defaultURL(searchingUpFrom: source)?.standardizedFileURL.path
            == env.standardizedFileURL.path)
        #expect(DevScannerConfig.defaultURL(searchingUpFrom: deep)?.standardizedFileURL.path
            == env.standardizedFileURL.path)

        let elsewhere = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: elsewhere) }
        #expect(DevScannerConfig.defaultURL(searchingUpFrom: elsewhere) == nil)
    }
}
