// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
@testable import NoctuleKit
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

// MenuModel.walk(_:) (Plan 24, Task 3; services-range design §5.1, §6): the checked menu walk that
// opens Select Service Types or Set Range. A model attached to a client of its own on each mock
// (MockSDS200 over UDP; MockSerialScanner as an SDS100, SDS150 or BCD436HP), so the mock's log
// holds only the model's commands (and a test's own "panel" commands, named where sent); one test
// runs the walk through a connected StationSession. Every test checks that no KEY,T or KEY,R was
// ever sent and counts the state-changing commands. All names and values are fictional.

private enum WalkTarget: CustomStringConvertible {
    case sds200, sds100, sds150, bcd436hp

    var model: ScannerModel {
        switch self {
        case .sds200: .sds200
        case .sds100: .sds100
        case .sds150: .sds150
        case .bcd436hp: .bcd436hp
        }
    }

    var description: String { "\(model)" }
}

/// A walk's model and the mock behind it.
@MainActor
private final class WalkRig {
    let menu: MenuModel
    let client: ScannerClient
    let log: @Sendable () async -> [String]
    let setFaults: @Sendable (MockFaults) async -> Void
    let menuPath: @Sendable () async -> [String]
    let isInMenu: @Sendable () async -> Bool

    init(menu: MenuModel, client: ScannerClient, log: @escaping @Sendable () async -> [String],
         setFaults: @escaping @Sendable (MockFaults) async -> Void,
         menuPath: @escaping @Sendable () async -> [String], isInMenu: @escaping @Sendable () async -> Bool) {
        self.menu = menu; self.client = client; self.log = log; self.setFaults = setFaults
        self.menuPath = menuPath; self.isInMenu = isInMenu
    }

    /// A mark for `commands(since:)`.
    func mark() async -> Int { await log().count }

    func commands(since mark: Int) async -> [String] { Array(await log().dropFirst(mark)) }
}

/// Runs `body` with a `MenuModel` attached to a client of its own on a mock of `target`, with that
/// model's navigation and destructive items. `control` runs on every `control()` call, before the
/// client is handed over (a test's panel acts there). Stops everything on every path, then checks
/// that no `KEY,T` or `KEY,R` reached the mock.
@MainActor
private func withWalk(
    _ target: WalkTarget, faults: MockFaults = .none, replyDelays: [String: Duration] = [:],
    commandTimeout: Duration = .seconds(2),
    control: @escaping @Sendable (ScannerClient, [String]) async -> Void = { _, _ in },
    _ body: (WalkRig) async throws -> Void
) async throws {
    var failure: (any Error)?
    var client: ScannerClient?
    var menu: MenuModel?
    let log: @Sendable () async -> [String]
    let stopMock: @Sendable () async -> Void
    let rigFor: (ScannerClient, MenuModel) -> WalkRig
    let connected: ScannerClient
    switch target {
    case .sds200:
        let mock = MockSDS200(scenario: .default, faults: faults,
                              options: MockSDS200.Options(clock: .stepped(at: 1), replyDelays: replyDelays))
        let ports = try await mock.start()
        log = { await mock.control.receivedCommands }
        stopMock = { await mock.stop() }
        connected = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort),
                                  commandTimeout: commandTimeout)
        rigFor = { client, menu in
            WalkRig(menu: menu, client: client, log: log, setFaults: { await mock.setFaults($0) },
                    menuPath: { await mock.menuPath }, isInMenu: { await mock.isInMenu })
        }
    case .sds100, .sds150, .bcd436hp:
        let personality: MockPersonality = switch target {
        case .sds100: .sds100
        case .sds150: .sds150
        default: .bcd436hp
        }
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 3), personality: personality,
                                     replyDelays: replyDelays)
        await mock.setFaults(faults)
        let path = try await mock.start()
        log = { await mock.receivedCommands }
        stopMock = { await mock.stop() }
        connected = ScannerClient(transport: SerialTransport(path: path), commandTimeout: commandTimeout)
        rigFor = { client, menu in
            WalkRig(menu: menu, client: client, log: log, setFaults: { await mock.setFaults($0) },
                    menuPath: { await mock.menuPath }, isInMenu: { await mock.isInMenu })
        }
    }
    do {
        client = connected
        try await connected.connect()
        let profile = ModelProfile.profile(for: target.model)
        let made = MenuModel(destructiveItems: profile.destructiveMenuItems)
        made.navigation = profile.menuNavigation
        made.walkGrace = .milliseconds(50)
        menu = made
        made.attach(control: {
            await control(connected, await log())
            return connected
        })
        try await body(rigFor(connected, made))
    } catch { failure = error }
    menu?.detach()
    await menu?.quiesce()
    await client?.disconnect()
    await stopMock()
    let all = await log()
    if let failure { throw failure }
    #expect(!all.contains { $0.uppercased().hasPrefix("KEY,T") || $0.uppercased().hasPrefix("KEY,R") },
            "KEY,T or KEY,R was sent: \(all)")
}

