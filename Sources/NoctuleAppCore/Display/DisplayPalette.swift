// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import NoctuleKit
import NoctuleStore

public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
}

/// Colors for drawing the scanner display. The factory palettes are our own choice, not a copy of
/// any scanner's: `blackOnWhite` and `whiteOnBlack` are exact; `color` is a dark navy screen with
/// pale text and amber highlights, for every model.
public struct DisplayPalette: Equatable, Sendable {
    public var background, text, highlightBackground, highlightText: RGB

    public static func factory(model: ScannerModel, mode: ColorMode) -> DisplayPalette {
        let black = RGB(r: 0, g: 0, b: 0), white = RGB(r: 1, g: 1, b: 1)
        switch mode {
        case .blackOnWhite:
            return DisplayPalette(background: white, text: black, highlightBackground: black, highlightText: white)
        case .whiteOnBlack:
            return DisplayPalette(background: black, text: white, highlightBackground: white, highlightText: black)
        case .color:
            return DisplayPalette(
                background: RGB(r: 0.05, g: 0.08, b: 0.16), text: RGB(r: 0.88, g: 0.92, b: 0.96),
                highlightBackground: RGB(r: 0.95, g: 0.68, b: 0.15), highlightText: RGB(r: 0.05, g: 0.08, b: 0.16))
        }
    }
}
