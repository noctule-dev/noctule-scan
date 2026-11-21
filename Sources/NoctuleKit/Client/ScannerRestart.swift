// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// How a `ScannerRestart.perform` ended.
public enum RestartOutcome: Sendable, Equatable {
    /// `MSM,1` was accepted (or the scanner went quiet before replying), the scanner answered
    /// `MDL` again, and the RTSP cooldown record for the host was cleared.
    case restarted
    /// The scanner rejected `MSM,1` (or the client wasn't connected). It carries the reason.
    /// Nothing changed; the cooldown record is kept.
    case notAccepted(String)
    /// `MSM,1` went out but `MDL` never answered within the timeout. The cooldown record is kept.
    /// The scanner may still be rebooting; tell the owner it may need a power cycle.
    case didNotComeBack
}

extension ScannerClient {
    /// Sends `MSM,1`, the owner-approved, undocumented command that makes the scanner reboot
    /// (per the ProScan developer it enters USB mass-storage mode for about 1 s, then restarts),
    /// and then disconnects locally (sending `PSI,0` first, best effort, if a push is active).
    ///
    /// `MSM,OK` and no reply at all both count as success: the scanner may reboot before it
    /// answers. A rejection (`NG`/`ERR`) throws `ScannerClientError.rejected` and leaves the
    /// client connected. It only works while the UDP control channel still answers; it can't
    /// recover a scanner whose network stack has hung, which still needs a power cycle.
    ///
    /// **Never call this automatically.** A restart interrupts whatever the owner is doing and
    /// drops the audio stream; the CLI or app must get explicit confirmation each time.
    /// Afterwards use `ScannerRestartMonitor.waitUntilBack` and clear the RTSP cooldown record
    /// (`ScannerRestart.perform` does all of it).
    public func restartScanner() async throws {
        do {
            let reply = try await send(ScannerCommand("MSM", "1"))
            guard reply.status == .ok else { throw ScannerClientError.unexpectedResponse(command: "MSM") }
        } catch ScannerClientError.timeout {
            // Silence is success: the scanner may reboot before it replies.
        }
        await disconnect()
    }
}

/// Waits for a rebooting scanner to answer on the control channel again.
public struct ScannerRestartMonitor: Sendable {
    /// Polls `MDL` every `pollInterval` (2 s), each time on a fresh `ScannerClient` and transport.
    /// An answer only counts as "back" once the scanner has gone silent at least once, because
    /// it can keep answering for a moment after `MSM,OK`; if it never goes quiet (a reboot between
    /// two polls), the first answer after `silenceGrace` (15 s) counts. Returns false once
    /// `timeout` has passed or the task is cancelled.
    ///
    /// Do not touch RTSP port 554 while waiting. `makeTransport` builds each poll's transport
    /// (default: `UDPTransport(host:port:)`); tests pass a simulated one.
    public static func waitUntilBack(
        host: String, port: UInt16, timeout: Duration = .seconds(90),
        pollInterval: Duration = .seconds(2), silenceGrace: Duration = .seconds(15),
        pollTimeout: Duration = .seconds(1),
        makeTransport: (@Sendable () -> any ScannerTransport)? = nil
    ) async -> Bool {
        let make = makeTransport ?? { UDPTransport(host: host, port: port) }
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: timeout)
        let graceEnd = start.advanced(by: silenceGrace)
        var sawSilence = false
        while !Task.isCancelled, clock.now < deadline {
            if await isAnswering(timeout: pollTimeout, makeTransport: make) {
                if sawSilence || clock.now >= graceEnd { return true }
            } else {
                sawSilence = true
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            do { try await Task.sleep(for: min(pollInterval, remaining)) } catch { return false }
        }
        return false
    }

    /// One `MDL` on a fresh client. True if the scanner answered within `timeout`.
    public static func isAnswering(
        host: String, port: UInt16, timeout: Duration = .seconds(1)
    ) async -> Bool {
        await isAnswering(timeout: timeout, makeTransport: { UDPTransport(host: host, port: port) })
    }

    static func isAnswering(timeout: Duration, makeTransport: @Sendable () -> any ScannerTransport) async -> Bool {
        let client = ScannerClient(transport: makeTransport(), commandTimeout: timeout)
        do {
            try await client.connect()
            _ = try await client.modelInfo()
            await client.disconnect()
            return true
        } catch {
            await client.disconnect()
            return false
        }
    }
}

public enum ScannerRestart {
    /// Restarts the scanner on `client`, waits for it, and clears the RTSP cooldown record.
    ///
    /// Sends `MSM,1` (`restartScanner()`), then waits for `MDL` to answer again
    /// (`ScannerRestartMonitor.waitUntilBack`), then clears the cooldown record for `host`,
    /// because the reboot resets the scanner's audio server. `host` is the key the RTSP client
    /// uses (the IP literal). The record is kept for any outcome but `.restarted`.
    ///
    /// **Never call this without explicit user confirmation.** Restarts are never automatic.
    public static func perform(
        client: ScannerClient, host: String, port: UInt16, cooldownStore: any RTSPCooldownStore,
        timeout: Duration = .seconds(90), pollInterval: Duration = .seconds(2),
        silenceGrace: Duration = .seconds(15), pollTimeout: Duration = .seconds(1),
        makeTransport: (@Sendable () -> any ScannerTransport)? = nil
    ) async -> RestartOutcome {
        do {
            try await client.restartScanner()
        } catch ScannerClientError.rejected(_, let response) {
            return .notAccepted(response)
        } catch {
            return .notAccepted(String(describing: error))
        }
        let back = await ScannerRestartMonitor.waitUntilBack(
            host: host, port: port, timeout: timeout, pollInterval: pollInterval,
            silenceGrace: silenceGrace, pollTimeout: pollTimeout, makeTransport: makeTransport)
        guard back else { return .didNotComeBack }
        await cooldownStore.clear(host: host)
        return .restarted
    }
}
