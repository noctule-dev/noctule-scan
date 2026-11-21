// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

@Suite("Favorites quick-key types", .timeLimit(.minutes(1)))
struct FavoritesTests {
    private func root(_ xml: String) throws -> NoctuleKit.XMLNode { try NoctuleKit.XMLNode.parse(Data(xml.utf8)) }

    @Test func listsDropTheBuiltIns() throws {
        let node = try root("""
            <?xml version="1.0" encoding="utf-8"?>
            <GLT>
              <FL Index="4294967295" Name="Full Database" Monitor="Off" Q_Key="None" N_Tag="None"/>
              <FL Index="4261412864" Name="Search with Scan" Monitor="Off" Q_Key="None" N_Tag="None"/>
              <FL Index="0" Name="Lakeview Fire" Monitor="On" Q_Key="5" N_Tag="None"/>
              <FL Index="2" Name="Harbor Roads" Monitor="Off" Q_Key="None" N_Tag="None"/>
            </GLT>
            """)
        let lists = try FavoritesXML.lists(node)
        #expect(lists.map(\.index) == [0, 2])
        #expect(lists.map(\.quickKey) == [5, nil])
        #expect(lists.map(\.monitored) == [true, false])
        #expect(lists[0].name == "Lakeview Fire")
    }

    @Test func systemsParseTypeAndAvoid() throws {
        let node = try root("""
            <GLT>
              <SYS Index="118" Name="Fictional P25" Type="P25 Trunk" Q_Key="3" Avoid="On" CountyId="1" N_Tag="None"/>
              <SYS Index="119" Name="Fictional Conv" Type="Conventional" Q_Key="None" Avoid="Off" CountyId="1" N_Tag="None"/>
              <Other Index="1"/>
            </GLT>
            """)
        let systems = try FavoritesXML.systems(node)
        #expect(systems.count == 2)
        #expect(systems[0].avoided)
        #expect(systems[0].type == "P25 Trunk")
        #expect(!systems[0].isConventional)
        #expect(systems[0].quickKey == 3)
        #expect(!systems[1].avoided)
        #expect(systems[1].isConventional)
        #expect(systems[1].quickKey == nil)
    }

    @Test func departmentsDropUnknown() throws {
        let node = try root("""
            <GLT>
              <DEPT Index="4294967295" Name="Unknown" Q_Key="None" Avoid="Off" TGroupId="1"/>
              <DEPT Index="4" Name="Fire Dispatch" Q_Key="2" Avoid="Off" CGroupId="7"/>
              <DEPT Index="5" Name="Road Crews" Q_Key="None" Avoid="On" TGroupId="8"/>
            </GLT>
            """)
        let departments = try FavoritesXML.departments(node)
        #expect(departments.map(\.index) == [4, 5])
        #expect(departments.allSatisfy { $0.kind == .department })
        #expect(departments.map(\.avoided) == [false, true])
        #expect(departments.map(\.quickKey) == [2, nil])
    }

    @Test func sitesAreSites() throws {
        let node = try root("""
            <GLT>
              <SITE Index="9" Name="Hilltop" Q_Key="1" Avoid="Off" SiteId="1"/>
            </GLT>
            """)
        let sites = try FavoritesXML.sites(node)
        #expect(sites.count == 1)
        #expect(sites[0].kind == .site)
        #expect(sites[0].quickKey == 1)
        #expect(sites[0].name == "Hilltop")
    }

    @Test func wrongRootThrows() throws {
        let node = try root("<MSI Name=\"x\"/>")
        #expect(throws: FavoritesXMLError.unexpectedRoot("MSI")) { try FavoritesXML.lists(node) }
        #expect(throws: FavoritesXMLError.unexpectedRoot("MSI")) { try FavoritesXML.sites(node) }
    }

    /// A document of another kind (a late reply to another `GLT`, which answers by command name) is refused, not
    /// read as an empty one: a `DEPT` document answering `GLT,SYS` would otherwise be a list with no systems.
    @Test func aDocumentOfAnotherKindThrows() throws {
        let departments = try root("""
            <GLT>
              <DEPT Index="4" Name="Fire Dispatch" Q_Key="2" Avoid="Off" CGroupId="7"/>
            </GLT>
            """)
        #expect(throws: FavoritesXMLError.self) { try FavoritesXML.systems(departments) }
        #expect(throws: FavoritesXMLError.self) { try FavoritesXML.sites(departments) }
        #expect(throws: FavoritesXMLError.self) { try FavoritesXML.lists(departments) }
        #expect(try FavoritesXML.departments(departments).count == 1)
        let systems = try root("<GLT><SYS Index=\"118\" Name=\"Fictional P25\" Type=\"P25 Trunk\" Q_Key=\"3\"/></GLT>")
        #expect(throws: FavoritesXMLError.self) { try FavoritesXML.departments(systems) }
        let lists = try root("<GLT><FL Index=\"0\" Name=\"Lakeview Fire\" Monitor=\"On\" Q_Key=\"5\"/></GLT>")
        #expect(throws: FavoritesXMLError.self) { try FavoritesXML.systems(lists) }
        let sites = try root("<GLT><SITE Index=\"9\" Name=\"Hilltop\" Q_Key=\"1\"/></GLT>")
        #expect(throws: FavoritesXMLError.self) { try FavoritesXML.departments(sites) }
        // An empty document is still an empty answer.
        #expect(try FavoritesXML.systems(root("<GLT></GLT>")).isEmpty)
    }

    @Test func statesNeedExactly100() {
        let zeros = [String](repeating: "0", count: 100)
        #expect(QuickKeyStates(fields: zeros) != nil)
        #expect(QuickKeyStates(fields: Array(zeros.dropLast())) == nil)
        #expect(QuickKeyStates(fields: zeros + ["0"]) == nil)
        var bad = zeros
        bad[7] = "3"
        #expect(QuickKeyStates(fields: bad) == nil)
    }

    @Test func statesExistingKeys() throws {
        var fields = [String](repeating: "0", count: 100)
        fields[0] = "2"; fields[1] = "1"; fields[3] = "2"
        let states = try #require(QuickKeyStates(fields: fields))
        #expect(states.existingKeys == [0, 1, 3])
        #expect(states[0] == .on)
        #expect(states[1] == .off)
        #expect(states[2] == QuickKeyState.none)
    }

    @Test func settingNamesOneKey() {
        let on = QuickKeyStates.setting(3, on: true)
        #expect(on.count == 100)
        #expect(on[3] == "2")
        #expect(on.enumerated().filter { $0.offset != 3 }.allSatisfy { $0.element == "0" })
        #expect(QuickKeyStates.setting(3, on: false)[3] == "1")
    }

    @Test func arrayCommandValidates() throws {
        #expect(throws: ScannerCommandError.invalidArgument("a,b")) {
            try ScannerCommand("SQK", arguments: ["1", "a,b"])
        }
        let command = try ScannerCommand("fqk", arguments: [String](repeating: "0", count: 101))
        let expected = (["FQK"] + [String](repeating: "0", count: 101)).joined(separator: ",") + "\r"
        #expect(command.wireBytes == Data(expected.utf8))
        #expect(command.arguments.count == 101)
    }
}
