// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum RTPPacketError: Error, Equatable, Sendable {
    case tooShort
    case badVersion(UInt8)
    case badPadding
    case badExtension
}

public struct RTPPacket: Sendable, Equatable {
    public var payloadType: UInt8
    public var marker: Bool
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var payload: Data

    public init(parsing data: Data) throws {
        let b = Array(data)
        guard b.count >= 12 else { throw RTPPacketError.tooShort }
        let version = b[0] >> 6
        guard version == 2 else { throw RTPPacketError.badVersion(version) }
        let hasPadding = b[0] & 0x20 != 0
        let hasExtension = b[0] & 0x10 != 0
        let csrcCount = Int(b[0] & 0x0F)
        marker = b[1] & 0x80 != 0
        payloadType = b[1] & 0x7F
        sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        timestamp = b[4...7].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        ssrc = b[8...11].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

        var start = 12 + 4 * csrcCount
        guard start <= b.count else { throw RTPPacketError.tooShort }
        if hasExtension {
            guard start + 4 <= b.count else { throw RTPPacketError.badExtension }
            let words = Int(b[start + 2]) << 8 | Int(b[start + 3])
            start += 4 + 4 * words
            guard start <= b.count else { throw RTPPacketError.badExtension }
        }
        var end = b.count
        if hasPadding {
            guard end > start else { throw RTPPacketError.badPadding }
            let pad = Int(b[end - 1])
            guard pad >= 1, pad <= end - start else { throw RTPPacketError.badPadding }
            end -= pad
        }
        payload = Data(b[start..<end])
    }
}
