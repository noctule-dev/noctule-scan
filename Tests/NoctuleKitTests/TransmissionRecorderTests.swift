// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

// MARK: - Fixtures

/// 2026-11-09 14:03:07 UTC.
private let fixtureDate = Date(timeIntervalSince1970: 1_794_232_987)

private func trunkHit(tg: String = "9", channel: String? = "Lakeview Fire", startedAt: Date = fixtureDate,
                      start: ContinuousClock.Instant = .now, end: ContinuousClock.Instant? = nil,
                      id: UUID = UUID()) -> Hit {
    Hit(id: id, key: HitKey(system: "Metro", talkgroupID: tg, frequencyMHz: nil), startedAt: startedAt,
        startInstant: start, endInstant: end ?? start, system: "Metro", channel: channel)
}

private func conventionalHit(mhz: Double, channel: String?) -> Hit {
    Hit(id: UUID(), key: HitKey(system: "Harbor", talkgroupID: nil, frequencyMHz: mhz), startedAt: fixtureDate,
        startInstant: .now, endInstant: .now, system: "Harbor", channel: channel)
}

private let utc = TimeZone(identifier: "UTC")!

// MARK: - RecordingName

@Test func fileNameFormat() {
    #expect(RecordingName.fileName(for: trunkHit(), timeZone: utc)
            == "2026-11-09 14-03-07 · TG9 · Lakeview Fire.wav")
}

@Test func fileNameUsesTheGivenTimeZone() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!  // UTC+9, no DST
    #expect(RecordingName.fileName(for: trunkHit(), timeZone: tokyo)
            == "2026-11-09 23-03-07 · TG9 · Lakeview Fire.wav")
}

@Test func conventionalName() {
    #expect(RecordingName.fileName(for: conventionalHit(mhz: 154.265, channel: "Ridge Dispatch"), timeZone: utc)
            == "2026-11-09 14-03-07 · 154.2650MHz · Ridge Dispatch.wav")
    #expect(RecordingName.fileName(for: conventionalHit(mhz: 162.55, channel: "WX 4"), timeZone: utc)
            == "2026-11-09 14-03-07 · 162.5500MHz · WX 4.wav")
}

@Test func emptyChannelIsUnknown() {
    #expect(RecordingName.fileName(for: trunkHit(channel: nil), timeZone: utc)
            == "2026-11-09 14-03-07 · TG9 · Unknown.wav")
    #expect(RecordingName.fileName(for: trunkHit(channel: ""), timeZone: utc)
            == "2026-11-09 14-03-07 · TG9 · Unknown.wav")
    // Only characters that sanitize away (whitespace) also give Unknown.
    #expect(RecordingName.fileName(for: trunkHit(channel: "   "), timeZone: utc)
            == "2026-11-09 14-03-07 · TG9 · Unknown.wav")
}

