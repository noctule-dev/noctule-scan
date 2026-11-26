// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
@testable import NoctuleKit
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

// MenuModel against a connected StationSession on an in-process MockSDS200 and its fictional menu
// tree (helpers in SessionTestSupport.swift). Each negative test reads the mock's received commands:
// a refused action must send no KEY or MSV. Every wait is bounded and every test stops the session
// and the mock in all paths. All names and values are fictional.

private let topItems = ["Set Scan Selection", "Set Your Location", "Search for...", "Display Options", "Settings"]

private func screen(_ content: MenuContent?) -> MenuScreen? {
    switch content {
    case .list(let screen), .entry(let screen): screen
    case .mirrored, nil: nil
    }
}

private func title(_ content: MenuContent?) -> String? {
    screen(content)?.title?.trimmingCharacters(in: .whitespaces)
}

private func isList(_ content: MenuContent?) -> Bool {
    if case .list = content { return true }
    return false
}

private func states(_ commands: [String]) -> [String] {
    commands.filter { $0.uppercased().hasPrefix("KEY,") || $0.uppercased().hasPrefix("MSV,") }
}

private func msvs(_ commands: [String]) -> [String] {
    commands.filter { $0.uppercased().hasPrefix("MSV,") }
}

private func keys(_ commands: [String]) -> [String] {
    commands.filter { $0.uppercased().hasPrefix("KEY,") }
}

private func parsedScreen(_ xml: String) throws -> MenuScreen {
    try MenuScreen(xml: XMLNode.parse(Data(xml.utf8)))
}

@MainActor
private func connect(_ rig: Rig) async throws {
    rig.start()
    try await rig.waitConnected()
}

/// Enters the menu and chooses each named item in turn; returns the content after the last.
@MainActor
private func open(_ rig: Rig, _ path: [String]) async throws -> MenuContent? {
    var content = try await rig.session.menu.enter()
    for name in path {
        let current = try #require(screen(content), "no list to choose \(name) from: \(String(describing: content))")
        let item = try #require(current.items.first { $0.name == name }, "no \(name) in \(current.items.map(\.name))")
        content = try await rig.session.menu.choose(item, on: current)
    }
    return content
}

/// A second client on the mock, standing in for the radio's own front panel.
private func panel(_ rig: Rig) async throws -> ScannerClient {
    let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: rig.station.connection.udpPort))
    try await client.connect()
    return client
}

/// Runs `body` with a panel client, disconnecting it on every path (it never subscribes, so no PSI).
@MainActor
private func withPanel(_ rig: Rig, _ body: (ScannerClient) async throws -> Void) async throws {
    let client = try await panel(rig)
    do { try await body(client) } catch {
        await client.disconnect()
        throw error
    }
    await client.disconnect()
}

/// The thrown `MenuActionError`, or nil when `body` returned.
@MainActor
private func menuError(_ body: () async throws -> MenuContent?) async -> MenuActionError? {
    do {
        _ = try await body()
        return nil
    } catch let error as MenuActionError {
        return error
    } catch {
        Issue.record("not a MenuActionError: \(error)")
        return nil
    }
}

private let trailingFields = ["1", "1", "0", "0", "", "", "0", "OFF", "3"]

private func pad(_ text: String) -> String { text.padding(toLength: 30, withPad: " ", startingAt: 0) }

/// A ten-line menu `STS` (design §4.2) with `highlighted` drawn reverse (`*` in every column).
private func menuDisplay(_ lines: [String], highlighted: Int?, cursorOnly: Bool = false,
                         screenKind: String = "menu_selection") throws -> DisplayModel {
    let status = try menuStatus(lines, highlighted: highlighted, cursorOnly: cursorOnly)
    let xml = "<ScannerInfo Mode=\"Menu tree\" V_Screen=\"\(screenKind)\"><MenuSummary name=\"\(lines[0])\" index=\"4293060001\" /></ScannerInfo>"
    let info = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
    return DisplayModel(status: status, info: info)
}

/// The raw `STS` of `menuDisplay(_:highlighted:cursorOnly:screenKind:)`.
private func menuStatus(_ lines: [String], highlighted: Int?, cursorOnly: Bool = false) throws -> DisplayStatus {
    var rows = lines.map { pad($0) }
    rows += Array(repeating: pad(""), count: 10 - rows.count)
    let masks = rows.indices.map { index -> String in
        if index == 0 { return String(repeating: "_", count: 30) }
        guard index == highlighted else { return pad("") }
        return cursorOnly ? "*" + String(repeating: " ", count: 29) : String(repeating: "*", count: 30)
    }
    return try DisplayStatus(fields: ["1111111111"] + zip(rows, masks).flatMap { [$0, $1] } + trailingFields)
}

