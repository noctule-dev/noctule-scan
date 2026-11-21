// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Testing

// `noctule` over USB serial against the `noctule-mock-scanner --model sds150 --serial` executable,
// both launched as subprocesses; the mock serves a pseudo-terminal behind a link in the test's own
// temporary directory. Every wait is bounded, and every subprocess is stopped (then killed if
// needed) on every path. All names and values are fictional.
//
// **Hardware safety.** The owner's real SDS150 may be plugged into this Mac, and it is then the
// only Uniden port automatic detection finds. So every `noctule` launched here gets
// `NOCTULE_NO_USB_DETECTION=1` (the CLI finds no ports at all) and passes the mock's port by path;
// no test runs a bare `--serial`. Each launch also gets `NOCTULE_TEST_SERIAL_PORTS` (a decoy: a
// path in the test's directory, or a second mock), which replaces the IOKit listing, so even a
// build that ignored the kill-switch would find the decoy, never the real scanner. And every program
// launched here runs in the test's temporary directory (`launch`), where `noctule` finds no
// `config/dev-scanner.env`: a command without `--host` that regressed into the network path has no
// address, so it can't reach the owner's SDS200 (`harnessRunsWhereNoConfigIsFound`).

/// A programmed talkgroup, then an unprogrammed conventional channel; one pass is 3.5 s.
private let scenarioJSON = """
    {
      "model": "SDS150",
      "firmware": "1.01.02",
      "loop": true,
      "mode": "trunk",
      "idle": { "system": "Lakeview County", "site": "Lakeview Simulcast", "frequencyMHz": 851.0125,
                "modulation": "NFM", "rssi": -999 },
      "transmissions": [
        { "at": 0.5, "duration": 1.0, "system": "Lakeview County", "department": "Lakeview Public Works",
          "channel": "County Roads", "tgid": "3301", "unitID": "6101", "frequencyMHz": 851.2375,
          "modulation": "NFM", "toneOrCode": "NAC 2A1h", "rssi": -62, "programmed": true, "toneHz": 440 },
        { "at": 2.0, "duration": 1.0, "system": "Lakeview County", "department": "Lakeview Parks",
          "channel": "Lakeview Marina", "frequencyMHz": 155.4321, "modulation": "FM", "rssi": -60,
          "programmed": false, "toneHz": 660 }
      ]
    }
    """

private let noneFoundLine = "No Uniden scanner found. Plug the scanner in and choose Serial Port on its screen."
private let hint = "Plug the scanner in and choose Serial Port on its screen."

/// A temporary directory per test: the mock's link, settings, recordings, the cooldown store a
/// USB station must never create, a scenario, and a decoy "detected" port. Removed by `cleanUp()`.
private struct SerialDirs {
    let root: URL
    var link: URL { root.appending(path: "port") }
    var settings: URL { root.appending(path: "settings") }
    var recordings: URL { root.appending(path: "recordings") }
    var cooldownStore: URL { root.appending(path: "cooldown.json") }
    var scenario: URL { root.appending(path: "scenario.json") }
    /// What the CLI's port listing holds (`NOCTULE_TEST_SERIAL_PORTS`): nothing is there unless a
    /// test starts a second mock behind it.
    var decoy: URL { root.appending(path: "decoy-port") }

