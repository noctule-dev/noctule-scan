// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import Darwin
import NoctuleAppCore
import NoctuleAudioCapture
import NoctuleAudioPlayback
import NoctuleKit
import NoctuleStore
import Synchronization

/// Owns the app's `SessionRegistry` and its lifecycle (Review Focus 1):
///
/// - **Quit** (menu, Cmd-Q, a signal below): `applicationShouldTerminate` answers
///   `.terminateLater`, awaits `registry.stopAll()` (every session: `PSI,0`, TEARDOWN; at most
///   15 s), then replies `true`, even if the deadline passed (the stops were given their time).
/// - **SIGTERM, SIGHUP and SIGINT** go to `NSApp.terminate(nil)` (from a main run-loop block, see
///   `terminateFromRunLoop()`), so they take the same path; a second signal does nothing extra.
///   The process then exits 0. If the quit is refused (a sheet, alert or modal panel is open), the
///   sessions are stopped anyway and the process exits 0 (`exitIfTerminateRefused`).
/// - **Sleep and wake** (`PowerGate`): IOKit sleep messages (`SystemPowerObserver`) hold the Mac
///   awake until every session has suspended (`PSI,0`, TEARDOWN), for at most 20 s, without
///   waiting for a resume still in flight; a full wake (`NSWorkspace.didWakeNotification`)
///   resumes them, each through its cooldown gate. While quitting, a sleep waits for the quit's
///   stops instead.
/// - **Update checks** (`updates`): started 5 s after launch has finished (`updateLaunchDelay`),
///   never holding it up, so the launch routing's station window is already open when a result
///   shows, and the network has had time to come up after a login; a sleep cancels their timer
///   (`NSWorkspace.willSleepNotification`) and a full wake sets it again; a quit stops them first,
///   so it never waits on one. Results show in `updateWindow`, never a modal alert.
/// - SIGPIPE is ignored, so a closed stdout or stderr can't kill the app mid-session.
/// - Closing the last window doesn't quit; a closed window's session stops through `release`.
///   Closing the last station window opens the Stations window (`stationWindows`), except while
///   quitting (`isQuitting`).
///
/// The test-only environment overrides (`SessionEnvironment.OverrideKey`) are applied here; each
/// one in effect is printed to stderr.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry: SessionRegistry
    let settings: any SettingsStore
    /// Holds `Stations/<uuid>/hits.sqlite`; the hit log window opens its own reader there.
    let settingsDirectory: URL
    /// Default recordings go to `<recordingsRoot>/<station name>/` (Settings shows it).
    let recordingsRoot: URL
    /// The stations as the picker and Settings show them; tells the registry about every change.
    let directory: StationDirectory
    /// Test-only (`NOCTULE_TEST_PRESENT_SHEET`): station windows present a sheet once open.
    let presentsTestSheet: Bool
    let launch = LaunchRoute()
    /// Asks the release feed for a newer version (update-check design §5); Settings shows its state.
    let updates: UpdateChecker
    private let updateWindow = UpdateWindowController()

    private var signalSources: [DispatchSourceSignal] = []
    private var power: SystemPowerObserver?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    /// How long after launch the first update check waits.
    static let updateLaunchDelay: Duration = .seconds(5)
    /// The quit's `stopAll()`, once quitting.
    private var quitStop: Task<Void, Never>?
    /// True from the moment a quit starts stopping sessions (`applicationShouldTerminate`, or the
    /// refused-quit fallback), so the station windows that close as their sessions go don't bring
    /// the Stations window back.
    private(set) var isQuitting = false
    /// The open station windows; closing the last one (outside a quit) opens the Stations window.
    lazy var stationWindows = StationWindowTracker { [unowned self] in self.isQuitting }

    override init() {
        signal(SIGPIPE, SIG_IGN)
        // `NOCTULE_TRACE`: a command trace on stderr, for diagnosing the real scanner (read-only, so it is
        // honoured with the standard settings too).
        if CommandTrace.isRequested(ProcessInfo.processInfo.environment) {
            CommandTrace.install { line in
                var now = timeval()
                gettimeofday(&now, nil)
                var seconds = now.tv_sec
                var parts = tm()
                localtime_r(&seconds, &parts)
                let stamp = String(format: "%02d:%02d:%02d.%03d", parts.tm_hour, parts.tm_min, parts.tm_sec,
                                   Int(now.tv_usec) / 1000)
                fputs("NoctuleScan: trace \(stamp) \(line)\n", stderr)
            }
            fputs("NoctuleScan: trace on (NOCTULE_TRACE)\n", stderr)
        }
        // The system's port listing goes in here, and only here; `applyingOverrides` replaces it
        // with none under the kill-switch or a private `NOCTULE_SETTINGS_DIR` (`USBDetection`).
        // The system's line-in source and input listing go in the same way, and `applyingOverrides` makes
        // the kill-switch win over them; under `NOCTULE_TEST_LINE_IN` the factory is the mock's stream's.
        var (environment, notes) = appSessionEnvironment(
            variables: ProcessInfo.processInfo.environment,
            makeAudioOutput: { AudioPlayer() },
            serialPorts: IOKitSerialPortFinder(),
            systemLineIn: { EngineLineInSource.system($0) },
            systemInputs: CoreAudioInputs(),
            makeLineInAudioOutput: { AudioPlayer(prefillSamples: AudioPlayer.lineInPrefillSamples) })
        environment.onWarning = { station, text in
            fputs(SessionWarningLog.line(station: station, text: text) + "\n", stderr)
        }
        for note in notes { fputs("NoctuleScan: test override: \(note)\n", stderr) }
        registry = SessionRegistry(environment: environment)
        settings = environment.settings
        settingsDirectory = environment.settingsDirectory
        recordingsRoot = environment.recordingsRoot
        presentsTestSheet = environment.presentsTestSheet
        directory = StationDirectory(settings: environment.settings, registry: registry)
        let (updateConfiguration, updateNotes) = UpdateCheckConfiguration.resolve(
            variables: ProcessInfo.processInfo.environment, infoDictionary: Bundle.main.infoDictionary ?? [:])
        for note in updateNotes { fputs("NoctuleScan: test override: \(note)\n", stderr) }
        let window = updateWindow
        let checker = UpdateChecker(
            configuration: updateConfiguration,
            // The same app.json actor as the rest of the app.
            preferences: environment.settings as? any UpdatePreferencesStore ?? InMemoryUpdatePreferences(),
            fetcher: URLSessionReleaseFetcher(userAgent: "NoctuleScan/\(updateConfiguration.runningVersionText)"),
            present: { result, trigger in window.show(result, trigger: trigger) },
            log: { text in fputs(UpdateCheckLog.line(text) + "\n", stderr) })
        window.skip = { [weak checker] version in Task { await checker?.skip(version) } }
        updates = checker
        super.init()
        signalSources = installTerminationSignals { [weak self] _ in
            terminateFromRunLoop()
            Task { @MainActor in await self?.exitIfTerminateRefused() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare executable (tests, `swift run`) there is no bundle to say so.
        NSApp.setActivationPolicy(.regular)
        let gate = PowerGate(
            suspend: { [weak self] in
                guard let self else { return }
                if let quitStop = self.quitStop { await quitStop.value } else { await self.registry.suspendAll() }
            },
            resume: { [weak self] in
                guard let self, self.quitStop == nil else { return }
                await self.registry.resumeAll()
            })
        let observer = SystemPowerObserver(gate: gate)
        if !observer.start() {
            fputs("NoctuleScan: couldn't register for sleep notifications; sessions may not stop before sleep\n", stderr)
        }
        power = observer
        // The one wake signal: a full wake. (IOKit's has-powered-on also arrives on dark wakes.)
        let updates = updates
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                gate.handle(.wake) {}
                updates.handleWake()
            }
        }
        // The update timer's clock runs during dark wakes; cancel it before sleep, so only the full
        // wake above sets it again.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { updates.handleSleep() }
        }
        // After the launch routing has opened its window, so a result shows in front of it; a quit
        // before then stops the checker, and `start()` then does nothing.
        Task {
            try? await Task.sleep(for: Self.updateLaunchDelay)
            await updates.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        power?.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// After a signal: if the quit never reached `applicationShouldTerminate` (AppKit and SwiftUI
    /// refuse to terminate while a sheet, an alert or a modal panel is up, such as the station
    /// editor or a confirmation), stop every session anyway (`PSI,0`, TEARDOWN; at most 15 s) and
    /// exit 0, so a signal never leaves the app running with the scanner session open.
    func exitIfTerminateRefused(after grace: Duration = .seconds(2)) async {
        // Quitting either way: no update check starts, logs or shows during the grace.
        updates.stop()
        try? await Task.sleep(for: grace)
        guard quitStop == nil else { return }
        fputs("NoctuleScan: quit was refused (a sheet or dialog is open); stopping sessions and exiting\n", stderr)
        isQuitting = true
        if !(await registry.stopAll()) {
            fputs("NoctuleScan: some scanner sessions were still stopping after 15 s; quitting anyway\n", stderr)
        }
        exit(0)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updates.stop()
        // A second request while the first is stopping sessions: that one's reply covers both.
        guard quitStop == nil else { return .terminateLater }
        isQuitting = true
        let registry = registry
        let stop = Task { @MainActor in
            let clean = await registry.stopAll()
            if !clean {
                fputs("NoctuleScan: some scanner sessions were still stopping after 15 s; quitting anyway\n", stderr)
            }
        }
        quitStop = stop
        Task { @MainActor in
            await stop.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Whether the launch routing (open the last station, else stay on the picker) has run. It runs
/// once per launch, not each time the picker reappears.
@MainActor
final class LaunchRoute {
    private(set) var handled = false
    /// True the first time only.
    func claim() -> Bool {
        defer { handled = true }
        return !handled
    }
}

/// Calls `NSApp.terminate(nil)` from a main run-loop block, not from a main-queue job.
///
/// `.terminateLater` makes `terminate` spin a nested run loop until the reply. Called from a
/// `Task { @MainActor in }` or `DispatchQueue.main.async` block, that nested loop runs inside a
/// main-queue callout, and the main queue doesn't drain re-entrantly: the `stopAll()` task (main
/// actor) never ran, so the app hung with the session open (LESSONS.md). A run-loop block isn't a
/// main-queue callout, so main-actor work keeps running in the nested loop.
nonisolated func terminateFromRunLoop() {
    let main = CFRunLoopGetMain()
    CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
    }
    CFRunLoopWakeUp(main)
}

/// True for the first caller only; shared by the signal handlers.
private final class FirstSignal: Sendable {
    private let fired = Mutex(false)
    func claim() -> Bool { fired.withLock { done in defer { done = true }; return !done } }
}

/// SIGTERM, SIGHUP and SIGINT through `DispatchSource`s. Nonisolated, with a `@Sendable` handler
/// that captures only its parameters: a closure that touched main-actor state would be inferred
/// `@MainActor` and trap on the global queue (LESSONS.md). `onSignal` runs once, for the first.
nonisolated func installTerminationSignals(_ onSignal: @escaping @Sendable (Int32) -> Void) -> [DispatchSourceSignal] {
    let first = FirstSignal()
    return [SIGTERM, SIGHUP, SIGINT].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { @Sendable in
            guard first.claim() else { return }
            onSignal(number)
        }
        source.resume()
        return source
    }
}
#endif
