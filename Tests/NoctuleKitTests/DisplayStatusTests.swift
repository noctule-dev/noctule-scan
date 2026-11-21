// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKitTestSupport
@testable import NoctuleKit

@Suite struct DisplayStatusTests {
    @Test func parsesRealCapture() throws {
        var a = UDPDatagramAssembler()
        guard case .fields("STS", let f) = a.feed(fixture("sts-trunk-sds200-1.24.00.txt")).first else { Issue.record(); return }
        let s = try DisplayStatus(fields: f)
        try #require(s.lines.count == 17)
        #expect(s.lines[4].text.hasPrefix("Lakeview Water & Power Co. P25"))
        #expect(s.lines[1].text.contains("\u{1A}\u{1B}"))
        #expect(s.lines[16].highlightMask == "********* ********** *********")
        #expect(s.softKeyLabels == ["SYSTEM", "DEPT", "CHANNEL"])
        #expect(s.trailing == ["1", "1", "0", "0", "", "", "1", "OFF", "3"])
        #expect(s.lines.map(\.sizeFlag) == Array("00001010100000000"))
    }

    @Test func rejectsTruncated() {
        #expect(throws: DisplayStatusError.tooFewFields(expected: 7, got: 3)) { try DisplayStatus(fields: ["000", "a", "b"]) }
    }
}
