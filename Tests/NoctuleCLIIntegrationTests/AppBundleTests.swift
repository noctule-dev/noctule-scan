// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

// What the built app may do (Plan 18 Task 13, line-in design §8): use the Mac's audio input. The
// entitlement and the usage string, and the two places that sign the app with the hardened runtime
// (`scripts/build-app.sh` for the everyday build, `packaging/notarize.sh` for a release; the latter's
// tests are in `PackagingTests`). Nothing here asks for the microphone: the signed fake app is never run.

private func plist(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repositoryFile(path))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

@Suite(.timeLimit(.minutes(1))) struct AppBundleTests {
    @Test func infoPlistHasMicrophoneUsage() throws {
        let info = try plist("Resources/Info.plist")
        #expect(info["NSMicrophoneUsageDescription"] as? String
            == "Noctule Scan records and plays your scanner's audio from the input its headphone jack is connected to.")
    }

    /// The app is unsandboxed, so audio input is the one entitlement it needs.
    @Test func entitlementsAllowAudioInputAndNothingElse() throws {
        let entitlements = try plist("Resources/NoctuleScan.entitlements")
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(entitlements.count == 1, "\(entitlements.keys.sorted())")
    }

    /// The codesign line of `build-app.sh`, run for real (ad hoc) on a fake app: it must carry the hardened
    /// runtime and the entitlement.
    @Test func buildAppSignsWithTheEntitlements() async throws {
        let script = try String(contentsOf: repositoryFile("scripts/build-app.sh"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("codesign ") }.map(String.init))
        #expect(line.contains("--options runtime"), "\(line)")
        #expect(line.contains("--entitlements \"$root/Resources/NoctuleScan.entitlements\""), "\(line)")
        #expect(line.contains("--sign -"), "\(line)")

        let directory = try spacedDirectory()
        let app = directory.appending(path: "Noctule Scan.app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repositoryFile("Resources/Info.plist"), to: app.appending(path: "Contents/Info.plist"))
        let executable = macOS.appending(path: "NoctuleScan")
        // A Mach-O one: codesign has nowhere to put entitlements in a script.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let root = try #require(packagingRoot).path
        let sign = try await run(URL(fileURLWithPath: "/bin/bash"), ["-c", "root=\"$1\"; app=\"$2\"; \(line)", "bash", root, app.path])
        try #require(sign.status == 0, "codesign: \(sign.stderr)")

        let entitlements = try await run(tool("codesign"), ["-d", "--entitlements", "-", app.path])
        #expect((entitlements.stdout + entitlements.stderr).contains("com.apple.security.device.audio-input"),
                "\(entitlements.stdout)\(entitlements.stderr)")
        let details = try await run(tool("codesign"), ["-dv", app.path])
        #expect(details.stderr.contains("runtime"), "codesign -dv: \(details.stderr)")
        #expect(try await run(tool("codesign"), ["--verify", "--strict", app.path]).status == 0)
    }

    @Test func buildAppHeaderNoLongerSaysNoEntitlements() throws {
        let script = try String(contentsOf: repositoryFile("scripts/build-app.sh"), encoding: .utf8)
        #expect(!script.contains("(no entitlements)"))
    }
}
