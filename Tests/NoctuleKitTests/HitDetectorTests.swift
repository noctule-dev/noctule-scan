// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKitTestSupport
@testable import NoctuleKit

/// Fictional, fixture-shaped `ScannerInfo` for a trunk talkgroup (shape of `gsi-trunk-sds200-1.24.00.xml`).
/// `tg: nil` gives the idle placeholder (`TGID=" ---"`, no `SiteFrequency`), which is never an
/// active channel. (A `SiteFrequency` alone would make `hasActiveChannel` true.)
private func info(
    tg: String?, sig: Int, uid: String? = nil, rssi: Int? = -70,
    system: String = "Testville P25", tgIndex: String = "7"
) -> ScannerInfo {
    let tgid = tg.map { "TGID:\($0)" } ?? " ---"
    let name = tg.map { "Test TG \($0)" } ?? ""
    let siteFreq = tg == nil ? "" : #"<SiteFrequency Freq=" 851.012500MHz" IFX="Off" SAS="NAC Search" SAD="NAC 1A2h"/>"#
    let xml = """
        <ScannerInfo Mode="Trunk Scan" V_Screen="trunk_scan">
          <System Name="\(system)" Index="3" Avoid="Off" SystemType="P25 Trunk" Hold="Off"/>
          <Department Name="Test Dept" Index="5" Avoid="Off" Hold="Off"/>
          <TGID Name="\(name)" Index="\(tgIndex)" Avoid="Off" TGID="\(tgid)" Hold="Off"/>
          <UnitID Name="" U_Id="\(uid.map { "UID:\($0)" } ?? "UID: ---")"/>
          <Site Name="testsite" Index="9" Avoid="Off" Hold="Off" Mod="NFM"/>
          \(siteFreq)
          <Property VOL="2" SQL="1" Sig="\(sig)" Rssi="\(rssi ?? -999)"/>
        </ScannerInfo>
        """
    return try! ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

/// Fictional conventional channel (`ConvFrequency`), optionally unprogrammed.
private func convInfo(freq: String, sig: Int, programmed: Bool = true) -> ScannerInfo {
    let index = programmed ? "12" : "4294967295"
    let xml = """
        <ScannerInfo Mode="Conventional Scan" V_Screen="conventional_scan">
          <System Name="Test Conv" Index="4" Avoid="Off" SystemType="Conventional" Hold="Off"/>
          <Department Name="Test Fire" Index="6" Avoid="Off" Hold="Off"/>
          <ConvFrequency Name="Test Disp" Index="\(index)" Avoid="Off" Hold="Off"/>
          <Site Name="" Mod="FM"/>
          <SiteFrequency Freq="\(freq)" SAD="CTCSS 100.0Hz"/>
          <Property VOL="2" SQL="1" Sig="\(sig)" Rssi="-75"/>
        </ScannerInfo>
        """
    return try! ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

/// The SDS150's conventional shape (`sds150-gsi-serial.txt`, fictional values): no `Site` or
/// `SiteFrequency`; frequency, modulation and tone are attributes of `ConvFrequency`. Only `Sig`
/// and `Rssi` vary: what else the SDS150 reports in `Property` during a transmission is unknown.
private func sds150ConvInfo(sig: Int, rssi: Int = -999) -> ScannerInfo {
    let xml = """
        <ScannerInfo Mode="Scan Mode" V_Screen="conventional_scan">
          <MonitorList Name="Lakeview County" Index="0" ListType="FL" Q_Key="5" N_Tag="None" DB_Counter="0" />
          <System Name="County Roads" Index="115" Avoid="Off" SystemType="Conventional" Q_Key="2" N_Tag="None" Hold="Off" />
          <Department Name="Road Crews" Index="118" Avoid="Off" Q_Key="0" Hold="Off" />
          <ConvFrequency Name="Plow Dispatch" Index="120" Avoid="Off" Freq="  155.012500MHz" Mod="NFM" N_Tag="None" Hold="Off" SvcType="Public Works" P_Ch="Off" SAS="All" SAD="None" RecSlot="Slot None" LVL="0" IFX="Off" TGID="TGID None" U_Id="UID None" />
          <DualWatch PRI="Off" CC="Off" WX="Off" />
          <Property F="Off" VOL="5" SQL="2" Sig="\(sig)" Att="Off" Rec="Off" KeyLock="Off" P25Status="None" Mute="Mute" Backlight="100" A_Led="Off" Dir="Up" Rssi="\(rssi)" />
          <ViewDescription>
            <OverWrite Text="Scanning..." />
          </ViewDescription>
        </ScannerInfo>
        """
    return try! ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

/// The SDS150 fixture itself (`sds150-gsi-serial.txt`, its `GSI,<XML>,` line dropped), with its
/// channel renamed to `channel` and `Sig` set to `sig`.
private func sds150Fixture(channel: String, sig: Int) throws -> ScannerInfo {
    let text = String(decoding: fixture("sds150-gsi-serial.txt"), as: UTF8.self)
    let document = try #require(text.split(separator: "\n", maxSplits: 1).last)
    let edited = document
        .replacingOccurrences(of: #"ConvFrequency Name="Plow Dispatch""#, with: "ConvFrequency Name=\"\(channel)\"")
        .replacingOccurrences(of: #"Sig="0""#, with: "Sig=\"\(sig)\"")
    return try ScannerInfo(xml: XMLNode.parse(Data(edited.utf8)))
}

/// Weather shape of `gsi-wx-sds200-1.26.01.xml`.
private func wxInfo(sig: Int) -> ScannerInfo {
    let xml = """
        <ScannerInfo Mode="WX Scan" V_Screen="wx_alert">
          <WxChannel Index="3" CH_No="4" Freq=" 162.550000MHz" Mod="FM" Hold="Off"/>
          <Property VOL="2" SQL="1" Sig="\(sig)" Rssi="-80"/>
        </ScannerInfo>
        """
    return try! ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

private final class IDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> UUID {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
}

private struct Harness {
    let t0 = ContinuousClock.now
    let date0 = Date(timeIntervalSince1970: 1_800_000_000)
    var detector: HitDetector

    init(
        endHangover: Duration = .seconds(1), stallEnd: Duration = .seconds(3),
        maxTransmission: Duration = .seconds(300)
    ) {
        let counter = IDCounter()
        detector = HitDetector(
            anchor: (t0, date0), endHangover: endHangover, stallEnd: stallEnd,
            maxTransmission: maxTransmission, makeID: { counter.next() })
    }

    func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }
    func date(_ ms: Int) -> Date { date0.addingTimeInterval(Double(ms) / 1000) }

    mutating func push(_ i: ScannerInfo, at ms: Int) -> [HitEvent] {
        detector.ingest(PushUpdate(info: i, receivedAt: at(ms)))
    }
    mutating func tick(_ ms: Int) -> [HitEvent] { detector.tick(now: at(ms)) }
    mutating func finish(_ ms: Int) -> [HitEvent] { detector.finish(now: at(ms)) }
}

private enum Kind: Equatable { case started, updated, ended }

private func kinds(_ events: [HitEvent]) -> [Kind] {
    events.map {
        switch $0 {
        case .started: .started
        case .updated: .updated
        case .ended: .ended
        }
    }
}

private func hits(_ events: [HitEvent]) -> [Hit] {
    events.map {
        switch $0 {
        case .started(let h), .updated(let h), .ended(let h): h
        }
    }
}

private func ended(_ events: [HitEvent]) -> [Hit] {
    events.compactMap { if case .ended(let h) = $0 { h } else { nil } }
}

/// Bounds-safe element access, so a wrong event list fails the test instead of crashing the run.
private func pick(_ list: [Hit], _ i: Int, sourceLocation: SourceLocation = #_sourceLocation) -> Hit {
    if i < list.count { return list[i] }
    Issue.record("no hit at index \(i) (have \(list.count))", sourceLocation: sourceLocation)
    return Hit(id: UUID(), key: HitKey(system: nil, talkgroupID: nil, frequencyMHz: nil), startedAt: .distantPast, startInstant: .now)
}

@Suite struct HitDetectorTests {
    @Test func startsUpdatesEnds() {
        var h = Harness()
        let s = h.push(info(tg: "101", sig: 4, uid: "5001", rssi: -70), at: 0)
        #expect(kinds(s) == [.started])
        let started = pick(hits(s), 0)
        #expect(started.key == HitKey(system: "Testville P25", talkgroupID: "101", frequencyMHz: nil))
        #expect(started.channel == "Test TG 101"); #expect(started.department == "Test Dept")
        #expect(started.site == "testsite"); #expect(started.modulation == "NFM")
        #expect(started.toneOrCode == "NAC 1A2h"); #expect(started.system == "Testville P25")
        #expect(started.unitIDs == ["5001"]); #expect(started.rssiMax == -70)
        #expect(started.endedAt == nil); #expect(started.endReason == nil)
        #expect(started.programmed); #expect(!started.continued)

        let u = h.push(info(tg: "101", sig: 5, uid: "5002", rssi: -60), at: 500)
        #expect(kinds(u) == [.updated])
        #expect(pick(hits(u), 0).unitIDs == ["5001", "5002"]); #expect(pick(hits(u), 0).rssiMax == -60)
        #expect(pick(hits(u), 0).endInstant == h.at(500)); #expect(pick(hits(u), 0).id == started.id)

        #expect(h.push(info(tg: nil, sig: 0), at: 1000).isEmpty)  // inactive: hangover pending
        let e = h.push(info(tg: nil, sig: 0), at: 1500)  // 1 s after the last active update
        #expect(kinds(e) == [.ended])
        let hit = pick(ended(e), 0)
        #expect(hit.endReason == .signalLost); #expect(hit.id == started.id)
        #expect(hit.endInstant == h.at(500)); #expect(hit.endedAt == h.date(500))
        #expect(hit.unitIDs == ["5001", "5002"]); #expect(hit.rssiMax == -60)
        #expect(h.tick(10_000).isEmpty)
    }

    @Test func channelChangeSplits() {
        var h = Harness()
        _ = h.push(info(tg: "101", sig: 4), at: 0)
        _ = h.push(info(tg: "101", sig: 4), at: 400)
        let e = h.push(info(tg: "202", sig: 3, uid: "6001"), at: 800)
        #expect(kinds(e) == [.ended, .started])
        let all = hits(e)
        #expect(pick(all, 0).key.talkgroupID == "101"); #expect(pick(all, 0).endReason == .channelChanged)
        #expect(pick(all, 0).endInstant == h.at(400))
        #expect(pick(all, 1).key.talkgroupID == "202"); #expect(pick(all, 1).startInstant == h.at(800))
        #expect(pick(all, 1).unitIDs == ["6001"]); #expect(pick(all, 0).id != pick(all, 1).id)
        #expect(!pick(all, 1).continued)
    }

    @Test func hangoverBridgesBriefDropout() {
        var h = Harness()
        let s = h.push(info(tg: "101", sig: 4), at: 0)
        #expect(h.push(info(tg: "101", sig: 4), at: 500).count == 1)
        #expect(h.push(info(tg: nil, sig: 0), at: 750).isEmpty)
        #expect(h.tick(900).isEmpty)
        let resumed = h.push(info(tg: "101", sig: 4), at: 1000)  // 500 ms gap since last active
        #expect(kinds(resumed) == [.updated]); #expect(pick(hits(resumed), 0).id == pick(hits(s), 0).id)
        let e = h.finish(1200)
        #expect(ended(e).count == 1); #expect(pick(ended(e), 0).id == pick(hits(s), 0).id)
        #expect(pick(ended(e), 0).endInstant == h.at(1000))
    }

    @Test func stallEndsHit() {
        var h = Harness()
        _ = h.push(info(tg: "101", sig: 4), at: 0)
        _ = h.push(info(tg: "101", sig: 4), at: 200)
        // No updates at all: frequent ticks past the hangover don't end it; only the stall does.
        for ms in stride(from: 300, through: 3100, by: 100) {
            #expect(h.tick(ms).isEmpty, "ended early at \(ms) ms")
        }
        let e = h.tick(3300)  // 3.1 s after the last update
        #expect(kinds(e) == [.ended])
        #expect(pick(ended(e), 0).endReason == .stalled); #expect(pick(ended(e), 0).endInstant == h.at(200))
        #expect(h.tick(5000).isEmpty)
    }

    @Test func finishWithReasonEndsTheOpenHit() {
        var h = Harness()
        _ = h.push(info(tg: "101", sig: 4), at: 0)
        _ = h.push(info(tg: "101", sig: 4), at: 200)
        let e = h.detector.finish(now: h.at(500), reason: .stalled)
        #expect(kinds(e) == [.ended])
        #expect(pick(ended(e), 0).endReason == .stalled)
        #expect(pick(ended(e), 0).endInstant == h.at(200))
        #expect(h.detector.finish(now: h.at(600), reason: .stalled).isEmpty)
        #expect(h.tick(9000).isEmpty)
        // The plain finish still says stopped.
        _ = h.push(info(tg: "102", sig: 4), at: 10_000)
        #expect(pick(ended(h.finish(10_100)), 0).endReason == .stopped)
    }

    @Test func maxLengthRollsOver() {
        var h = Harness(maxTransmission: .seconds(2))
        let s = h.push(info(tg: "101", sig: 4, uid: "5001"), at: 0)
        _ = h.push(info(tg: "101", sig: 4), at: 900)
        _ = h.push(info(tg: "101", sig: 4), at: 1800)
        let e = h.push(info(tg: "101", sig: 4, uid: "5002"), at: 2500)
        #expect(kinds(e) == [.ended, .started])
        let all = hits(e)
        #expect(pick(all, 0).id == pick(hits(s), 0).id); #expect(pick(all, 0).endReason == .maxLength)
        #expect(pick(all, 0).endInstant == h.at(1800)); #expect(!pick(all, 0).continued)
        #expect(pick(all, 1).continued); #expect(pick(all, 1).key == pick(all, 0).key)
        #expect(pick(all, 1).startInstant == h.at(2500)); #expect(pick(all, 1).unitIDs == ["5002"])
        #expect(pick(all, 1).id != pick(all, 0).id)
        #expect(kinds(h.push(info(tg: "101", sig: 4), at: 3000)) == [.updated])
    }

    @Test func idleUpdatesNeverStartHits() {
        var h = Harness()
        #expect(h.push(info(tg: nil, sig: 0), at: 0).isEmpty)
        #expect(h.push(info(tg: nil, sig: 3), at: 100).isEmpty)  // no active channel
        #expect(h.push(info(tg: "101", sig: 0), at: 200).isEmpty)  // channel but no signal
        #expect(h.tick(10_000).isEmpty)
        #expect(h.finish(11_000).isEmpty)
    }

    /// Control-channel park: systemType "P25 Trunk", TGID " ---", SiteFrequency present, Sig 3.
    @Test func trunkPlaceholderWithSiteFrequencyIsInactive() throws {
        let xml = """
            <ScannerInfo Mode="Trunk Scan" V_Screen="trunk_scan">
              <System Name="Testville P25" Index="3" Avoid="Off" SystemType="P25 Trunk" Hold="Off"/>
              <TGID Name="" Index="4294967295" Avoid="Off" TGID=" ---" Hold="Off"/>
              <UnitID Name="" U_Id="UID: ---"/>
              <Site Name="testsite" Index="9" Avoid="Off" Hold="Off" Mod="NFM"/>
              <SiteFrequency Freq=" 851.012500MHz" IFX="Off" SAS="NAC Search" SAD="NAC 1A2h"/>
              <Property VOL="2" SQL="1" Sig="3" Rssi="-70"/>
            </ScannerInfo>
            """
        let parked = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
        var h = Harness()
        for ms in stride(from: 0, through: 10_000, by: 500) {
            #expect(h.push(parked, at: ms).isEmpty, "hit started at \(ms) ms")
        }
        #expect(h.finish(10_500).isEmpty)
    }

    @Test func weatherKeysOnFrequency() {
        var h = Harness()
        let s = h.push(wxInfo(sig: 2), at: 0)
        #expect(kinds(s) == [.started])
        let hit = pick(hits(s), 0)
        #expect(hit.key == HitKey(system: nil, talkgroupID: nil, frequencyMHz: 162.55))
        #expect(hit.channel == "WX 4"); #expect(hit.modulation == "FM"); #expect(hit.programmed)
        #expect(hit.rssiMax == -80)
    }

    @Test func unprogrammedFlagCaptured() {
        var h = Harness()
        let s = h.push(convInfo(freq: " 154.250000MHz", sig: 3, programmed: false), at: 0)
        let hit = pick(hits(s), 0)
        #expect(!hit.programmed)
        #expect(hit.key == HitKey(system: "Test Conv", talkgroupID: nil, frequencyMHz: 154.25))
        #expect(hit.toneOrCode == "CTCSS 100.0Hz")
        var p = Harness()
        #expect(pick(hits(p.push(convInfo(freq: " 154.250000MHz", sig: 3), at: 0)), 0).programmed)
        var t = Harness()
        #expect(!pick(hits(t.push(info(tg: "9", sig: 3, tgIndex: "4294967295"), at: 0)), 0).programmed)
    }

    /// The SDS150 conventional shape: nothing while `Sig` is 0, a hit with the channel and its
    /// frequency once it rises, and its end after it falls back.
    @Test func sds150ConventionalStartsAndEnds() {
        var h = Harness()
        #expect(h.push(sds150ConvInfo(sig: 0), at: 0).isEmpty)
        #expect(h.tick(500).isEmpty)

        let s = h.push(sds150ConvInfo(sig: 3, rssi: -80), at: 1000)
        #expect(kinds(s) == [.started])
        let started = pick(hits(s), 0)
        #expect(started.key == HitKey(system: "County Roads", talkgroupID: nil, frequencyMHz: 155.0125))
        #expect(started.channel == "Plow Dispatch"); #expect(started.department == "Road Crews")
        #expect(started.system == "County Roads"); #expect(started.modulation == "NFM")
        #expect(started.toneOrCode == nil); #expect(started.unitIDs == [])
        #expect(started.rssiMax == -80); #expect(started.programmed)

        #expect(kinds(h.push(sds150ConvInfo(sig: 4, rssi: -72), at: 1500)) == [.updated])
        #expect(h.push(sds150ConvInfo(sig: 0), at: 2000).isEmpty)  // hangover pending
        let e = h.push(sds150ConvInfo(sig: 0), at: 2500)
        #expect(kinds(e) == [.ended])
        let hit = pick(ended(e), 0)
        #expect(hit.id == started.id); #expect(hit.endReason == .signalLost)
        #expect(hit.endInstant == h.at(1500)); #expect(hit.rssiMax == -72)
        #expect(hit.key.frequencyMHz == 155.0125)
        #expect(h.tick(10_000).isEmpty)
    }

    /// An SDS150 stepping through its conventional channels names each one with its frequency
    /// while `Sig` is 0: no hit, until a channel has a signal.
    @Test func scanningConventionalChannelsStartsNoHit() throws {
        var h = Harness()
        #expect(h.push(try sds150Fixture(channel: "Plow Dispatch", sig: 0), at: 0).isEmpty)
        #expect(h.push(try sds150Fixture(channel: "Salt Shed", sig: 0), at: 1000).isEmpty)
        #expect(h.push(try sds150Fixture(channel: "Road Crew 2", sig: 0), at: 2000).isEmpty)
        let s = h.push(try sds150Fixture(channel: "Plow Dispatch", sig: 2), at: 3000)
        #expect(kinds(s) == [.started])
        #expect(pick(hits(s), 0).channel == "Plow Dispatch")
    }

    @Test func datesFollowAnchor() {
        var h = Harness()
        let s = h.push(info(tg: "101", sig: 4), at: 2_250)
        #expect(pick(hits(s), 0).startedAt == h.date(2_250))
        _ = h.push(info(tg: "101", sig: 4), at: 4_750)
        let e = h.finish(5_000)
        #expect(pick(ended(e), 0).endedAt == h.date(4_750)); #expect(pick(ended(e), 0).startedAt == h.date(2_250))
    }

    // MARK: Extra coverage

    @Test func activeUpdateAfterHangoverStartsNewHit() {
        var h = Harness()
        let s = h.push(info(tg: "101", sig: 4), at: 0)
        _ = h.push(info(tg: nil, sig: 0), at: 300)
        let e = h.push(info(tg: "101", sig: 4), at: 1000)  // exactly lastActive + hangover
        #expect(kinds(e) == [.ended, .started])
        #expect(pick(hits(e), 0).id == pick(hits(s), 0).id); #expect(pick(hits(e), 0).endReason == .signalLost)
        #expect(pick(hits(e), 0).endInstant == h.at(0)); #expect(!pick(hits(e), 1).continued)
    }

    /// A lost PSI datagram (silence, no inactive push) must not split a transmission: only the
    /// stall ends a hit on silence.
    @Test func sameKeyAfterSilentGapUnderStallContinuesHit() {
        var h = Harness()
        let s = h.push(info(tg: "101", sig: 4), at: 0)
        for gap in [1_000, 1_010, 1_500, 2_500] {
            var g = Harness()
            let first = g.push(info(tg: "101", sig: 4), at: 0)
            let e = g.push(info(tg: "101", sig: 4), at: gap)
            #expect(kinds(e) == [.updated], "gap \(gap) ms")
            #expect(pick(hits(e), 0).id == pick(hits(first), 0).id, "gap \(gap) ms")
            #expect(pick(hits(e), 0).endInstant == g.at(gap), "gap \(gap) ms")
        }
        let e = h.push(info(tg: "101", sig: 4), at: 2_500)
        #expect(kinds(e) == [.updated]); #expect(pick(hits(e), 0).id == pick(hits(s), 0).id)
        #expect(pick(hits(e), 0).endInstant == h.at(2_500))
    }

    @Test func differentKeyAfterSilentGapIsChannelChanged() {
        var h = Harness()
        let s = h.push(info(tg: "101", sig: 4), at: 0)
        let e = h.push(info(tg: "202", sig: 4), at: 2_500)
        #expect(kinds(e) == [.ended, .started])
        #expect(pick(hits(e), 0).id == pick(hits(s), 0).id)
        #expect(pick(hits(e), 0).endReason == .channelChanged)
        #expect(pick(hits(e), 0).endInstant == h.at(0))
        #expect(pick(hits(e), 1).key.talkgroupID == "202")
    }

    /// Out-of-order `receivedAt` can't move the stall clock backwards.
    @Test func outOfOrderUpdatesDoNotRewindStallClock() {
        var h = Harness()
        _ = h.push(info(tg: "101", sig: 4), at: 1_000)
        _ = h.push(info(tg: "101", sig: 4), at: 800)
        _ = h.push(info(tg: "101", sig: 4), at: 1_200)
        #expect(h.tick(3_950).isEmpty)  // stall measured from 1200
        // Late arrival last: the stall is still measured from the newest instant (1200).
        var g = Harness()
        _ = g.push(info(tg: "101", sig: 4), at: 1_000)
        _ = g.push(info(tg: "101", sig: 4), at: 1_200)
        _ = g.push(info(tg: nil, sig: 0), at: 900)
        #expect(g.tick(3_950).isEmpty)
        #expect(ended(g.tick(4_200)).map(\.endReason) == [.stalled])
    }

    @Test func tickEndsSignalLostAfterInactiveUpdate() {
        var h = Harness()
        _ = h.push(info(tg: "101", sig: 4), at: 0)
        _ = h.push(info(tg: nil, sig: 0), at: 400)
        #expect(h.tick(999).isEmpty)
        let e = h.tick(1000)
        #expect(ended(e).map(\.endReason) == [.signalLost]); #expect(pick(ended(e), 0).endInstant == h.at(0))
    }

    @Test func stallCountsInactiveUpdatesAsReceived() {
        var h = Harness(endHangover: .seconds(5), stallEnd: .seconds(3))
        _ = h.push(info(tg: "101", sig: 4), at: 0)
        _ = h.push(info(tg: nil, sig: 0), at: 2000)
        #expect(h.tick(4900).isEmpty)  // 2.9 s since the last (inactive) update
        let e = h.tick(5000)
        #expect(ended(e).map(\.endReason) == [.signalLost])  // hangover reached first here
        var s = Harness(endHangover: .seconds(5), stallEnd: .seconds(3))
        _ = s.push(info(tg: "101", sig: 4), at: 0)
        _ = s.push(info(tg: nil, sig: 0), at: 1000)
        let st = s.tick(4000)  // 3 s since any update, hangover not yet reached
        #expect(ended(st).map(\.endReason) == [.stalled]); #expect(pick(ended(st), 0).endInstant == s.at(0))
    }

    @Test func updatesResumingAfterStallGapEndStalled() {
        var h = Harness()
        let s = h.push(info(tg: "101", sig: 4), at: 0)
        let e = h.push(info(tg: "101", sig: 4), at: 3500)  // no tick ran during the gap
        #expect(kinds(e) == [.ended, .started])
        #expect(pick(hits(e), 0).id == pick(hits(s), 0).id); #expect(pick(hits(e), 0).endReason == .stalled)
    }

    @Test func updatedOnlyForVisibleChangesAndAtMostOncePerIngest() {
        var h = Harness()
        _ = h.push(info(tg: "101", sig: 4, uid: "5001", rssi: -60), at: 0)
        // Same UID, lower RSSI: only the end extends, still one .updated.
        let u = h.push(info(tg: "101", sig: 4, uid: "5001", rssi: -90), at: 100)
        #expect(kinds(u) == [.updated]); #expect(pick(hits(u), 0).rssiMax == -60)
        #expect(pick(hits(u), 0).unitIDs == ["5001"])
        // A duplicate of an update already seen (same instant): nothing visible changes.
        #expect(h.push(info(tg: "101", sig: 4, uid: "5001", rssi: -90), at: 100).isEmpty)
        // Inactive updates never emit .updated.
        #expect(h.push(info(tg: nil, sig: 0), at: 200).isEmpty)
    }

    @Test func nilRssiExcludedFromMax() {
        var h = Harness()
        let s = h.push(info(tg: "101", sig: 4, rssi: nil), at: 0)
        #expect(pick(hits(s), 0).rssiMax == nil)
        let u = h.push(info(tg: "101", sig: 4, rssi: -88), at: 100)
        #expect(pick(hits(u), 0).rssiMax == -88)
        let v = h.push(info(tg: "101", sig: 4, rssi: nil), at: 200)
        #expect(pick(hits(v), 0).rssiMax == -88)
    }

    @Test func frequencyNoiseDoesNotSplit() {
        var h = Harness()
        let s = h.push(convInfo(freq: " 154.250000MHz", sig: 3), at: 0)
        let u = h.push(convInfo(freq: " 154.250001MHz", sig: 3), at: 100)
        #expect(kinds(u) == [.updated]); #expect(pick(hits(u), 0).id == pick(hits(s), 0).id)
        #expect(pick(hits(u), 0).key.frequencyMHz == 154.25)
    }

    @Test func finishEndsStoppedAndIsIdempotent() {
        var h = Harness()
        _ = h.push(info(tg: "101", sig: 4), at: 0)
        _ = h.push(info(tg: "101", sig: 4), at: 300)
        let e = h.finish(400)
        #expect(ended(e).map(\.endReason) == [.stopped]); #expect(pick(ended(e), 0).endInstant == h.at(300))
        #expect(h.finish(500).isEmpty); #expect(h.tick(9000).isEmpty)
    }

    @Test func idsComeFromInjectedGenerator() {
        var h = Harness()
        let a = pick(hits(h.push(info(tg: "101", sig: 4), at: 0)), 0)
        let b = pick(hits(h.push(info(tg: "202", sig: 4), at: 100)), 1)
        #expect(a.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(b.id == UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    }

    @Test func codableOmitsInstantsAndRoundTripsTheRest() throws {
        var h = Harness()
        _ = h.push(info(tg: "101", sig: 4, uid: "5001"), at: 0)
        let hit = pick(ended(h.finish(500)), 0)
        let data = try JSONEncoder().encode(hit)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["startInstant"] == nil); #expect(object["endInstant"] == nil)
        #expect(object["endReason"] as? String == "stopped")
        let back = try JSONDecoder().decode(Hit.self, from: data)
        #expect(back.id == hit.id); #expect(back.key == hit.key)
        #expect(back.startedAt == hit.startedAt); #expect(back.endedAt == hit.endedAt)
        #expect(back.unitIDs == hit.unitIDs); #expect(back.endReason == .stopped)
        #expect(back.startInstant == Hit.decodedInstantPlaceholder)
        #expect(back.endInstant == Hit.decodedInstantPlaceholder)
        var open = hit; open.endedAt = nil; open.endReason = nil
        let openBack = try JSONDecoder().decode(Hit.self, from: JSONEncoder().encode(open))
        #expect(openBack.endInstant == nil)
    }
}
