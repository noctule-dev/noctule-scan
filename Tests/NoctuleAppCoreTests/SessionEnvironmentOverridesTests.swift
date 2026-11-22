// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleKitTestSupport
import NoctuleStore
import Synchronization
import Testing
@testable import NoctuleAppCore

/// The app's test-only environment overrides (`NOCTULE_SETTINGS_DIR` and friends).
@Suite(.timeLimit(.minutes(3))) struct SessionEnvironmentOverridesTests {
    private let base = SessionEnvironment(
        settings: LocalSettingsStore(directory: URL(fileURLWithPath: "/base/settings")),
        settingsDirectory: URL(fileURLWithPath: "/base/settings"),
        recordingsRoot: URL(fileURLWithPath: "/base/recordings"),
        cooldownStore: InMemoryRTSPCooldownStore())

    @Test func noVariablesChangeNothing() {
        let (env, notes) = base.applyingOverrides(["HOME": "/Users/x", "NOCTULE_SETTINGS_DIR": ""])
        #expect(notes.isEmpty)
        #expect(env.settingsDirectory.path == "/base/settings")
        #expect(env.recordingsRoot.path == "/base/recordings")
        #expect(env.cooldownStore is InMemoryRTSPCooldownStore)
        #expect(env.cooldown == .seconds(120))
    }

    @Test func everyOverrideApplies() async throws {
        let (env, notes) = apply([
            "NOCTULE_SETTINGS_DIR": "/tmp/s",
            "NOCTULE_RECORDINGS_DIR": "/tmp/r",
            "NOCTULE_COOLDOWN_STORE": "/tmp/c.json",
            "NOCTULE_COOLDOWN_SECONDS": "1.5",
        ])
        #expect(notes.count == 5, "\(notes)")
        #expect(notes.contains("no USB detection with a private NOCTULE_SETTINGS_DIR"), "\(notes)")
        #expect(env.settingsDirectory.path == "/tmp/s")
        let settings = try #require(env.settings as? LocalSettingsStore)
        #expect(await settings.directory.path == "/tmp/s")
        #expect(env.recordingsRoot.path == "/tmp/r")
        let store = try #require(env.cooldownStore as? FileRTSPCooldownStore)
        #expect(await store.url.path == "/tmp/c.json")
        #expect(env.cooldown == .milliseconds(1500))
    }

    private let testDefault = URL(fileURLWithPath: "/shared/Caches/NoctuleScan/rtsp-cooldown.json")
    private let settings = ["NOCTULE_SETTINGS_DIR": "/tmp/s"]

    private func apply(_ variables: [String: String]) -> (environment: SessionEnvironment, notes: [String]) {
        base.applyingOverrides(variables, defaultCooldownStore: testDefault)
    }

    /// A shortened cooldown must never reach the shared store the real scanner's clients use.
    @Test func cooldownSecondsNeedsAPrivateStore() {
        let (env, notes) = apply(settings.merging(["NOCTULE_COOLDOWN_SECONDS": "1"]) { $1 })
        #expect(env.cooldown == .seconds(120))
        #expect(notes.last == "ignoring NOCTULE_COOLDOWN_SECONDS: it needs a private NOCTULE_COOLDOWN_STORE, not the shared one")
    }

    @Test func testSheetNeedsASettingsDirectory() {
        let (plain, none) = apply([:])
        #expect(!plain.presentsTestSheet && none.isEmpty)
        let (ignored, notes) = apply(["NOCTULE_TEST_PRESENT_SHEET": "1"])
        #expect(!ignored.presentsTestSheet)
        #expect(notes == ["ignoring NOCTULE_TEST_PRESENT_SHEET: it needs NOCTULE_SETTINGS_DIR too"])
        let (env, applied) = apply(settings.merging(["NOCTULE_TEST_PRESENT_SHEET": "1"]) { $1 })
        #expect(env.presentsTestSheet)
        #expect(applied.last == "NOCTULE_TEST_PRESENT_SHEET")
    }

    /// The store and the cooldown need a private settings directory too, so they can't be paired
    /// with the owner's real stations.
    @Test func storeAndCooldownNeedASettingsDirectory() {
        let (env, notes) = apply(["NOCTULE_COOLDOWN_STORE": "/tmp/c.json", "NOCTULE_COOLDOWN_SECONDS": "1"])
        #expect(env.cooldown == .seconds(120))
        #expect(env.cooldownStore is InMemoryRTSPCooldownStore)
        #expect(env.settingsDirectory.path == "/base/settings")
        #expect(notes == ["ignoring NOCTULE_COOLDOWN_STORE: it needs NOCTULE_SETTINGS_DIR too",
                          "ignoring NOCTULE_COOLDOWN_SECONDS: it needs NOCTULE_SETTINGS_DIR too"])
    }

    /// Naming the shared record as the "private" store doesn't shorten its cooldown, however the
    /// path is spelled.
    @Test(arguments: ["/shared/Caches/NoctuleScan/rtsp-cooldown.json",
                      "/shared/Caches/./NoctuleScan/../NoctuleScan/rtsp-cooldown.json",
                      "/SHARED/caches/NoctuleScan/RTSP-cooldown.json"])
    func sharedStoreKeepsTheFullCooldown(_ path: String) {
        let (env, notes) = apply(settings.merging(["NOCTULE_COOLDOWN_STORE": path, "NOCTULE_COOLDOWN_SECONDS": "1"]) { $1 })
        #expect(env.cooldown == .seconds(120), "\(notes)")
        #expect(notes.last?.hasPrefix("ignoring NOCTULE_COOLDOWN_SECONDS") == true, "\(notes)")
    }

    /// A symlinked folder, or a symlink to the shared file, still counts as the shared store.
    @Test func sharedStoreThroughSymlinksKeepsTheFullCooldown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overrides-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let shared = real.appendingPathComponent("rtsp-cooldown.json")
        let linkedFolder = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: real)
        let viaFolder = linkedFolder.appendingPathComponent("rtsp-cooldown.json").path

        // The shared file doesn't exist yet: matched through the folder.
        var result = base.applyingOverrides(settings.merging(["NOCTULE_COOLDOWN_STORE": viaFolder,
                                                              "NOCTULE_COOLDOWN_SECONDS": "1"]) { $1 },
                                            defaultCooldownStore: shared)
        #expect(result.environment.cooldown == .seconds(120), "\(result.notes)")

        // It exists, and the override is a symlink to it.
        try Data("{}".utf8).write(to: shared)
        let linkedFile = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: shared)
        result = base.applyingOverrides(settings.merging(["NOCTULE_COOLDOWN_STORE": linkedFile.path,
                                                          "NOCTULE_COOLDOWN_SECONDS": "1"]) { $1 },
                                        defaultCooldownStore: shared)
        #expect(result.environment.cooldown == .seconds(120), "\(result.notes)")

        // A different file in the same folder is private.
        result = base.applyingOverrides(settings.merging(["NOCTULE_COOLDOWN_STORE": real.appendingPathComponent("mine.json").path,
                                                          "NOCTULE_COOLDOWN_SECONDS": "1"]) { $1 },
                                        defaultCooldownStore: shared)
        #expect(result.environment.cooldown == .seconds(1), "\(result.notes)")
    }

    /// `NOCTULE_SETTINGS_DIR` naming the standard settings directory (the owner's real stations,
    /// which may name the real scanner) doesn't unlock a private store or a shorter cooldown,
    /// however the path is spelled (final review M1).
    @Test func standardSettingsDirectoryKeepsTheSharedStoreAndFullCooldown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overrides-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let standard = root.appendingPathComponent("Application Support/NoctuleScan", isDirectory: true)
        try FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: standard)
        for spelling in [standard.path, standard.path + "/", root.path + "/Application Support/./NoctuleScan",
                         standard.path.uppercased(), linked.path] {
            let (env, notes) = base.applyingOverrides(
                ["NOCTULE_SETTINGS_DIR": spelling, "NOCTULE_COOLDOWN_STORE": "/tmp/c.json", "NOCTULE_COOLDOWN_SECONDS": "1"],
                defaultCooldownStore: testDefault, standardSettingsDirectory: standard)
            #expect(env.cooldown == .seconds(120), "\(spelling): \(notes)")
            #expect(env.cooldownStore is InMemoryRTSPCooldownStore, "\(spelling): \(notes)")
            #expect(notes.contains("ignoring NOCTULE_COOLDOWN_STORE: it needs a private NOCTULE_SETTINGS_DIR, not the standard one"),
                    "\(spelling): \(notes)")
            #expect(notes.contains("ignoring NOCTULE_COOLDOWN_SECONDS: it needs a private NOCTULE_SETTINGS_DIR, not the standard one"),
                    "\(spelling): \(notes)")
        }
        // A different folder beside it is private.
        let (env, notes) = base.applyingOverrides(
            ["NOCTULE_SETTINGS_DIR": root.appendingPathComponent("Application Support/Other").path,
             "NOCTULE_COOLDOWN_STORE": "/tmp/c.json", "NOCTULE_COOLDOWN_SECONDS": "1"],
            defaultCooldownStore: testDefault, standardSettingsDirectory: standard)
        #expect(env.cooldown == .seconds(1), "\(notes)")
    }

    @Test(arguments: ["-1", "abc", "nan", "inf"])
    func invalidCooldownIsIgnored(_ text: String) {
        let (env, notes) = apply(settings.merging(["NOCTULE_COOLDOWN_STORE": "/tmp/c.json", "NOCTULE_COOLDOWN_SECONDS": text]) { $1 })
        #expect(env.cooldown == .seconds(120))
        #expect(notes.last?.hasPrefix("ignoring NOCTULE_COOLDOWN_SECONDS=\(text)") == true, "\(notes)")
    }

    @Test func hugeCooldownIsClampedToADay() {
        let (env, _) = apply(settings.merging(["NOCTULE_COOLDOWN_STORE": "/tmp/c.json", "NOCTULE_COOLDOWN_SECONDS": "1e12"]) { $1 })
        #expect(env.cooldown == .seconds(86_400))
    }

    // MARK: - The serial port listing (Plan 8 D2, D7)

    private let standard = URL(fileURLWithPath: "/std/Application Support/NoctuleScan", isDirectory: true)
    private let systemPort = SerialPortInfo(path: "/dev/cu.system", productName: "SDS150 Serial Port",
                                            vendorID: SerialPort.unidenVendorID, productID: 0x001A, serialNumber: nil)
    private static let noDetectionNote = "no USB detection with a private NOCTULE_SETTINGS_DIR"
    private static let needsPrivateNote = "ignoring NOCTULE_TEST_SERIAL_PORTS: it needs a private NOCTULE_SETTINGS_DIR"

    /// `base` with `system` as the listing it was given (the app passes IOKit's), overridden.
    private func applyPorts(_ variables: [String: String], system: RecordingListing)
        -> (environment: SessionEnvironment, notes: [String]) {
        var given = base
        given.serialPorts = system
        return given.applyingOverrides(variables, defaultCooldownStore: testDefault, standardSettingsDirectory: standard)
    }

    @Test func newPropertiesDefaults() {
        #expect(SessionEnvironment.OverrideKey.noUSBDetection == "NOCTULE_NO_USB_DETECTION")
        #expect(SessionEnvironment.OverrideKey.testSerialPorts == "NOCTULE_TEST_SERIAL_PORTS")
        #expect(SessionEnvironment.OverrideKey.testKeepAliveSeconds == "NOCTULE_TEST_KEEPALIVE_SECONDS")
        #expect(base.serialPorts.unidenPorts() == [])
        #expect(base.keepAliveInterval == nil)
        #expect(base.portPollInterval == .seconds(1))
        #expect(base.batteryPollInterval == .seconds(60))
    }

    /// Rule 1: the kill-switch lists nothing, whatever else is set, with no note, and the given
    /// listing is never asked.
    @Test func killSwitchListsNothing() {
        let variableSets: [[String: String]] = [
            [:],
            ["NOCTULE_SETTINGS_DIR": "/tmp/s"],
            ["NOCTULE_SETTINGS_DIR": "/tmp/s", "NOCTULE_TEST_SERIAL_PORTS": "/tmp/a"],
            ["NOCTULE_SETTINGS_DIR": standard.path],
            ["NOCTULE_TEST_SERIAL_PORTS": "/tmp/a"],
        ]
        for value in ["1", "0", " "] {
            for variables in variableSets {
                let system = RecordingListing([systemPort])
                let (env, notes) = applyPorts(variables.merging(["NOCTULE_NO_USB_DETECTION": value]) { $1 }, system: system)
                #expect(env.serialPorts.unidenPorts() == [], "\(variables)")
                #expect(!system.wasAsked, "\(variables)")
                #expect(!notes.contains { $0.contains("SERIAL_PORTS") || $0.contains("USB") }, "\(variables): \(notes)")
            }
        }
    }

    /// Rule 2a: a private settings directory with no decoy lists nothing, and says so.
    @Test func privateSettingsListNothing() {
        for extra in [[:], ["NOCTULE_TEST_SERIAL_PORTS": ""], ["NOCTULE_TEST_SERIAL_PORTS": ":"],
                      ["NOCTULE_NO_USB_DETECTION": ""]] {
            let system = RecordingListing([systemPort])
            let (env, notes) = applyPorts(settings.merging(extra) { $1 }, system: system)
            #expect(env.serialPorts.unidenPorts() == [], "\(extra)")
            #expect(!system.wasAsked, "\(extra)")
            #expect(notes == ["NOCTULE_SETTINGS_DIR=/tmp/s", Self.noDetectionNote], "\(extra)")
        }
    }

    /// Rule 2b: a private settings directory with `NOCTULE_TEST_SERIAL_PORTS` lists the decoy (as
    /// the CLI's `USBDetection.listing` does), never the given listing.
    @Test func privateSettingsListTheDecoy() {
        let system = RecordingListing([systemPort])
        let (env, notes) = applyPorts(settings.merging(["NOCTULE_TEST_SERIAL_PORTS": "/tmp/a:/tmp/b"]) { $1 }, system: system)
        let listed = env.serialPorts.unidenPorts()
        #expect(listed.map(\.path) == ["/tmp/a", "/tmp/b"])
        #expect(listed.allSatisfy { $0.knownModel == .sds150 && $0.productName == "SDS150 Serial Port" })
        #expect(!system.wasAsked)
        #expect(notes == ["NOCTULE_SETTINGS_DIR=/tmp/s",
                          "NOCTULE_TEST_SERIAL_PORTS=/tmp/a:/tmp/b (in place of the system's serial port listing)"])
    }

    /// Rule 3: the standard settings (no `NOCTULE_SETTINGS_DIR`, or one naming the standard
    /// directory however spelled) keep the listing they were given; a decoy there is ignored.
    @Test func standardSettingsKeepTheGivenListing() {
        for variables in [[:], ["NOCTULE_SETTINGS_DIR": standard.path], ["NOCTULE_SETTINGS_DIR": standard.path + "/"],
                          ["NOCTULE_SETTINGS_DIR": "/std/Application Support/./NoctuleScan"]] {
            let (env, notes) = applyPorts(variables, system: RecordingListing([systemPort]))
            #expect(env.serialPorts.unidenPorts() == [systemPort], "\(variables)")
            #expect(!notes.contains { $0.contains("SERIAL_PORTS") || $0.contains("USB") }, "\(variables): \(notes)")

            let decoy = variables.merging(["NOCTULE_TEST_SERIAL_PORTS": "/tmp/a"]) { $1 }
            let (ignored, ignoredNotes) = applyPorts(decoy, system: RecordingListing([systemPort]))
            #expect(ignored.serialPorts.unidenPorts() == [systemPort], "\(decoy)")
            #expect(ignoredNotes.contains(Self.needsPrivateNote), "\(decoy): \(ignoredNotes)")
        }
    }

    /// `NOCTULE_TEST_KEEPALIVE_SECONDS` only with a private settings directory and the kill-switch
    /// both set, and only inside `PushKeepAlive.overrideRange`; otherwise named and ignored.
    @Test func keepAliveNeedsPrivateSettingsAndTheKillSwitch() {
        let key = "NOCTULE_TEST_KEEPALIVE_SECONDS"
        let applied = "\(key)=0.5 (in place of the model's keep-alive interval; "
            + "a model without a keep-alive, or a network scanner, still gets none)"
        let unlocked = settings.merging(["NOCTULE_NO_USB_DETECTION": "1"]) { $1 }
        let (env, notes) = apply(unlocked.merging([key: "0.5"]) { $1 })
        #expect(env.keepAliveInterval == .milliseconds(500))
        #expect(notes.last == applied, "\(notes)")
        for (text, interval) in [("0.05", Duration.milliseconds(50)), ("60", .seconds(60)), ("1", .seconds(1))] {
            #expect(apply(unlocked.merging([key: text]) { $1 }).environment.keepAliveInterval == interval, "\(text)")
        }

        let needsBoth = "ignoring \(key): it needs a private NOCTULE_SETTINGS_DIR and NOCTULE_NO_USB_DETECTION"
        for variables in [[key: "0.5"], [key: "0.5", "NOCTULE_NO_USB_DETECTION": "1"],
                          [key: "0.5", "NOCTULE_SETTINGS_DIR": standard.path],
                          [key: "0.5", "NOCTULE_SETTINGS_DIR": standard.path, "NOCTULE_NO_USB_DETECTION": "1"]] {
            let (ignored, ignoredNotes) = applyPorts(variables, system: RecordingListing([]))
            #expect(ignored.keepAliveInterval == nil, "\(variables)")
            #expect(ignoredNotes.last == needsBoth, "\(variables): \(ignoredNotes)")
        }
        for text in ["0.01", "0", "-1", "61", "abc", "nan", "inf", "1e300"] {
            let (ignored, ignoredNotes) = apply(unlocked.merging([key: text]) { $1 })
            #expect(ignored.keepAliveInterval == nil, "\(text)")
            #expect(ignoredNotes.last == "ignoring \(key)=\(text): not a number of seconds from 0.05 to 60", "\(ignoredNotes)")
        }
        // Empty is unset: nothing applied, nothing said.
        let (unset, unsetNotes) = apply(unlocked.merging([key: ""]) { $1 })
        #expect(unset.keepAliveInterval == nil)
        #expect(!unsetNotes.contains { $0.contains(key) })
    }

    /// A private settings directory alone doesn't unlock the keep-alive override: such a directory
    /// can hold a copied station whose saved port is the real scanner, and a shortened `KAL` must
    /// never reach it. Only the kill-switch, which keeps the app from finding any port, does.
    @Test func keepAliveIsIgnoredWithoutTheKillSwitch() {
        let key = "NOCTULE_TEST_KEEPALIVE_SECONDS"
        for extra in [[:], ["NOCTULE_NO_USB_DETECTION": ""]] {
            let (env, notes) = apply(settings.merging([key: "0.5"]) { $1 }.merging(extra) { $1 })
            #expect(env.keepAliveInterval == nil, "\(extra)")
            #expect(notes.last == "ignoring \(key): it needs a private NOCTULE_SETTINGS_DIR and NOCTULE_NO_USB_DETECTION",
                    "\(extra): \(notes)")
        }
    }
    // MARK: - Audio inputs (line-in design §8)

    /// `base` with a given line-in factory and input listing (the app passes the system's), each
    /// recording whether it was used, overridden.
    private func applyLineIn(_ variables: [String: String])
        -> (environment: SessionEnvironment, notes: [String], factory: RecordingLineInFactory, inputs: RecordingInputs) {
        let factory = RecordingLineInFactory()
        let inputs = RecordingInputs()
        var given = base
        given.lineInSources = factory.factory
        given.audioInputs = inputs
        let (env, notes) = given.applyingOverrides(variables, defaultCooldownStore: testDefault,
                                                   standardSettingsDirectory: standard)
        return (env, notes, factory, inputs)
    }

    private let fictionalInput = LineInConfig(deviceUID: "fictional-uid", deviceName: "Fictional Interface", channel: .both)
    private static let testLineInNote = "NOCTULE_TEST_LINE_IN=/tmp/line (in place of the line-in device)"
    private static let testLineInIgnored =
        "ignoring NOCTULE_TEST_LINE_IN: it needs a private NOCTULE_SETTINGS_DIR and NOCTULE_NO_USB_DETECTION"

    @Test func lineInDefaults() {
        #expect(base.lineInSources == nil)
        #expect(base.audioInputs.inputs() == [])
        #expect(base.lineInTestStream == nil)
        let output = FakeOutput()
        let environment = SessionEnvironment(settings: base.settings, settingsDirectory: base.settingsDirectory,
                                             recordingsRoot: base.recordingsRoot, cooldownStore: base.cooldownStore,
                                             makeAudioOutput: { output })
        #expect(environment.makeLineInAudioOutput() === output, "the line-in output defaults to makeAudioOutput")
        let other = FakeOutput()
        let separate = SessionEnvironment(settings: base.settings, settingsDirectory: base.settingsDirectory,
                                          recordingsRoot: base.recordingsRoot, cooldownStore: base.cooldownStore,
                                          makeAudioOutput: { output }, makeLineInAudioOutput: { other })
        #expect(separate.makeLineInAudioOutput() === other)
        #expect(separate.makeAudioOutput() === output)
    }

    /// The kill-switch, whatever else is set: every source the factory makes is a
    /// `DisabledLineInSource` saying why, no input is listed, and neither the given factory nor the
    /// given listing is ever asked, with no note.
    @Test func killSwitchGivesTheDisabledFactory() async {
        let variableSets: [[String: String]] = [
            [:],
            ["NOCTULE_SETTINGS_DIR": "/tmp/s"],
            ["NOCTULE_SETTINGS_DIR": standard.path],
            ["NOCTULE_TEST_LINE_IN": "/tmp/line"],
            ["NOCTULE_SETTINGS_DIR": standard.path, "NOCTULE_TEST_LINE_IN": "/tmp/line"],
        ]
        for value in ["1", "0", " "] {
            for variables in variableSets {
                let (env, notes, factory, inputs) = applyLineIn(variables.merging(["NOCTULE_NO_USB_DETECTION": value]) { $1 })
                let make = env.lineInSources
                #expect(make != nil, "\(variables)")
                if let make {
                    let source = make(fictionalInput)
                    #expect(source is DisabledLineInSource, "\(variables)")
                    await source.start()
                    var states = source.states.makeAsyncIterator()
                    #expect(await states.next() == .failed("audio input disabled by NOCTULE_NO_USB_DETECTION"))
                    await source.stop()
                }
                #expect(env.audioInputs.inputs() == [], "\(variables)")
                #expect(env.lineInTestStream == nil, "\(variables)")
                #expect(factory.calls == 0 && !inputs.wasAsked, "\(variables)")
                #expect(!notes.contains { $0.contains("LINE_IN") && !$0.hasPrefix("ignoring") }, "\(variables): \(notes)")
            }
        }
    }

    /// `NOCTULE_TEST_LINE_IN` only with a private settings directory and the kill-switch: then the
    /// path is handed to the app shell (`lineInTestStream`), no input is listed, the given pieces are
    /// never asked, and the note says so. Otherwise it is named and ignored.
    @Test func testStreamNeedsPrivateSettings() async {
        let unlocked = settings.merging(["NOCTULE_NO_USB_DETECTION": "1", "NOCTULE_TEST_LINE_IN": "/tmp/line"]) { $1 }
        let (env, notes, factory, inputs) = applyLineIn(unlocked)
        #expect(env.lineInTestStream == "/tmp/line")
        #expect(notes.contains(Self.testLineInNote), "\(notes)")
        #expect(env.audioInputs.inputs() == [])
        // Until the shell builds the stream's factory, nothing it could reach opens a device.
        if let make = env.lineInSources { #expect(make(fictionalInput) is DisabledLineInSource) }
        #expect(factory.calls == 0 && !inputs.wasAsked)

        for variables in [["NOCTULE_TEST_LINE_IN": "/tmp/line"],
                          ["NOCTULE_TEST_LINE_IN": "/tmp/line", "NOCTULE_NO_USB_DETECTION": "1"],
                          ["NOCTULE_TEST_LINE_IN": "/tmp/line", "NOCTULE_SETTINGS_DIR": "/tmp/s"],
                          ["NOCTULE_TEST_LINE_IN": "/tmp/line", "NOCTULE_SETTINGS_DIR": standard.path,
                           "NOCTULE_NO_USB_DETECTION": "1"]] {
            let (ignored, ignoredNotes, _, _) = applyLineIn(variables)
            #expect(ignored.lineInTestStream == nil, "\(variables)")
            #expect(ignoredNotes.contains(Self.testLineInIgnored), "\(variables): \(ignoredNotes)")
            #expect(!ignoredNotes.contains(Self.testLineInNote), "\(variables)")
        }
        // Empty is unset: nothing applied, nothing said.
        let (unset, unsetNotes, _, _) = applyLineIn(unlocked.merging(["NOCTULE_TEST_LINE_IN": ""]) { $1 })
        #expect(unset.lineInTestStream == nil)
        #expect(!unsetNotes.contains { $0.contains("NOCTULE_TEST_LINE_IN") })
    }

    /// Without the kill-switch the given factory and listing stay (the system's, in the app).
    @Test func systemSelectionKeepsTheGivenPieces() {
        for variables in [[:], ["NOCTULE_SETTINGS_DIR": standard.path], ["NOCTULE_NO_USB_DETECTION": ""]] {
            let (env, notes, factory, inputs) = applyLineIn(variables)
            _ = env.lineInSources?(fictionalInput)
            #expect(factory.calls == 1, "\(variables)")
            #expect(env.audioInputs.inputs() == RecordingInputs.devices, "\(variables)")
            #expect(inputs.wasAsked)
            #expect(env.lineInTestStream == nil)
            #expect(!notes.contains { $0.contains("LINE_IN") }, "\(variables): \(notes)")
        }
    }
}

/// A line-in factory that counts the sources it makes (fakes; nothing is opened).
private final class RecordingLineInFactory: Sendable {
    private let made = Mutex(0)
    var calls: Int { made.withLock { $0 } }
    var factory: LineInSourceFactory {
        { [self] config in
            made.withLock { $0 += 1 }
            return FakeLineInSource(config: config)
        }
    }
}

/// An input listing that records whether it was asked (the app passes Core Audio's).
private final class RecordingInputs: AudioInputListing {
    static let devices = [AudioInputDevice(uid: "fictional-uid", name: "Fictional Interface", channelCount: 2)]
    private let asked = Mutex(false)
    var wasAsked: Bool { asked.withLock { $0 } }
    func inputs() -> [AudioInputDevice] {
        asked.withLock { $0 = true }
        return Self.devices
    }
}

/// A port listing that records whether it was asked (the app passes IOKit's).
private final class RecordingListing: SerialPortListing {
    private let ports: [SerialPortInfo]
    private let asked = Mutex(false)
    init(_ ports: [SerialPortInfo]) { self.ports = ports }
    var wasAsked: Bool { asked.withLock { $0 } }
    func unidenPorts() -> [SerialPortInfo] {
        asked.withLock { $0 = true }
        return ports
    }
}
