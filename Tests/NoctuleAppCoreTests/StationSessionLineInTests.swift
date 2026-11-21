// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleKitTestSupport
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

/// `StationSession` and `SessionRegistry` running a USB station's line-in (Plan 18 Task 11; line-in
/// design §5.4, §6): the session's audio state, the meter, the latching clip light and the clip
/// warning, Volume −1, an input swapped without touching the scanner, and listening kept through a
/// wait for the scanner. Every source is a `FakeLineInSource` made by `FakeLineInSources` through
/// `environment.lineInSources`: nothing opens an audio input. See `withUSBSession` for what every
/// test checks at the end. All names and values are fictional.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct StationSessionLineInTests {
    private let input = LineInConfig(deviceUID: "fictional-interface-uid", deviceName: "Fictional Interface", channel: .left)
    private let otherInput = LineInConfig(deviceUID: "other-interface-uid", deviceName: "Other Interface", channel: .both)
    private let hint = SerialPort.noneFoundHint

    private func setup(_ sources: FakeLineInSources) -> USBSetup {
        var setup = USBSetup()
        setup.lineIn = input
        setup.lineInSources = sources.factory
        return setup
    }

    private func level(_ peak: Double, clipped: Bool = false, at: ContinuousClock.Instant = .now) -> LineInLevel {
        LineInLevel(peakDBFS: peak, rmsDBFS: peak - 3, clipped: clipped, at: at)
    }

    /// Connects, and waits for the line-in's source to stream.
    private func connectStreaming(_ rig: USBRig, _ sources: FakeLineInSources) async throws -> FakeLineInSource {
        rig.start()
        try await rig.waitConnected()
        try await waitUntil("the line-in streaming (\(String(describing: rig.session.lineIn)))") {
            rig.session.lineIn == .streaming(deviceName: "Fictional Interface")
        }
        return try #require(sources.last)
    }

    @Test func lineInStationHasAudio() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            #expect(rig.session.lineIn == nil)
            let source = try await connectStreaming(rig, sources)
            #expect(rig.session.hasAudio)
            #expect(rig.session.canListen)
            #expect(rig.session.lineInConfig == input)
            #expect(source.config == input)
            #expect(sources.sources.count == 1)
            source.yield(chunk: FakeLineInSource.chunk(sequence: 0, value: 100))
            source.yield(chunk: FakeLineInSource.chunk(sequence: 1, value: 100))
            try await waitUntil("two chunks played") { rig.session.packets == 2 && rig.output.chunks == 2 }
            #expect(rig.output.plays == 1)
            #expect(rig.session.audio == .idle, "a line-in has no AudioSession")
            try await rig.stopSession()
            #expect(source.stopped)
            #expect(rig.session.lineIn == .stopped)
            #expect(rig.output.stops >= 1)
            #expect(rig.session.lineInLevel == nil && rig.session.peakHoldDBFS == nil)
        }
    }

    /// Without an input saved, or with no factory to make its source, the station has no audio and
    /// no source is made, as before Plan 18.
    @Test func lineInNeedsAnInputAndAFactory() async throws {
        let sources = FakeLineInSources()
        var noInput = USBSetup()
        noInput.lineInSources = sources.factory
        try await withUSBSession(noInput) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            #expect(!rig.session.hasAudio && !rig.session.canListen)
            #expect(rig.session.lineInConfig == nil && rig.session.lineIn == nil)
            #expect(sources.sources.isEmpty)
        }
        var noFactory = USBSetup()
        noFactory.lineIn = input
        try await withUSBSession(noFactory) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            #expect(!rig.session.hasAudio)
            #expect(rig.session.lineInConfig == nil)
        }
    }

    @Test func levelsAndClipLatch() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            let source = try await connectStreaming(rig, sources)
            #expect(rig.session.lineInLevel == nil && !rig.session.clipLatched)
            source.yield(level: level(-20))
            try await waitUntil("the level") { rig.session.lineInLevel?.peakDBFS == -20 }
            #expect(rig.session.peakHoldDBFS == -20)
            #expect(!rig.session.clipLatched)

            source.yield(level: level(0, clipped: true))
            try await waitUntil("the clip shown") { rig.session.lineInLevel?.clipped == true }
            #expect(rig.session.clipLatched)
            rig.session.clearClip()
            #expect(!rig.session.clipLatched)

            source.yield(level: level(-25))
            try await waitUntil("the next level") { rig.session.lineInLevel?.peakDBFS == -25 }
            #expect(!rig.session.clipLatched, "an unclipped level doesn't light CLIP again")
            #expect(rig.session.peakHoldDBFS == 0, "the clip's peak is held")

            // Listening off: the meter still moves.
            rig.session.listening = false
            source.yield(level: level(-30))
            try await waitUntil("a level with Listen off") { rig.session.lineInLevel?.peakDBFS == -30 }

            // The input gone: no reading, and no peak held.
            source.setState(.missing(deviceName: "Fictional Interface"))
            try await waitUntil("the input missing") { rig.session.lineIn == .missing(deviceName: "Fictional Interface") }
            #expect(rig.session.lineInLevel == nil)
            #expect(rig.session.peakHoldDBFS == nil)
            #expect(rig.session.canListen, "a missing input is a wait, not a block")

            // A clip read just before the input went (levels and states come on separate streams)
            // still lights CLIP, though the reading isn't shown.
            rig.session.clearClip()
            source.yield(level: level(0, clipped: true))
            try await waitUntil("CLIP from a reading not shown") { rig.session.clipLatched }
            #expect(rig.session.lineInLevel == nil)
        }
    }

    /// A burst of levels is shown at most 30 times a second, its loudest peak and any clip kept.
    @Test func levelsAreShownAtMostThirtyTimesASecond() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            let source = try await connectStreaming(rig, sources)
            source.yield(level: level(-50))
            try await waitUntil("the first level") { rig.session.lineInLevel?.peakDBFS == -50 }
            let before = rig.session.levelPublishes
            let began = ContinuousClock.now
            for step in 0..<40 {
                source.yield(level: level(-49 + Double(step) * 0.5))
                try await Task.sleep(for: .milliseconds(2))
            }
            source.yield(level: level(-60, clipped: true))
            try await waitUntil("the burst shown") { rig.session.lineInLevel?.clipped == true }
            let elapsed = began.duration(to: .now)
            let published = rig.session.levelPublishes - before
            let allowed = Int(elapsed / StationSession.levelRefreshInterval) + 2
            #expect(published <= allowed, "\(published) updates in \(elapsed)")
            #expect(published < 41)
            #expect(rig.session.clipLatched)
        }
    }

    @Test func clipWarningNamesTheHit() async throws {
        let sources = FakeLineInSources()
        let received = Mutex<[String]>([])
        var setup = setup(sources)
        setup.onWarning = { station, text in received.withLock { $0.append("\(station): \(text)") } }
        try await withUSBSession(setup) { rig in
            let source = try await connectStreaming(rig, sources)
            try await rig.waitForPush()
            rig.clock.set(usbFirstTransmissionAt + 0.01)
            try await waitUntil("a hit") { !rig.session.recentHits.isEmpty }
            source.yield(level: level(0, clipped: true))
            try await waitUntil("the clip warning") { rig.session.clipWarning != nil }
            let warning = try #require(rig.session.clipWarning)
            #expect(warning.hit.id == rig.session.recentHits.first?.hit.id)
            #expect(warning.audioClipped == true)
            let text = StationRunner.clippedMessage(channel: "Lakeview Fire Dispatch")
            #expect(rig.session.clipWarningText == text)
            #expect(received.withLock { $0 } .contains("Test Handheld: \(text)"))
            #expect(!rig.session.warnings.contains(text), "shown once, with its own buttons")
            #expect(rig.session.clipLatched)
            rig.session.dismissClipWarning()
            #expect(rig.session.clipWarning == nil && rig.session.clipWarningText == nil)
            #expect(rig.session.clipLatched, "dismissing the warning leaves CLIP lit")
            rig.clock.set(0)
        }
    }

    @Test func volumeDownSendsOneVOL() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            _ = try await connectStreaming(rig, sources)
            rig.session.setScannerVolume(5)
            try await waitUntil("the volume read as 5") { rig.session.info?.volume == 5 }
            let mark = await rig.commands.count
            rig.session.stepScannerVolumeDown()
            try await waitUntil("VOL,4") { await rig.commands(since: mark).contains("VOL,4") }
            try await Task.sleep(for: .milliseconds(400))
            #expect(await rig.commands(since: mark).filter { $0.hasPrefix("VOL") } == ["VOL,4"])
            #expect(await rig.mock.volume == 4)
        }
    }

    /// Connected, at the bottom of the range: Volume −1 sends nothing.
    @Test func volumeDownAtZeroSendsNothing() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            _ = try await connectStreaming(rig, sources)
            rig.session.setScannerVolume(0)
            try await waitUntil("the volume read as 0") { rig.session.info?.volume == 0 }
            let mark = await rig.commands.count
            rig.session.stepScannerVolumeDown()
            try await Task.sleep(for: .milliseconds(500))
            #expect(rig.isConnected)
            #expect(await rig.commands(since: mark).filter { $0.hasPrefix("VOL") } == [], "nothing below 0")
        }
    }

    /// Connected, with no volume reading (no push yet, or one without `VOL`): Volume −1 sends
    /// nothing. The reading is taken away and the step made in one main-actor turn, so no push can
    /// land in between.
    @Test func volumeDownWithNoReadingSendsNothing() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            _ = try await connectStreaming(rig, sources)
            try await rig.waitForPush()
            let mark = await rig.commands.count
            rig.session.info = nil
            rig.session.stepScannerVolumeDown()
            var withoutVolume = try #require(await nextInfo(rig))
            withoutVolume.volume = nil
            rig.session.info = withoutVolume
            rig.session.stepScannerVolumeDown()
            try await Task.sleep(for: .milliseconds(500))
            #expect(rig.isConnected)
            #expect(await rig.commands(since: mark).filter { $0.hasPrefix("VOL") } == [])
        }
    }

    /// The next push's status, once `info` is back after being cleared.
    private func nextInfo(_ rig: USBRig) async throws -> ScannerInfo? {
        try await rig.waitForPush()
        return rig.session.info
    }

    /// Not connected (waiting for the scanner): Volume −1 sends nothing, then or after it connects.
    @Test func volumeDownWhileNotConnectedSendsNothing() async throws {
        let sources = FakeLineInSources()
        var setup = setup(sources)
        setup.startMock = false
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            rig.session.stepScannerVolumeDown()
            _ = try await rig.mock.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            try await Task.sleep(for: .milliseconds(400))
            #expect(await rig.received("VOL") == 0)
        }
    }

    /// Review Focus 2: the scanner unplugged while the line-in runs. Listening and the meter go on
    /// through the wait, and after the replug the same relay and playback carry on.
    @Test func lineInRelaySurvivesTheScannerWait() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            let source = try await connectStreaming(rig, sources)
            try await rig.waitForPush()
            source.yield(chunk: FakeLineInSource.chunk(sequence: 0, value: 100))
            try await waitUntil("a chunk") { rig.session.packets == 1 }

            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            source.yield(chunk: FakeLineInSource.chunk(sequence: 1, value: 100))
            source.yield(chunk: FakeLineInSource.chunk(sequence: 2, value: 100))
            try await waitUntil("chunks during the wait") { rig.session.packets == 3 && rig.output.chunks == 3 }
            source.yield(level: level(-14))
            try await waitUntil("the meter during the wait") { rig.session.lineInLevel?.peakDBFS == -14 }
            #expect(rig.output.stops == 0, "playback stopped at the unplug")
            #expect(!source.stopped)
            #expect(rig.session.lineIn == .streaming(deviceName: "Fictional Interface"))
            #expect(rig.session.canListen)
            // Listen can be turned off and on again while the scanner is away.
            rig.session.listening = false
            #expect(rig.output.stops == 1)
            rig.session.listening = true
            try await waitUntil("playback again") { rig.output.plays == 2 }
            source.yield(chunk: FakeLineInSource.chunk(sequence: 3, value: 100))
            try await waitUntil("a chunk after Listen on") { rig.output.chunks == 4 }

            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            try await rig.waitForPush()
            source.yield(chunk: FakeLineInSource.chunk(sequence: 4, value: 100))
            try await waitUntil("a chunk after the replug") { rig.session.packets == 5 && rig.output.chunks == 5 }
            #expect(rig.output.plays == 2, "the resume started a second playback")
            #expect(sources.sources.count == 1, "the resume made a second source")
        }
    }

    /// Sleep stops the line-in, its relay and playback; wake starts a fresh source.
    @Test func suspendStopsTheLineIn() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            let source = try await connectStreaming(rig, sources)
            let session = rig.session
            let suspended = Done()
            Task { await session.suspend(); suspended.value = true }
            try await waitUntil("suspend") { suspended.value }
            #expect(source.stopped)
            #expect(rig.output.stops >= 1)
            #expect(rig.session.lineIn == .stopped)
            #expect(rig.session.lineInLevel == nil)
            Task { await session.resume() }
            try await rig.waitConnected()
            try await waitUntil("a second source streaming") {
                sources.sources.count == 2 && rig.session.lineIn == .streaming(deviceName: "Fictional Interface")
            }
            sources.sources[1].yield(chunk: FakeLineInSource.chunk(sequence: 0, value: 100))
            try await waitUntil("a chunk after the wake") { rig.session.packets == 1 }
        }
    }

    @Test func lineInChangedKeepsTheScanner() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            let first = try await connectStreaming(rig, sources)
            try await rig.waitForPush()
            let mark = await rig.commands.count
            try await bounded("lineInChanged(otherInput)") { await rig.session.lineInChanged(otherInput) }
            #expect(rig.session.lineInConfig == otherInput)
            #expect(first.stopped)
            try await waitUntil("the other input streaming") {
                rig.session.lineIn == .streaming(deviceName: "Other Interface")
            }
            let second = try #require(sources.last)
            #expect(sources.sources.count == 2)
            #expect(second.config == otherInput && second.started)
            second.yield(chunk: FakeLineInSource.chunk(sequence: 0, value: 100))
            try await waitUntil("a chunk from the other input") { rig.session.packets == 1 }
            #expect(rig.isConnected)
            #expect(rig.output.plays == 1, "playback was restarted for the swap")
            let since = await rig.commands(since: mark)
            #expect(!since.contains("MDL") && !since.contains { $0.hasPrefix("PSI") }, "\(since)")

            // No input: no audio, nothing playing, the scanner still connected.
            try await bounded("lineInChanged(nil)") { await rig.session.lineInChanged(nil) }
            #expect(second.stopped)
            #expect(!rig.session.hasAudio && rig.session.lineIn == nil && rig.session.lineInLevel == nil)
            #expect(rig.output.stops >= 1)
            // And back: the relay and playback start again.
            try await bounded("lineInChanged(input)") { await rig.session.lineInChanged(input) }
            try await waitUntil("the input again") { rig.session.lineIn == .streaming(deviceName: "Fictional Interface") }
            try #require(sources.sources.count == 3)
            sources.sources[2].yield(chunk: FakeLineInSource.chunk(sequence: 0, value: 100))
            try await waitUntil("a chunk after the input came back") { rig.output.chunks == 2 }
            #expect(rig.output.plays == 2)
            #expect(rig.isConnected)
            let after = await rig.commands(since: mark)
            #expect(!after.contains("MDL") && !after.contains { $0.hasPrefix("PSI") }, "\(after)")
        }
    }

    /// The registry passes an input change to the open session.
    @Test func registryPassesALineInChange() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            let registry = SessionRegistry(environment: rig.environment)
            let session = registry.open(rig.station)
            do {
                try await waitUntil("streaming") { session.lineIn == .streaming(deviceName: "Fictional Interface") }
                registry.lineInChanged(rig.station.id, to: otherInput)
                try await waitUntil("the other input") { session.lineIn == .streaming(deviceName: "Other Interface") }
                #expect(session.lineInConfig == otherInput)
                #expect(await rig.received("MDL") == 1)
                registry.lineInChanged(UUID(), to: input)  // no such session: nothing
            } catch {
                _ = await registry.stopAll()
                throw error
            }
            #expect(await registry.stopAll())
        }
    }

    @Test func previewUsesTheRunningSession() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            let registry = SessionRegistry(environment: rig.environment)
            let session = registry.open(rig.station)
            do {
                try await waitUntil("streaming") { session.lineIn == .streaming(deviceName: "Fictional Interface") }
                let running = try #require(sources.last)

                // The same input: the session's own levels, no second source.
                let shared = registry.previewLevels(stationID: rig.station.id, config: input)
                #expect(sources.sources.count == 1)
                let got = Mutex<[Double]>([])
                let reader = Task { for await level in shared.levels { got.withLock { $0.append(level.peakDBFS) } } }
                running.yield(level: level(-12))
                try await waitUntil("the session's level in the preview") { got.withLock { $0 } == [-12] }
                shared.cancel()
                try await bounded("the reader to end") { await reader.value }
                #expect(!running.stopped, "cancelling the preview stopped the session's source")

                // Another input: a short-lived source of its own, stopped by cancel.
                let own = registry.previewLevels(stationID: rig.station.id, config: otherInput)
                try await waitUntil("a preview source") { sources.sources.count == 2 && sources.sources[1].started }
                let preview = sources.sources[1]
                #expect(preview.config == otherInput)
                let ownGot = Mutex<[Double]>([])
                let ownReader = Task { for await level in own.levels { ownGot.withLock { $0.append(level.peakDBFS) } } }
                preview.yield(level: level(-33))
                try await waitUntil("the preview's level") { ownGot.withLock { $0 } == [-33] }
                own.cancel()
                try await waitUntil("the preview source stopped") { preview.stopped }
                try await bounded("the preview reader to end") { await ownReader.value }
                #expect(!running.stopped)

                // A station with no open session: a source of its own too.
                let none = registry.previewLevels(stationID: UUID(), config: input)
                try await waitUntil("a third source") { sources.sources.count == 3 }
                none.cancel()
                try await waitUntil("the third source stopped") { sources.sources[2].stopped }
            } catch {
                _ = await registry.stopAll()
                throw error
            }
            #expect(await registry.stopAll())
        }
    }

    /// A registry with no sessions over `sources` (no scanner needed for a preview of its own).
    private func previewRegistry(_ sources: FakeLineInSources) -> SessionRegistry {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-preview-\(UUID().uuidString)")
        var environment = SessionEnvironment(settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
                                             recordingsRoot: dir, cooldownStore: CooldownSpy())
        environment.lineInSources = sources.factory
        return SessionRegistry(environment: environment)
    }

    /// Ruling R19: a preview whose reader goes away (the view's task cancelled) without calling
    /// `cancel` stops its source.
    @Test func droppingThePreviewStopsItsSource() async throws {
        let sources = FakeLineInSources()
        let registry = previewRegistry(sources)
        let preview = registry.previewLevels(stationID: UUID(), config: input)
        let got = Mutex(0)
        let ended = Done()
        let reader = Task { for await _ in preview.levels { got.withLock { $0 += 1 } }; ended.value = true }
        try await waitUntil("the preview source") { sources.last?.started == true }
        let source = try #require(sources.last)
        source.yield(level: level(-20))
        try await waitUntil("a level") { got.withLock { $0 } == 1 }
        reader.cancel()
        try await waitUntil("the reader to end") { ended.value }
        try await waitUntil("the source stopped") { source.stopped }
        #expect(sources.sources.count == 1)
    }

    /// Ruling R19: sleep stops a preview's source, and wake starts a fresh one on the same stream;
    /// `cancel` then stops that one.
    @Test func suspendAllStopsAPreviewSource() async throws {
        let sources = FakeLineInSources()
        let registry = previewRegistry(sources)
        let preview = registry.previewLevels(stationID: UUID(), config: input)
        let got = Mutex<[Double]>([])
        let ended = Done()
        let reader = Task {
            for await level in preview.levels { got.withLock { $0.append(level.peakDBFS) } }
            ended.value = true
        }
        defer { reader.cancel() }
        try await waitUntil("the preview source") { sources.last?.started == true }
        let first = try #require(sources.last)
        try await bounded("suspendAll") { await registry.suspendAll() }
        #expect(first.stopped)
        // While asleep a new preview opens nothing.
        let asleep = registry.previewLevels(stationID: UUID(), config: otherInput)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sources.sources.count == 1)

        try await bounded("resumeAll") { await registry.resumeAll() }
        try await waitUntil("fresh sources after the wake") {
            sources.sources.count == 3 && sources.sources[1...].allSatisfy(\.started)
        }
        let again = try #require(sources.sources.first { $0 !== first && $0.config == input })
        again.yield(level: level(-9))
        try await waitUntil("a level after the wake, on the same stream") { got.withLock { $0 } == [-9] }
        preview.cancel()
        asleep.cancel()
        try await waitUntil("the reader to end") { ended.value }
        try await waitUntil("every preview source stopped") { sources.sources.allSatisfy(\.stopped) }
    }

    /// Ruling R19: a preview cancelled while the Mac is asleep stays closed after the wake: its
    /// one source (stopped by the sleep) is never followed by another.
    @Test func aPreviewCancelledWhileAsleepStaysClosed() async throws {
        let sources = FakeLineInSources()
        let registry = previewRegistry(sources)
        let preview = registry.previewLevels(stationID: UUID(), config: input)
        try await waitUntil("the preview source") { sources.last?.started == true }
        try await bounded("suspendAll") { await registry.suspendAll() }
        preview.cancel()
        // Until the termination has run (its main-actor half); not thrown, so a registry that never
        // lets go fails on the counts below.
        try? await waitUntil("the preview let go", .seconds(1)) { registry.previewCount == 0 }
        #expect(registry.previewCount == 0)
        try await bounded("resumeAll") { await registry.resumeAll() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(sources.sources.count == 1, "a source was opened after the wake for a preview that was gone")
        #expect(sources.sources.allSatisfy { $0.stopped })
    }

    /// A `cancel()` and a `resumeAll()` in one main-actor turn: the preview counts as ended from
    /// inside `cancel()`, so the wake opens nothing for it.
    @Test func cancelThenWakeInOneTurnOpensNothing() async throws {
        let sources = FakeLineInSources()
        let registry = previewRegistry(sources)
        let preview = registry.previewLevels(stationID: UUID(), config: input)
        try await waitUntil("the preview source") { sources.last?.started == true }
        try await bounded("suspendAll") { await registry.suspendAll() }
        preview.cancel()
        await registry.resumeAll()
        try await Task.sleep(for: .milliseconds(200))
        #expect(sources.sources.count == 1, "the wake opened a source for a cancelled preview")
        #expect(sources.sources.allSatisfy { $0.stopped })
    }

    /// `stopAll` returns only once a preview's source has stopped, whichever path stops it.
    @Test func stopAllWaitsForAPreviewsStop() async throws {
        let made = Mutex<[SlowStopSource]>([])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-preview-\(UUID().uuidString)")
        var environment = SessionEnvironment(settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
                                             recordingsRoot: dir, cooldownStore: CooldownSpy())
        environment.lineInSources = { config in
            let source = SlowStopSource(config: config)
            made.withLock { $0.append(source) }
            return source
        }
        let registry = SessionRegistry(environment: environment)
        _ = registry.previewLevels(stationID: UUID(), config: input)
        let source = try #require(made.withLock { $0.first })
        #expect(await registry.stopAll(deadline: .seconds(5)))
        #expect(source.stopFinished, "stopAll returned before the preview's source had stopped")
    }

    /// `stopAll` (quit) stops a preview's source and ends its stream.
    @Test func stopAllStopsAPreviewSource() async throws {
        let sources = FakeLineInSources()
        let registry = previewRegistry(sources)
        let preview = registry.previewLevels(stationID: UUID(), config: input)
        let ended = Done()
        let reader = Task { for await _ in preview.levels {}; ended.value = true }
        defer { reader.cancel() }
        try await waitUntil("the preview source") { sources.last?.started == true }
        #expect(await registry.stopAll(deadline: .seconds(5)))
        #expect(sources.last?.stopped == true)
        try await waitUntil("the stream to end") { ended.value }
        preview.cancel()
        #expect(sources.sources.count == 1)
    }

    /// A USB station plays its line-in through `makeLineInAudioOutput`, not `makeAudioOutput`.
    @Test func lineInPlaysThroughTheLineInOutput() async throws {
        let sources = FakeLineInSources()
        var setup = setup(sources)
        setup.separateLineInOutput = true
        try await withUSBSession(setup) { rig in
            let source = try await connectStreaming(rig, sources)
            source.yield(chunk: FakeLineInSource.chunk(sequence: 0, value: 100))
            try await waitUntil("a chunk played") { rig.lineInOutput.chunks == 1 }
            #expect(rig.lineInOutput.plays == 1)
            #expect(rig.output.plays == 0 && rig.output.chunks == 0)
        }
    }

    /// Runs `body`, failing (rather than hanging) if it takes longer than `limit`.
    private func bounded(_ what: String, _ limit: Duration = .seconds(5),
                         _ body: @escaping @MainActor () async -> Void) async throws {
        let done = Done()
        Task { await body(); done.value = true }
        try await waitUntil(what, limit) { done.value }
    }

    /// With no factory the preview has no levels, and finishes at once.
    @Test func previewWithNoFactoryIsEmpty() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-preview-\(UUID().uuidString)")
        let environment = SessionEnvironment(settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
                                             recordingsRoot: dir, cooldownStore: CooldownSpy())
        let registry = SessionRegistry(environment: environment)
        let preview = registry.previewLevels(stationID: UUID(), config: input)
        var count = 0
        for await _ in preview.levels { count += 1 }
        #expect(count == 0)
        preview.cancel()
    }

    /// A line-in station never calls the cooldown store or gate: not at start, through an unplug
    /// and replug, an input change, sleep and wake, or the stop.
    @Test func noCooldownCalls() async throws {
        let sources = FakeLineInSources()
        try await withUSBSession(setup(sources)) { rig in
            _ = try await connectStreaming(rig, sources)
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            try await bounded("lineInChanged(otherInput)") { await rig.session.lineInChanged(otherInput) }
            let session = rig.session
            let suspended = Done()
            Task { await session.suspend(); suspended.value = true }
            try await waitUntil("suspend") { suspended.value }
            Task { await session.resume() }
            try await rig.waitConnected()
            // The start reads the saved input again (the test changed only the running one).
            try await waitUntil("streaming after the wake") { session.lineIn == .streaming(deviceName: "Fictional Interface") }
            try await rig.stopSession()
            #expect(rig.cooldown.calls == [])
        }
    }

    /// Ruling R13: under the kill-switch the factory makes `DisabledLineInSource`s. The station still
    /// has audio, its line-in is `.failed(reason)`, and Listen is blocked.
    @Test func killSwitchBlocksListening() async throws {
        let reason = LineInDetection.disabledReason
        var setup = USBSetup()
        setup.lineIn = input
        setup.lineInSources = { _ in DisabledLineInSource(reason: reason) }
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("the line-in failed") { rig.session.lineIn == .failed(reason) }
            #expect(rig.session.hasAudio)
            #expect(!rig.session.canListen)
            #expect(rig.session.warnings.contains(reason))
        }
    }

    /// Permission denied blocks Listen too; streaming allows it.
    @Test func deniedBlocksListening() async throws {
        var setup = USBSetup()
        setup.lineIn = input
        setup.lineInSources = { config in
            let source = FakeLineInSource(config: config)
            source.startState = .denied
            return source
        }
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("denied") { rig.session.lineIn == .denied }
            #expect(rig.session.hasAudio && !rig.session.canListen)
        }
    }

    /// A network station's Listen is as before: allowed whenever it has audio.
    @Test func networkStationCanListen() {
        let dir = FileManager.default.temporaryDirectory
        let environment = SessionEnvironment(settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
                                             recordingsRoot: dir, cooldownStore: CooldownSpy())
        var station = Station()
        station.connection.host = "127.0.0.1"
        let session = StationSession(station: station, environment: environment)
        #expect(session.hasAudio && session.canListen)
        #expect(session.lineInConfig == nil)
    }
}

