// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import NoctuleAppCore
import NoctuleKit
import Testing
@testable import NoctuleScan

/// The Mac-style menu's view logic (remote menus design §5.3-§5.5), without any views: the local
/// selection and entry draft, the pending confirmation, and the text.
@MainActor @Suite(.timeLimit(.minutes(3))) struct MacMenuTests {
    private func screen(_ xml: String) throws -> MenuScreen {
        try MenuScreen(xml: NoctuleKit.XMLNode.parse(Data(xml.utf8)))
    }

    /// A fictional list screen: `items` as (index, name, value).
    private func list(index: String = "4293060002", selected: Int, items: [(Int, String, String?)]) throws -> MenuScreen {
        let rows = items.map { item in
            #"<MenuItem Name="\#(item.1)" Index="\#(item.0)""# + (item.2.map { #" Value="\#($0)""# } ?? "") + " />"
        }.joined()
        return try screen(#"<MSI Name="Select Lists to Monitor" Index="\#(index)" MenuType="TypeSelect" Selected="\#(selected)">"#
                          + rows + "</MSI>")
    }

    private func entry(index: String = "4293060020", value: String, maxLength: Int = 64,
                       added: String? = nil) throws -> MenuScreen {
        let info = added.map { #" AddedInformation="\#($0)""# } ?? ""
        return try screen(#"<MSI Name="Edit Name" Index="\#(index)" MenuType="TypeInput" Value="\#(value)">"#
                          + #"<MenuInput MaxLength="\#(maxLength)"\#(info) EnableKeys="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 " />"#
                          + "</MSI>")
    }

    private func fourteen(selected: Int, index: String = "4293060002") throws -> MenuScreen {
        try list(index: index, selected: selected, items: (0..<14).map { ($0, "List \($0)", $0.isMultiple(of: 2) ? "On" : "Off") })
    }

    // MARK: Selection

    @Test func selectionFollowsTheScannerOnNewScreen() throws {
        let state = MacMenuState()
        state.sync(with: .list(try fourteen(selected: 13)))
        #expect(state.selection == 13)

        // Moved locally, then the same menu re-read (a refresh, a toggle): the local selection stays.
        state.move(-3, in: try fourteen(selected: 13))
        #expect(state.selection == 10)
        state.sync(with: .list(try fourteen(selected: 2)))
        #expect(state.selection == 10, "a re-read of the same menu keeps the local selection")

        // The same menu, but the selected item is gone: the scanner's selection again.
        state.sync(with: .list(try list(selected: 1, items: [(0, "A", nil), (1, "B", nil)])))
        #expect(state.selection == 1)

        // Another screen: the scanner's selection.
        state.move(-1, in: try list(selected: 1, items: [(0, "A", nil), (1, "B", nil)]))
        #expect(state.selection == 0)
        state.sync(with: .list(try fourteen(selected: 5, index: "4293060001")))
        #expect(state.selection == 5)

        // Out of the menu and back in: the scanner's selection.
        state.move(1, in: try fourteen(selected: 5, index: "4293060001"))
        state.sync(with: nil)
        #expect(state.selection == nil)
        state.sync(with: .list(try fourteen(selected: 5, index: "4293060001")))
        #expect(state.selection == 5)
    }

    @Test func moveClampsAtEnds() throws {
        let state = MacMenuState()
        let screen = try fourteen(selected: 0)
        state.sync(with: .list(screen))
        state.move(-1, in: screen)
        #expect(state.selection == 0, "no wrap at the top")
        state.move(1, in: screen)
        #expect(state.selection == 1)
        state.move(100, in: screen)
        #expect(state.selection == 13, "no wrap at the bottom")
        state.move(1, in: screen)
        #expect(state.selection == 13)
    }

    /// `MSI` omits items (Analyze), so indexes skip; the local selection moves by row, not by index.
    @Test func moveSkipsNothingAcrossIndexGaps() throws {
        let state = MacMenuState()
        let screen = try list(selected: 7, items: [(5, "Search for...", nil), (7, "Close Call", nil), (9, "Display Options", nil)])
        state.sync(with: .list(screen))
        #expect(state.selection == 7)
        state.move(1, in: screen)
        #expect(state.selection == 9)
        state.move(-1, in: screen)
        #expect(state.selection == 7)
        state.move(-1, in: screen)
        #expect(state.selection == 5)
    }

    // MARK: Draft

    @Test func draftFollowsNewEntryScreen() throws {
        let state = MacMenuState()
        let name = try entry(value: "Custom 9")
        state.sync(with: .entry(name))
        #expect(state.draft == "Custom 9")
        state.setDraft("Custom 9 North", rules: name.input!)
        #expect(state.draft == "Custom 9 North")

        // The same entry re-read: the user's typing stays.
        state.sync(with: .entry(try entry(value: "Custom 9")))
        #expect(state.draft == "Custom 9 North")

        // The same entry with another value (changed on the radio): the new value (final review M3).
        state.sync(with: .entry(try entry(value: "Night Ops")))
        #expect(state.draft == "Night Ops")
        state.setDraft("Night Ops 2", rules: name.input!)
        state.sync(with: .entry(try entry(value: "Night Ops")))
        #expect(state.draft == "Night Ops 2", "and from there typing is kept again")

        // Another entry screen: its value.
        state.sync(with: .entry(try entry(index: "4293060030", value: "30.0", maxLength: 5)))
        #expect(state.draft == "30.0")

        // Gone when the content is no longer an entry; a return to the entry starts from its value.
        state.sync(with: .mirrored)
        #expect(state.draft == "")
        state.sync(with: .entry(name))
        #expect(state.draft == "Custom 9")
    }

    @Test func draftIsSanitizedAsTyped() throws {
        let state = MacMenuState()
        let range = try entry(index: "4293060030", value: "30.0", maxLength: 5)
        let rules = MenuScreen.InputRules(maxLength: 5, allowedCharacters: "0123456789.")
        state.sync(with: .entry(range))
        state.setDraft("12,5x\r", rules: rules)
        #expect(state.draft == "125")
        state.setDraft("1234567", rules: rules)
        #expect(state.draft == "12345")
    }

    // MARK: Confirmation

    @Test func pendingConfirmationClearsWhenContentChanges() throws {
        let state = MacMenuState()
        let screen = try list(selected: 0, items: [(0, "Clear User Data", nil)])
        state.sync(with: .list(screen))
        state.pendingConfirmation = .init(itemName: "Clear User Data", item: screen.items[0], screen: screen)

        state.sync(with: .list(screen))
        #expect(state.pendingConfirmation != nil, "the same content again leaves it")

        state.sync(with: .list(try list(selected: 0, items: [(0, "Clear User Data", nil), (1, "Other", nil)])))
        #expect(state.pendingConfirmation == nil, "any change of content clears it")

        state.sync(with: .mirrored)
        state.pendingConfirmation = .init(itemName: "Set All Lists Off", item: nil, screen: nil)
        state.sync(with: nil)
        #expect(state.pendingConfirmation == nil)
    }

    // MARK: Text

    @Test func activateTitles() {
        #expect(MacMenuText.activateTitle(MenuScreen.Item(index: 2, name: "Lakeview", value: "On")) == "Toggle")
        #expect(MacMenuText.activateTitle(MenuScreen.Item(index: 2, name: "Lakeview", value: "Off")) == "Toggle")
        #expect(MacMenuText.activateTitle(MenuScreen.Item(index: 0, name: "Set Scan Selection")) == "Open")
        #expect(MacMenuText.activateTitle(nil) == "Open")
    }

    @Test func breadcrumbTextJoins() throws {
        #expect(MacMenuText.breadcrumbText(["Menu", "Display Options"]) == "Menu › Display Options")
        #expect(MacMenuText.breadcrumbText(["Menu", "Search for...", "Custom 9", "Edit Name"])
                == "Menu › Search for... › Custom 9 › Edit Name")
        #expect(MacMenuText.breadcrumbText(["Menu"]) == nil)
        #expect(MacMenuText.breadcrumbText([]) == nil)

        // The title: the screen's, trimmed (the top menu is `Menu`), else the breadcrumb's last.
        let top = try screen(#"<MSI Name="       --- M E N U ---" Index="1" MenuType="TypeSelect" Selected="0"><MenuItem Name="A" Index="0" /></MSI>"#)
        #expect(MacMenuText.title(.list(top), breadcrumb: ["Menu"]) == "Menu")
        #expect(MacMenuText.title(.entry(try entry(value: "x")), breadcrumb: []) == "Edit Name")
        #expect(MacMenuText.title(.mirrored, breadcrumb: ["Menu", "Analyze"]) == "Analyze")
        #expect(MacMenuText.title(.mirrored, breadcrumb: []) == "Menu")
        #expect(MacMenuText.title(nil, breadcrumb: []) == "Menu")
    }

    @Test func unitTrims() {
        #expect(MacMenuText.unit(.init(maxLength: 5, allowedCharacters: "0123456789.", addedInformation: "          (mile)")) == "(mile)")
        #expect(MacMenuText.unit(.init(addedInformation: "   ")) == nil)
        #expect(MacMenuText.unit(.init()) == nil)
    }

    @Test func counterText() {
        let rules = MenuScreen.InputRules(maxLength: 64)
        #expect(MacMenuText.counter("Custom 9", rules: rules) == "8 of 64 characters")
        #expect(MacMenuText.counter("", rules: rules) == "0 of 64 characters")
        #expect(MacMenuText.counter("30.0", rules: .init()) == nil, "no MaxLength, no counter")
    }

    @Test func errorMessages() {
        #expect(MacMenuText.errorMessage(.menuChanged) == "The menu changed on the scanner. Nothing was sent.")
        #expect(MacMenuText.errorMessage(.noAnswer) == "The scanner didn't answer. Check the menu before trying again.")
        #expect(MacMenuText.errorMessage(.rejected("MSV,NG")) == "The scanner refused that.")
        #expect(MacMenuText.errorMessage(.invalidValue) == "That value isn't allowed here.")
        #expect(MacMenuText.errorMessage(.alreadyInMenu) == "The scanner is already in a menu. Nothing was sent.")
        #expect(MacMenuText.errorMessage(.functionPending) == "Func is on at the scanner. Nothing was sent.")
        #expect(MacMenuText.errorMessage(.walkStopped(expected: "Set Your Location", found: "Settings"))
                == "Couldn't open Set Your Location: the scanner showed Settings. Nothing more was sent.")
        #expect(MacMenuText.errorMessage(.walkStopped(expected: "Menu", found: nil))
                == "Couldn't open Menu: the scanner showed no menu. Nothing more was sent.")
        #expect(MacMenuText.errorMessage(.busy) == nil)
        #expect(MacMenuText.errorMessage(.needsConfirmation(itemName: "Clear User Data")) == nil)
        #expect(MacMenuText.errorMessage(.notInMenu) == nil)
        #expect(MacMenuText.errorMessage(.notConnected) == nil)
        #expect(MacMenuText.confirmationMessage(itemName: "Clear User Data")
                == "“Clear User Data” can't be undone from here. Send it to the scanner?")
        #expect(MacMenuText.pausedNote == "Scanning is paused while the scanner is in a menu.")
        #expect(MacMenuText.mirroredNote == "The scanner doesn't describe this screen. It is shown as the scanner draws it.")
    }

    /// Design §5.5: the menu area says so when the scanner stops answering reads.
    @Test func notAnsweringNoteShowsWhenReadsFail() {
        #expect(MacMenuText.notAnsweringNote == "The scanner isn't answering.")
        #expect(MacMenuText.statusLine(lastError: nil, isScannerAnswering: false) == "The scanner isn't answering.")
        #expect(MacMenuText.statusLine(lastError: .menuChanged, isScannerAnswering: false) == "The scanner isn't answering.",
                "the standing state wins over an older action's error")
        #expect(MacMenuText.statusLine(lastError: .menuChanged, isScannerAnswering: true)
                == "The menu changed on the scanner. Nothing was sent.")
        #expect(MacMenuText.statusLine(lastError: .busy, isScannerAnswering: true) == nil)
        #expect(MacMenuText.statusLine(lastError: nil, isScannerAnswering: true) == nil)
    }

    @Test func standingHintRule() {
        func row(_ text: String, title: Bool = false) -> DisplayRow {
            DisplayRow(segments: [DisplaySegment(text: text, highlighted: false, underlined: title)], large: false)
        }
        let blank = row(String(repeating: " ", count: 30))
        let title = row("       --- M E N U ---", title: true)
        // Six rows on the radio's screen, five in MSI (Analyze omitted): the hint.
        let six = [title] + ["Set Scan Selection", "Set Your Location", "Search for...", "Analyze",
                             "Display Options", "Settings"].map { row($0) } + [blank, blank, blank]
        #expect(MacMenuText.showsMoreItemsHint(displayRows: six, itemCount: 5))
        #expect(MacMenuText.moreItemsHint == "Some items appear only in the Scanner view.")
        // As many rows as items (the title doesn't count): no hint.
        #expect(!MacMenuText.showsMoreItemsHint(displayRows: six, itemCount: 6))
        #expect(!MacMenuText.showsMoreItemsHint(displayRows: [title, row("Set Range")] + Array(repeating: blank, count: 8),
                                                itemCount: 1))
        // Nine or more items: the screen shows nine at a time, so it can't tell. Never.
        let nine = [title] + (0..<9).map { row("Row \($0)") }
        #expect(!MacMenuText.showsMoreItemsHint(displayRows: nine, itemCount: 9))
        #expect(!MacMenuText.showsMoreItemsHint(displayRows: nine, itemCount: 12))
        // No display: never.
        #expect(!MacMenuText.showsMoreItemsHint(displayRows: nil, itemCount: 3))
    }
}
#endif
