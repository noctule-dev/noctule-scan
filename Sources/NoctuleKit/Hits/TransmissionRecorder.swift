// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// What became of one hit's recording, emitted when the recording closes, is skipped, or fails.
///
/// - Success: `path` is set, `error` is nil.
/// - Too short: `skippedShort` is true, the file was deleted, `path` is nil.
/// - Failure: `error` is set. `path` is set only if some audio reached the file before the
///   failure (the partial file is kept); a file with no samples is deleted.
public struct RecordingResult: Sendable, Equatable {
    public var hitID: UUID
    public var path: String?
    public var error: String?
    public var skippedShort: Bool

    public init(hitID: UUID, path: String? = nil, error: String? = nil, skippedShort: Bool = false) {
        self.hitID = hitID; self.path = path; self.error = error; self.skippedShort = skippedShort
    }
}

/// What the recorder writes through: `WAVWriter`, or a fault-injecting fake in tests.
protocol RecordingWriter: AnyObject {
    var samplesWritten: Int { get }
    var flushedSampleCount: Int { get }
    func append(_ samples: [Int16]) throws
    func flush() throws
    func close() throws
}

extension WAVWriter: RecordingWriter {}

/// Records one 16-bit 8 kHz mono WAV per transmission, aligned to `HitDetector` events.
///
/// Feed it every audio chunk (`ingest`) and every hit event (`handle`, including `.updated`),
/// in arrival order. Not `Sendable`: the owner serializes access, calls `flush()` about once a
/// second, and calls `finishAll()` when it stops.
///
/// Timing. A chunk's time is `receivedAt + audioOffset`, compared with the hit's
/// `startInstant` and `endInstant` (the first and last active push).
/// - Pre-roll: the recorder keeps a ring of the chunks received within the last
///   `preRoll + max(audioOffset, 0)` of the newest one. (A positive offset means audio arrives
///   before its push, so the ring keeps that much more, or the pre-roll would come up short.)
///   A recorded `.started` writes the ring chunks whose time is at least `startInstant - preRoll`.
/// - During the hit, a chunk whose time is at most the hit's last known end (from `.started`,
///   `.updated` and `.ended`) is written at once. Later chunks are held until an event or a close
///   decides where they belong, so a hit is never padded by the detector's end hangover.
/// - Post-roll: after `.ended`, the first chunk whose time is past `endInstant + postRoll` closes
///   the recording: in `handle(.ended)` itself when a held chunk is already past it (the usual
///   case, because of the detector's end hangover), else in the `ingest` that brings it. The held chunks up to that limit are written; that chunk and any
///   later held ones go to the pre-roll ring, not to the file.
/// - A `.started` while the previous recording is still open or in post-roll closes it at once
///   (also when the new hit isn't recorded). Held chunks before the cut go to the old file (within
///   its post-roll); held chunks from the cut on go to the ring. The cut is the new hit's pre-roll
///   start when it is recorded, else its `startInstant`. Audio up to the old hit's last active
///   push always stays in the old file. No chunk is ever written to two files.
/// - `finishAll()` closes whatever is open: a hit in post-roll gets its held chunks up to its
///   post-roll limit, a hit still open gets all of them.
///
/// Gaps: before a chunk with `lostBefore = n`, `n × 320` zero samples are written, except on the
/// first chunk of a file (that gap lies before the recording starts). A discontinuity or a new
/// SSRC adds nothing.
///
/// Minimum duration is measured from the samples actually written (pre-roll, post-roll and
/// silence included): below `minimumDuration` the file is deleted and the result is
/// `skippedShort`.
///
/// Errors: an open or write failure ends that hit's recording with an `error` result and never
/// throws out of `ingest`, `handle`, or `flush`. The partial file is kept (with its path in the
/// result) only if it holds durable samples, those a successful flush put in the header; otherwise
/// it is deleted and the path is nil. Later hits record normally. A failure found by
/// `flush()` is returned by the next `ingest`, `handle`, or `finishAll` call.
///
/// Held chunks wait for the next `.updated`, so without `.updated` events a long transmission is
/// held in memory until it ends (at most `maxTransmission` of audio, 16 KB per second).
public final class TransmissionRecorder {
    private final class Recording {
        let hitID: UUID
        let url: URL
        let writer: any RecordingWriter
        /// The hit's last known active instant.
        var end: ContinuousClock.Instant
        var ended = false
        /// Chunks after `end`, not yet written, in arrival order.
        var pending: [AudioChunk] = []

