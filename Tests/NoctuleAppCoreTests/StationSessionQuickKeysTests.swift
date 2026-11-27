// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import Synchronization
import Testing
import NoctuleKit
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

// `StationSession.quickKeys` (Plan 20 Task 7; design `docs/specs/2026-11-18-quick-keys-design.md` §5.4): each
// session owns a `QuickKeysModel`, attached to the runner's client while connected (and only for a model
// whose profile `supportsQuickKeys`), detached on every other phase, fed the pushes and `session.menu`'s
// own reads, quiesced before the stop's `PSI,0`, with its cache at `Stations/<uuid>/quick-keys.json`. On
// the network mock (`withSession`) and the serial mock behind a link with an empty port listing
// (`withUSBSession`, which also checks no subscription left, no `MSM`/`POF`, no cooldown store call).
// Every name is fictional (`MockFavorites.default`).

/// The lists of `MockFavorites.default`, in `GLT` order.
private let defaultLists: [UInt32] = [0, 1, 4, 6, 8, 10, 12, 14]
private let pollInterval: Duration = .milliseconds(150)

private func isQuickKeyCommand(_ command: String) -> Bool {
    let name = command.split(separator: ",", maxSplits: 1).first.map(String.init) ?? command
    return ["GLT", "FQK", "SQK", "DQK"].contains(name.uppercased())
}

