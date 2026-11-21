// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Dispatch
import Foundation
import Synchronization
import NoctuleCLICore
import NoctuleKit
import NoctuleStore

// Thin shell around NoctuleCLICore. Read-only (MDL, VER, VOL, SQL, GSI, STS, GCS, and PSI
// start/stop), except `listen` (one RTSP audio session, always torn down; ListenCommand.swift; or,
// with `--station` on a USB station, its line-in alone, with no scanner traffic; LineInListen.swift),
// `log` (a StationRunner: PSI pushes and, on a network station, one RTSP session, always stopped;
// LogCommand.swift), and `restart` (MSM,1 after explicit confirmation; RestartCommand.swift).
// `log` on a USB station with a line-in also records from its audio input (LineInSupport.swift;
// under NOCTULE_NO_USB_DETECTION no audio input is listed or opened).
// `station` and `hits` only touch local files (StationCommand.swift, HitsCommand.swift; `station add
// --audio-input` reads the input list); `ports` and `audio-inputs` only list, opening no port or
// input (PortsCommand.swift, AudioInputsCommand.swift). With `--serial`, `info`, `status`, `display`
// and `watch` talk to a USB scanner over its serial port instead of the network scanner.

// A closed stdout or stderr pipe must not kill the process mid-session (a leaked RTSP session,
// or a PSI push left running). With SIGPIPE ignored, writes to a closed pipe just fail.
signal(SIGPIPE, SIG_IGN)

/// `fputs`, not `FileHandle.write(_: Data)`, which raises on a closed pipe.
func printErr(_ text: String) {
    fputs(text + "\n", stderr)
}