/// A menu action whose command queues for the client's request slot behind a `GSI` the mock never answers (the
/// quick keys' I2 window, flaky-sweep review, on the menu). The `control()` call just before the command (after
/// `checkReads` calls for the action's own reads) first starts that `GSI`, waits until the mock has it, then hands
/// over the client; once the command is queued behind it, `interfere` runs, then the `GSI` is cancelled, freeing
/// the slot. Returns the action's result and the mock's `KEY`, `MSV` and `MSI` commands since the action began.
@MainActor
private func menuActionHeldAtTheSlot(
    checkReads: Int = 0, at screen: @escaping (ScannerClient) async throws -> MenuScreen,
    _ action: @escaping @MainActor (MenuModel, MenuScreen) async throws -> MenuContent?,
    whileWaiting interfere: @MainActor (MenuModel) -> Void
) async throws -> (result: Result<MenuContent?, any Error>, commands: [String]) {
    let mock = MockSDS200(scenario: .default, options: MockSDS200.Options(clock: .stepped(at: 1)))
    let ports = try await mock.start()
    let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort),
                               commandTimeout: .seconds(10))
    let held = Mutex<Task<Void, Never>?>(nil)
    do {
        try await client.connect()
        let current = try await screen(client)
        let mark = await commandMark(mock)
        let armed = Mutex<Int?>(checkReads)
        let model = MenuModel()
        model.attach(control: {
            let hold = armed.withLock { armed -> Bool in
                guard let left = armed else { return false }
                armed = left == 0 ? nil : left - 1
                return left == 0
            }
            if hold {
                let before = await mock.control.receivedCommands.count
                await mock.setFaults(MockFaults(dropNextRequest: "GSI"))
                held.withLock { $0 = Task { _ = try? await client.scannerInfo() } }
                let deadline = ContinuousClock.now + .seconds(5)
                while !(await mock.control.receivedCommands.dropFirst(before).contains("GSI")),
                      ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            return client
        })
        model.show(MenuModel.content(for: current), title: current.title, menuIndex: current.menuIndex)
        let task = Task { try await action(model, current) }
        try await waitUntil("the command queued behind the held GSI", .seconds(5)) {
            await client.requestsWaitingForTheSlot == 1
        }
        interfere(model)
        held.withLock { $0?.cancel() }
        let result = await task.result
        await held.withLock { $0 }?.value
        model.detach()
        await model.quiesce()
        let commands = await menuCommands(mock, since: mark)
        await client.disconnect()
        await mock.stop()
        return (result, commands)
    } catch {
        held.withLock { $0?.cancel() }
        await client.disconnect()
        await mock.stop()
        throw error
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct MenuModelTests {
    // MARK: Lists, entries, keys

    @Test func enterShowsTheTopList() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            #expect(menu.content == nil)
            #expect(!menu.isInMenu)
            let content = try await menu.enter()
            guard case .list(let top) = content else {
                Issue.record("not a list: \(String(describing: content))"); return
            }
            #expect(top.items.count == 5)
            #expect(top.items.map(\.name) == topItems)
            #expect(menu.content == content)
            #expect(menu.breadcrumb == ["Menu"])
            #expect(rig.session.menu.isInMenu)
            #expect(!menu.isBusy)
            #expect(menu.lastError == nil)
            #expect(await rig.mock.isInMenu)
            #expect(keys(await menuCommands(rig.mock)) == ["KEY,M,P"])
            #expect(msvs(await menuCommands(rig.mock)).isEmpty)
        }
        #expect(outcome.leaked == [])
    }

    @Test func chooseOpensSubmenuWithOneMSV() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let top = try #require(screen(try await menu.enter()))
            let item = try #require(top.items.first { $0.name == "Display Options" })
            #expect(item.index == 4, "MSI omits Analyze (3); the rest keep their indexes")
            let mark = await commandMark(rig.mock)
            let content = try await menu.choose(item, on: top)
            #expect(isList(content))
            #expect(title(content) == "Display Options")
            #expect(menu.content == content)
            let commands = await menuCommands(rig.mock, since: mark)
            #expect(states(commands) == ["MSV,,4"], "\(commands)")
            let msv = try #require(commands.firstIndex(of: "MSV,,4"))
            #expect(msv > 0 && commands[..<msv].allSatisfy { $0 == "MSI" }, "an MSI re-check first: \(commands)")
            #expect(commands[(msv + 1)...].allSatisfy { $0 == "MSI" }, "then reads only: \(commands)")
            #expect(commands[(msv + 1)...].count >= 1, "the screen is re-read after the action")
            #expect(menu.breadcrumb == ["Menu", "Display Options"])
            #expect(await rig.mock.menuPath.count == 2)
        }
        #expect(outcome.leaked == [])
    }

    @Test func toggleUpdatesTheItem() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let lists = try #require(screen(try await open(rig, ["Set Scan Selection", "Select Lists to Monitor"])))
            #expect(lists.title == "Select Lists to Monitor")
            #expect(lists.items.count == 12)
            let item = try #require(lists.items.first { $0.name == "Lakeview Fire" })
            #expect(item.value == "On")
            let content = try await menu.choose(item, on: lists)
            guard case .list(let after) = content else {
                Issue.record("not a list: \(String(describing: content))"); return
            }
            #expect(after.title == "Select Lists to Monitor", "a toggle stays on the list")
            #expect(after.items.first { $0.name == "Lakeview Fire" }?.value == "Off")
            #expect(after.items.first { $0.name == "County Roads" }?.value == "On")
            #expect(await rig.mock.menuActions.last == "toggle Lakeview Fire Off")
            #expect(menu.breadcrumb == ["Menu", "Set Scan Selection", "Select Lists to Monitor"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func setValueSavesAName() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let content = try await open(rig, ["Search for...", "Edit Custom", "Custom 3", "Edit Name"])
            guard case .entry(let entry) = content else {
                Issue.record("not an entry: \(String(describing: content))"); return
            }
            #expect(entry.value == "Custom 3")
            #expect(entry.input?.maxLength == 64)
            #expect(menu.breadcrumb == ["Menu", "Search for...", "Select Custom", "Custom 3", "Edit Name"])
            let mark = await commandMark(rig.mock)
            let after = try await menu.setValue("Night Ops", on: entry)
            #expect(isList(after), "saving returns to the bank's list")
            #expect(title(after) == "Night Ops", "the bank is named after its entry")
            #expect(await rig.mock.menuActions.last == "set Edit Name Night Ops")
            #expect(states(await menuCommands(rig.mock, since: mark)) == ["MSV,,Night Ops"])
            // The bank keeps its place in the path under its new name (same menu index).
            #expect(menu.breadcrumb == ["Menu", "Search for...", "Select Custom", "Night Ops"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func setRangeLeavesTheMenu() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let content = try await open(rig, ["Set Your Location", "Set Range"])
            guard case .entry(let entry) = content else {
                Issue.record("not an entry: \(String(describing: content))"); return
            }
            #expect(entry.value == "30.0")
            #expect(entry.input?.addedInformation?.trimmingCharacters(in: .whitespaces) == "(mile)")
            let after = try await menu.setValue("31.0", on: entry)
            #expect(after == nil)
            #expect(menu.content == nil)
            #expect(menu.breadcrumb.isEmpty)
            #expect(!menu.isInMenu)
            #expect(await rig.mock.menuActions.last == "set Set Range 31.0")
            #expect(await !rig.mock.isInMenu)
        }
        #expect(outcome.leaked == [])
    }

    @Test func backAndExit() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            #expect(title(try await open(rig, ["Display Options"])) == "Display Options")
            let mark = await commandMark(rig.mock)
            let up = try await menu.back()
            #expect(screen(up)?.items.map(\.name) == topItems)
            #expect(menu.breadcrumb == ["Menu"])
            let out = try await menu.exit()
            #expect(out == nil)
            #expect(menu.content == nil)
            #expect(menu.breadcrumb.isEmpty)
            #expect(await !rig.mock.isInMenu)
            #expect(states(await menuCommands(rig.mock, since: mark)) == ["KEY,M,P", "KEY,L,P"])
        }
        #expect(outcome.leaked == [])
    }

    // MARK: Exit Menu reads GSI first (final review I1)

    @Test func exitReadsGSIThenSendsOneKey() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Display Options"])
            let mark = await commandMark(rig.mock)
            #expect(try await menu.exit() == nil)
            let since = Array(await rig.commands.dropFirst(mark)).filter { $0.uppercased() != "STS" }
            let key = try #require(since.firstIndex(of: "KEY,L,P"), "\(since)")
            #expect(since[..<key].contains("GSI"), "GSI before the key: \(since)")
            #expect(keys(since) == ["KEY,L,P"])
            #expect(await !rig.mock.isInMenu)
        }
        #expect(outcome.leaked == [])
    }

    @Test func exitAfterThePanelLeftSendsNothing() async throws {
        // The reviewer's reproduction: Avoid on the radio's panel leaves the menu, and Exit Menu is
        // clicked before the model has followed. Outside a menu KEY,L is Avoid.
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Display Options"])
            let mark = await commandMark(rig.mock)
            try await withPanel(rig) { panel in try await panel.press(.avoid) }
            #expect(await !rig.mock.isInMenu)
            let error = await menuError { try await menu.exit() }
            // .notInMenu only if the model followed the panel out first; either way nothing is sent.
            #expect(error == nil || error == .notInMenu, "\(String(describing: error))")
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,L,P"], "the panel's only")
            #expect(menu.content == nil)
            #expect(await !rig.mock.isInMenu)
        }
        #expect(outcome.leaked == [])
    }

    @Test func exitOnAStaleMenuSendsNothing() async throws {
        // Unit level against a bare mock: no pushes, and the action starts before the refresh
        // loop's first tick, so the model still shows the menu the scanner has left.
        let mock = MockSDS200(scenario: .default, options: MockSDS200.Options(clock: .stepped(at: 1)))
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort))
        do {
            try await client.connect()
            try await client.press(.menu)
            let top = try await client.menuScreen()
            try await client.press(.avoid)  // the radio's panel leaves the menu
            let mark = await commandMark(mock)
            let model = MenuModel()
            model.attach(control: { client })
            model.show(.list(top), title: top.title, menuIndex: top.menuIndex)
            let action = Task { try await model.exit() }
            let result = await action.result
            switch result {
            case .success(let content): #expect(content == nil)
            case .failure(let error): Issue.record("exit threw \(error)")
            }
            #expect(model.lastError == nil)
            #expect(model.content == nil, "the read's answer is shown")
            #expect(model.breadcrumb.isEmpty)
            #expect(states(await menuCommands(mock, since: mark)).isEmpty)
            #expect(await mock.control.receivedCommands.dropFirst(mark).contains("GSI"))
            #expect(await !mock.isInMenu)
            model.detach()
            await model.quiesce()
        } catch {
            await client.disconnect()
            await mock.stop()
            throw error
        }
        await client.disconnect()
        await mock.stop()
    }

    @Test func exitWithGSIUnansweredSendsNothing() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Display Options"])
            await rig.mock.setFaults(MockFaults(dropNextRequest: "GSI", dropCount: 1000))
            let mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.exit() } == .noAnswer)
            #expect(menu.lastError == .noAnswer)
            #expect(keys(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await rig.mock.isInMenu)
            #expect(title(menu.content) == "Display Options", "content stays as it was")
            await rig.mock.setFaults(MockFaults())
        }
        #expect(outcome.leaked == [])
    }

    @Test func enterOnAMenuTheModelHasNotSeenSendsNoKey() async throws {
        // Unit level: the scanner is in a menu (the radio's panel) but the model's content is nil.
        // Only enter()'s own GSI read stops its KEY,M,P (which would go up a level).
        let mock = MockSDS200(scenario: .default, options: MockSDS200.Options(clock: .stepped(at: 1)))
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort))
        do {
            try await client.connect()
            try await client.press(.menu)
            try await client.press(.enterYes)  // Set Scan Selection
            let mark = await commandMark(mock)
            let model = MenuModel()
            model.attach(control: { client })
            #expect(model.content == nil)
            let action = Task { try await model.enter() }
            let content = try await action.value
            #expect(title(content) == "Set Scan Selection")
            #expect(states(await menuCommands(mock, since: mark)).isEmpty)
            #expect(await mock.menuPath.count == 2)
            model.detach()
            await model.quiesce()
        } catch {
            await client.disconnect()
            await mock.stop()
            throw error
        }
        await client.disconnect()
        await mock.stop()
    }

    @Test func backCancelsAnEntry() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            guard case .entry = try await open(rig, ["Set Your Location", "Set Range"]) else {
                Issue.record("no entry"); return
            }
            let mark = await commandMark(rig.mock)
            let up = try await menu.back()
            #expect(title(up) == "Set Your Location")
            #expect(menu.breadcrumb == ["Menu", "Set Your Location"])
            #expect(states(await menuCommands(rig.mock, since: mark)) == ["KEY,M,P"])
            #expect(await !rig.mock.menuActions.contains { $0.hasPrefix("set Set Range") })
        }
        #expect(outcome.leaked == [])
    }

    // MARK: Following the radio's own panel

    @Test func panelUseIsFollowed() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            try await waitUntil("a push") { rig.session.info != nil }
            #expect(menu.content == nil)
            try await withPanel(rig) { panel in
                try await panel.press(.menu)
                try await waitUntil("the model follows the panel into the menu", .seconds(3)) { isList(menu.content) }
                #expect(screen(menu.content)?.items.map(\.name) == topItems)
                #expect(menu.breadcrumb == ["Menu"])
                try await panel.press(.scrollRight)
                try await panel.press(.scrollRight)
                try await panel.press(.enterYes)
                try await waitUntil("the model follows the panel to Search for...", .seconds(3)) {
                    title(menu.content) == "Search for..."
                }
                #expect(menu.breadcrumb == ["Menu", "Search for..."])
                try await panel.press(.avoid)
                try await waitUntil("the model follows the panel out", .seconds(3)) { menu.content == nil }
                #expect(menu.breadcrumb.isEmpty)
            }
            // The model only read; every key was the panel's.
            let commands = await menuCommands(rig.mock)
            #expect(msvs(commands).isEmpty)
            #expect(keys(commands) == ["KEY,M,P", "KEY,>,P", "KEY,>,P", "KEY,E,P", "KEY,L,P"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func analyzeIsMirrored() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            try await withPanel(rig) { panel in
                try await panel.press(.menu)
                for _ in 0..<3 { try await panel.press(.scrollRight) }
                try await panel.press(.enterYes)
            }
            #expect(await rig.mock.menuPath.last == "Analyze")
            try await waitUntil("Analyze mirrored", .seconds(3)) { menu.content == .mirrored }
            #expect(menu.breadcrumb.last == "Analyze")
            let mark = await commandMark(rig.mock)
            let content = try await menu.press(.menu)
            #expect(screen(content)?.items.map(\.name) == topItems)
            #expect(isList(menu.content))
            #expect(menu.breadcrumb.last == "Menu")
            #expect(states(await menuCommands(rig.mock, since: mark)) == ["KEY,M,P"])
        }
        #expect(outcome.leaked == [])
    }

    // MARK: Destructive items and the re-check

    @Test func destructiveNeedsConfirmation() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            #expect(menu.isDestructive("Clear User Data"))
            #expect(menu.isDestructive("  delete all channels "))
            #expect(!menu.isDestructive("Display Options"))
            let settings = try #require(screen(try await open(rig, ["Settings"])))
            let item = try #require(settings.items.first { $0.name == "Clear User Data" })
            let actions = await rig.mock.menuActions
            let mark = await commandMark(rig.mock)
            let refused = await menuError { try await menu.choose(item, on: settings) }
            #expect(refused == .needsConfirmation(itemName: "Clear User Data"))
            #expect(menu.lastError == .needsConfirmation(itemName: "Clear User Data"))
            #expect(!menu.isBusy)
            #expect(states(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await rig.mock.menuActions == actions)

            let content = try await menu.choose(item, on: settings, confirmedDestructive: true)
            #expect(title(content) == "Settings")
            #expect(menu.lastError == nil)
            #expect(await rig.mock.menuActions.last == "run Clear User Data")
            #expect(states(await menuCommands(rig.mock, since: mark)) == ["MSV,,0"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func mirroredEnterOnDestructiveRowNeedsConfirmation() async throws {
        // Unit level, no scanner: the highlighted-row rule. `press(.enterYes)` applies it to a
        // fresh STS read inside the action (enterOnAJustMovedHighlightAsksFirst covers that path).
        let lists = try menuDisplay(
            ["Set Scan Selection", "Select Lists to Monitor", "Set All Lists Off", "Set All Lists On"], highlighted: 2)
        #expect(MenuModel.highlightedRowName(lists) == "Set All Lists Off")
        #expect(MenuModel().isDestructive("Set All Lists Off"))
        // An on/off suffix is not part of the name.
        let toggles = try menuDisplay(["Select Lists", "Delete Group              :On "], highlighted: 1)
        #expect(MenuModel.highlightedRowName(toggles) == "Delete Group")
        // A harmless row, an entry's cursor (not a full-row highlight), no highlight, no display.
        let harmless = try menuDisplay(["Settings", "Display Options"], highlighted: 1)
        #expect(MenuModel.highlightedRowName(harmless) == "Display Options")
        #expect(!MenuModel().isDestructive("Display Options"))
        let cursor = try menuDisplay(["Edit Name", "Delete Me"], highlighted: 1, cursorOnly: true, screenKind: "menu_input")
        #expect(MenuModel.highlightedRowName(cursor) == nil)
        #expect(MenuModel.highlightedRowName(try menuDisplay(["Settings", "Display Options"], highlighted: nil)) == nil)
        #expect(MenuModel.highlightedRowName(nil) == nil)

        // Connected to nothing (control is nil): nothing can be read or sent.
        let model = MenuModel()
        model.attach(control: { nil })
        model.show(.mirrored, title: "Set Scan Selection", menuIndex: "4293060001")
        #expect(model.content == .mirrored)
        #expect(await menuError { try await model.press(.enterYes) } == .notConnected)
        #expect(await menuError { try await model.press(.scrollRight) } == .notConnected)
        model.detach()
        #expect(model.content == nil)
        #expect(await menuError { try await model.press(.enterYes) } == .notConnected)
    }

    /// The on/off suffix is no part of a row's name, in either case, on the fresh `STS` that
    /// `press(.enterYes)` checks and on the display model alike.
    @Test func onOffSuffixIsStrippedIgnoringCase() throws {
        for (row, name) in [("Delete Group              :On ", "Delete Group"), ("Delete Group:OFF", "Delete Group"),
                            ("Set All Lists On   :on", "Set All Lists On"), ("Stop All Avoiding :Off", "Stop All Avoiding"),
                            ("Display Options", "Display Options")] {
            let status = try menuStatus(["Select Lists", row], highlighted: 1)
            #expect(MenuModel.highlightedRowName(status) == name, "\(row.debugDescription)")
            #expect(MenuModel.highlightedRowName(try menuDisplay(["Select Lists", row], highlighted: 1)) == name)
        }
        #expect(MenuModel().isDestructive(try #require(MenuModel.highlightedRowName(
            try menuStatus(["Select Lists", "DELETE GROUP :ON"], highlighted: 1)))))
    }

    @Test func confirmedNameIgnoresAnOnOffSuffix() async throws {
        // The confirmed name goes through the same rule as the highlighted row.
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Set Scan Selection"])
            _ = try await menu.press(.scrollRight)  // Set All Lists Off
            let mark = await commandMark(rig.mock)
            _ = try await menu.press(.enterYes, confirmedDestructive: true, confirmedItemName: "Set All Lists Off :ON")
            #expect(await rig.mock.menuActions.last == "run Set All Lists Off")
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,E,P"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func enterOnAJustMovedHighlightAsksFirst() async throws {
        // QA's probe: the session's display is re-read 150 ms after a reply, so right after a
        // scroll it still shows the old highlight. The check must read the screen itself.
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Set Scan Selection"])
            try await waitUntil("the display highlights Select Lists to Monitor", .seconds(3)) {
                MenuModel.highlightedRowName(rig.session.display) == "Select Lists to Monitor"
            }
            let mark = await commandMark(rig.mock)
            _ = try await menu.press(.scrollRight)
            let refused = await menuError { try await menu.press(.enterYes) }
            #expect(refused == .needsConfirmation(itemName: "Set All Lists Off"))
            #expect(await !rig.mock.menuActions.contains("run Set All Lists Off"))
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,>,P"])
            _ = try await menu.press(.enterYes, confirmedDestructive: true, confirmedItemName: "Set All Lists Off")
            #expect(await rig.mock.menuActions.last == "run Set All Lists Off")
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,>,P", "KEY,E,P"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func confirmedEnterRunsTheConfirmedRow() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Set Scan Selection"])
            _ = try await menu.press(.scrollRight)
            let mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.press(.enterYes) } == .needsConfirmation(itemName: "Set All Lists Off"))
            // Matched trimmed and ignoring case, like the destructive check.
            _ = try await menu.press(.enterYes, confirmedDestructive: true, confirmedItemName: "  set all lists OFF ")
            #expect(await rig.mock.menuActions.last == "run Set All Lists Off")
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,E,P"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func confirmedEnterOnAMovedHighlightIsMenuChanged() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Set Scan Selection"])
            _ = try await menu.press(.scrollRight)
            let refused = await menuError { try await menu.press(.enterYes) }
            #expect(refused == .needsConfirmation(itemName: "Set All Lists Off"))
            // While the confirmation shows, the radio's panel moves to another destructive row.
            try await withPanel(rig) { panel in try await panel.press(.scrollRight) }
            let actions = await rig.mock.menuActions
            let mark = await commandMark(rig.mock)
            let error = await menuError {
                try await menu.press(.enterYes, confirmedDestructive: true, confirmedItemName: "Set All Lists Off")
            }
            #expect(error == .menuChanged)
            #expect(menu.lastError == .menuChanged)
            #expect(keys(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await rig.mock.menuActions == actions)
            #expect(title(menu.content) == "Set Scan Selection", "content re-read")
        }
        #expect(outcome.leaked == [])
    }

    @Test func confirmedEnterWithoutANameIsMenuChanged() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Set Scan Selection"])
            _ = try await menu.press(.scrollRight)
            let actions = await rig.mock.menuActions
            let mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.press(.enterYes, confirmedDestructive: true) } == .menuChanged)
            #expect(keys(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await rig.mock.menuActions == actions)
        }
        #expect(outcome.leaked == [])
    }

    @Test func confirmFlagsDontBlockAHarmlessRow() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Set Scan Selection"])
            let mark = await commandMark(rig.mock)
            // Select Lists to Monitor is highlighted: not destructive, so the key goes whatever the flags.
            let content = try await menu.press(.enterYes, confirmedDestructive: true, confirmedItemName: "Something Else")
            #expect(title(content) == "Select Lists to Monitor")
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,E,P"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func unansweredSTSBeforeEnterSendsNothing() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Set Scan Selection"])
            _ = try await menu.press(.scrollRight)  // Set All Lists Off
            // The session's display loop reads STS too: a large count covers it.
            await rig.mock.setFaults(MockFaults(dropNextRequest: "STS", dropCount: 1000))
            let mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.press(.enterYes) } == .noAnswer)
            #expect(keys(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await !rig.mock.menuActions.contains("run Set All Lists Off"))
            await rig.mock.setFaults(MockFaults())
        }
        #expect(outcome.leaked == [])
    }

    @Test func enterOnAHarmlessRowSendsOneKey() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Set Scan Selection"])
            let mark = await commandMark(rig.mock)
            let content = try await menu.press(.enterYes)  // Select Lists to Monitor
            #expect(title(content) == "Select Lists to Monitor")
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,E,P"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func confirmAfterMenuChangedSendsNothing() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let settings = try #require(screen(try await open(rig, ["Settings"])))
            let item = try #require(settings.items.first { $0.name == "Clear User Data" })
            try await withPanel(rig) { panel in try await panel.press(.menu) }
            #expect(await rig.mock.menuPath.count == 1)
            let mark = await commandMark(rig.mock)
            let refused = await menuError { try await menu.choose(item, on: settings, confirmedDestructive: true) }
            #expect(refused == .menuChanged)
            #expect(menu.lastError == .menuChanged)
            #expect(states(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await !rig.mock.menuActions.contains("run Clear User Data"))
            #expect(screen(menu.content)?.items.map(\.name) == topItems, "content shows what was read")
            #expect(menu.breadcrumb == ["Menu"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func sameIndexDifferentNameIsMenuChanged() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let display = try #require(screen(try await open(rig, ["Display Options"])))
            let displayItem = try #require(display.items.first)
            #expect(displayItem.index == 0)
            _ = try await menu.back()
            let settings = try #require(screen(try await open(rig, ["Settings"])))
            #expect(settings.items.first?.index == 0)
            #expect(settings.menuIndex != display.menuIndex)
            let actions = await rig.mock.menuActions
            let mark = await commandMark(rig.mock)
            // Display Options' item 0 while the scanner shows Settings (whose item 0 is another item).
            #expect(await menuError { try await menu.choose(displayItem, on: display) } == .menuChanged)
            // Settings' own menu index and item index, but another name.
            var forged = settings
            let impostor = MenuScreen.Item(index: 0, name: "Set ID Format (P25/Mot)")
            forged.items = [impostor]
            #expect(await menuError { try await menu.choose(impostor, on: forged) } == .menuChanged)
            // An index the screen doesn't have.
            let missing = MenuScreen.Item(index: 7, name: "Clear User Data")
            #expect(await menuError { try await menu.choose(missing, on: settings, confirmedDestructive: true) } == .menuChanged)
            #expect(states(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await rig.mock.menuActions == actions)
            #expect(title(menu.content) == "Settings")
        }
        #expect(outcome.leaked == [])
    }

    @Test func recheckRequiresTheScreenKind() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            guard case .entry(let entry) = try await open(rig, ["Set Your Location", "Set Range"]) else {
                Issue.record("no entry"); return
            }
            let location = try #require(screen(try await menu.back()))
            #expect(location.title == "Set Your Location")
            let actions = await rig.mock.menuActions
            let mark = await commandMark(rig.mock)
            // The list's own menu index, but an entry screen: the scanner shows a list.
            var forgedEntry = entry
            forgedEntry.menuIndex = location.menuIndex
            #expect(await menuError { try await menu.setValue("1", on: forgedEntry) } == .menuChanged)
            guard case .entry = try await menu.choose(try #require(location.items.first), on: location) else {
                Issue.record("no entry"); return
            }
            let mark2 = await commandMark(rig.mock)
            // The entry's own menu index and an item 0, but a list: the scanner shows an entry.
            var forgedList = location
            forgedList.menuIndex = entry.menuIndex
            let item = try #require(location.items.first)
            #expect(await menuError { try await menu.choose(item, on: forgedList) } == .menuChanged)
            #expect(states(await menuCommands(rig.mock, since: mark)) == ["MSV,,0"], "only the real choose")
            #expect(states(await menuCommands(rig.mock, since: mark2)).isEmpty)
            #expect(await rig.mock.menuActions == actions)
            #expect(await rig.mock.menuPath.last == "Set Range")
        }
        #expect(outcome.leaked == [])
    }

    @Test func recheckComparesTheMenuIndex() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let custom3 = try #require(screen(try await open(rig, ["Search for...", "Edit Custom", "Custom 3"])))
            let editName = try #require(custom3.items.first)
            #expect(editName.index == 0 && editName.name == "Edit Name")
            let select = try #require(screen(try await menu.back()))
            let custom4Item = try #require(select.items.first { $0.name == "Custom 4" })
            let custom4 = try #require(screen(try await menu.choose(custom4Item, on: select)))
            // Same title shape, same item index and name: only the menu index tells them apart.
            #expect(custom4.items.first == editName)
            #expect(custom4.menuIndex != custom3.menuIndex)
            let mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.choose(editName, on: custom3) } == .menuChanged)
            #expect(states(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await rig.mock.menuPath.last == "Custom 4")
        }
        #expect(outcome.leaked == [])
    }

    @Test func enterWhenAlreadyInAMenuSendsNoKey() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Display Options"])
            let mark = await commandMark(rig.mock)
            let content = try await menu.enter()
            #expect(title(content) == "Display Options")
            #expect(menu.breadcrumb == ["Menu", "Display Options"])
            #expect(states(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await rig.mock.menuPath.count == 2)
        }
        #expect(outcome.leaked == [])
    }

    // MARK: Busy, lost commands, rejections

    @Test func lostKeyIsNotResent() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Display Options"])
            await rig.mock.setFaults(MockFaults(dropNextReply: "KEY"))
            var mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.back() } == .noAnswer)
            #expect(screen(menu.content)?.items.map(\.name) == topItems, "the re-read saw the key take effect")
            try await Task.sleep(for: .milliseconds(2500))
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,M,P"], "never resent")

            await rig.mock.setFaults(MockFaults(dropNextRequest: "KEY"))
            mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.press(.enterYes) } == .noAnswer)
            #expect(await rig.mock.menuPath.count == 1, "the lost key did nothing")
            try await Task.sleep(for: .milliseconds(2500))
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,E,P"], "never resent")
        }
        #expect(outcome.leaked == [])
    }

    @Test func busyDuringTheReread() async throws {
        var setup = Setup()
        setup.replyDelays = ["MSI": .milliseconds(400)]
        let outcome = try await withSession(setup) { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let top = try #require(screen(try await menu.enter()))
            let item = try #require(top.items.first { $0.name == "Display Options" })
            let mark = await commandMark(rig.mock)
            let first = Task { try await menu.choose(item, on: top) }
            try await waitUntil("MSV sent", .seconds(5)) { await rig.commands.contains("MSV,,4") }
            try await waitUntil("the re-read's MSI sent", .seconds(5)) {
                let since = await menuCommands(rig.mock, since: mark)
                return since.lastIndex(of: "MSI").map { $0 > (since.firstIndex(of: "MSV,,4") ?? Int.max) } ?? false
            }
            #expect(menu.isBusy)
            #expect(await menuError { try await menu.choose(item, on: top) } == .busy)
            #expect(await menuError { try await menu.back() } == .busy)
            #expect(title(try await first.value) == "Display Options")
            #expect(states(await menuCommands(rig.mock, since: mark)) == ["MSV,,4"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func secondActionWhileBusySendsNothing() async throws {
        var setup = Setup()
        setup.replyDelays = ["MSV": .milliseconds(300)]
        let outcome = try await withSession(setup) { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let top = try #require(screen(try await menu.enter()))
            let item = try #require(top.items.first { $0.name == "Display Options" })
            let mark = await commandMark(rig.mock)
            let first = Task { try await menu.choose(item, on: top) }
            try await waitUntil("busy", .seconds(2)) { menu.isBusy }
            #expect(await menuError { try await menu.choose(item, on: top) } == .busy)
            #expect(await menuError { try await menu.back() } == .busy)
            #expect(await menuError { try await menu.exit() } == .busy)
            #expect(await menuError { try await menu.press(.enterYes) } == .busy)
            #expect(await menuError { try await menu.refresh() } == .busy)
            let content = try await first.value
            #expect(title(content) == "Display Options")
            #expect(!menu.isBusy)
            #expect(menu.lastError == nil, "a refusal for busy doesn't overwrite the running action's outcome")
            #expect(states(await menuCommands(rig.mock, since: mark)) == ["MSV,,4"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func lostReplyIsNotResent() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let lists = try #require(screen(try await open(rig, ["Set Scan Selection", "Select Lists to Monitor"])))
            let transit = try #require(lists.items.first { $0.name == "Transit" })
            #expect(transit.value == "On")
            await rig.mock.setFaults(MockFaults(dropNextReply: "MSV"))
            let mark = await commandMark(rig.mock)
            let sent = ContinuousClock.now
            #expect(await menuError { try await menu.choose(transit, on: lists) } == .noAnswer)
            #expect(menu.lastError == .noAnswer)
            #expect(rig.session.lastKeyReply.map { $0 > sent } == true, "the display is told to re-read")
            #expect(!menu.isBusy)
            #expect(await rig.mock.menuActions.last == "toggle Transit Off")
            guard case .list(let after) = menu.content else {
                Issue.record("not a list: \(String(describing: menu.content))"); return
            }
            #expect(after.items.first { $0.name == "Transit" }?.value == "Off", "the re-read saw the toggle")
            try await Task.sleep(for: .milliseconds(2500))
            #expect(msvs(await menuCommands(rig.mock, since: mark)) == ["MSV,,5"], "never resent")
        }
        #expect(outcome.leaked == [])
    }

    @Test func lostRequestIsNotResent() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let lists = try #require(screen(try await open(rig, ["Set Scan Selection", "Select Lists to Monitor"])))
            let transit = try #require(lists.items.first { $0.name == "Transit" })
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MSV"))
            let mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.choose(transit, on: lists) } == .noAnswer)
            #expect(await !rig.mock.menuActions.contains { $0.hasPrefix("toggle Transit") })
            guard case .list(let after) = menu.content else {
                Issue.record("not a list: \(String(describing: menu.content))"); return
            }
            #expect(after.items.first { $0.name == "Transit" }?.value == "On")
            try await Task.sleep(for: .milliseconds(2500))
            #expect(msvs(await menuCommands(rig.mock, since: mark)) == ["MSV,,5"], "never resent")
        }
        #expect(outcome.leaked == [])
    }

    @Test func rejectedValueSurfaces() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            guard case .entry(let entry) = try await open(rig, ["Set Your Location", "Set Range"]) else {
                Issue.record("no entry"); return
            }
            await rig.mock.setFaults(MockFaults(rejectNext: "MSV"))
            let mark = await commandMark(rig.mock)
            let sent = ContinuousClock.now
            let error = await menuError { try await menu.setValue("31.0", on: entry) }
            #expect(rig.session.lastKeyReply.map { $0 > sent } == true, "the display is told to re-read")
            guard case .rejected = error else {
                Issue.record("not rejected: \(String(describing: error))"); return
            }
            #expect(menu.lastError == error)
            #expect(states(await menuCommands(rig.mock, since: mark)) == ["MSV,,31.0"])
            guard case .entry(let reread) = menu.content else {
                Issue.record("not an entry: \(String(describing: menu.content))"); return
            }
            #expect(reread.value == "30.0")
            #expect(await !rig.mock.menuActions.contains { $0.hasPrefix("set Set Range") })
        }
        #expect(outcome.leaked == [])
    }

    @Test func forgedRulesCannotSendAnOverlongValue() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            guard case .entry(let entry) = try await open(rig, ["Set Your Location", "Set Range"]) else {
                Issue.record("no entry"); return
            }
            // Rules looser than the scanner's (MaxLength 5): the re-read screen's rules decide.
            var loose = entry
            loose.input?.maxLength = 10
            let mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.setValue("12.5.5.5", on: loose) } == .invalidValue)
            #expect(menu.lastError == .invalidValue)
            #expect(msvs(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await !rig.mock.menuActions.contains { $0.hasPrefix("set Set Range") })
            guard case .entry(let shown) = menu.content else {
                Issue.record("not an entry: \(String(describing: menu.content))"); return
            }
            #expect(shown.input?.maxLength == 5, "content shows what was read")
        }
        #expect(outcome.leaked == [])
    }

    // MARK: The entry's value is part of the re-check (final review M3)

    @Test func setValueOnAnEntryWhoseValueChangedIsMenuChanged() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            guard case .entry(let held) = try await open(rig, ["Search for...", "Edit Custom", "Custom 3", "Edit Name"]) else {
                Issue.record("no entry"); return
            }
            #expect(held.value == "Custom 3")
            // The radio's panel saves another name, then opens Edit Name again: the same screen
            // (menu index, kind), another value.
            try await withPanel(rig) { panel in
                try await panel.setMenuValue("Night Ops")
                try await panel.press(.enterYes)
            }
            #expect(await rig.mock.menuPath.last == "Edit Name")
            let actions = await rig.mock.menuActions
            let mark = await commandMark(rig.mock)
            #expect(await menuError { try await menu.setValue("Day Ops", on: held) } == .menuChanged)
            #expect(msvs(await menuCommands(rig.mock, since: mark)).isEmpty)
            #expect(await rig.mock.menuActions == actions)
            guard case .entry(let shown) = menu.content else {
                Issue.record("not an entry: \(String(describing: menu.content))"); return
            }
            #expect(shown.value == "Night Ops", "content shows what was read")
            #expect(shown.menuIndex == held.menuIndex)

            // A held copy with a stale value, against an unchanged scanner: the same.
            var stale = shown
            stale.value = "Custom 3"
            #expect(await menuError { try await menu.setValue("Day Ops", on: stale) } == .menuChanged)
            #expect(msvs(await menuCommands(rig.mock, since: mark)).isEmpty)
            // The screen as read: sent.
            _ = try await menu.setValue("Day Ops", on: shown)
            #expect(msvs(await menuCommands(rig.mock, since: mark)) == ["MSV,,Day Ops"])
        }
        #expect(outcome.leaked == [])
    }

    // MARK: An entry needs both rules (final review M4)

    @Test func anEntryNeedsMaxLengthAndEnableKeys() throws {
        func input(_ rules: String) throws -> MenuScreen {
            try parsedScreen("""
                <MSI Name="Edit Name" Index="4293060020" MenuType="TypeInput" Value="Custom 3" >
                \(rules)
                <Footer No="1" EOT="1"/>
                </MSI>
                """)
        }
        let both = try input(#"<MenuInput MaxLength="64" EnableKeys="ABCabc123 " />"#)
        #expect(MenuModel.content(for: both) == .entry(both))
        // Unverified shapes (design §4.6): the mirrored text, where each action is one key.
        let none = try input("")
        #expect(none.kind == .input && none.input == nil)
        #expect(MenuModel.content(for: none) == .mirrored)
        let lengthOnly = try input(#"<MenuInput MaxLength="64" />"#)
        #expect(lengthOnly.input?.maxLength == 64 && lengthOnly.input?.allowedCharacters == nil)
        #expect(MenuModel.content(for: lengthOnly) == .mirrored)
        let keysOnly = try input(#"<MenuInput EnableKeys="0123456789." />"#)
        #expect(keysOnly.input?.maxLength == nil && keysOnly.input?.allowedCharacters != nil)
        #expect(MenuModel.content(for: keysOnly) == .mirrored)
        #expect(MenuModel.content(for: nil) == .mirrored)
    }

    @Test func setValueRefusesInvalidText() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            guard case .entry(let entry) = try await open(rig, ["Set Your Location", "Set Range"]) else {
                Issue.record("no entry"); return
            }
            // Let a stale push's read (if any) go by first: from here the model must send nothing.
            try await Task.sleep(for: .milliseconds(600))
            let mark = await commandMark(rig.mock)
            for text in ["", "123456", "12a", "1,2", "1\n2", "1\r"] {
                #expect(await menuError { try await menu.setValue(text, on: entry) } == .invalidValue, "\(text.debugDescription)")
                #expect(menu.lastError == .invalidValue)
            }
            // Nothing at all from the model (STS is the session's display loop, not the model's).
            let since = Array(await rig.commands.dropFirst(mark)).filter { $0.uppercased() != "STS" }
            #expect(since.isEmpty, "\(since)")
            #expect(await !rig.mock.menuActions.contains { $0.hasPrefix("set Set Range") })
            #expect(await rig.mock.menuPath.last == "Set Range")
        }
        #expect(outcome.leaked == [])
    }

    /// Final review I3: a value the client refuses before sending (`ScannerCommand`'s comma, CR or
    /// LF rule, or the client's own) is `.invalidValue`: nothing went out, so no display nudge and
    /// no re-read. Unreachable through `setValue`, whose validation comes first; the mapping itself.
    @Test func aRefusalBeforeSendingIsInvalidValue() {
        #expect(MenuModel.commandReply(to: ScannerCommandError.invalidArgument("a\r\nb")) == .refused)
        #expect(MenuModel.commandReply(to: ScannerClientError.invalidArgument("a,b")) == .refused)
        #expect(MenuModel.commandReply(to: ScannerClientError.rejected(command: "MSV", response: "MSV,NG")) == .rejected("MSV,NG"))
        #expect(MenuModel.commandReply(to: ScannerClientError.unexpectedResponse(command: "MSV"))
                == .rejected("unexpected reply to MSV"))
        #expect(MenuModel.commandReply(to: ScannerClientError.timeout(command: "MSV")) == .unanswered)
        #expect(MenuModel.commandReply(to: ScannerClientError.notConnected) == .gone)
        #expect(MenuModel.commandReply(to: CancellationError()) == .unanswered, "whether it went out is unknown")
    }

    // MARK: Reads

    @Test func msiUnansweredFallsBackToMirrored() async throws {
        // A new screen (out of the menu, into it) with no list or entry read for it yet: mirrored.
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MSI", dropCount: 2))
            let mark = await commandMark(rig.mock)
            let content = try await menu.enter()
            #expect(content == .mirrored)
            #expect(menu.content == .mirrored)
            #expect(menu.breadcrumb == ["Menu"])
            #expect(await menuCommands(rig.mock, since: mark) == ["KEY,M,P", "MSI", "MSI"], "two tries")
            let again = try await menu.refresh()
            #expect(screen(again)?.items.map(\.name) == topItems)
            #expect(isList(menu.content))
        }
        #expect(outcome.leaked == [])
    }

    // MARK: An unanswered MSI on the same screen keeps the content (final review I4)

    @Test func heldListKeepsItsContentWhenMSIGoesUnanswered() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let lists = try await open(rig, ["Set Scan Selection", "Select Lists to Monitor"])
            #expect(isList(lists))
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MSI", dropCount: 1000))
            let mark = await commandMark(rig.mock)
            #expect(try await menu.refresh() == lists)
            #expect(menu.content == lists)
            #expect(!menu.isScannerAnswering)
            #expect(menu.breadcrumb == ["Menu", "Set Scan Selection", "Select Lists to Monitor"])
            #expect(states(await menuCommands(rig.mock, since: mark)).isEmpty)
            // The refresh loop's reads go unanswered too: still the list.
            try await Task.sleep(for: .milliseconds(2500))
            #expect(menu.content == lists)
            await rig.mock.setFaults(MockFaults())
            try await waitUntil("the refresh loop recovers", .seconds(8)) { menu.isScannerAnswering }
            #expect(menu.content == lists)
        }
        #expect(outcome.leaked == [])
    }

    @Test func heldEntryKeepsItsContentWhenABackgroundMSIGoesUnanswered() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let entry = try await open(rig, ["Search for...", "Edit Custom", "Custom 3", "Edit Name"])
            guard case .entry = entry else {
                Issue.record("not an entry: \(String(describing: entry))"); return
            }
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MSI", dropCount: 1000))
            let mark = await commandMark(rig.mock)
            try await waitUntil("a background read goes unanswered", .seconds(10)) { !menu.isScannerAnswering }
            #expect(menu.content == entry, "the entry stays")
            #expect(menu.lastError == nil, "a background read records no error")
            await rig.mock.setFaults(MockFaults())
            try await waitUntil("the refresh loop recovers", .seconds(8)) { menu.isScannerAnswering }
            #expect(menu.content == entry)
            #expect(states(await menuCommands(rig.mock, since: mark)).isEmpty)
        }
        #expect(outcome.leaked == [])
    }

    @Test func anActionsUnansweredRereadOnTheSameScreenKeepsTheContent() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let lists = try await open(rig, ["Set Scan Selection", "Select Lists to Monitor"])
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MSI", dropCount: 1000))
            let mark = await commandMark(rig.mock)
            // A scroll keeps the screen (GSI's title, index and kind): its re-read's MSI goes unanswered.
            #expect(await menuError { try await menu.press(.scrollRight) } == .noAnswer)
            #expect(menu.content == lists, "the list stays")
            #expect(!menu.isScannerAnswering)
            #expect(keys(await menuCommands(rig.mock, since: mark)) == ["KEY,>,P"])
            // Back changes the screen: with no list read for it, mirrored.
            #expect(try await menu.back() == .mirrored)
            #expect(menu.content == .mirrored)
            #expect(menu.breadcrumb == ["Menu", "Set Scan Selection"])
            await rig.mock.setFaults(MockFaults())
            #expect(title(try await menu.refresh()) == "Set Scan Selection")
            #expect(menu.isScannerAnswering)
        }
        #expect(outcome.leaked == [])
    }

    @Test func aGarbledMSIOnTheSameScreenIsMirrored() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Display Options"])
            _ = try await menu.refresh()  // the refresh loop now rests 2 s, so it can't take the faults
            // Answered, but not with a screen (MSI,NG on both tries): the scanner can't describe it.
            await rig.mock.setFaults(MockFaults(dropCount: 2, rejectNext: "MSI"))
            #expect(try await menu.refresh() == .mirrored)
            #expect(menu.content == .mirrored)
            await rig.mock.setFaults(MockFaults())
            #expect(title(try await menu.refresh()) == "Display Options")
        }
        #expect(outcome.leaked == [])
    }

    @Test func idleRefreshSendsReadsOnly() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            _ = try await rig.session.menu.enter()
            let mark = await commandMark(rig.mock)
            try await Task.sleep(for: .milliseconds(4500))
            let commands = await menuCommands(rig.mock, since: mark)
            #expect(states(commands).isEmpty, "\(commands)")
            #expect(commands.count >= 1 && commands.count <= 4, "an MSI about every 2 s: \(commands)")
        }
        #expect(outcome.leaked == [])
    }

    @Test func scannerNotAnsweringIsReported() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            #expect(menu.isScannerAnswering)
            let top = try await menu.enter()
            #expect(menu.isScannerAnswering)
            await rig.mock.setFaults(MockFaults(dropNextRequest: "GSI", dropCount: 1000))
            #expect(await menuError { try await menu.refresh() } == .noAnswer)
            #expect(!menu.isScannerAnswering)
            #expect(menu.content == top, "content stays as it was")
            await rig.mock.setFaults(MockFaults())
            try await waitUntil("the refresh loop finds the scanner again", .seconds(6)) { menu.isScannerAnswering }

            // The same screen (GSI says so) with MSI unanswered: the list stays (final review I4).
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MSI", dropCount: 1000))
            #expect(try await menu.refresh() == top)
            #expect(menu.content == top)
            #expect(!menu.isScannerAnswering)
            await rig.mock.setFaults(MockFaults())
            #expect(try await menu.refresh() == top)
            #expect(menu.isScannerAnswering)
        }
        #expect(outcome.leaked == [])
    }

    // MARK: Decided at the slot

    @Test func aKeyHeldAtTheSlotIsSentOnce() async throws {
        let (result, commands) = try await menuActionHeldAtTheSlot(at: { client in
            try await client.press(.menu)
            try await client.press(.enterYes)  // Set Scan Selection
            return try await client.menuScreen()
        }, { model, _ in try await model.back() }, whileWaiting: { _ in })
        #expect(states(commands) == ["KEY,M,P"], "\(commands)")
        if case .failure(let error) = result { Issue.record("the action failed: \(error)") }
    }

    @Test func detachWhileAKeyWaitsForTheSlotSendsNoKey() async throws {
        let (result, commands) = try await menuActionHeldAtTheSlot(at: { client in
            try await client.press(.menu)
            try await client.press(.enterYes)  // Set Scan Selection
            return try await client.menuScreen()
        }, { model, _ in try await model.back() }, whileWaiting: { $0.detach() })
        #expect(states(commands).isEmpty, "\(commands)")
        if case .failure(let error) = result {
            #expect(error as? MenuActionError == .notConnected)
        } else {
            Issue.record("the action returned")
        }
    }

    @Test func detachWhileAnMSVWaitsForTheSlotSendsNoMSV() async throws {
        // `choose` re-reads MSI first (one control call), then its MSV queues behind the held GSI.
        let (result, commands) = try await menuActionHeldAtTheSlot(checkReads: 1, at: { client in
            try await client.press(.menu)
            return try await client.menuScreen()
        }, { model, top in
            let item = try #require(top.items.first { $0.name == "Display Options" })
            return try await model.choose(item, on: top)
        }, whileWaiting: { $0.detach() })
        #expect(commands.first == "MSI", "the re-check ran: \(commands)")
        #expect(states(commands).isEmpty, "\(commands)")
        if case .failure(let error) = result {
            #expect(error as? MenuActionError == .notConnected)
        } else {
            Issue.record("the action returned")
        }
    }

    @Test func detachDuringTheRecheckSendsNothing() async throws {
        // Unit level against a bare mock: the control never returns nil (as between detach() and
        // the runner's stop), so only the model's own generation check stands in the way.
        let options = MockSDS200.Options(clock: .stepped(at: 1), replyDelays: ["MSI": .milliseconds(400)])
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort))
        do {
            try await client.connect()
            try await client.press(.menu)
            let top = try await client.menuScreen()
            let item = try #require(top.items.first { $0.name == "Display Options" })
            let mark = await commandMark(mock)
            // Attach and start the action in one main-actor turn: the refresh loop's first tick
            // (100 ms) then finds the model busy, so the only MSI is the action's re-check.
            let model = MenuModel()
            model.attach(control: { client })
            model.show(.list(top), title: top.title, menuIndex: top.menuIndex)
            let action = Task { try await model.choose(item, on: top) }
            try await waitUntil("the re-check's MSI sent", .seconds(3)) {
                await menuCommands(mock, since: mark).contains("MSI") && model.isBusy
            }
            model.detach()
            let result = await action.result
            if case .failure(let error) = result {
                #expect(error as? MenuActionError == .notConnected)
            } else {
                Issue.record("the action returned")
            }
            try await Task.sleep(for: .milliseconds(800))
            #expect(states(await menuCommands(mock, since: mark)).isEmpty)
            #expect(await mock.menuPath.count == 1)
            await model.quiesce()
        } catch {
            await client.disconnect()
            await mock.stop()
            throw error
        }
        await client.disconnect()
        await mock.stop()
    }

    @Test func detachDuringTheControlHopSendsNoKey() async throws {
        // Unit level against a bare mock. A KEY action has no read before its command, so the
        // re-check in client(_:) after the (slow) control hop is all that stands after detach().
        let mock = MockSDS200(scenario: .default, options: MockSDS200.Options(clock: .stepped(at: 1)))
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort))
        do {
            try await client.connect()
            try await client.press(.menu)
            try await client.press(.enterYes)  // Set Scan Selection
            let screen = try await client.menuScreen()
            let mark = await commandMark(mock)
            let model = MenuModel()
            model.attach(control: {
                try? await Task.sleep(for: .milliseconds(400))
                return client
            })
            model.show(.list(screen), title: screen.title, menuIndex: screen.menuIndex)
            let action = Task { try await model.back() }
            try await Task.sleep(for: .milliseconds(150))
            #expect(model.isBusy)
            model.detach()
            let result = await action.result
            if case .failure(let error) = result {
                #expect(error as? MenuActionError == .notConnected)
            } else {
                Issue.record("the action returned")
            }
            try await Task.sleep(for: .milliseconds(800))
            #expect(states(await menuCommands(mock, since: mark)).isEmpty)
            #expect(await mock.menuPath.count == 2)
            await model.quiesce()
        } catch {
            await client.disconnect()
            await mock.stop()
            throw error
        }
        await client.disconnect()
        await mock.stop()
    }

    // MARK: Lifecycle
    // MARK: Lifecycle

    @Test func stopDuringMenuSendsNothingAfter() async throws {
        var setup = Setup()
        setup.replyDelays = ["MSV": .milliseconds(300)]
        let outcome = try await withSession(setup) { rig in
            try await connect(rig)
            let menu = rig.session.menu
            let top = try #require(screen(try await menu.enter()))
            let item = try #require(top.items.first { $0.name == "Display Options" })
            let action = Task { try await menu.choose(item, on: top) }
            try await waitUntil("MSV sent", .seconds(3)) { await rig.commands.contains("MSV,,4") }
            let mark = await commandMark(rig.mock)
            try await rig.stopSession()
            let result = await action.result
            switch result {
            case .success(let content): Issue.record("the action returned \(String(describing: content))")
            case .failure(let error): #expect(error as? MenuActionError == .notConnected)
            }
            #expect(menu.content == nil)
            #expect(menu.breadcrumb.isEmpty)
            #expect(!menu.isBusy)
            let after = Array(await rig.commands.dropFirst(mark))
            #expect(after.contains("PSI,0"))
            #expect(states(after).isEmpty, "nothing that changes state once the stop began: \(after)")
            #expect(await rig.mock.isInMenu, "stopping leaves the scanner in its menu (no Avoid)")
            #expect(await menuError { try await menu.back() } == .notConnected)
            #expect(await menuError { try await menu.enter() } == .notConnected)
            #expect(states(Array(await rig.commands.dropFirst(mark))).isEmpty)
        }
        #expect(outcome.leaked == [])
    }

    @Test func suspendClearsTheMenu() async throws {
        let outcome = try await withSession { rig in
            try await connect(rig)
            let menu = rig.session.menu
            _ = try await open(rig, ["Display Options"])
            #expect(menu.breadcrumb.count == 2)
            await rig.session.suspend()
            #expect(menu.content == nil)
            #expect(menu.breadcrumb.isEmpty)
            #expect(await menuError { try await menu.exit() } == .notConnected)
            #expect(await rig.mock.isInMenu)
        }
        #expect(outcome.leaked == [])
    }

    @Test func notConnectedAndNotInMenuErrors() async throws {
        let outcome = try await withSession { rig in
            let menu = rig.session.menu
            let screen = try parsedScreen("""
                <MSI Name="Settings" Index="4293060020" MenuType="TypeSelect" Selected="0" >
                <MenuItem Name="Night Mode" Index="0" />
                <Footer No="1" EOT="1"/>
                </MSI>
                """)
            let item = try #require(screen.items.first)
            #expect(await menuError { try await menu.enter() } == .notConnected)
            #expect(menu.lastError == .notConnected)
            #expect(await menuError { try await menu.refresh() } == .notConnected)
            #expect(await menuError { try await menu.back() } == .notConnected)
            #expect(await menuError { try await menu.choose(item, on: screen) } == .notConnected)
            #expect(await rig.commands.isEmpty)

            try await connect(rig)
            #expect(await menuError { try await menu.back() } == .notInMenu)
            #expect(await menuError { try await menu.exit() } == .notInMenu)
            #expect(await menuError { try await menu.press(.enterYes) } == .notInMenu)
            #expect(await menuError { try await menu.choose(item, on: screen) } == .notInMenu)
            #expect(await menuError { try await menu.setValue("1", on: screen) } == .notInMenu)
            #expect(menu.lastError == .notInMenu)
            #expect(try await menu.refresh() == nil, "refresh reads, in a menu or not")
            #expect(states(await menuCommands(rig.mock)).isEmpty)
            #expect(await !rig.mock.isInMenu)

            try await rig.stopSession()
            #expect(await menuError { try await menu.enter() } == .notConnected)
            #expect(states(await menuCommands(rig.mock)).isEmpty)
        }
        #expect(outcome.leaked == [])
    }
}

