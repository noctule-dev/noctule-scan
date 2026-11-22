// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleDevConfig
import NoctuleKitTestSupport
@testable import NoctuleCLICore

// The GSI fixture is the bare XML document (the "GSI,<XML>," prefix is already stripped).
private func gsi() throws -> ScannerInfo {
    try ScannerInfo(xml: XMLNode.parse(fixture("gsi-trunk-sds200-1.24.00.xml")))
}

/// The SDS150's serial `GSI` fixture, its `GSI,<XML>,` line dropped: a conventional channel.
private func sds150GSI() throws -> ScannerInfo {
    let text = String(decoding: fixture("sds150-gsi-serial.txt"), as: UTF8.self)
    let document = try #require(text.split(separator: "\n", maxSplits: 1).last)
    return try ScannerInfo(xml: XMLNode.parse(Data(document.utf8)))
}

@Suite(.timeLimit(.minutes(3))) struct CLIFormatTests {
    @Test func infoLines() {
        #expect(CLIFormat.info(model: "SDS200", firmware: "1.24.00", volume: 2, squelch: 1)
            == ["model: SDS200", "firmware: 1.24.00", "volume: 2", "squelch: 1"])
    }

    private func charge(_ cst: Int, percent: Int = 100) throws -> ChargeStatus {
        try ChargeStatus(fields: ["CST=\(cst)", "VOLT=4184mV:\(percent)%", "CURR=0mA", "TEMP=24.50C"])
    }

    @Test func infoBattery() throws {
        // Without a battery the four lines are unchanged.
        #expect(CLIFormat.info(model: "SDS150", firmware: "1.03.00", volume: 2, squelch: 1, battery: nil)
            == ["model: SDS150", "firmware: 1.03.00", "volume: 2", "squelch: 1"])
        #expect(CLIFormat.info(model: "SDS150", firmware: "1.03.00", volume: 2, squelch: 1, battery: try charge(4))
            == ["model: SDS150", "firmware: 1.03.00", "volume: 2", "squelch: 1", "battery: 100% (full)"])
        let words: [(Int, String)] = [(4, "full"), (6, "charging"), (0, "not charging"), (5, "recharging"),
                                      (1, "initializing"), (2, "temperature fault"), (3, "power fault"),
                                      (9, "unknown, CST=9"), (7, "unknown, CST=7"), (-1, "unknown, CST=-1")]
        for (code, word) in words {
            let lines = CLIFormat.info(model: "SDS150", firmware: "1.03.00", volume: 2, squelch: 1,
                                       battery: try charge(code, percent: 57))
            #expect(lines.last == "battery: 57% (\(word))", "CST=\(code)")
        }
    }

    @Test func audioInputLineFormat() {
        let device = AudioInputDevice(uid: "UID-1", name: "Fictional Interface", channelCount: 2)
        #expect(CLIFormat.audioInputLine(device) == "UID-1  Fictional Interface  2 ch")
        #expect(CLIFormat.audioInputLine(AudioInputDevice(uid: "UID-2", name: "Mono Input", channelCount: 1))
                == "UID-2  Mono Input  1 ch")
        #expect(CLIFormat.noAudioInputsLine == "No audio inputs found.")
    }

    @Test func portsFormat() {
        let a = SerialPortInfo(path: "/dev/cu.usbmodem0001", productName: "Test Scanner", vendorID: SerialPort.unidenVendorID,
                               productID: 0x001A, serialNumber: nil)
        let b = SerialPortInfo(path: "/dev/cu.usbmodem0002", productName: nil, vendorID: SerialPort.unidenVendorID,
                               productID: 0x7FFF, serialNumber: "1")
        #expect(CLIFormat.ports([a, b]) == [
            "/dev/cu.usbmodem0001  Test Scanner  unknown model",
            "/dev/cu.usbmodem0002  Uniden device  unknown model",
        ])
        // 0x001A is listed by two models, so a name that says neither leaves the model unknown.
        #expect(a.knownModel == nil)
        #expect(CLIFormat.ports([]) == ["No Uniden scanner found. Plug the scanner in and choose Serial Port on its screen."])
    }

    /// The SDS100 and the SDS150 share product ID 0x001A; the product name tells them apart.
    @Test func portsFormatLabelsHandheldsByProductName() {
        func port(_ path: String, _ name: String) -> SerialPortInfo {
            SerialPortInfo(path: path, productName: name, vendorID: SerialPort.unidenVendorID,
                           productID: 0x001A, serialNumber: nil)
        }
        #expect(CLIFormat.ports([port("/dev/cu.usbmodem0001", "SDS100 Serial Port"),
                                 port("/dev/cu.usbmodem0002", "SDS150 Serial Port")]) == [
            "/dev/cu.usbmodem0001  SDS100 Serial Port  SDS100",
            "/dev/cu.usbmodem0002  SDS150 Serial Port  SDS150",
        ])
    }

    @Test func statusLines() throws {
        #expect(CLIFormat.status(try gsi()) == [
            "system: LWPC P25-2",
            "department: Unknown",
            "channel: TGID:9",
            "tgid: 9",
            "uid: 7316",
            "site: northside",
            "frequency: 935.4375 MHz",
            "modulation: NFM",
            "tone/code: NAC 2B4h",
            "rssi: -69",
            "signal: 5",
            "muted: no",
        ])
    }

    /// The SDS150's conventional document: the frequency is on `ConvFrequency` (no `SiteFrequency`).
    @Test func statusLinesSDS150Conventional() throws {
        #expect(CLIFormat.status(try sds150GSI()) == [
            "system: County Roads",
            "department: Road Crews",
            "channel: Plow Dispatch",
            "tgid: -",
            "uid: -",
            "site: -",
            "frequency: 155.0125 MHz",
            "modulation: NFM",
            "tone/code: -",
            "rssi: -",
            "signal: 0",
            "muted: yes",
        ])
    }

    @Test func statusDashesForMissingFields() throws {
        let sparse = try ScannerInfo(xml: XMLNode.parse(Data(#"<ScannerInfo Mode="x"/>"#.utf8)))
        #expect(CLIFormat.status(sparse).allSatisfy { $0.hasSuffix(": -") })
        #expect(CLIFormat.status(sparse).count == 12)
        #expect(CLIFormat.status(sparse).suffix(2) == ["signal: -", "muted: -"])
    }

    /// `signal:` is `Sig` as reported; `muted:` is yes only for `Mute="Mute"`.
    @Test func statusSignalAndMuted() throws {
        func lines(_ property: String) throws -> [String] {
            let xml = "<ScannerInfo><Property \(property)/></ScannerInfo>"
            return Array(CLIFormat.status(try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))).suffix(2))
        }
        #expect(try lines(#"Sig="3" Mute="Unmute""#) == ["signal: 3", "muted: no"])
        #expect(try lines(#"Sig="0" Mute="Mute""#) == ["signal: 0", "muted: yes"])
        #expect(try lines(#"Sig="x""#) == ["signal: -", "muted: -"])
    }

    @Test func statusShowsDashForBlankValues() throws {
        let xml = #"<ScannerInfo><System Name=""/><Department Name="  "/><TGID Name="" TGID=" ---"/></ScannerInfo>"#
        let lines = CLIFormat.status(try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8))))
        #expect(lines[0] == "system: -"); #expect(lines[1] == "department: -")
        // " ---" is the idle placeholder, normalized to nil.
        #expect(lines.contains("tgid: -")); #expect(lines.contains("channel: -"))
    }

    @Test func displayLines() throws {
        var a = UDPDatagramAssembler()
        guard case .fields("STS", let f) = a.feed(fixture("sts-trunk-sds200-1.24.00.txt")).first else { Issue.record(); return }
        let lines = CLIFormat.display(try DisplayStatus(fields: f))
        #expect(lines.last == "soft keys: SYSTEM | DEPT | CHANNEL")
        #expect(lines.contains("Lakeview Water & Power Co. P25"))
        #expect(lines.contains("Northside Primary"))
        #expect(lines.contains("UID: ---        RSSI:-101dBm"))
        #expect(lines.allSatisfy { !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespaces) })
        #expect(!lines.dropLast().contains { $0.contains("SYSTEM      DEPT") })
    }

    /// `menu`: the `MSI` screen as the scanner sent it, every item with its own index (an index
    /// the scanner left out shows as a gap), values where it gave them.
    @Test func menuLines() throws {
        func screen(_ xml: String) throws -> MenuScreen { try MenuScreen(xml: XMLNode.parse(Data(xml.utf8))) }
        let list = try screen("""
            <MSI Name="Manage Lists" Index="4293063468" MenuType="TypeSelect" Value="Stale" Selected="2" >
              <MenuItem Name="Stop All Avoiding" Index="1" />
              <MenuItem Name="Information" Index="2" Value="On" />
              <Footer No="1" EOT="1"/>
            </MSI>
            """)
        #expect(CLIFormat.menu(list) == [
            "title: Manage Lists", "menu index: 4293063468", "type: select", "selected: 2", "items: 2",
            "item 1: Stop All Avoiding", "item 2: Information = On",
        ])
        let entry = try screen("""
            <MSI Name="Set Range" Index="4293050176" MenuType="TypeInput" Value="30.0" >
              <MenuInput MaxLength="5" AddedInformation="          (mile)" EnableKeys="0123456789." />
            </MSI>
            """)
        #expect(CLIFormat.menu(entry) == [
            "title: Set Range", "menu index: 4293050176", "type: input", "value: 30.0",
            "max length: 5", "keys: 0123456789.", "added information: (mile)",
        ])
        #expect(CLIFormat.menu(try screen(#"<MSI MenuType="TypeError" ></MSI>"#))
                == ["title: -", "menu index: -", "type: error (no menu screen the protocol describes)"])
        #expect(CLIFormat.menu(try screen(#"<MSI MenuType="TypeError" ><MenuErrorMsg Text="Not Available" /></MSI>"#)).last
                == "error: Not Available")
        #expect(CLIFormat.menu(try screen(#"<MSI Name="Where" MenuType="TypeLocation" ></MSI>"#))[2] == "type: location")
        #expect(CLIFormat.menu(try screen(#"<MSI Name="X" MenuType="TypeOdd" ></MSI>"#))[2] == "type: TypeOdd")
    }

    @Test func watchLine() throws {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        #expect(CLIFormat.watchLine(try gsi(), at: date, timeZone: utc)
            == "22:13:20  LWPC P25-2 / TGID:9  TG 9  UID 7316  935.4375 MHz  RSSI -69")
        let pst = TimeZone(identifier: "America/Los_Angeles")!
        #expect(CLIFormat.watchLine(try gsi(), at: date, timeZone: pst).hasPrefix("14:13:20  "))
    }

    @Test func watchLineSDS150Conventional() throws {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(CLIFormat.watchLine(try sds150GSI(), at: date, timeZone: utc)
            == "22:13:20  County Roads / Plow Dispatch  TG -  UID -  155.0125 MHz  RSSI -")
    }

    @Test func resolveHostPrefersFlags() {
        let r = resolveHost(invocation: CLIInvocation(command: .info, host: "h", port: 7), searchingFrom: URL(filePath: "/"))
        #expect(r?.host == "h" && r?.port == 7)
        let d = resolveHost(invocation: CLIInvocation(command: .info, host: "h"), searchingFrom: URL(filePath: "/"))
        #expect(d?.port == 50536)
    }

    @Test func resolveHostFromConfigAndNone() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "noctule-cli-\(UUID().uuidString)")
        let sub = root.appending(path: "a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let none = resolveHost(invocation: CLIInvocation(command: .info), searchingFrom: sub.standardizedFileURL)
        #expect(none == nil)
        try "SCANNER_HOST=cfg.example.lan\nSCANNER_UDP_PORT=6000\n".write(
            to: root.appending(path: "config/dev-scanner.env"), atomically: true, encoding: .utf8)
        let r = resolveHost(invocation: CLIInvocation(command: .info), searchingFrom: sub.standardizedFileURL)
        #expect(r?.host == "cfg.example.lan" && r?.port == 6000)
        let o = resolveHost(invocation: CLIInvocation(command: .info, port: 9), searchingFrom: sub.standardizedFileURL)
        #expect(o?.host == "cfg.example.lan" && o?.port == 9)
    }
}
