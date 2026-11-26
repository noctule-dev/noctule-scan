// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleKitTestSupport
@testable import NoctuleMockScanner

// The control core driven directly, with no socket or pseudo-terminal: what it sends, to which
// peer, under each personality. Scenario time is a stepped clock; push timing is real time (as in
// `MockControlServerTests`), so push waits are bounded polls.

/// Every send, in order.
private final class SendLog: Sendable {
    let items = Mutex<[(data: Data, peer: ControlPeer)]>([])
}

/// A `ControlCore` whose `sendToPeer` records every send, in order.
private final class CoreRig: Sendable {
    let core: ControlCore
    let clock: MockClock
    private let sent = SendLog()

    init(_ personality: MockPersonality, at time: Double = 3, scenario: MockScenario = .default) {
        clock = MockClock.stepped(at: time)
        core = ControlCore(scenario: scenario, clock: clock, rebootDuration: .milliseconds(200), personality: personality)
        core.sendToPeer = { [sent] data, peer in sent.items.withLock { $0.append((data, peer)) } }
    }

    /// Every send so far, oldest first.
    var all: [(data: Data, peer: ControlPeer)] { sent.items.withLock { $0 } }

    /// Hands `command` to the core (on its queue) and returns what it sent while handling it. The
    /// count is taken on the core's queue too: a push the timer sent between a count taken outside
    /// it and the handling was counted as a reply (it failed so under the background clamp).
    @discardableResult
    func send(_ command: String, from peer: ControlPeer = .stream) -> [Data] {
        core.sync { [sent] core in
            let before = sent.items.withLock { $0.count }
            core.receive(command, from: peer)
            return sent.items.withLock { Array($0[before...]) }.map(\.data)
        }
    }

    /// The one reply to `command`, as text.
    func reply(_ command: String, from peer: ControlPeer = .stream) -> String? {
        let replies = send(command, from: peer)
        #expect(replies.count == 1, "\(command): \(replies.count) replies")
        return replies.first.map { String(decoding: $0, as: UTF8.self) }
    }

    func pushes(to peer: ControlPeer) -> [Data] {
        all.filter { $0.peer == peer && $0.data.starts(with: Data("PSI,<XML>,".utf8)) }.map(\.data)
    }

    func stop() { core.sync { $0.cancelSubscriptions() } }
}

/// Fictional conventional traffic (no talkgroups) in the shape of `sds150-gsi-serial.txt`: one
/// channel with no tone at 2-5 s, one unprogrammed channel with a tone at 7-10 s.
private let conventionalScenario = MockScenario(
    idle: MockIdle(system: "County Roads", site: "County Roads Site", frequencyMHz: 155.0125),
    transmissions: [
        MockTransmission(at: 2, duration: 3, system: "County Roads", department: "Road Crews",
                         channel: "Plow Dispatch", frequencyMHz: 155.0125, rssi: -70),
        MockTransmission(at: 7, duration: 3, system: "County Roads", department: "Road Crews",
                         channel: "Grader Ops", frequencyMHz: 155.1625, modulation: "FM",
                         toneOrCode: "CTCSS 100.0Hz", rssi: -84, programmed: false),
    ])

/// At least three more pushes to the stream peer arrive (bounded).
private func expectPushing(_ rig: CoreRig, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let before = rig.pushes(to: .stream).count
    do {
        try await eventually { rig.pushes(to: .stream).count >= before + 3 }
    } catch {
        Issue.record("pushes stopped at scenario time \(rig.clock.now)", sourceLocation: sourceLocation)
        throw error
    }
}

/// No push to the stream peer arrives for 250 ms (after 60 ms for one already on its way).
private func expectNotPushing(_ rig: CoreRig, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    try await Task.sleep(for: .milliseconds(60))
    let before = rig.pushes(to: .stream).count
    try await Task.sleep(for: .milliseconds(250))
    #expect(rig.pushes(to: .stream).count == before, "pushes went on at scenario time \(rig.clock.now)",
            sourceLocation: sourceLocation)
}

/// Feeds `bytes` to a fresh `SerialResponseAssembler`.
private func assemble(_ bytes: Data) -> [ScannerResponse] {
    var assembler = SerialResponseAssembler()
    return assembler.ingest(bytes)
}

