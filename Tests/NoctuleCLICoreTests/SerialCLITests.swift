// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleDevConfig
import NoctuleStore
@testable import NoctuleCLICore

/// Runs `body` with a temporary directory holding `config/dev-scanner.env` with `text` (none when nil).
private func withConfig(_ text: String?, _ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "noctule-serial-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    if let text {
        try text.write(to: root.appending(path: "config/dev-scanner.env"), atomically: true, encoding: .utf8)
    }
    try body(root.standardizedFileURL)
}

private func port(_ path: String, product: String? = "Test Scanner", productID: Int = 0x001A) -> SerialPortInfo {
    SerialPortInfo(path: path, productName: product, vendorID: SerialPort.unidenVendorID, productID: productID,
                   serialNumber: nil)
}

@Suite struct SerialArgumentsTests {
    @Test func serialFlag() throws {
        #expect(try CLIArguments.parse(["info", "--serial"]).serial == .auto)
        #expect(try CLIArguments.parse(["info", "--serial", "/dev/ttys004"]).serial == .path("/dev/ttys004"))
        let watch = try CLIArguments.parse(["watch", "--serial", "--count", "3"])
        #expect(watch.serial == .auto)
        #expect(watch.command == .watch(interval: .milliseconds(500), count: 3))
        #expect(try CLIArguments.parse(["info"]).serial == nil)
        // The path is taken only when it starts with "/": anything else is the next argument.
        let status = try CLIArguments.parse(["--serial", "status"])
        #expect(status.serial == .auto && status.command == .status)
        #expect(try CLIArguments.parse(["status", "--serial", "--port", "5"]).serial == .auto)
        #expect(try CLIArguments.parse(["display", "--serial", "/tmp/p"]).serial == .path("/tmp/p"))
    }

    @Test func serialIsAcceptedWhereARefusalNeedsAReason() throws {
        #expect(try CLIArguments.parse(["listen", "--serial"]).serial == .auto)
        #expect(try CLIArguments.parse(["restart", "--serial"]).serial == .auto)
        for other in [["log", "--serial"], ["hits", "--serial"], ["station", "list", "--serial"],
                      ["station", "add", "--name", "A", "--serial"], ["ports", "--serial"]] {
            #expect(throws: CLIUsageError.self, "\(other)") { try CLIArguments.parse(other) }
        }
    }

    @Test func serialProblems() throws {
        func problem(_ args: [String]) throws -> String? { CLIArguments.serialProblem(try CLIArguments.parse(args)) }
        let combined = "--serial can't be combined with --host or --port"
        #expect(try problem(["info", "--serial", "--host", "h"]) == combined)
        #expect(try problem(["info", "--serial", "/tmp/p", "--host", "h"]) == combined)
        #expect(try problem(["status", "--serial", "--port", "5"]) == combined)
        #expect(try problem(["listen", "--serial"]) == "listen: no audio over USB")
        #expect(try problem(["restart", "--serial"]) == "restart: not supported over USB")
        #expect(try problem(["info", "--serial"]) == nil)
        #expect(try problem(["info", "--serial", "/tmp/p"]) == nil)
        #expect(try problem(["watch", "--serial", "--count", "2"]) == nil)
        // Without --serial there is nothing to refuse, whatever else is given.
        #expect(try problem(["info", "--host", "h", "--port", "5"]) == nil)
        #expect(try problem(["listen"]) == nil)
        #expect(try problem(["restart", "--yes"]) == nil)
    }

    @Test func portsCommand() throws {
        #expect(try CLIArguments.parse(["ports"]) == CLIInvocation(command: .ports))
        for bad in [["ports", "--host", "h"], ["ports", "--port", "5"], ["ports", "extra"]] {
            #expect(throws: CLIUsageError.self, "\(bad)") { try CLIArguments.parse(bad) }
        }
    }

    @Test func audioInputsCommand() throws {
        #expect(try CLIArguments.parse(["audio-inputs"]) == CLIInvocation(command: .audioInputs))
        for bad in [["audio-inputs", "--host", "x"], ["audio-inputs", "--port", "5"], ["audio-inputs", "--serial"],
                    ["audio-inputs", "extra"], ["audio-inputs", "--settings-dir", "d"]] {
            #expect(throws: CLIUsageError.self, "\(bad)") { try CLIArguments.parse(bad) }
        }
        #expect(CLIUsageError.usage.contains("audio-inputs"))
    }

    @Test func usageMentionsSerialPortsAndUSBStations() {
        let usage = CLIUsageError.usage
        #expect(usage.contains("ports"))
        #expect(usage.contains("[--serial [PATH]]"))
        #expect(usage.contains("noctule station add --name N --usb [--serial-port PATH]"))
    }
}

