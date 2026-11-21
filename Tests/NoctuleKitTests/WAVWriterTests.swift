// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

private func tempURL(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wav-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

private extension Data {
    func le16(at i: Int) -> Int { Int(self[startIndex + i]) | Int(self[startIndex + i + 1]) << 8 }
    func le32(at i: Int) -> Int { le16(at: i) | le16(at: i + 2) << 16 }
}

@Test func headerAndSamplesAreExact() throws {
    let url = tempURL("a.wav"); let w = try WAVWriter(url: url)
    try w.append([0, 1, -1, 32767]); try w.close()
    let d = try Data(contentsOf: url)
    #expect(d.count == 44 + 8)
    #expect(d.prefix(4) == Data("RIFF".utf8)); #expect(d.le32(at: 4) == 36 + 8)
    #expect(d.subdata(in: 8..<16) == Data("WAVEfmt ".utf8)); #expect(d.le32(at: 16) == 16)
    #expect(d.le16(at: 20) == 1); #expect(d.le16(at: 22) == 1); #expect(d.le32(at: 24) == 8000)
    #expect(d.le32(at: 28) == 16000); #expect(d.le16(at: 32) == 2); #expect(d.le16(at: 34) == 16)
    #expect(d.subdata(in: 36..<40) == Data("data".utf8)); #expect(d.le32(at: 40) == 8)
    #expect(d.subdata(in: 44..<52) == Data([0x00,0x00, 0x01,0x00, 0xFF,0xFF, 0xFF,0x7F]))
    #expect(w.samplesWritten == 4)
}

@Test func initWritesHeaderWithZeroSizes() throws {
    let url = tempURL("empty.wav"); let w = try WAVWriter(url: url, sampleRate: 16000)
    let d = try Data(contentsOf: url)
    #expect(d.count == 44); #expect(d.le32(at: 4) == 36); #expect(d.le32(at: 24) == 16000)
    #expect(d.le32(at: 28) == 32000); #expect(d.le32(at: 40) == 0)
    try w.close()
}

@Test func initTruncatesExistingFile() throws {
    let url = tempURL("t.wav")
    try Data(repeating: 0xAB, count: 500).write(to: url)
    let w = try WAVWriter(url: url); try w.close()
    #expect(try Data(contentsOf: url).count == 44)
}

@Test func flushLeavesPlayableFileWithoutClose() throws {
    let url = tempURL("f.wav"); let w = try WAVWriter(url: url)
    try w.append([Int16](repeating: 7, count: 800)); try w.flush()
    let d = try Data(contentsOf: url)
    #expect(d.le32(at: 40) == 1600); #expect(d.le32(at: 4) == 1636); #expect(d.count == 1644)
    // appending after a flush continues at the end of the data
    try w.append([1, 2]); try w.flush()
    let d2 = try Data(contentsOf: url)
    #expect(d2.count == 1648); #expect(d2.le32(at: 40) == 1604); #expect(d2.le32(at: 4) == 1640)
    #expect(d2.subdata(in: 1644..<1648) == Data([1, 0, 2, 0]))
    try w.close()
}

@Test func appendAfterCloseThrows() throws {
    let w = try WAVWriter(url: tempURL("c.wav"))
    try w.close(); try w.close()
    #expect(throws: WAVWriterError.closed) { try w.append([1]) }
}

@Test func headerSizesGuardOverflow() throws {
    let ok = try WAVWriter.headerSizes(dataBytes: 1600)
    #expect(ok.riff == 1636); #expect(ok.data == 1600)
    let max = UInt64(UInt32.max) - 36
    let edge = try WAVWriter.headerSizes(dataBytes: max)
    #expect(edge.riff == UInt32.max); #expect(edge.data == UInt32(max))
    #expect(throws: WAVWriterError.tooLarge) { try WAVWriter.headerSizes(dataBytes: max + 1) }
}

@Test func flushedSampleCountCountsOnlyFlushedSamples() throws {
    let url = tempURL("durable.wav"); let w = try WAVWriter(url: url)
    try w.append([1, 2, 3])
    #expect(w.flushedSampleCount == 0); #expect(w.samplesWritten == 3)
    try w.flush()
    #expect(w.flushedSampleCount == 3)
    try w.append([4])
    #expect(w.flushedSampleCount == 3); #expect(w.samplesWritten == 4)
    try w.close()
    #expect(w.flushedSampleCount == 4)
}
