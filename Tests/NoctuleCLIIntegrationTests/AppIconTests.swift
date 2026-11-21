// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

// The app icon's build (Plan 10, `docs/specs/2026-11-13-app-icon-design.md`; the official art moved
// out of this repo in Plan 21): `scripts/compile-app-icon.sh` compiled with `actool` from the
// placeholder icon in `Resources/Placeholder/AppIcon.icon`, and `build-app.sh` ordering.

/// The repository root: the nearest directory above this file that holds `Package.swift`.
private let iconRoot: URL? = {
    var components = URL(fileURLWithPath: #filePath).standardizedFileURL.pathComponents
    while components.count > 1 {
        components.removeLast()
        let dir = URL(fileURLWithPath: NSString.path(withComponents: components))
        if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) { return dir }
    }
    return nil
}()

/// Whether Xcode's `actool` is installed (a Command Line Tools-only Mac has no `actool`).
private let actoolAvailable: Bool = {
    guard let finder = try? Subprocess(URL(fileURLWithPath: "/usr/bin/xcrun"), ["--find", "actool"]) else { return false }
    _ = waitFor(30) { !finder.process.isRunning }
    return finder.finish().status == 0
}()

/// Runs `scripts/compile-app-icon.sh` with `arguments`, from a temporary directory, waiting up to
/// 120 s (a cold `actool` can take longer than `Subprocess.finish()`'s 10 s).
private func compileIcon(_ arguments: [String], in directory: URL) throws -> (status: Int32, stdout: String, stderr: String) {
    let script = try #require(iconRoot).appending(path: "scripts/compile-app-icon.sh")
    // The owner's config/branding.env must never reach a test: no folder named means the placeholder.
    let compile = try Subprocess(script, arguments, environment: ["NOCTULE_BRANDING_DIR": ""], currentDirectory: directory)
    if !waitFor(120, { !compile.process.isRunning }) { compile.kill() }
    return compile.finish()
}

private func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
}

@Suite(.enabled(if: actoolAvailable, "needs Xcode's actool"), .timeLimit(.minutes(1)))
struct AppIconCompileTests {
    @Test func compilesIntoIcnsAndAssetCatalog() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try compileIcon([out.path], in: dir)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(fileSize(out.appending(path: "AppIcon.icns")) > 1024)
        #expect(fileSize(out.appending(path: "Assets.car")) > 1024)
    }

    /// A name that doesn't match leaves macOS showing the generic icon, with no error anywhere.
    @Test func infoPlistNamesTheCompiledIcon() throws {
        let plistData = try Data(contentsOf: try #require(iconRoot).appending(path: "Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleIconName"] as? String == "AppIcon")
        let iconFile = try #require(plist["CFBundleIconFile"] as? String)
        #expect(iconFile == "AppIcon")
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try compileIcon([dir.path], in: dir)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "\(iconFile).icns").path))
    }

    /// A broken compile must fail the build, never leave an app without its icon.
    @Test func failsWithoutTheIcon() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try compileIcon([out.path, dir.appending(path: "Missing.icon").path], in: dir)
        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "Assets.car").path))
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "AppIcon.icns").path))
    }

    /// `actool` exits 0 and writes nothing for an icon not named `AppIcon`; the script must not.
    @Test func failsWhenActoolProducesNothing() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = dir.appending(path: "Other.icon")
        try FileManager.default.copyItem(at: try #require(iconRoot).appending(path: "Resources/Placeholder/AppIcon.icon"), to: other)
        let out = dir.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try compileIcon([out.path, other.path], in: dir)
        #expect(result.status != 0)
        #expect(result.stderr.contains("compile-app-icon: "), "stderr: \(result.stderr)")
    }

    /// The script, `Info.plist` and the icon copied into a temporary tree (the script finds its
    /// root from its own path), with that tree's `Info.plist` naming another icon.
    @Test func failsWhenInfoPlistNamesAnotherIcon() throws {
        let root = try #require(iconRoot)
        let tree = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tree) }
        for path in ["scripts/compile-app-icon.sh", "scripts/branding.sh", "Resources/Info.plist", "Resources/Placeholder"] {
            try FileManager.default.createDirectory(at: tree.appending(path: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appending(path: path), to: tree.appending(path: path))
        }
        let plistURL = tree.appending(path: "Resources/Info.plist")
        var plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        plist["CFBundleIconName"] = "Other"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        let out = tree.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let compile = try Subprocess(tree.appending(path: "scripts/compile-app-icon.sh"), [out.path], environment: ["NOCTULE_BRANDING_DIR": ""],
                                   currentDirectory: tree)
        if !waitFor(120, { !compile.process.isRunning }) { compile.kill() }
        let result = compile.finish()
        #expect(result.status != 0)
        #expect(result.stderr.contains(#"Info.plist names icon "Other" but actool produced "AppIcon""#),
                "stderr: \(result.stderr)")
    }
}

@Suite(.timeLimit(.minutes(1))) struct AppIconBuildScriptTests {
    /// The bundle gets its icon only if `build-app.sh` compiles it into `Contents/Resources`, and
    /// before signing (a file added after `codesign` breaks the signature).
    @Test func buildAppCompilesTheIconBeforeSigning() throws {
        let script = try String(contentsOf: try #require(iconRoot).appending(path: "scripts/build-app.sh"), encoding: .utf8)
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let compile = try #require(lines.firstIndex { $0.hasPrefix(#""$root/scripts/compile-app-icon.sh" "$app/Contents/Resources""#) },
                                   "build-app.sh doesn't compile the icon into the bundle")
        let sign = try #require(lines.firstIndex { $0.hasPrefix("codesign ") })
        #expect(compile < sign)
    }
}
