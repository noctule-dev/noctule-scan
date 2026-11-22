// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
@testable import NoctuleAppCore

private func info(_ attrs: String = "", inner: String = "") throws -> ScannerInfo {
    try ScannerInfo(xml: XMLNode.parse(Data("<ScannerInfo \(attrs)>\(inner)</ScannerInfo>".utf8)))
}

@Suite(.timeLimit(.minutes(3))) struct DisplayRefreshPolicyTests {
    let policy = DisplayRefreshPolicy()
    let t0 = ContinuousClock.now

    @Test func noPreviousFetchMeansNow() {
        #expect(policy.nextFetch(lastFetch: nil, lastKeyReply: nil, changed: false, now: t0) == t0)
    }

    @Test func policyRespectsMinInterval() {
        let next = policy.nextFetch(lastFetch: t0, lastKeyReply: nil, changed: true, now: t0 + .milliseconds(100))
        #expect(next == t0 + .seconds(1))
    }

    /// A model's policy takes its `ModelProfile.displayRefreshInterval` as `minInterval`; the rest
    /// stays the default.
    @Test func modelsPolicy() {
        let sds150 = DisplayRefreshPolicy(model: .sds150)
        #expect(sds150.minInterval == .milliseconds(100))
        #expect(sds150.nextFetch(lastFetch: t0, lastKeyReply: nil, changed: true, now: t0 + .milliseconds(50))
                == t0 + .milliseconds(100))
        #expect(sds150.nextFetch(lastFetch: t0, lastKeyReply: nil, changed: false, now: t0 + .milliseconds(50))
                == t0 + .seconds(5))
        #expect(sds150.maxInterval == policy.maxInterval && sds150.afterKey == policy.afterKey)
        #expect(sds150.menuMinInterval == policy.menuMinInterval && sds150.menuIdleInterval == policy.menuIdleInterval)
        let sds200 = DisplayRefreshPolicy(model: .sds200)
        #expect(sds200.minInterval == .milliseconds(100))
        #expect(sds200.nextFetch(lastFetch: t0, lastKeyReply: nil, changed: false, now: t0 + .milliseconds(50))
                == t0 + .seconds(5))
        #expect(sds200.maxInterval == policy.maxInterval && sds200.afterKey == policy.afterKey)
        #expect(sds200.menuMinInterval == policy.menuMinInterval && sds200.menuIdleInterval == policy.menuIdleInterval
                && sds200.menuMaxKeyDeferral == policy.menuMaxKeyDeferral)
        #expect(DisplayRefreshPolicy(model: .sds100).minInterval == .milliseconds(100))
        #expect(DisplayRefreshPolicy(model: .bcd436hp).minInterval == .seconds(1))
    }

    @Test func policyForcesMaxInterval() {
        let next = policy.nextFetch(lastFetch: t0, lastKeyReply: nil, changed: false, now: t0 + .seconds(2))
        #expect(next == t0 + .seconds(5))
    }

    @Test func policyAfterKeyReply() {
        let now = t0 + .milliseconds(650)
        let reply = now - .milliseconds(150)  // lastFetch only 0.5 s ago
        let lastFetch = now - .milliseconds(500)
        #expect(policy.nextFetch(lastFetch: lastFetch, lastKeyReply: reply, changed: false, now: now)
                == lastFetch + .seconds(1))
        // Long since the last fetch: wait afterKey after the reply.
        let later = t0 + .seconds(3)
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: later, changed: false, now: later)
                == later + .milliseconds(150))
        // A key reply before the last fetch doesn't count.
        #expect(policy.nextFetch(lastFetch: later, lastKeyReply: t0, changed: false, now: later)
                == later + .seconds(5))
    }

    @Test func policyNeverExceedsMaxInterval() {
        let reply = t0 + .milliseconds(4900)
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: reply, changed: false, now: reply) == t0 + .seconds(5))
    }

    @Test func changedWithNewerKeyReplyUsesMinInterval() {
        let reply = t0 + .milliseconds(300)
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: reply, changed: true, now: reply) == t0 + .seconds(1))
    }

    // MARK: In a menu

    @Test func menuKeyReplyFetchesWithoutTheOneSecondFloor() {
        // 200 ms, not 300: from 250 ms on the 400 ms cap (menuHeldKeyCannotDeferPastTheCap) decides.
        let reply = t0 + .milliseconds(200)
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: reply, changed: false, now: reply, inMenu: true)
                == t0 + .milliseconds(350))
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: reply, changed: false, now: reply, inMenu: false)
                == t0 + .seconds(1))
    }

    @Test func menuNeverFasterThanMenuMinInterval() {
        let reply = t0 + .milliseconds(10)
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: reply, changed: false, now: reply, inMenu: true)
                == t0 + .milliseconds(200))
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: nil, changed: true, now: reply, inMenu: true)
                == t0 + .milliseconds(200))
    }

    /// Final review I2: key replies every 80 ms (a held scroll key) would push "reply + afterKey"
    /// forever; in a menu the deferral is capped at `menuMaxKeyDeferral` after the last fetch.
    @Test func menuHeldKeyCannotDeferPastTheCap() {
        #expect(policy.menuMaxKeyDeferral == .milliseconds(400))
        let reply = t0 + .milliseconds(380)
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: reply, changed: false, now: reply, inMenu: true)
                == t0 + .milliseconds(400))
        // Simulated: replies every 80 ms for 3.2 s, the clock stepping 10 ms; fetch when due.
        var lastFetch = t0
        var lastReply: ContinuousClock.Instant?
        var fetches: [ContinuousClock.Instant] = []
        for step in 1...320 {
            let now = t0 + .milliseconds(10 * step)
            if step.isMultiple(of: 8) { lastReply = now }
            if policy.nextFetch(lastFetch: lastFetch, lastKeyReply: lastReply, changed: false, now: now, inMenu: true) <= now {
                fetches.append(now)
                lastFetch = now
            }
        }
        #expect(fetches.count >= 7, "fetches: \(fetches.count)")
        var previous = t0
        for fetch in fetches {
            #expect(previous.duration(to: fetch) <= .milliseconds(400))
            #expect(previous.duration(to: fetch) >= .milliseconds(200))
            previous = fetch
        }
        // A single reply still waits afterKey, and never comes before menuMinInterval.
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: t0 + .milliseconds(100), changed: false,
                                 now: t0 + .milliseconds(100), inMenu: true) == t0 + .milliseconds(250))
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: t0 + .milliseconds(10), changed: false,
                                 now: t0 + .milliseconds(10), inMenu: true) == t0 + .milliseconds(200))
        // Outside a menu nothing changes: a late reply still waits up to maxInterval.
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: t0 + .milliseconds(4900), changed: false,
                                 now: t0 + .milliseconds(4900)) == t0 + .seconds(5))
    }

    @Test func menuIdleRefreshesEveryTwoSeconds() {
        #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: nil, changed: false, now: t0 + .seconds(1), inMenu: true)
                == t0 + .seconds(2))
        // A key reply from before the last fetch doesn't count.
        let later = t0 + .seconds(3)
        #expect(policy.nextFetch(lastFetch: later, lastKeyReply: t0, changed: false, now: later, inMenu: true)
                == later + .seconds(2))
        #expect(policy.nextFetch(lastFetch: nil, lastKeyReply: nil, changed: false, now: t0, inMenu: true) == t0)
    }

    @Test func menuTitleChangeIsSignificant() throws {
        let a = try info("Mode=\"Menu tree\" V_Screen=\"menu_selection\"")
        var b = a; b.menuTitle = "Set Scan Selection"
        #expect(DisplayRefreshPolicy.significantChange(a, b))
        var c = b; c.menuIndex = "4293063672"
        #expect(DisplayRefreshPolicy.significantChange(b, c))
        var d = c; d.menuScreenKind = .input
        #expect(DisplayRefreshPolicy.significantChange(c, d))
        #expect(!DisplayRefreshPolicy.significantChange(d, d))
    }

    @Test func fourArgumentOverloadMatchesNotInMenu() {
        let reply = t0 + .milliseconds(300)
        for changed in [false, true] {
            for key in [nil, reply] {
                #expect(policy.nextFetch(lastFetch: t0, lastKeyReply: key, changed: changed, now: reply)
                        == policy.nextFetch(lastFetch: t0, lastKeyReply: key, changed: changed, now: reply, inMenu: false))
            }
        }
    }

    @Test func significantChangeDepartmentAndFlags() throws {
        var a = try info()
        a.system = NamedItem(name: "S"); a.department = NamedItem(name: "D")
        var b = a; b.department?.name = "D2"
        #expect(DisplayRefreshPolicy.significantChange(a, b))
        for (path, name) in [(\ScannerInfo.system, "system"), (\ScannerInfo.department, "department")] {
            var h = a; h[keyPath: path]?.hold = true
            #expect(DisplayRefreshPolicy.significantChange(a, h), "\(name) hold")
            var v = a; v[keyPath: path]?.avoid = true
            #expect(DisplayRefreshPolicy.significantChange(a, v), "\(name) avoid")
        }
    }

    @Test func significantChangeIgnoresRSSI() throws {
        let a = try info("Mode=\"Trunk\" V_Screen=\"scan\" TGID=\"1\"", inner: "<System Name=\"S\"/>")
        var b = try info("Mode=\"Trunk\" V_Screen=\"scan\" TGID=\"1\"", inner: "<System Name=\"S\"/>")
        b.rssi = 99; b.signalBars = 3
        #expect(!DisplayRefreshPolicy.significantChange(a, b))
        #expect(DisplayRefreshPolicy.significantChange(nil, b))
        var c = a; c.mode = "Conventional"
        #expect(DisplayRefreshPolicy.significantChange(a, c))
        var d = a; d.screen = "menu"
        #expect(DisplayRefreshPolicy.significantChange(a, d))
        var e = a; e.talkgroupID = "2"
        #expect(DisplayRefreshPolicy.significantChange(a, e))
        var f = a; f.channel = NamedItem(name: "Ch")
        #expect(DisplayRefreshPolicy.significantChange(a, f))
        var g = f; g.channel?.hold = true
        #expect(DisplayRefreshPolicy.significantChange(f, g))
        var h = f; h.channel?.avoid = true
        #expect(DisplayRefreshPolicy.significantChange(f, h))
        var i = a; i.system = NamedItem(name: "Other")
        #expect(DisplayRefreshPolicy.significantChange(a, i))
    }
}