@Test func sanitizesAndTruncates() {
    let dirty = "A/B:C\\D*E?F\"G<H>I|J\tK\nL\u{7F}M"
    #expect(RecordingName.fileName(for: trunkHit(channel: dirty), timeZone: utc)
            == "2026-11-09 14-03-07 · TG9 · A-B-C-D-E-F-G-H-I-J-K-L-M.wav")
    #expect(RecordingName.fileName(for: trunkHit(channel: "  North \u{00A0}  Gate  "), timeZone: utc)
            == "2026-11-09 14-03-07 · TG9 · North Gate.wav")
    // A dot-leading channel is fine: the name starts with the date.
    #expect(RecordingName.fileName(for: trunkHit(channel: ".hidden"), timeZone: utc)
            == "2026-11-09 14-03-07 · TG9 · .hidden.wav")

    // Truncation: 18-byte grapheme clusters must never be cut mid-cluster.
    let family = "👨‍👩‍👧"
    #expect(family.utf8.count == 18)
    let name = RecordingName.fileName(for: trunkHit(channel: String(repeating: family, count: 40)), timeZone: utc)
    #expect(name.utf8.count <= 200)
    #expect(name.hasPrefix("2026-11-09 14-03-07 · TG9 · "))
    #expect(name.hasSuffix(".wav"))
    let channelPart = name.dropFirst("2026-11-09 14-03-07 · TG9 · ".count).dropLast(4)
    #expect(!channelPart.isEmpty)
    #expect(channelPart.allSatisfy { String($0) == family })
    // As many whole clusters as fit.
    let fixedBytes = "2026-11-09 14-03-07 · TG9 · .wav".utf8.count
    #expect(channelPart.count == (200 - fixedBytes) / 18)

    // Plain ASCII truncates to exactly 200 bytes.
    let long = RecordingName.fileName(for: trunkHit(channel: String(repeating: "x", count: 500)), timeZone: utc)
    #expect(long.utf8.count == 200)
    // Truncation never leaves trailing whitespace before ".wav".
    let spaced = String(repeating: "ab ", count: 100)
    let n = RecordingName.fileName(for: trunkHit(channel: spaced), timeZone: utc)
    #expect(n.utf8.count <= 200)
    #expect(!n.hasSuffix(" .wav"))
}

@Test func talkgroupIDIsSanitizedToo() {
    #expect(RecordingName.fileName(for: trunkHit(tg: "1/2", channel: "Ops"), timeZone: utc)
            == "2026-11-09 14-03-07 · TG1-2 · Ops.wav")
}

// MARK: - TransmissionRecorder

/// A fresh folder in the system temp directory; `remove()` restores permissions and deletes it.
private struct TempFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func setPermissions(_ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    func remove() {
        try? setPermissions(0o700)
        try? FileManager.default.removeItem(at: url)
    }
    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

/// Chunks arrive every 40 ms; chunk k holds 320 samples of value k + 1 (never 0, so silence shows).
private struct Timeline {
    let t0 = ContinuousClock.now
    func at(_ k: Double) -> ContinuousClock.Instant { t0 + .microseconds(Int64(k * 40_000)) }
    func chunk(_ k: Int, ssrc: UInt32 = 7, lostBefore: Int = 0, discontinuity: Bool = false) -> AudioChunk {
        AudioChunk(samples: Array(repeating: Int16(k + 1), count: 320), rtpTimestamp: UInt32(k * 320),
                   sequence: UInt16(k), receivedAt: at(Double(k)), ssrc: ssrc, lostBefore: lostBefore,
                   discontinuity: discontinuity)
    }
    func hit(start: Int, end: Int? = nil, id: UUID = UUID(), channel: String = "Lakeview Fire") -> Hit {
        var h = trunkHit(channel: channel, startedAt: fixtureDate.addingTimeInterval(Double(start) * 0.04),
                         start: at(Double(start)), end: at(Double(end ?? start)), id: id)
        if end != nil { h.endedAt = h.startedAt.addingTimeInterval(Double(end! - start) * 0.04); h.endReason = .signalLost }
        return h
    }
}

/// Feeds chunks first...last; after ingesting chunk k, delivers `events[k]` in order.
private func run(_ r: TransmissionRecorder, _ tl: Timeline, from first: Int = 0, through last: Int,
                 events: [Int: [(HitEvent, Bool)]] = [:], chunk: (Int) -> AudioChunk? = { _ in nil })
    -> [RecordingResult] {
    var results: [RecordingResult] = []
    for k in first...last {
        results += r.ingest(chunk(k) ?? tl.chunk(k))
        for (e, record) in events[k] ?? [] { results += r.handle(e, record: record) }
    }
    return results
}

private func samples(_ path: String) throws -> [Int16] {
    let d = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(d.count >= 44)
    let dataSize = Int(d[d.startIndex + 40]) | Int(d[d.startIndex + 41]) << 8
        | Int(d[d.startIndex + 42]) << 16 | Int(d[d.startIndex + 43]) << 24
    #expect(dataSize == d.count - 44)
    var out: [Int16] = []
    out.reserveCapacity((d.count - 44) / 2)
    var i = d.startIndex + 44
    while i + 1 < d.endIndex {
        out.append(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8))
        i += 2
    }
    return out
}

