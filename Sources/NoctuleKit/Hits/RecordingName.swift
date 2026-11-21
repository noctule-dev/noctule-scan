// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// File names for per-transmission recordings.
///
/// - Trunk: `YYYY-MM-DD HH-MM-SS · TG<id> · <channel>.wav`
/// - Conventional and weather: `YYYY-MM-DD HH-MM-SS · <freq>MHz · <channel>.wav`, frequency `%.4f`.
///
/// The time is `hit.startedAt` in `timeZone` (local by default). The separators are space, middle
/// dot (U+00B7), space. The channel and talkgroup parts are sanitized: `/ : \ * ? " < > |` and
/// control characters become `-`, runs of whitespace become one space, and the ends are trimmed.
/// An empty channel becomes `Unknown`. The channel is truncated on a `Character` boundary so the
/// whole name is at most `maxBytes` UTF-8 bytes. A hit with neither a talkgroup nor a frequency
/// (which the detector never produces) gets `Unknown` as its middle part.
public enum RecordingName {
    /// The longest file name, in UTF-8 bytes. APFS allows 255; this leaves room for a collision
    /// suffix such as ` (999)`.
    public static let maxBytes = 200
    /// The middle part (talkgroup or frequency) is capped so the channel always keeps some room.
    static let maxMiddleBytes = 64

    public static func fileName(for hit: Hit, timeZone: TimeZone = .current) -> String {
        let separator = " \u{00B7} "
        let middle: String
        if let tg = hit.key.talkgroupID {
            middle = truncate("TG" + nonEmpty(sanitize(tg)), toBytes: maxMiddleBytes)
        } else if let mhz = hit.key.frequencyMHz {
            middle = String(format: "%.4fMHz", mhz)
        } else {
            middle = "Unknown"
        }
        var prefix = timestamp(hit.startedAt, timeZone: timeZone) + separator + middle + separator
        // The name starts with the date, so it can never start with "."; guard anyway.
        if prefix.hasPrefix(".") { prefix = "-" + prefix.dropFirst() }
        let suffix = ".wav"
        let budget = maxBytes - prefix.utf8.count - suffix.utf8.count
        var channel = truncate(nonEmpty(sanitize(hit.channel ?? "")), toBytes: budget)
        channel = channel.trimmingCharacters(in: .whitespaces)
        if channel.isEmpty { channel = "Unknown" }
        return prefix + channel + suffix
    }

    /// A folder name from free text (a station name): the same sanitizing as file-name parts,
    /// `Unknown` when nothing is left, a leading `.` replaced with `-` (no hidden folders), and
    /// truncated on a `Character` boundary to `maxBytes` UTF-8 bytes.
    public static func sanitizeFolderName(_ name: String) -> String {
        var out = nonEmpty(sanitize(name))
        if out.hasPrefix(".") { out = "-" + out.dropFirst() }
        return truncate(out, toBytes: maxBytes)
    }

    /// Replaces forbidden characters and control characters with `-`, collapses whitespace runs to
    /// one space, and trims.
    static func sanitize(_ s: String) -> String {
        let forbidden: Set<Unicode.Scalar> = ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"]
        var replaced = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if forbidden.contains(scalar) || scalar.properties.generalCategory == .control {
                replaced.append("-")
            } else {
                replaced.append(scalar)
            }
        }
        var out = ""
        var inWhitespace = false
        for ch in String(replaced) {
            if ch.isWhitespace {
                if !inWhitespace { out.append(" ") }
                inWhitespace = true
            } else {
                out.append(ch)
                inWhitespace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func nonEmpty(_ s: String) -> String { s.isEmpty ? "Unknown" : s }

    /// The longest prefix of whole `Character`s that fits in `limit` UTF-8 bytes.
    private static func truncate(_ s: String, toBytes limit: Int) -> String {
        guard s.utf8.count > limit else { return s }
        var out = ""
        var bytes = 0
        for ch in s {
            let n = String(ch).utf8.count
            if bytes + n > limit { break }
            out.append(ch)
            bytes += n
        }
        return out
    }

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d-%02d-%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
