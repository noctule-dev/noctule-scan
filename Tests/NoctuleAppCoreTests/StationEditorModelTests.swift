// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

// StationEditorModel against LocalSettingsStore in a temporary directory, an in-process
// MockSDS200 on loopback, and a closed loopback port. All names are fictional.

@MainActor
private func withEditor(existing: [Station] = [], editing: Station? = nil,
                        _ body: (StationEditorModel) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LocalSettingsStore(directory: dir)
    for s in existing { try await store.save(s) }
    let model = StationEditorModel(station: editing, settings: store, commandTimeout: .milliseconds(400))
    await model.load()
    try await body(model)
}

@MainActor
private func withStore(existing: [Station], _ body: (LocalSettingsStore) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LocalSettingsStore(directory: dir)
    for s in existing { try await store.save(s) }
    try await body(store)
}

private func station(_ name: String, host: String? = "127.0.0.1") -> Station {
    var s = Station()
    s.name = name
    s.connection.host = host
    return s
}

@Suite struct StationEditorModelTests {
    /// R18: saving an existing station applies only the editor's fields, so a view choice,
    /// saved filter or counts reset made in another window meanwhile survives.
    @MainActor @Test func saveKeepsFieldsTheEditorDoesNotOwn() async throws {
        let original = station("Test Station")
        try await withStore(existing: [original]) { store in
            let model = StationEditorModel(station: original, settings: store)
            await model.load()
            var filter = HitFilter(); filter.name = "Elsewhere"
            let entry = filter
            let resetAt = Date(timeIntervalSince1970: 1_800_000_000)
            try await store.update(id: original.id) {
                $0.preferredView = .macStyle; $0.savedFilters = [entry]; $0.countsResetAt = resetAt
            }
            model.draft.name = "Renamed Station"
            model.draft.connection.udpPort = 50999
            let saved = try await model.save()
            let stored = try #require(try await store.stations().first)
            #expect(saved == stored)
            #expect(stored.name == "Renamed Station" && stored.connection.udpPort == 50999)
            #expect(stored.preferredView == .macStyle)
            #expect(stored.savedFilters == [entry])
            #expect(stored.countsResetAt == resetAt)
        }
    }

    /// The editor sheet edits name and connection while Settings › Stations edits the key map,
    /// color mode and recording rules of the same station: a save writes only what the draft
    /// changed, so it never puts back the values the sheet was opened with.
    @MainActor @Test func saveKeepsSettingsChangedWhileTheEditorWasOpen() async throws {
        let original = station("Test Station")
        try await withStore(existing: [original]) { store in
            let model = StationEditorModel(station: original, settings: store)
            await model.load()
            try await store.update(id: original.id) {
                $0.keyMap.overrides[FrontPanelKey.avoid.rawValue] = "⌘l"
                $0.appearance.colorMode = .blackOnWhite
                $0.recording.saveAudio = .onlyNew
            }
            model.draft.name = "Renamed Station"
            _ = try await model.save()
            let stored = try #require(try await store.stations().first)
            #expect(stored.name == "Renamed Station")
            #expect(stored.keyMap.overrides == [FrontPanelKey.avoid.rawValue: "⌘l"])
            #expect(stored.appearance.colorMode == .blackOnWhite)
            #expect(stored.recording.saveAudio == .onlyNew)

            // A field the draft did change is written.
            model.draft.recording.saveAudio = .never
            _ = try await model.save()
            #expect(try await store.stations().first?.recording.saveAudio == .never)
        }
    }

    @MainActor @Test func saveOfAStationDeletedMeanwhileThrowsAndDoesNotRecreate() async throws {
        let original = station("Test Station")
        let keep = station("Other Station")
        try await withStore(existing: [original, keep]) { store in
            let model = StationEditorModel(station: original, settings: store)
            await model.load()
            try await store.deleteStation(id: original.id)
            model.draft.name = "Renamed Station"
            await #expect(throws: StationNoLongerExists.self) { _ = try await model.save() }
            #expect(try await store.stations().map(\.id) == [keep.id])
        }
    }

    @MainActor @Test func addingANewStationSavesItWhole() async throws {
        try await withStore(existing: []) { store in
            let model = StationEditorModel(station: nil, settings: store)
            model.draft.name = "New One"
            model.draft.connection.host = "127.0.0.1"
            model.draft.preferredView = .macStyle
            let saved = try await model.save()
            #expect(try await store.stations() == [saved])
        }
    }

    @MainActor @Test func duplicateNameRejected() async throws {
        let other = station("Lakeview Fire")
        try await withEditor(existing: [other]) { model in
            model.draft = station("  lakeview FIRE ")
            #expect(model.issues == ["a station named \"Lakeview Fire\" already exists"])
            await #expect(throws: StationValidationError.self) { _ = try await model.save() }
            model.draft.name = "Lakeview Fire 2"
            #expect(model.issues.isEmpty)
        }
        // Editing the station itself is not a duplicate of itself.
        try await withEditor(existing: [other], editing: other) { model in
            #expect(model.issues.isEmpty)
            model.draft.name = "LAKEVIEW FIRE"
            #expect(model.issues.isEmpty)
        }
    }