        init(hitID: UUID, url: URL, writer: any RecordingWriter, end: ContinuousClock.Instant) {
            self.hitID = hitID; self.url = url; self.writer = writer; self.end = end
        }
    }

    enum RecorderError: Error, CustomStringConvertible {
        case noFreeName(String)
        var description: String {
            switch self {
            case .noFreeName(let name): "no free file name for \(name) (tried up to (999))"
            }
        }
    }

    static let samplesPerChunk = 320
    static let maxCollisionSuffix = 999

    private let folder: URL
    private let preRoll: Duration
    private let postRoll: Duration
    private let audioOffset: Duration
    private let minimumDuration: Duration
    private let makeWriter: (URL) throws -> any RecordingWriter

    private var ring: [AudioChunk] = []
    private var current: Recording?
    /// Results of failures found by `flush()`, returned by the next call that returns results.
    private var queued: [RecordingResult] = []

    public convenience init(folder: URL, preRoll: Duration = .milliseconds(500), postRoll: Duration = .milliseconds(500),
                audioOffset: Duration = .zero, minimumDuration: Duration = .milliseconds(500)) {
        self.init(folder: folder, preRoll: preRoll, postRoll: postRoll, audioOffset: audioOffset,
                  minimumDuration: minimumDuration, makeWriter: { try WAVWriter(url: $0) })
    }

    /// For tests: `makeWriter` creates each recording's writer (a fault-injecting fake, say).
    init(folder: URL, preRoll: Duration, postRoll: Duration, audioOffset: Duration, minimumDuration: Duration,
         makeWriter: @escaping (URL) throws -> any RecordingWriter) {
        self.makeWriter = makeWriter
        self.folder = folder
        self.preRoll = preRoll
        self.postRoll = postRoll
        self.audioOffset = audioOffset
        self.minimumDuration = minimumDuration
    }

    public func ingest(_ chunk: AudioChunk) -> [RecordingResult] {
        var out = takeQueued()
        guard let rec = current else {
            addToRing(chunk)
            return out
        }
        if rec.ended, time(chunk) > rec.end + postRoll {
            out.append(close(rec, limit: rec.end + postRoll, cut: nil))
            addToRing(chunk)
            return out
        }
        if let failure = accept(chunk, into: rec) { out.append(failure) }
        return out
    }

    public func handle(_ event: HitEvent, record: Bool) -> [RecordingResult] {
        var out = takeQueued()
        switch event {
        case .started(let hit):
            if let rec = current {
                guard rec.hitID != hit.id else { return out }
                let cut = record ? hit.startInstant - preRoll : hit.startInstant
                out.append(close(rec, limit: rec.ended ? rec.end + postRoll : nil, cut: cut))
            }
            if record, let failure = open(hit) { out.append(failure) }
        case .updated(let hit):
            if let rec = current, rec.hitID == hit.id, let end = hit.endInstant {
                if let failure = extend(rec, to: end) { out.append(failure) }
            }
        case .ended(let hit):
            if let rec = current, rec.hitID == hit.id {
                rec.ended = true
                if let failure = extend(rec, to: hit.endInstant ?? rec.end) {
                    out.append(failure)
                } else if let last = rec.pending.last, time(last) > rec.end + postRoll {
                    // The held audio already runs past the post-roll (the detector's hangover), so
                    // close now: squelch-gated audio may send no further chunk until the next
                    // transmission.
                    out.append(close(rec, limit: rec.end + postRoll, cut: nil))
                }
            }
        }
        return out
    }

