// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// ITU-T G.711 µ-law (PCMU) decoding, bias 132.
public enum MuLaw {
    private static let table: [Int16] = (0..<256).map { i in
        let u = ~UInt8(i)
        let exponent = Int((u >> 4) & 0x07)
        let mantissa = Int(u & 0x0F)
        let magnitude = (((mantissa << 3) + 132) << exponent) - 132
        return Int16(u & 0x80 != 0 ? -magnitude : magnitude)
    }

    public static func decode(_ byte: UInt8) -> Int16 { table[Int(byte)] }
    public static func decode(_ bytes: Data) -> [Int16] { bytes.map { table[Int($0)] } }
}