    @MainActor @Test func issuesUseTheSharedWording() async throws {
        try await withEditor { model in
            model.draft.name = " "
            model.draft.connection.host = ""
            model.draft.recording.minimumDuration = 99
            #expect(model.issues == [StationIssue.emptyName.message, StationIssue.missingHost.message,
                                     StationIssue.invalidMinimumDuration.message])
        }
    }

    /// The reconnect wait is part of the connection: checked like the rest, and saved.
    @MainActor @Test func reconnectWaitIsValidatedAndSaved() async throws {
        let original = station("Test Station")
        try await withStore(existing: [original]) { store in
            let model = StationEditorModel(station: original, settings: store)
            await model.load()
            model.draft.connection.reconnectCooldownSeconds = 121
            #expect(model.issues == [StationIssue.invalidReconnectCooldown.message])
            model.draft.connection.reconnectCooldownSeconds = 0
            #expect(model.issues.isEmpty)
            _ = try await model.save()
            #expect(try await store.stations().first?.connection.reconnectCooldownSeconds == 0)
        }
    }

    @MainActor @Test func saveValidates() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        let model = StationEditorModel(station: nil, settings: store)
        await model.load()
        model.draft.connection.host = nil
        do { _ = try await model.save(); Issue.record("save should throw") }
        catch let e as StationValidationError { #expect(e.issues == model.issues && !e.issues.isEmpty) }
        #expect(try await store.stations().isEmpty)

        model.draft.name = "Hilltop Repeater"
        model.draft.connection.host = "192.0.2.10"
        let saved = try await model.save()
        #expect(saved == model.draft)
        #expect(try await store.stations() == [saved])
    }

    @MainActor @Test func testConnectionAgainstMock() async throws {
        let options = MockSDS200.Options(clock: .stepped(at: 1), reconnectCooldown: .milliseconds(300),
                                         rebootDuration: .milliseconds(300))
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        do {
            try await withEditor { model in
                model.draft = station("Mock")
                model.draft.connection.udpPort = ports.udpPort
                model.draft.connection.rtspPort = ports.rtspPort
                guard case .ok(let m, let fw) = await model.testConnection() else {
                    Issue.record("expected .ok"); return
                }
                #expect(m == "SDS200" && !fw.isEmpty)
                #expect(model.detectedModel == .sds200)
                #expect(model.draft.connection.modelOverride == nil)
            }
        } catch { await mock.stop(); throw error }
        let commands = await mock.control.receivedCommands
        let leaked = await mock.leakedSessions
        await mock.stop()
        #expect(commands == ["MDL", "VER"])
        #expect(leaked.isEmpty)
    }

    @MainActor @Test func testConnectionNoAnswer() async throws {
        let port = try closedUDPPort()
        try await withEditor { model in
            model.draft = station("Nowhere", host: "127.0.0.1")
            model.draft.connection.udpPort = port
            let result = await model.testConnection()
            #expect(result == .noAnswer(StationSession.noAnswerMessage(host: "127.0.0.1", port: port)))
            #expect(model.detectedModel == nil)
        }
    }

    @MainActor @Test func testConnectionWithoutHostSendsNothing() async throws {
        try await withEditor { model in
            model.draft = station("Blank", host: nil)
            #expect(await model.testConnection() == .failed("Blank has no address."))
        }
    }

    @MainActor @Test func keyConflictShown() async throws {
        try await withEditor { model in
            #expect(model.keyConflicts.isEmpty)
            model.draft.keyMap.overrides[FrontPanelKey.menu.rawValue] = "a"
            let chord = try #require(KeyChord("a"))
            #expect(model.keyConflicts[chord] == [FrontPanelKey.avoid, .menu])
        }
    }
}

/// Counts opens and closes; answers every command with an empty reply (`scripted`) or never answers.
private final class CountingTransport: ScannerTransport, @unchecked Sendable {
    let inner: (any ScannerTransport)?
    let counts = Mutex<(opens: Int, closes: Int)>((0, 0))
    let stream: AsyncStream<ScannerResponse>
    let continuation: AsyncStream<ScannerResponse>.Continuation
    init(wrapping inner: (any ScannerTransport)?) {
        self.inner = inner
        (stream, continuation) = AsyncStream.makeStream()
    }
    var opens: Int { counts.withLock { $0.opens } }
    var closes: Int { counts.withLock { $0.closes } }
    func open() async throws { counts.withLock { $0.opens += 1 }; try await inner?.open() }
    func send(_ command: ScannerCommand) async throws {
        if let inner { try await inner.send(command) }
        else { continuation.yield(.fields(command: command.name, fields: [])) }
    }
    var responses: AsyncStream<ScannerResponse> { inner?.responses ?? stream }
    func close() async {
        counts.withLock { $0.closes += 1 }
        await inner?.close()
        continuation.finish()
    }
}

