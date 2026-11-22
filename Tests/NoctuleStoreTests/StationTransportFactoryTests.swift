// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
@testable import NoctuleStore

// `StationTransportFactory`: a station's connection to its transport and address. Nothing here
// opens a port or sends anything: `make` only builds the transport. Every USB case passes a fake
// port listing, so the Mac's real serial ports are never looked up (the owner's scanner may be
// one of them).

/// A fixed list of "Uniden ports", in place of the IOKit lookup.
struct FakePorts: SerialPortListing {
    var ports: [SerialPortInfo]

    init(_ ports: [SerialPortInfo]) { self.ports = ports }

    func unidenPorts() -> [SerialPortInfo] { ports }
}

private func port(_ path: String) -> SerialPortInfo {
    SerialPortInfo(path: path, productName: "SDS150 Serial Port", vendorID: SerialPort.unidenVendorID,
                   productID: 0x001A, serialNumber: nil)
}

private func usbStation(port: String?) -> (connection: StationConnection, device: StationDeviceSettings) {
    var connection = StationConnection()
    connection.transport = .usbSerial
    var device = StationDeviceSettings(stationID: UUID())
    device.usbPort = port
    return (connection, device)
}

/// The error `make` throws, or nil when it returns.
private func failure(_ factory: StationTransportFactory, _ connection: StationConnection,
                     _ device: StationDeviceSettings) -> StationTransportError? {
    do {
        _ = try factory.make(connection, device: device)
        return nil
    } catch let error as StationTransportError {
        return error
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

@Suite(.timeLimit(.minutes(3))) struct StationTransportFactoryTests {
    @Test func factoryNetwork() async throws {
        let factory = StationTransportFactory(ports: FakePorts([]))
        var connection = StationConnection()
        connection.host = "192.0.2.10"
        let device = StationDeviceSettings(stationID: UUID())
        let made = try factory.make(connection, device: device)
        #expect(made.transport is UDPTransport)
        #expect(made.address == "192.0.2.10")

        // White space around the host isn't part of the address.
        connection.host = "  192.0.2.10\n"
        #expect(try factory.make(connection, device: device).address == "192.0.2.10")

        connection.host = ""
        #expect(failure(factory, connection, device) == .missingHost)
        connection.host = "   "
        #expect(failure(factory, connection, device) == .missingHost)
        connection.host = nil
        #expect(failure(factory, connection, device) == .missingHost)
    }

    @Test func factoryNetworkUsesTheInjectedTransport() async throws {
        // Ruling B: tests and the app hand their own network transport to the factory.
        let seen = SeenAddress()
        let factory = StationTransportFactory(ports: FakePorts([]), makeNetworkTransport: { host, port in
            seen.set(host, port)
            return UDPTransport(host: host, port: port)
        })
        var connection = StationConnection()
        connection.host = " 192.0.2.10 "
        connection.udpPort = 50999
        _ = try factory.make(connection, device: StationDeviceSettings(stationID: UUID()))
        #expect(seen.host == "192.0.2.10")
        #expect(seen.port == 50999)
    }

    @Test func factoryUSB() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-factory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // An ordinary file stands in for the port: `make` only checks that the path exists.
        let path = dir.appendingPathComponent("port").path
        try Data().write(to: URL(fileURLWithPath: path))

        // The configured path, when it exists (it needn't be a listed port).
        let configured = usbStation(port: path)
        let made = try StationTransportFactory(ports: FakePorts([])).make(configured.connection, device: configured.device)
        let serial = try #require(made.transport as? SerialTransport)
        #expect(await serial.path == path)
        #expect(made.address == path)

        // Nothing configured and no ports.
        let unset = usbStation(port: nil)
        #expect(failure(StationTransportFactory(ports: FakePorts([])), unset.connection, unset.device)
                == .scannerNotFound(hint: SerialPort.noneFoundHint))
        // A configured path that is gone, and no ports.
        let gone = usbStation(port: dir.appendingPathComponent("gone").path)
        #expect(failure(StationTransportFactory(ports: FakePorts([])), gone.connection, gone.device)
                == .scannerNotFound(hint: SerialPort.noneFoundHint))

        // Two ports: none is picked.
        let two = FakePorts([port(dir.appendingPathComponent("a").path), port(dir.appendingPathComponent("b").path)])
        #expect(failure(StationTransportFactory(ports: two), unset.connection, unset.device)
                == .scannerNotFound(hint: SerialPort.severalFoundHint))

        // Nothing configured and one port: that port.
        let only = try StationTransportFactory(ports: FakePorts([port(path)])).make(unset.connection, device: unset.device)
        #expect(await (try #require(only.transport as? SerialTransport)).path == path)
        #expect(only.address == path)

        // `exists` decides whether the configured path counts.
        let never = StationTransportFactory(ports: FakePorts([]), exists: { _ in false })
        #expect(failure(never, configured.connection, configured.device) == .scannerNotFound(hint: SerialPort.noneFoundHint))
    }

    /// Plan 8 D1: a saved port that is gone is `.scannerNotFound` with the none-found hint, even
    /// while another port is listed (it would be whatever scanner is plugged in), and even while
    /// several are; only a station with no saved port takes the listing's one port.
    @Test func savedPortThatIsGoneNeverFallsBack() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-factory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = dir.appendingPathComponent("present").path
        try Data().write(to: URL(fileURLWithPath: present))
        let gone = usbStation(port: dir.appendingPathComponent("gone").path)

        let one = StationTransportFactory(ports: FakePorts([port(present)]))
        #expect(failure(one, gone.connection, gone.device) == .scannerNotFound(hint: SerialPort.noneFoundHint))
        let two = StationTransportFactory(ports: FakePorts([port(present), port(dir.appendingPathComponent("b").path)]))
        #expect(failure(two, gone.connection, gone.device) == .scannerNotFound(hint: SerialPort.noneFoundHint))

        // Nothing saved, or white space: the one listed port; several: none picked.
        for unset in [nil, "  "] as [String?] {
            let station = usbStation(port: unset)
            #expect(try one.make(station.connection, device: station.device).address == present)
            #expect(failure(two, station.connection, station.device) == .scannerNotFound(hint: SerialPort.severalFoundHint))
        }
    }

    /// The listing `StationRunner`'s default factory and `StationSession` pass (the factory's
    /// `ports` has no default): it lists nothing, so a USB station with no port of its own finds
    /// none. (That nothing else is the default is the compiler's to check: `ports` is required.)
    @Test func emptyListingFindsNothing() {
        #expect(FixedSerialPortListing.empty.unidenPorts() == [])
        let listed = port("/dev/noctule-test-port")
        #expect(FixedSerialPortListing(ports: [listed]).unidenPorts() == [listed])
        let unset = usbStation(port: nil)
        #expect(failure(StationTransportFactory(ports: FixedSerialPortListing.empty), unset.connection, unset.device)
                == .scannerNotFound(hint: SerialPort.noneFoundHint))
    }

    @Test func factoryBluetoothIsNotSupported() async throws {
        var connection = StationConnection()
        connection.transport = .bluetooth
        connection.host = "192.0.2.10"
        #expect(failure(StationTransportFactory(ports: FakePorts([])), connection, StationDeviceSettings(stationID: UUID()))
                == .notSupportedOnThisDevice)
    }
}

/// The host and port the injected network transport was asked for.
private final class SeenAddress: Sendable {
    private let value = Mutex<(host: String, port: UInt16)?>(nil)

    func set(_ host: String, _ port: UInt16) { value.withLock { $0 = (host, port) } }
    var host: String? { value.withLock { $0?.host } }
    var port: UInt16? { value.withLock { $0?.port } }
}