/// The commands a walk's wire is made of: reads of the menu (`GSI`, `MSI`) and navigation.
private func wire(_ commands: [String]) -> [String] {
    commands.filter { command in
        let name = command.uppercased()
        return name == "GSI" || name == "MSI" || ["KEY,", "MSV,", "MNU,", "MSB,"].contains { name.hasPrefix($0) }
    }
}

/// Commands that change scanner state (AGENTS.md): `KEY`, `MSV`, `MNU`, `MSB`, `HLD`, a `VOL` or
/// `SQL` value, a quick-key set.
private func stateChanging(_ commands: [String]) -> [String] {
    commands.filter { command in
        let name = command.uppercased()
        if ["KEY,", "MSV,", "MNU,", "MSB,", "HLD,", "VOL,", "SQL,"].contains(where: { name.hasPrefix($0) }) { return true }
        if ["FQK,", "SQK,", "DQK,"].contains(where: { name.hasPrefix($0) }) {
            return name.split(separator: ",", omittingEmptySubsequences: false).count > 3
        }
        return false
    }
}

private func enterCommand(_ target: WalkTarget) -> String {
    target == .bcd436hp ? "MNU,TOP," : "KEY,M,P"
}

/// The thrown `MenuActionError`, or nil when `body` returned.
@MainActor
private func walkError(_ body: () async throws -> MenuContent?) async -> MenuActionError? {
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

private func screenTitle(_ content: MenuContent?) -> String? {
    switch content {
    case .list(let screen), .entry(let screen): screen.title?.trimmingCharacters(in: .whitespaces)
    case .mirrored, nil: nil
    }
}

private func parsedScreen(_ xml: String) throws -> MenuScreen {
    try MenuScreen(xml: XMLNode.parse(Data(xml.utf8)))
}

private func menuInfo(_ title: String, kind: String = "menu_selection") throws -> ScannerInfo {
    let xml = "<ScannerInfo Mode=\"Menu tree\" V_Screen=\"\(kind)\"><MenuSummary name=\"\(title)\" index=\"4293060001\" /></ScannerInfo>"
    return try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

private func scanningInfo() throws -> ScannerInfo {
    let xml = "<ScannerInfo Mode=\"Trunk Scan\" V_Screen=\"trunk_scan\"></ScannerInfo>"
    return try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

private let topMenuXML = """
    <MSI Name="       --- M E N U ---" Index="4293060001" MenuType="TypeSelect" Selected="0" >
    <MenuItem Name="Set Scan Selection" Index="0" />
    <MenuItem Name="Set Your Location " Index="1" />
    <MenuItem Name="Select Service Types" Index="2" />
    <MenuItem Name="Settings" Index="6" />
    <Footer No="1" EOT="1"/>
    </MSI>
    """

/// Range's wire (design §5.1) with `enter` and Set Your Location at 1, Set Range at 0 in the mock's tree.
private func rangeWire(_ enter: String) -> [String] {
    ["GSI", enter, "GSI", "MSI", "MSV,,1", "GSI", "MSI", "MSV,,0", "GSI", "MSI"]
}

/// Services' wire: Select Service Types is the top menu's item 2 in the mock's tree.
private func servicesWire(_ enter: String) -> [String] {
    ["GSI", enter, "GSI", "MSI", "MSV,,2", "GSI", "MSI"]
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct MenuWalkTests {
    // MARK: judge

    @Test func judgeProceedsOnTheTopMenuWithTheItem() throws {
        let verdict = MenuModel.judge(info: try menuInfo("       --- M E N U ---"), screen: try parsedScreen(topMenuXML),
                                      expecting: MenuStep(screen: "Menu", item: "Set Your Location"),
                                      destination: "Set Range", previousTitle: nil)
        #expect(verdict == .proceed(itemIndex: 1), "the item name is trimmed")
    }

    @Test func judgeMismatchesWhenTheItemIsMissing() throws {
        let verdict = MenuModel.judge(info: try menuInfo("       --- M E N U ---"), screen: try parsedScreen(topMenuXML),
                                      expecting: MenuStep(screen: "Menu", item: "Set Your Place"),
                                      destination: "Set Range", previousTitle: nil)
        #expect(verdict == .mismatch(found: "Menu"))
    }

    @Test func judgeMismatchesOnTwoItemsOfThatName() throws {
        let screen = try parsedScreen("""
            <MSI Name="--- M E N U ---" Index="4293060001" MenuType="TypeSelect" Selected="0" >
            <MenuItem Name="Set Your Location" Index="1" />
            <MenuItem Name="Set Your Location" Index="3" />
            <Footer No="1" EOT="1"/>
            </MSI>
            """)
        let verdict = MenuModel.judge(info: try menuInfo("--- M E N U ---"), screen: screen,
                                      expecting: MenuStep(screen: "Menu", item: "Set Your Location"),
                                      destination: "Set Range", previousTitle: nil)
        #expect(verdict == .mismatch(found: "Menu"))
    }

    @Test func judgeMatchesNamesExactly() throws {
        let verdict = MenuModel.judge(info: try menuInfo("--- M E N U ---"), screen: try parsedScreen(topMenuXML),
                                      expecting: MenuStep(screen: "Menu", item: "set your location"),
                                      destination: "Set Range", previousTitle: nil)
        #expect(verdict == .mismatch(found: "Menu"), "case-sensitive")
        let wrongScreen = MenuModel.judge(info: try menuInfo("--- M E N U ---"), screen: try parsedScreen(topMenuXML),
                                          expecting: MenuStep(screen: "Settings", item: "Set Your Location"),
                                          destination: "Set Range", previousTitle: nil)
        #expect(wrongScreen == .mismatch(found: "Menu"))
    }

    @Test func judgeMismatchesWithoutAList() throws {
        let entry = try parsedScreen("""
            <MSI Name="       --- M E N U ---" Index="4293060001" MenuType="TypeInput" Value="1" >
            <MenuItem Name="Set Your Location" Index="1" />
            <MenuInput MaxLength="5" EnableKeys="0123456789" />
            <Footer No="1" EOT="1"/>
            </MSI>
            """)
        let step = MenuStep(screen: "Menu", item: "Set Your Location")
        #expect(MenuModel.judge(info: try menuInfo("--- M E N U ---"), screen: entry, expecting: step,
                                destination: "Set Range", previousTitle: nil) == .mismatch(found: "Menu"))
        #expect(MenuModel.judge(info: try menuInfo("--- M E N U ---"), screen: nil, expecting: step,
                                destination: "Set Range", previousTitle: nil) == .mismatch(found: "Menu"),
                "an unanswered or garbled MSI")
    }

    @Test func judgeMismatchesWhenGSIAndMSIDisagree() throws {
        let verdict = MenuModel.judge(info: try menuInfo("Settings"), screen: try parsedScreen(topMenuXML),
                                      expecting: MenuStep(screen: "Menu", item: "Set Your Location"),
                                      destination: "Set Range", previousTitle: nil)
        #expect(verdict == .mismatch(found: "Settings"))
    }

    @Test func judgeIsStaleOnThePreviousScreen() throws {
        let verdict = MenuModel.judge(info: try menuInfo("--- M E N U ---"), screen: try parsedScreen(topMenuXML),
                                      expecting: MenuStep(screen: "Set Your Location", item: "Set Range"),
                                      destination: "Set Range", previousTitle: "Menu")
        #expect(verdict == .stale)
        // After the enter, the previous "screen" is none: still scanning is stale too.
        let scanning = MenuModel.judge(info: try scanningInfo(), screen: nil,
                                       expecting: MenuStep(screen: "Menu", item: "Set Your Location"),
                                       destination: "Set Range", previousTitle: nil)
        #expect(scanning == .stale)
    }

    @Test func judgeArrivalOnGSIWhateverMSISays() throws {
        let typeError = try parsedScreen("""
            <MSI Name="" Index="" MenuType="TypeError" >
            <MenuErrorMsg Text="The scanner is in state that you can't remote control." />
            <Footer No="1" EOT="1"/>
            </MSI>
            """)
        #expect(MenuModel.judge(info: try menuInfo(" Set Range ", kind: "menu_input"), screen: typeError,
                                expecting: nil, destination: "Set Range", previousTitle: "Set Your Location") == .arrived)
        #expect(MenuModel.judge(info: try menuInfo("Set Range", kind: "menu_input"), screen: nil,
                                expecting: nil, destination: "Set Range", previousTitle: "Set Your Location") == .arrived)
        #expect(MenuModel.judge(info: try menuInfo("Set Your Location"), screen: nil,
                                expecting: nil, destination: "Set Range", previousTitle: "Set Your Location") == .stale)
        #expect(MenuModel.judge(info: try menuInfo("Settings"), screen: nil,
                                expecting: nil, destination: "Set Range", previousTitle: "Set Your Location")
                == .mismatch(found: "Settings"))
        #expect(MenuModel.judge(info: try scanningInfo(), screen: nil,
                                expecting: nil, destination: "Set Range", previousTitle: "Set Your Location")
                == .mismatch(found: nil), "left the menu")
    }

    // MARK: Reaching the screens

    @Test func rangeOnTheSDS200SendsTheDesignedWire() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            let mark = await commandMark(rig.mock)
            let content = try await rig.session.menu.walk(.range)
            let window = await rig.mock.control.receivedCommands.dropFirst(mark)
            #expect(wire(Array(window)) == rangeWire("KEY,M,P"), "\(Array(window))")
            #expect(stateChanging(Array(window)) == ["KEY,M,P", "MSV,,1", "MSV,,0"], "\(Array(window))")
            guard case .entry(let screen) = content else {
                Issue.record("not an entry: \(String(describing: content))"); return
            }
            #expect(screen.title?.trimmingCharacters(in: .whitespaces) == "Set Range")
            #expect(rig.session.menu.content == content)
            #expect(rig.session.menu.breadcrumb == ["Menu", "Set Your Location", "Set Range"])
            #expect(!rig.session.menu.isBusy)
            #expect(rig.session.menu.lastError == nil)
            #expect(await rig.mock.menuPath.last == "Set Range")
        }
        #expect(outcome.leaked == [])
        #expect(!outcome.commands.contains { $0.hasPrefix("KEY,T") || $0.hasPrefix("KEY,R") })
    }

    @Test func servicesOnTheSDS200() async throws {
        try await withWalk(.sds200) { rig in
            let content = try await rig.menu.walk(.serviceTypes)
            guard case .list(let screen) = content else {
                Issue.record("not a list: \(String(describing: content))"); return
            }
            #expect(screen.title?.trimmingCharacters(in: .whitespaces) == "Select Service Types")
            #expect(screen.items.map(\.name).contains("Law Dispatch"))
            let log = await rig.log()
            #expect(wire(log) == servicesWire("KEY,M,P"), "\(log)")
            #expect(stateChanging(log).count == 2)
            #expect(await rig.menuPath().last == "Select Service Types")
        }
    }

    /// Range on a handheld: the designed wire with that model's enter.
    private func range(on target: WalkTarget) async throws {
        try await withWalk(target) { rig in
            let content = try await rig.menu.walk(.range)
            guard case .entry = content else {
                Issue.record("not an entry: \(String(describing: content))"); return
            }
            #expect(screenTitle(content) == "Set Range")
            let log = await rig.log()
            #expect(wire(log) == rangeWire(enterCommand(target)), "\(log)")
            #expect(stateChanging(log) == [enterCommand(target), "MSV,,1", "MSV,,0"], "\(log)")
            #expect(await rig.menuPath().last == "Set Range")
            #expect(rig.menu.breadcrumb == ["Menu", "Set Your Location", "Set Range"])
        }
    }

    @Test func rangeOnTheSDS100() async throws { try await range(on: .sds100) }

    @Test func rangeOnTheSDS150() async throws { try await range(on: .sds150) }

    @Test func rangeOnTheBCD436HPUsesMNU() async throws {
        try await range(on: .bcd436hp)
        try await withWalk(.bcd436hp) { rig in
            _ = try await rig.menu.walk(.range)
            #expect(!(await rig.log()).contains { $0.hasPrefix("KEY,") }, "no keys on the BCD436HP's walk")
        }
    }

    @Test func servicesOnTheBCD436HP() async throws {
        try await withWalk(.bcd436hp) { rig in
            let content = try await rig.menu.walk(.serviceTypes)
            #expect(screenTitle(content) == "Select Service Types")
            let log = await rig.log()
            #expect(wire(log) == servicesWire("MNU,TOP,"), "\(log)")
            #expect(stateChanging(log) == ["MNU,TOP,", "MSV,,2"])
        }
    }

    // MARK: Refused before anything is sent

    @Test func alreadyInMenuSendsNothing() async throws {
        try await withWalk(.sds200) { rig in
            _ = try await rig.menu.enter()
            rig.menu.show(nil, title: nil, menuIndex: nil)  // as if the panel's own menu hadn't been read yet
            let mark = await rig.mark()
            let error = await walkError { try await rig.menu.walk(.range) }
            #expect(error == .alreadyInMenu)
            #expect(rig.menu.lastError == .alreadyInMenu)
            let after = await rig.commands(since: mark)
            #expect(stateChanging(after).isEmpty, "\(after)")
            #expect(after == ["GSI", "MSI"], "the menu is shown as refresh() would: \(after)")
            #expect(screenTitle(rig.menu.content) == "--- M E N U ---")
            #expect(rig.menu.breadcrumb == ["Menu"])
            #expect(!rig.menu.isBusy)
        }
    }

    @Test func funcPendingSendsNothing() async throws {
        try await withWalk(.sds200) { rig in
            try await rig.client.press(.function)  // the radio's panel
            let mark = await rig.mark()
            let error = await walkError { try await rig.menu.walk(.range) }
            #expect(error == .functionPending)
            #expect(rig.menu.lastError == .functionPending)
            let after = await rig.commands(since: mark)
            #expect(after == ["GSI"], "\(after)")
            #expect(await !rig.isInMenu())
            #expect(rig.menu.content == nil)
        }
    }

    @Test func unansweredGSISendsNothing() async throws {
        try await withWalk(.sds200, commandTimeout: .milliseconds(400)) { rig in
            await rig.setFaults(MockFaults(dropNextRequest: "GSI", dropCount: 2))
            let error = await walkError { try await rig.menu.walk(.range) }
            #expect(error == .noAnswer)
            let log = await rig.log()
            #expect(stateChanging(log).isEmpty, "\(log)")
            #expect(await !rig.isInMenu())
        }
    }

    // MARK: Stops

    @Test func wrongPathStopsWithoutSending() async throws {
        try await withWalk(.sds200) { rig in
            let path = MenuPath(steps: [MenuStep(screen: "Menu", item: "Set Your Place")], destination: "Set Range")
            let error = await walkError { try await rig.menu.walk(path) }
            #expect(error == .walkStopped(expected: "Menu", found: "Menu"))
            #expect(rig.menu.lastError == .walkStopped(expected: "Menu", found: "Menu"))
            let log = await rig.log()
            #expect(stateChanging(log) == ["KEY,M,P"], "\(log)")
            #expect(wire(log) == ["GSI", "KEY,M,P", "GSI", "MSI", "GSI", "MSI"], "one re-read after the stop: \(log)")
            #expect(await rig.isInMenu())
            #expect(await rig.menuPath().count == 1, "left on the top menu")
            #expect(rig.menu.breadcrumb == ["Menu"])
        }
    }

    @Test func wrongScreenNameStops() async throws {
        try await withWalk(.sds200) { rig in
            let path = MenuPath(steps: [MenuStep(screen: "Menu", item: "Set Your Location"),
                                        MenuStep(screen: "Settings", item: "Set Range")],
                                destination: "Set Range")
            let error = await walkError { try await rig.menu.walk(path) }
            #expect(error == .walkStopped(expected: "Settings", found: "Set Your Location"))
            let log = await rig.log()
            #expect(stateChanging(log) == ["KEY,M,P", "MSV,,1"], "\(log)")
            #expect(await rig.menuPath().last == "Set Your Location")
        }
    }

    @Test func unansweredMSIStops() async throws {
        try await withWalk(.sds200, commandTimeout: .milliseconds(400)) { rig in
            await rig.setFaults(MockFaults(dropNextRequest: "MSI", dropCount: 2))
            let error = await walkError { try await rig.menu.walk(.range) }
            #expect(error == .walkStopped(expected: "Menu", found: "Menu"))
            let log = await rig.log()
            #expect(stateChanging(log) == ["KEY,M,P"], "\(log)")
        }
    }

    @Test func rejectedMSVStops() async throws {
        try await withWalk(.sds200) { rig in
            await rig.setFaults(MockFaults(rejectNext: "MSV"))
            let error = await walkError { try await rig.menu.walk(.range) }
            guard case .rejected = error else {
                Issue.record("expected .rejected, got \(String(describing: error))"); return
            }
            let log = await rig.log()
            #expect(stateChanging(log) == ["KEY,M,P", "MSV,,1"], "\(log)")
            let msv = try #require(log.firstIndex(of: "MSV,,1"))
            #expect(log[(msv + 1)...].allSatisfy { $0 == "GSI" || $0 == "MSI" }, "only reads after it: \(log)")
            #expect(await rig.menuPath().count == 1, "NG: not carried out")
        }
    }

    @Test func droppedEnterReplyStops() async throws {
        try await withWalk(.sds200, commandTimeout: .milliseconds(400)) { rig in
            await rig.setFaults(MockFaults(dropNextReply: "KEY"))
            let error = await walkError { try await rig.menu.walk(.range) }
            #expect(error == .noAnswer)
            let log = await rig.log()
            #expect(stateChanging(log) == ["KEY,M,P"], "never resent: \(log)")
            let key = try #require(log.firstIndex(of: "KEY,M,P"))
            #expect(log[(key + 1)...].allSatisfy { $0 == "GSI" || $0 == "MSI" }, "only reads after it: \(log)")
            #expect(await rig.isInMenu(), "the enter was carried out; its reply was lost")
        }
    }

    @Test func droppedEnterRequestStops() async throws {
        try await withWalk(.bcd436hp, commandTimeout: .milliseconds(400)) { rig in
            await rig.setFaults(MockFaults(dropNextRequest: "MNU"))
            let error = await walkError { try await rig.menu.walk(.range) }
            #expect(error == .noAnswer)
            let log = await rig.log()
            #expect(stateChanging(log) == ["MNU,TOP,"], "never resent: \(log)")
            #expect(await !rig.isInMenu())
        }
    }

    @Test func droppedMSVRequestStops() async throws {
        try await withWalk(.sds200, commandTimeout: .milliseconds(400)) { rig in
            await rig.setFaults(MockFaults(dropNextRequest: "MSV"))
            let error = await walkError { try await rig.menu.walk(.range) }
            #expect(error == .noAnswer)
            let log = await rig.log()
            #expect(stateChanging(log) == ["KEY,M,P", "MSV,,1"], "never resent: \(log)")
            let msv = try #require(log.firstIndex(of: "MSV,,1"))
            #expect(log[(msv + 1)...].allSatisfy { $0 == "GSI" || $0 == "MSI" }, "only reads after it: \(log)")
            #expect(await rig.menuPath().count == 1)
        }
    }

    // MARK: A slow redraw

    /// The panel puts the scanner back on the top menu just as the first `MSV`'s re-read starts, so
    /// that re-read looks stale; with `recover`, it opens Set Your Location again just before the
    /// grace re-read.
    private static func slowRedraw(recover: Bool) -> @Sendable (ScannerClient, [String]) async -> Void {
        let phase = Mutex(0)
        return { client, log in
            let now = phase.withLock { $0 }
            if now == 0, log.last == "MSV,,1" {
                phase.withLock { $0 = 1 }
                try? await client.press(.menu)  // the panel: back to the top menu
            } else if now == 1, recover, log.last == "MSI" {
                phase.withLock { $0 = 2 }
                try? await client.setMenuValue("1")  // the panel: Set Your Location again
            }
        }
    }

    @Test func slowRedrawGraceLetsTheWalkGoOn() async throws {
        try await withWalk(.sds200, control: Self.slowRedraw(recover: true)) { rig in
            let content = try await rig.menu.walk(.range)
            #expect(screenTitle(content) == "Set Range")
            let log = await rig.log()
            // The panel's commands in brackets: [KEY,M,P] after the first MSV, [MSV,,1] before the grace GSI.
            #expect(wire(log) == ["GSI", "KEY,M,P", "GSI", "MSI", "MSV,,1", "KEY,M,P", "GSI", "MSI",
                                  "MSV,,1", "GSI", "MSI", "MSV,,0", "GSI", "MSI"], "\(log)")
            #expect(stateChanging(log).count - 2 == 3, "the model's three: \(log)")
        }
    }

    @Test func secondStaleReadStops() async throws {
        try await withWalk(.sds200, control: Self.slowRedraw(recover: false)) { rig in
            let error = await walkError { try await rig.menu.walk(.range) }
            #expect(error == .walkStopped(expected: "Set Your Location", found: "Menu"))
            let log = await rig.log()
            #expect(wire(log) == ["GSI", "KEY,M,P", "GSI", "MSI", "MSV,,1", "KEY,M,P", "GSI", "MSI",
                                  "GSI", "MSI", "GSI", "MSI"], "grace re-read, then one re-read: \(log)")
            #expect(!log.contains("MSV,,0"))
        }
    }

    // MARK: Detach and busy

    @Test func detachMidWalkSendsNothingMore() async throws {
        try await withWalk(.sds200, replyDelays: ["MSV": .milliseconds(600)]) { rig in
            let menu = rig.menu
            let task = Task { try await menu.walk(.range) }
            try await waitUntil("the first MSV", .seconds(5)) { await rig.log().contains("MSV,,1") }
            menu.detach()
            let result = await task.result
            if case .failure(let error) = result { #expect(error as? MenuActionError == .notConnected) }
            else { Issue.record("expected .notConnected, got \(result)") }
            try await Task.sleep(for: .milliseconds(200))
            let log = await rig.log()
            #expect(stateChanging(log) == ["KEY,M,P", "MSV,,1"], "\(log)")
            #expect(log.last == "MSV,,1", "nothing after it, not even a re-read: \(log)")
            #expect(!menu.isBusy)
            #expect(menu.content == nil)
        }
    }

    @Test func detachWhileTheMSVWaitsForTheSlotWithholdsIt() async throws {
        let armed = Mutex(false)
        let held = Mutex<Task<Void, Never>?>(nil)
        let mockFaults = Mutex<(@Sendable (MockFaults) async -> Void)?>(nil)
        try await withWalk(.bcd436hp, commandTimeout: .seconds(10), control: { client, log in
            // The control() call for the first MSV (after the enter's re-read): hold the slot with a
            // GSI the mock never answers.
            guard log.contains("MNU,TOP,"), log.last == "MSI", !log.contains(where: { $0.hasPrefix("MSV") }),
                  armed.withLock({ let was = $0; $0 = true; return !was }),
                  let setFaults = mockFaults.withLock({ $0 }) else { return }
            await setFaults(MockFaults(dropNextRequest: "GSI"))
            held.withLock { $0 = Task { _ = try? await client.scannerInfo() } }
            try? await Task.sleep(for: .milliseconds(100))
        }) { rig in
            mockFaults.withLock { $0 = rig.setFaults }
            let menu = rig.menu
            let task = Task { try await menu.walk(.range) }
            try await waitUntil("the MSV queued behind the held GSI", .seconds(5)) {
                await rig.client.requestsWaitingForTheSlot == 1
            }
            menu.detach()
            held.withLock { $0?.cancel() }
            let result = await task.result
            if case .failure(let error) = result { #expect(error as? MenuActionError == .notConnected) }
            else { Issue.record("expected .notConnected, got \(result)") }
            await held.withLock { $0 }?.value
            let log = await rig.log()
            #expect(stateChanging(log) == ["MNU,TOP,"], "the MSV was withheld: \(log)")
            #expect(await rig.menuPath().count == 1)
        }
    }

    @Test func walkIsOneAction() async throws {
        try await withWalk(.sds200, replyDelays: ["MSV": .milliseconds(400)]) { rig in
            let menu = rig.menu
            let task = Task { try await menu.walk(.range) }
            try await waitUntil("in the menu, mid-walk", .seconds(5)) { menu.content != nil && menu.isBusy }
            guard case .list(let top) = menu.content else {
                Issue.record("not a list: \(String(describing: menu.content))"); return
            }
            let item = try #require(top.items.first)
            #expect(await walkError { try await menu.choose(item, on: top) } == .busy)
            #expect(await walkError { try await menu.back() } == .busy)
            #expect(await walkError { try await menu.walk(.serviceTypes) } == .busy)
            #expect(await walkError { try await menu.enter() } == .busy)
            let content = try await task.value
            #expect(screenTitle(content) == "Set Range")
            #expect(menu.lastError == nil, "a .busy refusal isn't recorded")
            let log = await rig.log()
            #expect(stateChanging(log) == ["KEY,M,P", "MSV,,1", "MSV,,0"], "\(log)")
        }
    }
}