/// The chunk indices a file holds, in order (each run of 320 equal non-zero samples is one chunk).
private func chunkIndices(_ s: [Int16]) -> [Int] {
    stride(from: 0, to: s.count, by: 320).compactMap { s[$0] == 0 ? nil : Int(s[$0]) - 1 }
}

@Test(arguments: [false, true])
func writesPreRollHitAndPostRoll(deliverUpdates: Bool) throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let id = UUID()
    var events: [Int: [(HitEvent, Bool)]] = [25: [(.started(tl.hit(start: 25, id: id)), true)]]
    if deliverUpdates {
        for k in stride(from: 30, through: 50, by: 5) {
            var h = tl.hit(start: 25, id: id); h.endInstant = tl.at(Double(k))
            events[k] = [(.updated(h), true)]
        }
    }
    // The detector ends the hit a 1 s hangover after its last active push (chunk 50).
    events[75] = [(.ended(tl.hit(start: 25, end: 50, id: id)), true)]
    let results = run(r, tl, through: 100, events: events)
    #expect(r.finishAll() == [])
    #expect(results.count == 1)
    let result = try #require(results.first)
    #expect(result.hitID == id); #expect(result.error == nil); #expect(!result.skippedShort)
    let path = try #require(result.path)
    #expect(URL(fileURLWithPath: path).lastPathComponent == RecordingName.fileName(for: tl.hit(start: 25, id: id)))
    let s = try samples(path)
    // 0.5 s pre-roll + 1 s hit + 0.5 s post-roll = 2.0 s (± one chunk).
    #expect(abs(s.count - 16_000) <= 320)
    // Pre-roll from t(25) - 0.5 s = chunk 12.5 (so 13), post-roll through t(50) + 0.5 s = chunk 62.5 (so 62).
    #expect(chunkIndices(s) == Array(13...62))
}

@Test func audioOffsetShiftsTheAlignment() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    // Audio arrives 200 ms (5 chunks) after the pushes that describe it.
    let r = TransmissionRecorder(folder: folder.url, audioOffset: .milliseconds(-200))
    let id = UUID()
    let results = run(r, tl, through: 100, events: [
        25: [(.started(tl.hit(start: 25, id: id)), true)],
        80: [(.ended(tl.hit(start: 25, end: 50, id: id)), true)],
    ])
    let path = try #require(results.first?.path)
    #expect(results.count == 1)
    #expect(chunkIndices(try samples(path)) == Array(18...67))
}

@Test func positiveAudioOffsetKeepsAFullPreRoll() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    // Audio arrives 200 ms before the pushes: the ring must hold preRoll + 200 ms.
    let r = TransmissionRecorder(folder: folder.url, audioOffset: .milliseconds(200))
    let id = UUID()
    let results = run(r, tl, through: 100, events: [
        25: [(.started(tl.hit(start: 25, id: id)), true)],
        75: [(.ended(tl.hit(start: 25, end: 50, id: id)), true)],
    ])
    let path = try #require(results.first?.path)
    // Effective time of chunk k is t(k + 5): pre-roll from t(12.5) is chunk 8, post-roll to t(62.5) is chunk 57.
    #expect(chunkIndices(try samples(path)) == Array(8...57))
}

