// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleStore

extension SessionEnvironment {
    /// The environment variables the app reads, for tests against `noctule-mock-scanner` only
    /// (the same rule as the CLI's `--settings-dir`, `--recordings`, `--cooldown-store` and
    /// `--cooldown-seconds`). Never shorten the full cooldown against the real scanner.
    public enum OverrideKey {
        public static let settingsDirectory = "NOCTULE_SETTINGS_DIR"
        public static let recordingsDirectory = "NOCTULE_RECORDINGS_DIR"
        public static let cooldownStore = "NOCTULE_COOLDOWN_STORE"
        public static let cooldownSeconds = "NOCTULE_COOLDOWN_SECONDS"
        public static let presentTestSheet = "NOCTULE_TEST_PRESENT_SHEET"
        /// `NOCTULE_NO_USB_DETECTION`, the USB detection kill-switch (the CLI's).
        public static let noUSBDetection = USBDetection.disableKey
        /// `NOCTULE_TEST_SERIAL_PORTS`, the decoy port listing (the CLI's).
        public static let testSerialPorts = USBDetection.testPortsKey
        /// The push keep-alive interval; the CLI's `KeepAliveOverride.key` is the same variable.
        public static let testKeepAliveSeconds = "NOCTULE_TEST_KEEPALIVE_SECONDS"
        /// `NOCTULE_TEST_LINE_IN`, the mock's line-out stream in place of the line-in device. The app's; the CLI reads it from Plan 19 on.
        public static let testLineIn = LineInDetection.testStreamKey
    }

