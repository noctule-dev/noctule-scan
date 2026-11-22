// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization
import Testing
import NoctuleKit
@testable import NoctuleMockScanner

// The mock SDS150 on a pseudo-terminal through the real client stack: `ScannerClient` over
// `SerialTransport`. Every serial port here is a pty the mock created. Scenario time is a stepped
// clock; pushes and the timed faults run in real time, so every wait is a bounded poll.

private let mainTitle = "       --- M E N U ---"

private func isTimeout(_ error: any Error) -> Bool {
    if case ScannerClientError.timeout = error { return true }
    return false
}

/// A fresh directory for link paths; `remove()` deletes it and everything in it.
private struct LinkDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "noctule-serial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ name: String = "port") -> String { url.appending(path: name).path }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// What is at `path` itself (not following a symlink): a symlink's target, or nil when nothing is.
private enum Entry: Equatable {
    case symlink(String)
    case other
}

private func entry(at path: String) -> Entry? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    guard info.st_mode & S_IFMT == S_IFLNK else { return .other }
    return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map(Entry.symlink) ?? .other
}

/// Collects pushed updates in the background; `finished` turns true when the stream ends.
private final class PushCollector: Sendable {
    private let items = Mutex<[ScannerInfo]>([])
    private let ended = Mutex(false)
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<PushUpdate>) {
        task.withLock {
            $0 = Task { [self] in
                for await update in stream { self.items.withLock { $0.append(update.info) } }
                self.ended.withLock { $0 = true }
            }
        }
    }

    var all: [ScannerInfo] { items.withLock { $0 } }
    var count: Int { items.withLock { $0.count } }
    var finished: Bool { ended.withLock { $0 } }
    func cancel() { task.withLock { $0?.cancel() } }
}

private struct SerialRig: Sendable {
    let mock: MockSerialScanner
    let clock: MockClock
    /// What `start()` returned: the link path when there is one, else the pty's slave.
    let path: String
    let client: ScannerClient

    func newClient(timeout: Duration = .milliseconds(700)) -> ScannerClient {
        ScannerClient(transport: SerialTransport(path: path), commandTimeout: timeout)
    }
}

/// Starts a mock on a stepped clock (at `time`), connects a `ScannerClient` over `SerialTransport`
/// on its port, runs `body` (bounded by `limit`), and in every path disconnects the client and
/// stops the mock. With `link`, the port is a symlink in a fresh directory, which must be gone after
/// the stop.
private func withSerialMock(
    at time: Double = 3, personality: MockPersonality = .sds150, faults: MockFaults = .none, link: Bool = false,
    replyDelays: [String: Duration] = [:], commandTimeout: Duration = .milliseconds(700),
    limit: Duration = .seconds(10), _ body: @escaping @Sendable (SerialRig) async throws -> Void
) async throws {
    let directory = try LinkDirectory()
    defer { directory.remove() }
    let linkPath = link ? directory.path() : nil
    let clock = MockClock.stepped(at: time)
    let mock = MockSerialScanner(scenario: .default, clock: clock, personality: personality, linkPath: linkPath,
                                 replyDelays: replyDelays)
    await mock.setFaults(faults)
    var failure: (any Error)?
    var client: ScannerClient?
    do {
        let path = try await mock.start()
        if let linkPath { #expect(path == linkPath) }
        let connected = ScannerClient(transport: SerialTransport(path: path), commandTimeout: commandTimeout)
        client = connected
        try await connected.connect()
        try await within(limit) { try await body(SerialRig(mock: mock, clock: clock, path: path, client: connected)) }
    } catch {
        failure = error
    }
    await client?.disconnect()
    await mock.stop()
    #expect(!(await mock.isPluggedIn))
    if let linkPath { #expect(entry(at: linkPath) == nil, "the link outlived stop()") }
    #expect(await mock.receivedCommands.allSatisfy { !$0.hasPrefix("MSM") }, "the client sent MSM over serial")
    if let failure { throw failure }
}

/// A raw descriptor on a pty the mock created, for writing bytes a `ScannerClient` never would
/// (half a command, several at once) and reading replies byte for byte.
/// Runs a blocking `body` on a dispatch thread and waits for it without holding a cooperative one.
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: body()) }
    }
}

private final class RawPort: Sendable {
    let fd: Int32

