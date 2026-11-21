// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
@testable import NoctuleKit

@Test func parsesFieldLines() {
    #expect(ResponseLineParser.parse("MDL,SDS200") == .fields(command: "MDL", fields: ["SDS200"]))
    #expect(ResponseLineParser.parse("VER,Version 1.24.00") == .fields(command: "VER", fields: ["Version 1.24.00"]))
    #expect(ResponseLineParser.parse("vol,2\r") == .fields(command: "VOL", fields: ["2"]))
    #expect(ResponseLineParser.parse("") == nil)
}

@Test func reportsStatus() {
    #expect(ResponseLineParser.parse("VOL,OK")?.status == .ok)
    #expect(ResponseLineParser.parse("KEY,NG")?.status == .rejected("KEY,NG"))
    #expect(ResponseLineParser.parse("VOL,2")?.status == nil)
}