extension StationEditorModelTests {
    @MainActor @Test func transportClosedOnEveryPath() async throws {
        let options = MockSDS200.Options(clock: .stepped(at: 1), reconnectCooldown: .milliseconds(300),
                                         rebootDuration: .milliseconds(300))
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        let closedPort = try closedUDPPort()
        var counters: [CountingTransport] = []
        var results: [ConnectionTest] = []
        // Nothing in here throws, so the mock is always stopped below.
        for (port, scripted) in [(ports.udpPort, false), (closedPort, false), (closedPort, true)] {
            let counter = CountingTransport(wrapping: scripted ? nil : UDPTransport(host: "127.0.0.1", port: port))
            counters.append(counter)
            let model = StationEditorModel(station: station("T"), settings: LocalSettingsStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("noctule-editor-\(UUID().uuidString)")),
                makeTransport: { _, _ in counter }, commandTimeout: .milliseconds(400))
            model.draft.connection.udpPort = port
            results.append(await model.testConnection())
        }
        await mock.stop()
        guard case .ok = results[0] else { Issue.record("success path: \(results[0])"); return }
        guard case .noAnswer = results[1] else { Issue.record("no-answer path: \(results[1])"); return }
        #expect(results[2] == .failed("The scanner answered but didn't understand MDL."))
        for c in counters { #expect(c.opens == 1 && c.closes == 1) }
    }

    @MainActor @Test func saveRejectsDuplicateWithoutLoad() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        let model = StationEditorModel(station: nil, settings: store)   // load() never called
        try await store.save(station("Lakeview Fire"))                  // "another window" adds it
        model.draft = station("lakeview fire")
        await #expect(throws: StationValidationError.self) { _ = try await model.save() }
        #expect(try await store.stations().count == 1)
    }

    @MainActor @Test func unreadableStoreSurfacesOnLoadAndSave() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("stations.json")
        try Data("{ not json".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let model = StationEditorModel(station: station("Hilltop"), settings: LocalSettingsStore(directory: dir))
        await model.load()
        #expect(model.loadError != nil)
        await #expect(throws: (any Error).self) { _ = try await model.save() }
    }
}

// MARK: - A USB station (SDS150 design §7.1; Plan 8 Task 8)
//
// The only port any of these can open is a MockSerialScanner's link in the test's temporary
// directory, saved as the draft's port by hand. The editor's listing is always a fake one the test
// fills (or the empty one): never the system's.

/// A port listing the test changes as it goes.
private final class TestPortListing: SerialPortListing {
    private let ports = Mutex<[SerialPortInfo]>([])
    func set(_ list: [SerialPortInfo]) { ports.withLock { $0 = list } }
    func unidenPorts() -> [SerialPortInfo] { ports.withLock { $0 } }
}

/// A listed SDS150 at a path that is never opened (nothing is there).
private func listedPort(_ path: String, name: String? = "SDS150 Serial Port") -> SerialPortInfo {
    SerialPortInfo(path: path, productName: name, vendorID: SerialPort.unidenVendorID, productID: 0x001A,
                   serialNumber: nil)
}

private func usbStation(_ name: String) -> Station {
    var s = Station()
    s.name = name
    s.connection.transport = .usbSerial
    return s
}

/// A temporary directory with a settings store in it, and a mock SDS150 behind `<dir>/port`
/// (started unless `start` is false). Always stops the mock; returns what it received.
@MainActor @discardableResult
private func withSerialMock(start: Bool = true, faults: MockFaults? = nil,
                            _ body: (_ store: LocalSettingsStore, _ link: String, _ dir: URL) async throws -> Void)
    async throws -> [String] {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-editor-usb-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let link = dir.appendingPathComponent("port").path
    let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 0), linkPath: link)
    if let faults { await mock.setFaults(faults) }
    if start { _ = try await mock.start() }
    var failure: (any Error)?
    do { try await body(LocalSettingsStore(directory: dir), link, dir) } catch { failure = error }
    await mock.stop()
    let commands = await mock.receivedCommands
    let subscribers = await mock.activeSubscribers
    if let failure { throw failure }
    #expect(subscribers == 0)
    return commands
}

/// A settings store that records its writes in order and can refuse station writes.
private actor RecordingStore: SettingsStore {
    struct Refused: Error {}
    let inner: LocalSettingsStore
    private(set) var writes: [String] = []
    private var failStationWrites = false
    init(wrapping inner: LocalSettingsStore) { self.inner = inner }
    func setFailStationWrites(_ fail: Bool) { failStationWrites = fail }

    func stations() async throws -> [Station] { try await inner.stations() }
    func save(_ station: Station) async throws {
        writes.append("save")
        if failStationWrites { throw Refused() }
        try await inner.save(station)
    }
    func update(id: UUID, _ mutate: @Sendable (inout Station) -> Void) async throws -> Station? {
        writes.append("update")
        if failStationWrites { throw Refused() }
        return try await inner.update(id: id, mutate)
    }
    func deleteStation(id: UUID) async throws { try await inner.deleteStation(id: id) }
    func deviceSettings(for id: UUID) async throws -> StationDeviceSettings { try await inner.deviceSettings(for: id) }
    func saveDeviceSettings(_ s: StationDeviceSettings) async throws {
        writes.append("saveDeviceSettings")
        try await inner.saveDeviceSettings(s)
    }
    func lastStationID() async -> UUID? { await inner.lastStationID() }
    func setLastStationID(_ id: UUID?) async { await inner.setLastStationID(id) }
}

/// Opens the mock's link and closes it again, sending nothing: fails if something still holds it.
private func expectPortReopens(_ link: String) async throws {
    let again = SerialTransport(path: link)
    do { try await again.open() } catch {
        Issue.record("the port didn't reopen: \(error)")
        return
    }
    await again.close()
}

