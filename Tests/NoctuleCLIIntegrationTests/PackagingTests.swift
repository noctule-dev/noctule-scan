// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import CryptoKit
import Foundation
import ImageIO
import Testing

// Release packaging (Plan 12, `docs/specs/2026-11-13-plan-12-hello-dmg.md`): the bundle's identity
// and the scripts under `packaging/`, run against stub Apple tools so no certificate is needed.

/// The repository root: the nearest directory above this file that holds `Package.swift`.
let packagingRoot: URL? = {
    var components = URL(fileURLWithPath: #filePath).standardizedFileURL.pathComponents
    while components.count > 1 {
        components.removeLast()
        let dir = URL(fileURLWithPath: NSString.path(withComponents: components))
        if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) { return dir }
    }
    return nil
}()

func repositoryFile(_ path: String) throws -> URL {
    try #require(packagingRoot).appending(path: path)
}

@Suite(.timeLimit(.minutes(1))) struct InfoPlistTests {
    @Test func identifierAndDevelopmentVersion() throws {
        let data = try Data(contentsOf: repositoryFile("Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == "app.noctule.scan")
        #expect(plist["CFBundleShortVersionString"] as? String == "0.0.0")
        #expect(plist["CFBundleVersion"] as? String == "0")
    }

    @Test func oldIdentifierIsGone() throws {
        for path in ["AGENTS.md", "LESSONS.md", "Resources/Info.plist"] {
            let text = try String(contentsOf: repositoryFile(path), encoding: .utf8)
            #expect(!text.contains("org.noctulescan"), "\(path) still names the old bundle identifier")
        }
    }
}

// MARK: - Test support

/// A fresh temporary directory with a subdirectory whose name has a space, as a checkout path may.
func spacedDirectory() throws -> URL {
    let url = try temporaryDirectory().appending(path: "with space")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A minimal app bundle: the real `Info.plist` and an executable that does nothing.
private func fakeApp(in directory: URL, name: String = "Noctule Scan.app") throws -> URL {
    let app = directory.appending(path: name)
    let macOS = app.appending(path: "Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: repositoryFile("Resources/Info.plist"),
                                     to: app.appending(path: "Contents/Info.plist"))
    let executable = macOS.appending(path: "NoctuleScan")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    // The image's volume icon is the app's own.
    let resources = app.appending(path: "Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"),
        to: resources.appending(path: "AppIcon.icns"))
    return app
}

// MARK: - Python for make-dmg.sh

/// The version of the Python at `path` ("3.12.4"), or nil if it isn't one.
private func pythonVersion(_ path: String) async -> (major: Int, minor: Int)? {
    guard FileManager.default.isExecutableFile(atPath: path),
          let result = try? await run(URL(fileURLWithPath: path), ["-c", "import sys; print(sys.version_info[0], sys.version_info[1])"]),
          result.status == 0 else { return nil }
    let parts = result.stdout.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return parts.count == 2 ? (parts[0], parts[1]) : nil
}

/// A Python 3.10 or newer to run make-dmg.sh with: `NOCTULE_PYTHON` from this process's environment, else
/// the first new enough of `python3` on `PATH`, Homebrew's, and `/usr/local`'s. The stock `/usr/bin/python3`
/// is 3.9, so a Mac (or runner) without another one fails the tests that build images, with a message.
/// Looked up once, by a task every caller awaits (a lazy global would block its callers' threads
/// while the first one runs the probes).
private let newPython = Task<String?, Never> {
    let environment = ProcessInfo.processInfo.environment
    var candidates: [String] = []
    if let chosen = environment["NOCTULE_PYTHON"], !chosen.isEmpty { candidates.append(chosen) }
    for directory in (environment["PATH"] ?? "").split(separator: ":") { candidates.append("\(directory)/python3") }
    candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
    for path in candidates {
        if let version = await pythonVersion(path), version.major > 3 || (version.major == 3 && version.minor >= 10) { return path }
    }
    return nil
}

/// The environment that lets make-dmg.sh build images: a Python 3.10+, and one virtual environment shared by
/// the whole test run (dmgbuild is installed from PyPI once, not once per test).
private func dmgEnvironment() async throws -> [String: String] {
    guard let python = await newPython.value else {
        throw SkipReason("no Python 3.10 or newer found: install one (brew install python) or set NOCTULE_PYTHON")
    }
    return ["NOCTULE_PYTHON": python, "NOCTULE_DMG_VENV": sharedDMGVenv.path]
}

private struct SkipReason: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private let sharedDMGVenv: URL = {
    let directory = (try? temporaryDirectory()) ?? FileManager.default.temporaryDirectory
    return directory.appending(path: "dmg-venv")
}()

/// Runs a tool or script and waits up to `limit` seconds for it, suspended: a test that waits for
/// a tool never holds a cooperative thread (IntegrationSupport.swift, "Waiting in these tests").
@discardableResult
func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
         currentDirectory: URL? = nil, limit: Double = 120, input: String? = nil) async throws -> (status: Int32, stdout: String, stderr: String) {
    let process = try Subprocess(executable, arguments, environment: environment, currentDirectory: currentDirectory, input: input)
    if !(await process.waitForExit(within: limit)) { process.kill() }
    return await process.finish()
}

/// Runs `<root>/<relativePath>` (a script under `packaging/`) from a temporary directory.
func runScript(_ relativePath: String, _ arguments: [String], environment: [String: String] = [:],
               root: URL? = nil, limit: Double = 120, input: String? = nil) async throws -> (status: Int32, stdout: String, stderr: String) {
    let script = try (root ?? #require(packagingRoot)).appending(path: relativePath)
    // Scripts that make a disk image (make-dmg.sh, and release.sh through it) get the shared Python environment.
    let defaults = (try? await dmgEnvironment()) ?? [:]
    // The owner's config/branding.env must never reach a test: a script runs on the placeholder unless a test says otherwise.
    let base = defaults.merging(["NOCTULE_BRANDING_DIR": ""]) { _, new in new }
    return try await run(script, arguments, environment: base.merging(environment) { _, new in new },
                         currentDirectory: FileManager.default.temporaryDirectory, limit: limit, input: input)
}

func tool(_ name: String) -> URL { URL(fileURLWithPath: "/usr/bin/\(name)") }

/// Mounts `dmg` read-only and out of the Finder's sight, runs `body` with the mount point, and
/// always detaches it.
private func withMountedImage(_ dmg: URL, _ body: (URL) async throws -> Void) async throws {
    let attach = try await run(tool("hdiutil"), ["attach", "-nobrowse", "-readonly", "-plist", dmg.path])
    try #require(attach.status == 0, "hdiutil attach failed: \(attach.stderr)")
    let plist = try PropertyListSerialization.propertyList(from: Data(attach.stdout.utf8), format: nil) as? [String: Any]
    let entities = (plist?["system-entities"] as? [[String: Any]]) ?? []
    let mountPoint = try #require(entities.compactMap { $0["mount-point"] as? String }.first)
    do {
        try await body(URL(fileURLWithPath: mountPoint))
    } catch {
        _ = try? await run(tool("hdiutil"), ["detach", "-force", mountPoint])
        throw error
    }
    _ = try? await run(tool("hdiutil"), ["detach", "-force", mountPoint])
}

private func imageFormat(_ dmg: URL) async throws -> String? {
    let info = try await run(tool("hdiutil"), ["imageinfo", "-plist", dmg.path])
    let plist = try PropertyListSerialization.propertyList(from: Data(info.stdout.utf8), format: nil) as? [String: Any]
    return plist?["Format"] as? String
}

/// Every suite that makes a disk image runs one test at a time, as a release does: once, with
/// several `hdiutil create` at once, `newfs_apfs` hung for good (LESSONS.md 2026-11-13).
@Suite(.serialized, .timeLimit(.minutes(2))) enum DiskImageTests {}

// MARK: - make-dmg.sh

extension DiskImageTests {
    @Suite(.timeLimit(.minutes(2))) struct MakeDMGTests {
        private func makeDMG(_ arguments: [String], _ extra: [String: String] = [:]) async throws
            -> (status: Int32, stdout: String, stderr: String) {
            try await runScript("packaging/dmg/make-dmg.sh", arguments, environment: extra, limit: 600)
        }

        @Test func makesAnImageWithTheAppAndApplications() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let dmg = dir.appending(path: "Noctule Scan 0.1.0.dmg")
            let result = try await makeDMG([app.path, dmg.path])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stdout == "dmg: \(dmg.path)\n")
            #expect(try await imageFormat(dmg) == "UDZO")
            try await withMountedImage(dmg) { volume in
                #expect(volume.lastPathComponent == "Noctule Scan")
                let names = try FileManager.default.contentsOfDirectory(atPath: volume.path).filter { !$0.hasPrefix(".") }
                #expect(names.sorted() == ["Applications", "Noctule Scan.app"])
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: volume.appending(path: "Applications").path)
                        == "/Applications")
                #expect(FileManager.default.isExecutableFile(
                    atPath: volume.appending(path: "Noctule Scan.app/Contents/MacOS/NoctuleScan").path))
                // dmgbuild keeps the background beside the volume's root as .background.tiff (not in a .background folder).
                #expect(FileManager.default.fileExists(atPath: volume.appending(path: ".background.tiff").path))
                #expect(FileManager.default.fileExists(atPath: volume.appending(path: ".VolumeIcon.icns").path))
            }
        }

        @Test func usesThePlaceholderByDefault() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let dmg = dir.appending(path: "placeholder.dmg")
            let result = try await makeDMG([app.path, dmg.path])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stderr.contains("branding: placeholder"), "\(result.stderr)")
            let want = try Data(contentsOf: repositoryFile("packaging/dmg/placeholder/background.tiff"))
            try await withMountedImage(dmg) { volume in
                let got = try Data(contentsOf: volume.appending(path: ".background.tiff"))
                #expect(got == want)
            }
        }

        @Test func usesTheBrandingFolderWhenSet() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let stub = try stubBrandingFolder(in: dir)
            let dmg = dir.appending(path: "branded.dmg")
            let result = try await makeDMG([app.path, dmg.path], ["NOCTULE_BRANDING_DIR": stub.path])
            #expect(result.status == 0, "\(result.stderr)")
            let want = try Data(contentsOf: stub.appending(path: "dmg/background.tiff"))
            try await withMountedImage(dmg) { volume in
                let got = try Data(contentsOf: volume.appending(path: ".background.tiff"))
                #expect(got == want)
            }
        }

        @Test func prepareBuildsOnlyTheEnvironment() async throws {
            let dir = try spacedDirectory()
            let environment = try await dmgEnvironment()
            let venv = try #require(environment["NOCTULE_DMG_VENV"])
            let result = try await makeDMG(["--prepare"])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stdout == "make-dmg: dmgbuild ready in \(venv)\n")
            #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: venv).appending(path: "requirements.sha256").path))
            let found = FileManager.default.enumerator(atPath: dir.deletingLastPathComponent().path)?
                .compactMap { $0 as? String }.filter { $0.hasSuffix(".dmg") } ?? []
            #expect(found.isEmpty, "\(found)")
        }

        @Test func prepareTakesNoOtherArguments() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let dmg = dir.appending(path: "x.dmg")
            for arguments in [["--prepare", app.path], ["--prepare", app.path, dmg.path], ["--prepare", "extra"],
                              [app.path, "--prepare"], ["--prepare", "--prepare"]] {
                let result = try await makeDMG(arguments)
                #expect(result.status == 2, "\(arguments)")
                #expect(!FileManager.default.fileExists(atPath: dmg.path))
            }
        }

        @Test func windowLayoutIsTheDesigns() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let dmg = dir.appending(path: "out.dmg")
            #expect(try await makeDMG([app.path, dmg.path]).status == 0)
            let venvPython = try await dmgEnvironment()["NOCTULE_DMG_VENV"].map { $0 + "/bin/python" }
            let script = """
                import json, sys
                from ds_store import DSStore
                out = {}
                with DSStore.open(sys.argv[1] + '/.DS_Store', 'r') as d:
                    for e in d:
                        v = e.value
                        if isinstance(v, bytes):
                            v = v.decode('ascii') if len(v) == 4 else len(v)
                        elif isinstance(v, dict):
                            v = {k: (len(x) if isinstance(x, bytes) else x) for k, x in v.items()}
                        out[e.filename + ':' + e.code.decode()] = v
                print(json.dumps(out))
                """
            try await withMountedImage(dmg) { volume in
                let read = try await run(URL(fileURLWithPath: #require(venvPython)), ["-c", script, volume.path])
                try #require(read.status == 0, "\(read.stderr)")
                let store = try #require(try JSONSerialization.jsonObject(with: Data(read.stdout.utf8)) as? [String: Any])
                #expect(store["Noctule Scan.app:Iloc"] as? [Int] == [170, 214], "\(store)")
                #expect(store["Applications:Iloc"] as? [Int] == [470, 214], "\(store)")
                let icon = try #require(store[".:icvp"] as? [String: Any])
                #expect(icon["iconSize"] as? Double == 128)
                #expect(icon["textSize"] as? Double == 12)
                #expect(icon["backgroundType"] as? Int == 2, "2 is a picture")
                let window = try #require(store[".:bwsp"] as? [String: Any])
                #expect(window["ShowToolbar"] as? Bool == false)
                #expect(window["ShowStatusBar"] as? Bool == false)
                #expect(window["ShowPathbar"] as? Bool == false)
                #expect(window["ShowSidebar"] as? Bool == false)
                #expect(window["WindowBounds"] as? String == "{{200, 120}, {640, 432}}")
                #expect(store[".:icvl"] as? String == "icnv", "icon view: \(store)")
            }
        }

        /// A release's app is signed and stapled before it goes into the image: the copy must still verify.
        /// (The marker is in Resources: codesign refuses a loose file in Contents.)
        @Test func signedAppSurvivesTheCopy() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let marker = Data("sealed \(UUID().uuidString)\n".utf8)
            try marker.write(to: app.appending(path: "Contents/Resources/marker"))
            let sign = try await run(tool("codesign"), ["--force", "--sign", "-", app.path])
            try #require(sign.status == 0, "codesign: \(sign.stderr)")
            let dmg = dir.appending(path: "out.dmg")
            let result = try await makeDMG([app.path, dmg.path])
            #expect(result.status == 0, "\(result.stderr)")
            try await withMountedImage(dmg) { volume in
                let copy = volume.appending(path: "Noctule Scan.app")
                let verify = try await run(tool("codesign"), ["--verify", "--strict", copy.path])
                #expect(verify.status == 0, "codesign --verify --strict: \(verify.stderr)")
                #expect(try Data(contentsOf: copy.appending(path: "Contents/Resources/marker")) == marker)
            }
        }

        /// dmgbuild runs `ditto` and ignores its exit status, so a copy that failed (here: a file the copy
        /// can't read) must be caught by make-dmg itself: exit 1, a clear message, and no image left behind.
        @Test func aFailedCopyOfTheAppFailsTheBuild() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let marker = app.appending(path: "Contents/Resources/marker")
            try Data("sealed\n".utf8).write(to: marker)
            let sign = try await run(tool("codesign"), ["--force", "--sign", "-", app.path])
            try #require(sign.status == 0, "codesign: \(sign.stderr)")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path) }
            let dmg = dir.appending(path: "out.dmg")
            let result = try await makeDMG([app.path, dmg.path])
            #expect(result.status == 1, "stdout: \(result.stdout) stderr: \(result.stderr)")
            #expect(result.stderr.contains("make-dmg: the app in the image isn't a faithful copy"), "\(result.stderr)")
            #expect(!result.stdout.contains("dmg:"), "\(result.stdout)")
            #expect(!FileManager.default.fileExists(atPath: dmg.path), "a bad image is removed")
        }

        /// make-dmg removes the environment directory when it must rebuild it, so it refuses a directory
        /// that isn't one.
        @Test func refusesToRemoveADirectoryThatIsNotAVenv() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let notVenv = dir.appending(path: "projects")
            try FileManager.default.createDirectory(at: notVenv, withIntermediateDirectories: true)
            let keep = notVenv.appending(path: "keep.txt")
            try "precious".write(to: keep, atomically: true, encoding: .utf8)
            let result = try await makeDMG([app.path, dir.appending(path: "out.dmg").path], ["NOCTULE_DMG_VENV": notVenv.path])
            #expect(result.status == 1, "\(result.stderr)")
            #expect(result.stderr.contains("isn't a virtual environment; not removing it"), "\(result.stderr)")
            #expect(try String(contentsOf: keep, encoding: .utf8) == "precious")
            #expect(try FileManager.default.contentsOfDirectory(atPath: notVenv.path) == ["keep.txt"])
        }

        /// The environment's Python runs isolated: a PYTHONPATH holding a broken `dmgbuild` can't take over.
        @Test func pythonPathCannotBypassTheInstalledPackages() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let fake = dir.appending(path: "fakepath/dmgbuild")
            try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
            try "raise SystemExit('fake dmgbuild was used')\n".write(to: fake.appending(path: "__init__.py"), atomically: true, encoding: .utf8)
            try "raise SystemExit('fake dmgbuild was used')\n".write(to: fake.appending(path: "__main__.py"), atomically: true, encoding: .utf8)
            let dmg = dir.appending(path: "out.dmg")
            let result = try await makeDMG([app.path, dmg.path], ["PYTHONPATH": dir.appending(path: "fakepath").path])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(!result.stderr.contains("fake dmgbuild"), "\(result.stderr)")
            #expect(try await imageFormat(dmg) == "UDZO")
        }

        @Test func aSecondRunReplacesTheImage() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let dmg = dir.appending(path: "Noctule Scan 0.1.0.dmg")
            #expect(try await makeDMG([app.path, dmg.path]).status == 0)
            try "x".write(to: app.appending(path: "Contents/Resources/extra"), atomically: true, encoding: .utf8)
            let second = try await makeDMG([app.path, dmg.path])
            #expect(second.status == 0, "\(second.stderr)")
            try await withMountedImage(dmg) { volume in
                let names = try FileManager.default.contentsOfDirectory(atPath: volume.path).filter { !$0.hasPrefix(".") }
                #expect(names.sorted() == ["Applications", "Noctule Scan.app"])
                #expect(FileManager.default.fileExists(atPath: volume.appending(path: "Noctule Scan.app/Contents/Resources/extra").path))
            }
        }

        @Test func buildFailureIsReported() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let result = try await makeDMG([app.path, dir.appending(path: "missing/out.dmg").path])
            #expect(result.status == 1)
            #expect(result.stderr.contains("make-dmg: dmgbuild failed"), "\(result.stderr)")
        }

        @Test func refusesWhatIsNotAnApp() async throws {
            let dir = try spacedDirectory()
            let plain = dir.appending(path: "Plain")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            let dmg = dir.appending(path: "out.dmg")
            for arguments in [[plain.path, dmg.path], [dir.appending(path: "Missing.app").path, dmg.path], [dmg.path]] {
                let result = try await makeDMG(arguments)
                #expect(result.status == 2, "\(arguments): \(result.stderr)")
                #expect(!FileManager.default.fileExists(atPath: dmg.path))
            }
        }

        @Test func oldPythonIsExplained() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            // A stand-in for the stock 3.9.6 (the machine running the tests may have no such Python).
            let old = dir.appending(path: "python3")
            try "#!/bin/bash\necho 3.9.6\n".write(to: old, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
            let venv = dir.appending(path: "venv")
            let dmg = dir.appending(path: "out.dmg")
            let result = try await makeDMG([app.path, dmg.path], ["NOCTULE_PYTHON": old.path, "NOCTULE_DMG_VENV": venv.path])
            #expect(result.status == 1)
            #expect(result.stderr.contains("make-dmg: needs Python 3.10 or newer (found 3.9.6)"), "\(result.stderr)")
            #expect(result.stderr.contains("brew install python"), "\(result.stderr)")
            #expect(!FileManager.default.fileExists(atPath: dmg.path))
            #expect(!FileManager.default.fileExists(atPath: venv.path))
        }

        @Test func missingPythonIsExplained() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let venv = dir.appending(path: "venv")
            let result = try await makeDMG([app.path, dir.appending(path: "out.dmg").path],
                                     ["NOCTULE_PYTHON": dir.appending(path: "none").path, "NOCTULE_DMG_VENV": venv.path])
            #expect(result.status == 1)
            #expect(result.stderr.contains("make-dmg: needs Python 3.10 or newer (found none"), "\(result.stderr)")
            #expect(!FileManager.default.fileExists(atPath: venv.path))
        }

        /// A probe that fails says why (a pyenv shim for a version that isn't installed prints its own error).
        @Test func failedPythonProbeNamesItsReason() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let shim = dir.appending(path: "python3")
            try "#!/bin/bash\necho \"pyenv: version '3.12.4' is not installed\" >&2\necho 'second line' >&2\nexit 1\n"
                .write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            let venv = dir.appending(path: "venv")
            let dmg = dir.appending(path: "out.dmg")
            let result = try await makeDMG([app.path, dmg.path], ["NOCTULE_PYTHON": shim.path, "NOCTULE_DMG_VENV": venv.path])
            #expect(result.status == 1)
            #expect(result.stderr.contains("make-dmg: needs Python 3.10 or newer"), "\(result.stderr)")
            #expect(result.stderr.contains("pyenv: version '3.12.4' is not installed"), "\(result.stderr)")
            #expect(!result.stderr.contains("second line"), "\(result.stderr)")
            #expect(result.stderr.contains("brew install python"), "\(result.stderr)")
            #expect(!FileManager.default.fileExists(atPath: dmg.path))
            #expect(!FileManager.default.fileExists(atPath: venv.path))
        }

        /// The environment is rebuilt when requirements.txt changed (its recorded hash differs), and when it
        /// can't import dmgbuild. This test has its own environment: it breaks it twice.
        @Test func changedRequirementsRebuildTheEnvironment() async throws {
            let dir = try spacedDirectory()
            let app = try fakeApp(in: dir)
            let venv = dir.appending(path: "venv")
            let extra = ["NOCTULE_DMG_VENV": venv.path]
            let installing = "make-dmg: installing dmgbuild into \(venv.path)"
            let hashFile = venv.appending(path: "requirements.sha256")

            let first = try await makeDMG([app.path, dir.appending(path: "one.dmg").path], extra)
            #expect(first.status == 0, "\(first.stderr)")
            #expect(first.stderr.contains(installing), "\(first.stderr)")
            let recorded = try String(contentsOf: hashFile, encoding: .utf8)
            let wanted = try await run(tool("shasum"), ["-a", "256", repositoryFile("packaging/dmg/requirements.txt").path])
                .stdout.split(separator: " ").first.map(String.init)
            #expect(recorded.trimmingCharacters(in: .whitespacesAndNewlines) == wanted)

            let reuse = try await makeDMG([app.path, dir.appending(path: "two.dmg").path], extra)
            #expect(reuse.status == 0, "\(reuse.stderr)")
            #expect(!reuse.stderr.contains("installing"), "an unchanged environment is reused: \(reuse.stderr)")

            try "0\n".write(to: hashFile, atomically: true, encoding: .utf8)
            let changed = try await makeDMG([app.path, dir.appending(path: "three.dmg").path], extra)
            #expect(changed.status == 0, "\(changed.stderr)")
            #expect(changed.stderr.contains(installing), "\(changed.stderr)")
            #expect(try String(contentsOf: hashFile, encoding: .utf8) == recorded)

            try FileManager.default.removeItem(at: venv.appending(path: "bin/python"))
            let broken = try await makeDMG([app.path, dir.appending(path: "four.dmg").path], extra)
            #expect(broken.status == 0, "\(broken.stderr)")
            #expect(broken.stderr.contains(installing), "\(broken.stderr)")
            #expect(FileManager.default.isExecutableFile(atPath: venv.appending(path: "bin/python").path))
        }

        @Test func requirementsArePinnedByHash() throws {
            let text = try String(contentsOf: repositoryFile("packaging/dmg/requirements.txt"), encoding: .utf8)
            let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
            let expected = [
                "dmgbuild==1.6.7 --hash=sha256:37ee5771c377beb3203d9164aae8046ffed8531c06edf9227f5788b3c599b1bf",
                "ds_store==1.3.3 --hash=sha256:b92a371efbf1b4ccce2a04d1ed13fceacc4736c81ba09cf5aefb74c088160a35",
                "mac_alias==2.2.3 --hash=sha256:7362b521d2132ef92f606a37abfed5fcd849ceb2f28b6f9743e014b02af92f0d",
            ]
            #expect(lines == expected)
            for line in lines {
                #expect(line.wholeMatch(of: /[A-Za-z0-9_.-]+==[0-9.]+ --hash=sha256:[0-9a-f]{64}/) != nil, "\(line)")
            }
        }
    }
}