    init(_ path: String) throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        #expect(Darwin.write(fd, bytes, bytes.count) == bytes.count)
    }

    /// Everything that arrives within `limit`, or as soon as it contains `until`. The waiting
    /// `poll` runs on a dispatch thread, never a cooperative one: the in-process mock answering
    /// this port needs the pool, which a blocking wait here starved (one thread under
    /// `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, three on the CI runner; LESSONS.md 2026-11-21).
    func read(for limit: Duration, until: String? = nil) async -> String {
        await offThePool { self.blockingRead(for: limit, until: until) }
    }

    /// The bytes that arrive within `limit`, or as soon as a `\r` ends a reply (off the pool).
    func readBytes(for limit: Duration) async -> [UInt8] {
        await offThePool { self.blockingReadBytes(for: limit) }
    }

    private func blockingRead(for limit: Duration, until: String?) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = ContinuousClock.now.duration(to: deadline)
            let ms = max(1, Int(left / .milliseconds(1)))
            guard poll(&descriptor, 1, Int32(ms)) > 0 else { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer[0..<count]) } else if count == 0 { break }
            if let until, String(decoding: data, as: UTF8.self).contains(until) { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func blockingReadBytes(for limit: Duration) -> [UInt8] {
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = ContinuousClock.now.duration(to: deadline)
            let ms = max(1, Int(left / .milliseconds(1)))
            guard poll(&descriptor, 1, Int32(ms)) > 0 else { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer[0..<count]) } else if count == 0 { break }
            if data.last == 0x0D { break }
        }
        return data
    }

    func close() { Darwin.close(fd) }
}