@Suite struct SerialConfigTests {
    @Test func serialPathConfig() throws {
        try withConfig("SCANNER_HOST=h\n") { dir in
            let url = dir.appending(path: "config/dev-scanner.env")
            let path = try DevScannerConfig.serialPath(from: url)
            #expect(path == nil)
        }
        try withConfig("SCANNER_SERIAL=\n") { dir in
            let path = try DevScannerConfig.serialPath(from: dir.appending(path: "config/dev-scanner.env"))
            #expect(path == nil)
        }
        try withConfig("SCANNER_SERIAL=auto\n") { dir in
            let path = try DevScannerConfig.serialPath(from: dir.appending(path: "config/dev-scanner.env"))
            #expect(path == nil)
        }
        try withConfig("# SCANNER_SERIAL=/tmp/commented\n") { dir in
            let path = try DevScannerConfig.serialPath(from: dir.appending(path: "config/dev-scanner.env"))
            #expect(path == nil)
        }
        try withConfig("SCANNER_SERIAL = /tmp/p \n") { dir in
            let path = try DevScannerConfig.serialPath(from: dir.appending(path: "config/dev-scanner.env"))
            #expect(path == "/tmp/p")
        }
        try withConfig(nil) { dir in
            #expect(throws: (any Error).self) { try DevScannerConfig.serialPath(from: dir.appending(path: "config/dev-scanner.env")) }
        }
    }

    /// The SDS100's hardware suites read their own key, by the same rules; the default key stays
    /// `SCANNER_SERIAL`, and neither reads the other's.
    @Test func devScannerConfigReadsTheKeyGiven() throws {
        let file = "SCANNER_SERIAL=/tmp/sds150\nSCANNER_SERIAL_SDS100 = /tmp/sds100 \n"
        try withConfig(file) { dir in
            let url = dir.appending(path: "config/dev-scanner.env")
            let sds100 = try DevScannerConfig.serialPath(from: url, key: "SCANNER_SERIAL_SDS100")
            let byDefault = try DevScannerConfig.serialPath(from: url)
            let named = try DevScannerConfig.serialPath(from: url, key: "SCANNER_SERIAL")
            #expect(sds100 == "/tmp/sds100")
            #expect(byDefault == "/tmp/sds150")
            #expect(named == "/tmp/sds150")
        }
        try withConfig("SCANNER_SERIAL=/tmp/sds150\n") { dir in
            let path = try DevScannerConfig.serialPath(from: dir.appending(path: "config/dev-scanner.env"),
                                                       key: "SCANNER_SERIAL_SDS100")
            #expect(path == nil)
        }
        try withConfig("SCANNER_SERIAL_SDS100=/tmp/sds100\n") { dir in
            let path = try DevScannerConfig.serialPath(from: dir.appending(path: "config/dev-scanner.env"))
            #expect(path == nil)
        }
        for value in ["auto", "AUTO", ""] {
            try withConfig("SCANNER_SERIAL=\(value)\nSCANNER_SERIAL_SDS100=\(value)\n") { dir in
                let url = dir.appending(path: "config/dev-scanner.env")
                let sds100 = try DevScannerConfig.serialPath(from: url, key: "SCANNER_SERIAL_SDS100")
                let byDefault = try DevScannerConfig.serialPath(from: url)
                #expect(sds100 == nil, "\(value)")
                #expect(byDefault == nil, "\(value)")
            }
        }
    }

    @Test func serialOnlyFileIsStillNotANetworkConfig() throws {
        try withConfig("SCANNER_SERIAL=/tmp/p\n") { dir in
            let url = dir.appending(path: "config/dev-scanner.env")
            #expect(throws: DevScannerConfigError.missingHost) { try DevScannerConfig.load(from: url) }
            let path = try DevScannerConfig.serialPath(from: url)
            #expect(path == "/tmp/p")
        }
    }

    /// Without `--serial` nothing about the network target changes, whatever `SCANNER_SERIAL` holds.
    @Test func hostResolutionUnchanged() throws {
        try withConfig("SCANNER_HOST=cfg.example.lan\nSCANNER_UDP_PORT=6000\nSCANNER_SERIAL=/tmp/p\n") { dir in
            let r = resolveHost(invocation: CLIInvocation(command: .info), searchingFrom: dir)
            #expect(r?.host == "cfg.example.lan" && r?.port == 6000)
            let a = resolveAudioTarget(invocation: CLIInvocation(command: .restart(confirmed: false)), searchingFrom: dir)
            #expect(a == AudioTarget(host: "cfg.example.lan", rtspPort: 554, controlPort: 6000))
        }
        // A file with only SCANNER_SERIAL gives no network target.
        try withConfig("SCANNER_SERIAL=/tmp/p\n") { dir in
            #expect(resolveHost(invocation: CLIInvocation(command: .info), searchingFrom: dir) == nil)
        }
    }
}