    /// The path of the file recording hit `hitID`, while that recording is open (including its
    /// post-roll); nil when the hit isn't being recorded or its recording has closed.
    public func currentPath(for hitID: UUID) -> String? {
        guard let rec = current, rec.hitID == hitID else { return nil }
        return rec.url.path
    }

    /// How long past its post-roll an ended recording may wait for a chunk before
    /// `closeExpired(now:)` closes it anyway.
    public static let expiryGrace: Duration = .milliseconds(500)

    /// Closes an ended recording whose post-roll limit (`endInstant + postRoll`) plus
    /// `expiryGrace` lies before `now + audioOffset` (the time a chunk received now would have).
    /// Held chunks within the post-roll are written. For audio that stops arriving (a dropped or
    /// squelch-gated stream), where no later chunk would ever close it. Open hits are left alone.
    public func closeExpired(now: ContinuousClock.Instant) -> [RecordingResult] {
        var out = takeQueued()
        if let rec = current, rec.ended, now + audioOffset > rec.end + postRoll + Self.expiryGrace {
            out.append(close(rec, limit: rec.end + postRoll, cut: nil))
        }
        return out
    }

    /// Flushes the open writer (header sizes and fsync). A failure ends that recording; its result
    /// comes from the next `ingest`, `handle` or `finishAll`. Never throws.
    public func flush() throws {
        guard let rec = current else { return }
        do {
            try rec.writer.flush()
        } catch {
            queued.append(fail(rec, error))
        }
    }

    public func finishAll() -> [RecordingResult] {
        var out = takeQueued()
        if let rec = current {
            out.append(close(rec, limit: rec.ended ? rec.end + postRoll : nil, cut: nil))
        }
        return out
    }

    // MARK: - Internals

    private func time(_ chunk: AudioChunk) -> ContinuousClock.Instant { chunk.receivedAt + audioOffset }

    private func takeQueued() -> [RecordingResult] {
        defer { queued = [] }
        return queued
    }

    private func addToRing(_ chunk: AudioChunk) {
        ring.append(chunk)
        let keep = preRoll + max(audioOffset, .zero)
        let oldest = chunk.receivedAt - keep
        if let firstKept = ring.firstIndex(where: { $0.receivedAt >= oldest }) {
            ring.removeFirst(firstKept)
        } else {
            ring.removeAll()
        }
    }

    /// Opens the hit's file and writes its pre-roll. Returns a result only on failure.
    private func open(_ hit: Hit) -> RecordingResult? {
        let name = RecordingName.fileName(for: hit)
        var url: URL?
        do {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = try freeURL(for: name)
            url = target
            let writer = try makeWriter(target)
            let rec = Recording(hitID: hit.id, url: target, writer: writer, end: hit.endInstant ?? hit.startInstant)
            current = rec
        } catch {
            // The name was free a moment ago, so anything there now is our own empty attempt.
            if let url, FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            return RecordingResult(hitID: hit.id, path: nil,
                                   error: "could not create \(url?.lastPathComponent ?? name): \(Self.describe(error))")
        }
        let windowStart = hit.startInstant - preRoll
        let preRollChunks = ring.filter { time($0) >= windowStart }
        ring.removeAll()
        for chunk in preRollChunks {
            guard let rec = current else { break }
            if let failure = accept(chunk, into: rec) { return failure }
        }
        return nil
    }