// MARK: - BCD436HP menus (Plan 23, Task 6)

/// A `MenuModel` attached to a client on a serial mock of `personality`, with the navigation and
/// destructive items that model's profile gives. Stops everything on every path.
@MainActor
private func withMenuModel(
    personality: MockPersonality, model: ScannerModel,
    control: @escaping @Sendable (ScannerClient, MockSerialScanner) async -> Void = { _, _ in },
    commandTimeout: Duration = .seconds(2),
    _ body: (MenuModel, ScannerClient, MockSerialScanner) async throws -> Void
) async throws {
    let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 3), personality: personality)
    var failure: (any Error)?
    var client: ScannerClient?
    var menu: MenuModel?
    do {
        let path = try await mock.start()
        let connected = ScannerClient(transport: SerialTransport(path: path), commandTimeout: commandTimeout)
        client = connected
        try await connected.connect()
        let profile = ModelProfile.profile(for: model)
        let made = MenuModel(destructiveItems: profile.destructiveMenuItems)
        made.navigation = profile.menuNavigation
        menu = made
        made.attach(control: {
            await control(connected, mock)
            return connected
        })
        try await body(made, connected, mock)
    } catch { failure = error }
    menu?.detach()
    await menu?.quiesce()
    await client?.disconnect()
    await mock.stop()
    if let failure { throw failure }
}