@Test func fillsGapsWithSilence() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let id = UUID()
    let results = run(r, tl, through: 100, events: [
        25: [(.started(tl.hit(start: 25, id: id)), true)],
        75: [(.ended(tl.hit(start: 25, end: 50, id: id)), true)],
    ], chunk: { k in
        switch k {
        case 35: tl.chunk(k, lostBefore: 3)
        case 40: tl.chunk(k, discontinuity: true)  // unknown gap: nothing extra
        case 45...: tl.chunk(k, ssrc: 99)           // new stream: nothing extra
        default: nil
        }
    })
    let s = try samples(try #require(results.first?.path))
    #expect(s.count == 50 * 320 + 960)
    // Chunks 13...34 come first, then exactly 960 zero samples, then chunk 35.
    let gapStart = (35 - 13) * 320
    #expect(s[gapStart - 1] == 35)  // last sample of chunk 34
    #expect(s[gapStart..<(gapStart + 960)].allSatisfy { $0 == 0 })
    #expect(s[gapStart + 960] == 36)  // first sample of chunk 35
    #expect(s.filter { $0 == 0 }.count == 960)
}

@Test func skipsShortTransmission() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url, preRoll: .zero, postRoll: .zero)
    let short = UUID(), long = UUID()
    let results = run(r, tl, through: 100, events: [
        // 5 chunks (25...29) = 0.2 s: skipped.
        25: [(.started(tl.hit(start: 25, id: short)), true)],
        30: [(.ended(tl.hit(start: 25, end: 29, id: short)), true)],
        // 13 chunks (60...72) = 0.52 s: kept.
        60: [(.started(tl.hit(start: 60, id: long)), true)],
        80: [(.ended(tl.hit(start: 60, end: 72, id: long)), true)],
    ])
    #expect(results.count == 2)
    #expect(results.first == RecordingResult(hitID: short, path: nil, error: nil, skippedShort: true))
    let kept = try #require(results.last)
    #expect(kept.hitID == long); #expect(!kept.skippedShort); #expect(kept.error == nil)
    #expect(chunkIndices(try samples(try #require(kept.path))) == Array(60...72))
    #expect(folder.files().count == 1)
}

@Test func unwritableFolderReportsError() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    try folder.setPermissions(0o500)
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let failed = UUID(), later = UUID()
    var results = run(r, tl, through: 25)
    results += r.handle(.started(tl.hit(start: 25, id: failed)), record: true)
    #expect(results.count == 1)
    let first = try #require(results.first)
    #expect(first.hitID == failed); #expect(first.path == nil); #expect(first.error != nil)
    #expect(!first.skippedShort)
    // The failed hit's end produces nothing more.
    #expect(r.handle(.ended(tl.hit(start: 25, end: 50, id: failed)), record: true) == [])
    #expect(folder.files().isEmpty)

    // Later hits still record once the folder is writable again.
    try folder.setPermissions(0o700)
    let next = run(r, tl, from: 26, through: 160, events: [
        100: [(.started(tl.hit(start: 100, id: later)), true)],
        140: [(.ended(tl.hit(start: 100, end: 125, id: later)), true)],
    ])
    #expect(next.count == 1)
    let ok = try #require(next.first)
    #expect(ok.hitID == later); #expect(ok.error == nil)
    #expect(chunkIndices(try samples(try #require(ok.path))) == Array(88...137))
}

@Test func currentPathFollowsTheOpenRecording() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let recorded = UUID(), skipped = UUID()
    _ = run(r, tl, through: 20)
    #expect(r.currentPath(for: recorded) == nil)
    _ = r.handle(.started(tl.hit(start: 20, id: recorded)), record: true)
    let path = try #require(r.currentPath(for: recorded))
    #expect(path.hasPrefix(folder.url.path))
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(r.currentPath(for: skipped) == nil)
    // Still open during the post-roll, after .ended.
    _ = run(r, tl, from: 21, through: 40)
    #expect(r.handle(.ended(tl.hit(start: 20, end: 40, id: recorded)), record: true) == [])
    #expect(r.currentPath(for: recorded) == path)
    // Closed: no path.
    let results = run(r, tl, from: 41, through: 60)
    #expect(results.first?.path == path)
    #expect(r.currentPath(for: recorded) == nil)
    // An unrecorded hit never has one.
    _ = r.handle(.started(tl.hit(start: 61, id: skipped)), record: false)
    #expect(r.currentPath(for: skipped) == nil)
}