// MARK: - Stub Apple tools

private let stubHash = "0123456789ABCDEF0123456789ABCDEF01234567"
/// What `security find-certificate -a -Z` prints for a keychain holding the signing certificate alone
/// (printf %b text): its hashes, then its attributes.
private let stubCertificateListing = #"SHA-256 hash: \#(stubHash)\#(stubHash.prefix(24))\nSHA-1 hash: \#(stubHash)\nkeychain: "/k"\n    "labl"<blob>="Developer ID Application: Test Person (TEAM123456)""#

/// Stand-ins for `codesign`, `xcrun`, `spctl`, `security` and `gh`, first on `PATH`. Each appends one
/// line, `<tool> <arguments>`, to the call log; behaviour is chosen by environment variables.
struct StubTools {
    let directory: URL
    let log: URL

    init() throws {
        directory = try spacedDirectory()
        log = directory.appending(path: "calls.log")
        let bin = directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = #"echo "$(basename "$0") $*" >> "$STUB_LOG""#
        let defaultIdentities = #"  1) \#(stubHash) "Developer ID Application: Test Person (TEAM123456)"\n     1 valid identities found"#
        let scripts = [
            "codesign": "\(record)\nexit 0\n",
            // `STUB_PLUTIL_NOOP=1` makes `-replace` do nothing, so a bundle keeps the version it was built with; every
            // other call (and every call without it) goes to the real plutil. `STUB_PLUTIL_NOOP_KEY=<key>` does the same
            // for the `-replace` of that one key only. Not logged.
            "plutil": """
                [[ -n "${STUB_PLUTIL_NOOP:-}" && "$1" == "-replace" ]] && exit 0
                [[ -n "${STUB_PLUTIL_NOOP_KEY:-}" && "$1" == "-replace" && "$2" == "$STUB_PLUTIL_NOOP_KEY" ]] && exit 0
                exec /usr/bin/plutil "$@"

                """,
            // `STUB_SECURITY_FAIL=<subcommand>` makes that subcommand fail. The keychain subcommands the CI
            // keychain uses answer nothing, except the search list, which holds one login keychain, and
            // `find-certificate`, which lists the signing certificate alone unless
            // `STUB_KEYCHAIN_CERTIFICATES` (printf %b text) says what the keychain holds.
            "security": """
                \(record)
                [[ "${STUB_SECURITY_FAIL:-}" == "$1" ]] && exit 1
                case "$1" in
                    find-certificate)
                        certificates='\(stubCertificateListing)'
                        printf '%b\\n' "${STUB_KEYCHAIN_CERTIFICATES-$certificates}"
                        exit 0 ;;
                    list-keychains)
                        [[ "$*" == "list-keychains -d user" ]] && echo '    "/Users/test/Library/Keychains/login.keychain-db"'
                        exit 0 ;;
                    create-keychain|set-keychain-settings|unlock-keychain|import|set-key-partition-list|delete-keychain)
                        exit 0 ;;
                esac
                identities='\(defaultIdentities)'
                printf '%b\\n' "${STUB_IDENTITIES-$identities}"

                """,
            "spctl": """
                \(record)
                # `STUB_SPCTL_FAIL_MATCH=<text>` fails any call whose arguments contain the text.
                [[ -n "${STUB_SPCTL_FAIL_MATCH:-}" && "$*" == *"$STUB_SPCTL_FAIL_MATCH"* ]] && exit 3
                echo "${@: -1}: accepted" >&2
                echo "source=Notarized Developer ID" >&2
                echo "origin=Developer ID Application: Test Person (TEAM123456)" >&2
                exit "${STUB_SPCTL_STATUS:-0}"

                """,
            // `gh release view` answers STUB_GH_VIEW_STATUS (default 1: no such release, said on stderr as `release not found`, or STUB_GH_VIEW_STDERR); `gh release
            // create` checks that each file it is given under build/ exists, then answers STUB_GH_CREATE_STATUS.
            "gh": """
                \(record)
                case "$1 $2" in
                    "release view")
                        # `--json` (cut-release.sh's look at the finished draft) answers the draft when STUB_GH_DRAFT is set.
                        if [[ -n "${STUB_GH_DRAFT:-}" && "$*" == *--json* ]]; then
                            version="${3#v}"
                            echo "{\\"url\\":\\"https://example.invalid/releases/$3\\",\\"assets\\":[{\\"name\\":\\"noctule-scan-$version.dmg\\"},{\\"name\\":\\"noctule-scan-$version.dmg.sha256\\"}]}"
                            exit 0
                        fi
                        status="${STUB_GH_VIEW_STATUS:-1}"
                        [[ "$status" != 0 ]] && echo "${STUB_GH_VIEW_STDERR-release not found}" >&2
                        exit "$status" ;;
                    "run list")
                        # STUB_GH_RUNS is the JSON `gh run list` prints; by default it is one run (4242) whose
                        # headBranch is the highest tag (by version) of the repository it runs in, as the workflow's run has.
                        if [[ -n "${STUB_GH_RUNS+x}" ]]; then echo "$STUB_GH_RUNS"; else
                            echo "[{\\"databaseId\\":4242,\\"headBranch\\":\\"$(git -c versionsort.suffix=- for-each-ref --sort=-v:refname --count=1 --format='%(refname:short)' refs/tags)\\",\\"url\\":\\"https://example.invalid/runs/4242\\"}]"
                        fi
                        exit 0 ;;
                    "run watch")
                        # STUB_GH_WATCH_SLEEP seconds of watching first (exec, so a signal ends the stub itself).
                        [[ -n "${STUB_GH_WATCH_SLEEP:-}" ]] && exec sleep "$STUB_GH_WATCH_SLEEP"
                        exit "${STUB_GH_WATCH_STATUS:-0}" ;;
                    "run view")
                        # `--json status,conclusion` (cut-release.sh's look at how the run stands) answers STUB_GH_RUN_STATUS
                        # and STUB_GH_RUN_CONCLUSION, a completed failure by default; anything else prints STUB_GH_RUN_VIEW.
                        if [[ "$*" == *status,conclusion* ]]; then
                            [[ -n "${STUB_GH_RUN_VIEW_FAILS:-}" ]] && exit 1
                            echo "{\\"status\\":\\"${STUB_GH_RUN_STATUS-completed}\\",\\"conclusion\\":\\"${STUB_GH_RUN_CONCLUSION-failure}\\"}"
                            exit 0
                        fi
                        [[ -n "${STUB_GH_RUN_VIEW:-}" ]] && echo "$STUB_GH_RUN_VIEW"
                        exit 0 ;;
                    "release create")
                        for argument in "${@:3}"; do
                            [[ "$argument" == */build/* && ! -f "$argument" ]] && exit 3
                        done
                        exit "${STUB_GH_CREATE_STATUS:-0}" ;;
                esac
                exit 0

                """,
            // `swift test` as cut-release.sh runs it: records its arguments and NOCTULE_NO_USB_DETECTION, sleeps
            // STUB_SWIFT_SLEEP seconds if set, says how the run went and exits STUB_SWIFT_STATUS (default 0).
            "swift": """
                \(record)
                echo "env NOCTULE_NO_USB_DETECTION=${NOCTULE_NO_USB_DETECTION-unset}" >> "$STUB_LOG"
                # Every variable cut-release.sh drops from the run, as `env NAME=value ...` (`unset` when absent).
                for name in NOCTULE_CI_RUNNER NOCTULE_HARDWARE_TESTS NOCTULE_AUDIO_HARDWARE_TESTS NOCTULE_RESTART_HARDWARE_TEST NOCTULE_SDS150_HARDWARE_TESTS NOCTULE_SDS150_PUSH_TEST NOCTULE_SDS150_KEEPALIVE_TEST; do
                    echo "env $name=${!name-unset}" >> "$STUB_LOG"
                done
                # `STUB_SWIFT_GRANDCHILD=<file>` starts a background `sleep` (as the suite's mock scanners are) and writes its pid there.
                if [[ -n "${STUB_SWIFT_GRANDCHILD:-}" ]]; then sleep 30 & echo $! > "$STUB_SWIFT_GRANDCHILD"; fi
                [[ -n "${STUB_SWIFT_SLEEP:-}" ]] && sleep "$STUB_SWIFT_SLEEP"
                status="${STUB_SWIFT_STATUS:-0}"
                if [[ "$status" == 0 ]]; then echo "Test run with 1 tests passed"; else echo "Test run with 1 tests failed"; fi
                exit "$status"

                """,
            "xcrun": """
                \(record)
                if [[ "$1 $2" == "notarytool submit" ]]; then
                    if [[ -n "${STUB_KEY_COPY:-}" ]]; then
                        while [[ $# -gt 0 ]]; do
                            [[ "$1" == --key ]] && cp "$2" "$STUB_KEY_COPY"
                            shift
                        done
                    fi
                    if [[ -n "${STUB_NOTARY_RAW:-}" ]]; then echo "$STUB_NOTARY_RAW"; exit "${STUB_NOTARY_EXIT:-0}"; fi
                    echo "{\\"id\\":\\"stub-1\\",\\"status\\":\\"${STUB_NOTARY_STATUS:-Accepted}\\"}"
                elif [[ "$1 $2" == "notarytool log" ]]; then
                    echo "stub log for stub-1"
                fi
                exit 0

                """,
        ]
        // `gh` is a Perl wrapper that notes how `gh run watch` was started before bash can touch its signals (bash resets
        // SIGTTOU and SIGTTIN for itself; the real gh is a Go program that keeps them as they were): whether standard input
        // is /dev/null, and whether SIGTTOU and SIGTTIN are ignored, so a terminal setting or read can't stop it in a
        // background process group. It then runs the bash stub, kept as impl/gh so the call log still says `gh`.
        let impl = directory.appending(path: "impl")
        try FileManager.default.createDirectory(at: impl, withIntermediateDirectories: true)
        let wrapper = """
            #!/usr/bin/perl
            if ("$ARGV[0] $ARGV[1]" eq "run watch" && open(my $log, ">>", $ENV{STUB_LOG})) {
                my @in = stat(STDIN); my @null = stat("/dev/null");
                my $stdin = (@in && $in[0] == $null[0] && $in[1] == $null[1]) ? "null" : "other";
                my ($ttou, $ttin) = map { ($SIG{$_} // "") eq "IGNORE" ? "yes" : "no" } qw(TTOU TTIN);
                print $log "watch stdin=$stdin ignores-TTOU=$ttou ignores-TTIN=$ttin\n";
            }
            exec { "/bin/bash" } "gh", "\(impl.path)/gh", @ARGV;

            """
        for (name, body) in scripts {
            let file = (name == "gh" ? impl : bin).appending(path: name)
            try ("#!/bin/bash\n" + body).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let gh = bin.appending(path: "gh")
        try wrapper.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
    }

    var environment: [String: String] {
        ["PATH": directory.appending(path: "bin").path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
         "STUB_LOG": log.path]
    }

    func calls() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

/// Whether `expected` appear in `lines` in order, each as a prefix of some line, other lines allowed between.
func inOrder(_ lines: [String], _ expected: [String]) -> Bool {
    var remaining = expected[...]
    for line in lines where remaining.first.map(line.hasPrefix) == true { remaining.removeFirst() }
    return remaining.isEmpty
}

// MARK: - notarize.sh

extension DiskImageTests {
    @Suite(.timeLimit(.minutes(1))) struct NotarizeTests {
        private let secrets = ["Test Person", "TEAM123456", "0123456789ABCDEF", "KEYID12345", "issuer-0000", "fake.p8"]
        private let apiKey = ["NOCTULE_NOTARY_KEY": "/tmp/fake.p8", "NOCTULE_NOTARY_KEY_ID": "KEYID12345",
                              "NOCTULE_NOTARY_ISSUER": "issuer-0000"]

        private func notarize(_ arguments: [String], _ stubs: StubTools, _ extra: [String: String] = [:]) async throws
            -> (status: Int32, stdout: String, stderr: String) {
            try await runScript("packaging/notarize.sh", arguments, environment: stubs.environment.merging(extra) { _, new in new })
        }

        @Test func checkFindsTheOneIdentity() async throws {
            let stubs = try StubTools()
            let result = try await notarize(["--check"], stubs)
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stdout.contains("notarize: ready (keychain profile)"))
            #expect(stubs.calls() == ["security find-identity -v -p codesigning"])
        }

        @Test func checkWithNoIdentity() async throws {
            let stubs = try StubTools()
            let result = try await notarize(["--check"], stubs, ["STUB_IDENTITIES": "     0 valid identities found"])
            #expect(result.status == 1)
            #expect(result.stderr.contains(
                "notarize: no Developer ID Application certificate in the keychain; see packaging/README.md (one-time setup)"))
        }