private func navCommands(_ commands: [String]) -> [String] {
    commands.filter { ["MNU", "MSB"].contains(String($0.prefix(3))) || $0.hasPrefix("KEY,M") || $0.hasPrefix("KEY,L") }
}

@MainActor
@Suite("BCD436HP menus", .serialized, .timeLimit(.minutes(2))) struct BCDMenuModelTests {
    @Test func enterSendsMNUTopOnlyOutsideAMenu() async throws {
        try await withMenuModel(personality: .bcd436hp, model: .bcd436hp) { menu, _, mock in
            _ = try await menu.enter()
            #expect(await mock.isInMenu)
            #expect(menu.isInMenu)
            let log = await mock.receivedCommands
            #expect(navCommands(log) == ["MNU,TOP,"])
            let mnu = try #require(log.firstIndex(of: "MNU,TOP,"))
            #expect(log[..<mnu].contains("GSI"), "GSI first: \(log)")
            _ = try await menu.enter()
            #expect(navCommands(await mock.receivedCommands) == ["MNU,TOP,"], "already in a menu: no second MNU")
        }
    }

    @Test func backSendsMSB() async throws {
        try await withMenuModel(personality: .bcd436hp, model: .bcd436hp) { menu, client, mock in
            try await client.openMenu()
            _ = try await menu.refresh()
            _ = try await menu.back()
            let nav = navCommands(await mock.receivedCommands)
            #expect(nav == ["MNU,TOP,", "MSB,,"])
        }
    }

    @Test func exitSendsMSBReturnOnlyInAMenu() async throws {
        try await withMenuModel(personality: .bcd436hp, model: .bcd436hp) { menu, _, mock in
            _ = try await menu.enter()
            let mark = await mock.receivedCommands.count
            _ = try await menu.exit()
            let after = Array(await mock.receivedCommands.dropFirst(mark))
            #expect(navCommands(after) == ["MSB,,RETURN_PREVOUS_MODE"])
            let msb = try #require(after.firstIndex(of: "MSB,,RETURN_PREVOUS_MODE"))
            #expect(after[..<msb].contains("GSI"))
            #expect(!(await mock.isInMenu))
            #expect(menu.content == nil)
        }
    }

    @Test func exitNeverPressesAvoid() async throws {
        try await withMenuModel(personality: .bcd436hp, model: .bcd436hp) { menu, _, mock in
            _ = try await menu.enter()
            _ = try await menu.back()
            _ = try await menu.exit()
            let log = await mock.receivedCommands
            #expect(!log.contains("KEY,L,P") && !log.contains("KEY,M,P"), "\(log)")
        }
    }

    @Test func staleExitIsRefusedQuietly() async throws {
        let left = Mutex(false), live = Mutex(false)
        try await withMenuModel(personality: .bcd436hp, model: .bcd436hp, control: { client, mock in
            // Between exit()'s GSI reply and its MSB: the radio's panel leaves the menu.
            guard live.withLock({ $0 }), await mock.receivedCommands.last == "GSI", await mock.isInMenu,
                  left.withLock({ let was = $0; $0 = true; return !was }) else { return }
            try? await client.leaveMenu()
        }) { menu, client, mock in
            try await client.openMenu()
            _ = try await menu.refresh()
            live.withLock { $0 = true }
            let error = await menuError { try await menu.exit() }
            #expect(left.withLock { $0 }, "the panel left the menu")
            if case .rejected = error {} else { Issue.record("expected .rejected, got \(String(describing: error))") }
            let log = await mock.receivedCommands
            #expect(log.filter { $0 == "MSB,,RETURN_PREVOUS_MODE" }.count == 2, "the panel's and the model's, never resent: \(log)")
            #expect(menu.content == nil)
            #expect(!menu.isInMenu)
        }
    }

    @Test func notResentAfterADroppedReply() async throws {
        try await withMenuModel(personality: .bcd436hp, model: .bcd436hp, commandTimeout: .milliseconds(400)) { menu, _, mock in
            await mock.setFaults(MockFaults(dropNextReply: "MNU"))
            _ = await menuError { try await menu.enter() }
            let log = await mock.receivedCommands
            #expect(log.filter { $0 == "MNU,TOP," }.count == 1, "\(log)")
        }
    }

    @Test func withheldOnceDetached() async throws {
        let armed = Mutex(false), live = Mutex(false)
        let held = Mutex<Task<Void, Never>?>(nil)
        try await withMenuModel(personality: .bcd436hp, model: .bcd436hp, control: { client, mock in
            // The call before exit()'s MSB (after its GSI): hold the slot with a GSI the mock never answers.
            guard live.withLock({ $0 }), await mock.receivedCommands.last == "GSI", await mock.isInMenu,
                  armed.withLock({ let was = $0; $0 = true; return !was }) else { return }
            let before = await mock.receivedCommands.count
            await mock.setFaults(MockFaults(dropNextRequest: "GSI"))
            held.withLock { $0 = Task { _ = try? await client.scannerInfo() } }
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await mock.receivedCommands.dropFirst(before).contains("GSI")), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }, commandTimeout: .seconds(10)) { menu, client, mock in
            try await client.openMenu()
            _ = try await menu.refresh()
            live.withLock { $0 = true }
            let task = Task { try await menu.exit() }
            try await waitUntil("the MSB queued behind the held GSI", .seconds(5)) {
                await client.requestsWaitingForTheSlot == 1
            }
            menu.detach()
            held.withLock { $0?.cancel() }
            _ = await task.result
            await held.withLock { $0 }?.value
            #expect(!(await mock.receivedCommands.contains("MSB,,RETURN_PREVOUS_MODE")))
            #expect(await mock.isInMenu)
        }
    }

    @Test func sdsUnchanged() async throws {
        try await withMenuModel(personality: .sds100, model: .sds100) { menu, _, mock in
            _ = try await menu.enter()
            _ = try await menu.back()
            _ = try await menu.exit()
            let log = await mock.receivedCommands
            #expect(navCommands(log) == ["KEY,M,P", "KEY,M,P", "KEY,L,P"], "\(log)")
            #expect(!log.contains { $0.hasPrefix("MNU") || $0.hasPrefix("MSB") })
        }
    }

    @Test func destructiveItemOnTheBCDAsksFirst() async throws {
        try await withMenuModel(personality: .bcd436hp, model: .bcd436hp) { menu, _, mock in
            #expect(menu.isDestructive("Clear All ID Avoids"))
            #expect(menu.isDestructive("Reset to Factory"))
            #expect(menu.isDestructive("Delete Favorites List"))
            #expect(!menu.isDestructive("Display Options"))
            _ = try await menu.enter()
            let sent = await mock.receivedCommands.count
            let screen = try parsedScreen("""
                <MSI Name="Fictional" Index="4293060020" MenuType="TypeSelect" Selected="0" >
                <MenuItem Name="Clear All ID Avoids" Index="0" />
                <Footer No="1" EOT="1"/>
                </MSI>
                """)
            let item = try #require(screen.items.first)
            let error = await menuError { try await menu.choose(item, on: screen) }
            #expect(error == .needsConfirmation(itemName: "Clear All ID Avoids"))
            #expect(await mock.receivedCommands.count == sent)
        }
    }
}