@Suite(.timeLimit(.minutes(1))) struct MockPersonalityTests {
    // MARK: The SDS200 form is today's, byte for byte

    /// Captured from the UDP `MockControlServer` before the core was made peer-neutral (default
    /// scenario, stepped clock at 3 s: the first transmission is on the air).
    @Test func sds200Unchanged() {
        let rig = CoreRig(.sds200)
        let peer = ControlPeer.udp(key: "client")
        #expect(rig.reply("MDL", from: peer) == "MDL,SDS200\r")
        #expect(rig.reply("VER", from: peer) == "VER,Version 1.26.01\r")
        #expect(rig.reply("GSI", from: peer) == "GSI,<XML>,\r<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ScannerInfo Mode=\"Trunk Scan\" V_Screen=\"trunk_scan\">\n<MonitorList Name=\"Mock Favorites\" Index=\"1\" ListType=\"FL\" Q_Key=\"0\" N_Tag=\"None\" DB_Counter=\"0\"/>\n<System Name=\"Riverbend County P25\" Index=\"101\" Avoid=\"Off\" SystemType=\"P25 Trunk\" Q_Key=\"0\" N_Tag=\"None\" Hold=\"Off\"/>\n<Department Name=\"Lakeview Fire\" Index=\"200\" Avoid=\"Off\" Q_Key=\"0\" Hold=\"Off\"/>\n<TGID Name=\"Lakeview Fire Dispatch\" Index=\"1000\" Avoid=\"Off\" TGID=\"TGID:1201\" SetSlot=\"Slot Any\" RecSlot=\"Slot None\" N_Tag=\"None\" Hold=\"Off\" P_Ch=\"Off\" LVL=\"0\"/>\n<UnitID Name=\"UID:4101\" U_Id=\"UID:4101\"/>\n<Site Name=\"Riverbend Simulcast\" Index=\"301\" Avoid=\"Off\" Q_Key=\"None\" Hold=\"Off\" Mod=\"NFM\"/>\n<SiteFrequency Freq=\" 851.237500MHz\" IFX=\"Off\" SAS=\"NAC Search\" SAD=\"NAC 2A1h\"/>\n<DualWatch PRI=\"Off\" CC=\"Off\" WX=\"Off\"/>\n<Property F=\"Off\" VOL=\"2\" SQL=\"1\" Sig=\"5\" Att=\"Off\" Rec=\"Off\" KeyLock=\"Off\" P25Status=\"PT1\" Mute=\"Unmute\" Backlight=\"100\" A_Led=\"Off\" Dir=\"Up\" Rssi=\"-62\"/>\n<ViewDescription></ViewDescription>\n</ScannerInfo>\r")
        // Beyond the brief's three: the MSI form keeps its Footer, and GCS is unknown.
        #expect(rig.reply("MSI", from: peer) == "MSI,<XML>,\r<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<MSI MenuType=\"TypeError\" >\n<Footer No=\"1\" EOT=\"1\"/>\n</MSI>\r")
        #expect(rig.reply("GCS", from: peer) == "ERR\r")
        #expect(rig.all.allSatisfy { $0.peer == peer })
    }

    @Test func sds200KeepsItsLevelRanges() {
        let rig = CoreRig(.sds200)
        #expect(rig.reply("VOL,29") == "VOL,OK\r")
        #expect(rig.reply("VOL,30") == "VOL,NG\r")
        #expect(rig.reply("SQL,19") == "SQL,OK\r")
        #expect(rig.reply("SQL,20") == "SQL,NG\r")
        #expect(rig.reply("VOL") == "VOL,29\r")
        #expect(rig.reply("SQL") == "SQL,19\r")
    }

    @Test func personalityValues() {
        let sds150 = MockPersonality.sds150
        #expect(sds150.reportedModel == "SDS150")
        #expect(sds150.firmware == "Version 1.01.02")
        #expect(sds150.volumeRange == 0...15)
        #expect(sds150.squelchRange == 0...15)
        #expect(!sds150.xmlFooter)
        #expect(sds150.chargeStatusReply == "GCS,CST=4,VOLT=4184mV:100%,CURR=0000mA,TEMP= 27.65C")
        #expect(!sds150.restartReboots)
        let sds200 = MockPersonality.sds200
        #expect(sds200.reportedModel == "SDS200")
        #expect(sds200.firmware == "Version 1.26.01")
        #expect(sds200.volumeRange == 0...29)
        #expect(sds200.squelchRange == 0...19)
        #expect(sds200.xmlFooter)
        #expect(sds200.chargeStatusReply == nil)
        #expect(sds200.restartReboots)
    }

    /// A conventional transmission on the SDS200 takes the form the SDS200 used on hardware
    /// (2026-11-13, Plan 8 Task 12 Step 3.4), the SDS150's: `Freq`, `Mod` and `SAD` on
    /// `ConvFrequency` with its `TGID`/`U_Id` placeholders, no `Site` or `SiteFrequency`, under
    /// `Mode="Scan Mode" V_Screen="conventional_scan"`; `\n` line breaks as over UDP.
    @Test func sds200ConventionalTakesTheHardwareForm() throws {
        let rig = CoreRig(.sds200, at: 3, scenario: conventionalScenario)
        let peer = ControlPeer.udp(key: "client")
        #expect(rig.reply("GSI", from: peer) == "GSI,<XML>,\r<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ScannerInfo Mode=\"Scan Mode\" V_Screen=\"conventional_scan\">\n<MonitorList Name=\"Mock Favorites\" Index=\"1\" ListType=\"FL\" Q_Key=\"0\" N_Tag=\"None\" DB_Counter=\"0\"/>\n<System Name=\"County Roads\" Index=\"101\" Avoid=\"Off\" SystemType=\"Conventional\" Q_Key=\"0\" N_Tag=\"None\" Hold=\"Off\"/>\n<Department Name=\"Road Crews\" Index=\"200\" Avoid=\"Off\" Q_Key=\"0\" Hold=\"Off\"/>\n<ConvFrequency Name=\"Plow Dispatch\" Index=\"1000\" Avoid=\"Off\" Freq=\"  155.012500MHz\" Mod=\"NFM\" N_Tag=\"None\" Hold=\"Off\" P_Ch=\"Off\" SAS=\"All\" SAD=\"None\" RecSlot=\"Slot None\" LVL=\"0\" IFX=\"Off\" TGID=\"TGID None\" U_Id=\"UID None\"/>\n<DualWatch PRI=\"Off\" CC=\"Off\" WX=\"Off\"/>\n<Property F=\"Off\" VOL=\"2\" SQL=\"1\" Sig=\"4\" Att=\"Off\" Rec=\"Off\" KeyLock=\"Off\" P25Status=\"PT1\" Mute=\"Unmute\" Backlight=\"100\" A_Led=\"Off\" Dir=\"Up\" Rssi=\"-70\"/>\n<ViewDescription></ViewDescription>\n</ScannerInfo>\r")
        // A tone and an unprogrammed channel, read back as the app reads it.
        rig.clock.set(8)
        let toned = try #require(rig.reply("GSI", from: peer))
        #expect(toned.contains("\n<ConvFrequency Name=\"Grader Ops\" Index=\"4294967295\" Avoid=\"Off\" Freq=\"  155.162500MHz\" Mod=\"FM\" "), "\(toned)")
        #expect(toned.contains(" SAD=\"CTCSS 100.0Hz\" "), "\(toned)")
        #expect(!toned.contains("<Site") && !toned.contains("<SiteFrequency"), "\(toned)")
        guard case .xml("GSI", let root)? = assemble(Data(toned.utf8)).first else {
            Issue.record("GSI: \(toned)")
            return
        }
        let info = try ScannerInfo(xml: root)
        #expect(info.frequencyMHz == 155.1625)
        #expect(info.modulation == "FM")
        #expect(info.toneOrCode == "CTCSS 100.0Hz")
        #expect(info.site == nil)
        #expect(info.channel?.isProgrammed == false)
        #expect(info.isReceiving)
    }

    // MARK: The SDS150

    /// The SDS150's conventional shape (`sds150-gsi-serial.txt`): `Freq`, `Mod` and `SAD` on
    /// `ConvFrequency`, with its `TGID`/`U_Id` placeholders, and no `Site` or `SiteFrequency`.
    @Test func sds150ConventionalShape() throws {
        let rig = CoreRig(.sds150, at: 3, scenario: conventionalScenario)
        let gsi = try #require(rig.reply("GSI"))
        #expect(gsi.contains("\r<ScannerInfo Mode=\"Scan Mode\" V_Screen=\"conventional_scan\">\r"))
        #expect(gsi.contains("\r<ConvFrequency Name=\"Plow Dispatch\" Index=\"1000\" Avoid=\"Off\" Freq=\"  155.012500MHz\" Mod=\"NFM\" N_Tag=\"None\" Hold=\"Off\" P_Ch=\"Off\" SAS=\"All\" SAD=\"None\" RecSlot=\"Slot None\" LVL=\"0\" IFX=\"Off\" TGID=\"TGID None\" U_Id=\"UID None\"/>\r"), "\(gsi)")
        #expect(!gsi.contains("<SiteFrequency"))
        #expect(!gsi.contains("<Site "))
        #expect(!gsi.contains("<TGID"))

        guard case .xml("GSI", let root)? = assemble(Data(gsi.utf8)).first else {
            Issue.record("GSI: \(gsi)")
            return
        }
        let info = try ScannerInfo(xml: root)
        #expect(info.channel?.name == "Plow Dispatch")
        #expect(info.frequencyMHz == 155.0125)
        #expect(info.modulation == "NFM")
        #expect(info.toneOrCode == nil)
        #expect(info.talkgroupID == nil)
        #expect(info.unitID == nil)
        #expect(!info.isTrunk)
        #expect(info.hasActiveChannel)
        #expect((info.signalBars ?? 0) > 0)
        #expect(info.isReceiving)

        // A tone and an unprogrammed channel.
        rig.clock.set(8)
        let toned = try #require(rig.reply("GSI"))
        #expect(toned.contains("<ConvFrequency Name=\"Grader Ops\" Index=\"4294967295\" Avoid=\"Off\" Freq=\"  155.162500MHz\" Mod=\"FM\" "))
        #expect(toned.contains(" SAD=\"CTCSS 100.0Hz\" "))
        guard case .xml("GSI", let tonedRoot)? = assemble(Data(toned.utf8)).first else {
            Issue.record("GSI: \(toned)")
            return
        }
        let second = try ScannerInfo(xml: tonedRoot)
        #expect(second.frequencyMHz == 155.1625)
        #expect(second.toneOrCode == "CTCSS 100.0Hz")
        #expect(second.channel?.isProgrammed == false)

        // The idle state is the SDS150's conventional scan (`sds150IdleIsAConventionalScan`).
        rig.clock.set(0)
        let idle = try #require(rig.reply("GSI"))
        #expect(idle.contains("<ScannerInfo Mode=\"Scan Mode\" V_Screen=\"conventional_scan\">"))
        #expect(!idle.contains("<SiteFrequency"))
    }

    @Test func idleForms() {
        #expect(MockPersonality.sds200.idleForm == .trunkSite)
        #expect(MockPersonality.sds150.idleForm == .conventionalScan)
    }

    /// The SDS150 idles as it did on hardware (`sds150-gsi-serial.txt`): stepping through
    /// conventional channels, each named with its frequency, `Sig="0"`, one per scenario second.
    @Test func sds150IdleIsAConventionalScan() throws {
        // Idle until 10 s.
        let scenario = MockScenario(idle: MockScenario.default.idle, transmissions: [
            MockTransmission(at: 10, duration: 2, system: "Riverbend County P25", department: "Lakeview Fire",
                             channel: "Lakeview Fire Dispatch", tgid: "1201", frequencyMHz: 851.2375),
        ])
        let rig = CoreRig(.sds150, at: 0, scenario: scenario)
        let expected = [("Plow Dispatch", 155.0125), ("Salt Shed", 155.7525), ("Road Crew 2", 156.015),
                        ("Plow Dispatch", 155.0125)]
        for (second, (name, mhz)) in expected.enumerated() {
            rig.clock.set(Double(second) + 0.5)
            let gsi = try #require(rig.reply("GSI"))
            #expect(gsi.contains("\r<ScannerInfo Mode=\"Scan Mode\" V_Screen=\"conventional_scan\">\r"), "\(gsi)")
            #expect(gsi.contains(#"<System Name="County Roads" "#), "\(gsi)")
            #expect(gsi.contains(#" SystemType="Conventional" "#), "\(gsi)")
            #expect(gsi.contains(#"<Department Name="Road Crews" "#), "\(gsi)")
            #expect(gsi.contains(#" SAD="None" "#) && gsi.contains(#" TGID="TGID None" U_Id="UID None"/>"#), "\(gsi)")
            #expect(gsi.contains(String(format: #" Freq="%12.6fMHz" Mod="NFM" "#, mhz)), "\(gsi)")
            #expect(gsi.contains(#" Sig="0" "#) && gsi.contains(#" P25Status="None" Mute="Mute" "#)
                    && gsi.contains(#" Rssi="-999"/>"#), "\(gsi)")
            #expect(gsi.contains("\r<ViewDescription>\r<OverWrite Text=\"Scanning...\" />\r</ViewDescription>\r"), "\(gsi)")
            #expect(!gsi.contains("<Site "))
            #expect(!gsi.contains("<SiteFrequency"))
            #expect(!gsi.contains("<TGID"))
            #expect(!gsi.contains("\n"))

            guard case .xml("GSI", let root)? = assemble(Data(gsi.utf8)).first else {
                Issue.record("GSI: \(gsi)")
                return
            }
            let info = try ScannerInfo(xml: root)
            #expect(info.channel?.name == name)
            #expect(info.frequencyMHz == mhz)
            #expect(info.signalBars == 0)
            #expect(info.mode == "Scan Mode")
            #expect(info.screen == "conventional_scan")
            #expect(info.system?.name == "County Roads")
            #expect(info.department?.name == "Road Crews")
            #expect(info.toneOrCode == nil)
            #expect(info.talkgroupID == nil)
            #expect(info.hasActiveChannel)
            #expect(!info.isReceiving)
        }

        // A transmission still has its own form.
        rig.clock.set(10.5)
        let live = try #require(rig.reply("GSI"))
        #expect(live.contains("<TGID Name=\"Lakeview Fire Dispatch\""))

        // The SDS200 idles on its trunk site, as before.
        let sds200 = CoreRig(.sds200, at: 0.5, scenario: scenario)
        let trunk = try #require(sds200.reply("GSI", from: .udp(key: "client")))
        #expect(trunk.contains("<ScannerInfo Mode=\"Trunk Scan\" V_Screen=\"trunk_scan\">"))
        #expect(trunk.contains("<SiteFrequency Freq=\" 851.012500MHz\""))
    }

    /// The SDS200's idle document, byte for byte as before the SDS150's idle form was added.
    @Test func sds200IdleUnchanged() {
        let rig = CoreRig(.sds200, at: 0.5)
        #expect(rig.reply("GSI", from: .udp(key: "client")) == "GSI,<XML>,\r<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ScannerInfo Mode=\"Trunk Scan\" V_Screen=\"trunk_scan\">\n<MonitorList Name=\"Mock Favorites\" Index=\"1\" ListType=\"FL\" Q_Key=\"0\" N_Tag=\"None\" DB_Counter=\"0\"/>\n<System Name=\"Riverbend County P25\" Index=\"101\" Avoid=\"Off\" SystemType=\"P25 Trunk\" Q_Key=\"0\" N_Tag=\"None\" Hold=\"Off\"/>\n<Site Name=\"Riverbend Simulcast\" Index=\"301\" Avoid=\"Off\" Q_Key=\"None\" Hold=\"Off\" Mod=\"NFM\"/>\n<SiteFrequency Freq=\" 851.012500MHz\" IFX=\"Off\" SAS=\"NAC Search\" SAD=\"\"/>\n<DualWatch PRI=\"Off\" CC=\"Off\" WX=\"Off\"/>\n<Property F=\"Off\" VOL=\"2\" SQL=\"1\" Sig=\"0\" Att=\"Off\" Rec=\"Off\" KeyLock=\"Off\" P25Status=\"PT1\" Mute=\"Unmute\" Backlight=\"100\" A_Led=\"Off\" Dir=\"Up\" Rssi=\"-999\"/>\n<ViewDescription></ViewDescription>\n</ScannerInfo>\r")
    }

    @Test func sds150TrunkTransmissionKeepsTheSDS200Shape() throws {
        let rig = CoreRig(.sds150)
        let gsi = try #require(rig.reply("GSI"))
        #expect(gsi.contains("<TGID Name=\"Lakeview Fire Dispatch\""))
        #expect(gsi.contains("<SiteFrequency Freq=\" 851.237500MHz\" IFX=\"Off\" SAS=\"NAC Search\" SAD=\"NAC 2A1h\"/>"))
        #expect(!gsi.contains("<ConvFrequency"))
    }

    @Test func sds150Identity() {
        let rig = CoreRig(.sds150)
        #expect(rig.reply("MDL") == "MDL,SDS150\r")
        #expect(rig.reply("VER") == "VER,Version 1.01.02\r")
    }

    @Test func sds150Levels() {
        let rig = CoreRig(.sds150)
        #expect(rig.reply("VOL,15") == "VOL,OK\r")
        #expect(rig.reply("VOL") == "VOL,15\r")
        #expect(rig.reply("VOL,16") == "VOL,NG\r")
        #expect(rig.reply("VOL") == "VOL,15\r")
        #expect(rig.reply("VOL,-1") == "VOL,NG\r")
        #expect(rig.reply("VOL") == "VOL,15\r")
        #expect(rig.reply("SQL,15") == "SQL,OK\r")
        #expect(rig.reply("SQL,16") == "SQL,NG\r")
        #expect(rig.reply("SQL") == "SQL,15\r")
        #expect(rig.core.sync { ($0.volume, $0.squelch) } == (15, 15))
    }

    @Test func sds150GSIHasNoFooter() throws {
        let rig = CoreRig(.sds150)
        let reply = try #require(rig.reply("GSI"))
        #expect(reply.contains("</ScannerInfo>"))
        #expect(!reply.contains("<Footer"))
        #expect(!reply.contains("<Foot"))
    }

    @Test func sds150MSIHasNoFooter() throws {
        let rig = CoreRig(.sds150)
        let outside = try #require(rig.reply("MSI"))
        #expect(outside.contains("</MSI>"))
        #expect(!outside.contains("<Foot"))
        #expect(rig.reply("KEY,M,P") == "KEY,OK\r")
        let inside = try #require(rig.reply("MSI"))
        #expect(inside.contains("MenuType=\"TypeSelect\""))
        #expect(!inside.contains("<Foot"))
    }

    /// Spec §3.2: on serial the document is CR-separated lines, the root's close on its own line.
    @Test func sds150XMLIsCRSeparatedLines() throws {
        let rig = CoreRig(.sds150)
        let gsi = try #require(rig.reply("GSI"))
        #expect(gsi.hasPrefix("GSI,<XML>,\r<?xml version=\"1.0\" encoding=\"utf-8\"?>\r<ScannerInfo "))
        #expect(gsi.hasSuffix("\r</ScannerInfo>\r"))
        #expect(!gsi.contains("\n"))
        let msi = try #require(rig.reply("MSI"))
        #expect(msi.hasSuffix("\r</MSI>\r"))
        #expect(!msi.contains("\n"))
    }

    @Test func sds150SerialFormAssembles() async throws {
        let rig = CoreRig(.sds150)
        defer { rig.stop() }

        let gsi = assemble(try #require(rig.send("GSI").first))
        #expect(gsi.count == 1)
        guard case .xml("GSI", let root)? = gsi.first else {
            Issue.record("GSI: \(gsi)")
            return
        }
        let info = try ScannerInfo(xml: root)
        #expect(info.channel?.name == MockScenario.default.transmissions[0].channel)
        #expect(info.volume == 2)

        #expect(rig.reply("PSI,50") == "PSI,OK\r")
        try await eventually { !rig.pushes(to: .stream).isEmpty }
        let push = assemble(try #require(rig.pushes(to: .stream).first))
        #expect(push.count == 1)
        guard case .xml("PSI", let pushRoot)? = push.first else {
            Issue.record("PSI: \(push)")
            return
        }
        #expect(try ScannerInfo(xml: pushRoot).channel?.name == MockScenario.default.transmissions[0].channel)
        #expect(rig.reply("PSI,0") == "PSI,OK\r")

        #expect(rig.reply("KEY,M,P") == "KEY,OK\r")
        let msi = assemble(try #require(rig.send("MSI").first))
        #expect(msi.count == 1)
        guard case .xml("MSI", let msiRoot)? = msi.first else {
            Issue.record("MSI: \(msi)")
            return
        }
        #expect(try MenuScreen(xml: msiRoot).kind == .select)
    }

    @Test func sds150ChargeStatus() {
        let rig = CoreRig(.sds150)
        #expect(rig.reply("GCS") == "GCS,CST=4,VOLT=4184mV:100%,CURR=0000mA,TEMP= 27.65C\n")
        // Every other reply still ends in `\r`.
        #expect(rig.reply("MDL") == "MDL,SDS150\r")
    }

    @Test func sds150RestartRefused() async throws {
        let rig = CoreRig(.sds150)
        defer { rig.stop() }
        #expect(rig.reply("KEY,M,P") == "KEY,OK\r")
        #expect(rig.reply("PSI,50") == "PSI,OK\r")

        #expect(rig.reply("MSM,1") == "MSM,NG\r")
        #expect(!rig.core.sync { $0.rebooting })
        // Nothing else happens: the menu and the subscription stay, and control answers.
        #expect(rig.core.sync { $0.menu.isActive })
        #expect(rig.core.sync { $0.subscribers.count } == 1)
        #expect(rig.reply("MDL") == "MDL,SDS150\r")
        let before = rig.pushes(to: .stream).count
        try await eventually { rig.pushes(to: .stream).count >= before + 2 }
        #expect(rig.core.sync { $0.log }.filter { $0.hasPrefix("MSM") } == ["MSM,1"])
    }

    // MARK: The push lifetime and `KAL`

    @Test func pushLifetimeValues() {
        #expect(MockPersonality.sds150.pushLifetime == 183)
        #expect(MockPersonality.sds150.pushLifetimeRestarts == ["KAL"])
        #expect(MockPersonality.sds150.silentCommands == ["KAL"])
        #expect(MockPersonality.sds200.pushLifetime == nil)
        #expect(MockPersonality.sds200.pushLifetimeRestarts == [])
        #expect(MockPersonality.sds200.silentCommands == [])
    }

    /// `KAL` on the SDS150: logged, and no reply at all [spec].
    @Test func sds150KeepAliveHasNoReply() {
        let rig = CoreRig(.sds150)
        #expect(rig.send("KAL").isEmpty)
        #expect(rig.send("kal").isEmpty)
        #expect(rig.reply("MDL") == "MDL,SDS150\r")
        #expect(rig.core.sync { $0.log } == ["KAL", "kal", "MDL"])
        #expect(rig.core.sync { $0.subscribers.isEmpty })
    }

    /// The SDS200 answers `KAL` as it answers any command it doesn't know, as before.
    @Test func sds200AnswersKeepAliveAsAnUnknownCommand() {
        let rig = CoreRig(.sds200)
        let peer = ControlPeer.udp(key: "client")
        #expect(rig.reply("KAL", from: peer) == "ERR\r")
        #expect(rig.reply("KAL") == "ERR\r")
    }

    /// Pushes stop once 183 s of scenario time have passed since the `PSI`; the subscription
    /// itself stays.
    @Test func sds150PushesStopAfterTheirLifetime() async throws {
        let rig = CoreRig(.sds150, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        try await expectPushing(rig)
        rig.clock.set(183)
        try await expectPushing(rig)
        rig.clock.set(183.5)
        try await expectNotPushing(rig)
        #expect(rig.core.sync { $0.subscribers.count } == 1)
        #expect(rig.reply("MDL") == "MDL,SDS150\r")
        try await expectNotPushing(rig)
    }

    /// `KAL` restarts the lifetime (on hardware `KAL` every 60 s kept the pushes going for 5
    /// minutes; that each one restarts it is assumed): pushes go on until 183 s after the latest
    /// `KAL`.
    @Test func keepAliveRestartsTheLifetime() async throws {
        let rig = CoreRig(.sds150, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        rig.clock.set(100)
        #expect(rig.send("KAL").isEmpty)
        rig.clock.set(250)
        try await expectPushing(rig)
        rig.clock.set(283)
        try await expectPushing(rig)
        rig.clock.set(283.5)
        try await expectNotPushing(rig)
    }

    /// Other commands don't restart it (the cautious assumption: the client must send `KAL`).
    @Test func otherCommandsDontRestartTheLifetime() async throws {
        let rig = CoreRig(.sds150, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        rig.clock.set(100)
        for command in ["MDL", "VER", "GSI", "STS", "VOL", "SQL", "GCS"] { _ = rig.send(command) }
        rig.clock.set(184)
        try await expectNotPushing(rig)
    }

    /// After the pushes stopped: a `KAL` starts them again (the rule read literally; an
    /// assumption), and so does a new `PSI` (seen on hardware).
    @Test func pushesStartAgainAfterKeepAliveOrNewPSI() async throws {
        let rig = CoreRig(.sds150, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        rig.clock.set(200)
        try await expectNotPushing(rig)
        #expect(rig.send("KAL").isEmpty)
        try await expectPushing(rig)
        rig.clock.set(400)
        try await expectNotPushing(rig)
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        try await expectPushing(rig)
        #expect(rig.core.sync { $0.subscribers.count } == 1)
    }

    /// A personality whose lifetime `KAL` doesn't restart (for the hardware check's failing case).
    @Test func lifetimeWithoutRestartsIgnoresKeepAlive() async throws {
        var personality = MockPersonality.sds150
        personality.pushLifetimeRestarts = []
        let rig = CoreRig(personality, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        rig.clock.set(100)
        #expect(rig.send("KAL").isEmpty)
        rig.clock.set(184)
        try await expectNotPushing(rig)
    }

    /// The SDS200 has no lifetime: pushes go on whatever the scenario time.
    @Test func sds200PushesNeverStop() async throws {
        let rig = CoreRig(.sds200, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        rig.clock.set(100_000)
        try await expectPushing(rig)
    }

    /// `KAL` with no subscription does nothing, and `PSI,0` still ends one.
    @Test func keepAliveWithoutASubscription() async throws {
        let rig = CoreRig(.sds150, at: 0)
        defer { rig.stop() }
        #expect(rig.send("KAL").isEmpty)
        #expect(rig.core.sync { $0.subscribers.isEmpty })
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        #expect(rig.reply("PSI,0") == "PSI,OK\r")
        #expect(rig.send("KAL").isEmpty)
        #expect(rig.core.sync { $0.subscribers.isEmpty })
        try await expectNotPushing(rig)
    }

    // MARK: The SDS100 (design `2026-11-16-sds100-usb-design.md` §5.4)

    @Test func sds100Identity() {
        let rig = CoreRig(.sds100)
        #expect(rig.reply("MDL") == "MDL,SDS100\r")
        #expect(rig.reply("VER") == "VER,Version 1.26.01\r")
        let sds100 = MockPersonality.sds100
        #expect(sds100.volumeRange == 0...15)
        #expect(sds100.squelchRange == 0...15)
        #expect(!sds100.xmlFooter)
        #expect(sds100.xmlLineBreak == "\r")
        #expect(sds100.chargeStatusReply == nil)
        #expect(!sds100.restartReboots)
        #expect(sds100.pushLifetime == 183)
        #expect(sds100.pushLifetimeRestarts == [])
        #expect(sds100.silentCommands == [])
        #expect(sds100.keepAliveRevivesStoppedPushes)
        #expect(sds100.displayGlyphBytes == [0x06, 0x07, 0x1A, 0x1B])
    }

    @Test func sds100Levels() {
        let rig = CoreRig(.sds100)
        #expect(rig.reply("VOL,15") == "VOL,OK\r")
        #expect(rig.reply("VOL,16") == "VOL,NG\r")
        #expect(rig.reply("VOL") == "VOL,15\r")
        #expect(rig.reply("SQL,15") == "SQL,OK\r")
        #expect(rig.reply("SQL,16") == "SQL,NG\r")
        #expect(rig.reply("SQL") == "SQL,15\r")
        #expect(rig.core.sync { ($0.volume, $0.squelch) } == (15, 15))
    }

    /// The SDS150's serial form: CR-separated lines, no `<Footer>`, for `GSI` and `MSI` alike.
    @Test func sds100XMLTakesTheSerialForm() throws {
        let rig = CoreRig(.sds100)
        let gsi = try #require(rig.reply("GSI"))
        #expect(gsi.hasPrefix("GSI,<XML>,\r<?xml version=\"1.0\" encoding=\"utf-8\"?>\r<ScannerInfo "))
        #expect(gsi.hasSuffix("\r</ScannerInfo>\r"))
        #expect(!gsi.contains("\n"))
        #expect(!gsi.contains("<Foot"))
        let outside = try #require(rig.reply("MSI"))
        #expect(outside.hasSuffix("\r</MSI>\r"))
        #expect(!outside.contains("\n"))
        #expect(!outside.contains("<Foot"))
        #expect(rig.reply("KEY,M,P") == "KEY,OK\r")
        let inside = try #require(rig.reply("MSI"))
        #expect(inside.contains("MenuType=\"TypeSelect\""))
        #expect(!inside.contains("\n"))
        #expect(!inside.contains("<Foot"))
        guard case .xml("GSI", let root)? = assemble(Data(gsi.utf8)).first else {
            Issue.record("GSI: \(gsi)")
            return
        }
        #expect(try ScannerInfo(xml: root).volume == 2)
    }

    /// `KAL` is an unknown command on the SDS100 [hw]: `ERR`, and it restarts nothing.
    @Test func sds100AnswersKeepAliveWithERR() async throws {
        let rig = CoreRig(.sds100, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("KAL") == "ERR\r")
        #expect(rig.reply("kal") == "ERR\r")
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        rig.clock.set(100)
        #expect(rig.reply("KAL") == "ERR\r")
        rig.clock.set(184)
        try await expectNotPushing(rig)
        #expect(rig.core.sync { $0.subscribers.count } == 1)
    }

    /// No battery reading over serial [hw]: `GCS` gets no usable answer; the mock's `ERR` is assumed.
    @Test func sds100AnswersChargeStatusWithERR() {
        let rig = CoreRig(.sds100)
        #expect(rig.reply("GCS") == "ERR\r")
    }

    /// Never sent by the product; the SDS150 mock's rule: `MSM,NG`, nothing else happens.
    @Test func sds100RestartRefused() async throws {
        let rig = CoreRig(.sds100)
        defer { rig.stop() }
        #expect(rig.reply("KEY,M,P") == "KEY,OK\r")
        #expect(rig.reply("PSI,50") == "PSI,OK\r")
        #expect(rig.reply("MSM,1") == "MSM,NG\r")
        #expect(!rig.core.sync { $0.rebooting })
        #expect(rig.core.sync { $0.menu.isActive })
        #expect(rig.core.sync { $0.subscribers.count } == 1)
        #expect(rig.reply("MDL") == "MDL,SDS100\r")
        let before = rig.pushes(to: .stream).count
        try await eventually { rig.pushes(to: .stream).count >= before + 2 }
    }

    /// Between transmissions it idles as the SDS200 mock does: the scenario's system, `Site` and
    /// `SiteFrequency`, under `Trunk Scan` (one `GSI` of a trunked ID search had this shape [hw]).
    @Test func sds100IdleIsTheTrunkSite() throws {
        #expect(MockPersonality.sds100.idleForm == .trunkSite)
        let rig = CoreRig(.sds100, at: 0)
        let gsi = try #require(rig.reply("GSI"))
        #expect(gsi.contains("\r<ScannerInfo Mode=\"Trunk Scan\" V_Screen=\"trunk_scan\">\r"), "\(gsi)")
        #expect(gsi.contains("\r<Site "), "\(gsi)")
        #expect(gsi.contains("\r<SiteFrequency "), "\(gsi)")
        #expect(!gsi.contains("conventional_scan"))
        guard case .xml("GSI", let root)? = assemble(Data(gsi.utf8)).first else {
            Issue.record("GSI: \(gsi)")
            return
        }
        let info = try ScannerInfo(xml: root)
        #expect(!info.isReceiving)
        #expect(info.site != nil)
    }

    /// An idle `STS`: the SDS200 mock's screen with four icon glyph bytes (0x06, 0x07, 0x1A, 0x1B
    /// [hw]) over columns 0-3 of its first line, one byte per column (assumed).
    @Test func sds100GlyphBytes() throws {
        let sds100 = CoreRig(.sds100, at: 0)
        let sds200 = CoreRig(.sds200, at: 0)
        let ours = try #require(sds100.send("STS").first)
        let theirs = try #require(sds200.send("STS").first)
        let prefix = Data("STS,00001010100000000,".utf8)
        #expect(ours.starts(with: prefix + Data([0x06, 0x07, 0x1A, 0x1B])), "\(ours.prefix(40))")
        #expect(theirs.starts(with: prefix + Data("    ".utf8)), "\(theirs.prefix(40))")
        #expect(ours.count == theirs.count)
        #expect(Data(ours.dropFirst(prefix.count + 4)) == Data(theirs.dropFirst(prefix.count + 4)))
        #expect(ours.filter { $0 < 0x20 && $0 != 0x0D } == Data([0x06, 0x07, 0x1A, 0x1B]))
        // A transmission's screen has none.
        let onAir = CoreRig(.sds100, at: 3)
        let screen = try #require(onAir.send("STS").first)
        #expect(screen.filter { $0 < 0x20 && $0 != 0x0D }.isEmpty, "a transmission's STS carries glyph bytes")
    }

    /// Pushes stop 183 s after the `PSI` (182-186 s on hardware); the subscription stays.
    @Test func sds100PushesStopAfterTheirLifetime() async throws {
        let rig = CoreRig(.sds100, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        try await expectPushing(rig)
        rig.clock.set(183)
        try await expectPushing(rig)
        rig.clock.set(183.5)
        try await expectNotPushing(rig)
        #expect(rig.core.sync { $0.subscribers.count } == 1)
        #expect(rig.reply("MDL") == "MDL,SDS100\r")
        try await expectNotPushing(rig)
    }

    /// The SDS100's keep-alive is the same `PSI` sent again [hw]: it restarts the count and adds
    /// no second subscription (that every `PSI` restarts the full 183 s is assumed). Pushes go on
    /// past 183 s and stop 183 s after the second `PSI`; `PSI,0` leaves none.
    @Test func aPSIWhileSubscribedRestartsTheLifetime() async throws {
        let rig = CoreRig(.sds100, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,100") == "PSI,OK\r")
        rig.clock.set(60)
        #expect(rig.reply("PSI,100") == "PSI,OK\r")
        #expect(rig.core.sync { $0.subscribers.count } == 1)
        rig.clock.set(200)
        try await expectPushing(rig)
        rig.clock.set(243)
        try await expectPushing(rig)
        rig.clock.set(243.5)
        try await expectNotPushing(rig)
        #expect(rig.core.sync { $0.subscribers.count } == 1)
        #expect(rig.reply("PSI,0") == "PSI,OK\r")
        #expect(rig.core.sync { $0.subscribers.count } == 0)
    }

    /// After the pushes stopped, a `PSI` starts them again [hw: a new `PSI` on a reopened port;
    /// on the open port, assumed]: the pessimistic twin of the renewal, which the replace rule
    /// doesn't depend on.
    @Test func aPSIAfterThePushesStoppedStartsThemAgain() async throws {
        let rig = CoreRig(.sds100, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        rig.clock.set(200)
        try await expectNotPushing(rig)
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        try await expectPushing(rig)
        #expect(rig.core.sync { $0.subscribers.count } == 1)
        rig.clock.set(400)
        try await expectNotPushing(rig)
    }

    // MARK: Peers

    @Test func pushesGoToTheSubscribingPeer() async throws {
        let rig = CoreRig(.sds150)
        defer { rig.stop() }
        let other = ControlPeer.udp(key: "other")
        #expect(rig.reply("PSI,50") == "PSI,OK\r")
        #expect(rig.reply("MDL", from: other) == "MDL,SDS150\r")
        try await eventually { rig.pushes(to: .stream).count >= 2 }
        #expect(rig.pushes(to: other).isEmpty)

        // Pushes follow the scenario clock.
        let second = MockScenario.default.transmissions[1]
        rig.clock.set(second.at + 0.5)
        try await eventually {
            guard let last = rig.pushes(to: .stream).last else { return false }
            return String(decoding: last, as: UTF8.self).contains(second.channel)
        }

        // A second subscriber gets its own pushes.
        #expect(rig.reply("PSI,50", from: other) == "PSI,OK\r")
        try await eventually { rig.pushes(to: other).count >= 2 }

        #expect(rig.reply("PSI,0") == "PSI,OK\r")
        #expect(rig.core.sync { Array($0.subscribers.keys) } == [other])
        let stopped = rig.pushes(to: .stream).count
        let otherBefore = rig.pushes(to: other).count
        try await eventually { rig.pushes(to: other).count >= otherBefore + 3 }
        #expect(rig.pushes(to: .stream).count == stopped)
    }
}

// MARK: The BCD436HP (design `2026-11-25-bcd436hp-usb-design.md` §3, §5.7, §5.11)

@Suite(.timeLimit(.minutes(1))) struct MockBCD436HPPersonalityTests {
    @Test func bcdIdentity() {
        let rig = CoreRig(.bcd436hp)
        #expect(rig.reply("MDL") == "MDL,BCD436HP\r")
        #expect(rig.reply("VER") == "VER,Version 1.28.24\r")
        let bcd = MockPersonality.bcd436hp
        #expect(bcd.volumeRange == 0...15)
        #expect(bcd.squelchRange == 0...15)
        #expect(bcd.clampsLevels)
        #expect(bcd.missingKeys == ["T", "Q"])
        #expect(bcd.bcdCommands)
        #expect(bcd.displayForm == .bcd436hp)
        #expect(bcd.displayGlyphBytes.count == 2)
        #expect(!bcd.restartReboots)
        #expect(bcd.pushLifetime == 183)
        #expect(MockPersonality.sds100.displayForm == .sds)
        #expect(!MockPersonality.sds100.clampsLevels)
        #expect(!MockPersonality.sds100.bcdCommands)
    }

    @Test func bcdClampsLevels() {
        let rig = CoreRig(.bcd436hp)
        #expect(rig.reply("VOL,16") == "VOL,OK\r")
        #expect(rig.reply("VOL") == "VOL,15\r")
        #expect(rig.reply("SQL,16") == "SQL,OK\r")
        #expect(rig.reply("SQL") == "SQL,15\r")
        #expect(rig.reply("VOL,7") == "VOL,OK\r")
        #expect(rig.reply("VOL") == "VOL,7\r")
        let sds100 = CoreRig(.sds100)
        #expect(sds100.reply("VOL,16") == "VOL,NG\r")
    }

    @Test func bcdRefusesKeysItHasNot() {
        let bcd = CoreRig(.bcd436hp)
        #expect(bcd.reply("KEY,T,P") == "KEY,NG\r")
        #expect(bcd.reply("KEY,Q,P") == "KEY,NG\r")
        #expect(bcd.reply("KEY,R,P") == "KEY,OK\r")
        #expect(bcd.reply("KEY,M,P") == "KEY,OK\r")
        let sds100 = CoreRig(.sds100)
        #expect(sds100.reply("KEY,T,P") == "KEY,NG\r")
        #expect(sds100.reply("KEY,Q,P") == "KEY,NG\r")
        #expect(sds100.reply("KEY,R,P") == "KEY,OK\r")
        let sds150 = CoreRig(.sds150)
        for key in ["T", "Q", "R"] { #expect(sds150.reply("KEY,\(key),P") == "KEY,NG\r") }
        let sds200 = CoreRig(.sds200)
        for key in ["T", "Q", "R"] { #expect(sds200.reply("KEY,\(key),P") == "KEY,OK\r") }
    }

    @Test func bcdAnswersKALAndGCSWithERR() async throws {
        let rig = CoreRig(.bcd436hp, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("KAL") == "ERR\r")
        #expect(rig.reply("GCS") == "ERR\r")
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        rig.clock.set(100)
        #expect(rig.reply("KAL") == "ERR\r")
        rig.clock.set(184)
        try await expectNotPushing(rig)
    }

    @Test func bcdMSICarriesAFooter() throws {
        let rig = CoreRig(.bcd436hp)
        let msi = try #require(rig.reply("MSI"))
        #expect(msi.contains("<Footer No=\"1\" EOT=\"1\"/>"), "\(msi)")
        #expect(msi.contains("\r"))
        let gsi = try #require(rig.reply("GSI"))
        #expect(!gsi.contains("<Footer"))
    }

    @Test func bcdPushLifetime() async throws {
        let rig = CoreRig(.bcd436hp, at: 0)
        defer { rig.stop() }
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        try await expectPushing(rig)
        rig.clock.set(100)
        #expect(rig.reply("PSI,20") == "PSI,OK\r")
        #expect(rig.core.sync { $0.subscribers.count } == 1)
        rig.clock.set(182)
        try await expectPushing(rig)
        rig.clock.set(284)
        try await expectNotPushing(rig)
        #expect(rig.core.sync { $0.subscribers.count } == 1)
    }
}