        @Test func checkWithTwoIdentities() async throws {
            let stubs = try StubTools()
            let two = #"  1) \#(stubHash) "Developer ID Application: Test Person (TEAM123456)"\n"#
                + #"  2) FEDCBA9876543210FEDCBA9876543210FEDCBA98 "Developer ID Application: Test Person (TEAM123456)"\n"#
                + "     2 valid identities found"
            let result = try await notarize(["--check"], stubs, ["STUB_IDENTITIES": two])
            #expect(result.status == 1)
            #expect(result.stderr.contains("notarize: several Developer ID Application certificates; set "
                + "NOCTULE_SIGNING_IDENTITY to the SHA-1 of the one to use (security find-identity -v -p codesigning)"))
            let chosen = try StubTools()
            let ok = try await notarize(["--check"], chosen, ["STUB_IDENTITIES": two, "NOCTULE_SIGNING_IDENTITY": "ABC"])
            #expect(ok.status == 0, "\(ok.stderr)")
            #expect(!chosen.calls().contains { $0.hasPrefix("security") })
        }

        @Test func partialAPIKeyIsRefused() async throws {
            let stubs = try StubTools()
            let app = try fakeApp(in: stubs.directory)
            for arguments in [["--check"], [app.path]] {
                let result = try await notarize(arguments, stubs, ["NOCTULE_NOTARY_KEY_ID": "KEYID12345"])
                #expect(result.status == 1)
                #expect(result.stderr.contains("notarize: NOCTULE_NOTARY_KEY, NOCTULE_NOTARY_KEY_ID and "
                    + "NOCTULE_NOTARY_ISSUER go together; set all three or none"))
            }
            #expect(!stubs.calls().contains { $0.hasPrefix("xcrun") || $0.hasPrefix("codesign") })
        }

        @Test func appIsSignedNotarizedAndStapled() async throws {
            let stubs = try StubTools()
            let app = try fakeApp(in: stubs.directory)
            let result = try await notarize([app.path], stubs)
            #expect(result.status == 0, "\(result.stderr)")
            let calls = stubs.calls()
            #expect(inOrder(calls, [
                "security find-identity",
                "codesign --force --options runtime --timestamp --entitlements ",
                "codesign --verify --strict \(app.path)",
                "xcrun notarytool submit ",
                "xcrun stapler staple \(app.path)",
            ]), "\(calls)")
            let submit = try #require(calls.first { $0.hasPrefix("xcrun notarytool submit") })
            #expect(submit.contains("Noctule Scan.zip --keychain-profile noctule-notary --wait --timeout 1h --output-format json"))
            #expect(result.stdout.hasSuffix("notarize: Noctule Scan.app: accepted and stapled\n"))
        }

        /// The app gets the hardened runtime and its entitlements (audio input) in one `codesign`; the image gets neither.
        @Test func notarizeSignsWithTheEntitlements() async throws {
            let stubs = try StubTools()
            let app = try fakeApp(in: stubs.directory)
            let result = try await notarize([app.path], stubs)
            #expect(result.status == 0, "\(result.stderr)")
            let signs = stubs.calls().filter { $0.hasPrefix("codesign --force ") }
            #expect(signs.count == 1, "\(signs)")
            let sign = try #require(signs.first)
            #expect(sign.hasPrefix("codesign --force --options runtime --timestamp --entitlements "), "\(sign)")
            #expect(sign.hasSuffix("/Resources/NoctuleScan.entitlements --sign \(stubHash) \(app.path)"), "\(sign)")
        }

        @Test func entitlementsFileMustExistBeforeAnythingIsSigned() async throws {
            let stubs = try StubTools()
            let app = try fakeApp(in: stubs.directory)
            let root = stubs.directory.appending(path: "bare-repo")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: repositoryFile("packaging"), to: root.appending(path: "packaging"))
            let result = try await runScript("packaging/notarize.sh", [app.path], environment: stubs.environment, root: root)
            #expect(result.status == 1)
            #expect(result.stderr.contains("notarize: no entitlements file at "), "\(result.stderr)")
            #expect(!stubs.calls().contains { $0.hasPrefix("codesign") || $0.hasPrefix("xcrun") })
        }

        @Test func dmgIsSignedWithoutRuntime() async throws {
            let stubs = try StubTools()
            let dmg = stubs.directory.appending(path: "Noctule Scan 0.1.0.dmg")
            #expect(try await runScript("packaging/dmg/make-dmg.sh", [fakeApp(in: stubs.directory).path, dmg.path]).status == 0)
            let result = try await notarize([dmg.path], stubs)
            #expect(result.status == 0, "\(result.stderr)")
            let calls = stubs.calls()
            #expect(calls.contains("codesign --force --timestamp --sign \(stubHash) \(dmg.path)"), "\(calls)")
            #expect(!calls.contains { $0.contains("--options") || $0.contains("--entitlements") })
            #expect(calls.contains { $0.hasPrefix("xcrun notarytool submit \(dmg.path) ") })
            #expect(calls.contains("xcrun stapler staple \(dmg.path)"))
        }

        @Test func apiKeyCredentialsAreUsed() async throws {
            let stubs = try StubTools()
            let app = try fakeApp(in: stubs.directory)
            let check = try await notarize(["--check"], stubs, apiKey)
            #expect(check.stdout.contains("notarize: ready (API key)"))
            let result = try await notarize([app.path], stubs, apiKey)
            #expect(result.status == 0, "\(result.stderr)")
            let submit = try #require(stubs.calls().first { $0.hasPrefix("xcrun notarytool submit") })
            #expect(submit.contains("--key /tmp/fake.p8 --key-id KEYID12345 --issuer issuer-0000"))
            #expect(!submit.contains("--keychain-profile"))
        }

        @Test func rejectionPrintsTheLogAndStaplesNothing() async throws {
            let stubs = try StubTools()
            let app = try fakeApp(in: stubs.directory)
            let result = try await notarize([app.path], stubs, ["STUB_NOTARY_STATUS": "Invalid"])
            #expect(result.status == 1)
            let output = result.stdout + result.stderr
            #expect(output.contains("stub log for stub-1"))
            #expect(output.contains("notarize: Noctule Scan.app: Apple answered Invalid; nothing stapled"))
            #expect(!output.contains("accepted and stapled"))
            #expect(stubs.calls().contains { $0.hasPrefix("xcrun notarytool log stub-1") })
            #expect(!stubs.calls().contains { $0.hasPrefix("xcrun stapler") })
        }

        @Test func failedSubmitPrintsApplesMessage() async throws {
        let stubs = try StubTools()
        let app = try fakeApp(in: stubs.directory)
        let raw = #"{"message":"No Keychain password item found for profile: noctule-notary"}"#
        let result = try await notarize([app.path], stubs, ["STUB_NOTARY_RAW": raw, "STUB_NOTARY_EXIT": "69"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("No Keychain password item found for profile: noctule-notary"), "\(result.stderr)")
        #expect(result.stderr.contains("Apple answered nothing usable; nothing stapled"))
        #expect(!stubs.calls().contains { $0.hasPrefix("xcrun notarytool log") || $0.hasPrefix("xcrun stapler") })
    }

    @Test func outputCarriesNoCredentials() async throws {
            let scenarios: [[String: String]] = [[:], apiKey, ["STUB_NOTARY_STATUS": "Invalid"],
                                                 apiKey.merging(["STUB_NOTARY_STATUS": "Invalid"]) { _, new in new }]
            for extra in scenarios {
                let stubs = try StubTools()
                let app = try fakeApp(in: stubs.directory)
                for arguments in [["--check"], [app.path]] {
                    let result = try await notarize(arguments, stubs, extra)
                    let output = result.stdout + result.stderr
                    for secret in secrets { #expect(!output.contains(secret), "\(extra) \(arguments) printed \(secret)") }
                }
            }
        }

        @Test func refusesOtherFiles() async throws {
            let stubs = try StubTools()
            let zip = stubs.directory.appending(path: "Noctule Scan.zip")
            try Data().write(to: zip)
            for arguments in [[zip.path], [stubs.directory.appending(path: "Missing.app").path], []] {
                let result = try await notarize(arguments, stubs)
                #expect(result.status == 2, "\(arguments): \(result.stderr)")
            }
            #expect(!stubs.calls().contains { $0.hasPrefix("codesign") })
        }
    }
}