@Test func folderNameIsSanitized() {
    #expect(RecordingName.sanitizeFolderName("Home SDS200") == "Home SDS200")
    #expect(RecordingName.sanitizeFolderName("Fire/Ops: North") == "Fire-Ops- North")
    #expect(RecordingName.sanitizeFolderName("  two   spaces \n") == "two spaces -")
    #expect(RecordingName.sanitizeFolderName("") == "Unknown")
    #expect(RecordingName.sanitizeFolderName("   ") == "Unknown")
    #expect(RecordingName.sanitizeFolderName(".hidden") == "-hidden")
    #expect(RecordingName.sanitizeFolderName("..") == "-.")
    let long = RecordingName.sanitizeFolderName(String(repeating: "é", count: 300))
    #expect(long.utf8.count <= RecordingName.maxBytes)
    #expect(long.utf8.count >= RecordingName.maxBytes - 1)
}

@Test func closeExpiredClosesEndedRecordingWithoutNewChunks() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let id = UUID()
    var results = run(r, tl, through: 40, events: [20: [(.started(tl.hit(start: 20, id: id)), true)]])
    // Audio stops at chunk 40, exactly when the hit ends: nothing past the post-roll is held.
    results += r.handle(.ended(tl.hit(start: 20, end: 40, id: id)), record: true)
    #expect(results.isEmpty)
    // Limit: chunk 40 + 12.5 (post-roll) + 12.5 (grace) = chunk 65.
    #expect(r.closeExpired(now: tl.at(64)).isEmpty)
    #expect(r.currentPath(for: id) != nil)
    let closed = r.closeExpired(now: tl.at(66))
    #expect(closed.count == 1)
    let result = try #require(closed.first)
    #expect(result.hitID == id); #expect(result.error == nil); #expect(!result.skippedShort)
    #expect(chunkIndices(try samples(try #require(result.path))) == Array(8...40))
    #expect(r.currentPath(for: id) == nil)
    #expect(r.closeExpired(now: tl.at(200)).isEmpty)
}

@Test func closeExpiredLeavesOpenOrRecentRecordingsAlone() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    #expect(r.closeExpired(now: tl.at(100)).isEmpty)  // nothing recording
    let open = UUID(), recent = UUID()
    _ = run(r, tl, through: 30, events: [20: [(.started(tl.hit(start: 20, id: open)), true)]])
    // Still open (no .ended), however late: left alone.
    #expect(r.closeExpired(now: tl.at(10_000)).isEmpty)
    #expect(r.currentPath(for: open) != nil)
    // A held chunk past the post-roll closes it in handle(.ended), as before.
    _ = run(r, tl, from: 31, through: 60)
    #expect(r.handle(.ended(tl.hit(start: 20, end: 30, id: open)), record: true).count == 1)

    _ = run(r, tl, from: 61, through: 80, events: [70: [(.started(tl.hit(start: 70, id: recent)), true)]])
    #expect(r.handle(.ended(tl.hit(start: 70, end: 80, id: recent)), record: true).isEmpty)
    // Ended, but within post-roll + grace (limit chunk 105): left alone.
    #expect(r.closeExpired(now: tl.at(90)).isEmpty)
    #expect(r.closeExpired(now: tl.at(104)).isEmpty)
    #expect(r.currentPath(for: recent) != nil)
}

@Test func recordFalseWritesNothing() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let id = UUID()
    let results = run(r, tl, through: 100, events: [
        25: [(.started(tl.hit(start: 25, id: id)), false)],
        75: [(.ended(tl.hit(start: 25, end: 50, id: id)), false)],
    ])
    #expect(results == [])
    #expect(r.finishAll() == [])
    #expect(folder.files().isEmpty)
}

