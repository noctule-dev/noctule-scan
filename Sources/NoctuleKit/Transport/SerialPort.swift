// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// A serial port on a Uniden USB device, as the registry describes it (nothing is opened to learn
/// it).
public struct SerialPortInfo: Sendable, Equatable {
    /// The callout device, `/dev/cu.…`.
    public var path: String
    public var productName: String?
    public var vendorID: Int
    public var productID: Int
    /// May be a placeholder shared by every unit (an SDS150's is), so it never tells two apart.
    public var serialNumber: String?

    public init(path: String, productName: String?, vendorID: Int, productID: Int, serialNumber: String?) {
        self.path = path
        self.productName = productName
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }

    /// The model this port is, under Uniden's vendor ID only: the USB product name's first word
    /// through `ScannerModel(reported:)` (`SDS100 Serial Port` is an SDS100; the SDS100 and the
    /// SDS150 share a product ID, so the name is what tells them apart); else the one model whose
    /// `ModelProfile.usbProductIDs` holds the product ID, if exactly one does; else nil, an unknown
    /// model, which is still offered (`MDL` decides once connected).
    public var knownModel: ScannerModel? {
        guard vendorID == SerialPort.unidenVendorID else { return nil }
        if let word = productName?.split(whereSeparator: \.isWhitespace).first,
           let named = ScannerModel(reported: String(word)) {
            return named
        }
        let listing = ScannerModel.allCases.filter { ModelProfile.profile(for: $0).usbProductIDs.contains(productID) }
        return listing.count == 1 ? listing[0] : nil
    }
}

/// Lists the Uniden serial ports present now. `IOKitSerialPortFinder` (macOS) asks the system;
/// `FixedSerialPortListing` lists what it was given, or nothing at all.
public protocol SerialPortListing: Sendable { func unidenPorts() -> [SerialPortInfo] }

/// A listing that never asks the system: always the ports it was given. `empty` is the listing for
/// anything that must not find a scanner by itself (a `StationRunner` built without a factory, a
/// `SessionEnvironment` the app shell hasn't given the system's listing, the CLI with USB
/// detection off).
public struct FixedSerialPortListing: SerialPortListing {
    public let ports: [SerialPortInfo]

    public init(ports: [SerialPortInfo]) { self.ports = ports }

    /// Lists no ports, ever.
    public static let empty = FixedSerialPortListing(ports: [])

    public func unidenPorts() -> [SerialPortInfo] { ports }
}

public enum SerialPortResolution: Sendable, Equatable {
    /// `info` is nil for a configured path that isn't a listed port (a mock pty, a symlink).
    case found(path: String, info: SerialPortInfo?)
    case noneFound
    case severalFound([SerialPortInfo])
}

public enum SerialPort {
    public static let unidenVendorID = 0x1965
    public static let noneFoundHint = "Plug the scanner in and choose Serial Port on its screen."
    public static let severalFoundHint = "More than one Uniden scanner is connected. Choose its port."
    /// A USB station's connection ended while its port is still there (the scanner refused `PSI`,
    /// or the subscription was ended): plugging it in is not the answer.
    public static let notSendingUpdatesHint = "The scanner is connected but isn't sending status updates."

    /// Which port a USB station opens: the configured path if it is set (not empty or white space)
    /// and `exists`. A configured path that doesn't exist is `.noneFound`, whatever `ports` lists:
    /// a saved port never falls back to a detected one (Plan 8 D1), since "the only listed port"
    /// would be whatever scanner is plugged in (on the development Mac, the owner's real one). Only
    /// with nothing configured (nil or blank) is it the only listed port. No port is ever picked
    /// from several.
    public static func resolve(configured: String?, ports: [SerialPortInfo],
                               exists: (String) -> Bool) -> SerialPortResolution {
        if let configured, !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard exists(configured) else { return .noneFound }
            return .found(path: configured, info: ports.first { $0.path == configured })
        }
        switch ports.count {
        case 0: return .noneFound
        case 1: return .found(path: ports[0].path, info: ports[0])
        default: return .severalFound(ports)
        }
    }
}
