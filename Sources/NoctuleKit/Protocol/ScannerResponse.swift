// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum ScannerResponse: Sendable, Equatable {
    case fields(command: String, fields: [String])
    case xml(command: String, root: XMLNode)

    public var command: String {
        switch self {
        case .fields(let command, _): command
        case .xml(let command, _): command
        }
    }
}

public enum ResponseStatus: Equatable {
    case ok
    case rejected(String)
}

extension ScannerResponse {
    public var status: ResponseStatus? {
        switch self {
        case .fields(let command, let fields):
            guard fields.count == 1 else { return nil }
            switch fields[0] {
            case "OK": return .ok
            case "NG", "ERR", "ERROR": return .rejected("\(command),\(fields.joined(separator: ","))")
            default: return nil
            }
        case .xml:
            return nil
        }
    }
}

extension String {
    /// Scanner text as both transports decode it: lossy UTF-8 (some display fields hold
    /// bytes that aren't valid) with NUL characters removed.
    init(scannerBytes: Data) {
        self = String(decoding: scannerBytes, as: UTF8.self).filter { $0 != "\u{0}" }
    }
}

public enum ResponseLineParser {
    public static func parse(_ line: String) -> ScannerResponse? {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n "))
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return .fields(command: parts[0].uppercased(), fields: Array(parts.dropFirst()))
    }
}