@Suite struct ResolveSerialTests {
    private let listed = port("/dev/cu.listed")
    private func resolve(_ invocation: CLIInvocation, in dir: URL, ports: [SerialPortInfo],
                         exists: @escaping (String) -> Bool = { _ in true }) -> SerialPortResolution {
        // Detection on: these tests are about the order of the other sources.
        resolveSerial(invocation: invocation, searchingFrom: dir, ports: ports, exists: exists, environment: [:])
    }

    @Test func resolveSerialOrder() throws {
        let flagPath = CLIInvocation(command: .info, serial: .path("/tmp/flag"))
        let bare = CLIInvocation(command: .info, serial: .auto)
        // The flag's path wins over SCANNER_SERIAL.
        try withConfig("SCANNER_SERIAL=/tmp/p\n") { dir in
            #expect(resolve(flagPath, in: dir, ports: [listed]) == .found(path: "/tmp/flag", info: nil))
            // SCANNER_SERIAL is used for a bare --serial, ahead of the listed ports.
            #expect(resolve(bare, in: dir, ports: [listed]) == .found(path: "/tmp/p", info: nil))
        }
        // SCANNER_SERIAL=auto, an absent key and a missing file fall to the listed ports.
        try withConfig("SCANNER_SERIAL=auto\n") { dir in
            #expect(resolve(bare, in: dir, ports: [listed]) == .found(path: "/dev/cu.listed", info: listed))
            #expect(resolve(bare, in: dir, ports: []) == .noneFound)
            #expect(resolve(bare, in: dir, ports: [listed, port("/dev/cu.other")])
                == .severalFound([listed, port("/dev/cu.other")]))
        }
        try withConfig("SCANNER_HOST=h\n") { dir in
            #expect(resolve(bare, in: dir, ports: [listed]) == .found(path: "/dev/cu.listed", info: listed))
        }
        try withConfig(nil) { dir in
            #expect(resolve(bare, in: dir, ports: [listed]) == .found(path: "/dev/cu.listed", info: listed))
            #expect(resolve(bare, in: dir, ports: []) == .noneFound)
        }
        // A config file with only SCANNER_SERIAL (no host) works.
        try withConfig("SCANNER_SERIAL=/tmp/only\n") { dir in
            #expect(resolve(bare, in: dir, ports: []) == .found(path: "/tmp/only", info: nil))
        }
    }

    /// A path given by the flag or by SCANNER_SERIAL is used as given: it never becomes a detected port
    /// (on the owner's Mac the detected port is the real scanner).
    @Test func explicitPathNeverFallsBack() throws {
        try withConfig(nil) { dir in
            let flag = CLIInvocation(command: .info, serial: .path("/nonexistent/port"))
            #expect(resolve(flag, in: dir, ports: [listed], exists: { _ in false })
                == .found(path: "/nonexistent/port", info: nil))
            #expect(resolve(flag, in: dir, ports: [], exists: { _ in false })
                == .found(path: "/nonexistent/port", info: nil))
        }
        try withConfig("SCANNER_SERIAL=/nonexistent/configured\n") { dir in
            let bare = CLIInvocation(command: .info, serial: .auto)
            #expect(resolve(bare, in: dir, ports: [listed], exists: { _ in false })
                == .found(path: "/nonexistent/configured", info: nil))
        }
    }

    /// With `NOCTULE_NO_USB_DETECTION` set, a bare `--serial` finds nothing: not `SCANNER_SERIAL`, not
    /// a listed port. Only a path on the command line is opened.
    @Test func detectionOffFindsNothingForABareSerial() throws {
        let off = [USBDetection.disableKey: "1"]
        try withConfig("SCANNER_SERIAL=/tmp/p\n") { dir in
            let bare = CLIInvocation(command: .info, serial: .auto)
            #expect(resolveSerial(invocation: bare, searchingFrom: dir, ports: [listed], exists: { _ in true },
                                  environment: off) == .noneFound)
            let flag = CLIInvocation(command: .info, serial: .path("/tmp/q"))
            #expect(resolveSerial(invocation: flag, searchingFrom: dir, ports: [listed], exists: { _ in true },
                                  environment: off) == .found(path: "/tmp/q", info: nil))
            // Detection on (unset or empty): today's order, SCANNER_SERIAL first.
            for on in [[:], [USBDetection.disableKey: ""]] {
                #expect(resolveSerial(invocation: bare, searchingFrom: dir, ports: [listed], exists: { _ in true },
                                      environment: on) == .found(path: "/tmp/p", info: nil))
            }
        }
    }

    @Test func noSerialFlagFindsNoPort() throws {
        // resolveSerial is for --serial invocations; without the flag it never reads SCANNER_SERIAL.
        try withConfig("SCANNER_SERIAL=/tmp/p\n") { dir in
            #expect(resolve(CLIInvocation(command: .info), in: dir, ports: [listed]) == .noneFound)
        }
    }
}

