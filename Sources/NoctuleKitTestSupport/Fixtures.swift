// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Loads a recorded fixture from the bundled `Fixtures` folder.
public func fixture(_ name: String) -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
          let data = try? Data(contentsOf: url)
    else {
        fatalError("Missing fixture: \(name)")
    }
    return data
}