// MARK: - release.sh

/// A git repository holding a copy of `packaging/`, `Resources/Info.plist` and the entitlements, and a stub
/// `scripts/build-app.sh` that makes `build/Noctule Scan.app` the way the real one lays it out.
func fakeRepository(in directory: URL) async throws -> URL {
    let repo = directory.appending(path: "repo")
    let files = FileManager.default
    try files.createDirectory(at: repo.appending(path: "Resources"), withIntermediateDirectories: true)
    try files.createDirectory(at: repo.appending(path: "scripts"), withIntermediateDirectories: true)
    try files.copyItem(at: repositoryFile("packaging"), to: repo.appending(path: "packaging"))
    try files.copyItem(at: repositoryFile("Resources/Info.plist"), to: repo.appending(path: "Resources/Info.plist"))
    try files.copyItem(at: repositoryFile("Resources/NoctuleScan.entitlements"),
                       to: repo.appending(path: "Resources/NoctuleScan.entitlements"))
    try files.copyItem(at: repositoryFile("scripts/branding.sh"), to: repo.appending(path: "scripts/branding.sh"))
    let build = repo.appending(path: "scripts/build-app.sh")
    try """
        #!/bin/bash
        set -euo pipefail
        root="$(cd "$(dirname "$0")/.." && pwd)"
        echo "build $*" >> "$STUB_LOG"
        echo "env GH_TOKEN=${GH_TOKEN-unset}" >> "$STUB_LOG"
        echo "env NOCTULE_BRANDING_DIR=${NOCTULE_BRANDING_DIR-unset}" >> "$STUB_LOG"
        echo "env NOCTULE_NOTARY_KEY_P8=${NOCTULE_NOTARY_KEY_P8-unset}" >> "$STUB_LOG"
        app="$root/build/Noctule Scan.app"
        rm -rf "$app"
        mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
        cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
        cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns "$app/Contents/Resources/AppIcon.icns"
        printf '#!/bin/sh\\nexit 0\\n' > "$app/Contents/MacOS/NoctuleScan"
        chmod 755 "$app/Contents/MacOS/NoctuleScan"

        """.write(to: build, atomically: true, encoding: .utf8)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: build.path)
    try "build/\n".write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
    for arguments in [["init", "-q", "-b", "main"], ["add", "-A"],
                      ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                       "commit", "-q", "-m", "fixture"],
                      ["update-ref", "refs/remotes/origin/main", "HEAD"]] {
        let git = try await run(tool("git"), ["-C", repo.path] + arguments)
        try #require(git.status == 0, "git \(arguments): \(git.stderr)")
    }
    return repo
}

/// A fake repository that is a clone of a bare `origin` (`origin.git` in `directory`), on `main`, with `tags`
/// (annotated, on the one commit) pushed to it and also present locally, as after a release made from here.
func releaseRepository(in directory: URL, tags: [String]) async throws -> (repo: URL, origin: URL) {
    let repo = try await fakeRepository(in: directory)
    let origin = directory.appending(path: "origin.git")
    let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                    "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"]
    var steps: [[String]] = [["init", "-q", "--bare", "-b", "main", origin.path]]
    steps += [["-C", repo.path, "config", "user.name", "Test"], ["-C", repo.path, "config", "user.email", "test@example.invalid"],
              ["-C", repo.path, "config", "commit.gpgsign", "false"], ["-C", repo.path, "config", "tag.gpgsign", "false"],
              ["-C", repo.path, "remote", "add", "origin", origin.path], ["-C", repo.path, "push", "-q", "origin", "main"]]
    for tag in tags {
        steps.append(["-C", repo.path] + identity + ["tag", "-a", tag, "-m", tag])
        steps.append(["-C", repo.path, "push", "-q", "origin", tag])
    }
    for arguments in steps {
        let git = try await run(tool("git"), arguments)
        try #require(git.status == 0, "git \(arguments): \(git.stderr)")
    }
    return (repo, origin)
}

/// Tags `HEAD` of `repo` (a lightweight tag, as `git tag` makes).
func tagHead(_ repo: URL, _ name: String) async throws {
    let git = try await run(tool("git"), ["-C", repo.path, "tag", name])
    try #require(git.status == 0, "git tag: \(git.stderr)")
}

func porcelain(_ repo: URL) async throws -> String {
    try await run(tool("git"), ["-C", repo.path, "status", "--porcelain"]).stdout
}

private func bundleVersions(_ app: URL) throws -> (short: String?, build: String?) {
    let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    return (plist?["CFBundleShortVersionString"] as? String, plist?["CFBundleVersion"] as? String)
}