@Test func unrecordedStartClosesPostRollRecording() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let a = UUID(), b = UUID()
    var results = run(r, tl, through: 52, events: [
        25: [(.started(tl.hit(start: 25, id: a)), true)],
        52: [(.ended(tl.hit(start: 25, end: 50, id: a)), true)],
    ])
    #expect(results == [])
    // Feed chunks 53...55, then B starts unrecorded at chunk 55, inside A's post-roll.
    for k in 53...55 { results += r.ingest(tl.chunk(k)) }
    results += r.handle(.started(tl.hit(start: 55, id: b)), record: false)
    #expect(results.count == 1)
    let path = try #require(results.first?.path)
    #expect(results.first?.hitID == a)
    // A keeps its post-roll up to (not including) B's first chunk.
    #expect(chunkIndices(try samples(path)) == Array(13...54))
    #expect(r.finishAll() == [])
}

@Test func newHitDuringPostRollGetsTheOverlap() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let a = UUID(), b = UUID()
    // channelChanged: A (25...50) ends and B starts on the same push (chunk 55).
    let results = run(r, tl, through: 120, events: [
        25: [(.started(tl.hit(start: 25, id: a)), true)],
        55: [(.ended(tl.hit(start: 25, end: 50, id: a)), true),
             (.started(tl.hit(start: 55, id: b, channel: "Ridge Ops")), true)],
        82: [(.ended(tl.hit(start: 55, end: 80, id: b, channel: "Ridge Ops")), true)],
    ])
    #expect(results.map(\.hitID) == [a, b])
    let sa = chunkIndices(try samples(try #require(results.first?.path)))
    let sb = chunkIndices(try samples(try #require(results.dropFirst().first?.path)))
    // A keeps everything through its last active push; the chunks after it that fall in B's
    // pre-roll go to B only.
    #expect(sa == Array(13...50))
    #expect(sb == Array(51...92))
    #expect(Set(sa).isDisjoint(with: sb))
}

@Test func finishAllClosesAnOpenHit() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let id = UUID()
    let during = run(r, tl, through: 60, events: [25: [(.started(tl.hit(start: 25, id: id)), true)]])
    #expect(during == [])
    let results = r.finishAll()
    #expect(results.count == 1)
    #expect(chunkIndices(try samples(try #require(results.first?.path))) == Array(13...60))
    #expect(r.finishAll() == [])
}

@Test func finishAllClosesAPostRollHitWithNoMoreAudio() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let id = UUID()
    _ = run(r, tl, through: 55, events: [
        25: [(.started(tl.hit(start: 25, id: id)), true)],
        52: [(.ended(tl.hit(start: 25, end: 50, id: id)), true)],
    ])
    let results = r.finishAll()
    #expect(chunkIndices(try samples(try #require(results.first?.path))) == Array(13...55))
}

@Test func flushMakesTheOpenFileValid() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let id = UUID()
    var h = tl.hit(start: 25, id: id)
    _ = run(r, tl, through: 40, events: [25: [(.started(h), true)]])
    h.endInstant = tl.at(40)
    #expect(r.handle(.updated(h), record: true) == [])
    try r.flush()
    let name = try #require(folder.files().first)
    let s = try samples(folder.url.appendingPathComponent(name).path)  // checks the data size field
    #expect(chunkIndices(s) == Array(13...40))
    _ = r.finishAll()
}

@Test func collisionSuffix() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let id = UUID()
    let base = (RecordingName.fileName(for: tl.hit(start: 25, id: id)) as NSString).deletingPathExtension
    for name in ["\(base).wav", "\(base) (2).wav"] {
        #expect(FileManager.default.createFile(atPath: folder.url.appendingPathComponent(name).path, contents: Data("x".utf8)))
    }
    let r = TransmissionRecorder(folder: folder.url)
    let results = run(r, tl, through: 100, events: [
        25: [(.started(tl.hit(start: 25, id: id)), true)],
        75: [(.ended(tl.hit(start: 25, end: 50, id: id)), true)],
    ])
    let path = try #require(results.first?.path)
    #expect(URL(fileURLWithPath: path).lastPathComponent == "\(base) (3).wav")
    // The existing files are untouched.
    #expect(try Data(contentsOf: folder.url.appendingPathComponent("\(base).wav")) == Data("x".utf8))
}

