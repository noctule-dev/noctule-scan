// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// What an `HLD` command holds on (BCD436HP design §3.5a): a system, a department (with its system),
/// a trunked talkgroup or a conventional frequency, each by its Favorites `Index`.
public enum HoldTarget: Sendable, Equatable {
    case system(index: UInt32)
    case department(index: UInt32, system: UInt32)
    case trunkChannel(index: UInt32)
    case conventionalChannel(index: UInt32)

    /// `HLD,SYS,<i>,`, `HLD,DEPT,<i>,<system i>`, `HLD,TGID,<i>,` or `HLD,CFREQ,<i>,`.
    public var command: ScannerCommand {
        get throws {
            switch self {
            case .system(let index): try ScannerCommand("HLD", "SYS", String(index), "")
            case .department(let index, let system): try ScannerCommand("HLD", "DEPT", String(index), String(system))
            case .trunkChannel(let index): try ScannerCommand("HLD", "TGID", String(index), "")
            case .conventionalChannel(let index): try ScannerCommand("HLD", "CFREQ", String(index), "")
            }
        }
    }
}
