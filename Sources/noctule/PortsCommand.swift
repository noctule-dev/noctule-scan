// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleCLICore
import NoctuleKit
import NoctuleStore

// `noctule ports`: lists the Uniden serial ports found (path, product name, known model), or the
// serial-mode hint when there are none. Opens nothing and sends nothing.

enum PortsCommand {
    /// `ports` is the shell's one listing (`USBDetection`), so the kill-switch applies here too.
    static func run(ports: any SerialPortListing) -> Int32 {
        CLIFormat.ports(ports.unidenPorts()).forEach { print($0) }
        return 0
    }
}
