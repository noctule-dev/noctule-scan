// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// What the mock's control core answers differently for each scanner model: its identity, its level
/// ranges, the form of its XML documents, and the commands only one model has. Everything else
/// (scenarios, menus, pushes apart from their lifetime, faults) is shared.
///
/// - `.sds200`: the UDP mock as it has always been (fw 1.26.01, protocol notes). `MockControlServer`
///   reports its scenario's `model` and `firmware` in place of `reportedModel` and `firmware`.
/// - `.sds150`: the SDS150 over USB serial (SDS150 design §3.2, §6). `MDL`, `VER` and the `GSI`
///   form (CR-separated lines, no `<Footer>`) were seen on hardware, and so was the shape of a
///   conventional channel (`MockScreens`' only conventional form, which the SDS200 uses too) and
///   of an idle moment, a conventional scan (`IdleForm.conventionalScan`).
///
/// **Assumptions, not hardware** (SDS150): an out-of-range `VOL`/`SQL` set answers `<NAME>,NG` and
/// changes nothing (the SDS200 mock's rule; the range is from Uniden's spec); `MSI` and `PSI`
/// pushes take the `GSI` form; the `GCS` values (only the line's shape and its `\n` terminator come
/// from the spec); `MSM,1` answered `MSM,NG` with nothing else happening (the client must never
/// send it over serial); every menu behaviour, copied from the SDS200 mock (`MockMenu`), including
/// that the SDS150 keeps sending `PSI` pushes while it is in a menu (the SDS200 does, seen on its
/// hardware; the SDS150's menu was never entered over serial): the app's Mac-style menu, its stall
/// warning and `StationRunner`'s resubscribe rest on it, and if it is wrong the runner replaces the
/// subscription about once a minute while the scanner sits in a menu (`PSI,0`, the port closed and
/// reopened, `MDL`, `VER`, `PSI`; design §6, Plan 8 hardware items 6 and 11); what
/// `Property` reports during a conventional transmission (`Sig` above 0, `Rssi`, `Mute`, the rest),
/// taken from the SDS200 mock: only the `ConvFrequency` attribute shape of an idle conventional
/// channel was seen on hardware (`sds150-gsi-serial.txt`); trunk transmissions, in the SDS200's
/// shape (none captured from the SDS150); the idle scan's three channels, their frequencies and
/// indexes and the step of one channel per scenario second (only one idle document was captured);
/// the idle `STS` display, the SDS200 mock's trunk idle screen while `GSI` and `PSI` show the
/// conventional scan (no SDS150 `STS` of a scan is captured), with three icon glyph bytes
/// (`displayGlyphBytes`: 0x80, 0x81, 0x8D) at columns 0-2 of its first line: that the SDS150 draws
/// icons as lone bytes like these, one per column, and which bytes it uses, is assumed (design
/// §7.3; the hardware suite's read-only run measures the widths on the real unit). It answers `KEY` with a code it lacks (`T`, `Q`, `R`) with `KEY,NG`
/// (design §5.11; assumed, not hardware).
///
/// - `.sds100`: the SDS100 over USB serial (SDS100 design §3, §5.4; fw 1.26.01, the owner's run of
///   2026-11-16). Seen on hardware: `MDL` `SDS100`; `VER` `1.26.01` (its `Version ` prefix is the
///   SDS150's form and the spec's); the push lifetime, below; `KAL` answered `ERR`; `GCS` giving no
///   usable answer; a `GSI` during a trunked ID search with the trunk shape (system, site, frequency
///   and modulation: `IdleForm.trunkSite`); and the `STS` icon glyphs as low control bytes (0x06,
///   0x07, 0x1A, 0x1B), the personality's `displayGlyphBytes`. Its answers otherwise follow the
///   SDS150's serial form.
///
/// **Assumptions, not hardware** (SDS100): the levels, 0-15 from the spec, and an out-of-range
/// `VOL`/`SQL` answered `NG` with nothing changed (the other mocks' rule); that the XML documents
/// take the SDS150's serial form, `\r`-separated lines with no `<Footer>` but on `GLT` (the client's
/// serial reader parsed the real replies, but the raw bytes were never looked at; the `GLT` footers
/// and pages were seen in the trace of 2026-11-19, as on the SDS150); that `GCS` is answered
/// `ERR`, as `KAL` is (the real answer wasn't usable; the product never sends `GCS` to an SDS100);
/// `MSM,1` answered `MSM,NG` with nothing else happening, never sent; that each icon glyph takes
/// one column (the hardware suite measures it, design §7 H1); and every scenario, menu, conventional
/// and trunk shape, fault, unplug and replug, taken from the SDS150 mock's; and that a `KEY` with a code
/// it lacks (`T`, `Q`) is answered `KEY,NG` (design §5.11). The push lifetime's
/// assumptions are in the next paragraph.
///
/// - `.bcd436hp`: the BCD436HP over USB serial (BCD436HP design §3, §5.7). Seen on hardware:
///   `MDL` `BCD436HP`; the push lifetime of the SDS100's kind; `KAL` doing nothing useful; an
///   out-of-range `VOL`/`SQL` set clamped and answered `OK` (`clampsLevels`); a `<Footer No="1"
///   EOT="1"/>` on an `MSI` document (`xmlFooter`; `GSI` and pushes carry none); two icon glyph
///   bytes on the idle screen (only their count was seen, design §3.6). It has no `T` or `Q` key
///   (`missingKeys`; design §5.11).
///
/// **Assumptions, not hardware** (BCD436HP): `VER`'s `Version ` prefix; `KAL` and `GCS` answered
/// `ERR`; `MSM,1` answered `MSM,NG` with nothing else happening; that every `PSI` restarts the full
/// 183 s; the glyph byte values (fictional); `GSI` and `PSI` without a footer; that a key the radio
/// lacks is answered `KEY,NG` (the SDS100 and SDS150 `missingKeys` too, design §5.11); and the
/// menus, scenarios, faults, unplug and replug, copied from the other serial mocks.
///
/// **The push lifetime** (SDS150; `pushLifetime`, `pushLifetimeRestarts`, `silentCommands`). Seen
/// on hardware (fw 1.01.02, 2026-11-12): pushes stop 183 s after the `PSI` (three timed runs), the
/// port stays open, the scanner goes on answering, and a new `PSI` starts them again; with `KAL`
/// every 60 s they went on past it (240 s with four `KAL`s, a 300 s `watch`, an hour of `log`), and
/// in the 240 s check nothing came back for a `KAL`, as Uniden's spec says. **Assumptions, not
/// hardware:** that every `KAL` restarts the full 183 s, counted from the latest `PSI` or `KAL` on
/// the scenario clock (seen: pushes for as long as `KAL`s came; the rule itself not measured); that no
/// other command does (`GSI`, `MDL`, `VOL`, …; only `KAL` was tried, at 60 s only); that a `KAL`
/// after the pushes stopped starts them again (the rule read literally: never tried; design §8
/// check 16), which `keepAliveRevivesStoppedPushes` (`--kal-after-expiry ignored`) turns into the
/// pessimistic answer for tests, where only a new `PSI` does; and that `KAL` with no subscription
/// does nothing (never tried).
///
/// **The SDS100's push lifetime** (same fields, no restarts). Seen on hardware (fw 1.26.01,
/// 2026-11-16): pushes stop 182-186 s after the `PSI`, port open, `MDL` answering at once on a
/// reopened port; `KAL` does nothing (`ERR`); and the same `PSI` sent again every 60 s on the open
/// port, with no `PSI,0` between, kept the pushes going through a 240 s hold, each answered
/// `PSI,OK`. The core already treats every non-zero `PSI` as a new subscription from that peer
/// (the old one replaced, one subscriber counted, its lifetime counted again from now), which is
/// what the SDS100 shows. **Assumptions, not hardware:** that every repeated `PSI` restarts the
/// full 183 s, and that a `PSI` after the pushes stopped starts them again on the open port (a
/// `PSI` on a reopened port is seen); that `GSI`, `STS`, `MSI` and the rest restart nothing.
///
/// **The headphone jack** (`MockLineOut`, with `--line-out`; line-in design §8; every serial
/// personality). Seen on the owner's SDS150 rig, 2026-11-17 (design §3a): the jack's idle floor is
/// broadband hiss at about -52 dBFS block RMS, peaks near -38 dBFS, with the squelch closed, and
/// volume 5 peaked at -3.4 dBFS on the loudest hit, on a mono input. **Assumptions, not hardware:**
/// the level curve (the tone's amplitude is volume / 8 with no ceiling before the jack's hard clip
/// at +-1, so 8 and up clips: full scale at 8, which the detector already counts as a clip, flat
/// tops from 9; the plan's `min(1, volume / 8)` could clip only through the hiss, so a ruling made
/// during the build chose this instead, 2026-11-17; the owner hasn't ruled on it), the stereo
/// layout (the same signal on the chosen channel or channels, zero on the other), that the noise is
/// Gaussian and sits under the tone as well, that the jack is quiet but for that noise between
/// transmissions and keeps playing through a USB unplug, and the scenario's synthetic sine standing
/// for speech. The 48 kHz stereo Float32 stream is the mock's own format, chosen so the conversion
/// and channel paths run; a real interface's blocks are its own.
///
/// **Favorites quick keys** (`MockFavorites`, every personality alike): the tree is fictional. Seen on
/// hardware (quick-keys design §3): the `GLT` shapes, and their pages over serial (a footer on every
/// `GLT` document, a long reply in several, the SDS150 and the SDS100, 2026-11-19; the mocks page by
/// element count, the hardware by size), `FQK`/`SQK`/`DQK` replies of the 100 values only,
/// a 0 in a set leaving a key alone (`SQK`), sets answered `OK` after about 0.8 s (`FQK`, `SQK`) or at
/// once (`DQK`). **Assumptions, not hardware:** an unknown `GLT` index answering an empty document; a
/// set of other than 100 values `0`-`2`, or addressed to a list or system key that nothing holds,
/// answered `NG`; a `1` or `2` for a key that doesn't exist ignored; a key several rows hold changing
/// them all, and its read answering the first holder; `FQK` and `DQK` sets taking 0 as `SQK` does; the
/// mismatch system's `DQK` set accepted and ignored; states kept across a power cycle.
public struct MockPersonality: Sendable, Equatable {
    /// The `MDL` reply after `MDL,`.
    public var reportedModel: String
    /// The `VER` reply after `VER,`.
    public var firmware: String
    /// `VOL,<n>` accepts these; anything else is `VOL,NG`.
    public var volumeRange: ClosedRange<Int>
    /// `SQL,<n>` accepts these; anything else is `SQL,NG`.
    public var squelchRange: ClosedRange<Int>
    /// The UDP form ends `MSI` documents with `<Footer No="1" EOT="1"/>`; the serial form has none.
    /// `GLT` documents carry their page footer on every model (`MockFavorites`), whatever this says.
    public var xmlFooter: Bool
    /// What separates the lines of an XML document: `\n` in the UDP form, `\r` on serial.
    public var xmlLineBreak: String
    /// The `GCS` reply line, without its terminator (`\n`, unlike every other reply); nil: `GCS`
    /// is an unknown command (`ERR`).
    public var chargeStatusReply: String?
    /// True: `MSM,1` answers `MSM,OK` and reboots. False: it answers `MSM,NG` and nothing else
    /// happens.
    public var restartReboots: Bool
    /// What `GSI` and `PSI` describe between a trunk-mode scenario's transmissions.
    public var idleForm: IdleForm
    /// Scenario seconds (on the mock's clock) after which a subscription's pushes stop, counted
    /// from its `PSI` or the latest command in `pushLifetimeRestarts` from the same peer; nil:
    /// they never stop. The subscription itself stays (counted until `PSI,0`, an unplug or a stop).
    public var pushLifetime: Double?
    /// Commands that restart the push lifetime of the sender's subscription. A non-zero `PSI`
    /// always does, since it starts a new subscription; these are the others.
    public var pushLifetimeRestarts: Set<String>
    /// A command in `pushLifetimeRestarts` that arrives after the pushes stopped starts them again
    /// (true: the mock's assumption so far) or does nothing (false: the pessimistic answer).
    /// Never tried on hardware (design §13 P); a new `PSI` starts them again either way.
    public var keepAliveRevivesStoppedPushes: Bool
    /// Raw bytes written over the first columns of the first line of an idle `STS` (the display's
    /// icon glyphs, which are not text). Empty: none (the SDS200's bytes are unchanged).
    public var displayGlyphBytes: [UInt8]
    /// Commands the model takes without any reply (logged and carried out, nothing sent back);
    /// every other command it doesn't know is answered `ERR`.
    public var silentCommands: Set<String>
    /// True: an out-of-range `VOL`/`SQL` set is clamped to the model's range and answered `OK`
    /// (the BCD436HP, design §3); false: it is answered `NG` and changes nothing.
    public var clampsLevels: Bool
    /// Front-panel key codes the model has no key for: `KEY,<code>,P` is answered `KEY,NG`
    /// (design §5.11; assumed that the radio answers so).
    public var missingKeys: Set<String>
    /// True: the model has the BCD436HP's `MNU`, `MSB` and `HLD` commands (Task 4 gives it behaviour).
    public var bcdCommands: Bool
    /// The form of `STS` and `GSI`'s display text (Task 3 gives `.bcd436hp` behaviour).
    public var displayForm: DisplayForm

