// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import NoctuleAppCore
import NoctuleAudioCapture
import NoctuleKit
import NoctuleStore
import Synchronization
import Testing
@testable import NoctuleScan

/// How the app picks its line-in pieces (line-in design §8): the system's, the mock's stream under the
/// test override, or none under the kill-switch. The "system" pieces here are fakes that count their
/// calls, so nothing opens an audio input or asks for the microphone.
@Suite(.timeLimit(.minutes(3))) struct LineInWiringTests {
    private final class SystemCalls: Sendable {
        private let counts = Mutex((sources: 0, listings: 0))
        var sources: Int { counts.withLock { $0.sources } }
        var listings: Int { counts.withLock { $0.listings } }
        func source() { counts.withLock { $0.sources += 1 } }
        func listing() { counts.withLock { $0.listings += 1 } }
    }

    private struct CountingListing: AudioInputListing {
        let calls: SystemCalls
        func inputs() -> [AudioInputDevice] {
            calls.listing()
            return [AudioInputDevice(uid: "fake-uid", name: "Fake Interface", channelCount: 2)]
        }
    }

    private let config = LineInConfig(deviceUID: "fake-uid", deviceName: "Fake Interface", channel: .both)
    private let killSwitch = SessionEnvironment.OverrideKey.noUSBDetection

    private func build(_ variables: [String: String], _ calls: SystemCalls) -> (environment: SessionEnvironment, notes: [String]) {
        appSessionEnvironment(
            variables: variables,
            makeAudioOutput: { SilentAudioOutput() },
            serialPorts: FixedSerialPortListing.empty,
            systemLineIn: { _ in calls.source(); return DisabledLineInSource(reason: "system") },
            systemInputs: CountingListing(calls: calls),
            makeLineInAudioOutput: { SilentAudioOutput() })
    }

    /// The first state a started source reports.
    private func firstState(_ source: any LineInSource) async -> LineInState? {
        await source.start()
        for await state in source.states { await source.stop(); return state }
        return nil
    }

    /// The directories a test made, removed when the test's suite instance goes (one per test).
    private final class Directories: Sendable {
        private let urls = Mutex<[URL]>([])
        func add(_ url: URL) { urls.withLock { $0.append(url) } }
        deinit { for url in urls.withLock({ $0 }) { try? FileManager.default.removeItem(at: url) } }
    }
    private let directories = Directories()

    private func privateDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "line-in-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.add(url)
        return url.path
    }

    @Test func withNoOverridesTheSystemPiecesAreUsed() async throws {
        let calls = SystemCalls()
        let (environment, notes) = build([SessionEnvironment.OverrideKey.settingsDirectory: try privateDirectory()], calls)
        _ = notes
        let factory = try #require(environment.lineInSources)
        #expect(calls.sources == 0)
        let source = factory(config)
        #expect(calls.sources == 1)
        let isPipe = source is PipeLineInSource
        #expect(!isPipe)
        #expect(environment.audioInputs.inputs().map(\.name) == ["Fake Interface"])
        #expect(calls.listings == 1)
        #expect(environment.lineInTestStream == nil)
    }

    /// The kill-switch wins: neither the system's factory nor its listing is ever asked.
    @Test func killSwitchKeepsTheDisabledFactoryAndAnEmptyListing() async throws {
        let calls = SystemCalls()
        let (environment, _) = build([killSwitch: "1"], calls)
        let factory = try #require(environment.lineInSources)
        let source = factory(config)
        #expect(!(source is PipeLineInSource))
        let state = await firstState(source)
        #expect(state == .failed(LineInDetection.disabledReason))
        #expect(environment.audioInputs.inputs().isEmpty)
        #expect(calls.sources == 0)
        #expect(calls.listings == 0)
    }

    @Test func testStreamBuildsAPipeSourceOnThePath() async throws {
        let calls = SystemCalls()
        let path = "/tmp/no-such-line-out.sock"
        let (environment, notes) = build([SessionEnvironment.OverrideKey.settingsDirectory: try privateDirectory(),
                                          killSwitch: "1",
                                          SessionEnvironment.OverrideKey.testLineIn: path], calls)
        let factory = try #require(environment.lineInSources)
        #expect(factory(config) is PipeLineInSource)
        #expect(environment.lineInTestStream == path)
        #expect(environment.audioInputs.inputs().isEmpty)
        #expect(calls.sources == 0)
        #expect(calls.listings == 0)
        #expect(notes.contains { $0.contains(SessionEnvironment.OverrideKey.testLineIn) }, "\(notes)")
    }

    /// The override needs the kill-switch and a private settings directory; without them the kill-switch
    /// (or the system) still decides, and no pipe is built.
    @Test func testStreamWithoutItsConditionsIsIgnored() async throws {
        let path = "/tmp/no-such-line-out.sock"
        let calls = SystemCalls()
        let (killed, _) = build([killSwitch: "1", SessionEnvironment.OverrideKey.testLineIn: path], calls)
        let killedFactory = try #require(killed.lineInSources)
        #expect(!(killedFactory(config) is PipeLineInSource))
        #expect(killed.lineInTestStream == nil)

        let (open, notes) = build([SessionEnvironment.OverrideKey.settingsDirectory: try privateDirectory(),
                                   SessionEnvironment.OverrideKey.testLineIn: path], calls)
        let openFactory = try #require(open.lineInSources)
        #expect(!(openFactory(config) is PipeLineInSource))
        #expect(open.lineInTestStream == nil)
        #expect(notes.contains { $0.contains("ignoring") && $0.contains(SessionEnvironment.OverrideKey.testLineIn) }, "\(notes)")
        #expect(calls.sources == 1)
    }
}
#endif
