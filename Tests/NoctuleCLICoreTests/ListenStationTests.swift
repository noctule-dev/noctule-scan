// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleStore
@testable import NoctuleCLICore

// `noctule listen --station` (Plan 19 Task 5): parsing, the refusals, what a station gives `listen`,
// and the line-in run's status lines and meter. All names and addresses are fictional.

@Suite(.timeLimit(.minutes(1))) struct ListenStationTests {
    private let t0 = ContinuousClock.now
    private let config = LineInConfig(deviceUID: "fictional-input-1", deviceName: "Fictional Interface", channel: .left)

    // MARK: parsing

    @Test func parsesStationMeterAndSettingsDir() throws {
        let a = try CLIArguments.parse(["listen", "--station", "Test Handheld", "--meter", "--settings-dir", "/tmp/s",
                                        "--seconds", "3", "--no-play", "--record", "/tmp/o.wav"])
        #expect(a.command == .listen(record: "/tmp/o.wav", seconds: 3, play: false, station: "Test Handheld", meter: true))
        #expect(a.settingsDir == "/tmp/s")
        #expect(try CLIArguments.parse(["listen"]).command == .listen(record: nil, seconds: nil, play: true, station: nil, meter: false))
    }

    @Test func stationWithAnAddressIsRefused() throws {
        let line = "listen: --station can't be combined with --host or --rtsp-port"
        #expect(try CLIArguments.listenProblem(CLIArguments.parse(["listen", "--station", "X", "--host", "h"])) == line)
        #expect(try CLIArguments.listenProblem(CLIArguments.parse(["listen", "--station", "X", "--rtsp-port", "5544"])) == line)
        #expect(try CLIArguments.listenProblem(CLIArguments.parse(["listen", "--station", "X"])) == nil)
        #expect(try CLIArguments.listenProblem(CLIArguments.parse(["listen", "--host", "h", "--rtsp-port", "5544"])) == nil)
        #expect(try CLIArguments.listenProblem(CLIArguments.parse(["info", "--host", "h"])) == nil)
    }

    @Test func meterWithoutAStationIsRefused() throws {
        let line = "listen: --meter needs a line-in station"
        #expect(try CLIArguments.listenProblem(CLIArguments.parse(["listen", "--meter"])) == line)
        #expect(try CLIArguments.listenProblem(CLIArguments.parse(["listen", "--meter", "--host", "h"])) == line)
        #expect(try CLIArguments.listenProblem(CLIArguments.parse(["listen", "--meter", "--station", "X"])) == nil)
    }

    @Test func meterAndSettingsDirApplyOnlyToListen() {
        for bad in [["log", "--meter"], ["info", "--meter"], ["watch", "--meter"], ["station", "list", "--meter"]] {
            #expect(throws: CLIUsageError.self, "\(bad)") { try CLIArguments.parse(bad) }
        }
        #expect(CLIUsageError.usage.contains("noctule listen --station N [--meter]"))
    }

    // MARK: what a station gives listen

    private func networkStation(wait: Int = 30) -> Station {
        var station = Station()
        station.name = "Test Base"
        station.connection.host = "192.0.2.10"
        station.connection.udpPort = 50999
        station.connection.rtspPort = 5544
        station.connection.reconnectCooldownSeconds = wait
        return station
    }

    private func usbStation(lineIn: Bool) -> (Station, StationDeviceSettings) {
        var station = Station()
        station.name = "Test Handheld"
        station.connection.transport = .usbSerial
        var device = StationDeviceSettings(stationID: station.id)
        device.usbPort = "/tmp/fictional-port"
        if lineIn {
            device.audioInputDevice = "fictional-input-1"
            device.audioInputName = "Fictional Interface"
            device.audioInputChannel = .left
        }
        return (station, device)
    }

    private func invocation(_ args: [String]) throws -> CLIInvocation {
        try CLIArguments.parse(["listen", "--station", "S"] + args)
    }

    @Test func aNetworkStationGivesItsAddressAndWait() throws {
        let station = networkStation(wait: 30)
        let plan = ListenStation.plan(station: station, device: StationDeviceSettings(stationID: station.id),
                                      invocation: try invocation([]))
        #expect(plan == .network(AudioTarget(host: "192.0.2.10", rtspPort: 5544, controlPort: 50999),
                                 RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .seconds(30))))
    }

    @Test func aNetworkStationKeepsTheMockOnlyFullValueAndTheFlags() throws {
        let station = networkStation(wait: 30)
        let device = StationDeviceSettings(stationID: station.id)
        let shortened = ListenStation.plan(station: station, device: device,
                                           invocation: try invocation(["--cooldown-seconds", "5", "--cooldown-store", "/tmp/c.json"]))
        #expect(shortened == .network(AudioTarget(host: "192.0.2.10", rtspPort: 5544, controlPort: 50999),
                                      RTSPCooldownPolicy(full: .seconds(5), afterCleanClose: .seconds(30))))
        let flags = ListenStation.plan(station: station, device: device,
                                       invocation: try invocation(["--port", "50111", "--reconnect-cooldown", "60"]))
        #expect(flags == .network(AudioTarget(host: "192.0.2.10", rtspPort: 5544, controlPort: 50111),
                                  RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .seconds(60))))
    }

    @Test func aNetworkStationRefusesTheMeter() throws {
        let station = networkStation()
        let plan = ListenStation.plan(station: station, device: StationDeviceSettings(stationID: station.id),
                                      invocation: try invocation(["--meter"]))
        #expect(plan == .refused(line: "listen: --meter needs a line-in station", exitCode: 2))
    }

    @Test func aNetworkStationWithoutAHostIsRefused() throws {
        var station = networkStation()
        station.connection.host = "  "
        let plan = ListenStation.plan(station: station, device: StationDeviceSettings(stationID: station.id),
                                      invocation: try invocation([]))
        #expect(plan == .refused(line: "listen: Test Base has no address", exitCode: 1))
    }

    @Test func aUSBStationGivesItsLineIn() throws {
        let (station, device) = usbStation(lineIn: true)
        #expect(ListenStation.plan(station: station, device: device, invocation: try invocation(["--meter"])) == .lineIn(config))
    }

    @Test func aUSBStationWithoutAnInputIsRefused() throws {
        let (station, device) = usbStation(lineIn: false)
        #expect(ListenStation.plan(station: station, device: device, invocation: try invocation([]))
            == .refused(line: "listen: Test Handheld has no audio input", exitCode: 1))
        var bluetooth = station
        bluetooth.connection.transport = .bluetooth
        #expect(ListenStation.plan(station: bluetooth, device: device, invocation: try invocation([]))
            == .refused(line: "listen: Test Handheld has no audio input", exitCode: 1))
    }

    // MARK: the line-in run's status

    @Test func statesBecomeLines() {
        var status = LineInListenStatus(config: config)
        #expect(status.handle(.starting) == .none)
        #expect(status.handle(.missing(deviceName: "Fictional Interface"))
            == .print("audio: line-in \"Fictional Interface\" isn't connected; waiting"))
        #expect(status.handle(.missing(deviceName: "Fictional Interface")) == .none)
        #expect(status.handle(.streaming(deviceName: "Fictional Interface")) == .print("audio: line-in Fictional Interface (left)"))
        #expect(status.handle(.streaming(deviceName: "Fictional Interface")) == .none)
        #expect(status.handle(.missing(deviceName: "Fictional Interface"))
            == .print("audio: line-in \"Fictional Interface\" isn't connected; waiting"))
        #expect(status.handle(.streaming(deviceName: "Fictional Interface")) == .print("audio: line-in Fictional Interface (left)"))
        #expect(status.handle(.stopped) == .none)
    }

    @Test func aRefusedInputEndsTheRun() {
        var status = LineInListenStatus(config: config)
        #expect(status.handle(.failed("audio input disabled by NOCTULE_NO_USB_DETECTION"))
            == .fail("audio: failed: audio input disabled by NOCTULE_NO_USB_DETECTION"))
        var denied = LineInListenStatus(config: config)
        #expect(denied.handle(.denied) == .fail(
            "audio: failed: this terminal isn't allowed to use audio input. Allow it in System Settings › Privacy & Security › Microphone."))
        // The same sentence as `log`'s warning.
        #expect(StationCLI.terminalDeniedLine == "warning: " + StationCLI.terminalDeniedText)
        // An input that was missing and then fails to open has still never streamed: fatal.
        var never = LineInListenStatus(config: config)
        #expect(never.handle(.missing(deviceName: "Fictional Interface"))
            == .print("audio: line-in \"Fictional Interface\" isn't connected; waiting"))
        #expect(never.handle(.failed("couldn't start the audio input \"Fictional Interface\": fictional error"))
            == .fail("audio: failed: couldn't start the audio input \"Fictional Interface\": fictional error"))
        #expect(!never.hasStreamed)
    }

    /// Once the input has streamed, a failure is a wait, as `log` treats it (the source watches
    /// for the device and starts again, as after a replug): one line per change, the run goes on,
    /// no meter meanwhile, and streaming again prints its line again. A denial stays fatal.
    @Test func aFailureAfterStreamingIsAWait() {
        var status = LineInListenStatus(config: config)
        #expect(!status.hasStreamed)
        #expect(status.handle(.streaming(deviceName: "Fictional Interface")) == .print("audio: line-in Fictional Interface (left)"))
        #expect(status.hasStreamed)
        let reason = "couldn't start the audio input \"Fictional Interface\": fictional error"
        #expect(status.handle(.failed(reason)) == .print("audio: \(reason); waiting"))
        #expect(ListenStation.failedWaitingLine(reason) == "audio: \(reason); waiting")
        #expect(status.handle(.failed(reason)) == .none)
        #expect(status.meterLine(at: t0) == nil)
        #expect(status.handle(.missing(deviceName: "Fictional Interface"))
            == .print("audio: line-in \"Fictional Interface\" isn't connected; waiting"))
        #expect(status.handle(.failed(reason)) == .print("audio: \(reason); waiting"))
        #expect(status.handle(.streaming(deviceName: "Fictional Interface")) == .print("audio: line-in Fictional Interface (left)"))
        #expect(status.hasStreamed)
        #expect(status.handle(.denied) == .fail(
            "audio: failed: this terminal isn't allowed to use audio input. Allow it in System Settings › Privacy & Security › Microphone."))
    }

    @Test func theMeterShowsOnlyWhileStreaming() {
        var status = LineInListenStatus(config: config)
        status.handle(LineInLevel(peakDBFS: -9, rmsDBFS: -15, clipped: false, at: t0))
        #expect(status.meterLine(at: t0) == nil)
        _ = status.handle(.streaming(deviceName: "Fictional Interface"))
        #expect(status.meterLine(at: t0) == "line-in ··················|·· peak −∞ dBFS")
        status.handle(LineInLevel(peakDBFS: -9, rmsDBFS: -15, clipped: true, at: t0))
        #expect(status.meterLine(at: t0) == "line-in ▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇·|·· peak −9 dBFS CLIP")
        // Unplugged: no line at all, not the last peak held.
        _ = status.handle(.missing(deviceName: "Fictional Interface"))
        #expect(status.meterLine(at: t0) == nil)
        status.handle(LineInLevel(peakDBFS: -3, rmsDBFS: -9, clipped: false, at: t0))
        #expect(status.meterLine(at: t0) == nil)
        // Back: a fresh meter, nothing held from before the unplug.
        _ = status.handle(.streaming(deviceName: "Fictional Interface"))
        #expect(status.meterLine(at: t0) == "line-in ··················|·· peak −∞ dBFS")
    }

    // MARK: writing the meter beside status lines

    @Test func onATerminalTheMeterIsRedrawnInPlace() {
        var output = MeterOutput(isTerminal: true)
        #expect(output.status("audio: line-in Fictional Interface (left)") == "audio: line-in Fictional Interface (left)\n")
        #expect(output.meter("line-in A") == "\rline-in A\u{1B}[K")
        #expect(output.meter("line-in B") == "\rline-in B\u{1B}[K")
        // A status line clears the meter's line first; the meter is drawn again under it.
        #expect(output.status("audio: line-in \"Fictional Interface\" isn't connected; waiting")
            == "\r\u{1B}[Kaudio: line-in \"Fictional Interface\" isn't connected; waiting\n")
        #expect(output.finish() == "")
        _ = output.meter("line-in C")
        #expect(output.finish() == "\n")
        #expect(output.finish() == "")
    }

    @Test func intoAPipeTheMeterIsALineEach() {
        var output = MeterOutput(isTerminal: false)
        #expect(output.meter("line-in A") == "line-in A\n")
        #expect(output.status("audio: x") == "audio: x\n")
        #expect(output.meter("line-in B") == "line-in B\n")
        #expect(output.finish() == "")
    }
}