@Test func collisionSuffixGivesUpAfter999() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let id = UUID()
    let base = (RecordingName.fileName(for: tl.hit(start: 25, id: id)) as NSString).deletingPathExtension
    let names = ["\(base).wav"] + (2...999).map { "\(base) (\($0)).wav" }
    for name in names {
        #expect(FileManager.default.createFile(atPath: folder.url.appendingPathComponent(name).path, contents: nil))
    }
    let r = TransmissionRecorder(folder: folder.url)
    _ = run(r, tl, through: 25)
    let results = r.handle(.started(tl.hit(start: 25, id: id)), record: true)
    #expect(results.count == 1)
    #expect(results.first?.path == nil); #expect(results.first?.error != nil)
    #expect(folder.files().count == 999)
}

// MARK: - Write failures (fault injection)

private struct DiskFull: Error {}

/// Wraps a real `WAVWriter`; the `failOnFlush`-th flush (or any close, if `failOnClose`) fails
/// as a full disk would, before writing anything. After a failure every call fails, and the inner
/// writer is abandoned unflushed, so the file keeps only what earlier flushes wrote.
private final class FaultyWriter: RecordingWriter {
    let inner: WAVWriter
    let failOnFlush: Int?
    let failOnClose: Bool
    var flushes = 0
    var broken = false

    init(url: URL, failOnFlush: Int? = nil, failOnClose: Bool = false) throws {
        inner = try WAVWriter(url: url); self.failOnFlush = failOnFlush; self.failOnClose = failOnClose
    }
    var samplesWritten: Int { inner.samplesWritten }
    var flushedSampleCount: Int { inner.flushedSampleCount }
    func append(_ samples: [Int16]) throws {
        if broken { throw DiskFull() }
        try inner.append(samples)
    }
    func flush() throws {
        flushes += 1
        if broken || flushes == failOnFlush { broken = true; throw DiskFull() }
        try inner.flush()
    }
    func close() throws {
        if broken || failOnClose { broken = true; throw DiskFull() }
        try inner.close()
    }
}

/// A recorder whose first writer is faulty and later ones are real.
private func faultyRecorder(_ folder: TempFolder, failOnFlush: Int? = nil, failOnClose: Bool = false)
    -> TransmissionRecorder {
    var made = 0
    return TransmissionRecorder(
        folder: folder.url, preRoll: .milliseconds(500), postRoll: .milliseconds(500), audioOffset: .zero,
        minimumDuration: .milliseconds(500),
        makeWriter: { url in
            made += 1
            return made == 1 ? try FaultyWriter(url: url, failOnFlush: failOnFlush, failOnClose: failOnClose)
                             : try WAVWriter(url: url)
        })
}

private func updated(_ tl: Timeline, start: Int, end: Int, id: UUID) -> HitEvent {
    var h = tl.hit(start: start, id: id); h.endInstant = tl.at(Double(end)); return .updated(h)
}

