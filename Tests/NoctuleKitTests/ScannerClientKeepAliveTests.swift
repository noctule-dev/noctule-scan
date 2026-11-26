// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKitTestSupport
import NoctuleMockScanner
@testable import NoctuleKit

// The push keep-alive (`startPush(…, keepAlive:)`): `KAL` every interval while that push is the
// active one, and never after its `PSI,0`, after `disconnect()` returns, or after a write that
// failed. Intervals here are short real ones and every wait is bounded. All values are fictional.

/// What a keep-alive test uses: `KAL` every `interval`.
private func keepAlive(_ interval: Duration = .milliseconds(50)) -> PushKeepAlive {
    PushKeepAlive(command: "KAL", interval: interval)
}

/// What a renewal test uses: the subscription's own `PSI` again every `interval`.
private func renew(_ interval: Duration = .milliseconds(50)) -> PushKeepAlive {
    PushKeepAlive(action: .renewSubscription, interval: interval)
}

/// Polls `condition` until it holds or `limit` passes; returns whether it held.
private func eventually(within limit: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Waits at most `limit` for the stream's next element; nil when it finished or timed out.
private func nextElement<T: Sendable>(_ stream: AsyncStream<T>, within limit: Duration = .seconds(2)) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Keeps push streams alive until `release()`: a dropped stream ends its push, and its keep-alive.
private final class Streams: Sendable {
    private let held = Mutex<[any Sendable]>([])
    func keep(_ stream: any Sendable) { held.withLock { $0.append(stream) } }
    func release() { held.withLock { $0 = [] } }
}

/// A keep-alive sleep the test drives: each wait returns only after `fire()` (one wait per fire),
/// so a keep-alive falls due exactly when the test says. `woken` counts the waits that returned.
private final class KeepAliveTrigger: Sendable {
    private let state = Mutex((fired: 0, woken: 0))

    func fire() { state.withLock { $0.fired += 1 } }
    var woken: Int { state.withLock { $0.woken } }

    var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void {
        { [self] _ in
            while true {
                let due = state.withLock { state -> Bool in
                    guard state.fired > state.woken else { return false }
                    state.woken += 1
                    return true
                }
                if due { return }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}

/// Errors handed to `onKeepAliveFailure`.
private final class Failures: Sendable {
    private let errors = Mutex<[any Error]>([])
    var report: @Sendable (any Error) -> Void { { [self] error in errors.withLock { $0.append(error) } } }
    var all: [any Error] { errors.withLock { $0 } }
}

/// What a request started in a task answered, read without awaiting the task (which may hang).
private final class Answer: Sendable {
    private let text = Mutex<String?>(nil)
    func set(_ value: String?) { text.withLock { $0 = value } }
    var value: String? { text.withLock { $0 } }
}

private func push(_ mode: String) -> ScannerResponse {
    .xml(command: "PSI", root: XMLNode(name: "ScannerInfo", attributes: ["Mode": mode]))
}

/// A fake scanner link that records each command when its write *completes*, and can hold a
/// keep-alive write in flight (it suspends until `release()`, while other sends go on) or make it
/// fail. A held write is what shows the ordering: a client that only cancelled its keep-alive
/// lazily would write `PSI,0` while the `KAL` was still on its way, and the `KAL` would land after.
/// A keep-alive write is a `KAL`, or a renewal: a non-zero `PSI` begun right after the same one
/// (the subscription's own `PSI` again; a newer push's different `PSI` is not one).
private actor KeepAliveLink: ScannerTransport {
    private nonisolated let current: Mutex<AsyncStream<ScannerResponse>>
    private var delivery: AsyncStream<ScannerResponse>.Continuation?
    private let reply: @Sendable (ScannerCommand) -> [ScannerResponse]

    /// Completed writes, in order, as `NAME[,args]`, with when each completed.
    private(set) var written: [(text: String, at: ContinuousClock.Instant)] = []
    /// Every `send` that began, in order (a held or failed one included).
    private(set) var attempts: [String] = []
    /// Completed writes and closes (`close` for `close()`), in order.
    private(set) var timeline: [String] = []
    private(set) var isOpen = false
    /// Hold every keep-alive write until `release()`.
    var holdKeepAlive = false
    /// Every keep-alive write throws.
    var failKeepAlive = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// The latest non-zero `PSI` begun: the same one again is a renewal.
    private var subscription: String?
    /// Keep-alive writes (`KAL`s and renewals) completed.
    private(set) var keepAlives = 0

    init(reply: @escaping @Sendable (ScannerCommand) -> [ScannerResponse] = { _ in [] }) {
        self.reply = reply
        let (finished, continuation) = AsyncStream.makeStream(of: ScannerResponse.self)
        continuation.finish()
        current = Mutex(finished)
    }

    nonisolated var responses: AsyncStream<ScannerResponse> { current.withLock { $0 } }

    func open() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: ScannerResponse.self)
        current.withLock { $0 = stream }
        delivery = continuation
        isOpen = true
    }

    func send(_ command: ScannerCommand) async throws {
        let text = ([command.name] + command.arguments).joined(separator: ",")
        attempts.append(text)
        let isPSI = command.name == "PSI" && text != "PSI,0"
        let isKeepAlive = command.name == "KAL" || (isPSI && text == subscription)
        if isPSI { subscription = text }
        guard isOpen else { throw SimulatedScannerTransportError.notOpen }
        if isKeepAlive {
            if failKeepAlive { throw SerialTransportError.writeFailed("short write: 1 of 4 bytes") }
            if holdKeepAlive { await withCheckedContinuation { held.append($0) } }
        }
        written.append((text, .now))
        if isKeepAlive { keepAlives += 1 }
        timeline.append(text)
        for response in reply(command) { delivery?.yield(response) }
    }

    func close() async {
        timeline.append("close")
        isOpen = false
        delivery?.finish()
        delivery = nil
    }

    func emit(_ response: ScannerResponse) { delivery?.yield(response) }

    /// Ends `responses` as if the link went away (no `close()`); later sends throw.
    func endResponses() {
        isOpen = false
        delivery?.finish()
        delivery = nil
    }

    func setHold(_ hold: Bool) { holdKeepAlive = hold }
    func setFail(_ fail: Bool) { failKeepAlive = fail }
    var heldCount: Int { held.count }

    /// Lets every held write complete.
    func release() {
        holdKeepAlive = false
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    var texts: [String] { written.map(\.text) }
}

@Suite(.timeLimit(.minutes(3))) struct ScannerClientKeepAliveTests {
    @Test func profileKeepAlive() {
        #expect(ModelProfile.profile(for: .sds150).pushKeepAlive == PushKeepAlive(command: "KAL", interval: .seconds(60)))
        #expect(ModelProfile.profile(for: .sds100).pushKeepAlive == PushKeepAlive(action: .renewSubscription, interval: .seconds(60)))
        #expect(ModelProfile.profile(for: .bcd436hp).pushKeepAlive == PushKeepAlive(action: .renewSubscription, interval: .seconds(60)))
        #expect(ModelProfile.profile(for: .sds200).pushKeepAlive == nil)
    }

    /// Without `keepAlive:` nothing but `PSI` goes out, as before.
    @Test func noKeepAliveByDefault() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        try await client.connect()
        let streams = Streams()
        defer { streams.release() }
        streams.keep(try await client.startPush(interval: .milliseconds(100)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await link.texts == ["PSI,100"])
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "PSI,0"])
    }

    /// `KAL` every interval, counted from the `PSI`, nothing else; the pushes keep coming.
    @Test func sendsTheKeepAliveEveryInterval() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        try await client.connect()
        let pushes = try await client.startPushUpdates(interval: .milliseconds(100), keepAlive: keepAlive())
        let psiAt = try #require(await link.written.first?.at)
        #expect(await eventually { await link.keepAlives >= 4 })
        await link.emit(push("Live"))
        #expect(await nextElement(pushes)?.info.mode == "Live")
        await client.disconnect()

        let written = await link.written
        #expect(written.first?.text == "PSI,100")
        #expect(written.last?.text == "PSI,0")
        #expect(written.dropFirst().dropLast().allSatisfy { $0.text == "KAL" }, "\(written.map(\.text))")
        let times = written.filter { $0.text == "KAL" }.map(\.at)
        let first = try #require(times.first)
        #expect(first - psiAt >= .milliseconds(50), "the first KAL came \(first - psiAt) after the PSI")
        // The k-th no sooner than k intervals after the PSI, and never two closer than an interval.
        for (index, at) in times.enumerated() {
            #expect(at - psiAt >= .milliseconds(50) * (index + 1), "KAL \(index + 1) at \(at - psiAt)")
        }
        for (earlier, later) in zip(times, times.dropFirst()) {
            #expect(later - earlier >= .milliseconds(50), "two KALs \(later - earlier) apart")
        }
    }

    /// A loop that wakes late (a Mac that slept or stalled) writes its late `KAL`, and the next one
    /// a whole interval after it, never sooner: two `KAL`s are never closer than one interval.
    @Test func lateWakeKeepsAWholeIntervalBeforeTheNext() async throws {
        let interval = Duration.milliseconds(200)
        let link = KeepAliveLink()
        let wakes = Mutex(0)
        // The first wake comes 0.9 of an interval late; the others on time.
        let client = ScannerClient(transport: link, keepAliveSleep: { due in
            let late = wakes.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            try await Task.sleep(until: late ? due + interval * 0.9 : due, clock: .continuous)
        })
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive(interval)))
        let psiAt = try #require(await link.written.first?.at)
        #expect(await eventually { await link.keepAlives >= 3 })
        await client.disconnect()
        let times = await link.written.filter { $0.text == "KAL" }.map(\.at)
        #expect(times[0] - psiAt >= interval * 1.9, "the first wake wasn't late: \(times[0] - psiAt)")
        for (earlier, later) in zip(times, times.dropFirst()) {
            #expect(later - earlier >= interval, "two KALs \(later - earlier) apart with a \(interval) interval")
        }
    }

    @Test func refusesAnIntervalUnderOneMillisecond() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        try await client.connect()
        for interval in [Duration.zero, .microseconds(999), .seconds(-1)] {
            do {
                _ = try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive(interval))
                Issue.record("expected invalidArgument for \(interval)")
            } catch let error as ScannerClientError {
                guard case .invalidArgument = error else { Issue.record("wrong error \(error)"); continue }
            }
        }
        #expect(await link.attempts.isEmpty)
        await client.disconnect()
    }

    // MARK: Never after the push's PSI,0

    /// The ordering proof: a `KAL` still being written when `stopPush()` is called is finished
    /// before `PSI,0` is written, and nothing follows.
    @Test func stopPushWaitsForAKeepAliveInFlight() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        // Held from the start, so a slow test can't let the first KAL through unheld.
        await link.setHold(true)
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive()))
        #expect(await eventually { await link.heldCount == 1 })
        let stop = Task { try await client.stopPush() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.texts == ["PSI,100"], "PSI,0 went out while a KAL was still being written")
        await link.release()
        try await stop.value
        #expect(await link.texts == ["PSI,100", "KAL", "PSI,0"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await link.attempts == ["PSI,100", "KAL", "PSI,0"])
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "KAL", "PSI,0"])
    }

    /// The same for `disconnect()`, and nothing is written once it has returned.
    @Test func disconnectWaitsForAKeepAliveInFlight() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        // Held from the start, so a slow test can't let the first KAL through unheld.
        await link.setHold(true)
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive()))
        #expect(await eventually { await link.heldCount == 1 })
        let disconnect = Task { await client.disconnect() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.texts == ["PSI,100"], "PSI,0 went out while a KAL was still being written")
        #expect(await link.isOpen)
        await link.release()
        await disconnect.value
        #expect(await link.texts == ["PSI,100", "KAL", "PSI,0"])
        #expect(!(await link.isOpen))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await link.attempts == ["PSI,100", "KAL", "PSI,0"])
    }

    /// The consumer cancelling: `PSI,0` (best effort) still comes after the `KAL` in flight.
    @Test func consumerCancelWaitsForAKeepAliveInFlight() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        try await client.connect()
        await link.setHold(true)
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive())
        let consumer = Task { for await _ in pushes {} }
        #expect(await eventually { await link.heldCount == 1 })
        consumer.cancel()
        await consumer.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.texts == ["PSI,100"], "PSI,0 went out while a KAL was still being written")
        await link.release()
        #expect(await eventually { await link.texts.count == 3 })
        #expect(await link.texts == ["PSI,100", "KAL", "PSI,0"])
        try await Task.sleep(for: .milliseconds(200))
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "KAL", "PSI,0"])
    }

    /// A dropped stream ends the keep-alive too.
    @Test func droppingTheStreamEndsTheKeepAlive() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        try await client.connect()
        do { _ = try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive()) }
        #expect(await eventually { await link.texts.contains("PSI,0") })
        try await Task.sleep(for: .milliseconds(200))
        let texts = await link.texts
        let stop = try #require(texts.firstIndex(of: "PSI,0"))
        #expect(!texts[stop...].contains("KAL"), "\(texts)")
        await client.disconnect()
    }

    /// A stop waits for an *older* push's `KAL` in flight too: one still held when a newer push
    /// starts lands before the `PSI,0` of a later `stopPush()`.
    @Test func stopPushWaitsForAnOlderPushsKeepAliveInFlight() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        await link.setHold(true)
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive()))
        #expect(await eventually { await link.heldCount == 1 })
        streams.keep(try await client.startPush(interval: .milliseconds(250)))
        let stop = Task { try await client.stopPush() }
        try await Task.sleep(for: .milliseconds(150))
        let before = await link.texts
        #expect(before == ["PSI,100", "PSI,250"], "PSI,0 overtook the older push's KAL: \(before)")
        await link.release()
        try await stop.value
        let after = await link.texts
        #expect(after == ["PSI,100", "PSI,250", "KAL", "PSI,0"], "\(after)")
        await client.disconnect()
        let attempts = await link.attempts
        #expect(attempts == ["PSI,100", "KAL", "PSI,250", "PSI,0"], "\(attempts)")
    }

    /// The same for `disconnect()`.
    @Test func disconnectWaitsForAnOlderPushsKeepAliveInFlight() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        await link.setHold(true)
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive()))
        #expect(await eventually { await link.heldCount == 1 })
        streams.keep(try await client.startPush(interval: .milliseconds(250)))
        let disconnect = Task { await client.disconnect() }
        try await Task.sleep(for: .milliseconds(150))
        let before = await link.texts
        #expect(before == ["PSI,100", "PSI,250"], "PSI,0 overtook the older push's KAL: \(before)")
        #expect(await link.isOpen)
        await link.release()
        await disconnect.value
        let after = await link.texts
        #expect(after == ["PSI,100", "PSI,250", "KAL", "PSI,0"], "\(after)")
        #expect(await link.timeline.last == "close")
    }

    /// The link going away: the transport is closed only after a `KAL` already on its way has
    /// been written (a transport whose `send` can suspend would otherwise be closed under it).
    @Test func transportEndClosesAfterAKeepAliveInFlight() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        await link.setHold(true)
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive()))
        #expect(await eventually { await link.heldCount == 1 })
        await link.endResponses()
        try await Task.sleep(for: .milliseconds(150))
        let before = await link.timeline
        #expect(before == ["PSI,100"], "closed while a KAL was still being written: \(before)")
        await link.release()
        #expect(await eventually { await link.timeline.last == "close" })
        #expect(await link.timeline == ["PSI,100", "KAL", "close"])
        await client.disconnect()
    }

    /// A client let go of without `disconnect()` stops writing keep-alives: the loop holds it
    /// only while a write starts, never across its sleep.
    @Test func droppedClientStopsTheKeepAlive() async throws {
        let link = KeepAliveLink()
        var client: ScannerClient? = ScannerClient(transport: link)
        try await client?.connect()
        let stream = try await client?.startPush(interval: .milliseconds(100), keepAlive: keepAlive(.milliseconds(40)))
        #expect(await eventually { await link.keepAlives >= 1 })
        weak let released = client
        client = nil
        #expect(await eventually { released == nil }, "the keep-alive loop still holds the client")
        try await Task.sleep(for: .milliseconds(100))
        let count = await link.attempts.count
        try await Task.sleep(for: .milliseconds(250))
        let attempts = await link.attempts
        #expect(attempts.count == count, "keep-alives went on after the client was dropped: \(attempts)")
        withExtendedLifetime(stream) {}
    }

    // MARK: Other ends of the push

    @Test func rejectedPSIEndsTheKeepAlive() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        try await client.connect()
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive())
        await link.emit(.fields(command: "PSI", fields: ["NG"]))
        #expect(await nextElement(pushes) == nil)
        let count = await link.attempts.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(await link.attempts.count == count)
        #expect(await link.keepAlives <= 1)
        await client.disconnect()
    }

    /// A newer push without a keep-alive ends the earlier one's.
    @Test func newerPushEndsTheKeepAlive() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive()))
        streams.keep(try await client.startPush(interval: .milliseconds(250)))
        try await Task.sleep(for: .milliseconds(200))
        let texts = await link.texts
        let newer = try #require(texts.firstIndex(of: "PSI,250"))
        #expect(!texts[newer...].contains("KAL"), "\(texts)")
        await client.disconnect()
    }

    /// A newer push with its own keep-alive: one loop, counted from the newer `PSI`.
    @Test func newerPushWithAKeepAliveRunsOneLoop() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive(.milliseconds(80))))
        streams.keep(try await client.startPush(interval: .milliseconds(250), keepAlive: keepAlive(.milliseconds(80))))
        try await Task.sleep(for: .milliseconds(300))
        await client.disconnect()
        let written = await link.written
        let newer = try #require(written.firstIndex { $0.text == "PSI,250" })
        let kals = written[newer...].filter { $0.text == "KAL" }.map(\.at)
        // Two loops would write about twice as many.
        #expect(kals.count >= 1 && kals.count <= 4, "\(written.map(\.text))")
        for (index, at) in kals.enumerated() {
            #expect(at - written[newer].at >= .milliseconds(80) * (index + 1))
        }
    }

    @Test func transportEndEndsTheKeepAlive() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        try await client.connect()
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive())
        await link.endResponses()
        #expect(await nextElement(pushes) == nil)
        let count = await link.attempts.count
        try await Task.sleep(for: .milliseconds(200))
        let attempts = await link.attempts
        #expect(attempts.count == count, "\(attempts)")
        await client.disconnect()
    }

    /// A keep-alive write that fails is never tried again; the push and the client go on.
    @Test func failedKeepAliveIsNeverRetried() async throws {
        let link = KeepAliveLink(reply: { command in
            command.name == "MDL" ? [.fields(command: "MDL", fields: ["SDS150"])] : []
        })
        let client = ScannerClient(transport: link)
        try await client.connect()
        await link.setFail(true)
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive())
        #expect(await eventually { await link.attempts.contains("KAL") })
        try await Task.sleep(for: .milliseconds(250))
        #expect(await link.attempts.filter { $0 == "KAL" }.count == 1)
        await link.emit(push("Live"))
        #expect(await nextElement(pushes)?.mode == "Live")
        #expect(try await client.modelInfo().reported == "SDS150")
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "KAL", "MDL", "PSI,0"])
    }

    /// A failed write is reported once, with its error, on the way out of the loop; nothing is
    /// retried, and nothing more is reported.
    @Test func failedKeepAliveWriteIsReportedOnce() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let failures = Failures()
        try await client.connect()
        await link.setFail(true)
        let streams = Streams()
        defer { streams.release() }
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive(),
                                                onKeepAliveFailure: failures.report))
        #expect(await eventually { failures.all.count == 1 })
        // Two intervals later: no second attempt, no second report.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await link.attempts.filter { $0 == "KAL" }.count == 1)
        #expect(failures.all.count == 1)
        let error = try #require(failures.all.first as? SerialTransportError)
        #expect(error == .writeFailed("short write: 1 of 4 bytes"))
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "KAL", "PSI,0"])
        #expect(failures.all.count == 1)
    }

    // MARK: The request slot

    /// A keep-alive that falls due while a request waits for its reply is written only once the
    /// reply has come: it takes the request slot like any request.
    @Test func keepAliveWaitsForAPendingReply() async throws {
        let gsi = SimulatedScannerTransport.sds200GSIResponse()
        let link = KeepAliveLink()  // The GSI's reply is held back until the test emits it.
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, commandTimeout: .seconds(2), keepAliveSleep: trigger.sleep)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPushUpdates(interval: .milliseconds(100), keepAlive: keepAlive()))
        let reading = Task { try await client.scannerInfo() }
        #expect(await eventually { await link.attempts.contains("GSI") })
        trigger.fire()
        #expect(await eventually { trigger.woken == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.attempts == ["PSI,100", "GSI"], "a KAL went out while the GSI's reply was pending")
        await link.emit(gsi)
        #expect(try await reading.value.mode == "Trunk Scan")
        #expect(await eventually { await link.keepAlives == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await link.texts == ["PSI,100", "GSI", "KAL"])
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "GSI", "KAL", "PSI,0"])
    }

    /// A request that is never answered holds the slot until it times out; the keep-alive goes
    /// out then, not before.
    /// The KAL is held to the GSI's own times, not to a fixed window: a window after the trigger
    /// that a late wakeup can stretch past the timeout failed on the CI runner (LESSONS.md
    /// 2026-11-21). The "nothing yet" check counts only when it is seen to run before the timeout.
    @Test func keepAliveAfterATimedOutRequest() async throws {
        let timeout = Duration.seconds(1)
        let link = KeepAliveLink()  // The GSI is never answered.
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, commandTimeout: timeout, keepAliveSleep: trigger.sleep)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive()))
        let reading = Task { try await client.scannerInfo() }
        #expect(await eventually { await link.attempts.contains("GSI") })
        let gsiAt = try #require(await link.written.first { $0.text == "GSI" }?.at)
        trigger.fire()
        #expect(await eventually { trigger.woken == 1 })
        try await Task.sleep(for: .milliseconds(100))
        let keepAlivesWhileWaiting = await link.keepAlives
        if ContinuousClock.now - gsiAt < timeout {  // the GSI was certainly still waiting when read
            #expect(keepAlivesWhileWaiting == 0, "a KAL went out while the GSI was still waiting")
        }
        await #expect(throws: ScannerClientError.timeout(command: "GSI")) { try await reading.value }
        #expect(await eventually { await link.keepAlives == 1 })
        let kalAt = try #require(await link.written.first { $0.text == "KAL" }?.at)
        #expect(kalAt - gsiAt >= timeout, "the KAL came \(kalAt - gsiAt) after the GSI")
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "GSI", "KAL", "PSI,0"])
    }

    /// A stop while a keep-alive waits for the slot: the keep-alive writes nothing, and the
    /// `PSI,0` goes out once the slot frees.
    @Test func stopWhileAKeepAliveWaitsWritesNoKeepAlive() async throws {
        let gsi = SimulatedScannerTransport.sds200GSIResponse()
        let link = KeepAliveLink()
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, commandTimeout: .seconds(2), keepAliveSleep: trigger.sleep)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive()))
        let reading = Task { try await client.scannerInfo() }
        #expect(await eventually { await link.attempts.contains("GSI") })
        trigger.fire()
        #expect(await eventually { trigger.woken == 1 })
        try await Task.sleep(for: .milliseconds(50))
        let stop = Task { try await client.stopPush() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.attempts == ["PSI,100", "GSI"], "something went out while the GSI's reply was pending")
        await link.emit(gsi)
        #expect(try await reading.value.mode == "Trunk Scan")
        try await stop.value
        #expect(await link.texts == ["PSI,100", "GSI", "PSI,0"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.attempts == ["PSI,100", "GSI", "PSI,0"])
        // The keep-alive that waited and wrote nothing gave the slot back: a later request gets
        // it and its reply. (A kept slot would hang it forever, so this waits only boundedly.)
        let answer = Answer()
        let again = Task { answer.set(try await client.scannerInfo().mode) }
        #expect(await eventually { await link.attempts.filter { $0 == "GSI" }.count == 2 },
                "a request after the stop never got the request slot")
        await link.emit(gsi)
        #expect(await eventually { answer.value == "Trunk Scan" }, "the request after the stop never completed")
        again.cancel()
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "GSI", "PSI,0", "GSI"])
    }

    // MARK: Whatever comes back

    /// An unsolicited `KAL,OK` (the spec says `KAL` has no reply), and a bare `ERR`, while a `GSI`
    /// is in flight: both are dropped; the `GSI` still gets its own reply and pushes still arrive.
    @Test func unsolicitedLinesDisturbNothing() async throws {
        let gsi = SimulatedScannerTransport.sds200GSIResponse()
        let link = KeepAliveLink(reply: { command in
            command.name == "KAL" ? [.fields(command: "KAL", fields: ["OK"]), .fields(command: "ERR", fields: [])] : []
        })
        let client = ScannerClient(transport: link, commandTimeout: .seconds(2))
        try await client.connect()
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive())
        #expect(await eventually { await link.keepAlives >= 2 })
        let reading = Task { try await client.scannerInfo() }
        #expect(await eventually { await link.attempts.contains("GSI") })
        await link.emit(.fields(command: "KAL", fields: ["OK"]))
        await link.emit(.fields(command: "ERR", fields: []))
        await link.emit(push("Between"))
        await link.emit(gsi)
        #expect(try await reading.value.mode == "Trunk Scan")
        #expect(await nextElement(pushes)?.mode == "Between")
        await client.disconnect()
    }

    // MARK: Renewing the subscription

    /// A renewal writes exactly the `PSI` the push was started with, never `KAL`, on the same
    /// timing as a `KAL`: the first an interval after the `PSI`, two never closer than one.
    @Test func renewalWritesTheSubscriptionsOwnPSI() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPush(interval: .milliseconds(250), keepAlive: renew()))
        #expect(await eventually { await link.texts.count >= 4 })
        await client.disconnect()

        let written = await link.written
        #expect(Array(written.prefix(3).map(\.text)) == ["PSI,250", "PSI,250", "PSI,250"], "\(written.map(\.text))")
        #expect(!written.contains { $0.text == "KAL" }, "\(written.map(\.text))")
        #expect(written.last?.text == "PSI,0")
        #expect(written.dropLast().allSatisfy { $0.text == "PSI,250" }, "\(written.map(\.text))")
        let psiAt = try #require(written.first?.at)
        let renewals = written.dropFirst().filter { $0.text == "PSI,250" }.map(\.at)
        for (index, at) in renewals.enumerated() {
            #expect(at - psiAt >= .milliseconds(50) * (index + 1), "renewal \(index + 1) at \(at - psiAt)")
        }
        for (earlier, later) in zip([psiAt] + renewals, renewals) {
            #expect(later - earlier >= .milliseconds(50), "two PSI,250 \(later - earlier) apart")
        }
    }

    /// `PSI,OK` to a renewal (and one that turns up late, while another request waits for its
    /// reply) reaches no caller: the request gets its own reply, the pushes go on, and nothing is
    /// reported as a failure.
    @Test func renewalOKReachesNoCaller() async throws {
        let link = KeepAliveLink(reply: { command in
            command.name == "PSI" ? [.fields(command: "PSI", fields: ["OK"])] : []
        })
        let client = ScannerClient(transport: link, commandTimeout: .seconds(2))
        let failures = Failures()
        try await client.connect()
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: renew(),
                                                onKeepAliveFailure: failures.report)
        #expect(await eventually { await link.keepAlives >= 2 })
        // The VOL's reply is held back until the test emits it; a late PSI,OK comes first.
        let answer = Answer()
        let reading = Task { answer.set(String(try await client.volume())) }
        #expect(await eventually { await link.attempts.contains("VOL") })
        await link.emit(.fields(command: "PSI", fields: ["OK"]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(answer.value == nil, "the VOL took a PSI,OK for its reply")
        await link.emit(.fields(command: "VOL", fields: ["7"]))
        #expect(await eventually { answer.value == "7" })
        try await reading.value
        #expect(await eventually { await link.keepAlives >= 3 }, "the renewals stopped")
        await link.emit(push("Live"))
        #expect(await nextElement(pushes)?.mode == "Live")
        #expect(failures.all.isEmpty, "\(failures.all)")
        await client.disconnect()
        #expect(await link.attempts.last == "PSI,0")
    }

    /// A stop while a renewal waits for the slot: the renewal writes nothing, and the `PSI,0`
    /// goes out once the slot frees.
    @Test func stopPushWhileARenewalWaitsWritesNoRenewal() async throws {
        let gsi = SimulatedScannerTransport.sds200GSIResponse()
        let link = KeepAliveLink()
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, commandTimeout: .seconds(2), keepAliveSleep: trigger.sleep)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: renew()))
        let reading = Task { try await client.scannerInfo() }
        #expect(await eventually { await link.attempts.contains("GSI") })
        trigger.fire()
        #expect(await eventually { trigger.woken == 1 })
        try await Task.sleep(for: .milliseconds(50))
        let stop = Task { try await client.stopPush() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.attempts == ["PSI,100", "GSI"], "something went out while the GSI's reply was pending")
        await link.emit(gsi)
        #expect(try await reading.value.mode == "Trunk Scan")
        try await stop.value
        #expect(await link.timeline == ["PSI,100", "GSI", "PSI,0"])
        trigger.fire()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.attempts == ["PSI,100", "GSI", "PSI,0"])
        await client.disconnect()
        let timeline = await link.timeline
        #expect(timeline == ["PSI,100", "GSI", "PSI,0", "close"], "\(timeline)")
    }

    /// A disconnect, and a consumer cancel, while a renewal waits for the slot: no renewal, then
    /// or later, after the `PSI,0` (or the close).
    @Test func disconnectAndConsumerCancelWriteNoRenewalAfterPSI0() async throws {
        let gsi = SimulatedScannerTransport.sds200GSIResponse()

        // disconnect(): the pending GSI fails, the waiting renewal gets the slot and writes nothing.
        do {
            let link = KeepAliveLink()
            let trigger = KeepAliveTrigger()
            let client = ScannerClient(transport: link, commandTimeout: .seconds(2), keepAliveSleep: trigger.sleep)
            let streams = Streams()
            defer { streams.release() }
            try await client.connect()
            streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: renew()))
            let reading = Task { try await client.scannerInfo() }
            #expect(await eventually { await link.attempts.contains("GSI") })
            trigger.fire()
            #expect(await eventually { trigger.woken == 1 })
            try await Task.sleep(for: .milliseconds(50))
            await client.disconnect()
            await #expect(throws: ScannerClientError.notConnected) { try await reading.value }
            #expect(await link.timeline == ["PSI,100", "GSI", "PSI,0", "close"])
            let count = await link.attempts.count
            trigger.fire()
            try await Task.sleep(for: .milliseconds(200))
            let attempts = await link.attempts
            #expect(attempts.count == count, "something was tried after the close: \(attempts)")
        }

        // A consumer cancel: its `PSI,0` waits for the slot behind the renewal, which writes nothing.
        do {
            let link = KeepAliveLink()
            let trigger = KeepAliveTrigger()
            let client = ScannerClient(transport: link, commandTimeout: .seconds(2), keepAliveSleep: trigger.sleep)
            try await client.connect()
            let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: renew())
            let consumer = Task { for await _ in pushes {} }
            let reading = Task { try await client.scannerInfo() }
            #expect(await eventually { await link.attempts.contains("GSI") })
            trigger.fire()
            #expect(await eventually { trigger.woken == 1 })
            try await Task.sleep(for: .milliseconds(50))
            consumer.cancel()
            await consumer.value
            try await Task.sleep(for: .milliseconds(100))
            #expect(await link.attempts == ["PSI,100", "GSI"], "something went out while the GSI's reply was pending")
            await link.emit(gsi)
            #expect(try await reading.value.mode == "Trunk Scan")
            #expect(await eventually { await link.attempts.contains("PSI,0") })
            let count = await link.attempts.count
            trigger.fire()
            try await Task.sleep(for: .milliseconds(200))
            let attempts = await link.attempts
            #expect(attempts == ["PSI,100", "GSI", "PSI,0"], "\(attempts)")
            #expect(attempts.count == count)
            await client.disconnect()
            #expect(await link.attempts == ["PSI,100", "GSI", "PSI,0"])
        }
    }

    /// A renewal already being written when `stopPush()` is called is finished first; then
    /// `PSI,0`, and nothing after.
    @Test func renewalInFlightIsWrittenBeforePSI0() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        // Held from the start, so a slow test can't let the first renewal through unheld.
        await link.setHold(true)
        streams.keep(try await client.startPush(interval: .milliseconds(100), keepAlive: renew()))
        #expect(await eventually { await link.heldCount == 1 })
        let stop = Task { try await client.stopPush() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.texts == ["PSI,100"], "PSI,0 went out while a renewal was still being written")
        await link.release()
        try await stop.value
        #expect(await link.texts == ["PSI,100", "PSI,100", "PSI,0"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await link.attempts == ["PSI,100", "PSI,100", "PSI,0"])
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "PSI,100", "PSI,0"])
    }

    /// A newer push ends the older push's renewals: its old `PSI,<ms>` is never written again,
    /// which would put the scanner back on the older rate.
    @Test func newerPushEndsTheOlderRenewal() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPush(interval: .milliseconds(250), keepAlive: renew()))
        streams.keep(try await client.startPush(interval: .milliseconds(100)))
        try await Task.sleep(for: .milliseconds(300))
        let texts = await link.texts
        let newer = try #require(texts.firstIndex(of: "PSI,100"))
        #expect(!texts[newer...].contains("PSI,250"), "\(texts)")
        await client.disconnect()
        let attempts = await link.attempts
        let newerAttempt = try #require(attempts.firstIndex(of: "PSI,100"))
        #expect(!attempts[newerAttempt...].contains("PSI,250"), "\(attempts)")
    }

    /// The same when the older push's renewal is already due and waiting for the slot as the
    /// newer push starts: once it gets the slot, it writes nothing.
    @Test func newerPushWhileARenewalWaitsWritesNoOldPSI() async throws {
        let gsi = SimulatedScannerTransport.sds200GSIResponse()
        let link = KeepAliveLink()
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, commandTimeout: .seconds(2), keepAliveSleep: trigger.sleep)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPush(interval: .milliseconds(250), keepAlive: renew()))
        let reading = Task { try await client.scannerInfo() }
        #expect(await eventually { await link.attempts.contains("GSI") })
        trigger.fire()
        #expect(await eventually { trigger.woken == 1 })
        try await Task.sleep(for: .milliseconds(50))
        streams.keep(try await client.startPush(interval: .milliseconds(100)))
        await link.emit(gsi)
        #expect(try await reading.value.mode == "Trunk Scan")
        trigger.fire()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await link.attempts == ["PSI,250", "GSI", "PSI,100"])
        await client.disconnect()
        #expect(await link.attempts == ["PSI,250", "GSI", "PSI,100", "PSI,0"])
    }

    /// A newer push while the older push's renewal is already being written: the newer `PSI` is
    /// written only once that renewal has landed, so the scanner ends on the newer rate, never the
    /// older one. (A request waiting for its reply doesn't hold the newer push up: only a renewal
    /// already on its way does; see `newerPushWhileARenewalWaitsWritesNoOldPSI`.)
    @Test func newerPushAfterAnInFlightRenewal() async throws {
        let link = KeepAliveLink()
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, keepAliveSleep: trigger.sleep)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        await link.setHold(true)
        streams.keep(try await client.startPush(interval: .milliseconds(250), keepAlive: renew()))
        trigger.fire()
        #expect(await eventually { await link.heldCount == 1 })
        let newer = Task { try await client.startPush(interval: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.timeline == ["PSI,250"], "the newer PSI went out while the older renewal was being written")
        await link.release()
        streams.keep(try await newer.value)
        trigger.fire()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.timeline == ["PSI,250", "PSI,250", "PSI,100"])
        await client.disconnect()
        let timeline = await link.timeline
        #expect(timeline == ["PSI,250", "PSI,250", "PSI,100", "PSI,0", "close"], "\(timeline)")
    }

    /// A newer push's wait on an in-flight renewal is over once the renewal has landed: nothing of
    /// it stays counted as an active push. After the newer push is stopped, a `disconnect()` writes
    /// no second `PSI,0` (a count left standing would make every later close write one with no
    /// subscription behind it).
    @Test func aFinishedRenewalWaitLeavesNoActivePushBehind() async throws {
        let link = KeepAliveLink()
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, keepAliveSleep: trigger.sleep)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        await link.setHold(true)
        streams.keep(try await client.startPush(interval: .milliseconds(250), keepAlive: renew()))
        trigger.fire()
        #expect(await eventually { await link.heldCount == 1 })
        let newer = Task { try await client.startPush(interval: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.timeline == ["PSI,250"], "the newer PSI went out while the older renewal was being written")
        await link.release()
        streams.keep(try await newer.value)
        try await client.stopPush()
        #expect(await link.attempts == ["PSI,250", "PSI,250", "PSI,100", "PSI,0"])
        await client.disconnect()
        let attempts = await link.attempts
        #expect(attempts.filter { $0 == "PSI,0" }.count == 1, "\(attempts)")
        #expect(attempts == ["PSI,250", "PSI,250", "PSI,100", "PSI,0"], "\(attempts)")
    }

    /// A `disconnect()` while a newer push waits for the older push's renewal to land: that
    /// renewal keeps the older subscription running on the scanner, so the close still writes
    /// `PSI,0` after it, and the newer push writes nothing (it throws `notConnected`).
    @Test func disconnectWhileANewerPushWaitsForAnInFlightRenewal() async throws {
        let link = KeepAliveLink()
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, keepAliveSleep: trigger.sleep)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        await link.setHold(true)
        streams.keep(try await client.startPush(interval: .milliseconds(250), keepAlive: renew()))
        trigger.fire()
        #expect(await eventually { await link.heldCount == 1 })
        let newer = Task { try await client.startPush(interval: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.timeline == ["PSI,250"])
        let closing = Task { await client.disconnect() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.timeline == ["PSI,250"], "the close went out while a renewal was still being written")
        await link.release()
        await closing.value
        await #expect(throws: ScannerClientError.self) { _ = try await newer.value }
        try await Task.sleep(for: .milliseconds(100))
        let timeline = await link.timeline
        #expect(timeline == ["PSI,250", "PSI,250", "PSI,0", "close"], "\(timeline)")
        #expect(await link.attempts == ["PSI,250", "PSI,250", "PSI,0"])
    }

    /// A rejection that comes before any renewal was written is the first `PSI`'s: no
    /// subscription exists, so the push ends (with no `PSI,0`), and no renewal is ever written.
    @Test func rejectedFirstPSIStillEndsThePush() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let failures = Failures()
        try await client.connect()
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: renew(.seconds(5)),
                                                onKeepAliveFailure: failures.report)
        await link.emit(.fields(command: "PSI", fields: ["NG"]))
        #expect(await nextElement(pushes) == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await link.attempts == ["PSI,100"])
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100"])
        #expect(failures.all.isEmpty, "\(failures.all)")
    }

    /// A `KAL` push is not a renewal: a `PSI` rejection after a `KAL` has been written still ends
    /// the push as before (no `PSI,0`, nothing reported), whatever the keep-alive wrote.
    @Test func rejectedPSIEndsAKALPushAfterAKeepAlive() async throws {
        let link = KeepAliveLink()
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, keepAliveSleep: trigger.sleep)
        let failures = Failures()
        try await client.connect()
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: keepAlive(),
                                                onKeepAliveFailure: failures.report)
        trigger.fire()
        #expect(await eventually { await link.keepAlives == 1 })
        await link.emit(.fields(command: "PSI", fields: ["NG"]))
        // A push after the rejection is never delivered: the stream has ended.
        await link.emit(push("After"))
        #expect(await nextElement(pushes)?.mode == nil, "the KAL push outlived a PSI rejection")
        trigger.fire()
        try await Task.sleep(for: .milliseconds(150))
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "KAL"])
        #expect(failures.all.isEmpty, "\(failures.all)")
    }

    /// A rejection after a renewal was written is the renewal's: the earlier subscription is still
    /// running, so the push stays (and its stop still writes `PSI,0`), its renewals stop, and the
    /// refusal is reported once, however many rejections come.
    @Test func rejectedRenewalKeepsThePush() async throws {
        let link = KeepAliveLink()
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, keepAliveSleep: trigger.sleep)
        let failures = Failures()
        try await client.connect()
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: renew(),
                                                onKeepAliveFailure: failures.report)
        trigger.fire()
        #expect(await eventually { await link.keepAlives == 1 })
        await link.emit(.fields(command: "PSI", fields: ["NG"]))
        #expect(await eventually { failures.all.count == 1 })
        await link.emit(push("After"))
        #expect(await nextElement(pushes)?.mode == "After", "the push ended")
        // No more renewals, however often the loop would have woken.
        trigger.fire(); trigger.fire(); trigger.fire()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await link.keepAlives == 1)
        #expect(await link.attempts == ["PSI,100", "PSI,100"])
        // A second rejection reports nothing more and still leaves the push.
        await link.emit(.fields(command: "PSI", fields: ["NG"]))
        await link.emit(push("Still"))
        #expect(await nextElement(pushes)?.mode == "Still", "the push ended")
        #expect(failures.all.count == 1)
        #expect(failures.all.first as? PushRenewalRefused == PushRenewalRefused())
        try await client.stopPush()
        #expect(await nextElement(pushes) == nil)
        #expect(await link.attempts == ["PSI,100", "PSI,100", "PSI,0"])
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "PSI,100", "PSI,0"])
        #expect(failures.all.count == 1)
    }

    /// A rejection that arrives while a renewal is still being written counts as the renewal's:
    /// part of it may already be with the scanner, so the push stays and is stopped with `PSI,0`.
    @Test func rejectionWhileARenewalIsBeingWrittenKeepsThePush() async throws {
        let link = KeepAliveLink()
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, keepAliveSleep: trigger.sleep)
        let failures = Failures()
        try await client.connect()
        await link.setHold(true)
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: renew(),
                                                onKeepAliveFailure: failures.report)
        trigger.fire()
        #expect(await eventually { await link.heldCount == 1 })
        await link.emit(.fields(command: "PSI", fields: ["NG"]))
        #expect(await eventually { failures.all.count == 1 })
        await link.emit(push("After"))
        #expect(await nextElement(pushes)?.mode == "After", "the push ended")
        await link.release()
        #expect(await eventually { await link.keepAlives == 1 })
        trigger.fire()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await link.attempts == ["PSI,100", "PSI,100"])
        try await client.stopPush()
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "PSI,100", "PSI,0"])
        #expect(failures.all.count == 1)
        #expect(failures.all.first as? PushRenewalRefused == PushRenewalRefused())
    }

    /// A renewal write that fails is reported once and never retried; a rejection that then
    /// comes (for the write that failed part-way) reports nothing more and leaves the push.
    @Test func failedRenewalWriteIsReportedOnceAndNeverRetried() async throws {
        let link = KeepAliveLink()
        let client = ScannerClient(transport: link)
        let failures = Failures()
        try await client.connect()
        await link.setFail(true)
        let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: renew(),
                                                onKeepAliveFailure: failures.report)
        #expect(await eventually { failures.all.count == 1 })
        // Two intervals later: no second attempt, no second report.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await link.attempts == ["PSI,100", "PSI,100"])
        let error = try #require(failures.all.first as? SerialTransportError)
        #expect(error == .writeFailed("short write: 1 of 4 bytes"))
        await link.emit(.fields(command: "PSI", fields: ["NG"]))
        await link.emit(push("After"))
        #expect(await nextElement(pushes)?.mode == "After", "the push ended")
        #expect(failures.all.count == 1)
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "PSI,100", "PSI,0"])
        #expect(failures.all.count == 1)
    }

    /// A renewal that falls due while a request waits for its reply is written only once the
    /// reply has come: it takes the request slot like any request.
    @Test func renewalWaitsForAPendingReply() async throws {
        let gsi = SimulatedScannerTransport.sds200GSIResponse()
        let link = KeepAliveLink()  // The GSI's reply is held back until the test emits it.
        let trigger = KeepAliveTrigger()
        let client = ScannerClient(transport: link, commandTimeout: .seconds(2), keepAliveSleep: trigger.sleep)
        let streams = Streams()
        defer { streams.release() }
        try await client.connect()
        streams.keep(try await client.startPushUpdates(interval: .milliseconds(100), keepAlive: renew()))
        let reading = Task { try await client.scannerInfo() }
        #expect(await eventually { await link.attempts.contains("GSI") })
        trigger.fire()
        #expect(await eventually { trigger.woken == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await link.attempts == ["PSI,100", "GSI"], "a renewal went out while the GSI's reply was pending")
        await link.emit(gsi)
        #expect(try await reading.value.mode == "Trunk Scan")
        #expect(await eventually { await link.keepAlives == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await link.texts == ["PSI,100", "GSI", "PSI,100"])
        await client.disconnect()
        #expect(await link.attempts == ["PSI,100", "GSI", "PSI,100", "PSI,0"])
    }

    // MARK: Against the mock SDS150

    /// The mock's pushes stop 183 s of scenario time after the `PSI` unless a `KAL` restarts the
    /// count (that each one does is the mock's assumption): with the keep-alive they go on past it.
    @Test func keepsTheMockPushingPastItsLifetime() async throws {
        let clock = MockClock.stepped(at: 0)
        let mock = MockSerialScanner(scenario: .default, clock: clock)
        let path = try await mock.start()
        let client = ScannerClient(transport: SerialTransport(path: path), commandTimeout: .milliseconds(700))
        do {
            try await client.connect()
            let pushes = try await client.startPushUpdates(interval: .milliseconds(30), keepAlive: keepAlive(.milliseconds(60)))
            let counter = Task {
                var count = 0
                for await _ in pushes { count += 1 }
                return count
            }
            let kals = { @Sendable in await mock.receivedCommands.filter { $0 == "KAL" }.count }
            // Each step stays inside 183 s of the latest KAL, which arrives after the step.
            for time in [100.0, 200.0, 300.0] {
                clock.set(time)
                let before = await kals()
                #expect(await eventually { await kals() > before }, "no KAL after scenario time \(time)")
            }
            let sent = await mock.pushesSent
            #expect(await eventually { await mock.pushesSent >= sent + 3 }, "pushes stopped")
            await client.disconnect()
            #expect(await counter.value > 0)
        } catch {
            await client.disconnect()
            await mock.stop()
            throw error
        }
        await mock.stop()
        let commands = await mock.receivedCommands
        #expect(commands.first == "PSI,30")
        #expect(commands.last == "PSI,0")
        #expect(commands.dropFirst().dropLast().allSatisfy { $0 == "KAL" }, "\(commands)")
        #expect(await mock.activeSubscribers == 0)
    }

    // MARK: Against the mock SDS100

    /// What `watch` does when the scanner rejects a renewal: the push goes on (the earlier
    /// subscription still runs), one failure is reported, no further renewal is written, and the
    /// stop's `PSI,0` leaves no subscription behind.
    @Test func rejectedRenewalOnTheMockLeavesNoSubscription() async throws {
        let clock = MockClock.stepped(at: 0)
        let mock = MockSerialScanner(scenario: .default, clock: clock, personality: .sds100)
        let path = try await mock.start()
        let client = ScannerClient(transport: SerialTransport(path: path), commandTimeout: .milliseconds(700))
        let failures = Failures()
        let renewals = { @Sendable in await mock.receivedCommands.filter { $0 == "PSI,100" }.count }
        var written = 0
        do {
            try await client.connect()
            let pushes = try await client.startPush(interval: .milliseconds(100), keepAlive: renew(.milliseconds(150)),
                                                    onKeepAliveFailure: failures.report)
            let counted = Mutex(0)
            let counter = Task { for await _ in pushes { counted.withLock { $0 += 1 } } }
            #expect(await eventually { counted.withLock { $0 } >= 1 }, "no first push")
            // The next `PSI` (a renewal: the first is due 150 ms after the subscription) is rejected.
            await mock.setFaults(MockFaults(dropCount: 1, rejectNext: "PSI"))
            #expect(await eventually { failures.all.count == 1 }, "the rejection wasn't reported")
            #expect(failures.all.first as? PushRenewalRefused == PushRenewalRefused())
            written = await renewals()
            #expect(written >= 2)
            // Pushes keep arriving, and no renewal follows over several intervals.
            let atRejection = counted.withLock { $0 }
            #expect(await eventually { counted.withLock { $0 } >= atRejection + 3 }, "pushes stopped")
            try await Task.sleep(for: .milliseconds(500))
            #expect(await renewals() == written, "a renewal followed the rejection")
            #expect(failures.all.count == 1)
            try await client.stopPush()
            await client.disconnect()
            _ = await counter.value
        } catch {
            await client.disconnect()
            await mock.stop()
            throw error
        }
        await mock.stop()
        let commands = await mock.receivedCommands
        // The subscription, its renewals up to the rejected one, and the stop.
        #expect(commands == Array(repeating: "PSI,100", count: written) + ["PSI,0"], "\(commands)")
        #expect(await mock.activeSubscribers == 0)
    }
}
