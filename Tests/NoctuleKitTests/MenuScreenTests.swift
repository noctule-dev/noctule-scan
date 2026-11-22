// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

/// The fixtures are the design's §4.3 samples (sanitized names).
@Suite(.timeLimit(.minutes(3))) struct MenuScreenTests {
    private func screen(_ xml: String) throws -> MenuScreen {
        try MenuScreen(xml: XMLNode.parse(Data(xml.utf8)))
    }

    private static let selectLists = """
        <?xml version="1.0" encoding="utf-8"?>
        <MSI Name="Select Lists to Monitor" Index="4293063468" MenuType="TypeSelect" Value="Full Database             :Off" Selected="0" >
          <MenuItem Name="Full Database" Index="0" Value="Off" />
          <MenuItem Name="Search with Scan" Index="1" Value="Off" />
          <MenuItem Name="Lakeview Fire" Index="2" Value="On" />
          <Footer No="1" EOT="1"/>
        </MSI>
        """

    @Test func selectListWithValues() throws {
        let s = try screen(Self.selectLists)
        #expect(s.kind == .select)
        #expect(s.title == "Select Lists to Monitor")
        #expect(s.menuIndex == "4293063468")
        #expect(s.selectedIndex == 0)
        #expect(s.items.count == 3)
        #expect(s.items[0].value == "Off")
        #expect(s.items[2] == MenuScreen.Item(index: 2, name: "Lakeview Fire", value: "On"))
        #expect(s.items[2].id == 2)
    }

    @Test func omittedItemsKeepTheirIndexes() throws {
        let items = (Array(0...7) + Array(9...15)).map { #"<MenuItem Name="Item \#($0)" Index="\#($0)" />"# }.joined(separator: "\n")
        let s = try screen(#"<MSI Name="Main Menu" Index="1" MenuType="TypeSelect" Selected="0" >\#(items)<Footer No="1" EOT="1"/></MSI>"#)
        #expect(!s.items.map(\.index).contains(8))
        #expect(s.items.count == 15)
        #expect(s.items.allSatisfy { $0.value == nil })
    }

    @Test func nameInput() throws {
        let s = try screen("""
            <MSI Name="Edit Name" Index="4293064052" MenuType="TypeInput" Value="Custom 9" >
              <MenuInput MaxLength="64" EnableKeys="ABCxyz1234567890[\\]^_`{|}~!&quot;#$%&amp;&apos;()*+,-./:;&lt;=&gt;?@ " />
              <Footer No="1" EOT="1"/>
            </MSI>
            """)
        #expect(s.kind == .input)
        #expect(s.value == "Custom 9")
        #expect(s.input?.maxLength == 64)
        let allowed = try #require(s.input?.allowedCharacters)
        for c in ["&", "\"", "'", "<", " "] { #expect(allowed.contains(c)) }
        #expect(!allowed.contains("é"))
        #expect(s.input?.addedInformation == nil)
    }

    @Test func numberInput() throws {
        let s = try screen("""
            <MSI Name="Set Range" Index="4293050176" MenuType="TypeInput" Value="30.0" >
              <MenuInput MaxLength="5" AddedInformation="          (mile)" EnableKeys="0123456789." />
              <Footer No="1" EOT="1"/>
            </MSI>
            """)
        #expect(s.value == "30.0")
        #expect(s.input?.maxLength == 5)
        #expect(s.input?.allowedCharacters == "0123456789.")
        #expect(s.input?.addedInformation == "          (mile)")
    }

    @Test func bareError() throws {
        let s = try screen(#"<MSI MenuType="TypeError" ><Footer No="1" EOT="1"/></MSI>"#)
        #expect(s.kind == .error)
        #expect(s.items.isEmpty)
        #expect(s.errorText == nil)
        #expect(s.title == nil)
    }

    @Test func errorWithMessage() throws {
        let s = try screen("""
            <MSI MenuType="TypeError" >
              <MenuErrorMsg Text="The scanner is in state that you can&apos;t remote control.&#xD;Please goto scan mode to remote control." ScanButton="1"  />
              <Footer No="1" EOT="1"/>
            </MSI>
            """)
        #expect(s.kind == .error)
        #expect(s.errorText?.hasPrefix("The scanner is in state that you can't remote control.") == true)
    }

    @Test func unknownTypeIsKept() throws {
        #expect(try screen(#"<MSI Name="X" MenuType="TypeFuture" />"#).kind == .other("TypeFuture"))
        #expect(try screen(#"<MSI Name="X" MenuType="TypeLocation" />"#).kind == .location)
        #expect(try screen(#"<MSI Name="X" />"#).kind == .other(""))
    }

    @Test func footerIsNotAnItem() throws {
        let s = try screen(Self.selectLists)
        #expect(s.items.map(\.name) == ["Full Database", "Search with Scan", "Lakeview Fire"])
    }

    @Test func menuItemNamesKeepCommasAndEntities() throws {
        let s = try screen(#"<MSI Name="Pick" MenuType="TypeSelect" ><MenuItem Name="Fire, North &amp; East" Index="3" /><MenuItem Name="No index" /></MSI>"#)
        #expect(s.items.map(\.name) == ["Fire, North & East"])
    }

    @Test func wrongRootThrows() throws {
        #expect(throws: MenuScreenError.unexpectedRoot("ScannerInfo")) {
            _ = try MenuScreen(xml: XMLNode(name: "ScannerInfo"))
        }
    }
}