@Test func firstFlushFailureDeletesEmptyFile() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = faultyRecorder(folder, failOnFlush: 1)
    let id = UUID()
    var results = run(r, tl, through: 40, events: [
        25: [(.started(tl.hit(start: 25, id: id)), true)],
        40: [(updated(tl, start: 25, end: 40, id: id), true)],
    ])
    #expect(results == [])
    try r.flush()  // fails inside; never throws
    results += r.ingest(tl.chunk(41))
    #expect(results.count == 1)
    let result = try #require(results.first)
    #expect(result.hitID == id); #expect(result.error != nil); #expect(result.path == nil)
    #expect(!result.skippedShort)
    #expect(folder.files().isEmpty)
    // Nothing more for that hit; the next hit records normally.
    let later = UUID()
    let next = run(r, tl, from: 42, through: 160, events: [
        43: [(.ended(tl.hit(start: 25, end: 40, id: id)), true)],
        100: [(.started(tl.hit(start: 100, id: later)), true)],
        140: [(.ended(tl.hit(start: 100, end: 125, id: later)), true)],
    ])
    #expect(next.map(\.hitID) == [later])
    #expect(next.first?.error == nil)
    #expect(chunkIndices(try samples(try #require(next.first?.path))) == Array(88...137))
}

@Test func closeFailureWithNothingFlushedDeletesFile() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = faultyRecorder(folder, failOnClose: true)
    let id = UUID()
    let results = run(r, tl, through: 100, events: [
        25: [(.started(tl.hit(start: 25, id: id)), true)],
        75: [(.ended(tl.hit(start: 25, end: 50, id: id)), true)],
    ])
    #expect(results.count == 1)
    #expect(results.first?.error != nil); #expect(results.first?.path == nil)
    #expect(folder.files().isEmpty)
}

@Test func midFileFailureKeepsDurableSamples() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = faultyRecorder(folder, failOnFlush: 2)
    let id = UUID()
    var results = run(r, tl, through: 40, events: [
        25: [(.started(tl.hit(start: 25, id: id)), true)],
        40: [(updated(tl, start: 25, end: 40, id: id), true)],
    ])
    try r.flush()  // succeeds: chunks 13...40 are on disk
    results += run(r, tl, from: 41, through: 50, events: [50: [(updated(tl, start: 25, end: 50, id: id), true)]])
    try r.flush()  // fails: chunks 41...50 never reach the disk
    results += r.ingest(tl.chunk(51))
    #expect(results.count == 1)
    let result = try #require(results.first)
    #expect(result.hitID == id); #expect(result.error != nil); #expect(!result.skippedShort)
    let path = try #require(result.path)
    let s = try samples(path)  // also checks the header's data size matches the file
    #expect(s.count == 28 * 320)
    #expect(chunkIndices(s) == Array(13...40))
}

// MARK: - Closing at .ended

@Test func endedClosesAtOnceWhenHeldAudioRunsPastPostRoll() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let id = UUID(), next = UUID()
    // Audio stops after chunk 75 (squelch-gated), and `.ended` comes after the 1 s hangover.
    #expect(run(r, tl, through: 75, events: [25: [(.started(tl.hit(start: 25, id: id)), true)]]) == [])
    let results = r.handle(.ended(tl.hit(start: 25, end: 50, id: id)), record: true)
    #expect(results.count == 1)
    #expect(results.first?.hitID == id)
    #expect(chunkIndices(try samples(try #require(results.first?.path))) == Array(13...62))
    // The held chunks past the post-roll (63...75) went to the ring: the next hit's pre-roll uses them.
    #expect(r.handle(.started(tl.hit(start: 75, id: next)), record: true) == [])
    let last = r.finishAll()
    #expect(last.map(\.hitID) == [next])
    #expect(chunkIndices(try samples(try #require(last.first?.path))) == Array(63...75))
}

@Test func endedWaitsWhileHeldAudioIsWithinPostRoll() throws {
    let folder = try TempFolder(); defer { folder.remove() }
    let tl = Timeline()
    let r = TransmissionRecorder(folder: folder.url)
    let id = UUID()
    _ = run(r, tl, through: 60, events: [25: [(.started(tl.hit(start: 25, id: id)), true)]])
    #expect(r.handle(.ended(tl.hit(start: 25, end: 50, id: id)), record: true) == [])
    let results = run(r, tl, from: 61, through: 70)
    #expect(results.count == 1)
    #expect(chunkIndices(try samples(try #require(results.first?.path))) == Array(13...62))
}
