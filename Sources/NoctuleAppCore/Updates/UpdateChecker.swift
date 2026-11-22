// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleStore
import Observation

/// What started a check.
public enum UpdateCheckTrigger: Sendable, Equatable {
    case launch, scheduled, manual
}

/// A release newer than the running version.
public struct UpdateOffer: Equatable, Sendable {
    public let release: LatestRelease
    public let running: AppVersion

    public init(release: LatestRelease, running: AppVersion) {
        self.release = release
        self.running = running
    }
}

/// How a check ended.
public enum UpdateCheckResult: Equatable, Sendable {
    case updateAvailable(UpdateOffer)
    case upToDate(running: AppVersion, latest: AppVersion)
    case developmentBuild(versionText: String)
    case failed(UpdateCheckFailure)
}

/// Asks the release feed whether a newer version exists: at launch, a day after the last check,
/// after a wake that finds one overdue, and when asked (update-check design §5.1–§5.6).
///
/// One check at a time; a manual check joins a running one. The fetch runs off the main actor and
/// nothing it throws escapes. A manual check presents every result; an automatic one presents
/// only an update that isn't the skipped version, while checks are still automatic, and logs one
/// line whatever it found. `lastChecked` moves only on a successful check. After `stop()` nothing
/// is presented, logged, saved or scheduled.
@MainActor @Observable
public final class UpdateChecker {
    public static let interval: Duration = .seconds(86_400)
    private static let intervalSeconds = TimeInterval(interval.components.seconds)

    public private(set) var isChecking = false
    /// The preference, loaded by `start()`.
    public private(set) var checksAutomatically = UpdatePreferences().checkAutomatically
    /// When the last successful check ended.
    public private(set) var lastChecked: Date?

    @ObservationIgnored private let configuration: UpdateCheckConfiguration
    @ObservationIgnored private let store: any UpdatePreferencesStore
    @ObservationIgnored private let fetcher: any ReleaseFetching
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let present: @MainActor (UpdateCheckResult, UpdateCheckTrigger) -> Void
    @ObservationIgnored private let log: @Sendable (String) -> Void

    /// The preferences as last loaded or changed here; nil until loaded.
    @ObservationIgnored private var preferences: UpdatePreferences?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    /// When the last check of any outcome ended, so a failure waits a full interval too.
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var check: Task<Void, Never>?
    /// The newest check task, kept after a stop so tests can wait for it.
    @ObservationIgnored private var latestCheck: Task<Void, Never>?
    @ObservationIgnored private var checkID = 0
    @ObservationIgnored private var manualJoined = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var timerID = 0
    /// Saves run one after another, so the newest preferences are the ones left in the store.
    @ObservationIgnored private var saving: Task<Void, Never>?

    /// The default `sleep` is on `SuspendingClock`, which stops while the Mac sleeps, so a check
    /// never falls due during a dark wake: after a full wake, `handleWake()` recomputes the timer
    /// from the wall clock and runs an overdue check then (design §5.2).
    public init(configuration: UpdateCheckConfiguration, preferences: any UpdatePreferencesStore,
                fetcher: any ReleaseFetching,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = {
                    try await SuspendingClock().sleep(for: $0)
                },
                present: @escaping @MainActor (UpdateCheckResult, UpdateCheckTrigger) -> Void,
                log: @escaping @Sendable (String) -> Void) {
        self.configuration = configuration
        self.store = preferences
        self.fetcher = fetcher
        self.now = now
        self.sleep = sleep
        self.present = present
        self.log = log
    }

    /// Whether this build asks the feed at all: a release version and a feed.
    private var canCheck: Bool { !configuration.isDevelopmentBuild && configuration.feed != nil }

    /// Loads the preferences, then runs the launch check when checks are automatic and this build
    /// can check. Says nothing otherwise (the configuration's notes already did).
    public func start() async {
        guard !started, !stopped else { return }
        _ = await loadPreferences()
        guard !started, !stopped else { return }
        started = true
        guard checksAutomatically, canCheck else { return }
        beginCheck(.launch)
    }

    /// A check the person asked for, whatever the preference; its result is always presented.
    /// Joins a running check, whose result is then presented as manual.
    public func checkNow() async {
        guard !stopped else { return }
        _ = await loadPreferences()
        guard !stopped else { return }
        if configuration.isDevelopmentBuild {
            present(.developmentBuild(versionText: configuration.runningVersionText), .manual)
            return
        }
        guard configuration.feed != nil else {
            present(.failed(.disabledForTesting), .manual)
            return
        }
        await beginCheck(.manual)?.value
    }

    /// Saves the preference. Off stops the timer (a running check still ends, unpresented unless
    /// manual); on starts it, checking at once if the last check is a full interval old.
    public func setChecksAutomatically(_ on: Bool) async {
        var updated = await loadPreferences()
        updated.checkAutomatically = on
        preferences = updated
        checksAutomatically = on
        let saved = save(updated)
        if on { schedule() } else { cancelTimer() }
        await saved.value
    }

    /// Automatic checks stop presenting this version; a manual check still does.
    public func skip(_ version: AppVersion) async {
        var updated = await loadPreferences()
        updated.skippedVersion = version.description
        preferences = updated
        await save(updated).value
    }

    /// After a full wake: the timer is set again from the clock, and a check that fell due runs once.
    public func handleWake() {
        guard started, !stopped, check == nil else { return }
        schedule()
    }

    /// Cancels the timer and any check in flight. No check result is presented, logged, saved or
    /// scheduled afterwards, and no check starts again; the person's own toggle and skip still save.
    public func stop() {
        stopped = true
        cancelTimer()
        check?.cancel()
        check = nil
        checkID += 1
        manualJoined = false
        isChecking = false
    }