/// A port listing that records whether it was asked.
private final class FakeListing: SerialPortListing {
    private let ports: [SerialPortInfo]
    private let asked = Mutex(false)
    init(_ ports: [SerialPortInfo]) { self.ports = ports }
    var wasAsked: Bool { asked.withLock { $0 } }
    func unidenPorts() -> [SerialPortInfo] {
        asked.withLock { $0 = true }
        return ports
    }
}

@Suite struct USBDetectionTests {
    private let key = USBDetection.disableKey

    /// Unset or empty: detection on. Any other value, "0" included: off.
    @Test func killSwitch() {
        #expect(key == "NOCTULE_NO_USB_DETECTION")
        #expect(USBDetection.isEnabled([:]))
        #expect(USBDetection.isEnabled([key: ""]))
        #expect(USBDetection.isEnabled(["OTHER": "1"]))
        for value in ["1", "0", "no", "false", " "] {
            #expect(!USBDetection.isEnabled([key: value]), "\(value)")
        }
    }

    @Test func listingHonoursTheKillSwitch() {
        let system = FakeListing([port("/dev/cu.system")])
        #expect(USBDetection.listing(environment: [:], system: system).unidenPorts().map(\.path) == ["/dev/cu.system"])
        #expect(USBDetection.listing(environment: [key: ""], system: system).unidenPorts().map(\.path) == ["/dev/cu.system"])
        let off = FakeListing([port("/dev/cu.system")])
        #expect(USBDetection.listing(environment: [key: "1"], system: off).unidenPorts() == [])
        #expect(!off.wasAsked, "with detection off the system listing is never asked")
    }

    /// `NOCTULE_TEST_SERIAL_PORTS` replaces the system listing (never asked), and the kill-switch
    /// still applies on top of it.
    @Test func testPortsReplaceTheSystemListing() {
        #expect(USBDetection.testPortsKey == "NOCTULE_TEST_SERIAL_PORTS")
        let system = FakeListing([port("/dev/cu.system")])
        let listed = USBDetection.listing(environment: [USBDetection.testPortsKey: "/tmp/a:/tmp/b"], system: system)
            .unidenPorts()
        #expect(listed.map(\.path) == ["/tmp/a", "/tmp/b"])
        #expect(listed.allSatisfy {
            $0.vendorID == SerialPort.unidenVendorID && $0.knownModel == .sds150 && $0.productName == "SDS150 Serial Port"
        })
        #expect(!system.wasAsked)
        let both = USBDetection.listing(environment: [USBDetection.testPortsKey: "/tmp/a", key: "1"], system: system)
        #expect(both.unidenPorts() == [])
        #expect(!system.wasAsked)
        // Empty: the system listing.
        #expect(USBDetection.listing(environment: [USBDetection.testPortsKey: ""], system: system).unidenPorts().map(\.path)
            == ["/dev/cu.system"])
    }

    /// The shell says when the test listing is in effect (one note), and only then.
    @Test func testPortsOverrideIsNoted() {
        let test = USBDetection.testPortsKey
        #expect(USBDetection.overrideNotes([test: "/tmp/a:/tmp/b"])
            == ["NOCTULE_TEST_SERIAL_PORTS=/tmp/a:/tmp/b (in place of the system's serial port listing)"])
        #expect(USBDetection.overrideNotes([test: "/tmp/a", key: ""]).count == 1)
        // Not in effect: detection off, or no paths.
        #expect(USBDetection.overrideNotes([test: "/tmp/a", key: "1"]) == [])
        #expect(USBDetection.overrideNotes([test: ""]) == [])
        #expect(USBDetection.overrideNotes([test: ":"]) == [])
        #expect(USBDetection.overrideNotes([:]) == [])
    }
}

