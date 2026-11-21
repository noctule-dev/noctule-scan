// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum WAVWriterError: Error, Equatable {
    case closed
    /// The data would not fit the 32-bit RIFF size fields.
    case tooLarge
}

/// Writes mono 16-bit little-endian PCM WAV. `flush()` writes buffered samples and
/// patches both size fields, then fsyncs, so a killed process leaves a valid file.
///
/// Not thread-safe and not `Sendable`; owners must serialize access.
public final class WAVWriter {
    private var handle: FileHandle?
    private var buffer: [Int16] = []
    private var flushedSamples = 0

    public init(url: URL, sampleRate: Int = 8000) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let h = try FileHandle(forWritingTo: url)
        do {
            try h.write(contentsOf: Self.header(sampleRate: sampleRate))
        } catch {
            try? h.close()
            throw error
        }
        handle = h
    }

    deinit { try? handle?.close() }

    public var samplesWritten: Int { flushedSamples + buffer.count }

    /// Samples on disk, counted in the header and synced, as of the last successful `flush`.
    public var flushedSampleCount: Int { flushedSamples }

    public func append(_ samples: [Int16]) throws {
        guard handle != nil else { throw WAVWriterError.closed }
        buffer.append(contentsOf: samples)
    }

    public func flush() throws {
        guard let h = handle else { throw WAVWriterError.closed }
        let total = UInt64(flushedSamples + buffer.count) * 2
        let sizes = try Self.headerSizes(dataBytes: total)
        if !buffer.isEmpty {
            var bytes = Data(capacity: buffer.count * 2)
            for s in buffer {
                let le = s.littleEndian
                bytes.append(UInt8(truncatingIfNeeded: le))
                bytes.append(UInt8(truncatingIfNeeded: le >> 8))
            }
            try h.seek(toOffset: 44 + UInt64(flushedSamples) * 2)
            try h.write(contentsOf: bytes)
        }
        try h.seek(toOffset: 4)
        try h.write(contentsOf: Self.le32(sizes.riff))
        try h.seek(toOffset: 40)
        try h.write(contentsOf: Self.le32(sizes.data))
        try h.seekToEnd()
        try h.synchronize()
        // Count the samples as flushed only once the header covers them and they're synced, so
        // `flushedSampleCount` never claims more than is durable. A failed flush keeps them
        // buffered; a retry rewrites them at the same offset.
        flushedSamples += buffer.count
        buffer.removeAll(keepingCapacity: true)
    }

    public func close() throws {
        guard let h = handle else { return }
        do { try flush() } catch {
            handle = nil
            try? h.close()
            throw error
        }
        handle = nil
        try h.close()
    }

    static func headerSizes(dataBytes: UInt64) throws -> (riff: UInt32, data: UInt32) {
        guard dataBytes + 36 <= UInt64(UInt32.max) else { throw WAVWriterError.tooLarge }
        return (UInt32(dataBytes + 36), UInt32(dataBytes))
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
              UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)])
    }

    private static func le16(_ v: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)])
    }

    private static func header(sampleRate: Int) -> Data {
        var d = Data("RIFF".utf8)
        d += le32(36); d += Data("WAVEfmt ".utf8); d += le32(16)
        d += le16(1); d += le16(1); d += le32(UInt32(sampleRate))
        d += le32(UInt32(sampleRate * 2)); d += le16(2); d += le16(16)
        d += Data("data".utf8); d += le32(0)
        return d
    }
}
