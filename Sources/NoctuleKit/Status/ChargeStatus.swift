// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum ChargeStatusError: Error, Equatable {
    case malformed(String)
}

/// The battery and charger state as returned by `GCS` (SDS150):
/// `GCS,CST=n,VOLT=nnnnmV:nn%,CURR=nnnnmA,TEMP=nn.nnC`. The spec's example has a space after `TEMP=`.
public struct ChargeStatus: Sendable, Equatable {
    public enum State: Int, Sendable { case notCharging = 0, initializing, temperatureFault, powerFault, full, recharge, charging }

    /// `nil` for a numeric `CST` outside 0...6.
    public var state: State?
    /// The `CST` code as reported, known or not (`state` is nil for one outside 0...6).
    public var stateCode: Int
    public var millivolts: Int
    public var percent: Int
    /// Positive while charging, negative while discharging.
    public var milliamps: Int
    public var celsius: Double

    /// Takes the reply's fields (`CST=…`, `VOLT=…`, `CURR=…`, `TEMP=…`, found by key in any order; other
    /// fields are ignored). Throws `.malformed` naming the field that is missing or unreadable.
    public init(fields: [String]) throws {
        func value(_ key: String) throws -> String {
            for field in fields {
                let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            throw ChargeStatusError.malformed("missing \(key)")
        }
        func number(_ text: String, suffix: String, in key: String) throws -> Int {
            guard text.hasSuffix(suffix), let n = Int(text.dropLast(suffix.count)) else {
                throw ChargeStatusError.malformed("\(key)=\(text)")
            }
            return n
        }

        let cst = try value("CST")
        guard let code = Int(cst) else { throw ChargeStatusError.malformed("CST=\(cst)") }
        stateCode = code
        state = State(rawValue: code)

        // VOLT=4184mV:100%
        let volt = try value("VOLT")
        let voltParts = volt.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard voltParts.count == 2 else { throw ChargeStatusError.malformed("VOLT=\(volt)") }
        millivolts = try number(voltParts[0], suffix: "mV", in: "VOLT")
        percent = try number(voltParts[1], suffix: "%", in: "VOLT")

        milliamps = try number(try value("CURR"), suffix: "mA", in: "CURR")

        let temp = try value("TEMP")
        guard temp.hasSuffix("C"), let degrees = Double(temp.dropLast()) else {
            throw ChargeStatusError.malformed("TEMP=\(temp)")
        }
        celsius = degrees
    }
}
