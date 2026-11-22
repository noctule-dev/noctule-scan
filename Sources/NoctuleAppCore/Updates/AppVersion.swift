// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// A semantic version (SemVer 2.0.0, no build metadata): `1.2.3` or `1.2.3-beta.4`, with an
/// optional leading `v`. The grammar is `release.sh`'s `semver` pattern.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// `[]` for a final release, `["beta", "4"]` for `-beta.4`.
    public let prerelease: [String]

    public init?(_ text: String) {
        var body = Substring(text)
        if body.hasPrefix("v") { body = body.dropFirst() }
        let halves = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = halves[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in core {
            guard Self.isNumeric(part), part == "0" || !part.hasPrefix("0"), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        var identifiers: [String] = []
        if halves.count == 2 {
            let parts = halves[1].split(separator: ".", omittingEmptySubsequences: false)
            for part in parts {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
                else { return nil }
                identifiers.append(String(part))
            }
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        prerelease = identifiers
    }

    public var isFinal: Bool { prerelease.isEmpty }

    /// `0.0.0` with no prerelease: a build that wasn't stamped with a release version.
    public var isDevelopment: Bool { major == 0 && minor == 0 && patch == 0 && prerelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // A final release is above any prerelease of the same number.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.isFinal && b.isFinal }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            return identifierPrecedes(x, y)
        }
        return a.prerelease.count < b.prerelease.count
    }

    private static func isNumeric(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// SemVer §11: numeric identifiers by value and below alphanumeric ones, which go by ASCII.
    private static func identifierPrecedes(_ x: String, _ y: String) -> Bool {
        let xNumeric = isNumeric(Substring(x)), yNumeric = isNumeric(Substring(y))
        switch (xNumeric, yNumeric) {
        case (true, true):
            // By length then text, so a long run of digits can't overflow.
            let a = x.drop { $0 == "0" }, b = y.drop { $0 == "0" }
            return a.count != b.count ? a.count < b.count : a < b
        case (true, false): return true
        case (false, true): return false
        case (false, false): return x.utf8.lexicographicallyPrecedes(y.utf8)
        }
    }
}
