// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// Which USB serial ports `noctule` and the app may find by itself (SDS150 design §4.3, §13 A, L;
/// Plan 8 D2): one rule for both. In the CLI, everything that looks for ports (`ports`, a bare
/// `--serial`, and the transport factory `log` builds for a USB station) goes through the shell's
/// one process environment: `listing(environment:system:)`, made once, and `resolveSerial(…,
/// environment:)`. The app's `SessionEnvironment.applyingOverrides` builds its listing through
/// `listing(environment:system:)` too, and adds one rule of its own: with a private
/// `NOCTULE_SETTINGS_DIR` it never asks the system's listing.
///
/// **The guarantee:** with `disableKey` set, `noctule` and the app open a serial port only when
/// its path is given on the command line (`--serial PATH`) or saved in the station being run.
public enum USBDetection {
    /// Set to any non-empty value, no USB ports are found anywhere: `ports` lists none, a bare
    /// `--serial` resolves to none found (without reading `SCANNER_SERIAL` from the config file),
    /// and a USB station can only open its own configured port. For runs against the mock while a
    /// real scanner is plugged in (it would be "the only Uniden port" a station with no saved port
    /// uses).
    public static let disableKey = "NOCTULE_NO_USB_DETECTION"
    /// Tests only: colon-separated paths that stand in for the system's listing (each listed as an
    /// SDS150 in serial mode), so a test can show what is done with a detected port without the
    /// system listing ever being asked. The kill-switch still applies on top.
    public static let testPortsKey = "NOCTULE_TEST_SERIAL_PORTS"

    /// True unless `disableKey` is set to a non-empty value.
    public static func isEnabled(_ environment: [String: String]) -> Bool {
        (environment[disableKey] ?? "").isEmpty
    }

    /// The `test override: …` notes the shell (and the app) print to stderr, one per override in
    /// effect: `testPortsKey` when it replaces the system's listing (set, and detection on).
    /// Nothing otherwise: with detection off it changes nothing.
    public static func overrideNotes(_ environment: [String: String]) -> [String] {
        guard isEnabled(environment), let value = environment[testPortsKey], !testPorts(value).isEmpty else { return [] }
        return ["\(testPortsKey)=\(value) (in place of the system's serial port listing)"]
    }

    private static func testPorts(_ value: String) -> [String] {
        value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// The listing to use: none with detection off; else the `testPortsKey` paths when set; else
    /// `system` (IOKit, in the shell). With detection off `system` is never asked.
    public static func listing(environment: [String: String], system: any SerialPortListing) -> any SerialPortListing {
        guard isEnabled(environment) else { return FixedSerialPortListing.empty }
        let test = testPorts(environment[testPortsKey] ?? "")
        guard test.isEmpty else {
            return FixedSerialPortListing(ports: test.map {
                SerialPortInfo(path: $0, productName: "SDS150 Serial Port", vendorID: SerialPort.unidenVendorID,
                               productID: ModelProfile.profile(for: .sds150).usbProductIDs.min() ?? 0, serialNumber: nil)
            })
        }
        return system
    }
}