extension StationEditorModelTests {
    @MainActor @Test func usbStatusFollowsThePorts() async throws {
        try await withSerialMock(start: false) { store, _, dir in
            let listing = TestPortListing()
            let model = StationEditorModel(station: usbStation("Handheld"), settings: store, ports: listing)
            await model.load()

            // None listed.
            model.refreshPorts()
            #expect(model.foundPorts == [])
            #expect(model.usbStatus == .noneFound)
            #expect(StationText.usbStatusText(model.usbStatus) == SerialPort.noneFoundHint)

            // One listed: that one.
            let first = listedPort(dir.appendingPathComponent("first").path)
            listing.set([first])
            #expect(model.usbStatus == .noneFound, "the listing is read only by refreshPorts()")
            model.refreshPorts()
            #expect(model.foundPorts == [first])
            #expect(model.usbStatus == .found(first))
            #expect(StationText.usbStatusText(model.usbStatus) == "SDS150 Serial Port on \(first.path)")

            // Two listed: the user chooses.
            let second = listedPort(dir.appendingPathComponent("second").path, name: nil)
            listing.set([first, second])
            model.refreshPorts()
            #expect(model.usbStatus == .choose([first, second]))
            #expect(StationText.usbStatusText(model.usbStatus) == SerialPort.severalFoundHint)
            #expect(StationText.usbStatusText(.found(second)) == "Uniden device on \(second.path)")

            // A saved port that is there wins over the listing, even when not listed itself.
            let saved = dir.appendingPathComponent("saved").path
            #expect(FileManager.default.createFile(atPath: saved, contents: nil))
            model.usbPort = saved
            guard case .found(let info) = model.usbStatus else {
                Issue.record("expected .found, got \(model.usbStatus)"); return
            }
            #expect(info.path == saved)
            #expect(StationText.usbStatusText(model.usbStatus) == "Uniden device on \(saved)")

            // A saved port that isn't there never falls back to a listed one.
            listing.set([first])
            model.refreshPorts()
            let missing = dir.appendingPathComponent("missing").path
            model.usbPort = missing
            #expect(model.usbStatus == .savedPortMissing(missing))
            #expect(StationText.usbStatusText(model.usbStatus)
                    == "\(missing) isn't connected. " + SerialPort.noneFoundHint)
        }
    }

    @MainActor @Test func testConnectionOverSerial() async throws {
        let commands = try await withSerialMock { store, link, _ in
            let model = StationEditorModel(station: usbStation("Handheld"), settings: store,
                                           commandTimeout: .milliseconds(400))
            await model.load()
            model.usbPort = link
            #expect(await model.testConnection() == .ok(model: "SDS150", firmware: "1.01.02"))
            #expect(model.detectedModel == .sds150)
            // The test closed the port: it opens again at once (a port left open would be busy).
            try await expectPortReopens(link)
        }
        #expect(commands == ["MDL", "VER"])
    }

    /// A scanner that doesn't answer `MDL` is a no-answer on its port, and the port is closed
    /// on that path too.
    @MainActor @Test func testConnectionWhenTheScannerDoesntAnswer() async throws {
        let commands = try await withSerialMock(faults: MockFaults(dropNextRequest: "MDL")) { store, link, _ in
            let model = StationEditorModel(station: usbStation("Handheld"), settings: store,
                                           commandTimeout: .milliseconds(400))
            model.usbPort = link
            #expect(await model.testConnection() == .noAnswer(StationSession.noAnswerUSBMessage(port: link)))
            #expect(model.detectedModel == nil)
            try await expectPortReopens(link)
        }
        #expect(commands == ["MDL"])
    }

    @MainActor @Test func testConnectionWithNoPortSaysTheHint() async throws {
        let commands = try await withSerialMock { store, link, dir in
            // Nothing saved and nothing listed.
            let model = StationEditorModel(station: usbStation("Handheld"), settings: store,
                                           commandTimeout: .milliseconds(400))
            await model.load()
            model.refreshPorts()
            #expect(await model.testConnection() == .failed(SerialPort.noneFoundHint))
            // Several listed and nothing saved: never one picked from several (both listed paths
            // are the mock's link and a path with nothing at it).
            let listing = TestPortListing()
            listing.set([listedPort(link), listedPort(dir.appendingPathComponent("other").path)])
            let several = StationEditorModel(station: usbStation("Handheld"), settings: store, ports: listing,
                                             commandTimeout: .milliseconds(400))
            several.refreshPorts()
            #expect(await several.testConnection() == .failed(SerialPort.severalFoundHint))
            // A saved port that isn't there.
            let missing = dir.appendingPathComponent("missing").path
            model.usbPort = missing
            #expect(await model.testConnection()
                    == .failed("\(missing) isn't connected. " + SerialPort.noneFoundHint))
            #expect(model.detectedModel == nil)
        }
        #expect(commands == [])
    }

    @MainActor @Test func testConnectionOnABusyPort() async throws {
        let commands = try await withSerialMock { store, link, _ in
            let holder = SerialTransport(path: link)
            try await holder.open()
            let model = StationEditorModel(station: usbStation("Handheld"), settings: store,
                                           commandTimeout: .milliseconds(400))
            model.usbPort = link
            let result = await model.testConnection()
            await holder.close()
            #expect(result == .failed(StationSession.busyPortMessage(link)))
            #expect(model.detectedModel == nil)
        }
        #expect(commands == [])
    }

    @MainActor @Test func testConnectionWhileTheStationIsOpenSaysDisconnectFirst() async throws {
        let station = usbStation("Handheld")
        let commands = try await withSerialMock { store, link, _ in
            let model = StationEditorModel(station: station, settings: store, commandTimeout: .milliseconds(400),
                                           isOpenElsewhere: { $0 == station.id })
            model.usbPort = link
            #expect(await model.testConnection()
                    == .failed("Disconnect Handheld first: its window is using the scanner."))
        }
        #expect(commands == [])
    }

    @MainActor @Test func testConnectionWithoutASerialTransportIsNotSupported() async throws {
        let commands = try await withSerialMock { store, link, _ in
            let model = StationEditorModel(station: usbStation("Handheld"), settings: store,
                                           makeSerialTransport: { _ in nil })
            model.usbPort = link
            #expect(await model.testConnection() == .failed(StationSession.notSupportedHereMessage))
        }
        #expect(commands == [])
    }

    @MainActor @Test func savingAUSBStationWritesTheDevicePort() async throws {
        try await withSerialMock(start: false) { store, link, _ in
            // A new station, its port chosen.
            let model = StationEditorModel(station: nil, settings: store)
            await model.load()
            model.draft.name = "Handheld"
            model.draft.connection.transport = .usbSerial
            model.usbPort = link
            let saved = try await model.save()
            #expect(model.savedPortChanged)
            let stored = try await store.stations()
            #expect(stored == [saved])
            #expect(saved.connection.transport == .usbSerial)
            #expect(saved.connection.host == nil)
            #expect(try await store.deviceSettings(for: saved.id).usbPort == link)

            // Saving again with the same port changes nothing.
            _ = try await model.save()
            #expect(!model.savedPortChanged)

            // Edited back to Automatic: the port goes, the recordings folder stays.
            var device = try await store.deviceSettings(for: saved.id)
            device.recordingsFolder = "/tmp/Elsewhere"
            try await store.saveDeviceSettings(device)
            let editor = StationEditorModel(station: saved, settings: store)
            await editor.load()
            #expect(editor.usbPort == link)
            editor.usbPort = nil
            _ = try await editor.save()
            #expect(editor.savedPortChanged)
            let after = try await store.deviceSettings(for: saved.id)
            #expect(after.usbPort == nil)
            #expect(after.recordingsFolder == "/tmp/Elsewhere")
        }
    }

    /// The port is written before the station (as `noctule station add` does): a station write
    /// that fails leaves at most a stray port, never a USB station stored without its port
    /// (Automatic, which would take whichever single port is found). A later save that works still
    /// reports the port change.
    @MainActor @Test func aUSBStationsPortIsSavedBeforeTheStation() async throws {
        try await withSerialMock(start: false) { local, link, _ in
            let store = RecordingStore(wrapping: local)
            await store.setFailStationWrites(true)
            let model = StationEditorModel(station: nil, settings: store)
            await model.load()
            model.draft.name = "Handheld"
            model.draft.connection.transport = .usbSerial
            model.usbPort = link
            await #expect(throws: RecordingStore.Refused.self) { _ = try await model.save() }
            #expect(await store.writes == ["saveDeviceSettings", "save"])
            #expect(try await local.stations().isEmpty)
            #expect(try await local.deviceSettings(for: model.draft.id).usbPort == link)

            await store.setFailStationWrites(false)
            let saved = try await model.save()
            #expect(model.savedPortChanged, "the port change of the failed save is still reported")
            #expect(try await local.stations() == [saved])
            #expect(try await local.deviceSettings(for: saved.id).usbPort == link)
        }
    }

    /// Switching a network station to USB keeps its host, ports and reconnect wait as they were.
    @MainActor @Test func switchingToUSBKeepsTheNetworkFields() async throws {
        var original = station("Desk Scanner", host: "192.0.2.10")
        original.connection.udpPort = 50999
        original.connection.reconnectCooldownSeconds = 30
        try await withStore(existing: [original]) { store in
            let model = StationEditorModel(station: original, settings: store)
            await model.load()
            model.draft.connection.transport = .usbSerial
            #expect(model.issues.isEmpty)
            let saved = try await model.save()
            #expect(saved.connection.transport == .usbSerial)
            #expect(saved.connection.host == "192.0.2.10")
            #expect(saved.connection.udpPort == 50999)
            #expect(saved.connection.reconnectCooldownSeconds == 30)
            #expect(!model.savedPortChanged)
            #expect(SessionRegistry.editRestartsSession(from: original, to: saved))
        }
    }

    @MainActor @Test func usbStationNeedsNoHost() async throws {
        try await withEditor { model in
            model.draft = usbStation("Handheld")
            model.draft.connection.host = nil
            #expect(model.issues.isEmpty)
        }
    }
}