@MainActor
private func allFresh(_ model: QuickKeysModel) -> Bool {
    !model.lists.isEmpty && model.lists.allSatisfy { model.trees[$0.index]?.freshness == .fresh }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct StationSessionQuickKeysTests {
    @Test func connectedSessionLoadsTheKeypad() async throws {
        try await withSession(Setup(quickKeysPollInterval: pollInterval)) { rig in
            let quickKeys = rig.session.quickKeys
            #expect(!quickKeys.isAttached)
            rig.start()
            try await rig.waitConnected()
            #expect(rig.session.supportsQuickKeys)
            #expect(quickKeys.isAttached)
            // Nothing reads while the pop-over is closed.
            try await Task.sleep(for: pollInterval * 3)
            #expect(await rig.commands.filter(isQuickKeyCommand).isEmpty)
            quickKeys.open()
            try await waitUntil("the keypad") { quickKeys.lists.map(\.index) == defaultLists }
            let first = await rig.commands.filter(isQuickKeyCommand)
            #expect(first.prefix(2) == ["GLT,FL", "FQK"], "\(first)")
            // The session's pushes reach the model: the mock's `MonitorList Index="1"` is scanning now.
            try await waitUntil("scanning now from the pushes") { quickKeys.scanning.list == 1 }
            try await waitUntil("every list read") { allFresh(quickKeys) }
            #expect(quickKeys.switchState(for: .list(4)) == .off)
            quickKeys.close()
        }
    }

    @Test func unplugWithThePopoverOpen() async throws {
        try await withUSBSession(USBSetup(quickKeysPollInterval: pollInterval)) { rig in
            let quickKeys = rig.session.quickKeys
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            quickKeys.open()
            try await waitUntil("every list read") { allFresh(quickKeys) }
            let lists = quickKeys.lists.map(\.index)
            let trees = Set(quickKeys.trees.keys)
            #expect(lists == defaultLists)

            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: SerialPort.noneFoundHint))
            // R10: this session's lists and trees stay, read-only, every row unavailable.
            #expect(!quickKeys.isAttached)
            #expect(quickKeys.isOpen)
            #expect(quickKeys.lists.map(\.index) == lists)
            #expect(Set(quickKeys.trees.keys) == trees)
            #expect(quickKeys.lists.allSatisfy { $0.state == nil })
            #expect(quickKeys.switchState(for: .list(4)) == .unavailable)
            #expect(quickKeys.switchState(for: .system(list: 1, system: 101)) == .unavailable)
            await quickKeys.toggle(.list(4))  // refused: nothing to send it on
            try await Task.sleep(for: pollInterval * 3)
            #expect(quickKeys.switchState(for: .list(4)) == .unavailable)

            let mark = await rig.commands.count
            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            #expect(quickKeys.isAttached)
            // Reads resume on the new connection, after its MDL, VER and PSI.
            try await waitUntil("reads after the replug") { allFresh(quickKeys) }
            let second = await rig.commands(since: mark)
            #expect(second.prefix(3) == ["MDL", "VER", "PSI,100"], "\(second)")
            #expect(second.contains("GLT,FL"), "\(second)")
            #expect(!second.contains { $0.hasPrefix("FQK,") }, "a set went out: \(second)")
            #expect(quickKeys.switchState(for: .list(4)) == .off)

            try await rig.stopSession()
            let atStop = await rig.commands
            try await Task.sleep(for: pollInterval * 3)
            #expect(await rig.commands == atStop, "a command after the stop")
            #expect(atStop.last == "PSI,0", "\(atStop.suffix(5))")
            #expect(!quickKeys.isAttached)
        }
    }

    @Test func stopLeavesNothingRunning() async throws {
        // A slow GLT keeps a read in flight when the stop comes: it is awaited, never abandoned.
        let setup = Setup(replyDelays: ["GLT": .milliseconds(120)], quickKeysPollInterval: pollInterval)
        let outcome = try await withSession(setup) { rig in
            let quickKeys = rig.session.quickKeys
            rig.start()
            try await rig.waitConnected()
            quickKeys.open()
            try await waitUntil("the keypad") { !quickKeys.lists.isEmpty }
            try await waitUntil("a list read under way") {
                await rig.commands.contains { $0.hasPrefix("GLT,SYS") }
            }
            try await rig.stopSession()
            #expect(!quickKeys.isAttached)
            #expect(quickKeys.isOpen, "the stop leaves the pop-over open, read-only")
            let atStop = await rig.commands
            try await Task.sleep(for: pollInterval * 3)
            #expect(await rig.commands == atStop, "a command after the stop")
            quickKeys.close()
        }
        // Nothing of the model's follows the PSI,0.
        let lastStop = try #require(outcome.commands.lastIndex(of: "PSI,0"))
        let after = outcome.commands[(lastStop + 1)...]
        #expect(!after.contains(where: isQuickKeyCommand), "\(Array(after))")
    }

    @Test func aStopDetachesTheQuickKeysAndTheMenuBeforeItsFirstAwait() async throws {
        // A set or menu command still waiting for the client's slot is withheld from a stop's first synchronous step
        // (`halt()`), not only from `performStop`'s phase change a task hop later (QA review of the slot guard, I1).
        // Observation's `onChange` runs synchronously in `phase`'s `willSet`, the stop's first phase change, which
        // comes before that setter's `didSet` detaches the models: whatever is detached then, `halt()` detached.
        try await withSession(Setup(quickKeysPollInterval: .seconds(30))) { rig in
            let session = rig.session
            rig.start()
            try await rig.waitConnected()
            #expect(session.quickKeys.isAttached)
            #expect(session.menu.isAttached)
            let seen = Mutex<(quickKeys: Bool, menu: Bool)?>(nil)
            withObservationTracking {
                _ = session.phase
            } onChange: {
                MainActor.assumeIsolated {
                    let attached = (session.quickKeys.isAttached, session.menu.isAttached)
                    seen.withLock { $0 = attached }
                }
            }
            try await rig.stopSession()
            let atPhaseChange = try #require(seen.withLock { $0 }, "the stop changed the phase")
            #expect(!atPhaseChange.quickKeys, "the quick keys detached by `halt()`, before the phase changed")
            #expect(!atPhaseChange.menu, "the menu detached by `halt()`, before the phase changed")
            #expect(!rig.isConnected)
        }
    }

    @Test func theCacheFileIsPerStation() async throws {
        try await withSession(Setup(quickKeysPollInterval: pollInterval)) { rig in
            let expected = rig.dir.appendingPathComponent("Stations", isDirectory: true)
                .appendingPathComponent(rig.station.id.uuidString, isDirectory: true)
                .appendingPathComponent("quick-keys.json")
            #expect(StationSession.quickKeysCacheURL(settingsDirectory: rig.dir, stationID: rig.station.id) == expected)
            #expect(StationSession.quickKeysCacheURL(settingsDirectory: rig.dir, stationID: rig.station.id)
                        .deletingLastPathComponent()
                    == StationSession.hitLogURL(settingsDirectory: rig.dir, stationID: rig.station.id)
                        .deletingLastPathComponent(), "beside the hit log")
            // No cache, no connection, no override: nothing says the model has quick keys yet.
            #expect(!rig.session.supportsQuickKeys)

            rig.start()
            try await rig.waitConnected()
            rig.session.quickKeys.open()
            try await waitUntil("every list read") { allFresh(rig.session.quickKeys) }
            rig.session.quickKeys.close()
            #expect(FileManager.default.fileExists(atPath: expected.path))

            // Another station's session has no cache, and doesn't claim quick keys before it connects.
            var other = Station()
            other.name = "Other Station"
            let otherSession = StationSession(station: other, environment: rig.session.environment)
            #expect(!otherSession.supportsQuickKeys)
            otherSession.quickKeys.open()
            #expect(otherSession.quickKeys.trees.isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: StationSession.quickKeysCacheURL(settingsDirectory: rig.dir, stationID: other.id).path))
            otherSession.quickKeys.close()

            // A fresh session for this station finds its cache: shown read-only, offered before connecting.
            let again = StationSession(station: rig.station, environment: rig.session.environment)
            #expect(again.supportsQuickKeys)
            again.quickKeys.open()
            #expect(Set(again.quickKeys.trees.keys) == Set(defaultLists))
            #expect(again.quickKeys.trees.values.allSatisfy { $0.freshness == .checking })
            #expect(again.quickKeys.switchState(for: .system(list: 1, system: 101)) == .unavailable)
            again.quickKeys.close()
        }
    }

    /// The owner-visible bug of 2026-11-19: over USB serial a `GLT` reply comes in pages, and with only the first
    /// page taken the next read got the rest, failed, and no list behind it ever loaded ("Checking…"). On the
    /// paged serial mocks (four elements a page), every list's tree loads whole, on every handheld.
    @Test func everyListsTreeLoadsWholeOverUSB() async throws {
        let mock = MockFavorites.default
        for personality in [MockPersonality.sds150, .sds100, .bcd436hp] {
            try await withUSBSession(USBSetup(personality: personality, quickKeysPollInterval: pollInterval)) { rig in
                let quickKeys = rig.session.quickKeys
                rig.start()
                try await rig.waitConnected()
                quickKeys.open()
                try await waitUntil("every list read on the \(personality.reportedModel)") { allFresh(quickKeys) }
                #expect(quickKeys.lists.map(\.index) == defaultLists)
                for list in defaultLists {
                    let tree = try #require(quickKeys.trees[list], "list \(list)")
                    let systems = mock.systems.filter { $0.listIndex == list }
                    #expect(tree.systems.map(\.index) == systems.map(\.index), "list \(list)")
                    for system in tree.systems {
                        let held = mock.children.filter { $0.systemIndex == system.index && $0.index != 4_294_967_295 }
                        let expected = held.filter { $0.kind == .department } + held.filter { $0.kind == .site }
                        #expect(system.children.map(\.index) == expected.map(\.index), "system \(system.index)")
                    }
                }
                quickKeys.close()
            }
        }
    }

    /// Plan 23 Task 10: on a BCD436HP session the pop-over's model attaches once connected, reads
    /// (`GLT,FL`, `FQK`, each list's paged tree), and one tile click sends exactly one `FQK` set
    /// naming only that key (0 everywhere else), followed by a re-read; nothing else changes state.
    @Test func bcd436hpTileClickSendsOneFQKSet() async throws {
        var setup = USBSetup(personality: .bcd436hp, quickKeysPollInterval: pollInterval)
        setup.personality = .bcd436hp
        let outcome = try await withUSBSession(setup) { rig in
            let quickKeys = rig.session.quickKeys
            rig.start()
            try await rig.waitConnected()
            #expect(rig.session.supportsQuickKeys)
            #expect(quickKeys.isAttached)
            quickKeys.open()
            try await waitUntil("every list read") { allFresh(quickKeys) }
            let first = await rig.commands.filter(isQuickKeyCommand)
            #expect(first.prefix(2) == ["GLT,FL", "FQK"], "\(first)")
            #expect(quickKeys.lists.map(\.index) == defaultLists)
            #expect(quickKeys.switchState(for: .list(4)) == .off)
            // Poll reads may run beside the click; only the sets and what follows them matter.
            let mark = await rig.commands.count
            await quickKeys.toggle(.list(4))
            let after = Array(await rig.commands.dropFirst(mark))
            let sets = after.filter { $0.hasPrefix("FQK,") }
            #expect(sets.count == 1, "\(after)")
            let values = (sets.first ?? "").split(separator: ",").dropFirst().map { Int($0) ?? -1 }
            #expect(values.count == 100, "\(sets)")
            #expect(values.enumerated().filter { $0.element != 0 }.map(\.offset) == [1], "\(sets)")
            // List 4's quick key is 1: "2" (on) there, "0" (leave alone) everywhere else.
            #expect(values.count > 1 && values[1] == 2, "\(sets)")
            #expect(after.filter { $0.hasPrefix("SQK,") && $0.split(separator: ",").count > 2 }.isEmpty, "\(after)")
            #expect(quickKeys.switchState(for: .list(4)) == .on)
            // The set was followed by a re-read of that scope.
            let setAt = try #require(after.firstIndex { $0.hasPrefix("FQK,") })
            #expect(after[(setAt + 1)...].contains("FQK"), "\(after)")
            quickKeys.close()
        }
        #expect(!outcome.commands.contains { $0.hasPrefix("KAL") || $0.hasPrefix("GCS") || $0.hasPrefix("MNU")
                                              || $0.hasPrefix("MSB") || $0.hasPrefix("HLD") || $0.hasPrefix("KEY") },
                "\(outcome.commands)")
        #expect(outcome.commands.last == "PSI,0", "\(outcome.commands.suffix(5))")
    }

    @Test func noCooldownCall() async throws {
        let outcome = try await withUSBSession(USBSetup(quickKeysPollInterval: pollInterval)) { rig in
            let quickKeys = rig.session.quickKeys
            rig.start()
            try await rig.waitConnected()
            quickKeys.open()
            try await waitUntil("every list read") { allFresh(quickKeys) }
            try await Task.sleep(for: pollInterval * 3)  // a few polls
            quickKeys.close()
            #expect(rig.cooldown.calls == [])
        }
        #expect(outcome.cooldownCalls == [])
        #expect(outcome.commands.contains("GLT,FL"))
    }

    /// A model whose profile lacks quick keys never attaches the model: an open sends nothing.
    @Test func aModelWithoutQuickKeysNeverReads() async throws {
        var personality = MockPersonality.sds150
        personality.reportedModel = "UBC9999"
        try await withUSBSession(USBSetup(personality: personality, quickKeysPollInterval: pollInterval)) { rig in
            rig.start()
            try await rig.waitConnected()
            #expect(!rig.session.supportsQuickKeys)
            #expect(!rig.session.quickKeys.isAttached)
            rig.session.quickKeys.open()
            try await Task.sleep(for: pollInterval * 4)
            #expect(await rig.commands.filter(isQuickKeyCommand).isEmpty)
            rig.session.quickKeys.close()
        }
    }

    /// An `MDL` that names no known model, on a station with no override, has no quick keys (no `.sds200`
    /// fallback, unlike `session.model`): nothing attaches, and an open reads nothing (Task 7 QA m1).
    @Test func anUnrecognisedModelGetsNoQuickKeys() async throws {
        var personality = MockPersonality.sds150
        personality.reportedModel = "XR9000"
        try await withUSBSession(USBSetup(personality: personality, quickKeysPollInterval: pollInterval)) { rig in
            #expect(rig.station.connection.modelOverride == nil)
            rig.start()
            try await rig.waitConnected()
            #expect(rig.session.model == .sds200, "the session's own fallback, which quick keys don't follow")
            #expect(!rig.session.supportsQuickKeys)
            #expect(!rig.session.quickKeys.isAttached)
            rig.session.quickKeys.open()
            try await Task.sleep(for: pollInterval * 4)
            #expect(await rig.commands.filter(isQuickKeyCommand).isEmpty)
            rig.session.quickKeys.close()
        }
    }

    /// An `MDL` that names no known model falls back to the station's override, so the override's quick keys
    /// attach (every known model has them now, so no model can show the detected one winning).
    @Test func anUnknownModelFallsBackToTheOverride() async throws {
        var personality = MockPersonality.sds150
        personality.reportedModel = "UBC9999"
        try await withUSBSession(USBSetup(personality: personality, quickKeysPollInterval: pollInterval)) { rig in
            var station = rig.station
            station.connection.modelOverride = .sds150
            let session = StationSession(station: station, environment: rig.environment)
            #expect(session.supportsQuickKeys, "before connecting, the override answers")
            let done = Done()
            Task { await session.start(); done.value = true }
            var failure: (any Error)?
            do {
                try await waitUntil("connected (phase \(session.phase))") {
                    if case .connected = session.phase { return true }
                    return false
                }
                #expect(session.supportsQuickKeys)
                #expect(session.quickKeys.isAttached)
            } catch { failure = error }
            await session.stop()
            try await waitUntil("start() to return") { done.value }
            if let failure { throw failure }
        }
    }

    /// The station's model override answers before any connection; the connected model's profile after.
    @Test func supportsQuickKeysFollowsTheModel() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-qk-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let environment = SessionEnvironment(settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
                                             recordingsRoot: dir, cooldownStore: InMemoryRTSPCooldownStore())
        var station = Station()
        station.connection.modelOverride = .sds100
        #expect(StationSession(station: station, environment: environment).supportsQuickKeys)
        station.connection.modelOverride = .bcd436hp
        #expect(StationSession(station: station, environment: environment).supportsQuickKeys)
        station.connection.modelOverride = nil
        #expect(!StationSession(station: station, environment: environment).supportsQuickKeys)
    }

    /// `session.menu`'s own reads say "in a menu" as well as the pushes: the moment the menu model shows a
    /// menu, nothing switches; when it leaves, every tree is checked again.
    @Test func theMenuModelsKnowledgeStopsSwitching() async throws {
        try await withSession(Setup(quickKeysPollInterval: pollInterval)) { rig in
            let quickKeys = rig.session.quickKeys
            rig.start()
            try await rig.waitConnected()
            quickKeys.open()
            try await waitUntil("every list read") { allFresh(quickKeys) }
            #expect(quickKeys.switchState(for: .list(4)) == .off)
            #expect(!(rig.session.info?.isMenu ?? false), "the scanner isn't in a menu")
            let keypadReads = await rig.commands.filter { $0 == "GLT,FL" }.count

            // As if the menu model had read a menu screen (pushes still say scanning).
            rig.session.menu.show(.mirrored, title: "Fictional Menu", menuIndex: "1")
            #expect(quickKeys.isInMenu)
            #expect(quickKeys.switchState(for: .list(4)) == .inMenu)
            await quickKeys.toggle(.list(4))  // refused
            #expect(!(await rig.commands.contains { $0.hasPrefix("FQK,") }))

            // The menu model's own read (GSI) finds no menu: switching comes back after a full re-check.
            try await waitUntil("the menu model leaves the menu") { !rig.session.menu.isInMenu }
            #expect(!quickKeys.isInMenu)
            try await waitUntil("the keypad read again") {
                await rig.commands.filter { $0 == "GLT,FL" }.count > keypadReads
            }
            try await waitUntil("every list read again") { allFresh(quickKeys) }
            #expect(quickKeys.switchState(for: .list(4)) == .off)
            quickKeys.close()
        }
    }

    /// A tile's click under way (its `FQK` set's reply takes the mock's 0.8 s): Services and Range
    /// are refused `.busy` and send nothing, so no walk's enter can be written ahead of a set still
    /// waiting for the slot (services-range design §5.1 step 0, §10).
    @Test func walkRefusedWhileAQuickKeySetIsPending() async throws {
        let outcome = try await withSession(Setup(quickKeysPollInterval: pollInterval)) { rig in
            let session = rig.session
            let quickKeys = session.quickKeys
            rig.start()
            try await rig.waitConnected()
            quickKeys.open()
            try await waitUntil("every list read") { allFresh(quickKeys) }
            #expect(!quickKeys.hasPendingChange)
            let click = Task { @MainActor in await quickKeys.toggle(.list(4)) }
            try await waitUntil("the set is sent") { await rig.commands.contains { $0.hasPrefix("FQK,") } }
            #expect(quickKeys.hasPendingChange)
            await #expect(throws: MenuActionError.busy) { try await session.openMenuShortcut(.range) }
            session.press(.range)
            #expect(session.menuShortcutInFlight == nil, "the press is refused too")
            #expect(session.menuShortcutMessage == nil, "busy says nothing")
            await click.value
            #expect(!quickKeys.hasPendingChange)
            quickKeys.close()
        }
        #expect(!outcome.commands.contains { $0.hasPrefix("KEY,M") || $0.hasPrefix("MSV") }, "\(outcome.commands)")
        #expect(outcome.commands.filter { $0.hasPrefix("FQK,") }.count == 1, "\(outcome.commands)")
    }
}
