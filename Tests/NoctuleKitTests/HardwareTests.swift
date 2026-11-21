// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleDevConfig
@testable import NoctuleKit

/// Read-only checks against the real development scanner. Opt-in: `NOCTULE_HARDWARE_TESTS=1`.
/// The address comes from the git-ignored `config/dev-scanner.env`. Only `MDL`, `VER`, `VOL`,
/// `SQL`, `GSI`, `STS`, at most one `MSI`, and `PSI` start/stop are sent; `PSI,0` and disconnect run on every path.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NOCTULE_HARDWARE_TESTS"] == "1"), .serialized)
struct HardwareTests {
    private static func client() throws -> ScannerClient {
        guard let url = DevScannerConfig.defaultURL(searchingUpFrom: URL(fileURLWithPath: #filePath)) else {
            throw DevScannerConfigError.missingHost
        }
        let config = try DevScannerConfig.load(from: url)
        return ScannerClient(transport: UDPTransport(host: config.host, port: config.port))
    }

    /// Runs `body` against a connected client and always disconnects, even if `body` throws.
    private static func withScanner(_ body: (ScannerClient) async throws -> Void) async throws {
        let client = try client()
        do {
            try await client.connect()
            try await body(client)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    @Test func readsIdentityAndStatus() async throws {
        try await Self.withScanner { client in
            #expect(try await client.modelInfo().model == .sds200)
            let firmware = try await client.firmwareVersion()
            #expect(!firmware.isEmpty)
            print("Hardware: SDS200 firmware \(firmware)")
            #expect((0...29).contains(try await client.volume()))
            #expect((0...19).contains(try await client.squelch()))
            let info = try await client.scannerInfo()
            #expect(info.mode != nil)
            print("Hardware: GSI mode \(info.mode ?? "nil"), screen \(info.screen ?? "nil")")
            let display = try await client.displayStatus()
            #expect(!display.softKeyLabels.isEmpty)
        }
    }

    @Test func pushDeliversScannerInfo() async throws {
        try await Self.withScanner { client in
            let pushes = try await client.startPush(interval: .milliseconds(500))
            // stopPush runs whether or not a push arrives in time; disconnect (in withScanner)
            // would also send PSI,0 if this were skipped by a throw.
            let received: ScannerInfo? = await withTaskGroup(of: ScannerInfo?.self) { group in
                group.addTask {
                    var iterator = pushes.makeAsyncIterator()
                    return await iterator.next()
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            try await client.stopPush()
            #expect(received != nil, "no PSI push within 3 s")
            #expect(received?.mode != nil)
        }
    }

    /// Outside a menu `MSI` answers a `TypeError` screen, which is data, not a failure. Reads only:
    /// `GSI` first, and if the scanner is in a menu nothing more is sent. Never `KEY` or `MSV`.
    @Test func menuDescriptionOutsideAMenuIsAnError() async throws {
        try await Self.withScanner { client in
            let info = try await client.scannerInfo()
            guard !info.isMenu else {
                Issue.record("scanner is in a menu; skipped")
                return
            }
            let screen = try await client.menuScreen()
            #expect(screen.kind == .error, "MSI outside a menu: \(screen.kind)")
        }
    }
}
