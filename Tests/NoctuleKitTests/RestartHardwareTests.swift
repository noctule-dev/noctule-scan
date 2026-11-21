// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleDevConfig
@testable import NoctuleKit

/// Restarts the real development scanner with `MSM,1`. Opt-in: `NOCTULE_RESTART_HARDWARE_TEST=1`.
/// Owner-approved on 2026-11-08; run it once, with the scanner healthy and control answering.
///
/// Confirms `MDL` answers, calls `restartScanner()`, waits up to 90 s for `MDL` to answer again,
/// then sends one read-only `GSI`. It never touches RTSP port 554. The address comes from the
/// git-ignored `config/dev-scanner.env` and is never printed; only durations are.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NOCTULE_RESTART_HARDWARE_TEST"] == "1"), .serialized)
struct RestartHardwareTests {
    @Test func restartsAndComesBack() async throws {
        guard let url = DevScannerConfig.defaultURL(searchingUpFrom: URL(fileURLWithPath: #filePath)) else {
            throw DevScannerConfigError.missingHost
        }
        let config = try DevScannerConfig.load(from: url)
        let client = ScannerClient(transport: UDPTransport(host: config.host, port: config.port),
                                   commandTimeout: .seconds(3))
        try await client.connect()
        do {
            let model = try await client.modelInfo()  // must answer before we restart
            print("Restart hardware: MDL answered before restart (\(model.reported))")
            let clock = ContinuousClock()
            let sent = clock.now
            try await client.restartScanner()
            print("Restart hardware: MSM,1 accepted after \(sent.duration(to: clock.now))")
            let back = await ScannerRestartMonitor.waitUntilBack(
                host: config.host, port: config.port, timeout: .seconds(90))
            let elapsed = sent.duration(to: clock.now)
            print("Restart hardware: back=\(back) after \(elapsed) from send")
            #expect(back, "scanner did not answer MDL within 90 s of the restart")
            guard back else { return }
            let after = ScannerClient(transport: UDPTransport(host: config.host, port: config.port),
                                      commandTimeout: .seconds(3))
            try await after.connect()
            do {
                let info = try await after.scannerInfo()
                print("Restart hardware: GSI after restart OK, mode \(info.mode ?? "nil")")
                await after.disconnect()
            } catch {
                await after.disconnect()
                throw error
            }
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }
}
