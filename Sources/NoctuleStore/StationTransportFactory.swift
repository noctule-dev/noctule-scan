// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

public enum StationTransportError: Error, Equatable {
    /// A network station with no host.
    case missingHost
    /// No port for a USB station; `hint` says what to do (`SerialPort.noneFoundHint` or
    /// `severalFoundHint`).
    case scannerNotFound(hint: String)
    /// The connection's transport can't be used here: USB serial on iOS, Bluetooth anywhere.
    case notSupportedOnThisDevice
}

/// Builds the transport for a station's connection: UDP to its host for a network station, the
/// serial port for a USB one (SDS150 design §4.3, §4.5). `make` opens nothing and sends nothing;
/// the transport does that when it is opened.
///
/// **A USB station's port** is `SerialPort.resolve`'s choice: the port in the device settings
/// (`StationDeviceSettings.usbPort`) when it is set, and `.scannerNotFound` with the none-found
/// hint when that port isn't there (a saved port never falls back to a listed one, Plan 8 D1);
/// with no port saved, the only Uniden port `ports` lists, otherwise `.scannerNotFound` with the
/// hint for none or for several. `ports` is required and has no default: with the system's
/// listing (`IOKitSerialPortFinder`) "the only Uniden port" is whatever real scanner is plugged
/// in, so only the `noctule` shell and the app's `AppDelegate` pass that listing, each through
/// `USBDetection`'s rule (`SessionEnvironment.applyingOverrides` in the app, whose `serialPorts`
/// a `StationSession` hands to the factory of a USB station), which honours the kill-switch;
/// `StationRunner`'s default factory and a network station's session pass
/// `FixedSerialPortListing.empty`, and tests their own fake. On iOS there is no serial transport,
/// and a USB station is `.notSupportedOnThisDevice`.
public struct StationTransportFactory: Sendable {
    private let ports: any SerialPortListing
    private let exists: @Sendable (String) -> Bool
    private let makeNetworkTransport: @Sendable (String, UInt16) -> any ScannerTransport
    /// Builds a USB station's transport on its resolved port; nil is `SerialTransport(path:)`.
    private let makeSerialTransport: (@Sendable (String) -> any ScannerTransport)?

    /// - Parameters:
    ///   - ports: lists the Uniden serial ports a USB station with no saved port may use. Never
    ///     defaulted: a caller that hasn't decided passes `FixedSerialPortListing.empty`.
    ///   - exists: whether a configured port path is there now. The default is a `stat` (it
    ///     follows symlinks and never opens the device).
    ///   - makeNetworkTransport: builds a network station's transport from its host (trimmed) and
    ///     UDP port; tests and the app hand in their own.
    public init(ports: any SerialPortListing,
                exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                makeNetworkTransport: @escaping @Sendable (String, UInt16) -> any ScannerTransport = { UDPTransport(host: $0, port: $1) }) {
        self.ports = ports
        self.exists = exists
        self.makeNetworkTransport = makeNetworkTransport
        makeSerialTransport = nil
    }

    /// Tests only: `makeSerialTransport` builds a USB station's transport on the resolved path (a
    /// `SerialTransport` wrapped to fail a write, say), in place of a plain `SerialTransport`.
    init(ports: any SerialPortListing, makeSerialTransport: @escaping @Sendable (String) -> any ScannerTransport) {
        self.ports = ports
        exists = { FileManager.default.fileExists(atPath: $0) }
        makeNetworkTransport = { UDPTransport(host: $0, port: $1) }
        self.makeSerialTransport = makeSerialTransport
    }

    /// The transport, and the address that identifies the scanner (host, or the resolved port path).
    public func make(_ connection: StationConnection, device: StationDeviceSettings) throws
        -> (transport: any ScannerTransport, address: String) {
        switch connection.transport {
        case .network:
            let host = (connection.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { throw StationTransportError.missingHost }
            return (makeNetworkTransport(host, connection.udpPort), host)
        case .usbSerial:
            #if os(macOS)
            switch SerialPort.resolve(configured: device.usbPort, ports: ports.unidenPorts(), exists: exists) {
            case .found(let path, _): return (makeSerialTransport?(path) ?? SerialTransport(path: path), path)
            case .noneFound: throw StationTransportError.scannerNotFound(hint: SerialPort.noneFoundHint)
            case .severalFound: throw StationTransportError.scannerNotFound(hint: SerialPort.severalFoundHint)
            }
            #else
            throw StationTransportError.notSupportedOnThisDevice
            #endif
        case .bluetooth:
            throw StationTransportError.notSupportedOnThisDevice
        }
    }
}