@Suite(.timeLimit(.minutes(1))) struct MockSerialScannerTests {
    // MARK: Identity and status

    @Test func identifies() async throws {
        try await withSerialMock { rig in
            let model = try await rig.client.modelInfo()
            #expect(model.reported == "SDS150")
            #expect(model.model == .sds150)
            #expect(try await rig.client.firmwareVersion() == "1.01.02")
            #expect(await rig.mock.receivedCommands == ["MDL", "VER"])
            // Without split-writes, every reply goes out in one write.
            #expect(await rig.mock.largestWrite == "VER,Version 1.01.02\r".utf8.count)
        }
    }

    @Test func mdlNameOverride() async throws {
        var personality = MockPersonality.sds150
        personality.reportedModel = "SDS150GBT"
        try await withSerialMock(personality: personality) { rig in
            let model = try await rig.client.modelInfo()
            #expect(model.reported == "SDS150GBT")
            #expect(model.model == .sds150)
        }
    }

    @Test func statusAndDisplay() async throws {
        try await withSerialMock { rig in
            let info = try await rig.client.scannerInfo()
            #expect(info.channel?.name == MockScenario.default.transmissions[0].channel)
            let display = try await rig.client.displayStatus()
            #expect(!display.lines.isEmpty)
            #expect(try await rig.client.chargeStatus().percent == 100)
            #expect(try await rig.client.volume() == 2)
            try await rig.client.setVolume(15)
            await #expect { try await rig.client.setVolume(16) } throws: { _ in true }
            #expect(try await rig.client.volume() == 15)
        }
    }

    /// The SDS150's idle `STS` carries three icon glyph bytes at columns 0-2 of its first line
    /// (design §7.3; which bytes the real unit uses is an assumption). The SDS200's `STS` has none:
    /// the same screen, byte for byte, apart from those three columns.
    @Test func sds150DisplayCarriesGlyphBytes() async throws {
        func rawSTS(_ personality: MockPersonality, at time: Double = 0) async throws -> [UInt8] {
            let bytes = Mutex<[UInt8]>([])
            try await withSerialMock(at: time, personality: personality) { rig in
                await rig.client.disconnect()
                let port = try RawPort(rig.path)
                defer { port.close() }
                port.write("STS\r")
                let read = await port.readBytes(for: .seconds(2))
                bytes.withLock { $0 = read }
            }
            return bytes.withLock { $0 }
        }
        let sds150 = try await rawSTS(.sds150)
        let sds200 = try await rawSTS(.sds200)
        let prefix = Array("STS,00001010100000000,".utf8)
        #expect(sds150.starts(with: prefix + [0x80, 0x81, 0x8D]), "\(sds150.prefix(40))")
        #expect(sds150.last == 0x0D)
        // Only those three columns differ; the SDS200's bytes are plain ASCII, unchanged.
        #expect(sds200.starts(with: prefix + Array("   ".utf8)), "\(sds200.prefix(40))")
        #expect(sds200.allSatisfy { $0 < 0x80 })
        #expect(sds150.count == sds200.count)
        #expect(Array(sds150.dropFirst(prefix.count + 3)) == Array(sds200.dropFirst(prefix.count + 3)))
        #expect(sds150.filter { $0 >= 0x80 } == [0x80, 0x81, 0x8D])
        // Only the idle screen has them: at 3 s a transmission is on air, and its first line is plain.
        let onAir = try await rawSTS(.sds150, at: 3)
        #expect(onAir.starts(with: prefix), "\(onAir.prefix(40))")
        #expect(onAir.allSatisfy { $0 < 0x80 }, "a transmission's STS carries glyph bytes")
    }

    /// The SDS100 mock through the real client stack (design §5.4): its identity, a `GSI`, and an
    /// `STS` whose four icon glyphs (0x06, 0x07, 0x1A, 0x1B) decode as one column each, so every
    /// line's text and mask have the same width.
    @Test func sds100OverTheSerialTransport() async throws {
        try await withSerialMock(at: 0, personality: .sds100) { rig in
            let model = try await rig.client.modelInfo()
            #expect(model.reported == "SDS100")
            #expect(model.model == .sds100)
            #expect(try await rig.client.firmwareVersion() == "1.26.01")
            let info = try await rig.client.scannerInfo()
            #expect(info.volume == 2)
            #expect(info.system?.name == MockScenario.default.idle.system)
            #expect(!info.isReceiving)
            let display = try await rig.client.displayStatus()
            #expect(!display.lines.isEmpty)
            for line in display.lines {
                #expect(line.text.count == line.highlightMask.count, "\(line)")
            }
            let first = try #require(display.lines.first)
            #expect(Array(first.text.unicodeScalars.prefix(4).map(\.value)) == [0x06, 0x07, 0x1A, 0x1B])
            try await rig.client.setVolume(15)
            await #expect { try await rig.client.setVolume(16) } throws: { _ in true }
            #expect(try await rig.client.volume() == 15)
            #expect(await rig.mock.receivedCommands.allSatisfy { !$0.hasPrefix("GCS") && !$0.hasPrefix("KAL") })
        }
    }

    // MARK: Pushes

    @Test func pushesAndTidyStop() async throws {
        let second = MockScenario.default.transmissions[1]
        try await withSerialMock(at: second.at - 0.5) { rig in
            let pushes = PushCollector(try await rig.client.startPushUpdates(interval: .milliseconds(100)))
            defer { pushes.cancel() }
            try await eventually { pushes.count >= 3 }
            // Idle: the SDS150 steps through conventional channels, none of them receiving.
            #expect(pushes.all.first?.mode == "Scan Mode")
            #expect(pushes.all.first?.isReceiving == false)
            #expect(await rig.mock.activeSubscribers == 1)

            rig.clock.advance(by: 1)  // crosses into transmission 2
            try await eventually { pushes.all.last?.channel?.name == second.channel }

            try await rig.client.stopPush()
            try await eventually { await rig.mock.activeSubscribers == 0 }
            #expect(await rig.mock.receivedCommands.filter { $0.hasPrefix("PSI") } == ["PSI,100", "PSI,0"])
            let sent = await rig.mock.pushesSent
            try await Task.sleep(for: .milliseconds(300))
            #expect(await rig.mock.pushesSent == sent)
        }
    }

    @Test func splitWrites() async throws {
        try await withSerialMock(faults: MockFaults(splitWrites: true)) { rig in
            let info = try await rig.client.scannerInfo()
            #expect(info.channel?.name == MockScenario.default.transmissions[0].channel)
            let pushes = PushCollector(try await rig.client.startPushUpdates(interval: .milliseconds(100)))
            defer { pushes.cancel() }
            try await eventually { pushes.count >= 3 }
            #expect(pushes.all.allSatisfy { $0.channel?.name == MockScenario.default.transmissions[0].channel })
            try await rig.client.stopPush()
            #expect(await rig.mock.largestWrite == 7)
        }
    }

    // MARK: Menus

    @Test func menusWork() async throws {
        try await withSerialMock { rig in
            try await rig.client.press(.menu)
            let screen = try await rig.client.menuScreen()
            #expect(screen.kind == .select)
            #expect(screen.title == mainTitle)
            #expect(screen.items.map(\.name) == ["Set Scan Selection", "Set Your Location", "Search for...",
                                                  "Display Options", "Settings"])
            #expect(await rig.mock.isInMenu)
            #expect(await rig.mock.menuPath == [mainTitle])
            try await rig.client.press(.avoid)
            #expect(!(await rig.mock.isInMenu))
        }
    }

    // MARK: Faults

    @Test func dropReplyFault() async throws {
        try await withSerialMock(faults: MockFaults(dropNextReply: "KEY")) { rig in
            await #expect { try await rig.client.press(.menu) } throws: { isTimeout($0) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(await rig.mock.receivedCommands.filter { $0.hasPrefix("KEY") } == ["KEY,M,P"])
            #expect(await rig.mock.isInMenu, "the key was carried out")
            #expect(await rig.mock.menuPath == [mainTitle])
            // The fault cleared itself.
            try await rig.client.press(.avoid)
            #expect(await rig.mock.receivedCommands.filter { $0.hasPrefix("KEY") } == ["KEY,M,P", "KEY,L,P"])
        }
    }

    @Test func dropRequestFault() async throws {
        try await withSerialMock(faults: MockFaults(dropNextRequest: "KEY")) { rig in
            await #expect { try await rig.client.press(.menu) } throws: { isTimeout($0) }
            #expect(await rig.mock.receivedCommands == ["KEY,M,P"])  // logged all the same
            #expect(!(await rig.mock.isInMenu))
        }
    }

    // MARK: Unplugging

    @Test func unplugAndReplug() async throws {
        try await withSerialMock(link: true) { rig in
            let pushes = PushCollector(try await rig.client.startPushUpdates(interval: .milliseconds(100)))
            defer { pushes.cancel() }
            try await eventually { pushes.count >= 2 }
            #expect(await rig.mock.activeSubscribers == 1)
            #expect(entry(at: rig.path) != nil)

            await rig.mock.unplug()
            try await eventually { pushes.finished }  // the client's stream ended
            #expect(!(await rig.mock.isPluggedIn))
            #expect(entry(at: rig.path) == nil, "the link is gone")
            #expect(await rig.mock.activeSubscribers == 0)
            await #expect(throws: SerialTransportError.noSuchPort(rig.path)) {
                try await SerialTransport(path: rig.path).open()
            }

            let path = try await rig.mock.replug()
            #expect(path == rig.path)
            #expect(await rig.mock.isPluggedIn)
            let client = rig.newClient()
            try await client.connect()
            let model = try await client.modelInfo()
            #expect(model.model == .sds150)
            // The scenario runs on, and a new subscription gets pushes.
            let second = MockScenario.default.transmissions[1]
            rig.clock.set(second.at + 0.5)
            let again = PushCollector(try await client.startPushUpdates(interval: .milliseconds(100)))
            defer { again.cancel() }
            try await eventually { again.all.last?.channel?.name == second.channel }
            try await client.stopPush()
            try await eventually { await rig.mock.activeSubscribers == 0 }
            await client.disconnect()
        }
    }

    @Test func replugWithoutALinkGivesTheNewPty() async throws {
        try await withSerialMock { rig in
            #expect(rig.path.hasPrefix("/dev/ttys"))
            await rig.mock.unplug()
            let path = try await rig.mock.replug()
            #expect(path.hasPrefix("/dev/ttys"))
            let client = ScannerClient(transport: SerialTransport(path: path), commandTimeout: .milliseconds(700))
            try await client.connect()
            #expect(try await client.modelInfo().reported == "SDS150")
            await client.disconnect()
        }
    }

    @Test func timedUnplugAndReplug() async throws {
        try await withSerialMock(faults: MockFaults(unplugAfter: 0.3, replugAfter: 0.5), link: true) { rig in
            #expect(await rig.mock.isPluggedIn)
            try await eventually { !(await rig.mock.isPluggedIn) }
            #expect(entry(at: rig.path) == nil)
            try await eventually { await rig.mock.isPluggedIn }
            let client = rig.newClient()
            try await client.connect()
            #expect(try await client.modelInfo().model == .sds150)
            await client.disconnect()
        }
    }

    @Test func timedUnplugWithoutReplugStaysUnplugged() async throws {
        try await withSerialMock(faults: MockFaults(unplugAfter: 0.2)) { rig in
            try await eventually { !(await rig.mock.isPluggedIn) }
            try await Task.sleep(for: .milliseconds(500))
            #expect(!(await rig.mock.isPluggedIn))
        }
    }

    /// `unplug-after-psi`: the unplug clock starts at the first subscribing `PSI`, however long the
    /// client took to get there, not at `start()`; a `PSI,0` doesn't start it. (On the stepped
    /// clock for the scenario; the fault itself runs in real time, like `unplugAfter`.)
    @Test func unplugAfterPSICountsFromTheFirstSubscription() async throws {
        let faults = MockFaults(unplugAfter: 0.3, unplugCountsFromFirstPSI: true)
        try await withSerialMock(faults: faults) { rig in
            await rig.client.disconnect()
            let port = try RawPort(rig.path)
            defer { port.close() }
            port.write("MDL\r")
            port.write("PSI,0\r")
            // Well past 0.3 s from `start()` (a late wake only lengthens this): still plugged in.
            try await Task.sleep(for: .milliseconds(900))
            #expect(await rig.mock.isPluggedIn, "unplugged before any subscribing PSI")
            port.write("PSI,250\r")
            try await eventually { !(await rig.mock.isPluggedIn) }
        }
    }

    @Test func plainUnplugStillCountsFromStart() async throws {
        try await withSerialMock(faults: MockFaults(unplugAfter: 0.3)) { rig in
            #expect(!(await rig.mock.receivedCommands.contains { $0.hasPrefix("PSI,") && $0 != "PSI,0" }))
            try await eventually { !(await rig.mock.isPluggedIn) }
        }
    }

    @Test func delayedReplyDoesNotCrossAnUnplug() async throws {
        try await withSerialMock(link: true, replyDelays: ["KEY": .milliseconds(400)]) { rig in
            await rig.client.disconnect()
            let before = try RawPort(rig.path)
            before.write("KEY,M,P\r")
            try await eventually { await rig.mock.receivedCommands.contains("KEY,M,P") }
            before.close()
            await rig.mock.unplug()
            _ = try await rig.mock.replug()
            let after = try RawPort(rig.path)
            defer { after.close() }
            let text = await after.read(for: .milliseconds(800))
            #expect(!text.contains("KEY,OK"), "a reply held back before the unplug reached the new port: \(text)")
        }
    }

    // MARK: The link path

    @Test func linkPathNeverReplacesAFileOrDirectory() async throws {
        let directory = try LinkDirectory()
        defer { directory.remove() }
        let file = directory.path("file")
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: file))
        let folder = directory.path("folder")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        for path in [file, folder] {
            let mock = MockSerialScanner(scenario: .default, clock: .stepped(), linkPath: path)
            await #expect(throws: MockSerialScannerError.linkPathOccupied(path)) { try await mock.start() }
            #expect(!(await mock.isPluggedIn))
            await mock.stop()
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data("keep me".utf8))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func replugNeverReplacesAFile() async throws {
        try await withSerialMock(link: true) { rig in
            await rig.mock.unplug()
            try Data("keep me".utf8).write(to: URL(fileURLWithPath: rig.path))
            await #expect(throws: MockSerialScannerError.linkPathOccupied(rig.path)) { try await rig.mock.replug() }
            #expect(!(await rig.mock.isPluggedIn))
            #expect(try Data(contentsOf: URL(fileURLWithPath: rig.path)) == Data("keep me".utf8))
            await rig.mock.stop()
            #expect(entry(at: rig.path) == .other, "stop() deleted a file it didn't make")
            try FileManager.default.removeItem(atPath: rig.path)
        }
    }

    @Test func staleLinkIsReplaced() async throws {
        let directory = try LinkDirectory()
        defer { directory.remove() }
        let link = directory.path()
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/dev/ttys-left-by-a-crash")
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(), linkPath: link)
        let path = try await mock.start()
        #expect(path == link)
        guard case .symlink(let target)? = entry(at: link) else {
            Issue.record("no link at \(link)")
            await mock.stop()
            return
        }
        #expect(target.hasPrefix("/dev/ttys"))
        let client = ScannerClient(transport: SerialTransport(path: link), commandTimeout: .milliseconds(700))
        try await client.connect()
        #expect(try await client.modelInfo().reported == "SDS150")
        await client.disconnect()
        await mock.stop()
        #expect(entry(at: link) == nil)
    }

    @Test func secondMockBehindTheSameLink() async throws {
        let directory = try LinkDirectory()
        defer { directory.remove() }
        let link = directory.path()
        let first = MockSerialScanner(scenario: .default, clock: .stepped(), linkPath: link)
        _ = try await first.start()
        await first.unplug()
        #expect(entry(at: link) == nil)

        var personality = MockPersonality.sds150
        personality.reportedModel = "SDS150GBT"
        let second = MockSerialScanner(scenario: .default, clock: .stepped(), personality: personality, linkPath: link)
        #expect(try await second.start() == link)
        await first.stop()  // unplugged: it must leave the second mock's link alone
        #expect(entry(at: link) != nil)
        let client = ScannerClient(transport: SerialTransport(path: link), commandTimeout: .milliseconds(700))
        try await client.connect()
        #expect(try await client.modelInfo().reported == "SDS150GBT")
        await client.disconnect()
        await second.stop()
        #expect(entry(at: link) == nil)
    }

    @Test func linkReplacedByAnotherMockIsLeftAlone() async throws {
        let directory = try LinkDirectory()
        defer { directory.remove() }
        let link = directory.path()
        let first = MockSerialScanner(scenario: .default, clock: .stepped(), linkPath: link)
        let second = MockSerialScanner(scenario: .default, clock: .stepped(), linkPath: link)
        _ = try await first.start()
        _ = try await second.start()  // replaces the first one's link, which is still plugged in
        await first.stop()
        guard case .symlink(let target)? = entry(at: link) else {
            Issue.record("the first mock removed the second one's link")
            await second.stop()
            return
        }
        #expect(target.hasPrefix("/dev/ttys"))
        await second.stop()
        #expect(entry(at: link) == nil)
    }

    // MARK: Byte stream and stop

    /// `KAL` puts no byte on the port [spec]: the next reply is the first thing that comes back.
    @Test func keepAlivePutsNothingOnThePort() async throws {
        try await withSerialMock { rig in
            await rig.client.disconnect()
            let port = try RawPort(rig.path)
            defer { port.close() }
            port.write("KAL\r")
            try await eventually { await rig.mock.receivedCommands == ["KAL"] }
            port.write("MDL\r")
            let text = await port.read(for: .seconds(2), until: "MDL,SDS150\r")
            #expect(text == "MDL,SDS150\r")
            #expect(await port.read(for: .milliseconds(200)) == "")
            #expect(await rig.mock.receivedCommands == ["KAL", "MDL"])
        }
    }

    /// Over the pty as in the core: the subscription's pushes stop 183 s of scenario time after
    /// the `PSI`, and the subscription is still counted until `PSI,0`.
    @Test func pushesStopAfterTheLifetimeOnThePort() async throws {
        try await withSerialMock(at: 0) { rig in
            let pushes = PushCollector(try await rig.client.startPushUpdates(interval: .milliseconds(50)))
            defer { pushes.cancel() }
            try await eventually { pushes.count >= 2 }
            rig.clock.set(190)
            try await Task.sleep(for: .milliseconds(100))
            let sent = await rig.mock.pushesSent
            try await Task.sleep(for: .milliseconds(300))
            #expect(await rig.mock.pushesSent == sent)
            #expect(await rig.mock.activeSubscribers == 1)
            try await rig.client.stopPush()
            try await eventually { await rig.mock.activeSubscribers == 0 }
        }
    }

    /// A `KAL` that arrives after the pushes stopped: with `keepAliveRevivesStoppedPushes` false
    /// (the pessimistic answer) it does nothing, and only a new `PSI` starts them again; with true
    /// (the mock's assumption so far) the `KAL` alone does.
    @Test(arguments: [false, true])
    func lateKeepAliveIsIgnoredWhenToldSo(_ revives: Bool) async throws {
        var personality = MockPersonality.sds150
        personality.pushLifetime = 1
        personality.keepAliveRevivesStoppedPushes = revives
        try await withSerialMock(at: 0, personality: personality) { rig in
            await rig.client.disconnect()
            let port = try RawPort(rig.path)
            defer { port.close() }
            /// Reads (and drops) what the pushes put on the port for `time`, so it never fills.
            func drain(_ time: Duration) async { _ = await port.read(for: time) }
            port.write("PSI,100\r")
            try await eventually { await rig.mock.pushesSent >= 2 }
            rig.clock.set(1.5)  // past the lifetime: the pushes stop
            await drain(.milliseconds(300))
            let stopped = await rig.mock.pushesSent
            await drain(.milliseconds(300))
            #expect(await rig.mock.pushesSent == stopped)

            port.write("KAL\r")
            try await eventually { await rig.mock.receivedCommands.last == "KAL" }
            await drain(.milliseconds(400))
            if revives {
                #expect(await rig.mock.pushesSent > stopped)
            } else {
                #expect(await rig.mock.pushesSent == stopped)
                rig.clock.advance(by: 2)
                await drain(.milliseconds(400))
                #expect(await rig.mock.pushesSent == stopped)
                port.write("PSI,500\r")
                try await eventually { await rig.mock.pushesSent > stopped }
            }
            port.write("PSI,0\r")
            try await eventually { await rig.mock.activeSubscribers == 0 }
        }
    }

    @Test func commandsAreFramedAcrossAndWithinReads() async throws {
        try await withSerialMock { rig in
            await rig.client.disconnect()
            let port = try RawPort(rig.path)
            defer { port.close() }
            port.write("MD")
            try await Task.sleep(for: .milliseconds(50))
            port.write("L\rVER\r\nVO")
            try await Task.sleep(for: .milliseconds(50))
            port.write("L\n\r \r")
            let text = await port.read(for: .seconds(2), until: "VOL,2\r")
            #expect(text == "MDL,SDS150\rVER,Version 1.01.02\rVOL,2\r")
            #expect(await rig.mock.receivedCommands == ["MDL", "VER", "VOL"])
        }
    }

    @Test func stopKeepsTheSubscriptionCountAndTheLastCommand() async throws {
        let directory = try LinkDirectory()
        defer { directory.remove() }
        let link = directory.path()
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(), linkPath: link)
        _ = try await mock.start()
        let port = try RawPort(link)
        port.write("PSI,100\r")
        try await eventually { await mock.activeSubscribers == 1 }
        port.write("MDL\r")  // written just before the stop: still logged
        await mock.stop()
        port.close()
        #expect(await mock.receivedCommands == ["PSI,100", "MDL"])
        // A client that left its subscription running shows in the count kept at stop().
        #expect(await mock.activeSubscribers == 1)
        #expect(entry(at: link) == nil)
        #expect(!(await mock.isPluggedIn))
        await #expect(throws: MockSerialScannerError.stopped) { try await mock.replug() }
    }

    /// What a client wrote just before the pty closes still reaches `received` (the stop above
    /// relies on it for a client's last command). The I/O thread usually reads first, so this tries
    /// many times to catch a close that wins the race.
    @Test func ptyYieldsBytesWrittenJustBeforeItsClose() async throws {
        for attempt in 0..<200 {
            let terminal = try PseudoTerminal()
            let port = try RawPort(terminal.slavePath)
            port.write("PSI,0\r")
            terminal.close()
            port.close()
            var received = Data()
            for await chunk in terminal.received { received.append(chunk) }
            #expect(received == Data("PSI,0\r".utf8), "attempt \(attempt)")
            if received != Data("PSI,0\r".utf8) { return }
        }
    }

    @Test func stopEndsTheClientsStream() async throws {
        let mock = MockSerialScanner(scenario: .default, clock: .stepped())
        let path = try await mock.start()
        let client = ScannerClient(transport: SerialTransport(path: path), commandTimeout: .milliseconds(700))
        try await client.connect()
        let pushes = PushCollector(try await client.startPushUpdates(interval: .milliseconds(100)))
        defer { pushes.cancel() }
        try await eventually { pushes.count >= 1 }
        await mock.stop()
        try await eventually { pushes.finished }
        await client.disconnect()
    }
}