/// `PeakHold`: the meter's peak tick (line-in design §5.3).
@Suite(.timeLimit(.minutes(1))) struct PeakHoldTests {
    @Test func holdsThenFallsToTheCurrentPeak() {
        var hold = PeakHold()
        let t0 = ContinuousClock.now
        #expect(PeakHold.holdTime == .milliseconds(1500))
        #expect(hold.update(peak: -20, at: t0) == -20)
        #expect(hold.update(peak: -30, at: t0 + .milliseconds(1000)) == -20)
        #expect(hold.update(peak: -35, at: t0 + .milliseconds(1499)) == -20)
        #expect(hold.update(peak: -32, at: t0 + .milliseconds(1500)) == -32, "falls after 1.5 s")
        #expect(hold.update(peak: -40, at: t0 + .milliseconds(2000)) == -32, "the new hold starts at the fall")
        #expect(hold.update(peak: -40, at: t0 + .milliseconds(3000)) == -40)
    }

    @Test func aHigherPeakIsHeldAtOnce() {
        var hold = PeakHold()
        let t0 = ContinuousClock.now
        _ = hold.update(peak: -20, at: t0)
        #expect(hold.update(peak: -6, at: t0 + .milliseconds(1400)) == -6)
        #expect(hold.update(peak: -30, at: t0 + .milliseconds(2800)) == -6, "held from the higher peak's time")
        #expect(hold.update(peak: -30, at: t0 + .milliseconds(2900)) == -30)
        #expect(hold.update(peak: -.infinity, at: t0 + .milliseconds(3000)) == -30)
    }

    @Test func resetForgets() {
        var hold = PeakHold()
        let t0 = ContinuousClock.now
        _ = hold.update(peak: 0, at: t0)
        hold.reset()
        #expect(hold.held == nil)
        #expect(hold.update(peak: -50, at: t0 + .milliseconds(10)) == -50)
    }
}

/// A line-in source whose stop takes 300 ms (a slow device), for checking who waits for it. It
/// opens nothing and yields nothing.
final class SlowStopSource: LineInSource {
    let chunks: AsyncStream<AudioChunk>
    let levels: AsyncStream<LineInLevel>
    let states: AsyncStream<LineInState>
    private let sinks: (AsyncStream<AudioChunk>.Continuation, AsyncStream<LineInLevel>.Continuation,
                        AsyncStream<LineInState>.Continuation)
    private let finished = Mutex(false)
    var stopFinished: Bool { finished.withLock { $0 } }

    init(config: LineInConfig) {
        let (chunks, chunkSink) = AsyncStream.makeStream(of: AudioChunk.self)
        let (levels, levelSink) = AsyncStream.makeStream(of: LineInLevel.self)
        let (states, stateSink) = AsyncStream.makeStream(of: LineInState.self)
        self.chunks = chunks; self.levels = levels; self.states = states
        sinks = (chunkSink, levelSink, stateSink)
    }

    func start() async {}

    func stop() async {
        try? await Task.sleep(for: .milliseconds(300))
        sinks.0.finish(); sinks.1.finish(); sinks.2.finish()
        finished.withLock { $0 = true }
    }
}