    /// `self` with the test overrides in `variables` applied, and one line per override applied
    /// or ignored (the app prints them to stderr).
    ///
    /// - `NOCTULE_SETTINGS_DIR`: the settings directory and a `LocalSettingsStore` on it.
    /// - `NOCTULE_RECORDINGS_DIR`: the recordings root.
    /// - `NOCTULE_COOLDOWN_STORE`: a `FileRTSPCooldownStore` at that path. Honoured only together
    ///   with a `NOCTULE_SETTINGS_DIR` that isn't the standard one (`standardSettingsDirectory`,
    ///   compared after resolving symlinks), so a private store is never paired with the owner's
    ///   real stations (which may name the real scanner).
    /// - `NOCTULE_COOLDOWN_SECONDS`: the full reconnect cooldown (after an unclean close; a
    ///   station's clean-close wait is clamped to it), a number ≥ 0, clamped to a day.
    ///   Honoured only together with a non-standard `NOCTULE_SETTINGS_DIR` and a `NOCTULE_COOLDOWN_STORE` that
    ///   isn't the shared record (`defaultCooldownStore`, compared after resolving symlinks), so a
    ///   shortened cooldown never reaches the store the CLI and the real scanner use.
    ///
    /// - `NOCTULE_TEST_PRESENT_SHEET`: any value; each station window presents a sheet once its
    ///   session is open (`presentsTestSheet`). Honoured only together with `NOCTULE_SETTINGS_DIR`.
    ///
    /// The serial port listing (`serialPorts`; Plan 8 D2, D7), so an app launched by an agent or a
    /// test (always with a private `NOCTULE_SETTINGS_DIR`) never finds the real scanner, in order:
    /// - `NOCTULE_NO_USB_DETECTION` set: no ports, nothing said, `NOCTULE_TEST_SERIAL_PORTS`
    ///   ignored (`USBDetection.isEnabled`).
    /// - Else a private `NOCTULE_SETTINGS_DIR` (set, and not the standard directory): the decoy
    ///   paths of `NOCTULE_TEST_SERIAL_PORTS` when set (`USBDetection.listing`, the CLI's), else no
    ///   ports; the listing `self` was given (the system's) is never asked.
    /// - Else (the standard settings): the listing `self` was given; `NOCTULE_TEST_SERIAL_PORTS`
    ///   is ignored, since a decoy has no business beside the owner's real stations.
    ///
    /// - `NOCTULE_TEST_KEEPALIVE_SECONDS`: the push keep-alive interval (`keepAliveInterval`), a
    ///   number of seconds in `PushKeepAlive.overrideRange` (0.05 to 60). Honoured only together
    ///   with a private `NOCTULE_SETTINGS_DIR` *and* `NOCTULE_NO_USB_DETECTION`: a private
    ///   directory can hold a copied station whose saved port is the real scanner (a saved port is
    ///   opened whatever the listing says), and a shortened `KAL` must never reach it; the
    ///   kill-switch is the setting every agent and test run carries.
    ///
    /// Audio inputs (line-in design §8), by `LineInDetection.selection(…, app: true)`, so an app
    /// launched by an agent or a test never opens a real input, even one saved in a station:
    /// - `NOCTULE_NO_USB_DETECTION` set: every line-in source is a `DisabledLineInSource` saying why
    ///   (`LineInDetection.disabledReason`), no input is listed, and the factory and listing `self`
    ///   was given (the system's) are never asked; nothing said.
    /// - With it, a private `NOCTULE_SETTINGS_DIR` and `NOCTULE_TEST_LINE_IN`: its path is
    ///   `lineInTestStream`, for the app shell to build its factory from; until it does, the factory
    ///   is the disabled one, and no input is listed. Noted.
    /// - Else the given factory and listing stay; `NOCTULE_TEST_LINE_IN` is named and ignored.
    ///
    /// Empty values count as unset; an invalid cooldown is ignored (the default stays).
    public func applyingOverrides(_ variables: [String: String],
                                  defaultCooldownStore: URL = FileRTSPCooldownStore.defaultURL,
                                  standardSettingsDirectory: URL = SessionEnvironment.standardSettingsDirectory)
        -> (environment: SessionEnvironment, notes: [String]) {
        func value(_ key: String) -> String? {
            guard let text = variables[key], !text.isEmpty else { return nil }
            return text
        }
        var result = self
        var notes: [String] = []
        let settingsPath = value(OverrideKey.settingsDirectory)
        // The standard directory holds the owner's real stations: never pair it with a private
        // store or a shortened cooldown, however the path is spelled.
        var standardSettings = false
        if let path = settingsPath {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            standardSettings = FileRTSPCooldownStore.samePath(url, standardSettingsDirectory)
            result.settingsDirectory = url
            result.settings = LocalSettingsStore(directory: url)
            notes.append("\(OverrideKey.settingsDirectory)=\(path)")
        }
        if let path = value(OverrideKey.recordingsDirectory) {
            result.recordingsRoot = URL(fileURLWithPath: path, isDirectory: true)
            notes.append("\(OverrideKey.recordingsDirectory)=\(path)")
        }
        let privateSettings = settingsPath != nil && !standardSettings
        if !USBDetection.isEnabled(variables) {
            result.serialPorts = FixedSerialPortListing.empty
        } else if privateSettings {
            // `system: .empty`: with no decoy paths `USBDetection.listing` returns `system`, and a
            // private settings directory must never reach the system's listing.
            result.serialPorts = USBDetection.listing(environment: variables, system: FixedSerialPortListing.empty)
            let decoy = USBDetection.overrideNotes(variables)
            notes += decoy.isEmpty ? ["no USB detection with a private \(OverrideKey.settingsDirectory)"] : decoy
        } else if value(OverrideKey.testSerialPorts) != nil {
            notes.append("ignoring \(OverrideKey.testSerialPorts): it needs a private \(OverrideKey.settingsDirectory)")
        }
        switch LineInDetection.selection(environment: variables, privateSettings: privateSettings, app: true) {
        case .system:
            break
        case .disabled(let reason):
            result.lineInSources = { _ in DisabledLineInSource(reason: reason) }
            result.audioInputs = FixedAudioInputListing.empty
        case .testStream(let path):
            // The kill-switch is set here too: the system's factory must stay out of reach, so the
            // disabled one stands until the shell puts the stream's in its place.
            result.lineInSources = { _ in DisabledLineInSource(reason: LineInDetection.disabledReason) }
            result.audioInputs = FixedAudioInputListing.empty
            result.lineInTestStream = path
        }
        let lineInNotes = LineInDetection.overrideNotes(variables, privateSettings: privateSettings, app: true)
        notes += lineInNotes
        if lineInNotes.isEmpty, value(OverrideKey.testLineIn) != nil {
            notes.append("ignoring \(OverrideKey.testLineIn): it needs a private \(OverrideKey.settingsDirectory)"
                + " and \(OverrideKey.noUSBDetection)")
        }
        var privateStore = false
        if let path = value(OverrideKey.cooldownStore) {
            if settingsPath == nil {
                notes.append("ignoring \(OverrideKey.cooldownStore): it needs \(OverrideKey.settingsDirectory) too")
            } else if standardSettings {
                notes.append("ignoring \(OverrideKey.cooldownStore): it needs a private \(OverrideKey.settingsDirectory), not the standard one")
            } else {
                let url = URL(fileURLWithPath: path)
                result.cooldownStore = FileRTSPCooldownStore(url: url)
                notes.append("\(OverrideKey.cooldownStore)=\(path)")
                privateStore = !FileRTSPCooldownStore.samePath(url, defaultCooldownStore)
            }
        }
        if let text = value(OverrideKey.cooldownSeconds) {
            if settingsPath == nil {
                notes.append("ignoring \(OverrideKey.cooldownSeconds): it needs \(OverrideKey.settingsDirectory) too")
            } else if standardSettings {
                notes.append("ignoring \(OverrideKey.cooldownSeconds): it needs a private \(OverrideKey.settingsDirectory), not the standard one")
            } else if !privateStore {
                notes.append("ignoring \(OverrideKey.cooldownSeconds): it needs a private \(OverrideKey.cooldownStore), not the shared one")
            } else if let seconds = Double(text), seconds.isFinite, seconds >= 0 {
                result.cooldown = .milliseconds(Int64((min(seconds, 86_400) * 1000).rounded()))
                notes.append("\(OverrideKey.cooldownSeconds)=\(text)")
            } else {
                notes.append("ignoring \(OverrideKey.cooldownSeconds)=\(text): not a number of seconds ≥ 0")
            }
        }
        if value(OverrideKey.presentTestSheet) != nil {
            if settingsPath == nil {
                notes.append("ignoring \(OverrideKey.presentTestSheet): it needs \(OverrideKey.settingsDirectory) too")
            } else {
                result.presentsTestSheet = true
                notes.append(OverrideKey.presentTestSheet)
            }
        }
        if let text = value(OverrideKey.testKeepAliveSeconds) {
            // Checked as a number before any `Duration` is made, so `inf`, `nan` and `1e300` are
            // refused rather than converted (as the CLI's `KeepAliveOverride` does).
            let range = PushKeepAlive.overrideRange
            let seconds = (range.lowerBound / .seconds(1)) ... (range.upperBound / .seconds(1))
            if !privateSettings || USBDetection.isEnabled(variables) {
                notes.append("ignoring \(OverrideKey.testKeepAliveSeconds): it needs a private \(OverrideKey.settingsDirectory)"
                    + " and \(OverrideKey.noUSBDetection)")
            } else if let number = Double(text), seconds.contains(number) {
                result.keepAliveInterval = .milliseconds(Int64((number * 1000).rounded()))
                notes.append("\(OverrideKey.testKeepAliveSeconds)=\(text) (in place of the model's keep-alive interval; "
                    + "a model without a keep-alive, or a network scanner, still gets none)")
            } else {
                notes.append("ignoring \(OverrideKey.testKeepAliveSeconds)=\(text): not a number of seconds from 0.05 to 60")
            }
        }
        return (result, notes)
    }
}