let invocation: CLIInvocation
do {
    invocation = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIUsageError {
    printErr(error.description)
    exit(64)
} catch {
    printErr("\(error)")
    exit(64)
}

// `--serial` with `--host`/`--port`, on `listen` or on `restart`: refused before anything is opened.
if let problem = CLIArguments.serialProblem(invocation) {
    printErr("noctule: \(problem)")
    exit(2)
}
// `listen --station` with an address, or `--meter` with no station: refused before anything is read.
if let problem = CLIArguments.listenProblem(invocation) {
    printErr(problem)
    exit(2)
}

/// The environment `USBDetection` reads, once: the port listing below and a bare `--serial`.
let environment = ProcessInfo.processInfo.environment
// `NOCTULE_TRACE`: a command trace on stderr, for diagnosing a real scanner (read-only; honoured always).
if CommandTrace.isRequested(environment) {
    CommandTrace.install { printErr("noctule: trace \($0)") }
    printErr("noctule: trace on (NOCTULE_TRACE)")
}
/// The one port listing every command uses (`ports`, a bare `--serial`, `log`'s transport factory):
/// IOKit's, or none at all when `NOCTULE_NO_USB_DETECTION` is set (`USBDetection`).
let usbPorts = USBDetection.listing(environment: environment, system: IOKitSerialPortFinder())
// A test-only listing in effect redirects where `--serial` and `log` may go: say so, as the app does.
for note in USBDetection.overrideNotes(environment) { printErr("noctule: test override: \(note)") }
// The test-only keep-alive interval (`watch` and `log` on a USB scanner; only with the kill-switch
// set): say so too, or that it is ignored.
for note in KeepAliveOverride.notes(environment) { printErr("noctule: test override: \(note)") }

// The test-only line-in stream (`NOCTULE_TEST_LINE_IN`, only with the kill-switch set) redirects every
// line-in a station or `listen` would open: say so, once, for the commands that reach one.
switch invocation.command {
case .audioInputs, .station, .log, .listen:
    for note in LineInDetection.overrideNotes(environment, privateSettings: false, app: false) {
        printErr("noctule: test override: \(note)")
    }
default:
    break
}

let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// `--cooldown-seconds` is mock-only: refuse it without a private store, before anything else.
switch invocation.command {
case .listen, .log:
    if let problem = CLIArguments.cooldownOverrideProblem(invocation) {
        printErr("noctule: \(problem)")
        exit(2)
    }
default:
    break
}

// Stations, the hit log, audio, and restart run on their own paths (with their own signal handling) and never reach
// the control-only client below.
switch invocation.command {
case .ports:
    exit(PortsCommand.run(ports: usbPorts))
case .audioInputs:
    exit(AudioInputsCommand.run(listing: LineInSupport.listing(for: LineInSupport.selection(environment: environment))))
case .station(let action):
    exit(await StationCommand.run(action, settingsDirectory: StationCLI.settingsDirectory(invocation.settingsDir)))
case .hits(let options):
    exit(await HitsCommand.run(options, settingsDirectory: StationCLI.settingsDirectory(invocation.settingsDir)))
case .log(let station, let seconds):
    let lineInSelection = LineInSupport.selection(environment: environment)
    let lineInDisabled: Bool
    if case .disabled = lineInSelection { lineInDisabled = true } else { lineInDisabled = false }
    exit(await LogCommand.run(LogOptions(
        station: station, seconds: seconds,
        settingsDirectory: StationCLI.settingsDirectory(invocation.settingsDir),
        recordingsRoot: StationCLI.recordingsRoot(invocation.recordings),
        cooldown: .milliseconds(Int64(((invocation.cooldownSeconds ?? 120) * 1000).rounded())),
        cooldownStoreURL: invocation.cooldownStore.map { URL(fileURLWithPath: $0) } ?? FileRTSPCooldownStore.defaultURL,
        ports: usbPorts, keepAliveInterval: KeepAliveOverride.interval(environment),
        lineInSources: LineInSupport.factory(for: lineInSelection), lineInDisabled: lineInDisabled)))
case .listen(let record, let seconds, let play, let stationName, let meter):
    let options = ListenOptions(record: record, seconds: seconds, play: play)
    let cooldownStoreURL = invocation.cooldownStore.map { URL(fileURLWithPath: $0) } ?? FileRTSPCooldownStore.defaultURL
    // `--station`: a network station's address, or a USB station's line-in alone (its audio input,
    // never its serial port, and no station lock).
    if let stationName {
        exit(await ListenCommand.runStation(
            named: stationName, options: options, meter: meter, invocation: invocation,
            settingsDirectory: StationCLI.settingsDirectory(invocation.settingsDir), cooldownStoreURL: cooldownStoreURL,
            lineInSources: LineInSupport.factory(for: LineInSupport.selection(environment: environment))))
    }
    guard let target = resolveAudioTarget(invocation: invocation, searchingFrom: currentDirectory) else {
        printErr("No scanner address: pass --host or create config/dev-scanner.env (see config/dev-scanner.env.example)")
        exit(2)
    }
    let network = NetworkListenOptions(
        target: target,
        cooldownPolicy: ListenFormat.cooldownPolicy(cooldownSeconds: invocation.cooldownSeconds,
                                                    reconnectCooldown: invocation.reconnectCooldown),
        cooldownStoreURL: cooldownStoreURL)
    exit(await ListenCommand.run(options, network: network))
case .restart(let confirmed):
    guard let target = resolveAudioTarget(invocation: invocation, searchingFrom: currentDirectory) else {
        printErr("No scanner address: pass --host or create config/dev-scanner.env (see config/dev-scanner.env.example)")
        exit(2)
    }
    exit(await RestartCommand.run(
        target: target, confirmed: confirmed,
        cooldownStoreURL: invocation.cooldownStore.map { URL(fileURLWithPath: $0) } ?? FileRTSPCooldownStore.defaultURL))
default:
    break
}
// The scanner: the USB serial port with `--serial` (decided by the flag alone; design §5), else the
// network scanner as always.
let transport: any ScannerTransport
/// How messages name the scanner: `host:port`, or the serial port's path.
let targetName: String
if invocation.serial != nil {
    // An explicit path (the flag's, or SCANNER_SERIAL) is used as given; only a bare `--serial`
    // looks at the listing. With USB detection off, a bare `--serial` finds nothing at all.
    let resolution = resolveSerial(invocation: invocation, searchingFrom: currentDirectory,
                                   ports: invocation.serial == .auto ? usbPorts.unidenPorts() : [],
                                   exists: { FileManager.default.fileExists(atPath: $0) },
                                   environment: environment)
    guard case .found(let path, _) = resolution else {
        (CLIFormat.serialResolutionFailure(resolution) ?? []).forEach(printErr)
        exit(2)
    }
    transport = SerialTransport(path: path)
    targetName = path
} else {
    guard let target = resolveHost(invocation: invocation, searchingFrom: currentDirectory) else {
        printErr("No scanner address: pass --host or create config/dev-scanner.env (see config/dev-scanner.env.example)")
        exit(2)
    }
    transport = UDPTransport(host: target.host, port: target.port)
    targetName = "\(target.host):\(target.port)"
}

let client = ScannerClient(transport: transport)
/// The first stop signal received, if any.
final class InterruptFlag: Sendable {
    private let value = Mutex<Int32?>(nil)
    func set(_ signal: Int32) { value.withLock { if $0 == nil { $0 = signal } } }
    var isSet: Bool { value.withLock { $0 != nil } }
    /// 128 + the signal's number (130 for SIGINT, 143 for SIGTERM, 129 for SIGHUP).
    var exitCode: Int32? { value.withLock { $0.map { 128 + $0 } } }
}
let interrupted = InterruptFlag()

// Ignore the stop signals' default action (SIGINT, SIGTERM, SIGHUP; `stopSignals`) so dispatch
// sources can run an orderly shutdown: disconnect() sends PSI,0 if a push is active, then
// closes the transport.
//
// The handlers run on a global queue, so they must not touch main.swift top-level globals:
// under Swift 6 those are @MainActor-isolated, which would make the closure @MainActor and
// trap in the runtime's executor check when libdispatch calls it off the main queue.
// installStopSignalHandlers is a nonisolated function whose closures capture only Sendable
// values passed in as parameters.
func installStopSignalHandlers(client: ScannerClient, interrupted: InterruptFlag) -> [DispatchSourceSignal] {
    stopSignals.map { signo in
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
        source.setEventHandler { @Sendable in
            interrupted.set(signo)
            Task { @Sendable in
                await client.disconnect()
                exit(interrupted.exitCode ?? 128 + signo)
            }
        }
        source.resume()
        return source
    }
}
let signalSources = installStopSignalHandlers(client: client, interrupted: interrupted)

func finish(_ code: Int32) async -> Never {
    await client.disconnect()
    // If a stop signal arrived while we were finishing, report it as an interrupt.
    exit(interrupted.exitCode ?? code)
}

do {
    try await client.connect()
    switch invocation.command {
    case .info:
        let model = try await client.modelInfo()
        let firmware = try await client.firmwareVersion()
        let volume = try await client.volume()
        let squelch = try await client.squelch()
        // `GCS` only to a model that has it (the SDS150), once; no answer is a warning, not a failure.
        var battery: ChargeStatus?
        if let known = model.model, ModelProfile.profile(for: known).supportsChargeStatus {
            do { battery = try await client.chargeStatus() } catch { printErr(CLIFormat.noBatteryLine(error)) }
        }
        let lines = CLIFormat.info(model: model.model?.rawValue ?? model.reported, firmware: firmware,
                                   volume: volume, squelch: squelch, battery: battery)
        lines.forEach { print($0) }
    case .status:
        CLIFormat.status(try await client.scannerInfo()).forEach { print($0) }
    case .display:
        CLIFormat.display(try await client.displayStatus()).forEach { print($0) }
    case .menu:
        CLIFormat.menu(try await client.menuScreen()).forEach { print($0) }
    case .quickKeys:
        // `MDL` first: only a model with quick keys is asked for them, and nothing else is sent.
        let model = try await client.modelInfo()
        guard let known = model.model, ModelProfile.profile(for: known).supportsQuickKeys else {
            printErr("quick-keys: the \(model.reported) has no quick keys")
            await finish(1)
        }
        CLIFormat.quickKeys(try await QuickKeyTreeReader.read(using: client)).forEach { print($0) }
    case .watch(let interval, let count):
        // UDP "connects" to anything and PSI is fire-and-forget, so probe with a read-only
        // MDL first: an unreachable scanner fails here instead of watching silently forever.
        let reported: String
        do {
            reported = try await client.modelInfo().reported
        } catch {
            printErr("cannot reach scanner at \(targetName): \(error)")
            await finish(1)
        }
        // The model's push keep-alive (the SDS150's KAL), over serial only.
        let keepAlive = KeepAliveOverride.forWatch(reportedModel: reported, invocation: invocation,
                                                   environment: environment)
        let updates = try await client.startPush(interval: interval, keepAlive: keepAlive)
        let deadline = WatchLoop.deadline(forInterval: interval)
        let outcome = await WatchLoop.run(updates, count: count, deadline: deadline) { info in
            print(CLIFormat.watchLine(info, at: Date()))
            fflush(stdout)
        }
        switch outcome {
        case .countReached:
            break
        case .stalled:
            printErr(WatchLoop.stallMessage(target: targetName, deadline: deadline))
            await finish(1)
        case .streamEnded(let seen):
            // A stop signal disconnects the client, which ends the stream; that is a normal stop.
            if interrupted.isSet { await finish(0) }
            printErr("PSI updates from \(targetName) ended after \(seen) update(s)"
                + (count.map { " of \($0)" } ?? ""))
            await finish(1)
        }
    case .listen, .restart, .ports, .audioInputs, .station, .log, .hits:
        break  // handled above
    }
    await finish(0)
} catch {
    // A serial port that is busy (exit 1) or missing (exit 2): nothing was sent.
    if let failure = CLIFormat.serialOpenFailure(error) {
        printErr(failure.line)
        await finish(failure.exitCode)
    }
    printErr("error: \(error)")
    await finish(1)
}