extension DiskImageTests {
    @Suite(.timeLimit(.minutes(1))) struct ReleaseTests {
        private func release(_ arguments: [String], _ stubs: StubTools, _ repo: URL, _ extra: [String: String] = [:]) async throws
            -> (status: Int32, stdout: String, stderr: String) {
            // Every run has official (stub) art unless the test says otherwise, as the owner's would.
            let art = stubs.directory.appending(path: "stub-branding")
            if !FileManager.default.fileExists(atPath: art.path) { _ = try stubBrandingFolder(in: stubs.directory) }
            let environment = stubs.environment.merging(["NOCTULE_BRANDING_DIR": art.path]) { _, new in new }
            return try await runScript("packaging/release.sh", arguments,
                                 environment: environment.merging(extra) { _, new in new }, root: repo)
        }

        // MARK: the official art

        /// The release job checks the art out to `branding/` in the work tree; the clean-tree check must not see it.
        @Test func anIgnoredBrandingCheckoutDoesNotDirtyTheTree() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try String(contentsOf: repositoryFile(".gitignore"), encoding: .utf8)
                .write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
            for arguments in [["add", ".gitignore"],
                              ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                               "commit", "-q", "--amend", "--no-edit"]] {
                let git = try await run(tool("git"), ["-C", repo.path] + arguments)
                try #require(git.status == 0, "git \(arguments): \(git.stderr)")
            }
            let art = repo.appending(path: "branding/builds/noctule-scan")
            try FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
            try "x".write(to: art.appending(path: "placeholder.txt"), atomically: true, encoding: .utf8)
            try await tagHead(repo, "v0.2.0")
            let result = try await release(["0.2.0"], stubs, repo)
            #expect(result.status == 0, "\(result.stderr)")
        }

        @Test func releaseWithoutArtIsRefused() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.2.0")
            let result = try await release(["0.2.0"], stubs, repo, ["NOCTULE_BRANDING_DIR": ""])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release: no official art: set NOCTULE_BRANDING_DIR (or config/branding.env) to the design-language repo's builds/noctule-scan folder"), "\(result.stderr)")
            #expect(stubs.calls().isEmpty, "\(stubs.calls())")
        }

        @Test func malformedArtFolderIsRefused() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.2.0")
            let empty = stubs.directory.appending(path: "empty-art")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let result = try await release(["0.2.0"], stubs, repo, ["NOCTULE_BRANDING_DIR": empty.path])
            #expect(result.status == 1)
            #expect(result.stderr.contains("isn't a branding folder"), "\(result.stderr)")
            #expect(stubs.calls().isEmpty, "\(stubs.calls())")
        }

        @Test func untaggedWithoutArtIsMarkedUnbranded() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            let result = try await release(["0.2.0", "--untagged"], stubs, repo, ["NOCTULE_BRANDING_DIR": ""])
            #expect(result.status == 0, "\(result.stderr)")
            let build = repo.appending(path: "build")
            #expect(FileManager.default.fileExists(atPath: build.appending(path: "noctule-scan-0.2.0-untagged-unbranded.dmg").path))
            #expect(!FileManager.default.fileExists(atPath: build.appending(path: "noctule-scan-0.2.0-untagged.dmg").path))
        }

        @Test func artIsPassedToTheBuild() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.2.0")
            let result = try await release(["0.2.0"], stubs, repo)
            #expect(result.status == 0, "\(result.stderr)")
            let art = stubs.directory.appending(path: "stub-branding").resolvingSymlinksInPath().path
            #expect(stubs.calls().contains("env NOCTULE_BRANDING_DIR=\(art)"), "\(stubs.calls())")
        }

        /// A malformed folder is a refusal even with `--untagged`: it must not fall through to an unbranded build.
        @Test func malformedArtFolderIsRefusedEvenUntagged() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            let empty = stubs.directory.appending(path: "empty-art")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let result = try await release(["0.2.0", "--untagged"], stubs, repo, ["NOCTULE_BRANDING_DIR": empty.path])
            #expect(result.status == 1)
            #expect(result.stderr.contains("isn't a branding folder"), "\(result.stderr)")
            #expect(stubs.calls().isEmpty, "\(stubs.calls())")
            let build = repo.appending(path: "build")
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? []).filter { $0.hasSuffix(".dmg") }.isEmpty)
        }

        /// Art named only by `config/branding.env`, with the variable truly unset: release.sh must export it to the build.
        @Test func artFromTheConfigFileReachesTheBuild() async throws {
            let stubs = try StubTools()
            let art = try stubBrandingFolder(in: stubs.directory)
            let repo = try await fakeRepository(in: stubs.directory)
            try FileManager.default.createDirectory(at: repo.appending(path: "config"), withIntermediateDirectories: true)
            try "NOCTULE_BRANDING_DIR=\(art.path)\n".write(to: repo.appending(path: "config/branding.env"),
                                                          atomically: true, encoding: .utf8)
            try await tagHead(repo, "v0.2.0")
            let environment = ((try? await dmgEnvironment()) ?? [:]).merging(stubs.environment) { _, new in new }
            let result = try await run(tool("env"), ["-u", "NOCTULE_BRANDING_DIR", repo.appending(path: "packaging/release.sh").path, "0.2.0",
                                              "--allow-dirty"],
                                 environment: environment, currentDirectory: FileManager.default.temporaryDirectory, limit: 120)
            #expect(result.status == 0, "\(result.stderr)")
            #expect(stubs.calls().contains("env NOCTULE_BRANDING_DIR=\(art.resolvingSymlinksInPath().path)"), "\(stubs.calls())")
        }

        /// The art folder as a git repository with one commit; returns its HEAD.
        private func gitArt(in stubs: StubTools) async throws -> String {
            let art = stubs.directory.appending(path: "stub-branding")
            _ = try stubBrandingFolder(in: stubs.directory)
            for arguments in [["init", "-q", "-b", "main"], ["add", "-A"],
                              ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                               "commit", "-q", "-m", "art"]] {
                let git = try await run(tool("git"), ["-C", art.path] + arguments)
                try #require(git.status == 0, "git \(arguments): \(git.stderr)")
            }
            return try await run(tool("git"), ["-C", art.path, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @Test func releaseWarnsWhenTheArtIsntThePinnedCommit() async throws {
            let stubs = try StubTools()
            let head = try await gitArt(in: stubs)
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.2.0")
            let pinned = String(repeating: "a", count: 40)
            try "\(pinned)\n".write(to: repo.appending(path: "packaging/branding-ref"), atomically: true, encoding: .utf8)
            let result = try await release(["0.2.0", "--allow-dirty"], stubs, repo)
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stderr.contains("release: warning: the art at "), "\(result.stderr)")
            #expect(result.stderr.contains("is \(head), not packaging/branding-ref's \(pinned)"), "\(result.stderr)")
        }

        @Test func noWarningWhenTheArtIsThePinnedCommit() async throws {
            let stubs = try StubTools()
            let head = try await gitArt(in: stubs)
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.2.0")
            try "\(head)\n".write(to: repo.appending(path: "packaging/branding-ref"), atomically: true, encoding: .utf8)
            let result = try await release(["0.2.0", "--allow-dirty"], stubs, repo)
            #expect(result.status == 0, "\(result.stderr)")
            #expect(!result.stderr.contains("warning: the art"), "\(result.stderr)")
        }

        @Test func fullRunStampsSignsAndPackages() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.3.0-beta.1")
            let result = try await release(["0.3.0-beta.1", "--build", "7"], stubs, repo)
            #expect(result.status == 0, "\(result.stderr)")
            let app = repo.appending(path: "build/Noctule Scan.app")
            let dmg = repo.appending(path: "build/noctule-scan-0.3.0-beta.1.dmg")
            let versions = try bundleVersions(app)
            #expect(versions.short == "0.3.0")
            #expect(versions.build == "7")
            #expect(FileManager.default.fileExists(atPath: dmg.path))
            let calls = stubs.calls()
            #expect(inOrder(calls, [
                "security find-identity",
                "build release",
                "codesign --force --options runtime --timestamp --entitlements ",
                "xcrun notarytool submit ",
                "xcrun stapler staple \(app.path)",
                "codesign --force --timestamp --sign \(stubHash) \(dmg.path)",
                "xcrun notarytool submit \(dmg.path) ",
                "xcrun stapler staple \(dmg.path)",
                "spctl --assess --type execute --verbose \(app.path)",
                "spctl --assess --type open --context context:primary-signature --verbose \(dmg.path)",
                "xcrun stapler validate \(app.path)",
                "xcrun stapler validate \(dmg.path)",
                "spctl --assess --type execute --verbose ",
            ]), "\(calls)")
            let shasum = try await run(tool("shasum"), ["-a", "256", dmg.path]).stdout.split(separator: " ").first.map(String.init)
            #expect(result.stdout.contains("release: \(dmg.path)\n"))
            #expect(result.stdout.contains("sha256: \(try #require(shasum))\n"))
            #expect(try await porcelain(repo).isEmpty)
        }

        // MARK: the version comes from a tag

        private static let untaggedMessage =
            "release: HEAD isn't tagged v%@; cut releases with packaging/cut-release.sh (or pass --untagged to try a release locally)"

        @Test func untaggedHeadIsRefused() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            let result = try await release(["0.2.0"], stubs, repo)
            #expect(result.status == 1)
            #expect(result.stderr.contains(String(format: Self.untaggedMessage, "0.2.0")), "\(result.stderr)")
            #expect(stubs.calls().isEmpty, "\(stubs.calls())")
        }

        @Test func wrongTagIsRefused() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.1.9")
            let result = try await release(["0.2.0"], stubs, repo)
            #expect(result.status == 1)
            #expect(result.stderr.contains(String(format: Self.untaggedMessage, "0.2.0")), "\(result.stderr)")
            #expect(!stubs.calls().contains { $0.hasPrefix("build") })
        }

        /// The tag is the full version given: `v0.1.1`, or another beta's, doesn't release `0.1.1-beta.2`.
        @Test func betaVersionNeedsItsOwnTag() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.1.1")
            try await tagHead(repo, "v0.1.1-beta.1")
            let refused = try await release(["0.1.1-beta.2"], stubs, repo)
            #expect(refused.status == 1)
            #expect(refused.stderr.contains(String(format: Self.untaggedMessage, "0.1.1-beta.2")), "\(refused.stderr)")
            #expect(stubs.calls().isEmpty, "\(stubs.calls())")
            // And the reverse: a longer tag on HEAD doesn't release the shorter version.
            let longer = try await fakeRepository(in: stubs.directory.appending(path: "longer"))
            try await tagHead(longer, "v0.1.1-beta.2")
            let refusedShort = try await release(["0.1.1"], stubs, longer)
            #expect(refusedShort.status == 1)
            #expect(refusedShort.stderr.contains(String(format: Self.untaggedMessage, "0.1.1")), "\(refusedShort.stderr)")
            #expect(stubs.calls().isEmpty, "\(stubs.calls())")
            try await tagHead(repo, "v0.1.1-beta.2")
            let allowed = try await release(["0.1.1-beta.2", "--build", "3"], stubs, repo)
            #expect(allowed.status == 0, "\(allowed.stderr)")
            #expect(FileManager.default.fileExists(atPath: repo.appending(path: "build/noctule-scan-0.1.1-beta.2.dmg").path))
            #expect(try bundleVersions(repo.appending(path: "build/Noctule Scan.app")).short == "0.1.1")
        }

        @Test func untaggedFlagMarksTheDMG() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            let result = try await release(["0.2.0", "--untagged"], stubs, repo)
            #expect(result.status == 0, "\(result.stderr)")
            let build = repo.appending(path: "build")
            #expect(FileManager.default.fileExists(atPath: build.appending(path: "noctule-scan-0.2.0-untagged.dmg").path))
            #expect(!FileManager.default.fileExists(atPath: build.appending(path: "noctule-scan-0.2.0.dmg").path))
            #expect(result.stdout.contains("release: \(build.path)/noctule-scan-0.2.0-untagged.dmg\n"), "\(result.stdout)")
        }

        @Test func versionInsideTheDMGIsChecked() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.2.0")
            let result = try await release(["0.2.0", "--build", "12"], stubs, repo)
            #expect(result.status == 0, "\(result.stderr)")
            let dmg = repo.appending(path: "build/noctule-scan-0.2.0.dmg")
            try await withMountedImage(dmg) { mount in
                let versions = try bundleVersions(mount.appending(path: "Noctule Scan.app"))
                #expect(versions.short == "0.2.0")
                #expect(versions.build == "12")
            }
        }

        @Test func wrongBuildInsideTheDMGFails() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.2.0")
            let result = try await release(["0.2.0", "--build", "12"], stubs, repo, ["STUB_PLUTIL_NOOP_KEY": "CFBundleVersion"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release: the app in the DMG says 0.2.0 (build 0), expected 0.2.0 (build 12)"), "\(result.stderr)")
            #expect(!result.stdout.contains("release: /"))
            #expect(!result.stdout.contains("sha256:"))
            #expect(try await attachedImages(under: stubs.directory) == false)
        }

        @Test func wrongVersionInsideTheDMGFails() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.2.0")
            let result = try await release(["0.2.0", "--build", "12"], stubs, repo, ["STUB_PLUTIL_NOOP": "1"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release: the app in the DMG says 0.0.0 (build 0), expected 0.2.0 (build 12)"), "\(result.stderr)")
            #expect(!result.stdout.contains("release: /"))
            #expect(!result.stdout.contains("sha256:"))
            #expect(try await attachedImages(under: stubs.directory) == false)
        }

        /// Whether `hdiutil info` lists an image under `directory`.
        private func attachedImages(under directory: URL) async throws -> Bool {
            try await run(tool("hdiutil"), ["info"]).stdout.contains(directory.lastPathComponent)
        }

        @Test func releaseChecksTheAppInsideTheDMG() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.1.0")
            let tmp = stubs.directory.appending(path: "tmp")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let result = try await release(["0.1.0"], stubs, repo, ["TMPDIR": tmp.path])
            #expect(result.status == 0, "\(result.stderr)")
            let leftover = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
            #expect(leftover.filter { $0.hasPrefix("noctule-release-check.") }.isEmpty, "\(leftover)")
            let calls = stubs.calls()
            let dmg = repo.appending(path: "build/noctule-scan-0.1.0.dmg")
            let prefix = "spctl --assess --type execute --verbose "
            let inside = calls.filter { $0.hasPrefix(prefix) && $0.hasSuffix("/Noctule Scan.app") }
                .filter { !$0.contains(repo.appending(path: "build").path) }
            #expect(inside.count == 1, "\(calls)")
            #expect(inOrder(calls, ["xcrun stapler validate \(dmg.path)", inside.first ?? "?"]), "\(calls)")
            #expect(try await attachedImages(under: stubs.directory) == false)
        }

        @Test func failedCheckInsideTheDMGDetaches() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.1.0")
            let result = try await release(["0.1.0"], stubs, repo, ["STUB_SPCTL_FAIL_MATCH": "noctule-release-check"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release: Gatekeeper (app in the DMG) check failed"), "\(result.stderr)")
            #expect(!result.stdout.contains("release: /"))
            #expect(!result.stdout.contains("sha256:"))
            #expect(try await attachedImages(under: stubs.directory) == false)
        }

        @Test func defaultBuildNumberIsZero() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.1.0")
            let result = try await release(["0.1.0"], stubs, repo)
            #expect(result.status == 0, "\(result.stderr)")
            #expect(try bundleVersions(repo.appending(path: "build/Noctule Scan.app")).build == "0")
            #expect(FileManager.default.fileExists(atPath: repo.appending(path: "build/noctule-scan-0.1.0.dmg").path))
        }

        @Test func badVersionsBuildNothing() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            let cases: [([String], String)] = [
                (["v0.1.0"], "release: give the version without the v (0.1.0, not v0.1.0)"),
                (["0.1"], "release: 0.1 isn't a version (1.2.3 or 1.2.3-beta.1)"),
                (["1.2.3+meta"], "release: 1.2.3+meta isn't a version (1.2.3 or 1.2.3-beta.1)"),
                (["01.2.3"], "release: 01.2.3 isn't a version (1.2.3 or 1.2.3-beta.1)"),
                (["0.1.0", "--build", "x"], "release: --build takes a whole number"),
                ([], "usage:"),
            ]
            for (arguments, message) in cases {
                let result = try await release(arguments, stubs, repo)
                #expect(result.status == 2, "\(arguments)")
                #expect(result.stderr.contains(message), "\(arguments): \(result.stderr)")
            }
            #expect(stubs.calls().isEmpty, "\(stubs.calls())")
        }

        @Test func dirtyTreeIsRefused() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.1.0")
            try "x".write(to: repo.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)
            let refused = try await release(["0.1.0"], stubs, repo)
            #expect(refused.status == 1)
            #expect(refused.stderr.contains(
                "release: the working tree has changes; commit them, or pass --allow-dirty to try a release locally"))
            #expect(!stubs.calls().contains { $0.hasPrefix("build") })
            let allowed = try await release(["0.1.0", "--allow-dirty"], stubs, repo)
            #expect(allowed.status == 0, "\(allowed.stderr)")
        }

        @Test func missingCertificateStopsBeforeTheBuild() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.1.0")
            let result = try await release(["0.1.0"], stubs, repo, ["STUB_IDENTITIES": "     0 valid identities found"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("no Developer ID Application certificate"))
            #expect(!stubs.calls().contains { $0.hasPrefix("build") })
        }

        @Test func rejectedAppStopsTheRun() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.1.0")
            let result = try await release(["0.1.0"], stubs, repo, ["STUB_NOTARY_STATUS": "Invalid"])
            #expect(result.status == 1)
            #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "build/noctule-scan-0.1.0.dmg").path))
            #expect(!result.stdout.contains("sha256:"))
            #expect(try await porcelain(repo).isEmpty)
        }

        @Test func gatekeeperOutputCarriesNoIdentity() async throws {
        let stubs = try StubTools()
        let repo = try await fakeRepository(in: stubs.directory)
        try await tagHead(repo, "v0.1.0")
        for extra in [[:], ["STUB_SPCTL_STATUS": "3"]] {
            let result = try await release(["0.1.0"], stubs, repo, extra)
            let output = result.stdout + result.stderr
            #expect(output.contains("source=Notarized Developer ID"), "\(extra)")
            #expect(!output.contains("Test Person") && !output.contains("TEAM123456"), "\(extra): \(output)")
        }
    }

    @Test func failedGatekeeperCheckFailsTheRun() async throws {
            let stubs = try StubTools()
            let repo = try await fakeRepository(in: stubs.directory)
            try await tagHead(repo, "v0.1.0")
            let result = try await release(["0.1.0"], stubs, repo, ["STUB_SPCTL_STATUS": "3"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("check failed"))
            #expect(!result.stdout.contains("sha256:"))
        }
    }
}

// MARK: - release-from-tag.sh

