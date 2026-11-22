// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import Foundation
import NoctuleKit
import NoctuleMockScanner
import NoctuleStore
import SwiftUI
import Testing
@testable import NoctuleAppCore
@testable import NoctuleScan

/// `MacMenuActions` against a connected `StationSession` on an in-process `MockSDS200` and its
/// fictional menu tree: what each click or key press sends, read from the mock's received commands.
/// Every wait is bounded; every test stops the session and the mock on all paths and checks that
/// no RTSP session leaked. All names are fictional.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct MacMenuActionsTests {
    struct TimedOut: Error { let what: String }
    final class Flag { var value = false }

    private func waitUntil(_ what: String, _ limit: Duration = .seconds(5),
                           _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor struct Rig {
        let mock: MockSDS200
        let session: StationSession
        let udpPort: UInt16
        var menu: MenuModel { session.menu }
    }

    /// A connected session on a fresh mock; always stops both. Returns the mock's leaked sessions.
    @discardableResult
    private func withMenuSession(replyDelays: [String: Duration] = [:],
                                 _ body: (Rig) async throws -> Void) async throws -> [String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-macmenu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let options = MockSDS200.Options(clock: .stepped(at: 1), reconnectCooldown: .milliseconds(300),
                                         rebootDuration: .milliseconds(300), replyDelays: replyDelays)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        var station = Station()
        station.name = "Test Station"
        station.connection.host = "127.0.0.1"
        station.connection.udpPort = ports.udpPort
        station.connection.rtspPort = ports.rtspPort
        let environment = SessionEnvironment(
            settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
            recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
            cooldownStore: InMemoryRTSPCooldownStore(), cooldown: .milliseconds(300),
            audioConfig: AudioSessionConfig(requestTimeout: .seconds(1), rtpCloseDelay: .milliseconds(50)))
        let session = StationSession(station: station, environment: environment)
        let rig = Rig(mock: mock, session: session, udpPort: ports.udpPort)

        let started = Flag()
        Task { await session.start(); started.value = true }
        var failure: (any Error)?
        do {
            try await waitUntil("connected") {
                if case .connected = session.phase { return true }
                return false
            }
            try await body(rig)
        } catch { failure = error }
        let stopped = Flag()
        Task { await session.stop(); stopped.value = true }
        do {
            try await waitUntil("stop", .seconds(15)) { stopped.value }
            try await waitUntil("start() to return", .seconds(15)) { started.value }
        } catch { if failure == nil { failure = error } }
        await mock.stop()
        let leaked = await mock.leakedSessions
        if let failure { throw failure }
        return leaked
    }

    /// The mock's state-changing commands (`KEY`, `MSV`) since `mark`.
    private func sent(_ rig: Rig, since mark: Int) async -> [String] {
        await rig.mock.control.receivedCommands.dropFirst(mark).filter {
            let name = $0.uppercased()
            return name.hasPrefix("KEY,") || name.hasPrefix("MSV,")
        }
    }

    private func mark(_ rig: Rig) async -> Int { await rig.mock.control.receivedCommands.count }

    /// Enters the menu and opens each named item, straight through the model (test setup).
    private func open(_ rig: Rig, _ path: [String]) async throws -> MenuScreen {
        var content = try await rig.menu.enter()
        for name in path {
            guard case .list(let screen) = content, let item = screen.items.first(where: { $0.name == name }) else {
                throw TimedOut(what: "no \(name) in \(String(describing: content))")
            }
            content = try await rig.menu.choose(item, on: screen)
        }
        switch content {
        case .list(let screen), .entry(let screen): return screen
        default: throw TimedOut(what: "not a list or entry: \(String(describing: content))")
        }
    }

    /// Lets any action task spawned in this turn run to its end.
    private func settle(_ rig: Rig) async throws {
        try await Task.sleep(for: .milliseconds(50))
        try await waitUntil("idle") { !rig.menu.isBusy }
    }

    // MARK: Key repeats (fix round 1, Critical)

    @Test func keyRepeatActivationsSendNothing() async throws {
        let leaked = try await withMenuSession { rig in
            let lists = try await open(rig, ["Set Scan Selection", "Select Lists to Monitor"])
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            let repeating = MacMenuActions(menu: rig.menu, state: state, isKeyRepeat: { true })
            let before = await mark(rig)
            #expect(repeating.activateSelection(on: lists) == nil)
            #expect(repeating.choose(lists.items[2], on: lists) == nil)
            #expect(repeating.back() == nil)
            #expect(repeating.exit() == nil)
            #expect(repeating.press(.soft1) == nil)
            #expect(repeating.press(.enterYes) == nil)
            #expect(repeating.perform(.activate) == nil)
            #expect(repeating.perform(.back) == nil)
            state.pendingConfirmation = .init(itemName: "Set All Lists Off", item: nil, screen: nil)
            #expect(repeating.confirm() == nil)
            #expect(state.pendingConfirmation != nil, "a repeat neither sends nor answers the confirmation")
            state.pendingConfirmation = nil
            try await settle(rig)
            #expect(await sent(rig, since: before).isEmpty)

            // Scroll keys repeat, as in the Scanner view's key monitor.
            let scroll = await mark(rig)
            try await #require(repeating.press(.scrollRight)).value
            #expect(await sent(rig, since: scroll) == ["KEY,>,P"])

            // An entry: Save, Cancel.
            _ = try await rig.menu.exit()
            let range = try await open(rig, ["Set Your Location", "Set Range"])
            state.sync(with: rig.menu.content)
            state.setDraft("12", rules: range.input!)
            let entry = await mark(rig)
            #expect(repeating.save(on: range) == nil)
            #expect(repeating.perform(.activate) == nil)
            #expect(repeating.back() == nil)
            try await settle(rig)
            #expect(await sent(rig, since: entry).isEmpty)

            // Outside a menu: the Menu button.
            _ = try await rig.menu.exit()
            let outside = await mark(rig)
            #expect(repeating.enter() == nil)
            try await settle(rig)
            #expect(await sent(rig, since: outside).isEmpty)
            #expect(!rig.menu.isInMenu)
        }
        #expect(leaked == [])
    }

    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    /// QA's harness as a test: a hosted default button (as Toggle is) gets a Return and then held
    /// Returns (`isARepeat`) as key equivalents. SwiftUI fires the button on every repeat; only the
    /// first press may act. `isKeyRepeat` reads the event being dispatched, standing in for
    /// `NSApp.currentEvent`, which a test process can't set.
    @Test func heldReturnOnADefaultButtonTogglesOnce() async throws {
        let leaked = try await withMenuSession { rig in
            let lists = try await open(rig, ["Set Scan Selection", "Select Lists to Monitor"])
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            state.selection = 2
            // The event being dispatched, as `NSApp.currentEvent` would give it in the app (a test
            // process can't dequeue events: `NSApp.nextEvent` here ended the test process).
            var dispatching: NSEvent?
            let actions = MacMenuActions(menu: rig.menu, state: state,
                                         isKeyRepeat: { dispatching.map { $0.type == .keyDown && $0.isARepeat } ?? false })
            var fired = 0
            let button = Button("Toggle") {
                fired += 1
                actions.activateSelection(on: lists)
            }.keyboardShortcut(.defaultAction)

            _ = NSApplication.shared
            let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled],
                                   backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: button)
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 80)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            @MainActor func dispatchReturn(repeat isRepeat: Bool) throws {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: isRepeat, keyCode: 36))
                dispatching = event
                defer { dispatching = nil }
                // What AppKit does with a key equivalent for the key window (`sendEvent` alone
                // doesn't reach it in a test process, which can't become active).
                #expect(window.performKeyEquivalent(with: event), "the default button took Return")
            }

            let before = await mark(rig)
            try dispatchReturn(repeat: false)
            try await settle(rig)
            for _ in 0..<8 {
                try dispatchReturn(repeat: true)
                try await settle(rig)  // busy clears between repeats, as when a reply is quick
            }
            #expect(fired >= 2, "the harness reached the button on repeats (fired \(fired))")
            let msvs = await sent(rig, since: before).filter { $0.uppercased().hasPrefix("MSV,") }
            #expect(msvs.count == 1, "one Return held down toggled \(msvs.count) times")
        }
        #expect(leaked == [])
    }

    // MARK: Confirmation (fix round 1, Important 2)

    @Test func returnAndEscCancelAPendingConfirmation() async throws {
        let leaked = try await withMenuSession { rig in
            let settings = try await open(rig, ["Settings"])
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            let actions = MacMenuActions(menu: rig.menu, state: state, isKeyRepeat: { false })
            let before = await mark(rig)
            for command in [MacMenuCommand.activate, .back] {
                try await #require(actions.activateSelection(on: settings)).value
                #expect(state.pendingConfirmation?.itemName == "Clear User Data")
                #expect(actions.perform(command) == nil)
                #expect(state.pendingConfirmation == nil, "\(command) cancels")
                try await settle(rig)
            }
            #expect(await sent(rig, since: before).isEmpty)
            #expect(await !rig.mock.menuActions.contains("run Clear User Data"))
            #expect(rig.menu.isInMenu)
        }
        #expect(leaked == [])
    }

    @Test func confirmOnAListItemSendsOneMSV() async throws {
        let leaked = try await withMenuSession { rig in
            let settings = try await open(rig, ["Settings"])
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            let actions = MacMenuActions(menu: rig.menu, state: state, isKeyRepeat: { false })
            try await #require(actions.activateSelection(on: settings)).value
            #expect(state.pendingConfirmation == .init(itemName: "Clear User Data", item: settings.items[0], screen: settings))
            let before = await mark(rig)
            try await #require(actions.confirm()).value
            #expect(state.pendingConfirmation == nil)
            #expect(await sent(rig, since: before) == ["MSV,,0"])
            #expect(await rig.mock.menuActions.last == "run Clear User Data")
        }
        #expect(leaked == [])
    }

    @Test func confirmOnAMirroredEnterSendsOneKeyWithTheShownName() async throws {
        let leaked = try await withMenuSession { rig in
            _ = try await open(rig, ["Set Scan Selection"])
            _ = try await rig.menu.press(.scrollRight)  // Set All Lists Off highlighted
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            let actions = MacMenuActions(menu: rig.menu, state: state, isKeyRepeat: { false })
            try await #require(actions.press(.enterYes)).value
            #expect(state.pendingConfirmation == .init(itemName: "Set All Lists Off", item: nil, screen: nil))
            let before = await mark(rig)
            try await #require(actions.confirm()).value
            #expect(await sent(rig, since: before) == ["KEY,E,P"])
            #expect(await rig.mock.menuActions.last == "run Set All Lists Off")
        }
        #expect(leaked == [])
    }

    @Test func confirmAfterTheHighlightMovedSendsNothing() async throws {
        let leaked = try await withMenuSession { rig in
            _ = try await open(rig, ["Set Scan Selection"])
            _ = try await rig.menu.press(.scrollRight)
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            let actions = MacMenuActions(menu: rig.menu, state: state, isKeyRepeat: { false })
            try await #require(actions.press(.enterYes)).value
            #expect(state.pendingConfirmation?.itemName == "Set All Lists Off")
            // The radio's panel moves to the other destructive row while the confirmation shows.
            let panel = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: rig.udpPort))
            try await panel.connect()
            try await panel.press(.scrollRight)
            await panel.disconnect()
            let actionsBefore = await rig.mock.menuActions
            let before = await mark(rig)
            try await #require(actions.confirm()).value
            #expect(await sent(rig, since: before).isEmpty)
            #expect(rig.menu.lastError == .menuChanged)
            #expect(await rig.mock.menuActions == actionsBefore)
        }
        #expect(leaked == [])
    }

    @Test func needsConfirmationAsksOnlyWhileTheContentIsUnchanged() async throws {
        let leaked = try await withMenuSession { rig in
            let settings = try await open(rig, ["Settings"])
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            let actions = MacMenuActions(menu: rig.menu, state: state, isKeyRepeat: { false })
            // The content changes between the click and the refusal: no confirmation for a screen that has gone.
            let task = try #require(actions.activateSelection(on: settings))
            rig.menu.show(.mirrored, title: "Settings", menuIndex: nil)
            await task.value
            #expect(state.pendingConfirmation == nil)
            // Unchanged: it asks.
            _ = try await rig.menu.refresh()
            state.sync(with: rig.menu.content)
            try await #require(actions.activateSelection(on: settings)).value
            #expect(state.pendingConfirmation?.itemName == "Clear User Data")
        }
        #expect(leaked == [])
    }

    @Test func twoActivationsInOneTurnSendOneCommand() async throws {
        let leaked = try await withMenuSession { rig in
            _ = try await open(rig, ["Set Scan Selection", "Select Lists to Monitor"])
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            state.selection = 2
            let actions = MacMenuActions(menu: rig.menu, state: state, isKeyRepeat: { false })
            let before = await mark(rig)
            let first = actions.perform(.activate)
            let second = actions.perform(.activate)
            await first?.value
            await second?.value
            try await settle(rig)
            #expect(await sent(rig, since: before).filter { $0.hasPrefix("MSV,") }.count == 1)
            #expect(rig.menu.lastError == nil, ".busy isn't recorded")
            #expect(MacMenuText.statusLine(lastError: rig.menu.lastError, isScannerAnswering: rig.menu.isScannerAnswering) == nil,
                    "no error line for .busy")
        }
        #expect(leaked == [])
    }

    // MARK: Entry while busy (fix rounds 1 and 2)

    /// Typing goes on while an action is in flight (the field never refuses it, so what it shows is
    /// the draft); only a submit is refused then, so one Save sends one value.
    @Test func entryEditsAreKeptWhileBusyButASubmitSendsNothing() async throws {
        let leaked = try await withMenuSession(replyDelays: ["MSV": .milliseconds(400)]) { rig in
            let range = try await open(rig, ["Set Your Location", "Set Range"])
            let rules = try #require(range.input)
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            let actions = MacMenuActions(menu: rig.menu, state: state, isKeyRepeat: { false })
            state.setDraft("12", rules: rules)
            let before = await mark(rig)
            let save = try #require(actions.save(on: range))
            try await waitUntil("the save is in flight") { rig.menu.isBusy }
            state.setDraft("25", rules: rules)
            #expect(state.draft == "25", "typing while busy is kept")
            #expect(actions.save(on: range) == nil, "a second submit while busy starts nothing")
            #expect(actions.perform(.activate) == nil)
            await save.value
            try await settle(rig)
            #expect(await sent(rig, since: before) == ["MSV,,12"])
        }
        #expect(leaked == [])
    }

    // MARK: An unanswered MSI keeps the screen (final review I4)

    /// A refresh whose `MSI` goes unanswered on the same entry screen keeps the entry, so the
    /// draft the user is typing survives (it was replaced by the mirrored text and lost).
    @Test func theDraftSurvivesAnUnansweredRefresh() async throws {
        let leaked = try await withMenuSession { rig in
            let entry = try await open(rig, ["Search for...", "Edit Custom", "Custom 3", "Edit Name"])
            let rules = try #require(entry.input)
            let state = MacMenuState()
            state.sync(with: rig.menu.content)
            #expect(state.draft == "Custom 3")
            state.setDraft("Night Op", rules: rules)
            let before = await mark(rig)
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MSI", dropCount: 1000))
            _ = try? await rig.menu.refresh()
            state.sync(with: rig.menu.content)
            #expect(rig.menu.content == .entry(entry))
            #expect(!rig.menu.isScannerAnswering)
            #expect(state.draft == "Night Op", "the typing is kept")
            await rig.mock.setFaults(MockFaults())
            _ = try await rig.menu.refresh()
            state.sync(with: rig.menu.content)
            #expect(rig.menu.isScannerAnswering)
            #expect(state.draft == "Night Op")
            #expect(await sent(rig, since: before).isEmpty)
        }
        #expect(leaked == [])
    }

    // MARK: Local moves repeat (fix round 2)

    /// ↑/↓ on a list only move the local selection, so a held arrow keeps moving it.
    @Test func localMovesRepeat() throws {
        let screen = try MenuScreen(xml: NoctuleKit.XMLNode.parse(Data(
            (#"<MSI Name="Lists" Index="4293060002" MenuType="TypeSelect" Selected="0">"#
             + (0..<5).map { #"<MenuItem Name="List \#($0)" Index="\#($0)" Value="On" />"# }.joined()
             + "</MSI>").utf8)))
        let menu = MenuModel()
        menu.show(.list(screen), title: "Lists", menuIndex: "4293060002")
        let state = MacMenuState()
        state.sync(with: menu.content)
        let repeating = MacMenuActions(menu: menu, state: state, isKeyRepeat: { true })
        repeating.perform(.moveDown)
        repeating.perform(.moveDown)
        #expect(state.selection == 2)
        repeating.perform(.moveUp)
        #expect(state.selection == 1)
    }
}
#endif
