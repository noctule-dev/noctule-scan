// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

// Fictional ports only. Nothing here opens a path; `finderListsOnlyUniden` reads the IOKit
// registry and must pass with any number of Uniden scanners attached, including none.

private func port(_ path: String, productID: Int = 0x001A, name: String? = "SDS150 Serial Port") -> SerialPortInfo {
    SerialPortInfo(path: path, productName: name, vendorID: SerialPort.unidenVendorID,
                   productID: productID, serialNumber: "TEST0001")
}

private let first = port("/dev/cu.usbmodemA1")
private let second = port("/dev/cu.usbmodemB1")

@Suite struct SerialPortTests {
    @Test func configuredAndPresentWins() {
        // A configured path that exists beats one listed port, and two (no `.severalFound`).
        #expect(SerialPort.resolve(configured: "/dev/ttys042", ports: [first], exists: { _ in true })
            == .found(path: "/dev/ttys042", info: nil))
        #expect(SerialPort.resolve(configured: "/dev/ttys042", ports: [first, second], exists: { _ in true })
            == .found(path: "/dev/ttys042", info: nil))
        // A configured path that is a listed port comes with that port's info.
        #expect(SerialPort.resolve(configured: second.path, ports: [first, second], exists: { _ in true })
            == .found(path: second.path, info: second))
        // `exists` is asked about the configured path itself.
        let asked = SerialPort.resolve(configured: "/dev/ttys042", ports: [first],
                                       exists: { $0 == "/dev/ttys042" })
        #expect(asked == .found(path: "/dev/ttys042", info: nil))
    }

    /// Plan 8 D1: a saved port that is gone is not found, whatever is listed. Falling back to "the
    /// only listed port" would open whatever scanner is plugged in (on the development Mac, the
    /// owner's real SDS150) for a station that saved another one. Only nil or blank falls back.
    @Test func savedPortNeverFallsBack() {
        #expect(SerialPort.resolve(configured: "/dev/cu.gone", ports: [first], exists: { _ in false })
            == .noneFound)
        #expect(SerialPort.resolve(configured: "/dev/cu.gone", ports: [], exists: { _ in false })
            == .noneFound)
        #expect(SerialPort.resolve(configured: "/dev/cu.gone", ports: [first, second], exists: { _ in false })
            == .noneFound)
        // Even when the gone path is itself a listed port (the listing and `exists` disagree).
        #expect(SerialPort.resolve(configured: first.path, ports: [first], exists: { _ in false })
            == .noneFound)
        // Nothing saved (nil or blank): the only listed port, and none from several.
        for unset in [nil, "  "] as [String?] {
            #expect(SerialPort.resolve(configured: unset, ports: [first], exists: { _ in false })
                == .found(path: first.path, info: first), "\(String(describing: unset))")
            #expect(SerialPort.resolve(configured: unset, ports: [first, second], exists: { _ in false })
                == .severalFound([first, second]), "\(String(describing: unset))")
        }
    }

    @Test func onlyPort() {
        #expect(SerialPort.resolve(configured: nil, ports: [first], exists: { _ in true })
            == .found(path: first.path, info: first))
        // An empty or white-space path is not configured, whatever `exists` says.
        for blank in ["", "   ", "\t\n"] {
            #expect(SerialPort.resolve(configured: blank, ports: [first], exists: { _ in true })
                == .found(path: first.path, info: first), "\(blank.debugDescription)")
        }
    }

    @Test func noneFound() {
        #expect(SerialPort.resolve(configured: nil, ports: [], exists: { _ in true }) == .noneFound)
        #expect(SerialPort.resolve(configured: " ", ports: [], exists: { _ in true }) == .noneFound)
    }

    /// Review Focus 5: two scanners and no port chosen pick nothing.
    @Test func severalFoundPicksNothing() {
        #expect(SerialPort.resolve(configured: nil, ports: [first, second], exists: { _ in true })
            == .severalFound([first, second]))
        #expect(SerialPort.resolve(configured: nil, ports: [second, first], exists: { _ in true })
            == .severalFound([second, first]))
    }

    @Test func knownModel() {
        let path = "/dev/cu.usbmodemA1"
        // The product name wins: the SDS100 and the SDS150 share product ID 0x001A.
        #expect(port(path, name: "SDS100 Serial Port").knownModel == .sds100)
        #expect(port(path, name: "SDS150 Serial Port").knownModel == .sds150)
        #expect(port(path, productID: 0x9999, name: "SDS200 Serial Port").knownModel == .sds200)
        // With no name, the product ID names a model only when exactly one model lists it.
        // Two models list 0x001A (the SDS100 and the SDS150), so the ID alone names neither.
        #expect(port(path, name: nil).knownModel == nil)
        #expect(port(path, productID: 0x001A, name: nil).knownModel == nil)
        #expect(port(path, productID: 0x9999, name: nil).knownModel == nil)
        #expect(port(path, productID: 0x9999, name: "Uniden device").knownModel == nil)
        // A name that gives no model falls back to the product ID.
        #expect(port(path, name: "Uniden device").knownModel == nil)
        #expect(port(path, productID: 0x001A, name: "Serial Port").knownModel == nil)
        // A model's name reads through `ScannerModel(reported:)`: first word, any case.
        #expect(port(path, productID: 0x9999, name: "sds100 serial port").knownModel == .sds100)
        // A name or a product ID means a model only under Uniden's vendor ID.
        for name in ["SDS100 Serial Port", "SDS150 Serial Port", nil] {
            var other = port(path, name: name)
            other.vendorID = 0x05AC
            #expect(other.knownModel == nil, "\(name ?? "nil")")
        }
        // The ambiguity is real in the profiles, and a name decides between the two models.
        #expect(ModelProfile.profile(for: .sds100).usbProductIDs.contains(0x001A))
        #expect(ModelProfile.profile(for: .sds150).usbProductIDs.contains(0x001A))
        #expect(port(path, productID: 0x001A, name: "SDS100 Serial Port").knownModel == .sds100)
        #expect(port(path, productID: 0x001A, name: "SDS150 Serial Port").knownModel == .sds150)
    }

    @Test func hints() {
        #expect(SerialPort.unidenVendorID == 0x1965)
        #expect(SerialPort.noneFoundHint == "Plug the scanner in and choose Serial Port on its screen.")
        #expect(SerialPort.severalFoundHint == "More than one Uniden scanner is connected. Choose its port.")
    }

    #if os(macOS)
    @Test func finderListsOnlyUniden() {
        let ports = IOKitSerialPortFinder().unidenPorts()
        for port in ports {
            #expect(port.vendorID == 0x1965)
            #expect(port.path.hasPrefix("/dev/cu."))
        }
    }

    @Test func finderKeepsOnlyUnidenUSBPorts() {
        typealias Entry = IOKitSerialPortFinder.RegistryEntry
        let entries = [
            Entry(calloutDevice: "/dev/cu.usbmodemA1" as NSString,
                  usbDevice: ["idVendor": NSNumber(value: 0x1965), "idProduct": NSNumber(value: 0x001A),
                              "USB Product Name": "SDS150 Serial Port" as NSString,
                              "USB Serial Number": "TEST0001" as NSString]),
            // Another vendor's USB serial adapter.
            Entry(calloutDevice: "/dev/cu.usbserial-X1" as NSString,
                  usbDevice: ["idVendor": NSNumber(value: 0x0403), "idProduct": NSNumber(value: 0x6001)]),
            // A port not on USB (Bluetooth, built in).
            Entry(calloutDevice: "/dev/cu.Bluetooth-Incoming-Port" as NSString, usbDevice: nil),
        ]
        #expect(IOKitSerialPortFinder.ports(from: entries) == [
            SerialPortInfo(path: "/dev/cu.usbmodemA1", productName: "SDS150 Serial Port", vendorID: 0x1965,
                           productID: 0x001A, serialNumber: "TEST0001"),
        ])
    }

    @Test func finderSkipsWhatItCantRead() {
        typealias Entry = IOKitSerialPortFinder.RegistryEntry
        let uniden: [String: Any] = ["idVendor": NSNumber(value: 0x1965), "idProduct": NSNumber(value: 0x0042)]
        var noProduct = uniden
        noProduct["idProduct"] = nil
        var textVendor = uniden
        textVendor["idVendor"] = "6501" as NSString
        let entries = [
            Entry(calloutDevice: nil, usbDevice: uniden),
            Entry(calloutDevice: NSNumber(value: 1), usbDevice: uniden),
            Entry(calloutDevice: "/dev/cu.usbmodemC1" as NSString, usbDevice: noProduct),
            Entry(calloutDevice: "/dev/cu.usbmodemD1" as NSString, usbDevice: textVendor),
            // Optional names missing or of the wrong type: still a port, without them.
            Entry(calloutDevice: "/dev/cu.usbmodemE1" as NSString,
                  usbDevice: uniden.merging(["USB Product Name": NSNumber(value: 7)]) { $1 }),
        ]
        #expect(IOKitSerialPortFinder.ports(from: entries) == [
            SerialPortInfo(path: "/dev/cu.usbmodemE1", productName: nil, vendorID: 0x1965, productID: 0x0042,
                           serialNumber: nil),
        ])
    }

    @Test func finderSortsByPath() {
        typealias Entry = IOKitSerialPortFinder.RegistryEntry
        let device: [String: Any] = ["idVendor": NSNumber(value: 0x1965), "idProduct": NSNumber(value: 0x001A)]
        let paths = IOKitSerialPortFinder.ports(from: [
            Entry(calloutDevice: "/dev/cu.usbmodemB1" as NSString, usbDevice: device),
            Entry(calloutDevice: "/dev/cu.usbmodemA1" as NSString, usbDevice: device),
        ]).map(\.path)
        #expect(paths == ["/dev/cu.usbmodemA1", "/dev/cu.usbmodemB1"])
    }
    #endif
}