extension DiskImageTests {
    @Suite(.timeLimit(.minutes(1))) struct ReleaseFromTagTests {
        private static let keyText = "-----BEGIN PRIVATE KEY-----\nfake-key-body\n-----END PRIVATE KEY-----\n"
        private static let keyBase64 = Data(keyText.utf8).base64EncodedString()
        private typealias Result = (status: Int32, stdout: String, stderr: String)

        private struct Rig {
            let stubs: StubTools
            let repo: URL
            let runnerTemp: URL
            let keyCopy: URL
            let art: URL

            init() async throws {
                stubs = try StubTools()
                repo = try await fakeRepository(in: stubs.directory)
                runnerTemp = stubs.directory.appending(path: "runner temp")
                try FileManager.default.createDirectory(at: runnerTemp, withIntermediateDirectories: true)
                keyCopy = stubs.directory.appending(path: "key-copy")
                art = try stubBrandingFolder(in: stubs.directory)
            }

            func run(_ arguments: [String], _ extra: [String: String] = [:]) async throws -> Result {
                let secrets = ["NOCTULE_NOTARY_KEY_P8": ReleaseFromTagTests.keyBase64, "NOCTULE_NOTARY_KEY_ID": "KEYID12345",
                               "NOCTULE_NOTARY_ISSUER": "issuer-0000", "GH_TOKEN": "gh-token-secret",
                               "RUNNER_TEMP": runnerTemp.path, "STUB_KEY_COPY": keyCopy.path,
                               "NOCTULE_BRANDING_DIR": art.path]
                let environment = stubs.environment.merging(secrets) { _, new in new }.merging(extra) { _, new in new }
                return try await runScript("packaging/ci/release-from-tag.sh", arguments, environment: environment,
                                     root: repo, limit: 600)
            }

            var leftovers: [String] {
                ((try? FileManager.default.contentsOfDirectory(atPath: runnerTemp.path)) ?? []).sorted()
            }
            var calls: [String] { stubs.calls() }
            func called(_ prefix: String) -> Bool { calls.contains { $0.hasPrefix(prefix) } }
            func dmg(_ version: String) -> URL { repo.appending(path: "build/noctule-scan-\(version).dmg") }
        }

        private func sha(_ file: URL) async throws -> String {
            try #require(await run(tool("shasum"), ["-a", "256", file.path]).stdout.split(separator: " ").first.map(String.init))
        }

        @Test func draftReleaseForAFinalVersion() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await rig.run(["v0.2.0", "12"])
            #expect(result.status == 0, "\(result.stderr)")
            let dmg = rig.dmg("0.2.0")
            let checksum = rig.repo.appending(path: "build/noctule-scan-0.2.0.dmg.sha256")
            let hex = try await sha(dmg)
            let notes = "Draft made by the release workflow (run 12). SHA-256 of noctule-scan-0.2.0.dmg: \(hex). "
                + "Write the notes, then publish."
            let key = "\(rig.runnerTemp.path)/"
            let calls = rig.calls
            #expect(inOrder(calls, [
                "gh release view v0.2.0",
                "security ",
                "build release",
                "xcrun notarytool submit ",
                "xcrun notarytool submit \(dmg.path) ",
                "gh release create v0.2.0 \(dmg.path) \(checksum.path) --draft --verify-tag --title Noctule Scan 0.2.0 --notes \(notes)",
            ]), "\(calls)")
            let submits = calls.filter { $0.hasPrefix("xcrun notarytool submit ") }
            #expect(submits.count == 2)
            for submit in submits {
                #expect(submit.contains(" --key \(key)") && submit.contains("/AuthKey.p8 --key-id KEYID12345 --issuer issuer-0000 "), "\(submit)")
            }
            #expect(!calls.contains { $0.contains("--prerelease") })
            let versions = try bundleVersions(rig.repo.appending(path: "build/Noctule Scan.app"))
            #expect(versions.build == "12")
            #expect(versions.short == "0.2.0")
            #expect(try String(contentsOf: checksum, encoding: .utf8) == "\(hex)  noctule-scan-0.2.0.dmg\n")
            let names = try FileManager.default.contentsOfDirectory(atPath: rig.repo.appending(path: "build").path)
                .filter { $0 != "Noctule Scan.app" }
            #expect(names.sorted() == ["noctule-scan-0.2.0.dmg", "noctule-scan-0.2.0.dmg.sha256"], "\(names)")
            #expect(names.allSatisfy { $0 == $0.lowercased() && !$0.contains(" ") })
            #expect(try String(contentsOf: rig.keyCopy, encoding: .utf8) == Self.keyText)
            func mode(_ url: URL) throws -> Int {
                (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
            }
            #expect(try mode(rig.keyCopy) == 0o600)
            // The key's umask must not reach the build: the app stays readable by other accounts.
            let app = rig.repo.appending(path: "build/Noctule Scan.app/Contents")
            #expect(try mode(app.appending(path: "Info.plist")) & 0o004 != 0)
            #expect(try mode(app.appending(path: "MacOS/NoctuleScan")) & 0o005 == 0o005)
            #expect(try mode(app.appending(path: "MacOS")) & 0o005 == 0o005)
            #expect(calls.contains("env GH_TOKEN=unset"), "release.sh must not see GH_TOKEN: \(calls)")
            #expect(calls.contains("env NOCTULE_NOTARY_KEY_P8=unset"), "release.sh must not see the base64 key: \(calls)")
            #expect(rig.leftovers.isEmpty, "\(rig.leftovers)")
            #expect(result.stdout.contains("release-from-tag: draft release v0.2.0 created\n"))
        }

        @Test func preReleaseForASuffix() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0-beta.1")
            let result = try await rig.run(["v0.2.0-beta.1", "3"])
            #expect(result.status == 0, "\(result.stderr)")
            let create = try #require(rig.calls.first { $0.hasPrefix("gh release create ") })
            #expect(create.contains(" \(rig.dmg("0.2.0-beta.1").path) \(rig.dmg("0.2.0-beta.1").path).sha256 "), "\(create)")
            #expect(create.contains(" --prerelease"))
            #expect(create.contains("--title Noctule Scan 0.2.0-beta.1 "))
            #expect(try bundleVersions(rig.repo.appending(path: "build/Noctule Scan.app")).short == "0.2.0")
        }

        @Test func existingReleaseStopsBeforeApple() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await rig.run(["v0.2.0", "12"], ["STUB_GH_VIEW_STATUS": "0"])
            #expect(result.status == 1)
            #expect(result.stderr.contains(
                "release-from-tag: a release for v0.2.0 already exists; delete it or push a new tag"), "\(result.stderr)")
            for prefix in ["security", "build", "xcrun", "gh release create"] { #expect(!rig.called(prefix), "\(rig.calls)") }
        }

        @Test func ghFailureStopsBeforeApple() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let line = "HTTP 401: Bad credentials (https://api.github.com/graphql)"
            let result = try await rig.run(["v0.2.0", "12"], ["STUB_GH_VIEW_STATUS": "1", "STUB_GH_VIEW_STDERR": "\(line)\nsecond line"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release-from-tag: couldn't ask GitHub about releases: \(line)\n"), "\(result.stderr)")
            #expect(!result.stderr.contains("second line"))
            for prefix in ["security", "build", "xcrun", "gh release create"] { #expect(!rig.called(prefix), "\(rig.calls)") }
            #expect(rig.leftovers.isEmpty, "\(rig.leftovers)")
        }

        @Test func missingGhStopsBeforeApple() async throws {
            guard !FileManager.default.fileExists(atPath: "/usr/bin/gh"), !FileManager.default.fileExists(atPath: "/bin/gh") else {
                Issue.record("skipped: a real gh is in /usr/bin or /bin, so it can't be left off PATH")
                return
            }
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let bin = rig.stubs.directory.appending(path: "bin")
            try FileManager.default.removeItem(at: bin.appending(path: "gh"))
            let result = try await rig.run(["v0.2.0", "12"], ["PATH": "\(bin.path):/usr/bin:/bin"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release-from-tag: couldn't ask GitHub about releases"), "\(result.stderr)")
            for prefix in ["security", "build", "xcrun"] { #expect(!rig.called(prefix), "\(rig.calls)") }
            #expect(rig.leftovers.isEmpty, "\(rig.leftovers)")
        }

        private func preflight(_ rig: Rig, _ arguments: [String], _ extra: [String: String] = [:]) async throws -> Result {
            let blank = ["NOCTULE_NOTARY_KEY_P8": "", "NOCTULE_NOTARY_KEY_ID": "", "NOCTULE_NOTARY_ISSUER": ""]
            var environment = rig.stubs.environment.merging(["GH_TOKEN": "gh-token-secret", "STUB_KEY_COPY": rig.keyCopy.path]) { _, n in n }
            environment = environment.merging(blank) { _, n in n }.merging(extra) { _, n in n }
            return try await runScript("packaging/ci/release-from-tag.sh", arguments, environment: environment, root: rig.repo, limit: 600)
        }

        @Test func preflightNeedsNoAppleSecrets() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await preflight(rig, ["--preflight", "v0.2.0"])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stdout.contains("release-from-tag: v0.2.0 can be released\n"), "\(result.stdout)")
            #expect(rig.calls == ["gh release view v0.2.0"], "\(rig.calls)")
        }

        @Test func preflightRefusesATagNotOnMain() async throws {
            let rig = try await Rig()
            for arguments in [["checkout", "-q", "-b", "side"],
                              ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                               "commit", "-q", "--allow-empty", "-m", "side"]] {
                let git = try await run(tool("git"), ["-C", rig.repo.path] + arguments)
                try #require(git.status == 0, "\(git.stderr)")
            }
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await preflight(rig, ["--preflight", "v0.2.0"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release-from-tag: v0.2.0 isn't on main; tag a commit that is"), "\(result.stderr)")
            #expect(rig.calls.isEmpty, "\(rig.calls)")
        }

        @Test func preflightRefusesAnExistingRelease() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await preflight(rig, ["--preflight", "v0.2.0"], ["STUB_GH_VIEW_STATUS": "0"])
            #expect(result.status == 1)
            #expect(result.stderr.contains(
                "release-from-tag: a release for v0.2.0 already exists; delete it or push a new tag"), "\(result.stderr)")
            #expect(!result.stdout.contains("can be released"))
        }

        @Test func preflightRefusesOtherArguments() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            for arguments in [["--preflight"], ["--preflight", "v0.2.0", "extra"], ["--preflight", "0.2.0"]] {
                let result = try await preflight(rig, arguments)
                #expect(result.status == 2, "\(arguments)")
                #expect(result.stderr.contains("usage:"), "\(arguments): \(result.stderr)")
            }
            #expect(rig.calls.isEmpty, "\(rig.calls)")
        }

        @Test func tagNotOnMainIsRefused() async throws {
            let rig = try await Rig()
            for arguments in [["checkout", "-q", "-b", "side"],
                              ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                               "commit", "-q", "--allow-empty", "-m", "side"]] {
                let git = try await run(tool("git"), ["-C", rig.repo.path] + arguments)
                try #require(git.status == 0, "\(git.stderr)")
            }
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await rig.run(["v0.2.0", "12"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release-from-tag: v0.2.0 isn't on main; tag a commit that is"), "\(result.stderr)")
            #expect(rig.calls.isEmpty, "\(rig.calls)")
        }

        @Test func missingOriginMainIsExplained() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let git = try await run(tool("git"), ["-C", rig.repo.path, "update-ref", "-d", "refs/remotes/origin/main"])
            try #require(git.status == 0, "\(git.stderr)")
            let result = try await rig.run(["v0.2.0", "12"])
            #expect(result.status == 1)
            #expect(result.stderr.contains(
                "release-from-tag: origin/main isn't there; fetch it (actions/checkout with fetch-depth: 0)"), "\(result.stderr)")
            #expect(rig.calls.isEmpty, "\(rig.calls)")
        }

        @Test func missingSecretIsNamed() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            for name in ["NOCTULE_NOTARY_KEY_P8", "NOCTULE_NOTARY_KEY_ID", "NOCTULE_NOTARY_ISSUER", "GH_TOKEN"] {
                let result = try await rig.run(["v0.2.0", "12"], [name: ""])
                #expect(result.status == 1, "\(name)")
                let message = name == "GH_TOKEN" ? "release-from-tag: GH_TOKEN is empty"
                    : "release-from-tag: the secret \(name) is empty or not visible to this repository"
                #expect(result.stderr.contains(message), "\(name): \(result.stderr)")
            }
            // The checks that need no Apple secret run first, so gh may have been asked; nothing else was called.
            #expect(rig.calls.allSatisfy { $0 == "gh release view v0.2.0" }, "\(rig.calls)")
        }

        @Test func badBase64KeyStopsTheRun() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await rig.run(["v0.2.0", "12"], ["NOCTULE_NOTARY_KEY_P8": "not base64!!"])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release-from-tag: NOCTULE_NOTARY_KEY_P8 isn't base64"), "\(result.stderr)")
            #expect(!rig.called("build"))
            #expect(rig.leftovers.isEmpty, "\(rig.leftovers)")
        }

        @Test func notAKeyStopsTheRun() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await rig.run(["v0.2.0", "12"], ["NOCTULE_NOTARY_KEY_P8": Data("hello".utf8).base64EncodedString()])
            #expect(result.status == 1)
            #expect(result.stderr.contains("release-from-tag: NOCTULE_NOTARY_KEY_P8 isn't a .p8 key"), "\(result.stderr)")
            #expect(!rig.called("build"))
            #expect(rig.leftovers.isEmpty, "\(rig.leftovers)")
        }

        @Test func keyFileIsRemovedOnFailure() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await rig.run(["v0.2.0", "12"], ["STUB_NOTARY_STATUS": "Invalid"])
            #expect(result.status == 1)
            #expect(!rig.called("gh release create"))
            #expect(rig.leftovers.isEmpty, "\(rig.leftovers)")
        }

        @Test func failedCreateFailsTheRun() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            let result = try await rig.run(["v0.2.0", "12"], ["STUB_GH_CREATE_STATUS": "1"])
            #expect(result.status == 1)
            #expect(rig.called("gh release create"))
            #expect(!result.stdout.contains("created"))
        }

        @Test func outputCarriesNoSecrets() async throws {
            let forbidden = ["KEYID12345", "issuer-0000", "fake-key-body", Self.keyBase64, "gh-token-secret",
                             "Test Person", "TEAM123456"]
            let scenarios: [[String: String]] = [[:], ["STUB_NOTARY_STATUS": "Invalid"], ["STUB_GH_VIEW_STATUS": "0"],
                                                 ["NOCTULE_NOTARY_KEY_P8": "not base64!!"],
                                                 ["NOCTULE_NOTARY_KEY_P8": Data("hello".utf8).base64EncodedString()]]
            for extra in scenarios {
                let rig = try await Rig()
                try await tagHead(rig.repo, "v0.2.0")
                let result = try await rig.run(["v0.2.0", "12"], extra)
                let output = result.stdout + result.stderr
                for secret in forbidden {
                    #expect(!output.contains(secret), "\(extra.keys): output shows a secret")
                }
            }
        }

        @Test func refusesBadArguments() async throws {
            let rig = try await Rig()
            try await tagHead(rig.repo, "v0.2.0")
            for arguments in [["0.2.0", "12"], ["vfoo", "12"], ["v0.2.0"], ["v0.2.0", "x"], []] {
                let result = try await rig.run(arguments)
                #expect(result.status == 2, "\(arguments)")
                #expect(result.stderr.contains("usage:"), "\(arguments): \(result.stderr)")
            }
            #expect(rig.calls.isEmpty, "\(rig.calls)")
        }
    }
}

// MARK: - The placeholder installer background (Plan 21, Task 2)

@Suite(.timeLimit(.minutes(2))) struct PlaceholderBackgroundTests {
    private static let committed = "packaging/dmg/placeholder/background.tiff"

    private func images(at url: URL) throws -> [CGImage] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.lastPathComponent) is missing or unreadable")
        return try (0..<CGImageSourceGetCount(source)).map { try #require(CGImageSourceCreateImageAtIndex(source, $0, nil)) }
    }

    /// The 8-bit sRGB RGBA bytes of an image, and its width.
    private func pixels(_ image: CGImage) throws -> (bytes: [UInt8], width: Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return (bytes, image.width)
    }

    private func pixel(_ p: (bytes: [UInt8], width: Int), _ x: Int, _ y: Int) -> [Int] {
        let o = (y * p.width + x) * 4
        return [Int(p.bytes[o]), Int(p.bytes[o + 1]), Int(p.bytes[o + 2])]
    }

    @Test func nothingInPackagingCarriesC2PA() throws {
        let root = try repositoryFile("packaging")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        let needle = Data("c2pa".utf8)
        var checked = 0
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            checked += 1
            #expect(try Data(contentsOf: url).range(of: needle) == nil, "\(url.lastPathComponent) mentions c2pa")
        }
        #expect(checked > 0)
    }

    @Test func tiffHasBothResolutions() throws {
        let all = try images(at: repositoryFile(Self.committed))
        #expect(all.map { [$0.width, $0.height] } == [[640, 400], [1280, 800]])
    }

    @Test func isPlainLightGrey() throws {
        let p = try pixels(try #require(try images(at: repositoryFile(Self.committed)).first))
        for (x, y) in [(320, 4), (320, 396), (20, 214)] {
            let c = pixel(p, x, y)
            #expect(c.allSatisfy { $0 >= 0xD8 }, "(\(x), \(y)) is light: \(c)")
            #expect((c.max() ?? 0) - (c.min() ?? 0) <= 6, "(\(x), \(y)) is grey: \(c)")
        }
        var amber = 0
        for y in 0..<p.bytes.count / 4 / p.width {
            for x in 0..<p.width {
                let c = pixel(p, x, y)
                if c[0] > c[2] + 40 { amber += 1 }
            }
        }
        #expect(amber == 0, "\(amber) pixels with red well above blue")
    }

    @Test func rendererReproducesTheCommittedImage() async throws {
        let out = try temporaryDirectory().appending(path: "again.tiff")
        let script = try repositoryFile("packaging/dmg/placeholder/render-placeholder-background.swift")
        let result = try await run(URL(fileURLWithPath: "/usr/bin/swift"), [script.path, out.path],
                             currentDirectory: FileManager.default.temporaryDirectory, limit: 300)
        try #require(result.status == 0, "\(result.stderr)")
        let got = try images(at: out), want = try images(at: repositoryFile(Self.committed))
        try #require(got.count == want.count)
        for (a, b) in zip(got, want) {
            try #require(a.width == b.width && a.height == b.height)
            let pa = try pixels(a), pb = try pixels(b)
            let worst = zip(pa.bytes, pb.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst <= 2, "largest channel difference \(worst)")
        }
    }
}

