// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// The branding switch (Plan 21, `docs/specs/2026-11-20-open-source-prep-design.md` §4.2):
// `scripts/branding.sh` picks the official art (`NOCTULE_BRANDING_DIR`, or `config/branding.env`) or
// the committed placeholder, and `scripts/compile-app-icon.sh` uses it.

private let brandingRoot: URL? = {
    var components = URL(fileURLWithPath: #filePath).standardizedFileURL.pathComponents
    while components.count > 1 {
        components.removeLast()
        let dir = URL(fileURLWithPath: NSString.path(withComponents: components))
        if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) { return dir }
    }
    return nil
}()

/// A solid #FF00FF image `width` x `height` pixels.
private func magentaImage(_ width: Int, _ height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

/// A stub branding folder in `directory`: a copy of the placeholder icon and a two-image TIFF
/// (640x400 and 1280x800, solid #FF00FF) as `dmg/background.tiff`. Shared with the DMG tests.
func stubBrandingFolder(in directory: URL) throws -> URL {
    let folder = directory.appending(path: "stub-branding")
    try FileManager.default.createDirectory(at: folder.appending(path: "dmg"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: try #require(brandingRoot).appending(path: "Resources/Placeholder/AppIcon.icon"),
                                     to: folder.appending(path: "AppIcon.icon"))
    let tiff = folder.appending(path: "dmg/background.tiff")
    let destination = try #require(CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 2, nil))
    for (width, height) in [(640, 400), (1280, 800)] {
        CGImageDestinationAddImage(destination, try magentaImage(width, height), nil)
    }
    try #require(CGImageDestinationFinalize(destination))
    return folder
}

/// The compile script, the switch, `Info.plist` and the placeholder copied into a temporary tree
/// (the script finds its root from its own path), so a `config/branding.env` can be planted.
private struct BrandingTree {
    let root: URL
    let out: URL

    init() throws {
        root = try temporaryDirectory()
        let source = try #require(brandingRoot)
        for path in ["scripts/compile-app-icon.sh", "scripts/branding.sh", "Resources/Info.plist", "Resources/Placeholder"] {
            try FileManager.default.createDirectory(at: root.appending(path: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appending(path: path), to: root.appending(path: path))
        }
        out = root.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func writeConfig(_ text: String) throws {
        try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
        try text.write(to: root.appending(path: "config/branding.env"), atomically: true, encoding: .utf8)
    }

    var icns: URL { out.appending(path: "AppIcon.icns") }

    /// Runs the tree's compile script; `variable` nil leaves `NOCTULE_BRANDING_DIR` out of the environment.
    func compile(variable: String?, from directory: URL? = nil) async throws -> (status: Int32, stdout: String, stderr: String) {
        let script = root.appending(path: "scripts/compile-app-icon.sh")
        let process: Subprocess
        if let variable {
            process = try Subprocess(script, [out.path], environment: ["NOCTULE_BRANDING_DIR": variable],
                                     currentDirectory: directory ?? root)
        } else {
            process = try Subprocess(URL(fileURLWithPath: "/usr/bin/env"), ["-u", "NOCTULE_BRANDING_DIR", script.path, out.path],
                                     currentDirectory: directory ?? root)
        }
        if !(await process.waitForExit(within: 120)) { process.kill() }
        return await process.finish()
    }
}

// One test at a time: each runs tools (IntegrationSupport.swift, "Waiting in these tests").
@Suite(.serialized, .enabled("needs Xcode's actool") { await actoolInstalled.value }, .timeLimit(.minutes(3)))
struct BrandingTests {
    private let placeholderLine = "branding: placeholder (set NOCTULE_BRANDING_DIR for the official art)"

    @Test func emptyVariableMeansPlaceholder() async throws {
        let tree = try BrandingTree()
        defer { tree.cleanUp() }
        let stub = try stubBrandingFolder(in: tree.root)
        try tree.writeConfig("NOCTULE_BRANDING_DIR=\(stub.path)\n")
        let result = try await tree.compile(variable: "")
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(placeholderLine), "stderr: \(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: tree.icns.path))
    }

    @Test func variableNamesTheFolder() async throws {
        let tree = try BrandingTree()
        defer { tree.cleanUp() }
        let stub = try stubBrandingFolder(in: tree.root)
        let result = try await tree.compile(variable: stub.path)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stderr.contains("branding: \(stub.path)"), "stderr: \(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: tree.icns.path))
    }

    @Test func configFileIsReadWhenTheVariableIsUnset() async throws {
        let tree = try BrandingTree()
        defer { tree.cleanUp() }
        let stub = try stubBrandingFolder(in: tree.root)
        try tree.writeConfig("# the official art\nNOCTULE_BRANDING_DIR=\"\(stub.path)\"\n")
        let result = try await tree.compile(variable: nil)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stderr.contains("branding: \(stub.path)"), "stderr: \(result.stderr)")
    }

    @Test func relativeBrandingPathResolvesFromTheRoot() async throws {
        let tree = try BrandingTree()
        defer { tree.cleanUp() }
        let stub = try stubBrandingFolder(in: tree.root)
        try tree.writeConfig("NOCTULE_BRANDING_DIR=stub-branding\n")
        let elsewhere = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let result = try await tree.compile(variable: nil, from: elsewhere)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stderr.contains("branding: \(stub.path)"), "stderr: \(result.stderr)")
    }

    @Test func brandingFolderMissingPartsFails() async throws {
        let tree = try BrandingTree()
        defer { tree.cleanUp() }
        let partial = tree.root.appending(path: "partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tree.root.appending(path: "Resources/Placeholder/AppIcon.icon"),
                                         to: partial.appending(path: "AppIcon.icon"))
        let result = try await tree.compile(variable: partial.path)
        #expect(result.status == 1, "stderr: \(result.stderr)")
        #expect(result.stderr.contains("isn't a branding folder (it needs AppIcon.icon and dmg/background.tiff)"),
                "stderr: \(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: tree.icns.path))
    }

    @Test func configFileIsNotExecuted() async throws {
        let tree = try BrandingTree()
        defer { tree.cleanUp() }
        let marker = tree.root.appending(path: "marker")
        try tree.writeConfig("NOCTULE_BRANDING_DIR=$(touch \(marker.path))\n")
        let result = try await tree.compile(variable: nil)
        #expect(result.status == 1, "the text isn't a folder: \(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// With a `config/branding.env` in the tree (as on the owner's Mac), `runScript` must still get
    /// the placeholder: its default `NOCTULE_BRANDING_DIR=""` is what keeps that file out of tests.
    @Test func runScriptDefaultsToThePlaceholder() async throws {
        let tree = try BrandingTree()
        defer { tree.cleanUp() }
        let stub = try stubBrandingFolder(in: tree.root)
        try tree.writeConfig("NOCTULE_BRANDING_DIR=\(stub.path)\n")
        let result = try await runScript("scripts/compile-app-icon.sh", [tree.out.path], root: tree.root)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(placeholderLine), "stderr: \(result.stderr)")
    }
}

@Suite(.timeLimit(.minutes(1))) struct PlaceholderIconTests {
    private func layer(_ name: String) throws -> String {
        try String(contentsOf: try #require(brandingRoot).appending(path: "Resources/Placeholder/AppIcon.icon/Assets/\(name)"),
                   encoding: .utf8)
    }

    /// "Signal on graphite": a grey squircle, white mark; no night blue, amber or creature.
    @Test func placeholderIconIsCandidateA() throws {
        let background = try layer("00-background.svg").lowercased()
        #expect(background.contains("#8b939b"))
        #expect(background.contains("#5b636b"))
        for forbidden in ["bat", "#f5a83a", "#1d2648"] {
            #expect(!background.contains(forbidden), "background mentions \(forbidden)")
        }
        for name in ["00-background.svg", "01-signal.svg"] {
            #expect(!(try layer(name).lowercased().contains("c2pa")), "\(name) mentions c2pa")
        }
    }
}