@Suite struct SerialShellFormatTests {
    @Test func serialOpenFailures() {
        let busy = CLIFormat.serialOpenFailure(SerialTransportError.busy("/tmp/p"))
        #expect(busy?.line == "/tmp/p is in use by another program.")
        #expect(busy?.exitCode == 1)
        let missing = CLIFormat.serialOpenFailure(SerialTransportError.noSuchPort("/tmp/p"))
        #expect(missing?.line == "/tmp/p: no such port")
        #expect(missing?.exitCode == 2)
        #expect(CLIFormat.serialOpenFailure(SerialTransportError.openFailed("x")) == nil)
        #expect(CLIFormat.serialOpenFailure(ScannerClientError.timeout(command: "MDL")) == nil)
    }

    @Test func resolutionFailures() {
        #expect(CLIFormat.serialResolutionFailure(.noneFound)
            == ["No Uniden scanner found. Plug the scanner in and choose Serial Port on its screen."])
        let a = port("/dev/cu.a"), b = port("/dev/cu.b", product: nil, productID: 0x7777)
        #expect(CLIFormat.serialResolutionFailure(.severalFound([a, b])) == [
            "/dev/cu.a  Test Scanner  unknown model",
            "/dev/cu.b  Uniden device  unknown model",
            "Pass --serial PATH to choose one.",
        ])
        #expect(CLIFormat.serialResolutionFailure(.found(path: "/dev/cu.a", info: a)) == nil)
    }

    @Test func noBatteryLine() {
        #expect(CLIFormat.noBatteryLine(ScannerClientError.timeout(command: "GCS")) == "warning: no battery status (no answer to GCS)")
        #expect(CLIFormat.noBatteryLine(ScannerClientError.unexpectedResponse(command: "GCS"))
            == "warning: no battery status (unreadable answer to GCS)")
        #expect(CLIFormat.noBatteryLine(ScannerClientError.rejected(command: "GCS", response: "GCS,NG"))
            == "warning: no battery status (the scanner answered GCS,NG)")
    }

    @Test func stallMessageForAPort() {
        #expect(WatchLoop.stallMessage(target: "/tmp/p", deadline: .seconds(5)) == "no PSI updates from /tmp/p for 5 s")
        #expect(WatchLoop.stallMessage(host: "h", port: 7, deadline: .milliseconds(5100)) == "no PSI updates from h:7 for 5.1 s")
    }

    @Test func usbLogLines() {
        #expect(StationCLI.eventOutput(.disconnected(hint: SerialPort.noneFoundHint))
            == .stderr("log: scanner disconnected. Plug the scanner in and choose Serial Port on its screen."))
        #expect(StationCLI.eventOutput(.connected(model: "SDS150", firmware: "1.01.02"), reconnect: true)
            == .stderr("log: reconnected SDS150 1.01.02"))
        #expect(StationCLI.eventOutput(.connected(model: "SDS150", firmware: "1.01.02"), reconnect: false)
            == .stderr("log: connected to SDS150 (firmware 1.01.02)"))
        #expect(StationCLI.noAudioOverUSBLine == "log: no audio over USB")
        #expect(StationCLI.waitingForScannerLine == "log: waiting for the scanner…")
    }

    @Test func logStartFailures() {
        #expect(StationCLI.startFailureLine(SerialTransportError.busy("/tmp/p"), stationName: "Truck")
            == "/tmp/p is in use by another program.")
        #expect(StationCLI.startFailureLine(StationTransportError.scannerNotFound(hint: SerialPort.noneFoundHint), stationName: "Truck")
            == "log: couldn't start \"Truck\": Plug the scanner in and choose Serial Port on its screen.")
        #expect(StationCLI.startFailureLine(ScannerClientError.timeout(command: "MDL"), stationName: "Truck")
            == "log: couldn't start \"Truck\": timeout(command: \"MDL\")")
    }

    @Test func addedLines() {
        var usb = StationCLI.makeStation(StationAddOptions(name: "Truck", host: "", usb: true, serialPort: "/tmp/p"))
        #expect(StationCLI.addedLine(usb, usbPort: "/tmp/p") == "added station \"Truck\" (USB /tmp/p, save audio: every)")
        #expect(StationCLI.addedLine(usb, usbPort: nil) == "added station \"Truck\" (USB, save audio: every)")
        usb.recording.saveAudio = .never
        #expect(StationCLI.addedLine(usb, usbPort: nil) == "added station \"Truck\" (USB, save audio: never)")
        let net = StationCLI.makeStation(StationAddOptions(name: "Base", host: "h", udpPort: 6000, saveAudio: .onlyNew))
        #expect(StationCLI.addedLine(net, usbPort: nil) == "added station \"Base\" (h, udp 6000, rtsp 554, save audio: new)")
    }
}
