// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import Foundation
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI
import Testing
@testable import NoctuleScan

/// The hit log window's own logic: wording and formats, rows and sorting, sidebar entries, and
/// playback sequencing. All values are fictional.
@MainActor @Suite struct HitLogWindowTests {
    private static let noon: Date = {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(12 * 3600)
    }()

    private static func hit(tg: String?, freq: Double? = nil, start: Date = noon, duration: Double? = 2.25,
                            units: [String] = ["100200"]) -> Hit {
        Hit(id: UUID(), key: HitKey(system: "Fictional County P25", talkgroupID: tg, frequencyMHz: freq),
            startedAt: start, endedAt: duration.map { start.addingTimeInterval($0) },
            startInstant: .now, endInstant: duration == nil ? nil : .now,
            system: "Fictional County P25", department: "Fire", channel: "Fire Dispatch", site: nil,
            unitIDs: units, modulation: "NFM", toneOrCode: "NAC 2F1", rssiMax: 3,
            programmed: true, endReason: duration == nil ? nil : .signalLost)
    }

    // MARK: Text

    @Test func deleteConfirmationUsesTheBriefsWording() {
        #expect(HitLogText.deleteConfirmation(rows: 3) == "Delete 3 rows and move their recordings to the Trash?")
        #expect(HitLogText.deleteConfirmation(rows: 1) == "Delete 1 row and move their recordings to the Trash?")
    }

    @Test func csvFileNameIsStationNameHits() {
        #expect(HitLogText.csvFileName(stationName: "Test Station") == "Test Station hits.csv")
        #expect(HitLogText.csvFileName(stationName: "North/South: A") == "North-South- A hits.csv")
        #expect(HitLogText.csvFileName(stationName: "  ") == "Station hits.csv")
    }

    @Test func formats() {
        #expect(HitLogText.path("Fictional County P25", "Fire", "Fire Dispatch") == "Fictional County P25 › Fire › Fire Dispatch")
        #expect(HitLogText.path("Fictional Valley", nil, " ", "Marina Ops") == "Fictional Valley › Marina Ops")
        #expect(HitLogText.path(nil, "") == "—")
        #expect(HitLogText.frequency(155.1234) == "155.1234")
        #expect(HitLogText.frequency(-1) == "—")
        #expect(HitLogText.rssi(.min) == "—" && HitLogText.rssi(4) == "4")
        #expect(HitLogText.talkTime(7) == "0:07")
        #expect(HitLogText.talkTime(189.4) == "3:09")
        #expect(HitLogText.talkTime(3725) == "1:02:05")
        #expect(HitLogText.duration(2.25) == "2.3 s" || HitLogText.duration(2.25) == "2.2 s")
        #expect(HitLogText.duration(75) == "1:15")
        #expect(HitLogText.duration(-1) == "on air")
    }