    /// Which family's display the mock draws.
    public enum DisplayForm: Sendable, Equatable {
        /// The SDS models': 4 lines of 20+ columns with soft keys.
        case sds
        /// The BCD436HP's: 24 columns, no soft-key line.
        case bcd436hp
    }

    /// What an idle moment of a trunk-mode scenario looks like in `ScannerInfo` (a weather
    /// scenario's idle is the same under every personality).
    public enum IdleForm: Sendable, Equatable {
        /// The SDS200 mock's: the scenario's idle system, `Site` and `SiteFrequency` (the control
        /// channel) under `Mode="Trunk Scan"`, no channel.
        case trunkSite
        /// The SDS150's (fw 1.01.02, seen on hardware, `sds150-gsi-serial.txt`): stepping through
        /// conventional channels, each named with its frequency while nothing is on the air. The
        /// root says `Mode="Scan Mode" V_Screen="conventional_scan"`; `System` (`SystemType=
        /// "Conventional"`), `Department` and `ConvFrequency` in the conventional form
        /// (`MockScreens`' `convFrequency`, `SAD="None"`); no `Site` or `SiteFrequency`;
        /// `Property` with `Sig="0"`, `Mute="Mute"`, `P25Status="None"`, `Rssi="-999"`; and
        /// `<OverWrite Text="Scanning..." />` in `ViewDescription`. The channel steps once per
        /// scenario second through three fixed fictional channels of `County Roads` › `Road Crews`
        /// (`MockScreens.idleScanChannels`), whatever the scenario's idle names (assumptions; see
        /// the type comment).
        case conventionalScan
    }

