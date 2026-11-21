// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleCLICore
import NoctuleKit

// `noctule restart`: sends the owner-approved `MSM,1` after explicit confirmation, waits for the
// scanner to answer `MDL` again, and clears its RTSP cooldown record. Never run automatically.

enum RestartCommand {
    static let timeout: Duration = .seconds(90)

    static func run(target: AudioTarget, confirmed: Bool, cooldownStoreURL: URL) async -> Int32 {
        if !confirmed {
            print(RestartFormat.prompt(host: target.host), terminator: "")
            fflush(stdout)
            guard RestartFormat.isConfirmation(readLine()) else {
                print("restart: cancelled")
                return 1
            }
        }
        let client = ScannerClient(transport: UDPTransport(host: target.host, port: target.controlPort))
        do {
            try await client.connect()
        } catch {
            fputs("restart: can't reach the scanner: \(error)\n", stderr)
            await client.disconnect()
            return 1
        }
        print("restart: restarting the scanner; waiting up to \(timeout.components.seconds) s for it to answer again")
        fflush(stdout)
        let started = ContinuousClock.now
        let outcome = await ScannerRestart.perform(
            client: client, host: target.host, port: target.controlPort,
            cooldownStore: FileRTSPCooldownStore(url: cooldownStoreURL), timeout: timeout)
        await client.disconnect()
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let result = RestartFormat.outcome(outcome, seconds: seconds, timeoutSeconds: Int(timeout.components.seconds))
        print(result.line)
        if result.success { print(RestartFormat.unverifiedRevivalNote) }
        return result.success ? 0 : 1
    }
}