// MARK: - signing-keychain.sh

// One test at a time: each runs tools (IntegrationSupport.swift, "Waiting in these tests").
@Suite(.serialized, .timeLimit(.minutes(1))) struct SigningKeychainTests {
    private static let password = "p12-secret-pw"
    private static let p12 = Data("fake-p12".utf8).base64EncodedString()
    private typealias Result = (status: Int32, stdout: String, stderr: String)

    /// A stub directory, a `RUNNER_TEMP` under a directory with a space, and the keychain path the script will use.
    private struct Rig {
        let stubs: StubTools
        let runnerTemp: URL
        var keychain: String { runnerTemp.appending(path: "noctule-signing.keychain-db").path }

        init() throws {
            stubs = try StubTools()
            runnerTemp = stubs.directory.appending(path: "runner temp")
            try FileManager.default.createDirectory(at: runnerTemp, withIntermediateDirectories: true)
        }

        /// Runs the script with both secrets set, then `extra` (an empty value is set empty).
        func run(_ arguments: [String], _ extra: [String: String] = [:]) async throws -> Result {
            let secrets = ["NOCTULE_DEVELOPER_ID_P12": SigningKeychainTests.p12,
                           "NOCTULE_DEVELOPER_ID_P12_PASSWORD": SigningKeychainTests.password]
            let environment = stubs.environment.merging(["RUNNER_TEMP": runnerTemp.path]) { _, new in new }
                .merging(secrets) { _, new in new }.merging(extra) { _, new in new }
            return try await runScript("packaging/ci/signing-keychain.sh", arguments, environment: environment)
        }

        var leftovers: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: runnerTemp.path)) ?? []).sorted()
        }
    }

    /// The keychain password the script chose, from the `create-keychain` call.
    private func generatedPassword(_ rig: Rig) -> String? {
        let prefix = "security create-keychain -p "
        guard let line = rig.stubs.calls().first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return line.dropFirst(prefix.count).split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    private func noSecrets(_ rig: Rig, _ result: Result) {
        let output = result.stdout + result.stderr
        var forbidden = [Self.password, "fake-p12", Self.p12]
        if let generated = generatedPassword(rig) { forbidden.append(generated) }
        for secret in forbidden { #expect(!output.contains(secret), "output shows a secret") }
    }

    @Test func createImportsTheCertificateAndTheIntermediate() async throws {
        let rig = try Rig()
        let result = try await rig.run(["create"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("signing-keychain: \(rig.keychain)"))
        #expect(result.stdout.contains("signing-keychain: ready"))
        let kc = rig.keychain
        let calls = rig.stubs.calls()
        let x = try #require(generatedPassword(rig))
        #expect(x.count >= 24)
        let intermediate = try repositoryFile("packaging/ci/DeveloperIDG2CA.cer").path
        let expected = [
            "security create-keychain -p \(x) \(kc)",
            "security set-keychain-settings -lut 21600 \(kc)",
            "security unlock-keychain -p \(x) \(kc)",
            "security import \(rig.runnerTemp.path)/",
            "security find-certificate -a -Z \(kc)",
            "security import \(intermediate) -k \(kc)",
            "security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \(x) \(kc)",
            "security list-keychains -d user",
            "security list-keychains -d user -s \(kc) /Users/test/Library/Keychains/login.keychain-db",
        ]
        #expect(inOrder(calls, expected), "calls were \(calls)")
        let importLine = try #require(calls.first { $0.hasPrefix("security import \(rig.runnerTemp.path)/") })
        #expect(importLine.hasSuffix(" -k \(kc) -P \(Self.password) -T /usr/bin/codesign -f pkcs12"), "\(importLine)")
        #expect(rig.leftovers.isEmpty, "left \(rig.leftovers)")
        noSecrets(rig, result)
    }

    @Test func aFailedImportLeavesNoP12() async throws {
        let rig = try Rig()
        let result = try await rig.run(["create"], ["STUB_SECURITY_FAIL": "import"])
        #expect(result.status == 1)
        #expect(rig.leftovers.isEmpty, "left \(rig.leftovers)")
        noSecrets(rig, result)
    }

    /// A `.p12` exported with its certificate chain already holds Apple's G2 intermediate, and
    /// importing it a second time fails ("The specified item already exists in the keychain"), as
    /// the first real release run did (2026-11-15).
    @Test func aP12WithItsChainSkipsTheIntermediate() async throws {
        let rig = try Rig()
        let intermediate = try repositoryFile("packaging/ci/DeveloperIDG2CA.cer")
        let sha1 = Insecure.SHA1.hash(data: try Data(contentsOf: intermediate)).map { String(format: "%02X", $0) }.joined()
        let holdsBoth = stubCertificateListing + #"\nSHA-256 hash: \#(sha1)\#(sha1.prefix(24))\nSHA-1 hash: \#(sha1)\n    "labl"<blob>="Developer ID Certification Authority""#
        let result = try await rig.run(["create"], ["STUB_KEYCHAIN_CERTIFICATES": holdsBoth])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("signing-keychain: the .p12 already holds Apple's Developer ID G2 intermediate"), "\(result.stdout)")
        #expect(result.stdout.contains("signing-keychain: ready"))
        let calls = rig.stubs.calls()
        #expect(!calls.contains { $0.hasPrefix("security import \(intermediate.path)") }, "\(calls)")
        #expect(inOrder(calls, ["security import \(rig.runnerTemp.path)/", "security find-certificate -a -Z \(rig.keychain)",
                                "security set-key-partition-list", "security list-keychains -d user -s \(rig.keychain)"]), "\(calls)")
        #expect(!calls.contains { $0.hasPrefix("security delete-keychain") })
        noSecrets(rig, result)
    }

    /// Only the G2 intermediate itself counts: any other certificate in the keychain (the signing
    /// certificate, an older intermediate of the same name) leaves the import in, even one whose
    /// SHA-1 differs from the intermediate's in its last digit only.
    @Test func anotherCertificateDoesNotStandInForTheIntermediate() async throws {
        let rig = try Rig()
        let intermediate = try repositoryFile("packaging/ci/DeveloperIDG2CA.cer")
        let sha1 = Insecure.SHA1.hash(data: try Data(contentsOf: intermediate)).map { String(format: "%02X", $0) }.joined()
        let other = sha1.dropLast() + (sha1.hasSuffix("0") ? "1" : "0")
        let listing = stubCertificateListing + #"\nSHA-1 hash: \#(other)\n    "labl"<blob>="Developer ID Certification Authority""#
        let result = try await rig.run(["create"], ["STUB_KEYCHAIN_CERTIFICATES": listing])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(rig.stubs.calls().contains("security import \(intermediate.path) -k \(rig.keychain)"), "\(rig.stubs.calls())")
    }

    /// If the keychain can't be listed, the intermediate is imported as before.
    @Test func anUnlistableKeychainStillGetsTheIntermediate() async throws {
        let rig = try Rig()
        let intermediate = try repositoryFile("packaging/ci/DeveloperIDG2CA.cer")
        let result = try await rig.run(["create"], ["STUB_SECURITY_FAIL": "find-certificate"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(rig.stubs.calls().contains("security import \(intermediate.path) -k \(rig.keychain)"), "\(rig.stubs.calls())")
        #expect(result.stdout.contains("signing-keychain: ready"))
    }

    /// What `find-certificate` prints (the certificates' names and hashes) never reaches the log.
    @Test func theKeychainListingIsNeverPrinted() async throws {
        for extra in [[:], ["STUB_KEYCHAIN_CERTIFICATES": stubCertificateListing + #"\nSHA-1 hash: \#(String(repeating: "B", count: 40))"#]] {
            let rig = try Rig()
            let result = try await rig.run(["create"], extra)
            let output = result.stdout + result.stderr
            for shown in ["Test Person", stubHash, "SHA-1 hash", String(repeating: "B", count: 40)] {
                #expect(!output.contains(shown), "output shows \(shown)")
            }
        }
    }

    @Test func aSecretWrappedOverSeveralLinesIsAccepted() async throws {
        let rig = try Rig()
        let wrapped = "\(Self.p12.prefix(4))\n\(Self.p12.dropFirst(4))\n"
        let result = try await rig.run(["create"], ["NOCTULE_DEVELOPER_ID_P12": wrapped])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(rig.stubs.calls().contains { $0.hasPrefix("security import ") })
    }

    @Test func missingSecretsAreNamed() async throws {
        for name in ["NOCTULE_DEVELOPER_ID_P12", "NOCTULE_DEVELOPER_ID_P12_PASSWORD"] {
            let rig = try Rig()
            let result = try await rig.run(["create"], [name: ""])
            #expect(result.status == 1, "\(name) empty")
            #expect(result.stderr.contains("signing-keychain: the secret \(name) is empty or not visible to this repository"),
                    "\(result.stderr)")
            #expect(rig.stubs.calls().isEmpty)

            // Unset: the same, with the variable left out of the environment altogether.
            let script = try repositoryFile("packaging/ci/signing-keychain.sh")
            var environment = rig.stubs.environment.merging(["RUNNER_TEMP": rig.runnerTemp.path,
                "NOCTULE_DEVELOPER_ID_P12": Self.p12, "NOCTULE_DEVELOPER_ID_P12_PASSWORD": Self.password]) { _, new in new }
            environment.removeValue(forKey: name)
            let unset = try await run(tool("env"), ["-u", name, script.path, "create"], environment: environment)
            #expect(unset.status == 1, "\(name) unset")
            #expect(unset.stderr.contains("signing-keychain: the secret \(name) is empty or not visible to this repository"),
                    "\(unset.stderr)")
            #expect(rig.stubs.calls().isEmpty)
        }
    }

    @Test func badBase64IsRefused() async throws {
        for bad in ["not base64!!", "QUJDR", "QUJD===="] {
            let rig = try Rig()
            let result = try await rig.run(["create"], ["NOCTULE_DEVELOPER_ID_P12": bad])
            #expect(result.status == 1, "\(bad)")
            #expect(result.stderr.contains("signing-keychain: NOCTULE_DEVELOPER_ID_P12 isn't base64"), "\(result.stderr)")
            #expect(rig.stubs.calls().isEmpty, "\(bad): \(rig.stubs.calls())")
            #expect(rig.leftovers.isEmpty)
        }
    }

    @Test func deleteRemovesTheKeychain() async throws {
        let rig = try Rig()
        try "x".write(toFile: rig.keychain, atomically: true, encoding: .utf8)
        let result = try await rig.run(["delete"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("signing-keychain: deleted"))
        #expect(rig.stubs.calls() == ["security delete-keychain \(rig.keychain)"])
    }

    @Test func deleteWithNoKeychainIsFine() async throws {
        let rig = try Rig()
        let result = try await rig.run(["delete"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("signing-keychain: nothing to delete"))
        #expect(rig.stubs.calls().isEmpty)
    }

    @Test func createReplacesAKeychainAlreadyThere() async throws {
        let rig = try Rig()
        try "x".write(toFile: rig.keychain, atomically: true, encoding: .utf8)
        let result = try await rig.run(["create"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(inOrder(rig.stubs.calls(), ["security delete-keychain \(rig.keychain)", "security create-keychain"]))
    }

    @Test func aFailedCreateDeletesItsKeychain() async throws {
        for step in ["import", "set-key-partition-list", "list-keychains"] {
            let rig = try Rig()
            let result = try await rig.run(["create"], ["STUB_SECURITY_FAIL": step])
            #expect(result.status == 1, "\(step)")
            #expect(rig.stubs.calls().last == "security delete-keychain \(rig.keychain)", "\(step): \(rig.stubs.calls())")
            #expect(rig.leftovers.isEmpty, "left \(rig.leftovers)")
        }
    }

    @Test func aFinishedCreateKeepsItsKeychain() async throws {
        let rig = try Rig()
        let result = try await rig.run(["create"])
        #expect(result.status == 0)
        #expect(!rig.stubs.calls().contains { $0.hasPrefix("security delete-keychain") })
    }

    @Test func outputCarriesNoSecrets() async throws {
        var runs: [(Rig, Result)] = []
        func record(_ extra: [String: String], _ arguments: [String] = ["create"], keychainFile: Bool = false) async throws {
            let rig = try Rig()
            if keychainFile { try "x".write(toFile: rig.keychain, atomically: true, encoding: .utf8) }
            runs.append((rig, try await rig.run(arguments, extra)))
        }
        try await record([:])
        try await record(["STUB_SECURITY_FAIL": "import"])
        try await record(["STUB_SECURITY_FAIL": "set-key-partition-list"])
        try await record(["NOCTULE_DEVELOPER_ID_P12": "not base64!!"])
        try await record(["NOCTULE_DEVELOPER_ID_P12": ""])
        try await record(["NOCTULE_DEVELOPER_ID_P12_PASSWORD": ""])
        try await record([:], ["delete"], keychainFile: true)
        try await record([:], ["delete"])
        for (rig, result) in runs { noSecrets(rig, result) }
    }

    @Test func intermediateIsApplesG2() throws {
        let data = try Data(contentsOf: repositoryFile("packaging/ci/DeveloperIDG2CA.cer"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a")
    }

    @Test func refusesOtherArguments() async throws {
        for arguments in [[], ["make"], ["create", "delete"]] as [[String]] {
            let rig = try Rig()
            let result = try await rig.run(arguments)
            #expect(result.status == 2, "\(arguments)")
            #expect(rig.stubs.calls().isEmpty)
        }
    }
}

// MARK: - .github/workflows/release.yml

/// Plan 14 Task 4. The package has no YAML library, so the workflow is read as text. **Assumption:** the file is
/// formatted the way it is written today: top-level keys at column 0, the one job's keys at 4 spaces, its steps
/// as a list under `    steps:` whose items start with `      - ` and whose own keys sit at 8 spaces. A reformat
/// that breaks that makes these tests fail loudly (`steps` comes back empty) rather than pass quietly.
@Suite(.timeLimit(.minutes(1))) struct ReleaseWorkflowTests {
    private static let secrets = ["NOCTULE_DEVELOPER_ID_P12", "NOCTULE_DEVELOPER_ID_P12_PASSWORD",
                                  "NOCTULE_NOTARY_KEY_P8", "NOCTULE_NOTARY_KEY_ID", "NOCTULE_NOTARY_ISSUER"]
    private static let brandingKey = "NOCTULE_BRANDING_DEPLOY_KEY"

    private struct Workflow {
        let text: String
        let lines: [String]
        /// Everything before `    steps:` (the workflow's top and the job's own keys).
        let header: [String]
        /// One entry per step, from its `      - ` line to the line before the next.
        let steps: [String]

        init() throws {
            text = try String(contentsOf: repositoryFile(".github/workflows/release.yml"), encoding: .utf8)
            lines = text.components(separatedBy: "\n")
            let stepsAt = try #require(lines.firstIndex(of: "    steps:"))
            header = Array(lines[..<stepsAt])
            var out: [String] = []
            for line in lines[(stepsAt + 1)...] {
                if line.hasPrefix("      - ") { out.append(line) } else if !out.isEmpty { out[out.count - 1] += "\n" + line }
            }
            steps = out
        }

        func stepIndex(containing needle: String) -> Int? { steps.firstIndex { $0.contains(needle) } }

        /// The lines of the top-level block `key:` (up to the next line at column 0).
        func block(_ key: String) -> [String] {
            guard let start = lines.firstIndex(of: "\(key):") else { return [] }
            return Array(lines[(start + 1)...].prefix { $0.isEmpty || $0.hasPrefix(" ") })
        }

        /// The job-level `env:` block (4-space `env:` in the header, its 6-space entries).
        var jobEnv: [String] {
            guard let start = header.firstIndex(of: "    env:") else { return [] }
            return Array(header[(start + 1)...].prefix { $0.hasPrefix("      ") })
        }
    }

    /// `release.sh` refuses a dirty tree, so the folder the art is checked out to must be ignored.
    @Test func theBrandingCheckoutPathIsIgnored() async throws {
        let w = try Workflow()
        let step = try #require(w.steps.first { $0.contains("name: Check out the branding") })
        let line = try #require(step.components(separatedBy: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("path:") })
        let path = line.trimmingCharacters(in: .whitespaces).dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
        #expect(!path.isEmpty)
        let root = try repositoryFile("")
        let git = try await run(tool("git"), ["-C", root.path, "check-ignore", "-q", "--no-index", path + "/builds/noctule-scan/x"])
        #expect(git.status == 0, "\(path) isn't ignored by .gitignore: release.sh would see it as an untracked change")
    }

    @Test func triggersOnVersionTagsOnly() throws {
        let w = try Workflow()
        let on = w.block("on").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        #expect(on == ["push:", "tags:", "- 'v*.*.*'"], "\(on)")
    }

    @Test func jobUsesTheReleaseEnvironment() throws {
        let w = try Workflow()
        #expect(w.header.filter { $0.hasPrefix("    environment:") } == ["    environment: release"], "\(w.header)")
    }

    @Test func runnerAndXcodeArePinned() throws {
        let w = try Workflow()
        #expect(w.header.contains("    runs-on: xcode-27"))
        #expect(w.header.contains("    timeout-minutes: 180"))
        let xcode = try #require(w.stepIndex(containing: "sudo xcode-select -s /Applications/Xcode_27.2.app"))
        #expect(w.steps[xcode].contains("xcodebuild -version"))
    }

    @Test func permissionsAndConcurrency() throws {
        let w = try Workflow()
        let text = w.text
        #expect(text.contains("    permissions:\n      contents: write\n"))
        #expect(text.contains("    concurrency:\n      group: release-${{ github.ref_name }}\n      cancel-in-progress: false\n"))
        // No `permissions:` or `concurrency:` at the top level to widen or change them.
        #expect(!w.lines.contains { $0.hasPrefix("permissions:") || $0.hasPrefix("env:") })
    }

    @Test func actionsArePinnedBySHA() throws {
        let w = try Workflow()
        let uses = w.lines.compactMap { line -> String? in
            guard let r = line.range(of: "uses:") else { return nil }
            return line[r.upperBound...].split(separator: " ").first.map(String.init)
        }
        #expect(!uses.isEmpty)
        for value in uses {
            #expect(value.wholeMatch(of: /[\w.-]+\/[\w.-]+@[0-9a-f]{40}/) != nil, "\(value)")
        }
        #expect(w.text.contains("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1"))
        let checkout = try #require(w.stepIndex(containing: "actions/checkout@"))
        #expect(w.steps[checkout].contains("fetch-depth: 0"))
    }

    @Test func eachSecretAppearsOnceInItsStep() throws {
        let w = try Workflow()
        let reference = /\$\{\{\s*secrets\.(\w+)\s*\}\}/
        let all = w.text.matches(of: reference).map { String($0.output.1) }
        for name in Self.secrets + [Self.brandingKey] { #expect(all.filter { $0 == name }.count == 1, "\(name)") }
        #expect(all.count == Self.secrets.count + 1, "\(all)")
        let create = try #require(w.stepIndex(containing: "signing-keychain.sh create"))
        let release = try #require(w.stepIndex(containing: "release-from-tag.sh \"$GITHUB_REF_NAME\" \"$GITHUB_RUN_NUMBER\""))
        for name in Self.secrets.prefix(2) { #expect(w.steps[create].contains("\(name): ${{ secrets.\(name) }}"), "\(name)") }
        for name in Self.secrets.suffix(3) { #expect(w.steps[release].contains("\(name): ${{ secrets.\(name) }}"), "\(name)") }
        // Not at the workflow's or the job's level.
        #expect(!w.header.joined(separator: "\n").contains("secrets."))
        #expect(w.steps[release].contains("GH_TOKEN: ${{ github.token }}"))
    }

    @Test func brandingIsCheckedOutAtThePinnedRef() throws {
        let w = try Workflow()
        let read = try #require(w.stepIndex(containing: "name: Read the branding ref"))
        #expect(w.steps[read].contains("id: branding"), "\(w.steps[read])")
        #expect(w.steps[read].contains("run: echo \"ref=$(cat packaging/branding-ref)\" >> \"$GITHUB_OUTPUT\""), "\(w.steps[read])")
        let step = try #require(w.stepIndex(containing: "name: Check out the branding"))
        let text = w.steps[step]
        #expect(text.contains("uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1"), "\(text)")
        for line in ["repository: noctule-dev/noctule-design-language",
                     "ref: ${{ steps.branding.outputs.ref }}",
                     "ssh-key: ${{ secrets.NOCTULE_BRANDING_DEPLOY_KEY }}",
                     "path: branding",
                     "sparse-checkout: builds/noctule-scan",
                     "persist-credentials: false"] {
            #expect(text.contains("          \(line)"), "\(line)")
        }
    }

    @Test func brandingComesAfterTheTestsAndBeforeTheBuild() throws {
        let w = try Workflow()
        let keychain = try #require(w.stepIndex(containing: "signing-keychain.sh create"))
        let read = try #require(w.stepIndex(containing: "name: Read the branding ref"))
        let checkout = try #require(w.stepIndex(containing: "name: Check out the branding"))
        let release = try #require(w.stepIndex(containing: "release-from-tag.sh \"$GITHUB_REF_NAME\" \"$GITHUB_RUN_NUMBER\""))
        let lastTest = try #require(w.steps.lastIndex { $0.contains("swift test") })
        #expect(lastTest < keychain)
        #expect(keychain < read)
        #expect(read < checkout)
        #expect(checkout < release)
    }

    @Test func onlyTheBuildStepSeesTheBranding() throws {
        let w = try Workflow()
        let holders = w.steps.indices.filter { w.steps[$0].contains("NOCTULE_BRANDING_DIR") }
        let release = try #require(w.stepIndex(containing: "release-from-tag.sh \"$GITHUB_REF_NAME\" \"$GITHUB_RUN_NUMBER\""))
        #expect(holders == [release], "\(holders)")
        #expect(w.steps[release].contains("          NOCTULE_BRANDING_DIR: ${{ github.workspace }}/branding/builds/noctule-scan"))
        #expect(!w.header.joined(separator: "\n").contains("NOCTULE_BRANDING_DIR"))
        #expect(w.text.components(separatedBy: "NOCTULE_BRANDING_DIR").count - 1 == 1)
    }

    @Test func brandingRefIsAFullSHA() throws {
        let text = try String(contentsOf: repositoryFile("packaging/branding-ref"), encoding: .utf8)
        #expect(text.wholeMatch(of: /[0-9a-f]{40}\n?/) != nil, "\(text)")
    }

    @Test func cleanupRunsAlways() throws {
        let w = try Workflow()
        let last = try #require(w.steps.last)
        #expect(last.contains("signing-keychain.sh delete"))
        #expect(last.contains("if: always()"))
        #expect(w.steps.filter { $0.contains("signing-keychain.sh delete") }.count == 1)
    }

    @Test func noDebugOutput() throws {
        let w = try Workflow()
        for banned in ["set -x", "ACTIONS_STEP_DEBUG", "ACTIONS_RUNNER_DEBUG"] {
            #expect(!w.text.contains(banned), "\(banned)")
        }
    }

    /// Both `swift test` steps (and the build of the tests) come before the keychain exists.
    @Test func testsRunBeforeSigning() throws {
        let w = try Workflow()
        let keychain = try #require(w.stepIndex(containing: "signing-keychain.sh create"))
        let build = try #require(w.steps.firstIndex { $0.contains("swift build --build-tests") })
        let tests = w.steps.indices.filter { w.steps[$0].contains("swift test") }
        #expect(tests.count == 2)
        #expect(build < tests[0])
        for index in tests { #expect(index < keychain) }
        let order = ["actions/checkout@", "sudo xcode-select", "swift build --build-tests"]
        let positions = try order.map { needle in try #require(w.stepIndex(containing: needle)) }
        #expect(positions == positions.sorted())
        #expect(positions.last! < tests[0])
    }

    /// The timing-sensitive suites run alone in the second step; together the two steps cover every suite.
    @Test func testsCoverEverySuite() throws {
        let w = try Workflow()
        let tests = w.steps.filter { $0.contains("swift test") }
        try #require(tests.count == 2)
        let skipped = Set(tests[0].matches(of: /--skip\s(\w+)/).map { String($0.output.1) })
        let filter = try #require(tests[1].firstMatch(of: /--filter "([^"]+)"/)).output.1
        let filtered = Set(filter.split(separator: "|").map(String.init))
        #expect(!skipped.isEmpty)
        #expect(skipped == filtered, "skipped \(skipped), filtered \(filtered)")
        #expect(tests[0].contains("--skip-build") && tests[1].contains("--skip-build"))
        #expect(tests[1].contains("--no-parallel"))
        // No single test is skipped by the workflow; the known flakes skip themselves on a CI runner.
        #expect(!tests[1].contains("--skip "), "\(tests[1])")
        #expect(w.text.components(separatedBy: "--skip ").count - 1 == skipped.count)
    }

    /// A hung step fails the run in minutes, not after the job's three hours: the build gets 15, each test step 20.
    @Test func stepsHaveTimeLimits() throws {
        let w = try Workflow()
        let build = try #require(w.steps.first { $0.contains("swift build --build-tests") })
        #expect(build.contains("        timeout-minutes: 15"), "\(build)")
        let tests = w.steps.filter { $0.contains("swift test") }
        #expect(tests.count == 2)
        for step in tests { #expect(step.contains("        timeout-minutes: 20"), "\(step)") }
    }

    /// The job says it is a CI runner, which switches on the tests' `.skippedOnCIRunner` trait.
    @Test func jobMarksTheCIRunner() throws {
        let w = try Workflow()
        #expect(w.jobEnv.contains("      NOCTULE_CI_RUNNER: \"1\""), "\(w.jobEnv)")
    }

    /// The only `--skip` in any step is one of the suites of the first test step.
    @Test func noSingleTestIsSkipped() throws {
        let w = try Workflow()
        let suites: Set<String> = ["MockSDS200Tests", "MockSerialScannerTests", "ScannerClientTests", "KeepAliveOnTheMock",
                                   "PipeLineInSourceTests", "MockLineOutTests", "StationRunnerLineInTests",
                                   "StationRunnerClippedAndSilentHitsTests", "LineInCLIIntegrationTests"]
        let all = w.steps.flatMap { $0.matches(of: /--skip\s(\w+)/).map { String($0.output.1) } }
        #expect(Set(all) == suites, "\(all)")
        #expect(all.count == suites.count, "\(all)")
        for step in w.steps where step.contains("--skip ") { #expect(step.contains("name: Test (parallel)"), "\(step)") }
    }

    @Test func dmgEnvironmentIsBuiltBeforeSigning() throws {
        let w = try Workflow()
        let prepare = try #require(w.stepIndex(containing: "make-dmg.sh --prepare"))
        let keychain = try #require(w.stepIndex(containing: "signing-keychain.sh create"))
        let lastTest = try #require(w.steps.lastIndex { $0.contains("swift test") })
        #expect(lastTest < prepare)
        #expect(prepare < keychain)
    }

    @Test func pythonIsChosenExplicitly() throws {
        let w = try Workflow()
        let line = try #require(w.jobEnv.first { $0.contains("NOCTULE_PYTHON:") })
        let value = line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        #expect(value.hasPrefix("/"), "\(value)")
        #expect(w.jobEnv.contains { $0.contains("NOCTULE_NO_USB_DETECTION: \"1\"") })
    }

    @Test func releaseStepPassesTagAndRunNumber() throws {
        let w = try Workflow()
        let release = try #require(w.stepIndex(containing: "release-from-tag.sh \"$GITHUB_REF_NAME\" \"$GITHUB_RUN_NUMBER\""))
        #expect(w.steps[release].contains("packaging/ci/release-from-tag.sh \"$GITHUB_REF_NAME\" \"$GITHUB_RUN_NUMBER\""))
        let keychain = try #require(w.stepIndex(containing: "signing-keychain.sh create"))
        #expect(keychain < release)
    }

    @Test func tagIsCheckedFirst() throws {
        let w = try Workflow()
        let checkout = try #require(w.stepIndex(containing: "actions/checkout@"))
        let check = try #require(w.stepIndex(containing: "release-from-tag.sh --preflight"))
        #expect(check == checkout + 1)
        #expect(!w.steps[check].contains("secrets."))
        #expect(w.steps[check].contains("name: Check the tag"))
        #expect(w.steps[check].contains("run: packaging/ci/release-from-tag.sh --preflight \"$GITHUB_REF_NAME\""))
        #expect(w.steps[check].contains("GH_TOKEN: ${{ github.token }}"))
        let xcode = try #require(w.stepIndex(containing: "sudo xcode-select"))
        #expect(check < xcode)
    }

    @Test func checkoutDoesNotPersistCredentials() throws {
        let w = try Workflow()
        let checkout = try #require(w.stepIndex(containing: "actions/checkout@"))
        #expect(w.steps[checkout].contains("persist-credentials: false"))
    }
}
