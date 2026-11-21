// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
@testable import NoctuleStore

@Suite struct LineInSettingsTests {
    private let killSwitch = "NOCTULE_NO_USB_DETECTION"
    private let testKey = "NOCTULE_TEST_LINE_IN"

    @Test func deviceSettingsRoundTripLineIn() throws {
        var dev = StationDeviceSettings(stationID: UUID())
        dev.audioInputDevice = "UID-1"
        dev.audioInputName = "Fictional Interface"
        dev.audioInputChannel = .left
        let back = try JSONDecoder().decode(StationDeviceSettings.self, from: JSONEncoder().encode(dev))
        #expect(back == dev)
        #expect(back.audioInputDevice == "UID-1" && back.audioInputName == "Fictional Interface" && back.audioInputChannel == .left)
        #expect(back.lineIn == LineInConfig(deviceUID: "UID-1", deviceName: "Fictional Interface", channel: .left))
    }

    /// The key names and channel words are `device.json`'s format, which AGENTS.md has agents write
    /// by hand: a rename in `CodingKeys` or in `LineInChannel` would silently drop a saved input, so
    /// they are pinned here as literal text, not through a round trip.
    @Test func deviceJSONKeysAndChannelWordsArePinned() throws {
        let id = UUID()
        for (word, channel) in [("left", LineInChannel.left), ("right", .right), ("both", .both)] {
            let json = #"{"stationID":"\#(id.uuidString)","usbPort":"/dev/example","audioInputDevice":"UID-1","#
                + #""audioInputName":"Fictional Interface","audioInputChannel":"\#(word)"}"#
            let dev = try JSONDecoder().decode(StationDeviceSettings.self, from: Data(json.utf8))
            #expect(dev.lineIn == LineInConfig(deviceUID: "UID-1", deviceName: "Fictional Interface", channel: channel))

            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dev)) as? [String: Any]
            #expect(encoded?["audioInputDevice"] as? String == "UID-1")
            #expect(encoded?["audioInputName"] as? String == "Fictional Interface")
            #expect(encoded?["audioInputChannel"] as? String == word)
            #expect(Set(encoded?.keys.filter { $0.hasPrefix("audioInput") } ?? [])
                    == ["audioInputDevice", "audioInputName", "audioInputChannel"])
        }
        #expect(LineInChannel.allCases.map(\.rawValue) == ["left", "right", "both"])
    }

    /// A channel word this build doesn't know (a hand edit, or a later build's) reads as absent, so
    /// `.both`, rather than failing the whole file.
    @Test func unknownChannelWordReadsAsBoth() throws {
        let id = UUID()
        let json = #"{"stationID":"\#(id.uuidString)","usbPort":"/dev/example","audioInputDevice":"UID-1","#
            + #""audioInputChannel":"middle"}"#
        let dev = try JSONDecoder().decode(StationDeviceSettings.self, from: Data(json.utf8))
        #expect(dev.usbPort == "/dev/example")
        #expect(dev.audioInputChannel == nil)
        #expect(dev.lineIn?.channel == .both)
    }

    /// The same through the store: the file isn't moved aside, so every station keeps its port.
    @Test func unknownChannelWordDoesNotQuarantineDeviceSettings() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-line-in-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = UUID(), b = UUID()
        let json = """
            {"version":1,"devices":[
              {"stationID":"\(a.uuidString)","usbPort":"/dev/example-a","audioInputDevice":"UID-1","audioInputChannel":"middle"},
              {"stationID":"\(b.uuidString)","usbPort":"/dev/example-b"}
            ]}
            """
        try Data(json.utf8).write(to: dir.appendingPathComponent("device.json"))
        let store = LocalSettingsStore(directory: dir)
        #expect(try await store.deviceSettings(for: a).usbPort == "/dev/example-a")
        #expect(try await store.deviceSettings(for: a).lineIn?.channel == .both)
        #expect(try await store.deviceSettings(for: b).usbPort == "/dev/example-b")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.hasPrefix("device.json.corrupt-") })
    }

    @Test func oldDeviceJSONHasNoLineIn() throws {
        let id = UUID()
        let json = #"{"stationID":"\#(id.uuidString)","usbPort":"/dev/example","audioOutputDevice":"Speakers"}"#
        let dev = try JSONDecoder().decode(StationDeviceSettings.self, from: Data(json.utf8))
        #expect(dev.lineIn == nil)
        #expect(dev.audioInputDevice == nil && dev.audioInputName == nil && dev.audioInputChannel == nil)
        #expect(dev.usbPort == "/dev/example")
    }

    @Test func channelDefaultsToBoth() {
        var dev = StationDeviceSettings(stationID: UUID())
        dev.audioInputDevice = "UID-2"
        #expect(dev.lineIn == LineInConfig(deviceUID: "UID-2", deviceName: "UID-2", channel: .both))
        dev.audioInputName = "Named"
        #expect(dev.lineIn?.deviceName == "Named")
    }

    @Test func killSwitchDisablesLineIn() {
        let reason = "audio input disabled by NOCTULE_NO_USB_DETECTION"
        for app in [false, true] {
            for privateSettings in [false, true] {
                #expect(LineInDetection.selection(environment: [killSwitch: "1"], privateSettings: privateSettings, app: app)
                        == .disabled(reason: reason))
            }
        }
    }

    @Test func testStreamNeedsKillSwitch() {
        let env = [killSwitch: "1", testKey: "/tmp/line-out"]
        // CLI: the kill-switch is all it needs.
        #expect(LineInDetection.selection(environment: env, privateSettings: false, app: false) == .testStream(path: "/tmp/line-out"))
        // App: also a private settings directory.
        #expect(LineInDetection.selection(environment: env, privateSettings: true, app: true) == .testStream(path: "/tmp/line-out"))
        #expect(LineInDetection.selection(environment: env, privateSettings: false, app: true)
                == .disabled(reason: "audio input disabled by NOCTULE_NO_USB_DETECTION"))
        // Without the kill-switch the variable is ignored.
        #expect(LineInDetection.selection(environment: [testKey: "/tmp/line-out"], privateSettings: true, app: true) == .system)
        #expect(LineInDetection.selection(environment: [testKey: "/tmp/line-out"], privateSettings: false, app: false) == .system)
        // An empty value is no value.
        #expect(LineInDetection.selection(environment: [killSwitch: "1", testKey: ""], privateSettings: false, app: false)
                == .disabled(reason: "audio input disabled by NOCTULE_NO_USB_DETECTION"))
        // An empty kill-switch is off.
        #expect(LineInDetection.selection(environment: [killSwitch: "", testKey: "/tmp/x"], privateSettings: true, app: true) == .system)
    }

    @Test func noVariablesIsSystem() {
        #expect(LineInDetection.selection(environment: [:], privateSettings: false, app: false) == .system)
        #expect(LineInDetection.selection(environment: [:], privateSettings: true, app: true) == .system)
    }

    @Test func overrideNotesNameTheTestStream() {
        #expect(LineInDetection.overrideNotes([killSwitch: "1", testKey: "/tmp/line-out"], privateSettings: false, app: false)
                == ["NOCTULE_TEST_LINE_IN=/tmp/line-out (in place of the line-in device)"])
        #expect(LineInDetection.overrideNotes([testKey: "/tmp/line-out"], privateSettings: true, app: true).isEmpty)
        #expect(LineInDetection.overrideNotes([killSwitch: "1", testKey: "/tmp/line-out"], privateSettings: false, app: true).isEmpty)
        #expect(LineInDetection.overrideNotes([:], privateSettings: false, app: false).isEmpty)
    }
}