// MARK: - A USB station's audio input (line-in design §5.1, §6.1; Plan 18 Task 12)
//
// The listing is always a fixed one the test gives: never the system's.

private let interfaceInput = AudioInputDevice(uid: "fake-uid-interface", name: "Test Interface", channelCount: 2)
private let monoInput = AudioInputDevice(uid: "fake-uid-mono", name: "Test Mono Input", channelCount: 1)

/// A device-settings record for `station`, written to `store` as the editor would find it.
private func saveInput(_ station: Station, uid: String?, name: String?, channel: LineInChannel?,
                       to store: some SettingsStore) async throws {
    var device = StationDeviceSettings(stationID: station.id)
    device.audioInputDevice = uid
    device.audioInputName = name
    device.audioInputChannel = channel
    try await store.saveDeviceSettings(device)
}

/// An input listing the test changes as it goes.
private final class TestAudioListing: AudioInputListing {
    private let devices = Mutex<[AudioInputDevice]>([])
    func set(_ list: [AudioInputDevice]) { devices.withLock { $0 = list } }
    func inputs() -> [AudioInputDevice] { devices.withLock { $0 } }
}

extension StationEditorModelTests {
    @MainActor @Test func loadsTheSavedInput() async throws {
        let handheld = usbStation("Handheld")
        try await withStore(existing: [handheld]) { store in
            try await saveInput(handheld, uid: interfaceInput.uid, name: interfaceInput.name, channel: .right,
                                to: store)
            let model = StationEditorModel(station: handheld, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [interfaceInput, monoInput]))
            await model.load()
            #expect(model.audioInputs == [interfaceInput, monoInput])
            #expect(model.audioInput == interfaceInput.uid)
            #expect(model.audioInputChannel == .right)
            #expect(model.lineInConfig == LineInConfig(deviceUID: interfaceInput.uid,
                                                       deviceName: interfaceInput.name, channel: .right))
            let options = model.audioInputOptions
            #expect(options.map(\.uid) == [nil, interfaceInput.uid, monoInput.uid])
            #expect(options.map(\.title) == ["None (no audio)", "Test Interface", "Test Mono Input"])
        }
    }

    @MainActor @Test func aStationWithNoInputIsNone() async throws {
        let handheld = usbStation("Handheld")
        try await withStore(existing: [handheld]) { store in
            let model = StationEditorModel(station: handheld, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [interfaceInput]))
            await model.load()
            #expect(model.audioInput == nil)
            #expect(model.audioInputChannel == .both)
            #expect(model.lineInConfig == nil)
            #expect(model.audioInputOptions.map(\.title) == ["None (no audio)", "Test Interface"])
            // The listing is read again with the ports.
            #expect(model.audioInputs == [interfaceInput])
        }
    }

    @MainActor @Test func missingInputShowsNotConnected() async throws {
        let handheld = usbStation("Handheld")
        try await withStore(existing: [handheld]) { store in
            try await saveInput(handheld, uid: "fake-uid-unplugged", name: "Unplugged Interface", channel: nil,
                                to: store)
            let model = StationEditorModel(station: handheld, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [monoInput]))
            await model.load()
            #expect(model.audioInput == "fake-uid-unplugged")
            #expect(model.audioInputChannel == .both)
            #expect(model.audioInputOptions.map(\.uid) == [nil, monoInput.uid, "fake-uid-unplugged"])
            #expect(model.audioInputOptions.map(\.title)
                == ["None (no audio)", "Test Mono Input", "Unplugged Interface (not connected)"])
            // Still the station's input, so the missing device is what it would listen to.
            #expect(model.lineInConfig?.deviceName == "Unplugged Interface")
            // Choosing another input keeps the missing one on offer.
            model.audioInput = monoInput.uid
            #expect(model.audioInputOptions.map(\.uid) == [nil, monoInput.uid, "fake-uid-unplugged"])
            #expect(model.lineInConfig?.deviceName == "Test Mono Input")
        }
    }

    @MainActor @Test func savesTheInputBeforeTheStation() async throws {
        try await withSerialMock(start: false) { local, link, _ in
            let store = RecordingStore(wrapping: local)
            let model = StationEditorModel(station: nil, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [interfaceInput]))
            await model.load()
            model.draft.name = "Handheld"
            model.draft.connection.transport = .usbSerial
            model.usbPort = link
            model.audioInput = interfaceInput.uid
            model.audioInputChannel = .left
            let saved = try await model.save()
            // The port and the input in one device-settings write, before the station.
            #expect(await store.writes == ["saveDeviceSettings", "save"])
            let device = try await local.deviceSettings(for: saved.id)
            #expect(device.usbPort == link)
            #expect(device.audioInputDevice == interfaceInput.uid)
            #expect(device.audioInputName == "Test Interface")
            #expect(device.audioInputChannel == .left)
            #expect(model.lineInChanged)
        }
    }

    @MainActor @Test func aFailedStationWriteStillReportsTheInputChange() async throws {
        try await withSerialMock(start: false) { local, link, _ in
            let store = RecordingStore(wrapping: local)
            await store.setFailStationWrites(true)
            let model = StationEditorModel(station: nil, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [interfaceInput]))
            await model.load()
            model.draft.name = "Handheld"
            model.draft.connection.transport = .usbSerial
            model.usbPort = link
            model.audioInput = interfaceInput.uid
            await #expect(throws: RecordingStore.Refused.self) { _ = try await model.save() }
            #expect(!model.lineInChanged)
            await store.setFailStationWrites(false)
            _ = try await model.save()
            #expect(model.lineInChanged, "the input written by the failed save is still reported")
        }
    }

    @MainActor @Test func networkStationClearsTheInput() async throws {
        let desk = station("Desk Scanner")
        try await withStore(existing: [desk]) { store in
            try await saveInput(desk, uid: interfaceInput.uid, name: interfaceInput.name, channel: .left, to: store)
            var device = try await store.deviceSettings(for: desk.id)
            device.recordingsFolder = "/tmp/Elsewhere"
            try await store.saveDeviceSettings(device)
            let model = StationEditorModel(station: desk, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [interfaceInput]))
            await model.load()
            _ = try await model.save()
            let after = try await store.deviceSettings(for: desk.id)
            #expect(after.audioInputDevice == nil && after.audioInputName == nil && after.audioInputChannel == nil)
            #expect(after.recordingsFolder == "/tmp/Elsewhere")
            #expect(model.lineInChanged)
        }
    }

    @MainActor @Test func aNetworkStationWithNoInputWritesNoDeviceSettings() async throws {
        let desk = station("Desk Scanner")
        try await withStore(existing: [desk]) { local in
            let store = RecordingStore(wrapping: local)
            let model = StationEditorModel(station: desk, settings: store)
            await model.load()
            model.draft.name = "Desk Scanner Two"
            _ = try await model.save()
            #expect(await store.writes == ["update"])
            #expect(!model.lineInChanged)
        }
    }

    @MainActor @Test func switchingAUSBStationToNetworkClearsItsInput() async throws {
        let handheld = usbStation("Handheld")
        try await withStore(existing: [handheld]) { store in
            try await saveInput(handheld, uid: interfaceInput.uid, name: interfaceInput.name, channel: .both,
                                to: store)
            let model = StationEditorModel(station: handheld, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [interfaceInput]))
            await model.load()
            model.draft.connection.transport = .network
            model.draft.connection.host = "127.0.0.1"
            _ = try await model.save()
            #expect(try await store.deviceSettings(for: handheld.id).audioInputDevice == nil)
            #expect(model.lineInChanged)
        }
    }

    @MainActor @Test func sharedInputNoteForOverlap() async throws {
        let mine = usbStation("Handheld One")
        let other = usbStation("Handheld Two")
        let desk = station("Desk Scanner")
        try await withStore(existing: [mine, other, desk]) { store in
            @MainActor func setOther(_ channel: LineInChannel?, uid: String? = interfaceInput.uid) async throws {
                try await saveInput(other, uid: uid, name: interfaceInput.name, channel: channel, to: store)
            }
            @MainActor func model(_ channel: LineInChannel, uid: String? = interfaceInput.uid) async -> StationEditorModel {
                let model = StationEditorModel(station: mine, settings: store,
                                               audioInputs: FixedAudioInputListing(inputs: [interfaceInput]))
                await model.load()
                model.audioInput = uid
                model.audioInputChannel = channel
                return model
            }
            // Same side: a note.
            try await setOther(.left)
            #expect(await model(.left).sharedInputNote == "Handheld Two also uses this input (Left).")
            // Opposite sides of one interface: none.
            #expect(await model(.right).sharedInputNote == nil)
            // Both overlaps everything, either way round.
            #expect(await model(.both).sharedInputNote == "Handheld Two also uses this input (Left).")
            try await setOther(.both)
            #expect(await model(.right).sharedInputNote == "Handheld Two also uses this input (Both).")
            // A channel left unset reads as both.
            try await setOther(nil)
            #expect(await model(.left).sharedInputNote == "Handheld Two also uses this input (Both).")
            // Another input, or none chosen here: no note.
            #expect(await model(.left, uid: monoInput.uid).sharedInputNote == nil)
            #expect(await model(.left, uid: nil).sharedInputNote == nil)
            // The station's own saved input never counts.
            try await saveInput(mine, uid: interfaceInput.uid, name: interfaceInput.name, channel: .left, to: store)
            try await setOther(nil, uid: nil)
            #expect(await model(.left).sharedInputNote == nil)
        }
    }

    @MainActor @Test func lineInChangeIsReported() async throws {
        let handheld = usbStation("Handheld")
        try await withStore(existing: [handheld]) { store in
            try await saveInput(handheld, uid: interfaceInput.uid, name: interfaceInput.name, channel: .left,
                                to: store)
            let listing = FixedAudioInputListing(inputs: [interfaceInput, monoInput])
            let model = StationEditorModel(station: handheld, settings: store, audioInputs: listing)
            await model.load()
            #expect(!model.lineInChanged)

            // Nothing about the input edited: not a change.
            model.draft.name = "Handheld Renamed"
            _ = try await model.save()
            #expect(!model.lineInChanged)

            // The channel.
            model.audioInputChannel = .right
            _ = try await model.save()
            #expect(model.lineInChanged)
            #expect(try await store.deviceSettings(for: handheld.id).audioInputChannel == .right)

            // Saving the same thing again.
            _ = try await model.save()
            #expect(!model.lineInChanged)

            // The device.
            model.audioInput = monoInput.uid
            _ = try await model.save()
            #expect(model.lineInChanged)
            let device = try await store.deviceSettings(for: handheld.id)
            #expect(device.audioInputDevice == monoInput.uid && device.audioInputName == "Test Mono Input")

            // None clears all three.
            model.audioInput = nil
            _ = try await model.save()
            #expect(model.lineInChanged)
            let cleared = try await store.deviceSettings(for: handheld.id)
            #expect(cleared.audioInputDevice == nil && cleared.audioInputName == nil
                && cleared.audioInputChannel == nil)
        }
    }

    @MainActor @Test func theSavedChannelStaysAbsentWhileItIsNotEdited() async throws {
        let handheld = usbStation("Handheld")
        try await withStore(existing: [handheld]) { store in
            try await saveInput(handheld, uid: interfaceInput.uid, name: interfaceInput.name, channel: nil, to: store)
            let model = StationEditorModel(station: handheld, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [interfaceInput]))
            await model.load()
            model.draft.name = "Handheld Renamed"
            _ = try await model.save()
            #expect(!model.lineInChanged)
            #expect(try await store.deviceSettings(for: handheld.id).audioInputChannel == nil)
        }
    }

    /// Design §5.1: a UID that moved with the USB socket is found again by its name when exactly one
    /// present input has it, as the runner does; the saved UID stays as it was until the user edits.
    @MainActor @Test func fallsBackToTheSavedName() async throws {
        let handheld = usbStation("Handheld")
        let moved = AudioInputDevice(uid: "fake-uid-interface-new-socket", name: interfaceInput.name, channelCount: 2)
        try await withStore(existing: [handheld]) { store in
            try await saveInput(handheld, uid: interfaceInput.uid, name: interfaceInput.name, channel: .left,
                                to: store)
            let model = StationEditorModel(station: handheld, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [monoInput, moved]))
            await model.load()
            #expect(model.audioInput == moved.uid)
            #expect(model.audioInputOptions.map(\.uid) == [nil, monoInput.uid, moved.uid])
            #expect(!model.audioInputOptions.map(\.title).contains { $0.contains("not connected") })
            #expect(model.lineInConfig == LineInConfig(deviceUID: moved.uid, deviceName: moved.name, channel: .left))

            // An untouched save (here a rename) leaves the three keys as they were.
            model.draft.name = "Handheld Renamed"
            _ = try await model.save()
            #expect(!model.lineInChanged)
            let device = try await store.deviceSettings(for: handheld.id)
            #expect(device.audioInputDevice == interfaceInput.uid)
            #expect(device.audioInputName == interfaceInput.name)
            #expect(device.audioInputChannel == .left)

            // Another input is saved as usual.
            model.audioInput = monoInput.uid
            _ = try await model.save()
            #expect(model.lineInChanged)
            #expect(try await store.deviceSettings(for: handheld.id).audioInputDevice == monoInput.uid)
        }
    }

    @MainActor @Test func theNameFallbackSavesNoneAndAChannelChange() async throws {
        let handheld = usbStation("Handheld")
        let moved = AudioInputDevice(uid: "fake-uid-interface-new-socket", name: interfaceInput.name, channelCount: 2)
        try await withStore(existing: [handheld]) { store in
            try await saveInput(handheld, uid: interfaceInput.uid, name: interfaceInput.name, channel: .left,
                                to: store)
            let listing = FixedAudioInputListing(inputs: [moved])
            let channelEditor = StationEditorModel(station: handheld, settings: store, audioInputs: listing)
            await channelEditor.load()
            channelEditor.audioInputChannel = .right
            _ = try await channelEditor.save()
            #expect(channelEditor.lineInChanged)
            let device = try await store.deviceSettings(for: handheld.id)
            #expect(device.audioInputDevice == interfaceInput.uid && device.audioInputChannel == .right)

            let noneEditor = StationEditorModel(station: handheld, settings: store, audioInputs: listing)
            await noneEditor.load()
            noneEditor.audioInput = nil
            _ = try await noneEditor.save()
            #expect(noneEditor.lineInChanged)
            #expect(try await store.deviceSettings(for: handheld.id).audioInputDevice == nil)
        }
    }

    @MainActor @Test func aSavedNameOnTwoInputsIsNotAMatch() async throws {
        let handheld = usbStation("Handheld")
        let twinA = AudioInputDevice(uid: "fake-uid-twin-a", name: interfaceInput.name, channelCount: 2)
        let twinB = AudioInputDevice(uid: "fake-uid-twin-b", name: interfaceInput.name, channelCount: 2)
        try await withStore(existing: [handheld]) { store in
            try await saveInput(handheld, uid: interfaceInput.uid, name: interfaceInput.name, channel: nil, to: store)
            let model = StationEditorModel(station: handheld, settings: store,
                                           audioInputs: FixedAudioInputListing(inputs: [twinA, twinB]))
            await model.load()
            #expect(model.audioInput == interfaceInput.uid)
            #expect(model.audioInputOptions.map(\.title)
                == ["None (no audio)", "Test Interface", "Test Interface", "Test Interface (not connected)"])
        }
    }

    @MainActor @Test func theNameFallbackFollowsTheListing() async throws {
        let handheld = usbStation("Handheld")
        let moved = AudioInputDevice(uid: "fake-uid-interface-new-socket", name: interfaceInput.name, channelCount: 2)
        try await withStore(existing: [handheld]) { store in
            try await saveInput(handheld, uid: interfaceInput.uid, name: interfaceInput.name, channel: nil, to: store)
            let listing = TestAudioListing()
            let model = StationEditorModel(station: handheld, settings: store, audioInputs: listing)
            await model.load()
            #expect(model.audioInput == interfaceInput.uid)
            listing.set([moved])
            model.refreshPorts()
            #expect(model.audioInput == moved.uid)
            listing.set([])
            model.refreshPorts()
            #expect(model.audioInput == interfaceInput.uid)
            #expect(model.audioInputOptions.last?.title == "Test Interface (not connected)")
        }
    }
}
