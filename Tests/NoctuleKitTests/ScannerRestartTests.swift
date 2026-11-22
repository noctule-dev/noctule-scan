// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKitTestSupport
@testable import NoctuleKit

private let fastPoll: Duration = .milliseconds(20)

private func client(_ scanner: ScriptedReboot, timeout: Duration = .milliseconds(300)) -> ScannerClient {
    ScannerClient(transport: scanner.makeTransport(), commandTimeout: timeout)
}

// MARK: restartScanner

@Test func restartSendsMSMExactlyOnceAndAcceptsOK() async throws {
    let scanner = ScriptedReboot(silentPolls: 0)
    let c = client(scanner)
    try await c.connect()
    try await c.restartScanner()
    #expect(scanner.msmCount == 1)
}

@Test func restartTreatsSilenceAsSuccessAndDisconnects() async throws {
    let scanner = ScriptedReboot(silentPolls: 0, msmReplies: [])
    let c = client(scanner, timeout: .milliseconds(100))
    try await c.connect()
    try await c.restartScanner()
    #expect(scanner.msmCount == 1)
    await #expect(throws: ScannerClientError.notConnected) { try await c.modelInfo() }
}

@Test func restartDisconnectsAfterOK() async throws {
    let scanner = ScriptedReboot(silentPolls: 0)
    let c = client(scanner)
    try await c.connect()
    try await c.restartScanner()
    await #expect(throws: ScannerClientError.notConnected) { try await c.modelInfo() }
}

@Test func restartRejectionThrowsAndStaysConnected() async throws {
    let scanner = ScriptedReboot(silentPolls: 0, msmReplies: [.fields(command: "MSM", fields: ["NG"])])
    let c = client(scanner)
    try await c.connect()
    await #expect(throws: ScannerClientError.rejected(command: "MSM", response: "MSM,NG")) {
        try await c.restartScanner()
    }
    #expect(scanner.msmCount == 1)
    #expect(try await c.modelInfo().reported == "SDS200")
    await c.disconnect()
}

@Test func restartWhenNotConnectedThrows() async {
    let c = client(ScriptedReboot(silentPolls: 0))
    await #expect(throws: ScannerClientError.notConnected) { try await c.restartScanner() }
}

// MARK: ScannerRestartMonitor

private func wait(_ scanner: ScriptedReboot, timeout: Duration = .seconds(3),
                  grace: Duration = .seconds(1), pollTimeout: Duration = .milliseconds(60)) async -> Bool {
    await ScannerRestartMonitor.waitUntilBack(
        host: "192.0.2.10", port: 50536, timeout: timeout, pollInterval: fastPoll,
        silenceGrace: grace, pollTimeout: pollTimeout, makeTransport: { scanner.makeTransport() })
}

@Test func monitorReturnsTrueWhenMDLReappearsAfterSilence() async throws {
    let scanner = ScriptedReboot(silentPolls: 3)
    let c = client(scanner)
    try await c.connect()
    try await c.restartScanner()
    #expect(await wait(scanner))
    #expect(scanner.mdlCount == 4)  // three silent polls, then the answer
}

@Test func monitorIgnoresAnswersGivenBeforeTheScannerWentSilent() async throws {
    // Right after MSM,OK the scanner keeps answering for a moment. Those answers are not "back".
    let scanner = ScriptedReboot(answerPolls: 2, silentPolls: 2)
    let c = client(scanner)
    try await c.connect()
    try await c.restartScanner()
    #expect(await wait(scanner))
    #expect(scanner.mdlCount == 5)  // two early answers, two silent polls, then the real answer
}

@Test func monitorFallsBackAfterGraceWhenScannerNeverWentSilent() async {
    // A reboot faster than the poll interval: the scanner never looks silent, so after the grace
    // period the monitor accepts the first answer.
    let scanner = ScriptedReboot(silentPolls: 0)
    let started = ContinuousClock.now
    // A poll timeout long enough that an answering scanner never looks silent: at 60 ms, a busy test
    // process took an answer for silence and accepted the next one at 126 ms, before the grace (a
    // full local swift test, 2026-11-22).
    #expect(await wait(scanner, grace: .milliseconds(150), pollTimeout: .seconds(2)))
    #expect(ContinuousClock.now - started >= .milliseconds(150))
}

@Test func monitorReturnsFalseOnTimeout() async throws {
    let scanner = ScriptedReboot(silentPolls: 10_000)
    let c = client(scanner)
    try await c.connect()
    try await c.restartScanner()
    let started = ContinuousClock.now
    #expect(await wait(scanner, timeout: .milliseconds(400)) == false)
    #expect(ContinuousClock.now - started < .seconds(2))
}

@Test func monitorStopsWhenCancelled() async throws {
    let scanner = ScriptedReboot(silentPolls: 10_000)
    let c = client(scanner)
    try await c.connect()
    try await c.restartScanner()
    let task = Task { await wait(scanner, timeout: .seconds(30)) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let result = await task.value
    #expect(result == false)
}

// MARK: ScannerRestart.perform

@Test func performRestartsWaitsAndClearsTheCooldown() async {
    let scanner = ScriptedReboot(silentPolls: 2)
    let c = client(scanner)
    try? await c.connect()
    let store = InMemoryRTSPCooldownStore()
    await store.recordClosed(host: "192.0.2.10", at: Date())
    let outcome = await ScannerRestart.perform(
        client: c, host: "192.0.2.10", port: 50536, cooldownStore: store, timeout: .seconds(3),
        pollInterval: fastPoll, silenceGrace: .seconds(1), pollTimeout: .milliseconds(60),
        makeTransport: { scanner.makeTransport() })
    #expect(outcome == .restarted)
    #expect(scanner.msmCount == 1)
    #expect(await store.lastClosed(host: "192.0.2.10") == nil)
}

@Test func performKeepsTheCooldownWhenRejected() async {
    let scanner = ScriptedReboot(silentPolls: 0, msmReplies: [.fields(command: "MSM", fields: ["ERR"])])
    let c = client(scanner)
    try? await c.connect()
    let store = InMemoryRTSPCooldownStore()
    await store.recordClosed(host: "192.0.2.10", at: Date())
    let outcome = await ScannerRestart.perform(
        client: c, host: "192.0.2.10", port: 50536, cooldownStore: store, timeout: .milliseconds(200),
        pollInterval: fastPoll, silenceGrace: .milliseconds(50), pollTimeout: .milliseconds(60),
        makeTransport: { scanner.makeTransport() })
    #expect(outcome == .notAccepted("MSM,ERR"))
    #expect(await store.lastClosed(host: "192.0.2.10") != nil)
    await c.disconnect()
}

@Test func performKeepsTheCooldownWhenTheScannerNeverReturns() async {
    let scanner = ScriptedReboot(silentPolls: 10_000)
    let c = client(scanner)
    try? await c.connect()
    let store = InMemoryRTSPCooldownStore()
    await store.recordClosed(host: "192.0.2.10", at: Date())
    let outcome = await ScannerRestart.perform(
        client: c, host: "192.0.2.10", port: 50536, cooldownStore: store, timeout: .milliseconds(300),
        pollInterval: fastPoll, silenceGrace: .milliseconds(50), pollTimeout: .milliseconds(60),
        makeTransport: { scanner.makeTransport() })
    #expect(outcome == .didNotComeBack)
    #expect(await store.lastClosed(host: "192.0.2.10") != nil)
}