    /// The path column drops whole leading parts, never cuts mid-word; the channel survives.
    @Test func pathFallsBackAtPartBoundaries() {
        let parts = HitLogText.pathParts("Fictional County P25", "Fire", "Fire Dispatch")
        #expect(HitLogText.pathFallbacks(parts) == ["Fictional County P25 › Fire › Fire Dispatch",
                                                    "Fire › Fire Dispatch", "Fire Dispatch"])
        #expect(HitLogText.pathFallbacks(HitLogText.pathParts(nil, " ", "Marina Ops")) == ["Marina Ops"])
        #expect(HitLogText.pathFallbacks([]) == ["—"])
        let row = HitRow(transmission: LoggedHit(hit: Self.hit(tg: "4711"), audioPath: nil, audioError: nil, isNew: false))
        #expect(row.pathParts == ["Fictional County P25", "Fire", "Fire Dispatch"])
        #expect(row.path == "Fictional County P25 › Fire › Fire Dispatch")
    }

    @Test func timesShowTheDateOnlyOffToday() {
        let now = Self.noon
        #expect(HitLogText.time(now.addingTimeInterval(-3600), now: now) == "11:00:00")
        let earlier = HitLogText.time(now.addingTimeInterval(-2 * 86_400), now: now)
        #expect(earlier.hasSuffix(", 12:00:00") && earlier.count > ", 12:00:00".count)
        #expect(HitLogText.session(Calendar.current.startOfDay(for: now), now: now) == "Today")
        #expect(HitLogText.session(now.addingTimeInterval(-86_400), now: now) == "Yesterday")
        #expect(!["Today", "Yesterday"].contains(HitLogText.session(now.addingTimeInterval(-3 * 86_400), now: now)))
    }

    @Test func noAudioSaysWhy() {
        let h = Self.hit(tg: "4711")
        #expect(HitLogText.noAudio(LoggedHit(hit: h, audioPath: "/tmp/x.wav", audioError: nil, isNew: false)) == nil)
        #expect(HitLogText.noAudio(LoggedHit(hit: h, audioPath: nil, audioError: "disk full", isNew: false))
                == "no audio: disk full")
        #expect(HitLogText.noAudio(LoggedHit(hit: h, audioPath: nil, audioError: nil, isNew: false))
                == "no audio: not recorded")
    }

    // MARK: Rows

    @Test func rowsFromGroupsAndTransmissions() {
        let g = HitGroup(key: HitKey(system: "Fictional County P25", talkgroupID: "4711", frequencyMHz: nil),
                         label: "Fire Dispatch", hits: 3, talkTime: 6.5, firstSeen: Self.noon,
                         lastSeen: Self.noon.addingTimeInterval(60), rssiMax: nil, programmed: true, isNew: true,
                         modes: ["NFM", "FM"], toneOrCode: "NAC 2F1", department: "Fire", lastUnitID: "100201")
        let row = HitRow(group: g)
        #expect(row.id == g.id && row.tgid == "4711" && row.frequency == -1 && row.rssi == .min)
        #expect(row.mode == "NFM, FM" && row.uid == "100201" && row.hits == 3 && row.isNew)
        #expect(row.path == "Fictional County P25 › Fire › Fire Dispatch")

        let open = Self.hit(tg: nil, freq: 155.1234, duration: nil, units: ["1", "2"])
        let t = HitRow(transmission: LoggedHit(hit: open, audioPath: nil, audioError: nil, isNew: false))
        #expect(t.id == open.id.uuidString && t.tgid == "" && t.frequency == 155.1234)
        #expect(t.duration == -1 && t.uid == "1, 2" && t.rssi == 3)
    }

    @Test func tgidSortsNumerically() {
        let rows = ["4711", "9", "77", ""].map { tg -> HitRow in
            HitRow(transmission: LoggedHit(hit: Self.hit(tg: tg.isEmpty ? nil : tg), audioPath: nil,
                                           audioError: nil, isNew: false))
        }
        let sorted = rows.sorted(using: [KeyPathComparator(\HitRow.tgid, comparator: .localizedStandard)])
        #expect(sorted.map(\.tgid) == ["", "9", "77", "4711"])
        let byRSSIDesc = rows.sorted(using: [KeyPathComparator(\HitRow.rssi, order: .reverse)])
        #expect(byRSSIDesc.count == 4)
    }

    // MARK: Sidebar

    @Test func sidebarEntriesMapToFilterAndDay() {
        var current = HitFilter(); current.text = "fire"; current.system = "Old"
        var saved = HitFilter(); saved.name = "NFM only"; saved.modes = ["NFM"]; saved.text = nil
        let day = Self.noon
        let all = HitLogSidebarItem.all.apply(current: current, saved: [saved])
        #expect(all.session == nil && all.filter.text == "fire" && all.filter.system == nil && !all.filter.onlyNew)
        let d = HitLogSidebarItem.day(day).apply(current: current, saved: [saved])
        #expect(d.session == day && d.filter.text == "fire")
        let new = HitLogSidebarItem.onlyNew.apply(current: current, saved: [saved])
        #expect(new.filter.onlyNew && new.session == nil && new.filter.text == "fire")
        let s = HitLogSidebarItem.saved(saved.id).apply(current: current, saved: [saved])
        #expect(s.filter == saved && s.session == nil)
        let gone = HitLogSidebarItem.saved(UUID()).apply(current: current, saved: [saved])
        #expect(gone.filter.modes.isEmpty && gone.filter.text == "fire")
    }

    // MARK: Playback

    @MainActor final class FakePlayer: WAVPlayer {
        let url: URL
        var duration: TimeInterval { 1 }
        var onFinish: (@MainActor () -> Void)?
        var playing = false
        var stopped = false
        init(url: URL) { self.url = url }
        func play() -> Bool { playing = true; return true }
        func stop() { playing = false; stopped = true }
        func finish() { playing = false; onFinish?() }
    }

    final class Players {
        var made: [FakePlayer] = []
        var missing: Set<String> = []
    }

    private func makePlayback(_ players: Players) -> WAVPlayback {
        WAVPlayback { url in
            if players.missing.contains(url.lastPathComponent) { throw CocoaError(.fileReadNoSuchFile) }
            let p = FakePlayer(url: url)
            players.made.append(p)
            return p
        }
    }

    private func item(_ name: String) -> WAVPlayback.Item {
        WAVPlayback.Item(id: UUID(), url: URL(fileURLWithPath: "/nonexistent/\(name).wav"))
    }

    @Test func oneAtATimeAndToggleStops() {
        let players = Players()
        let playback = makePlayback(players)
        let a = item("a"), b = item("b")
        playback.play(a)
        #expect(playback.playingID == a.id && players.made[0].playing)
        playback.play(b)
        #expect(players.made[0].stopped && playback.playingID == b.id)
        playback.toggle(b)
        #expect(playback.playingID == nil && players.made[1].stopped)
        playback.toggle(a)
        #expect(playback.playingID == a.id)
        players.made[2].finish()
        #expect(playback.playingID == nil)
    }

    @Test func playAllRunsInOrderSkipsMissingAndCanBeStopped() {
        let players = Players()
        players.missing = ["b.wav"]
        let playback = makePlayback(players)
        let a = item("a"), b = item("b"), c = item("c"), d = item("d")
        playback.playAll([a, b, c, d])
        #expect(playback.isPlayingAll && playback.playingID == a.id)
        players.made[0].finish()
        #expect(playback.playingID == c.id)  // b is missing: skipped
        #expect(playback.problem == "The recording b.wav is missing.")
        // A late finish from a player that was already replaced does nothing.
        players.made[0].finish()
        #expect(playback.playingID == c.id)
        playback.stop()
        #expect(playback.playingID == nil && !playback.isPlayingAll && players.made[1].stopped)
        #expect(players.made.map(\.url.lastPathComponent) == ["a.wav", "c.wav"])  // d never started
    }

    @Test func playAllEndsAfterTheLast() {
        let players = Players()
        let playback = makePlayback(players)
        let a = item("a"), b = item("b")
        playback.playAll([a, b])
        players.made[0].finish()
        #expect(playback.playingID == b.id)
        players.made[1].finish()
        #expect(playback.playingID == nil && !playback.isPlayingAll)
    }

    @Test func deletingThePlayingHitStopsIt() {
        let players = Players()
        let playback = makePlayback(players)
        let a = item("a"), b = item("b"), c = item("c")
        playback.playAll([a, b, c])
        playback.stop(ifAnyOf: [b.id])          // queued: dropped from the queue
        players.made[0].finish()
        #expect(playback.playingID == c.id)
        playback.stop(ifAnyOf: [c.id])          // playing: stopped
        #expect(playback.playingID == nil && players.made[1].stopped)
    }

    /// The real player opens a recording as the runner writes it (16-bit 8 kHz mono WAV).
    @Test func avAudioPlayerLoadsARecording() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-wav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        let writer = try WAVWriter(url: url)
        try writer.append((0..<12_000).map { Int16(sin(Double($0) * 0.3) * 8000) })
        try writer.close()
        let duration = try WAVPlayback.duration(of: url)
        #expect(abs(duration - 1.5) < 0.01)
        let player = try AVWAVPlayer(url: url)
        #expect(abs(player.duration - 1.5) < 0.01)
        #expect(throws: (any Error).self) { _ = try AVWAVPlayer(url: dir.appendingPathComponent("missing.wav")) }
    }
}
#endif
