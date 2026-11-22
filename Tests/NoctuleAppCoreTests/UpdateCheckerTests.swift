// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleStore
import Synchronization
import Testing

@testable import NoctuleAppCore

// MARK: - Test doubles

private let feedURL = URL(string: "file:///fictional/latest.json")!
private let releasePage = "https://github.com/noctule-dev/noctule-scan/releases/tag/v"
private let releaseNotes = "Fictional notes."

private func version(_ text: String) -> AppVersion { AppVersion(text)! }

private func releaseBody(_ tag: String) -> Data {
    Data(
        """
        {"tag_name":"v\(tag)","prerelease":false,"draft":false,"body":"\(releaseNotes)","html_url":"\(releasePage)\(tag)"}
        """.utf8)
}

/// The release `releaseBody(tag)` decodes to.
private func release(_ tag: String) -> LatestRelease {
    LatestRelease(version: version(tag), notes: releaseNotes, page: URL(string: releasePage + tag)!)
}

/// A count a test can wait on. A wait ends when the count reaches its target, or when the waiting
/// task is cancelled (as a time limit does), so a test that goes wrong fails instead of hanging.
private final class CountSignal: Sendable {
    private struct State {
        var count = 0
        var nextID = 0
        var waiters: [Int: (target: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
        var cancelled: Set<Int> = []
    }

    private let state = Mutex(State())

    var count: Int { state.withLock { $0.count } }

    func increment() {
        let ready = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.count += 1
            let done = s.waiters.filter { $0.value.target <= s.count }
            done.keys.forEach { s.waiters.removeValue(forKey: $0) }
            return done.values.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    func wait(for target: Int) async {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.count >= target || s.cancelled.remove(id) != nil { return true }
                    s.waiters[id] = (target, continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiting = state.withLock { s -> CheckedContinuation<Void, Never>? in
                if let waiter = s.waiters.removeValue(forKey: id) { return waiter.continuation }
                s.cancelled.insert(id)
                return nil
            }
            waiting?.resume()
        }
    }
}

/// Answers each fetch with the current reply, counting calls; while held, a fetch waits for `release()`.
private actor FakeFetcher: ReleaseFetching {
    enum Reply: Sendable {
        case answer(Int, Data)
        case error(any Error)
        static func latest(_ tag: String) -> Reply { .answer(200, releaseBody(tag)) }
    }

    private var reply: Reply
    private let fetched = CountSignal()
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var calls: Int { fetched.count }

    init(_ reply: Reply) { self.reply = reply }

    func fetch(_ url: URL) async throws -> (status: Int, body: Data) {
        fetched.increment()
        if holding { await withCheckedContinuation { held.append($0) } }
        switch reply {
        case .answer(let status, let body): return (status, body)
        case .error(let error): throw error
        }
    }

    func setReply(_ reply: Reply) { self.reply = reply }
    func hold() { holding = true }

    func release() {
        holding = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func waitForCalls(_ count: Int) async { await fetched.wait(for: count) }
}

/// Records each requested sleep and holds it until `resume()`; a cancelled sleep throws.
private actor TestSleeper {
    private(set) var requests: [Duration] = []
    private let requested = CountSignal()
    private let cancelled = CountSignal()
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledEarly: Set<Int> = []
    private var nextID = 0

    func sleep(_ duration: Duration) async throws {
        nextID += 1
        let id = nextID
        requests.append(duration)
        requested.increment()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                register(id, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func register(_ id: Int, _ continuation: CheckedContinuation<Void, any Error>) {
        if cancelledEarly.remove(id) != nil {
            cancelled.increment()
            continuation.resume(throwing: CancellationError())
        } else {
            pending[id] = continuation
        }
    }

    private func cancel(_ id: Int) {
        if let continuation = pending.removeValue(forKey: id) {
            cancelled.increment()
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledEarly.insert(id)
        }
    }

    func waitForCancellations(_ count: Int) async { await cancelled.wait(for: count) }

    /// Ends every pending sleep normally.
    func resume() {
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume() }
    }

    func waitForRequests(_ count: Int) async { await requested.wait(for: count) }
}

private final class TestNow: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var date: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

private final class LogLines: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

private struct Shown: Equatable {
    let result: UpdateCheckResult
    let trigger: UpdateCheckTrigger
    init(_ result: UpdateCheckResult, _ trigger: UpdateCheckTrigger) {
        self.result = result
        self.trigger = trigger
    }
}

@MainActor private final class Shelf {
    var shown: [Shown] = []
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400
private let hour: TimeInterval = 3_600

/// One checker and everything it talks to.
@MainActor private struct Harness {
    let fetcher: FakeFetcher
    let sleeper = TestSleeper()
    let clock = TestNow(start)
    let store: InMemoryUpdatePreferences
    let shelf = Shelf()
    let logs = LogLines()
    let checker: UpdateChecker

    init(running: String = "1.0.0", feed: URL? = feedURL, reply: FakeFetcher.Reply = .latest("1.0.0"),
         preferences: UpdatePreferences = .init(), store: InMemoryUpdatePreferences? = nil) {
        let fetcher = FakeFetcher(reply)
        let sleeper = sleeper, clock = clock, shelf = shelf, logs = logs
        let store = store ?? InMemoryUpdatePreferences(preferences)
        self.fetcher = fetcher
        self.store = store
        checker = UpdateChecker(
            configuration: UpdateCheckConfiguration(runningVersionText: running, runningVersion: AppVersion(running),
                                                    feed: feed),
            preferences: store, fetcher: fetcher,
            now: { clock.date },
            sleep: { try await sleeper.sleep($0) },
            present: { shelf.shown.append(Shown($0, $1)) },
            log: { logs.append($0) })
    }

    var shown: [Shown] { shelf.shown }
    var saved: UpdatePreferences { get async { await store.updatePreferences() } }

    /// Lets queued main-actor work run, so a test can see that nothing more happens.
    func yield() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private func preferences(on: Bool = true, lastChecked: Date? = nil, skipped: String? = nil) -> UpdatePreferences {
    var preferences = UpdatePreferences()
    preferences.checkAutomatically = on
    preferences.lastChecked = lastChecked
    preferences.skippedVersion = skipped
    return preferences
}

// MARK: - Tests

/// The update checker's state machine (update-check design §5.1–§5.6).
@MainActor @Suite(.timeLimit(.minutes(1))) struct UpdateCheckerTests {
    @Test func launchFindsAnUpdate() async {
        let h = Harness(reply: .latest("1.0.1"))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        let offer = UpdateOffer(release: release("1.0.1"), running: version("1.0.0"))
        #expect(h.shown == [Shown(.updateAvailable(offer), .launch)])
        #expect(h.logs.all == ["Noctule Scan 1.0.1 is available"])
        #expect(h.checker.lastChecked == start)
        #expect(await h.saved.lastChecked == start)
        h.checker.stop()
    }

    @Test func launchUpToDateShowsNothing() async {
        let h = Harness(reply: .latest("1.0.0"))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        #expect(h.shown.isEmpty)
        #expect(h.logs.all == ["up to date (1.0.0)"])
        h.checker.stop()
    }

    @Test func betaIsToldAboutItsFinal() async {
        let h = Harness(running: "1.0.0-beta.3", reply: .latest("1.0.0"))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        let offer = UpdateOffer(release: release("1.0.0"), running: version("1.0.0-beta.3"))
        #expect(h.shown == [Shown(.updateAvailable(offer), .launch)])
        h.checker.stop()
    }

    @Test func aheadOfTheRelease() async {
        let h = Harness(running: "1.1.0-beta.1", reply: .latest("1.0.0"))
        await h.checker.checkNow()
        #expect(h.shown == [Shown(.upToDate(running: version("1.1.0-beta.1"), latest: version("1.0.0")), .manual)])
        #expect(h.logs.all.isEmpty)
    }

    @Test func launchFailureIsOnlyLogged() async {
        let missing = Harness(reply: .answer(404, Data()))
        await missing.checker.start()
        await missing.checker.waitUntilIdle()
        #expect(missing.shown.isEmpty)
        #expect(missing.logs.all == ["no release published yet"])
        #expect(missing.checker.lastChecked == nil)
        #expect(await missing.saved.lastChecked == nil)
        missing.checker.stop()

        let offline = Harness(reply: .error(URLError(.notConnectedToInternet)))
        await offline.checker.start()
        await offline.checker.waitUntilIdle()
        #expect(offline.shown.isEmpty)
        #expect(offline.logs.all == [URLError(.notConnectedToInternet).localizedDescription])
        #expect(offline.checker.lastChecked == nil)
        offline.checker.stop()
    }

    @Test func manualShowsEveryOutcome() async {
        let h = Harness()
        let cases: [(FakeFetcher.Reply, UpdateCheckResult)] = [
            (.latest("1.0.0"), .upToDate(running: version("1.0.0"), latest: version("1.0.0"))),
            (.answer(404, Data()), .failed(.noRelease)),
            (.answer(403, Data()), .failed(.rateLimited)),
            (.answer(200, Data("garbage".utf8)), .failed(.unreadable("not a release"))),
            (.error(URLError(.timedOut)), .failed(.network(URLError(.timedOut).localizedDescription))),
        ]
        for (reply, _) in cases {
            await h.fetcher.setReply(reply)
            await h.checker.checkNow()
        }
        #expect(h.shown == cases.map { Shown($0.1, .manual) })
        #expect(await h.fetcher.calls == cases.count)
        #expect(h.logs.all.isEmpty)
    }

    @Test func preferenceOffMeansNoLaunchCheck() async {
        let h = Harness(reply: .latest("1.0.1"), preferences: preferences(on: false))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        await h.yield()
        #expect(!h.checker.checksAutomatically)
        #expect(await h.fetcher.calls == 0)
        #expect(await h.sleeper.requests.isEmpty)

        await h.checker.checkNow()
        #expect(await h.fetcher.calls == 1)
        let offer = UpdateOffer(release: release("1.0.1"), running: version("1.0.0"))
        #expect(h.shown == [Shown(.updateAvailable(offer), .manual)])
        await h.yield()
        #expect(await h.sleeper.requests.isEmpty)
    }

    @Test func developmentBuildNeverChecksByItself() async {
        let h = Harness(running: "0.0.0", reply: .latest("1.0.1"))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        #expect(await h.fetcher.calls == 0)
        await h.checker.checkNow()
        #expect(h.shown == [Shown(.developmentBuild(versionText: "0.0.0"), .manual)])
        #expect(await h.fetcher.calls == 0)
        #expect(h.logs.all.isEmpty)
        #expect(await h.sleeper.requests.isEmpty)
    }

    @Test func noFeedManual() async {
        let h = Harness(feed: nil, reply: .latest("1.0.1"))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        #expect(await h.fetcher.calls == 0)
        await h.checker.checkNow()
        #expect(h.shown == [Shown(.failed(.disabledForTesting), .manual)])
        #expect(await h.fetcher.calls == 0)
        #expect(h.logs.all.isEmpty)
        #expect(await h.sleeper.requests.isEmpty)
    }

    @Test func skipHidesThatVersionFromAutomaticChecks() async {
        let store = InMemoryUpdatePreferences()
        let first = Harness(store: store)
        await first.checker.skip(version("1.0.1"))
        #expect(await store.updatePreferences().skippedVersion == "1.0.1")

        let skipped = Harness(reply: .latest("1.0.1"), store: store)
        await skipped.checker.start()
        await skipped.checker.waitUntilIdle()
        #expect(skipped.shown.isEmpty)
        #expect(skipped.logs.all == ["skipped 1.0.1"])
        skipped.checker.stop()

        let newer = Harness(reply: .latest("1.0.2"), store: store)
        await newer.checker.start()
        await newer.checker.waitUntilIdle()
        let offer = UpdateOffer(release: release("1.0.2"), running: version("1.0.0"))
        #expect(newer.shown == [Shown(.updateAvailable(offer), .launch)])
        newer.checker.stop()

        let manual = Harness(reply: .latest("1.0.1"), store: store)
        await manual.checker.checkNow()
        let skippedOffer = UpdateOffer(release: release("1.0.1"), running: version("1.0.0"))
        #expect(manual.shown == [Shown(.updateAvailable(skippedOffer), .manual)])
    }

    @Test func schedulesADayAfterTheLastCheck() async {
        let h = Harness(reply: .latest("1.0.0"))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        await h.sleeper.waitForRequests(1)
        #expect(await h.sleeper.requests == [UpdateChecker.interval])

        await h.fetcher.setReply(.latest("1.0.1"))
        await h.sleeper.resume()
        await h.fetcher.waitForCalls(2)
        await h.checker.waitUntilIdle()
        let offer = UpdateOffer(release: release("1.0.1"), running: version("1.0.0"))
        #expect(h.shown == [Shown(.updateAvailable(offer), .scheduled)])
        #expect(h.logs.all == ["up to date (1.0.0)", "Noctule Scan 1.0.1 is available"])
        await h.sleeper.waitForRequests(2)
        h.checker.stop()
    }

    @Test func futureLastCheckWaitsAtMostADay() async {
        let h = Harness(reply: .answer(500, Data()),
                        preferences: preferences(lastChecked: start.addingTimeInterval(3 * day)))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        #expect(h.logs.all == ["couldn't read GitHub's answer (status 500)"])
        await h.sleeper.waitForRequests(1)
        let requested = await h.sleeper.requests
        #expect(requested.count == 1)
        #expect(requested.allSatisfy { $0 > .zero && $0 <= UpdateChecker.interval })
        h.checker.stop()
    }

    @Test func failureWaitsAFullDay() async {
        let h = Harness(reply: .answer(429, Data()), preferences: preferences(lastChecked: start.addingTimeInterval(-3 * day)))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        #expect(h.logs.all == ["rate limited by GitHub"])
        await h.sleeper.waitForRequests(1)
        #expect(await h.sleeper.requests == [UpdateChecker.interval])
        await h.yield()
        #expect(await h.fetcher.calls == 1)
        h.checker.stop()
    }

    @Test func developmentBuildWithNoFeedManual() async {
        let h = Harness(running: "0.0.0", feed: nil, reply: .latest("1.0.1"))
        await h.checker.start()
        await h.checker.checkNow()
        #expect(h.shown == [Shown(.developmentBuild(versionText: "0.0.0"), .manual)])
        #expect(await h.fetcher.calls == 0)
        #expect(h.logs.all.isEmpty)
    }

    @Test func manualCheckResetsTheTimer() async {
        let h = Harness(reply: .latest("1.0.0"))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        await h.sleeper.waitForRequests(1)

        h.clock.advance(20 * hour)
        await h.checker.checkNow()
        await h.sleeper.waitForCancellations(1)
        await h.sleeper.waitForRequests(2)
        #expect(await h.sleeper.requests == [UpdateChecker.interval, UpdateChecker.interval])
        #expect(await h.fetcher.calls == 2)
        h.checker.stop()
    }

    @Test func wakeAfterADayChecksOnce() async {
        let h = Harness(reply: .latest("1.0.0"))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        await h.sleeper.waitForRequests(1)

        h.clock.advance(2 * day)
        h.checker.handleWake()
        await h.fetcher.waitForCalls(2)
        await h.checker.waitUntilIdle()
        await h.sleeper.waitForRequests(2)
        #expect(await h.sleeper.requests == [UpdateChecker.interval, UpdateChecker.interval])
        #expect(await h.fetcher.calls == 2)

        // A wake that isn't overdue only restarts the timer.
        h.clock.advance(hour)
        h.checker.handleWake()
        await h.sleeper.waitForRequests(3)
        await h.yield()
        #expect(await h.fetcher.calls == 2)
        #expect(await h.sleeper.requests.last == .seconds(23 * hour))
        h.checker.stop()
    }

    @Test func turningOnChecksWhenOverdue() async {
        let overdue = Harness(preferences: preferences(on: false, lastChecked: start.addingTimeInterval(-2 * day)))
        await overdue.checker.start()
        await overdue.checker.setChecksAutomatically(true)
        await overdue.checker.waitUntilIdle()
        #expect(await overdue.fetcher.calls == 1)
        #expect(overdue.checker.checksAutomatically)
        #expect(await overdue.saved.checkAutomatically)
        overdue.checker.stop()

        let recent = Harness(preferences: preferences(on: false, lastChecked: start.addingTimeInterval(-hour)))
        await recent.checker.start()
        await recent.checker.setChecksAutomatically(true)
        await recent.sleeper.waitForRequests(1)
        await recent.yield()
        #expect(await recent.fetcher.calls == 0)
        let requested = await recent.sleeper.requests
        #expect(requested.count == 1)
        #expect(requested.allSatisfy { $0 > .seconds(22 * hour) && $0 <= .seconds(23 * hour) })
        recent.checker.stop()
    }

    @Test func turningOffStopsTheTimer() async {
        let h = Harness(reply: .latest("1.0.0"))
        await h.checker.start()
        await h.checker.waitUntilIdle()
        await h.sleeper.waitForRequests(1)
        await h.checker.setChecksAutomatically(false)
        #expect(await h.saved.checkAutomatically == false)
        await h.sleeper.waitForCancellations(1)
        h.checker.handleWake()
        await h.yield()
        #expect(await h.sleeper.requests.count == 1)
        #expect(await h.fetcher.calls == 1)
    }

    @Test func turningOffDropsAnInFlightAutomaticResult() async {
        let h = Harness(reply: .latest("1.0.1"))
        await h.fetcher.hold()
        await h.checker.start()
        await h.fetcher.waitForCalls(1)
        await h.checker.setChecksAutomatically(false)
        await h.fetcher.release()
        await h.checker.waitUntilIdle()
        await h.yield()
        #expect(h.shown.isEmpty)
        #expect(h.logs.all == ["Noctule Scan 1.0.1 is available"])
        #expect(await h.sleeper.requests.isEmpty)
        #expect(await h.saved.checkAutomatically == false)
    }

    @Test func manualJoinsARunningCheck() async {
        let h = Harness(reply: .latest("1.0.1"))
        await h.fetcher.hold()
        await h.checker.start()
        await h.fetcher.waitForCalls(1)
        let manual = Task { await h.checker.checkNow() }
        await h.yield()
        await h.fetcher.release()
        await manual.value
        let offer = UpdateOffer(release: release("1.0.1"), running: version("1.0.0"))
        #expect(h.shown == [Shown(.updateAvailable(offer), .manual)])
        #expect(await h.fetcher.calls == 1)
        // It started as the launch check, so it logs as one.
        #expect(h.logs.all == ["Noctule Scan 1.0.1 is available"])
        h.checker.stop()
    }

    @Test func isCheckingTracksTheCheck() async {
        let h = Harness()
        #expect(!h.checker.isChecking)
        await h.fetcher.hold()
        await h.checker.start()
        await h.fetcher.waitForCalls(1)
        #expect(h.checker.isChecking)
        await h.fetcher.release()
        await h.checker.waitUntilIdle()
        #expect(!h.checker.isChecking)
        h.checker.stop()
    }

    @Test func stopCancelsAnInFlightCheck() async {
        let h = Harness(reply: .latest("1.0.1"))
        await h.fetcher.hold()
        await h.checker.start()
        await h.fetcher.waitForCalls(1)
        h.checker.stop()
        #expect(!h.checker.isChecking)
        await h.fetcher.release()
        await h.checker.waitUntilIdle()
        await h.yield()
        #expect(h.shown.isEmpty)
        #expect(h.logs.all.isEmpty)
        #expect(h.checker.lastChecked == nil)
        #expect(await h.saved.lastChecked == nil)
        #expect(await h.sleeper.requests.isEmpty)

        // Nothing starts again after a stop.
        await h.checker.checkNow()
        h.checker.handleWake()
        await h.yield()
        #expect(await h.fetcher.calls == 1)
        #expect(h.shown.isEmpty)
    }

    @Test func stopCancelsTheTimer() async {
        let h = Harness()
        await h.checker.start()
        await h.checker.waitUntilIdle()
        await h.sleeper.waitForRequests(1)
        h.checker.stop()
        await h.sleeper.waitForCancellations(1)
        await h.yield()
        #expect(await h.sleeper.requests.count == 1)
        #expect(await h.fetcher.calls == 1)
    }

    @Test func logLineFormat() {
        let date = Date(timeIntervalSince1970: 1_800_006_060)
        #expect(UpdateCheckLog.line("up to date (1.0.0)", at: date, timeZone: .gmt)
            == "NoctuleScan: 09:41:00 update check: up to date (1.0.0)")
    }
}
