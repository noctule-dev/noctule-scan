// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

@Test func muLawReferenceValues() {
    #expect(MuLaw.decode(0xFF) == 0); #expect(MuLaw.decode(0x7F) == 0)
    #expect(MuLaw.decode(0x00) == -32124); #expect(MuLaw.decode(0x80) == 32124)
    #expect(MuLaw.decode(0xF0) == 120); #expect(MuLaw.decode(0x70) == -120)
    #expect(MuLaw.decode(Data([0xFF, 0x80, 0x00])) == [0, 32124, -32124])
}

@Test func parsesMinimalPacket() throws {
    let bytes: [UInt8] = [0x80, 0x00, 0x12, 0x34, 0x00, 0x00, 0x01, 0x40, 0xDE, 0xAD, 0xBE, 0xEF, 0xFF, 0x7F]
    let p = try RTPPacket(parsing: Data(bytes))
    #expect(p.payloadType == 0); #expect(p.sequence == 0x1234); #expect(p.timestamp == 320)
    #expect(p.ssrc == 0xDEADBEEF); #expect(p.payload == Data([0xFF, 0x7F])); #expect(p.marker == false)
}

@Test func parsesMarkerAndPayloadType() throws {
    let bytes: [UInt8] = [0x80, 0x88, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 1, 0x55]
    let p = try RTPPacket(parsing: Data(bytes))
    #expect(p.marker); #expect(p.payloadType == 8); #expect(p.payload == Data([0x55]))
}

@Test func skipsCSRCExtensionAndPadding() throws {
    let bytes: [UInt8] = [
        0xB1, 0x00, 0x00, 0x07,             // V=2 P=1 X=1 CC=1, PT 0, seq 7
        0x00, 0x00, 0x03, 0x20,             // ts 800
        0x00, 0x00, 0x00, 0x2A,             // ssrc 42
        0x11, 0x22, 0x33, 0x44,             // csrc
        0xBE, 0xDE, 0x00, 0x01,             // ext header, 1 word
        0x01, 0x02, 0x03, 0x04,             // ext word
        0xAA, 0xBB,                         // payload
        0x00, 0x02,                         // padding (2)
    ]
    let p = try RTPPacket(parsing: Data(bytes))
    #expect(p.sequence == 7); #expect(p.timestamp == 800); #expect(p.ssrc == 42)
    #expect(p.payload == Data([0xAA, 0xBB]))
}

@Test func rejectsBadPackets() {
    #expect(throws: RTPPacketError.tooShort) { try RTPPacket(parsing: Data(repeating: 0x80, count: 11)) }
    #expect(throws: RTPPacketError.badVersion(1)) { try RTPPacket(parsing: Data([0x40] + Array(repeating: 0, count: 11))) }
    // CSRC count overruns
    #expect(throws: RTPPacketError.tooShort) { try RTPPacket(parsing: Data([0x82] + Array(repeating: 0, count: 15))) }
    // extension header missing / length overruns
    #expect(throws: RTPPacketError.badExtension) { try RTPPacket(parsing: Data([0x90] + Array(repeating: 0, count: 11))) }
    #expect(throws: RTPPacketError.badExtension) {
        try RTPPacket(parsing: Data([0x90] + Array(repeating: 0, count: 11) + [0xBE, 0xDE, 0x00, 0x05, 0, 0]))
    }
    // padding count zero, or larger than the payload
    #expect(throws: RTPPacketError.badPadding) { try RTPPacket(parsing: Data([0xA0] + Array(repeating: 0, count: 11) + [0x00])) }
    #expect(throws: RTPPacketError.badPadding) { try RTPPacket(parsing: Data([0xA0] + Array(repeating: 0, count: 11) + [0x09])) }
}

@Test func parsesSlicedData() throws {
    let bytes: [UInt8] = [0xEE, 0xEE, 0x80, 0x00, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0, 1, 0x10]
    let p = try RTPPacket(parsing: Data(bytes)[2...])
    #expect(p.sequence == 2); #expect(p.payload == Data([0x10]))
}

@Test func trackerHandlesWrapGapDuplicateReorder() {
    var t = RTPSequenceTracker()
    #expect(t.observe(65534) == .first); #expect(t.observe(65535) == .inOrder); #expect(t.observe(0) == .inOrder)
    #expect(t.observe(3) == .gap(missing: 2)); #expect(t.lost == 2)
    #expect(t.observe(1) == .reordered); #expect(t.lost == 1)
    #expect(t.observe(3) == .duplicate); #expect(t.duplicates == 1)
    #expect(t.reordered == 1)
    #expect(t.received == 5)
    #expect(t.observe(40000) == .first)   // restart
    #expect(t.received == 6)
}

@Test func trackerDuplicateWithinWindowAndFarJumps() {
    var t = RTPSequenceTracker()
    _ = t.observe(100)
    for s in UInt16(101)...110 { _ = t.observe(s) }
    #expect(t.observe(105) == .duplicate)
    #expect(t.observe(110) == .duplicate)
    #expect(t.duplicates == 2)
    #expect(t.observe(110 + 3001) == .first)       // forward jump over 3000
    #expect(t.observe(3111 + 3000) == .gap(missing: 2999))
    #expect(t.observe(6111 - 65) == .stale)        // backward over 64: too late to place
    #expect(t.observe(6111 - 3001) == .first)      // backward over 3000: the stream reset
    t.reset()
    #expect(t.received == 0 && t.lost == 0 && t.duplicates == 0 && t.reordered == 0)
    #expect(t.observe(5) == .first)
}

@Test func trackerFlagsStalePacketsWithoutRestarting() {
    var t = RTPSequenceTracker()
    for s in UInt16(0)...99 { _ = t.observe(s) }
    #expect(t.observe(10) == .stale)
    #expect(t.observe(100) == .inOrder)
    #expect(t.lost == 0)
    #expect(t.stale == 1)
    #expect(t.received == 101)
    t.reset()
    #expect(t.stale == 0)
}

@Test func trackerRestartsAfterARunOfStalePackets() {
    // A same-SSRC sequence reset a little way back must not silence the stream until it
    // catches up: after 8 stale packets in a row the tracker restarts at the 8th.
    var t = RTPSequenceTracker()
    for s in UInt16(1000)...1010 { _ = t.observe(s) }
    for s in UInt16(500)..<507 { #expect(t.observe(s) == .stale) }
    #expect(t.observe(507) == .first)
    #expect(t.observe(508) == .inOrder)
    #expect(t.stale == 7)
    #expect(t.lost == 0)
}

@Test func trackerStaleRunIsBrokenByAPlacedPacket() {
    var t = RTPSequenceTracker()
    for s in UInt16(1000)...1010 { _ = t.observe(s) }
    for s in UInt16(500)..<507 { _ = t.observe(s) }
    #expect(t.observe(1011) == .inOrder)
    #expect(t.observe(507) == .stale)
    #expect(t.stale == 8)
}

@Test func trackerReorderOfNeverMissingDoesNotGoNegative() {
    var t = RTPSequenceTracker()
    _ = t.observe(10); _ = t.observe(11)
    // 9 was never seen, never counted missing (we started at 10)
    #expect(t.observe(9) == .reordered)
    #expect(t.lost == 0)
}
