// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKitTestSupport
@testable import NoctuleKit

@Suite(.timeLimit(.minutes(3))) struct ScannerInfoTests {
    @Test func parsesRealTrunkCapture() throws {
        let info = try ScannerInfo(xml: XMLNode.parse(fixture("gsi-trunk-sds200-1.24.00.xml")))
        #expect(info.mode == "Trunk Scan"); #expect(info.screen == "trunk_scan")
        #expect(info.system?.name == "LWPC P25-2"); #expect(info.systemType == "P25 Trunk")
        #expect(info.department?.name == "Unknown"); #expect(info.department?.isProgrammed == false)
        #expect(info.channel?.name == "TGID:9"); #expect(info.channel?.isProgrammed == false)
        #expect(info.talkgroupID == "9"); #expect(info.unitID == "7316")
        #expect(info.site?.name == "northside"); #expect(info.modulation == "NFM")
        #expect(info.frequencyMHz == 935.4375); #expect(info.toneOrCode == "NAC 2B4h")
        #expect(info.rssi == -69); #expect(info.signalBars == 5)
        #expect(info.volume == 2); #expect(info.squelch == 1)
        #expect(info.attenuatorOn == false); #expect(info.recordingOn == false); #expect(info.muted == false)
        #expect(info.monitorList?.name == "lakeworks"); #expect(info.monitorList?.isProgrammed == true)
    }

    @Test func functionOnReadsPropertyF() throws {
        func info(_ attr: String) throws -> ScannerInfo {
            try ScannerInfo(xml: XMLNode.parse(Data("<ScannerInfo Mode=\"Scan Mode\" V_Screen=\"conventional_scan\"><Property \(attr)VOL=\"5\"/></ScannerInfo>".utf8)))
        }
        #expect(try info("F=\"On\" ").functionOn == true)
        #expect(try info("F=\"Off\" ").functionOn == false)
        #expect(try info("").functionOn == nil)
    }

    @Test func trunkIsActiveNotWeather() throws {
        let info = try ScannerInfo(xml: XMLNode.parse(fixture("gsi-trunk-sds200-1.24.00.xml")))
        #expect(info.hasActiveChannel); #expect(!info.isWeather)
    }

    @Test func parsesWeatherShape() throws {
        let info = try ScannerInfo(xml: XMLNode.parse(fixture("gsi-wx-sds200-1.26.01.xml")))
        #expect(info.mode == "WX Scan"); #expect(info.screen == "wx_alert")
        #expect(info.channel?.name == "WX 4"); #expect(info.channel?.index == 3)
        #expect(info.channel?.hold == false)
        #expect(info.frequencyMHz == 162.55); #expect(info.modulation == "FM")
        #expect(info.isWeather); #expect(info.hasActiveChannel)
        #expect(info.rssi == -80); #expect(info.signalBars == 2)
    }

    @Test(arguments: [" ---", "TGID: ---", "---"])
    func idlePlaceholdersAreNil(tgid: String) throws {
        let xml = #"<ScannerInfo Mode="Trunk Scan"><Department Name="" Index="4294967295"/><TGID Name="" Index="4294967295" TGID="\#(tgid)"/><UnitID Name="" U_Id="UID: ---"/><Property Rssi="-999"/></ScannerInfo>"#
        let info = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
        #expect(info.talkgroupID == nil); #expect(info.unitID == nil)
        #expect(info.department == nil); #expect(info.rssi == nil)
        #expect(!info.hasActiveChannel)
    }

    @Test func isTrunkFromSystemTypeOrTGIDElement() throws {
        #expect(try ScannerInfo(xml: XMLNode.parse(fixture("gsi-trunk-sds200-1.24.00.xml"))).isTrunk)
        #expect(try !ScannerInfo(xml: XMLNode.parse(fixture("gsi-wx-sds200-1.26.01.xml"))).isTrunk)
        let byType = #"<ScannerInfo><System Name="Test Sys" SystemType="motorola trunk"/></ScannerInfo>"#
        #expect(try ScannerInfo(xml: XMLNode.parse(Data(byType.utf8))).isTrunk)
        let byElement = #"<ScannerInfo><TGID Name="" TGID=" ---"/></ScannerInfo>"#
        #expect(try ScannerInfo(xml: XMLNode.parse(Data(byElement.utf8))).isTrunk)
        let conv = #"<ScannerInfo Mode="Conventional Scan"><System Name="Test Conv" SystemType="Conventional"/><ConvFrequency Name="Test Disp" Index="12"/><SiteFrequency Freq=" 154.250000MHz"/></ScannerInfo>"#
        let c = try ScannerInfo(xml: XMLNode.parse(Data(conv.utf8)))
        #expect(!c.isTrunk); #expect(c.hasActiveChannel)
    }

    /// An idle or ID-searching trunk scanner parked on a control channel reports a `SiteFrequency`
    /// and a signal, but no talkgroup: not an active channel.
    @Test func trunkPlaceholderWithSiteFrequencyIsInactive() throws {
        let xml = #"<ScannerInfo Mode="Trunk Scan"><System Name="Test Sys" SystemType="P25 Trunk"/><TGID Name="" Index="4294967295" TGID=" ---"/><SiteFrequency Freq=" 851.012500MHz"/><Property Sig="3" Rssi="-70"/></ScannerInfo>"#
        let info = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
        #expect(info.isTrunk); #expect(info.frequencyMHz != nil); #expect(!info.hasActiveChannel)
    }

    @Test func unitIDDashesAreNil() throws {
        let xml = #"<ScannerInfo><UnitID Name="" U_Id=" ---"/></ScannerInfo>"#
        #expect(try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8))).unitID == nil)
    }

    @Test func toleratesSparseAndUnknownContent() throws {
        let xml = #"<ScannerInfo Mode="Conventional Scan"><ConvFrequency Name="Fire Disp" Index="12"/><NewThing X="1"/><Property VOL="x"/></ScannerInfo>"#
        let info = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
        #expect(info.channel?.name == "Fire Disp"); #expect(info.channel?.isProgrammed == true)
        #expect(info.system == nil); #expect(info.volume == nil); #expect(info.rssi == nil)
        #expect(info.raw.child("NewThing") != nil)
    }

    // MARK: The SDS150's conventional shape (no SiteFrequency; Freq, Mod, SAD on ConvFrequency)

    /// The SDS150 fixture (`GSI,<XML>,` line dropped): a conventional channel whose frequency,
    /// modulation and tone are attributes of `ConvFrequency` itself.
    private func sds150Conventional() throws -> ScannerInfo {
        let text = String(decoding: fixture("sds150-gsi-serial.txt"), as: UTF8.self)
        let document = try #require(text.split(separator: "\n", maxSplits: 1).last)
        return try ScannerInfo(xml: XMLNode.parse(Data(document.utf8)))
    }

    @Test func sds150ConventionalReadsConvFrequencyAttributes() throws {
        let info = try sds150Conventional()
        #expect(info.channel?.name == "Plow Dispatch")
        #expect(info.frequencyMHz == 155.0125)
        #expect(info.modulation == "NFM")
        #expect(!info.isTrunk)
        #expect(info.hasActiveChannel)
        // `TGID="TGID None"` and `U_Id="UID None"` on ConvFrequency are placeholders, not IDs.
        #expect(info.talkgroupID == nil)
        #expect(info.unitID == nil)
        // `SAD="None"` is the SDS150's placeholder for no tone.
        #expect(info.toneOrCode == nil)
        #expect(info.signalBars == 0)
    }

    /// `SAD="None"` (any case) reads the same from either element: no tone or code.
    @Test(arguments: ["None", "none", " NONE "])
    func sadNoneReadsTheSameOnSiteFrequency(sad: String) throws {
        let xml = #"<ScannerInfo><System Name="Test Conv" SystemType="Conventional"/><ConvFrequency Name="Test Disp" Index="12"/><SiteFrequency Freq=" 155.012500MHz" SAD="\#(sad)"/></ScannerInfo>"#
        #expect(try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8))).toneOrCode == nil)
        let conv = #"<ScannerInfo><System Name="Test Conv" SystemType="Conventional"/><ConvFrequency Name="Test Disp" Index="12" Freq=" 155.012500MHz" SAD="\#(sad)"/></ScannerInfo>"#
        #expect(try ScannerInfo(xml: XMLNode.parse(Data(conv.utf8))).toneOrCode == nil)
    }

    /// An SDS150 stepping through its conventional channels names each one with its frequency,
    /// so it has an active channel, but with `Sig="0"` it isn't receiving.
    @Test func sds150ScanningIsNotReceiving() throws {
        let info = try sds150Conventional()
        #expect(info.hasActiveChannel)
        #expect(!info.isReceiving)
        #expect(info.toneOrCode == nil)
        #expect(info.talkgroupID == nil)

        let text = String(decoding: fixture("sds150-gsi-serial.txt"), as: UTF8.self)
        let document = try #require(text.split(separator: "\n", maxSplits: 1).last)
        let receiving = document.replacingOccurrences(of: #"Sig="0""#, with: #"Sig="3""#)
        #expect(receiving != String(document))
        #expect(try ScannerInfo(xml: XMLNode.parse(Data(receiving.utf8))).isReceiving)
    }

    /// The SDS150's `None` placeholders on a trunk document's `TGID` and `UnitID` elements are no
    /// identifier (an assumption until a trunk capture from the SDS150; only the `ConvFrequency`
    /// attributes were seen on hardware).
    @Test func nonePlaceholdersAreNoIdentifier() throws {
        let xml = #"<ScannerInfo Mode="Trunk Scan"><System Name="Test Sys" SystemType="P25 Trunk"/><TGID Name="Test TG" Index="7" TGID="TGID None"/><UnitID Name="" U_Id="UID None"/><SiteFrequency Freq=" 851.012500MHz"/><Property Sig="3"/></ScannerInfo>"#
        let info = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
        #expect(info.talkgroupID == nil)
        #expect(info.unitID == nil)
        #expect(!info.hasActiveChannel)
        #expect(!info.isReceiving)

        let real = xml.replacingOccurrences(of: "TGID None", with: "TGID:1201")
        let live = try ScannerInfo(xml: XMLNode.parse(Data(real.utf8)))
        #expect(live.talkgroupID == "1201")
        #expect(live.hasActiveChannel)
        #expect(live.isReceiving)
    }

    @Test(arguments: ["None", "TGID None", "UID None", " None "])
    func nonePlaceholderSpellings(placeholder: String) throws {
        let xml = #"<ScannerInfo><TGID Name="Test TG" Index="7" TGID="\#(placeholder)"/><UnitID Name="" U_Id="\#(placeholder)"/></ScannerInfo>"#
        let info = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
        #expect(info.talkgroupID == nil)
        #expect(info.unitID == nil)
    }

    /// With both elements present, `SiteFrequency` and `Site` win, as before (the SDS200's shape).
    @Test func siteFrequencyAndSiteWinOverConvFrequency() throws {
        let xml = #"<ScannerInfo><System Name="Test Conv" SystemType="Conventional"/><ConvFrequency Name="Test Disp" Index="12" Freq=" 155.012500MHz" Mod="AM" SAD="CTCSS 67.0Hz"/><Site Name="" Mod="FM"/><SiteFrequency Freq=" 154.250000MHz" SAD="CTCSS 100.0Hz"/></ScannerInfo>"#
        let info = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
        #expect(info.frequencyMHz == 154.25)
        #expect(info.modulation == "FM")
        #expect(info.toneOrCode == "CTCSS 100.0Hz")
        // An unparsable SiteFrequency still gives nil, not the ConvFrequency's value.
        let bad = #"<ScannerInfo><ConvFrequency Name="Test Disp" Freq=" 155.012500MHz"/><SiteFrequency Freq="--"/></ScannerInfo>"#
        #expect(try ScannerInfo(xml: XMLNode.parse(Data(bad.utf8))).frequencyMHz == nil)
    }

    @Test(arguments: ["", "  ", "MHz", "abc", " 155.0125kHz"])
    func unparsableConvFrequencyIsNil(freq: String) throws {
        let xml = #"<ScannerInfo><System Name="Test Conv" SystemType="Conventional"/><ConvFrequency Name="Test Disp" Index="12" Freq="\#(freq)" Mod="NFM"/></ScannerInfo>"#
        let info = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
        #expect(info.frequencyMHz == nil)
        #expect(!info.hasActiveChannel)
        #expect(info.modulation == "NFM")
    }

    @Test func rejectsWrongRoot() {
        #expect(throws: ScannerInfoError.unexpectedRoot("GLT")) {
            try ScannerInfo(xml: XMLNode(name: "GLT", attributes: [:], children: []))
        }
    }

    private func menuInfo(mode: String, screen: String) throws -> ScannerInfo {
        let xml = """
            <ScannerInfo Mode="\(mode)" V_Screen="\(screen)">
              <MenuSummary name="Set Scan Selection" index="4293063672" />
              <ViewDescription>
              </ViewDescription>
            </ScannerInfo>
            """
        return try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
    }

    @Test func menuTreeReportsTitleIndexAndKind() throws {
        let info = try menuInfo(mode: "Menu tree", screen: "menu_selection")
        #expect(info.isMenu)
        #expect(info.menuTitle == "Set Scan Selection")
        #expect(info.menuIndex == "4293063672")
        #expect(info.menuScreenKind == .selection)
        #expect(info.channel == nil)
        #expect(!info.hasActiveChannel)
    }

    @Test func menuInputKind() throws {
        let info = try menuInfo(mode: "Menu tree", screen: "menu_input")
        #expect(info.isMenu)
        #expect(info.menuScreenKind == .input)
    }

    @Test func scanModeIsNotAMenu() throws {
        let info = try ScannerInfo(xml: XMLNode.parse(Data(#"<ScannerInfo Mode="Trunk Scan" V_Screen="trunk_scan"></ScannerInfo>"#.utf8)))
        #expect(!info.isMenu)
        #expect(info.menuTitle == nil)
        #expect(info.menuIndex == nil)
        #expect(info.menuScreenKind == nil)
    }
}
