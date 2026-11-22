// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
@testable import NoctuleAppCore

@Suite(.timeLimit(.minutes(1))) struct AppVersionTests {
    @Test(arguments: [
        ("1.2.3", "1.2.3"), ("v1.2.3", "1.2.3"), ("1.2.3-beta.4", "1.2.3-beta.4"),
        ("v0.1.1-beta.4", "0.1.1-beta.4"), ("10.20.30", "10.20.30"),
    ])
    func parses(text: String, description: String) throws {
        let version = try #require(AppVersion(text))
        #expect(version.description == description)
    }

    @Test func partsAndFlags() throws {
        let beta = try #require(AppVersion("v0.1.1-beta.4"))
        #expect((beta.major, beta.minor, beta.patch) == (0, 1, 1))
        #expect(beta.prerelease == ["beta", "4"])
        #expect(!beta.isFinal)
        #expect(try #require(AppVersion("1.0.0")).isFinal)
    }

    @Test(arguments: ["", "1.2", "1.2.3.4", "01.2.3", "1.2.3-", "1.2.3+meta", "1.2.3-beta..1", "v", " 1.2.3", "latest", "1.0.0-01", "99999999999999999999.0.0"])
    func refuses(text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func orders() throws {
        let ascending = ["1.0.0-alpha", "1.0.0-beta", "1.0.0-beta.3", "1.0.0-beta.10", "1.0.0",
                         "1.0.1-beta.1", "1.0.1", "1.1.0", "2.0.0"]
        let versions = try ascending.map { try #require(AppVersion($0)) }
        for i in versions.indices {
            for j in versions.indices {
                #expect((versions[i] < versions[j]) == (i < j), "\(ascending[i]) vs \(ascending[j])")
            }
        }
        #expect(try #require(AppVersion("1.0.0-1")) < #require(AppVersion("1.0.0-a")))
        #expect(try #require(AppVersion("1.0.0-99999999999999999999")) < #require(AppVersion("1.0.0-100000000000000000000")))
        #expect(AppVersion("v1.0.0") == AppVersion("1.0.0"))
    }

    @Test func development() throws {
        #expect(try #require(AppVersion("0.0.0")).isDevelopment)
        #expect(!(try #require(AppVersion("0.0.0-beta.1"))).isDevelopment)
        #expect(!(try #require(AppVersion("0.0.1"))).isDevelopment)
    }
}
