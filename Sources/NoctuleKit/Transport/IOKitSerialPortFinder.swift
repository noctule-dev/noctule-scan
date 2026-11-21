// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import IOKit
import IOKit.serial

/// Lists Uniden serial ports from the IOKit registry. macOS only.
///
/// It matches `IOSerialBSDClient` services, reads each one's `IOCalloutDevice`, and walks up the
/// service plane to the `IOUSBHostDevice` it belongs to for `idVendor`, `idProduct`,
/// `USB Product Name` and `USB Serial Number` (the device, not the interface between: interfaces
/// carry `idVendor` too, but not the names). Only vendor `0x1965` is kept, sorted by path. It
/// reads registry properties only: no device is opened and nothing is sent.
public struct IOKitSerialPortFinder: SerialPortListing {
    public init() {}

    public func unidenPorts() -> [SerialPortInfo] {
        Self.ports(from: Self.registryEntries())
    }

    /// One serial port as the registry describes it, before any filtering.
    struct RegistryEntry {
        var calloutDevice: Any?
        /// The properties of the USB device above the port; nil when it isn't on USB.
        var usbDevice: [String: Any]?
    }

    static let usbDeviceKeys = ["idVendor", "idProduct", "USB Product Name", "USB Serial Number"]

    /// Keeps the Uniden USB ports, sorted by path. An entry without a callout path, vendor ID or
    /// product ID of the expected type is skipped; a missing or mistyped name is nil.
    static func ports(from entries: [RegistryEntry]) -> [SerialPortInfo] {
        entries.compactMap { entry -> SerialPortInfo? in
            guard let path = entry.calloutDevice as? String, let device = entry.usbDevice,
                  let vendorID = (device["idVendor"] as? NSNumber)?.intValue,
                  let productID = (device["idProduct"] as? NSNumber)?.intValue,
                  vendorID == SerialPort.unidenVendorID
            else { return nil }
            return SerialPortInfo(path: path, productName: device["USB Product Name"] as? String,
                                  vendorID: vendorID, productID: productID,
                                  serialNumber: device["USB Serial Number"] as? String)
        }
        .sorted { $0.path < $1.path }
    }

    /// Every `IOSerialBSDClient` in the registry. Releases each object it obtains.
    private static func registryEntries() -> [RegistryEntry] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        // `IOServiceGetMatchingServices` consumes `matching`.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var entries: [RegistryEntry] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var usbDevice: [String: Any]?
            if let device = usbDeviceAbove(service) {
                defer { IOObjectRelease(device) }
                var properties: [String: Any] = [:]
                for key in usbDeviceKeys { properties[key] = property(key, of: device) }
                usbDevice = properties
            }
            entries.append(RegistryEntry(calloutDevice: property(kIOCalloutDeviceKey, of: service), usbDevice: usbDevice))
        }
        return entries
    }

    /// The nearest ancestor of `service` in the service plane that is a USB device, retained (the
    /// caller releases it); nil if there is none.
    private static func usbDeviceAbove(_ service: io_object_t) -> io_registry_entry_t? {
        var entry: io_registry_entry_t = service
        IOObjectRetain(entry)
        while true {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 { return entry }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            entry = parent
        }
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
#endif