    public init(reportedModel: String, firmware: String, volumeRange: ClosedRange<Int>, squelchRange: ClosedRange<Int>,
                xmlFooter: Bool, xmlLineBreak: String, chargeStatusReply: String?, restartReboots: Bool,
                idleForm: IdleForm = .trunkSite,
                pushLifetime: Double? = nil, pushLifetimeRestarts: Set<String> = [], silentCommands: Set<String> = [],
                keepAliveRevivesStoppedPushes: Bool = true, displayGlyphBytes: [UInt8] = [],
                clampsLevels: Bool = false, missingKeys: Set<String> = [], bcdCommands: Bool = false,
                displayForm: DisplayForm = .sds) {
        self.reportedModel = reportedModel; self.firmware = firmware
        self.volumeRange = volumeRange; self.squelchRange = squelchRange
        self.xmlFooter = xmlFooter; self.xmlLineBreak = xmlLineBreak
        self.chargeStatusReply = chargeStatusReply; self.restartReboots = restartReboots
        self.idleForm = idleForm
        self.pushLifetime = pushLifetime; self.pushLifetimeRestarts = pushLifetimeRestarts
        self.silentCommands = silentCommands
        self.keepAliveRevivesStoppedPushes = keepAliveRevivesStoppedPushes
        self.displayGlyphBytes = displayGlyphBytes
        self.clampsLevels = clampsLevels; self.missingKeys = missingKeys
        self.bcdCommands = bcdCommands; self.displayForm = displayForm
    }