    private func freeURL(for name: String) throws -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) { return first }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2...Self.maxCollisionSuffix {
            let candidate = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw RecorderError.noFreeName(name)
    }

    /// Writes the chunk if it falls within the hit's known end, else holds it.
    private func accept(_ chunk: AudioChunk, into rec: Recording) -> RecordingResult? {
        if time(chunk) <= rec.end {
            if let failure = writePending(rec, upTo: rec.end) { return failure }
            return write(chunk, to: rec)
        }
        rec.pending.append(chunk)
        return nil
    }

    private func extend(_ rec: Recording, to end: ContinuousClock.Instant) -> RecordingResult? {
        if end > rec.end { rec.end = end }
        return writePending(rec, upTo: rec.end)
    }

    /// Writes held chunks from the front while their time is at most `limit`.
    private func writePending(_ rec: Recording, upTo limit: ContinuousClock.Instant) -> RecordingResult? {
        // Take them out first, so a failure (which sends what is still held to the ring) can't
        // hand an already-written chunk to the next recording.
        let count = rec.pending.prefix(while: { time($0) <= limit }).count
        guard count > 0 else { return nil }
        let due = rec.pending.prefix(count)
        rec.pending.removeFirst(count)
        for chunk in due {
            if let failure = write(chunk, to: rec) { return failure }
        }
        return nil
    }

    private func write(_ chunk: AudioChunk, to rec: Recording) -> RecordingResult? {
        do {
            if chunk.lostBefore > 0, rec.writer.samplesWritten > 0 {
                try rec.writer.append(Array(repeating: 0, count: chunk.lostBefore * Self.samplesPerChunk))
            }
            try rec.writer.append(chunk.samples)
            return nil
        } catch {
            return fail(rec, error)
        }
    }

    /// Closes `rec`: writes held chunks whose time is at most `limit` (nil: no limit) and before
    /// `cut` (nil: no cut), sends the rest to the ring, and returns the result.
    private func close(_ rec: Recording, limit: ContinuousClock.Instant?, cut: ContinuousClock.Instant?) -> RecordingResult {
        current = nil
        let held = rec.pending
        rec.pending = []
        var index = 0
        while index < held.count {
            let t = time(held[index])
            if let limit, t > limit { break }
            if let cut, t >= cut { break }
            if let failure = write(held[index], to: rec) {
                for chunk in held[(index + 1)...] { addToRing(chunk) }
                return failure
            }
            index += 1
        }
        for chunk in held[index...] { addToRing(chunk) }

        let samples = rec.writer.samplesWritten
        do {
            try rec.writer.close()
        } catch {
            return failureResult(rec, error)
        }
        if Duration.microseconds(Int64(samples) * 125) < minimumDuration {
            try? FileManager.default.removeItem(at: rec.url)
            return RecordingResult(hitID: rec.hitID, path: nil, error: nil, skippedShort: true)
        }
        return RecordingResult(hitID: rec.hitID, path: rec.url.path)
    }

    /// Ends `rec` after a write or flush error: closes what it can, keeps a file that has samples,
    /// and sends held chunks to the ring.
    private func fail(_ rec: Recording, _ error: any Error) -> RecordingResult {
        if current === rec { current = nil }
        try? rec.writer.close()
        for chunk in rec.pending { addToRing(chunk) }
        rec.pending = []
        return failureResult(rec, error)
    }

    /// Keeps the file only if some samples are durable (flushed, in the header, synced); buffered
    /// samples that never reached the disk don't count. A kept partial file is never deleted for
    /// being shorter than `minimumDuration`: it is evidence of the failure, and it has audio.
    private func failureResult(_ rec: Recording, _ error: any Error) -> RecordingResult {
        let message = "could not write \(rec.url.lastPathComponent): \(Self.describe(error))"
        if rec.writer.flushedSampleCount == 0 {
            try? FileManager.default.removeItem(at: rec.url)
            return RecordingResult(hitID: rec.hitID, path: nil, error: message)
        }
        return RecordingResult(hitID: rec.hitID, path: rec.url.path, error: message)
    }

    private static func describe(_ error: any Error) -> String {
        if let e = error as? RecorderError { return e.description }
        return error.localizedDescription
    }
}
