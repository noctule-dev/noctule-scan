// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum ScannerCommandError: Error, Equatable {
    case invalidArgument(String)
}

public struct ScannerCommand: Sendable, Equatable {
    public let name: String
    public let arguments: [String]

    /// Throws `invalidArgument` for an argument holding a comma (the field separator), CR (which
    /// ends a command) or LF. Checked by Unicode scalar: "\r\n" is one `Character`, equal to
    /// neither "\r" nor "\n", so `contains("\r")` misses it (LESSONS 2026-11-10).
    public init(_ name: String, _ arguments: String...) throws {
        try self.init(name, arguments: arguments)
    }

    /// The same as the variadic initializer, for a command whose argument count is only known
    /// at run time (the quick-key sets send 100 values).
    public init(_ name: String, arguments: [String]) throws {
        for argument in arguments where argument.unicodeScalars.contains(where: { $0 == "," || $0 == "\r" || $0 == "\n" }) {
            throw ScannerCommandError.invalidArgument(argument)
        }
        self.name = name.uppercased()
        self.arguments = arguments
    }

    public var wireBytes: Data {
        Data(([name] + arguments).joined(separator: ",").appending("\r").utf8)
    }
}
