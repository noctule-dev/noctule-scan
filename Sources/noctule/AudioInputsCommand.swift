// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleCLICore
import NoctuleKit

// `noctule audio-inputs`: lists the audio inputs the system offers (`<UID>  <name>  <n> ch`), or
// `No audio inputs found.`. Opens none: it only reads the device list. With the kill-switch set the
// list is empty (`LineInSupport.listing`).

enum AudioInputsCommand {
    static func run(listing: any AudioInputListing) -> Int32 {
        let inputs = listing.inputs()
        if inputs.isEmpty {
            print(CLIFormat.noAudioInputsLine)
        } else {
            inputs.forEach { print(CLIFormat.audioInputLine($0)) }
        }
        return 0
    }
}
