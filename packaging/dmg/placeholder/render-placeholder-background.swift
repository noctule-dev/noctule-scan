// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors
// Renders the placeholder installer background (Plan 21, Task 2) as a two-resolution TIFF: plain
// light grey, a faint dotted arrow and one line of text. No mark, no wordmark, no font files: the
// text is the system font. The official art is another repository's (NOCTULE_BRANDING_DIR).
//
//   swift packaging/dmg/placeholder/render-placeholder-background.swift <out.tiff>
//
// Geometry is in points with the origin at the top left (the window is 640 x 400 pt); the 2x image is
// the same drawing scaled.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render-placeholder-background: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift render-placeholder-background.swift <out.tiff>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(scale: Int) -> CGImage {
    let w = 640 * scale, h = 400 * scale
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("no bitmap context") }
    context.translateBy(x: 0, y: CGFloat(h))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))  // points, origin top left
    context.setShouldAntialias(true)
    context.setShouldSmoothFonts(false)

    let gradient = CGGradient(colorsSpace: space, colors: [color(0xF6F7F8), color(0xE9EBED)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 400), options: [])

    // The arrow: a dotted line and a chevron.
    context.setStrokeColor(color(0x9AA1A8))
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineDash(phase: 0, lengths: [1, 9])
    context.move(to: CGPoint(x: 250, y: 214))
    context.addLine(to: CGPoint(x: 378, y: 214))
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])
    context.move(to: CGPoint(x: 376, y: 204))
    context.addLine(to: CGPoint(x: 392, y: 214))
    context.addLine(to: CGPoint(x: 376, y: 224))
    context.strokePath()

    // The line of text: the system font, 13 pt, centred, its baseline at y = 352.
    let system = CTFontCreateUIFontForLanguage(.system, 13, nil)!
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): system,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0x7A828A),
    ]
    let text = CTLineCreateWithAttributedString(
        NSAttributedString(string: "Drag the app to Applications to install it.", attributes: attributes))
    let width = CGFloat(CTLineGetTypographicBounds(text, nil, nil, nil))
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // the text is flipped back
    context.textPosition = CGPoint(x: 320 - width / 2, y: 352)
    CTLineDraw(text, context)
    context.restoreGState()

    guard let image = context.makeImage() else { fail("no image") }
    return image
}

let work = FileManager.default.temporaryDirectory.appending(path: "noctule-placeholder-background-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func writePNG(_ image: CGImage, dpi: Double, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("can't write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    if !CGImageDestinationFinalize(destination) { fail("can't write \(url.path)") }
}

let one = work.appending(path: "background.png"), two = work.appending(path: "background@2x.png")
writePNG(render(scale: 1), dpi: 72, to: one)
writePNG(render(scale: 2), dpi: 144, to: two)

try? FileManager.default.removeItem(at: output)
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", one.path, two.path, "-out", output.path]
tiffutil.standardOutput = FileHandle.nullDevice
tiffutil.standardError = FileHandle.nullDevice
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { fail("tiffutil failed (\(tiffutil.terminationStatus))") }
print("background: \(output.path)")