    public static let sds200 = MockPersonality(
        reportedModel: "SDS200", firmware: "Version 1.26.01", volumeRange: 0...29, squelchRange: 0...19,
        xmlFooter: true, xmlLineBreak: "\n", chargeStatusReply: nil, restartReboots: true,
        idleForm: .trunkSite)

    public static let sds150 = MockPersonality(
        reportedModel: "SDS150", firmware: "Version 1.01.02", volumeRange: 0...15, squelchRange: 0...15,
        xmlFooter: false, xmlLineBreak: "\r", chargeStatusReply: "GCS,CST=4,VOLT=4184mV:100%,CURR=0000mA,TEMP= 27.65C",
        restartReboots: false, idleForm: .conventionalScan,
        pushLifetime: 183, pushLifetimeRestarts: ["KAL"], silentCommands: ["KAL"],
        displayGlyphBytes: [0x80, 0x81, 0x8D], missingKeys: ["T", "Q", "R"])

    /// The SDS100 over USB serial (SDS100 design §3, §5.4). Its keep-alive is a repeated `PSI`
    /// (every `PSI` restarts the lifetime, in the core), so `KAL` is an unknown command: `ERR`,
    /// restarting nothing.
    public static let sds100 = MockPersonality(
        reportedModel: "SDS100", firmware: "Version 1.26.01", volumeRange: 0...15, squelchRange: 0...15,
        xmlFooter: false, xmlLineBreak: "\r", chargeStatusReply: nil, restartReboots: false,
        idleForm: .trunkSite, pushLifetime: 183, pushLifetimeRestarts: [], silentCommands: [],
        displayGlyphBytes: [0x06, 0x07, 0x1A, 0x1B], missingKeys: ["T", "Q"])

    /// The BCD436HP over USB serial (BCD436HP design §3, §5; fw 1.28.24). Its keep-alive is a
    /// repeated `PSI` as the SDS100's is, so `KAL` is an unknown command (`ERR`).
    public static let bcd436hp = MockPersonality(
        reportedModel: "BCD436HP", firmware: "Version 1.28.24", volumeRange: 0...15, squelchRange: 0...15,
        xmlFooter: true, xmlLineBreak: "\r", chargeStatusReply: nil, restartReboots: false,
        idleForm: .trunkSite, pushLifetime: 183, pushLifetimeRestarts: [], silentCommands: [],
        displayGlyphBytes: [0x8A, 0x8B], clampsLevels: true, missingKeys: ["T", "Q"],
        bcdCommands: true, displayForm: .bcd436hp)

    /// This personality, reporting `scenario`'s model and firmware (the UDP mock's identity).
    func reporting(_ scenario: MockScenario) -> MockPersonality {
        var personality = self
        personality.reportedModel = scenario.model
        personality.firmware = "Version \(scenario.firmware)"
        return personality
    }
}