    /// For tests: returns once the newest check has ended and every save is done (or the test is
    /// cancelled, so a checker that never settles fails the test's time limit instead of hanging).
    func waitUntilIdle() async {
        var seen: Task<Void, Never>?
        while !Task.isCancelled, let task = latestCheck, task != seen {
            seen = task
            await task.value
        }
        await saving?.value
    }

    // MARK: - Checks

    private func loadPreferences() async -> UpdatePreferences {
        if let preferences { return preferences }
        let loaded = await store.updatePreferences()
        if let preferences { return preferences }
        preferences = loaded
        checksAutomatically = loaded.checkAutomatically
        lastChecked = loaded.lastChecked
        return loaded
    }

    /// Starts a check, or joins the one running. Nil when this build can't check, or after a stop.
    @discardableResult
    private func beginCheck(_ trigger: UpdateCheckTrigger) -> Task<Void, Never>? {
        guard !stopped, !configuration.isDevelopmentBuild, let feed = configuration.feed,
              let running = configuration.runningVersion else { return nil }
        if let check {
            if trigger == .manual { manualJoined = true }
            return check
        }
        checkID += 1
        let id = checkID
        manualJoined = false
        isChecking = true
        let fetcher = self.fetcher
        let task = Task { [weak self] in
            let outcome = await UpdateChecker.fetchRelease(from: feed, with: fetcher)
            self?.finish(outcome, trigger: trigger, running: running, id: id)
        }
        check = task
        latestCheck = task
        return task
    }

    @concurrent
    private nonisolated static func fetchRelease(from feed: URL, with fetcher: any ReleaseFetching) async
        -> Result<LatestRelease, UpdateCheckFailure> {
        do {
            let (status, body) = try await fetcher.fetch(feed)
            return ReleaseFeed.decode(status: status, body: body)
        } catch {
            return .failure(ReleaseFeed.failure(for: error))
        }
    }

    private func finish(_ outcome: Result<LatestRelease, UpdateCheckFailure>, trigger: UpdateCheckTrigger,
                        running: AppVersion, id: Int) {
        guard id == checkID, !stopped else { return }
        let manual = trigger == .manual || manualJoined
        check = nil
        manualJoined = false
        isChecking = false
        let ended = now()
        lastAttempt = ended
        let result: UpdateCheckResult
        switch outcome {
        case .success(let release):
            lastChecked = ended
            if var updated = preferences {
                updated.lastChecked = ended
                preferences = updated
                save(updated, unlessStopped: true)
            }
            result = release.version > running
                ? .updateAvailable(UpdateOffer(release: release, running: running))
                : .upToDate(running: running, latest: release.version)
        case .failure(let failure):
            result = .failed(failure)
        }
        let skipped = isSkipped(result)
        if trigger != .manual { log(Self.logText(result, skipped: skipped)) }
        if manual {
            present(result, .manual)
        } else if case .updateAvailable = result, !skipped, checksAutomatically {
            present(result, trigger)
        }
        schedule()
    }

    private func isSkipped(_ result: UpdateCheckResult) -> Bool {
        guard case .updateAvailable(let offer) = result, let text = preferences?.skippedVersion else { return false }
        return AppVersion(text) == offer.release.version
    }

    @discardableResult
    private func save(_ preferences: UpdatePreferences, unlessStopped: Bool = false) -> Task<Void, Never> {
        let previous = saving
        let store = self.store
        let task = Task { [weak self] in
            await previous?.value
            if unlessStopped, self?.stopped ?? true { return }
            await store.saveUpdatePreferences(preferences)
        }
        saving = task
        return task
    }

    // MARK: - The timer

    /// Sets the timer for the next automatic check: a full interval after the later of the last
    /// successful check and the last attempt, at most an interval from now; overdue, it checks now.
    private func schedule() {
        cancelTimer()
        guard started, !stopped, checksAutomatically, canCheck, check == nil, let preferences else { return }
        let last = [preferences.lastChecked, lastAttempt].compactMap { $0 }.max()
        let wait = last.map { $0.addingTimeInterval(Self.intervalSeconds).timeIntervalSince(now()) } ?? 0
        guard wait > 0 else {
            beginCheck(.scheduled)
            return
        }
        let delay = wait >= Self.intervalSeconds ? Self.interval : .seconds(wait)
        let id = timerID
        let sleep = self.sleep
        timer = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            self?.timerFired(id)
        }
    }

    private func timerFired(_ id: Int) {
        guard id == timerID, !stopped, checksAutomatically else { return }
        timer = nil
        beginCheck(.scheduled)
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerID += 1
    }

    // MARK: - The log

    /// The text of an automatic check's log line.
    static func logText(_ result: UpdateCheckResult, skipped: Bool) -> String {
        switch result {
        case .updateAvailable(let offer):
            skipped ? "skipped \(offer.release.version)" : "Noctule Scan \(offer.release.version) is available"
        case .upToDate(let running, _):
            "up to date (\(running))"
        case .developmentBuild(let text):
            "development build (\(text))"
        case .failed(let failure):
            switch failure {
            case .network(let message): message
            case .noRelease: "no release published yet"
            case .rateLimited: "rate limited by GitHub"
            case .unreadable(let detail): "couldn't read GitHub's answer (\(detail))"
            case .disabledForTesting: "off with a private settings directory"
            }
        }
    }
}

/// The line the app writes to stderr for each automatic check:
/// `NoctuleScan: HH:mm:ss update check: <text>`, in local time (the `SessionWarningLog` format).
public enum UpdateCheckLog {
    public static func line(_ text: String, at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return "NoctuleScan: \(formatter.string(from: date)) update check: \(text)"
    }
}
