// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import NoctuleKit

extension SessionRegistry {
    /// The audio inputs the sessions may listen to (`SessionEnvironment.audioInputs`), for the
    /// station editor's Audio section: the same kill-switch rules apply (empty under it). Listing
    /// opens nothing.
    public var audioInputs: any AudioInputListing { environment.audioInputs }
}
