// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

@Test func encodesBareCommand() throws {
    #expect(try ScannerCommand("MDL").wireBytes == Data("MDL\r".utf8))
}

@Test func encodesArguments() throws {
    #expect(try ScannerCommand("KEY", "L", "P").wireBytes == Data("KEY,L,P\r".utf8))
}

@Test func rejectsDelimitersInArguments() {
    #expect(throws: ScannerCommandError.invalidArgument("a,b")) { try ScannerCommand("HLD", "a,b") }
    #expect(throws: ScannerCommandError.invalidArgument("x\r")) { try ScannerCommand("HLD", "x\r") }
}

/// Final review I3: "\r\n" is one `Character`, equal to neither "\r" nor "\n", so a check by
/// Character let it through (`MSV,,a\r\nb\r` on the wire). Checked by Unicode scalar.
@Test func rejectsLineBreaksByScalar() {
    for argument in ["a\r\nb", "\r\n", "a\nb", "\n", "a\rb", "\r", "x\u{0D}\u{0A}"] {
        #expect(throws: ScannerCommandError.invalidArgument(argument), "\(argument.debugDescription)") {
            try ScannerCommand("MSV", "", argument)
        }
    }
    #expect(throws: ScannerCommandError.invalidArgument("a,\r\n")) { try ScannerCommand("MSV", "", "a,\r\n") }
    #expect(throws: Never.self) { try ScannerCommand("MSV", "", "Night Ops") }
}