    init() throws {
        root = try temporaryDirectory()
        try scenarioJSON.write(to: scenario, atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// The kill-switch, and the decoy listing in place of IOKit's.
    var environment: [String: String] {
        ["NOCTULE_NO_USB_DETECTION": "1", "NOCTULE_TEST_SERIAL_PORTS": decoy.path]
    }

    var settingsFlags: [String] { ["--settings-dir", settings.path] }
    /// `log`'s flags, with the network-only cooldown flags too: they must have no effect.
    var logFlags: [String] {
        settingsFlags + ["--recordings", recordings.path, "--cooldown-seconds", "1", "--cooldown-store", cooldownStore.path]
    }

    /// The names of every file and folder under the directory.
    func files() -> [String] {
        FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
    }
}

/// The one place this suite launches a program (`noctule`, or a test of this harness): with the
/// test's environment, and with the test's temporary directory as its working directory. `noctule`
/// looks for `config/dev-scanner.env` upwards from its working directory; from the repository root
/// it would find the owner's real SDS200 there. From the temporary directory it finds none, so a
/// command that regressed into the network path (a `restart` or `listen` whose `--serial` refusal
/// broke) ends in "No scanner address", exit 2, and sends nothing anywhere.
private func launch(_ binary: URL, _ arguments: [String], _ dirs: SerialDirs,
                    environment: [String: String]? = nil) throws -> Subprocess {
    try Subprocess(binary, arguments, environment: environment ?? dirs.environment, currentDirectory: dirs.root)
}

/// Runs `noctule` with the test's environment (plus `extra`) to completion (killed after `limit`
/// seconds).
private func serialNoctule(_ arguments: [String], _ dirs: SerialDirs, limit: Double = 20,
                           extra: [String: String] = [:]) async throws
    -> (exited: Bool, status: Int32, stdout: String, stderr: String) {
    let process = try launch(try noctuleBinary(), arguments, dirs,
                             environment: dirs.environment.merging(extra) { _, new in new })
    let exited = await process.waitForExit(within: limit)
    process.kill()
    let result = await process.finish()
    return (exited, result.status, result.stdout, result.stderr)
}

/// Starts `noctule` with the test's environment and leaves it running.
private func startNoctule(_ arguments: [String], _ dirs: SerialDirs) throws -> Subprocess {
    try launch(try noctuleBinary(), arguments, dirs)
}

/// The directories from `directory` up to the root, as `noctule` searches them for
/// `config/dev-scanner.env`, with any that holds one.
private func devConfigsAbove(_ directory: URL) -> [String] {
    var components = directory.standardizedFileURL.pathComponents
    var found: [String] = []
    while !components.isEmpty {
        let candidate = NSString.path(withComponents: components + ["config", "dev-scanner.env"])
        if FileManager.default.fileExists(atPath: candidate) { found.append(candidate) }
        components.removeLast()
    }
    return found
}

/// Stops a running `noctule` with `signal` and returns its outcome (killed after `limit` seconds).
private func stop(_ process: Subprocess, with signal: Int32, limit: Double = 10) async
    -> (exited: Bool, status: Int32, stdout: String, stderr: String) {
    process.send(signal)
    let exited = await process.waitForExit(within: limit)
    process.kill()
    let result = await process.finish()
    return (exited, result.status, result.stdout, result.stderr)
}

/// Adds the USB station "Test Handheld" on `port` (the mock's link, which need not exist yet).
private func addUSBStation(_ dirs: SerialDirs, port: String) async throws {
    let add = try await serialNoctule(["station", "add", "--name", "Test Handheld", "--usb", "--serial-port", port]
                                      + dirs.settingsFlags, dirs)
    #expect(add.exited && add.status == 0, "\(add.stdout) \(add.stderr)")
}

private func lines(_ text: String, containing needle: String) -> [String] {
    text.components(separatedBy: "\n").filter { $0.contains(needle) }
}

@Suite(.timeLimit(.minutes(1))) struct SerialIntegrationTests {
    // MARK: The harness

    /// What keeps `listenAndRestartRefused` safe if the refusal it tests ever regresses: every
    /// program this suite launches runs in the test's temporary directory, where no
    /// `config/dev-scanner.env` can be found, so a `noctule` without `--host` has no scanner to talk
    /// to. Checked step by step, each a precondition of the next: the launched process's working
    /// directory, no config above it, and only then a `noctule info` with neither `--host` nor
    /// `--serial` (which, from the repository root, would talk to the real SDS200), which must end
    /// in the no-address hint, exit 2.
    @Test func harnessRunsWhereNoConfigIsFound() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let pwd = try launch(URL(fileURLWithPath: "/bin/pwd"), ["-P"], dirs)
        let exited = await pwd.waitForExit(within: 10)
        pwd.kill()
        let result = await pwd.finish()
        // `/bin/pwd -P` prints the physical path (`/private/var/…`), as `realpath` gives it.
        let expected = try #require(realpath(dirs.root.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        try #require(exited && result.status == 0, "\(result.stderr)")
        try #require(result.stdout == expected + "\n", "launched in \(result.stdout), not \(expected)")
        try #require(devConfigsAbove(dirs.root) == [], "a config file would be found: \(devConfigsAbove(dirs.root))")

        let info = try await serialNoctule(["info"], dirs, limit: 10)
        #expect(info.exited && info.status == 2, "\(info.status) \(info.stdout) \(info.stderr)")
        #expect(info.stderr.contains("No scanner address: pass --host or create config/dev-scanner.env"), "\(info.stderr)")
        #expect(info.stdout.isEmpty, "\(info.stdout)")
    }

    // MARK: Ports and refusals

    /// With the kill-switch set, `ports` finds nothing, even with a port in its listing.
    @Test func portsWithDetectionOff() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.decoy)
        do {
            let ports = try await serialNoctule(["ports"], dirs)
            #expect(ports.exited && ports.status == 0, "\(ports.stderr)")
            #expect(ports.stdout == noneFoundLine + "\n", "\(ports.stdout)")
            #expect(!ports.stdout.contains(dirs.decoy.path))
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == [])
    }

    @Test func serialWithHostRefused() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            let info = try await serialNoctule(["info", "--serial", mock.port, "--host", "127.0.0.1"], dirs)
            #expect(info.exited && info.status == 2, "\(info.status) \(info.stdout) \(info.stderr)")
            #expect(info.stderr.contains("--serial can't be combined with --host or --port"), "\(info.stderr)")
            #expect(info.stdout.isEmpty, "\(info.stdout)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(mock.commands == [], "\(result.stderr)")
    }

    /// Refused before anything is opened. Safe even if the refusal regressed: the harness runs
    /// `noctule` where no config file is found (`harnessRunsWhereNoConfigIsFound`), so `restart`
    /// and `listen` would end in "No scanner address" instead of reaching the real SDS200, and
    /// `listen` names a private cooldown record, never the shared one.
    @Test func listenAndRestartRefused() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            let listen = try await serialNoctule(["listen", "--serial", mock.port, "--seconds", "1", "--no-play",
                                                  "--cooldown-store", dirs.cooldownStore.path], dirs)
            #expect(listen.exited && listen.status == 2, "\(listen.status) \(listen.stderr)")
            #expect(listen.stderr.contains("listen: no audio over USB"), "\(listen.stderr)")
            let restart = try await serialNoctule(["restart", "--serial", mock.port, "--yes",
                                                   "--cooldown-store", dirs.cooldownStore.path], dirs)
            #expect(restart.exited && restart.status == 2, "\(restart.status) \(restart.stderr)")
            #expect(restart.stderr.contains("restart: not supported over USB"), "\(restart.stderr)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(mock.commands == [], "\(result.stderr)")
        #expect(!result.stderr.contains("MSM"), "\(result.stderr)")
    }

    /// An explicit path never falls back to a detected port (here the decoy, a live mock).
    @Test func missingExplicitPort() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let decoy = try await SerialMock.launch(link: dirs.decoy)
        do {
            let missing = dirs.root.appending(path: "no-such-port").path
            let info = try await serialNoctule(["info", "--serial", missing], dirs)
            #expect(info.exited && info.status == 2, "\(info.status) \(info.stdout) \(info.stderr)")
            #expect(info.stderr.contains("\(missing): no such port"), "\(info.stderr)")
            #expect(info.stdout.isEmpty, "\(info.stdout)")
        } catch {
            Issue.record(error)
        }
        let result = await decoy.shutdown()
        #expect(decoy.commands == [], "\(result.stderr)")
    }

    // MARK: info, status, display, watch

    @Test func infoOverSerial() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            let info = try await serialNoctule(["info", "--serial", mock.port], dirs)
            #expect(info.exited && info.status == 0, "\(info.stderr)")
            #expect(info.stdout.contains("model: SDS150"), "\(info.stdout)")
            #expect(info.stdout.contains("firmware: 1.01.02"), "\(info.stdout)")
            #expect(info.stdout.contains("battery: 100% (full)"), "\(info.stdout)")
            #expect(info.stderr.isEmpty, "\(info.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL", "VER", "VOL", "SQL", "GCS"], "\(mock.commands)")
    }

    /// `GCS` goes only to a model whose profile has charge status.
    @Test func infoSendsNoChargeStatusToOtherModels() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, ["--mdl-name", "SDS100"])
        do {
            let info = try await serialNoctule(["info", "--serial", mock.port], dirs)
            #expect(info.exited && info.status == 0, "\(info.stderr)")
            #expect(info.stdout.contains("model: SDS100"), "\(info.stdout)")
            #expect(!info.stdout.contains("battery"), "\(info.stdout)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(!mock.commands.contains("GCS"), "\(mock.commands)")
    }

    /// An unanswered `GCS` is a warning, not a failure, and is not asked again.
    @Test func infoWithoutABatteryAnswer() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, ["--fault", "drop-reply=GCS"])
        do {
            let info = try await serialNoctule(["info", "--serial", mock.port], dirs)
            #expect(info.exited && info.status == 0, "\(info.stderr)")
            #expect(info.stdout.hasPrefix("model: SDS150\nfirmware: 1.01.02\nvolume: "), "\(info.stdout)")
            #expect(lines(info.stdout, containing: "squelch: ").count == 1, "\(info.stdout)")
            #expect(!info.stdout.contains("battery"), "\(info.stdout)")
            #expect(lines(info.stderr, containing: "warning: no battery status (").count == 1, "\(info.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.filter { $0 == "GCS" }.count == 1, "\(mock.commands)")
    }

    @Test func statusAndDisplayOverSerial() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            let status = try await serialNoctule(["status", "--serial", mock.port], dirs)
            #expect(status.exited && status.status == 0, "\(status.stderr)")
            // The default scenario idles until 2 s, as the SDS150 does: stepping through conventional
            // channels, muted (`Mute="Mute"`); a transmission reports `Mute="Unmute"`.
            let idle = status.stdout.contains("system: County Roads\n")
            #expect(idle || status.stdout.contains("system: Riverbend County P25\n"), "\(status.stdout)")
            // `Sig` is what hit detection reads; `Mute` is shown beside it.
            #expect(status.stdout.contains("\nsignal: "), "\(status.stdout)")
            #expect(status.stdout.contains(idle ? "\nmuted: yes\n" : "\nmuted: no\n"), "\(status.stdout)")

            let display = try await serialNoctule(["display", "--serial", mock.port], dirs)
            #expect(display.exited && display.status == 0, "\(display.stderr)")
            #expect(display.stdout.contains("soft keys: SYSTEM | DEPT | CHANNEL"), "\(display.stdout)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["GSI", "STS"], "\(mock.commands)")
    }

    /// `menu` sends one `MSI` and nothing else; outside a menu the scanner answers a `TypeError`
    /// screen, which `menu` prints and exits 0 on.
    @Test func menuOverSerial() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            let menu = try await serialNoctule(["menu", "--serial", mock.port], dirs)
            #expect(menu.exited && menu.status == 0, "\(menu.stderr)")
            #expect(menu.stdout.contains("type: error"), "\(menu.stdout)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MSI"], "\(mock.commands)")
    }

    /// `quick-keys` over USB (design §5.3): `MDL`, then reads of the tree and its key states and
    /// nothing else (never a set, `KAL`, `MSM` or `POF`), on both handhelds.
    @Test(arguments: ["sds150", "sds100"])
    func quickKeysOverSerial(model: String) async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, model: model, ["--no-delays"])
        do {
            let run = try await serialNoctule(["quick-keys", "--serial", mock.port], dirs)
            #expect(run.exited && run.status == 0, "\(run.stderr)")
            #expect(run.stdout.components(separatedBy: "\n").first == "F0    on   Mock Police", "\(run.stdout)")
            #expect(run.stdout.contains("\n    D2    ?    Air Attack\n"), "\(run.stdout)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        let commands = mock.commands
        #expect(commands.first == "MDL", "\(commands)")
        for command in commands.dropFirst() {
            #expect(["GLT,", "FQK", "SQK,", "DQK,"].contains { command.hasPrefix($0) }, "\(command)")
            // A read has no 100 values after the key(s).
            #expect(command.split(separator: ",").count <= 3, "\(command)")
        }
        #expect(commands.dropFirst().sorted() == expectedQuickKeyReads, "\(commands)")
        for refused in ["KAL", "MSM", "POF", "GCS", "PSI"] {
            #expect(!commands.contains { $0.hasPrefix(refused) }, "\(refused) in \(commands)")
        }
    }

    /// A model without quick keys is refused after `MDL`: one line on stderr, exit 1, nothing else sent.
    @Test func quickKeysRefusedOnAModelWithoutThem() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, ["--mdl-name", "BCD436HP"])
        do {
            let run = try await serialNoctule(["quick-keys", "--serial", mock.port], dirs)
            #expect(run.exited && run.status == 1, "\(run.stderr)")
            #expect(run.stderr == "quick-keys: the BCD436HP has no quick keys\n", "\(run.stderr)")
            #expect(run.stdout.isEmpty, "\(run.stdout)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL"], "\(mock.commands)")
    }

    @Test func watchOverSerial() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            let watch = try await serialNoctule(["watch", "--serial", mock.port, "--count", "3"], dirs)
            #expect(watch.exited && watch.status == 0, "\(watch.stderr)")
            #expect(watch.stdout.split(separator: "\n").count == 3, "\(watch.stdout)")
            // Idle (the SDS150's conventional scan) or the first transmission.
            #expect(watch.stdout.contains("County Roads / ") || watch.stdout.contains("Riverbend County P25"),
                    "\(watch.stdout)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL", "PSI,500", "PSI,0"], "\(mock.commands)")
    }

    // MARK: The push keep-alive

    /// The mock's pushes stop 1.5 s after the `PSI` unless a `KAL` restarts the count (as on
    /// hardware for an hour; that each `KAL` restarts the full count is the mock's assumption).
    /// With the test override's 0.4 s keep-alive, `watch`
    /// runs past that (20 updates at 200 ms is 4 s) and reaches its count; without one it would
    /// stall (5 s with no update).
    @Test func watchKeepsPushingPastTheLifetime() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, ["--push-lifetime", "1.5"])
        do {
            let watch = try await serialNoctule(["watch", "--serial", mock.port, "--interval", "200", "--count", "20"],
                                                dirs, extra: ["NOCTULE_TEST_KEEPALIVE_SECONDS": "0.4"])
            #expect(watch.exited && watch.status == 0, "\(watch.status) \(watch.stderr)")
            #expect(watch.stdout.split(separator: "\n").count == 20, "\(watch.stdout)")
            #expect(watch.stderr == "noctule: test override: NOCTULE_TEST_KEEPALIVE_SECONDS=0.4 (in place of the "
                + "model's keep-alive interval; a model without a keep-alive, or a network scanner, still gets none)\n",
                    "\(watch.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        let commands = mock.commands
        #expect(Array(commands.prefix(2)) == ["MDL", "PSI,200"], "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(commands.dropFirst(2).dropLast().allSatisfy { $0 == "KAL" }, "\(commands)")
        #expect(commands.filter { $0 == "KAL" }.count >= 4, "\(commands)")
    }

    /// Without the override the keep-alive is the SDS150's 60 s: a short `watch` sends none.
    @Test func watchWithoutTheOverrideSendsNoKeepAliveInAShortRun() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            let watch = try await serialNoctule(["watch", "--serial", mock.port, "--interval", "100", "--count", "5"], dirs)
            #expect(watch.exited && watch.status == 0, "\(watch.status) \(watch.stderr)")
            #expect(watch.stderr == "", "\(watch.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL", "PSI,100", "PSI,0"], "\(mock.commands)")
    }

    /// `log` on a USB station runs past the mock's lifetime with no stall warning, and the mock
    /// saw `KAL`s, the last command `PSI,0`.
    @Test func logKeepsPushingPastTheLifetime() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, ["--scenario", dirs.scenario.path, "--push-lifetime", "1.5"])
        do {
            try await addUSBStation(dirs, port: mock.port)
            let log = try await serialNoctule(["log", "--seconds", "6"] + dirs.logFlags, dirs, limit: 30,
                                              extra: ["NOCTULE_TEST_KEEPALIVE_SECONDS": "0.4"])
            #expect(log.exited && log.status == 0, "\(log.status) \(log.stdout) \(log.stderr)")
            #expect(log.stderr.hasPrefix("noctule: test override: NOCTULE_TEST_KEEPALIVE_SECONDS=0.4 "), "\(log.stderr)")
            #expect(!log.stderr.contains("warning:"), "\(log.stderr)")
            #expect(!log.stderr.contains("stopped sending updates"), "\(log.stderr)")
            #expect(!log.stderr.contains("subscribing again"), "\(log.stderr)")
            // Hits all through the 6 s (one scenario pass is 3.5 s, two transmissions each).
            #expect(lines(log.stdout, containing: "  + ").count >= 3, "\(log.stdout)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        let commands = mock.commands
        #expect(commands.first == "MDL" && commands.last == "PSI,0", "\(commands)")
        #expect(commands.filter { $0 == "KAL" }.count >= 6, "\(commands)")
        let stop = try #require(commands.lastIndex(of: "PSI,0"))
        #expect(!commands[stop...].contains("KAL"), "\(commands)")
    }

    /// The pushes stop (a 1 s lifetime) before the first `KAL` (2 s), and the mock ignores a `KAL`
    /// after they stopped: `log` says the scanner is connected but not sending, waits, reconnects
    /// with a fresh `PSI`, and runs to the end; no subscription is left running.
    @Test func logReplacesADeadSubscription() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, ["--scenario", dirs.scenario.path, "--push-lifetime", "1",
                                                                 "--kal-after-expiry", "ignored"])
        do {
            try await addUSBStation(dirs, port: mock.port)
            let log = try await serialNoctule(["log", "--seconds", "8"] + dirs.logFlags, dirs, limit: 30,
                                              extra: ["NOCTULE_TEST_KEEPALIVE_SECONDS": "2"])
            #expect(log.exited && log.status == 0, "\(log.status) \(log.stdout) \(log.stderr)")
            #expect(log.stderr.contains("log: scanner disconnected. The scanner is connected but isn't sending status updates.\n"
                                        + "log: waiting for the scanner…\n"), "\(log.stderr)")
            #expect(log.stderr.contains("log: reconnected SDS150 1.01.02"), "\(log.stderr)")
            #expect(log.stderr.contains("warning: the scanner stopped sending status updates; subscribing again"),
                    "\(log.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        let commands = mock.commands.filter { $0 != "KAL" }
        #expect(Array(commands.prefix(5)) == ["MDL", "VER", "PSI,100", "PSI,0", "MDL"], "\(mock.commands)")
        #expect(commands.last == "PSI,0", "\(mock.commands)")
    }

    // MARK: An SDS100 (Plan 17 Task 6)
    //
    // The SDS100 has no `KAL`: its keep-alive is a repeated `PSI,<ms>`, every 60 s (here 0.5 s, by
    // `NOCTULE_TEST_KEEPALIVE_SECONDS`, against a mock whose pushes stop 2 s after the latest
    // `PSI`). It has no battery status either. None of these may send it `KAL`, `GCS`, `MSM`,
    // `POF`, `KEY` or `MSV`.

    private let sds100Override = ["NOCTULE_TEST_KEEPALIVE_SECONDS": "0.5"]

    /// What nothing here may send an SDS100.
    private func sds100Forbidden(_ commands: [String]) -> [String] {
        commands.filter { command in ["KAL", "GCS", "MSM", "POF", "KEY", "MSV"].contains { command.hasPrefix($0) } }
    }

    @Test func sds100Info() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, model: "sds100")
        do {
            let info = try await serialNoctule(["info", "--serial", mock.port], dirs)
            #expect(info.exited && info.status == 0, "\(info.stderr)")
            #expect(info.stdout.hasPrefix("model: SDS100\nfirmware: 1.26.01\nvolume: "), "\(info.stdout)")
            #expect(lines(info.stdout, containing: "squelch: ").count == 1, "\(info.stdout)")
            #expect(!info.stdout.contains("battery"), "\(info.stdout)")
            #expect(info.stderr.isEmpty, "\(info.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL", "VER", "VOL", "SQL"], "\(mock.commands)")
    }

    @Test func sds100StatusDisplayAndMenu() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, model: "sds100")
        do {
            let status = try await serialNoctule(["status", "--serial", mock.port], dirs)
            #expect(status.exited && status.status == 0, "\(status.stderr)")
            #expect(status.stdout.contains("\nsignal: "), "\(status.stdout)")
            #expect(status.stdout.contains("\nmuted: "), "\(status.stdout)")

            let display = try await serialNoctule(["display", "--serial", mock.port], dirs)
            #expect(display.exited && display.status == 0, "\(display.stderr)")
            #expect(display.stdout.contains("soft keys: "), "\(display.stdout)")

            // Outside a menu the scanner describes a `TypeError` screen, which `menu` prints.
            let menu = try await serialNoctule(["menu", "--serial", mock.port], dirs)
            #expect(menu.exited && menu.status == 0, "\(menu.stderr)")
            #expect(menu.stdout.contains("type: error"), "\(menu.stdout)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["GSI", "STS", "MSI"], "\(mock.commands)")
    }

    /// The mock's pushes stop 2 s after the latest `PSI`; renewing the subscription's own
    /// `PSI,200` every 0.5 s takes `watch` through 40 updates (8 s), where without renewals it
    /// would stall. Nothing but `PSI,200` goes out between the first and the last command.
    @Test func sds100WatchKeepsPushingPastTheLifetime() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, model: "sds100", ["--push-lifetime", "2"])
        do {
            let watch = try await serialNoctule(["watch", "--serial", mock.port, "--interval", "200", "--count", "40"],
                                                dirs, extra: sds100Override)
            #expect(watch.exited && watch.status == 0, "\(watch.status) \(watch.stderr)")
            #expect(watch.stdout.split(separator: "\n").count == 40, "\(watch.stdout)")
            #expect(watch.stderr.hasPrefix("noctule: test override: NOCTULE_TEST_KEEPALIVE_SECONDS=0.5 "), "\(watch.stderr)")
            #expect(!watch.stderr.contains("no PSI updates"), "\(watch.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        let commands = mock.commands
        #expect(Array(commands.prefix(2)) == ["MDL", "PSI,200"], "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(commands.dropFirst(1).dropLast().allSatisfy { $0 == "PSI,200" }, "\(commands)")
        #expect(commands.filter { $0 == "PSI,200" }.count >= 5, "\(commands)")
        #expect(!commands.contains("PSI,100"), "\(commands)")
        #expect(sds100Forbidden(commands) == [], "\(commands)")
    }

    /// With no renewal (the 60 s default never falls due in this run) the same mock's pushes stop
    /// after 2 s and `watch` stalls, naming the port, and still ends the subscription.
    @Test func sds100WatchWithoutRenewalsStalls() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, model: "sds100", ["--push-lifetime", "2"])
        do {
            let watch = try await serialNoctule(["watch", "--serial", mock.port, "--interval", "200", "--count", "40"],
                                                dirs)
            #expect(watch.exited && watch.status == 1, "\(watch.status) \(watch.stderr)")
            #expect(watch.stderr.contains("no PSI updates from \(mock.port) for 5 s"), "\(watch.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        let commands = mock.commands
        #expect(commands == ["MDL", "PSI,200", "PSI,0"], "\(commands)")
    }

    /// `log` on a USB station that is an SDS100 runs past the mock's lifetime with no stall or
    /// resubscribe, renewing its `PSI,100`; `PSI,0` is last and no cooldown record appears.
    @Test func sds100LogKeepsPushingPastTheLifetime() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, model: "sds100", ["--push-lifetime", "2"])
        do {
            try await addUSBStation(dirs, port: mock.port)
            let log = try await serialNoctule(["log", "--seconds", "8"] + dirs.logFlags, dirs, limit: 30,
                                              extra: sds100Override)
            #expect(log.exited && log.status == 0, "\(log.status) \(log.stdout) \(log.stderr)")
            #expect(log.stderr.contains("log: connected to SDS100 (firmware 1.26.01)\nlog: no audio over USB\n"),
                    "\(log.stderr)")
            #expect(!log.stderr.contains("warning:"), "\(log.stderr)")
            #expect(!log.stderr.contains("subscribing again"), "\(log.stderr)")
            #expect(!log.stderr.contains("disconnected"), "\(log.stderr)")
            let files = dirs.files()
            #expect(!files.contains { $0.contains("cooldown") }, "\(files)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        let commands = mock.commands
        #expect(Array(commands.prefix(3)) == ["MDL", "VER", "PSI,100"], "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(commands.filter { $0 == "PSI,100" }.count >= 6, "\(commands)")
        #expect(commands.filter { $0 == "PSI,0" }.count == 1, "\(commands)")
        #expect(sds100Forbidden(commands) == [], "\(commands)")
    }

    /// A stall names the port, and still ends the subscription.
    @Test func watchStallNamesThePort() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, ["--fault", "stall-psi=1"])
        do {
            let watch = try await serialNoctule(["watch", "--serial", mock.port, "--count", "10"], dirs)
            #expect(watch.exited && watch.status == 1, "\(watch.status) \(watch.stderr)")
            #expect(watch.stderr.contains("no PSI updates from \(mock.port) for 5 s"), "\(watch.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.last == "PSI,0", "\(mock.commands)")
    }

    /// Runs `watch` until its first line, stops it with `signal`, and checks the exit status and
    /// that the subscription ended (`PSI,0`; the mock's `active-subscriptions=0`).
    private func watchStops(on signal: Int32, status expected: Int32) async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            let watch = try startNoctule(["watch", "--serial", mock.port], dirs)
            let watching = await watch.waitForOutput(within: 10) { !$0.isEmpty }
            #expect(watching, "\(watch.stderr)")
            let result = await stop(watch, with: signal)
            #expect(result.exited && result.status == expected, "\(result.status) \(result.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.last == "PSI,0", "\(mock.commands)")
    }

    @Test func watchSigintTidies() async throws {
        try await watchStops(on: SIGINT, status: 130)
    }

    @Test(arguments: [(SIGTERM, Int32(143)), (SIGHUP, Int32(129))])
    func watchTerminationSignalsTidy(_ signal: Int32, _ status: Int32) async throws {
        try await watchStops(on: signal, status: status)
    }

    /// While `watch` holds the port, `info` is refused: nothing is sent from it.
    @Test func busyPort() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            let watch = try startNoctule(["watch", "--serial", mock.port], dirs)
            let watching = await watch.waitForOutput(within: 10) { !$0.isEmpty }
            #expect(watching, "\(watch.stderr)")
            let info = try await serialNoctule(["info", "--serial", mock.port], dirs)
            #expect(info.exited && info.status == 1, "\(info.status) \(info.stdout) \(info.stderr)")
            #expect(info.stderr.contains("\(mock.port) is in use by another program."), "\(info.stderr)")
            #expect(info.stdout.isEmpty, "\(info.stdout)")
            let result = await stop(watch, with: SIGINT)
            #expect(result.exited && result.status == 130, "\(result.status) \(result.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL", "PSI,500", "PSI,0"], "\(mock.commands)")
    }

    // MARK: Stations and log

    @Test func stationAddAndListUSB() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let port = dirs.link.path
        let add = try await serialNoctule(["station", "add", "--name", "Test Handheld", "--usb", "--serial-port", port]
                                          + dirs.settingsFlags, dirs)
        #expect(add.exited && add.status == 0, "\(add.stderr)")
        #expect(add.stdout == "added station \"Test Handheld\" (USB \(port), save audio: every)\n", "\(add.stdout)")

        let other = try await serialNoctule(["station", "add", "--name", "Other Handheld", "--usb"] + dirs.settingsFlags, dirs)
        #expect(other.exited && other.status == 0, "\(other.stderr)")
        #expect(other.stdout == "added station \"Other Handheld\" (USB, save audio: every)\n", "\(other.stdout)")

        let list = try await serialNoctule(["station", "list"] + dirs.settingsFlags, dirs)
        #expect(list.exited && list.status == 0, "\(list.stderr)")
        #expect(list.stdout == "  Test Handheld  USB \(port)  save audio: every\n  Other Handheld  USB  save audio: every\n",
                "\(list.stdout)")
        let device = (try? String(contentsOf: dirs.settings.appending(path: "device.json"), encoding: .utf8)) ?? ""
        #expect(device.contains("\"usbPort\""), "\(device)")
    }

    @Test func logOverSerial() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link, ["--scenario", dirs.scenario.path])
        do {
            try await addUSBStation(dirs, port: mock.port)
            let log = try await serialNoctule(["log", "--seconds", "6"] + dirs.logFlags, dirs, limit: 30)
            #expect(log.exited && log.status == 0, "\(log.status) \(log.stdout) \(log.stderr)")
            #expect(log.stderr.contains("log: connected to SDS150 (firmware 1.01.02)\nlog: no audio over USB\n"),
                    "\(log.stderr)")
            #expect(lines(log.stderr, containing: "log: no audio over USB").count == 1, "\(log.stderr)")
            let starts = lines(log.stdout, containing: "  + ")
            let ends = lines(log.stdout, containing: "  - ")
            #expect(starts.count >= 2 && starts.count == ends.count, "\(log.stdout)")
            #expect(starts.contains { $0.contains("TG3301 County Roads") }, "\(log.stdout)")
            #expect(starts.contains { $0.contains("155.4321MHz Lakeview Marina") }, "\(log.stdout)")
            #expect(!log.stdout.contains("→"), "\(log.stdout)")
            #expect(!log.stderr.contains("audio:"), "\(log.stderr)")
            #expect(!log.stderr.contains("warning:"), "\(log.stderr)")
            // No cooldown record or lock, and no recordings, anywhere in the test's directory.
            let files = dirs.files()
            #expect(!files.contains { $0.contains("cooldown") }, "\(files)")
            #expect(!FileManager.default.fileExists(atPath: dirs.recordings.path), "\(files)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.first == "MDL" && mock.commands.last == "PSI,0", "\(mock.commands)")
        #expect(!mock.commands.contains { $0.hasPrefix("MSM") || $0.hasPrefix("POF") }, "\(mock.commands)")
    }

    /// A USB station never waits on, reads or writes the RTSP cooldown record, even one that holds
    /// a host (a hand-edited file) whose record says to wait.
    @Test func logOverSerialNeverWaitsOnTheCooldown() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            try await addUSBStation(dirs, port: mock.port)
            let url = dirs.settings.appending(path: "stations.json")
            var file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var stations = try #require(file["stations"] as? [[String: Any]])
            var connection = try #require(stations[0]["connection"] as? [String: Any])
            connection["host"] = "127.0.0.1"
            stations[0]["connection"] = connection
            file["stations"] = stations
            try JSONSerialization.data(withJSONObject: file).write(to: url)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let seed = Data("{\"127.0.0.1\":{\"lastClosed\":\"\(format.string(from: Date()))\"}}".utf8)
            try seed.write(to: dirs.cooldownStore)

            let flags = dirs.settingsFlags + ["--recordings", dirs.recordings.path, "--cooldown-seconds", "60",
                                              "--cooldown-store", dirs.cooldownStore.path]
            let log = try await serialNoctule(["log", "--seconds", "2"] + flags, dirs, limit: 20)
            #expect(log.exited && log.status == 0, "\(log.status) \(log.stderr)")
            #expect(log.stderr.contains("log: connected to SDS150"), "\(log.stderr)")
            #expect(!log.stderr.contains("waiting"), "\(log.stderr)")
            #expect(try Data(contentsOf: dirs.cooldownStore) == seed)
            #expect(!FileManager.default.fileExists(atPath: dirs.cooldownStore.path + ".lock"), "\(dirs.files())")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
    }

    /// The scanner goes away for two seconds and comes back: `log` says so, waits, reconnects and
    /// logs again. The station is added before the mock starts, so `log` connects (and gets a
    /// push) well before the unplug two seconds after the mock's start.
    @Test func logResumes() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        try await addUSBStation(dirs, port: dirs.link.path)
        let mock = try await SerialMock.launch(link: dirs.link, ["--scenario", dirs.scenario.path, "--fault", "unplug=2:2"])
        do {
            let log = try startNoctule(["log", "--seconds", "10"] + dirs.logFlags, dirs)
            let reconnected = await log.waitForStderr(within: 15) { $0.contains("log: reconnected") }
            #expect(reconnected, "\(log.stderr)")
            let startsAtReconnect = lines(log.stdout, containing: "  + ").count
            let hitAfter = await log.waitForOutput(within: 8) { lines($0, containing: "  + ").count > startsAtReconnect }
            #expect(hitAfter, "\(log.stdout)")
            let exited = await log.waitForExit(within: 15)
            log.kill()
            let result = await log.finish()
            #expect(exited && result.status == 0, "\(result.status) \(result.stderr)")
            #expect(result.stderr.contains("log: scanner disconnected. \(hint)\nlog: waiting for the scanner…\n"),
                    "\(result.stderr)")
            #expect(result.stderr.contains("log: reconnected SDS150 1.01.02"), "\(result.stderr)")
            #expect(lines(result.stderr, containing: "log: no audio over USB").count == 1, "\(result.stderr)")
            #expect(!result.stderr.contains("warning:"), "\(result.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.filter { $0 == "MDL" }.count == 2, "\(mock.commands)")
    }

    /// The scanner goes away for good: a stop signal during the wait exits at once.
    @Test func logSigtermDuringWait() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        try await addUSBStation(dirs, port: dirs.link.path)
        let mock = try await SerialMock.launch(link: dirs.link, ["--fault", "unplug=2"])
        do {
            let log = try startNoctule(["log"] + dirs.logFlags, dirs)
            let waiting = await log.waitForStderr(within: 15) { $0.contains("log: waiting for the scanner…") }
            #expect(waiting, "\(log.stderr)")
            let result = await stop(log, with: SIGTERM, limit: 2)
            #expect(result.exited && result.status == 143, "\(result.status) \(result.stderr)")
            #expect(result.stderr.contains("log: scanner disconnected. \(hint)"), "\(result.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL", "VER", "PSI,100"], "\(mock.commands)")
    }

    /// `--seconds` running out while `log` waits for the scanner is a normal end: exit 0.
    @Test func logSecondsRunOutDuringWait() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        try await addUSBStation(dirs, port: dirs.link.path)
        let mock = try await SerialMock.launch(link: dirs.link, ["--fault", "unplug=2"])
        do {
            let log = try await serialNoctule(["log", "--seconds", "5"] + dirs.logFlags, dirs, limit: 15)
            #expect(log.exited && log.status == 0, "\(log.status) \(log.stderr)")
            #expect(log.stderr.contains("log: scanner disconnected. \(hint)\nlog: waiting for the scanner…\n"),
                    "\(log.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL", "VER", "PSI,100"], "\(mock.commands)")
    }

    /// The per-station lock holds for a USB station too: a second `log` on it sends nothing.
    @Test func secondLogOnAUSBStationRefused() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            try await addUSBStation(dirs, port: mock.port)
            let first = try startNoctule(["log"] + dirs.logFlags, dirs)
            let connected = await first.waitForStderr(within: 10) { $0.contains("log: no audio over USB") }
            #expect(connected, "\(first.stderr)")
            let second = try await serialNoctule(["log", "--seconds", "2"] + dirs.logFlags, dirs, limit: 10)
            #expect(second.exited && second.status == 1, "\(second.status) \(second.stderr)")
            #expect(second.stderr.contains(
                "log: Test Handheld is open in another Noctule Scan process (pid \(first.process.processIdentifier))"),
                "\(second.stderr)")
            #expect(!second.stderr.contains("in use by another program"), "\(second.stderr)")
            let result = await stop(first, with: SIGINT)
            #expect(result.exited && result.status == 130, "\(result.status) \(result.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.filter { $0 == "MDL" }.count == 1, "\(mock.commands)")
    }

    /// Stop signals while `log` runs end the subscription (`PSI,0`) and exit 128 + signo.
    @Test(arguments: [(SIGINT, Int32(130)), (SIGHUP, Int32(129)), (SIGTERM, Int32(143))])
    func logStopSignalsTidy(_ signal: Int32, _ status: Int32) async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            try await addUSBStation(dirs, port: mock.port)
            let log = try startNoctule(["log"] + dirs.logFlags, dirs)
            let connected = await log.waitForStderr(within: 10) { $0.contains("log: no audio over USB") }
            #expect(connected, "\(log.stderr)")
            try? await Task.sleep(for: .milliseconds(700))  // a push or two
            let result = await stop(log, with: signal)
            #expect(result.exited && result.status == status, "\(result.status) \(result.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands.last == "PSI,0", "\(mock.commands)")
    }

    /// A connection that never delivered a push isn't resumed: `log` reports the disconnect and the
    /// runner's warning, says nothing about waiting, and exits 1.
    @Test func logExitsWhenTheScannerWontBeResumed() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        try await addUSBStation(dirs, port: dirs.link.path)
        let mock = try await SerialMock.launch(link: dirs.link, ["--fault", "stall-psi=0", "--fault", "unplug=2"])
        do {
            let log = try await serialNoctule(["log", "--seconds", "30"] + dirs.logFlags, dirs, limit: 15)
            #expect(log.exited && log.status == 1, "\(log.status) \(log.stderr)")
            #expect(log.stderr.contains("log: scanner disconnected. \(hint)\n"), "\(log.stderr)")
            #expect(log.stderr.contains(
                "warning: the scanner isn't sending status updates; not reconnecting by itself"), "\(log.stderr)")
            #expect(!log.stderr.contains("waiting"), "\(log.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL", "VER", "PSI,100"], "\(mock.commands)")
    }

    /// A USB station whose port isn't there fails at once with the hint, and never takes a port
    /// from the listing (here a live decoy mock): the kill-switch reaches `log`'s transport factory.
    @Test func logWithoutItsPortExitsAtOnce() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        try await addUSBStation(dirs, port: dirs.link.path)  // nothing there
        let decoy = try await SerialMock.launch(link: dirs.decoy)
        do {
            let log = try await serialNoctule(["log", "--seconds", "30"] + dirs.logFlags, dirs, limit: 10)
            #expect(log.exited && log.status == 1, "\(log.status) \(log.stderr)")
            #expect(log.stderr.contains(hint), "\(log.stderr)")
            #expect(!log.stderr.contains("waiting"), "\(log.stderr)")
            #expect(!log.stderr.contains("log: connected"), "\(log.stderr)")
        } catch {
            Issue.record(error)
        }
        let result = await decoy.shutdown()
        #expect(decoy.commands == [], "\(result.stderr)")
    }

    @Test func logBusyPort() async throws {
        let dirs = try SerialDirs()
        defer { dirs.cleanUp() }
        let mock = try await SerialMock.launch(link: dirs.link)
        do {
            try await addUSBStation(dirs, port: mock.port)
            let watch = try startNoctule(["watch", "--serial", mock.port], dirs)
            let watching = await watch.waitForOutput(within: 10) { !$0.isEmpty }
            #expect(watching, "\(watch.stderr)")
            let log = try await serialNoctule(["log", "--seconds", "5"] + dirs.logFlags, dirs, limit: 10)
            #expect(log.exited && log.status == 1, "\(log.status) \(log.stderr)")
            #expect(log.stderr.contains("\(mock.port) is in use by another program."), "\(log.stderr)")
            #expect(!log.stderr.contains("log: connected"), "\(log.stderr)")
            let result = await stop(watch, with: SIGINT)
            #expect(result.exited && result.status == 130, "\(result.status) \(result.stderr)")
        } catch {
            Issue.record(error)
        }
        await mock.shutdown()
        #expect(mock.commands == ["MDL", "PSI,500", "PSI,0"], "\(mock.commands)")
    }
}
