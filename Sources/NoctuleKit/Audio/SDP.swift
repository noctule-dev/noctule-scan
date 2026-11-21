// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public struct SDPAudioDescription: Sendable, Equatable {
    public var payloadType: Int
    public var control: String?

    public init(payloadType: Int, control: String?) {
        self.payloadType = payloadType; self.control = control
    }

    public static func parse(_ text: String) throws -> SDPAudioDescription {
        var sessionControl: String?
        var mediaControl: String?
        var payloadType: Int?
        var inAudio = false
        var seenMedia = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                seenMedia = true
                let fields = line.dropFirst(2).split(separator: " ")
                if payloadType == nil, fields.count >= 4, fields[0] == "audio", let pt = Int(fields[3]) {
                    payloadType = pt
                    inAudio = true
                } else {
                    inAudio = false
                }
            } else if line.hasPrefix("a=control:") {
                let value = String(line.dropFirst("a=control:".count))
                if !seenMedia { sessionControl = value } else if inAudio, mediaControl == nil { mediaControl = value }
            }
        }
        guard let pt = payloadType else { throw RTSPError.malformed("SDP has no audio media line") }
        return SDPAudioDescription(payloadType: pt, control: mediaControl ?? sessionControl)
    }
}
