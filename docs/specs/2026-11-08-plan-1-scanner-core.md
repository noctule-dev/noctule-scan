# Plan 1 — Scanner Core (NoctuleKit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Swift package, `NoctuleKit`, that talks to an SDS200 over the network: it sends commands, reassembles responses, parses status (`GSI`/`PSI`) and display (`STS`), presses keys, and runs push updates. It also includes a read-only `noctule` CLI that proves it against the real scanner.

**Architecture:** A transport protocol (`ScannerTransport`) sits underneath an actor (`ScannerClient`) that serializes request/response pairs and routes `PSI` pushes to a stream. A UDP transport (Network.framework) and a simulated transport implement it. Parsers are pure value types that run against real captured fixtures. Model knowledge lives in a data table (`ModelProfile`).

**Tech Stack:** Swift 6.4, Swift Package Manager, Swift Testing (`import Testing`), Foundation `XMLParser`, Network.framework. No third-party dependencies.

**Spec:** `docs/specs/2026-11-08-noctule-scan-design.md` and `docs/specs/2026-11-08-sds-remote-protocol.md`. Read `AGENTS.md` and `LESSONS.md` first.

### Where this plan sits

The design covers four subsystems. Each gets its own plan, and each produces working, testable software:

1. **Scanner core (this plan):** protocol, transports, parsing, client, CLI.
2. **Audio:** RTSP/RTP client, µ-law decode, playback, WAV writer, keepalive/teardown/recovery (design §8).
3. **Stations, hit logging, and storage:** stations, hit detection from `PSI`, hit-log database, recording files, storage interface with iCloud hooks (design §6, §9, §10).
4. **Mac app:** Connect, scanner view, Mac-style view, hit log UI, settings (design §7, §12).

## Global Constraints

- Swift and SwiftUI only; this plan has no UI. Shared code must not import AppKit or UIKit (design §11).
- Package platforms: `.macOS(.v26), .iOS(.v26)`. NoctuleKit must build for iOS, so use no macOS-only APIs: `XMLParser` is fine, `XMLDocument` is not.
- No third-party dependencies.
- Default UDP port `50536`. Command terminator `\r`. XML marker `,<XML>,`.
- Unprogrammed index sentinel: `4294967295`.
- SDS200 volume `0...29`, squelch `0...19`. SDS100/SDS150 volume `0...15`, squelch `0...15`. BCD436HP ranges unknown (`nil`).
- No real hosts or addresses in tracked files. The dev scanner comes from git-ignored `config/dev-scanner.env` (`SCANNER_HOST`, `SCANNER_IP`, `SCANNER_UDP_PORT`).
- Hardware tests are opt-in (`NOCTULE_HARDWARE_TESTS=1`) and read-only: `MDL`, `VER`, `VOL`, `SQL`, `GSI`, `STS`, and `PSI` start/stop. Every `PSI` start is paired with `PSI,0` in all exit paths.
- Never send undocumented or guessed commands to the scanner.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Scanner unreachable (VPN down, wrong address):** every command fails with `ScannerClientError.timeout` within its timeout and never hangs. Pinned in Task 6 (simulated, no reply) and Task 7 (UDP to a closed loopback port).
2. **An unsolicited `PSI` push arrives while a command is waiting:** the push goes to the push stream and the command still gets its own reply. Pinned in Task 6.
3. **XML fragments that are lost, out of order, or never finished (`EOT`):** they're dropped without crashing, and the next complete document still parses. Pinned in Task 2.
4. **Firmware or mode differences** (missing attributes, unknown elements, conventional mode): `ScannerInfo` parses what it knows, leaves the rest `nil`, and keeps the raw tree. Pinned in Task 3.
5. **Non-UTF-8 bytes and control characters in `STS`** (icon glyphs, `\x1a\x1b`): the decoder replaces invalid bytes and keeps control characters, and the parse still succeeds. Pinned in Tasks 2 and 4.

---

### Task 1: Package scaffold, commands, and line responses

**Files:**
- Create: `Package.swift`
- Create: `Sources/NoctuleKit/Protocol/ScannerCommand.swift`
- Create: `Sources/NoctuleKit/Protocol/ScannerResponse.swift`
- Create: `Tests/NoctuleKitTests/ScannerCommandTests.swift`
- Create: `Tests/NoctuleKitTests/ResponseLineParserTests.swift`

**Interfaces:**
- Produces:
  - `struct ScannerCommand: Sendable, Equatable { let name: String; let arguments: [String]; init(_ name: String, _ arguments: String...) throws; var wireBytes: Data }`
  - `enum ScannerCommandError: Error, Equatable { case invalidArgument(String) }`
  - `enum ScannerResponse: Sendable, Equatable { case fields(command: String, fields: [String]); case xml(command: String, root: XMLNode); var command: String { get } }`. `XMLNode` is defined in Task 2. Until then, Task 1 declares only the `.fields` case and Task 2 adds `.xml`.
  - `enum ResponseStatus: Equatable { case ok; case rejected(String) }` and `extension ScannerResponse { var status: ResponseStatus? }`. `status` is `.ok` for fields `["OK"]`, `.rejected(raw)` for `["NG"]`, `["ERR"]`, or `["ERROR"]`, and `nil` otherwise.
  - `enum ResponseLineParser { static func parse(_ line: String) -> ScannerResponse? }`

- [ ] **Step 1: Create `Package.swift`**

Use tools version 6.2. Platforms per Global Constraints. Products: library `NoctuleKit`, executable `noctule`. Targets: `NoctuleKit`; `NoctuleKitTestSupport` (depends on NoctuleKit); `NoctuleDevConfig` (no deps); executable `noctule` (depends on NoctuleKit and NoctuleDevConfig; add it in Task 8). Test target `NoctuleKitTests` depends on NoctuleKit, NoctuleKitTestSupport, and NoctuleDevConfig, with `resources: [.copy("Fixtures")]`. Create an empty `Sources/<target>/` file for each target so the package resolves.

- [ ] **Step 2: Write the failing tests**

```swift
@Test func encodesBareCommand() throws {
    #expect(try ScannerCommand("MDL").wireBytes == Data("MDL\r".utf8))
}
@Test func encodesArguments() throws {
    #expect(try ScannerCommand("KEY", "L", "P").wireBytes == Data("KEY,L,P\r".utf8))
}
@Test func rejectsDelimitersInArguments() {
    #expect(throws: ScannerCommandError.invalidArgument("a,b")) { try ScannerCommand("HLD", "a,b") }
    #expect(throws: ScannerCommandError.invalidArgument("x\r")) { try ScannerCommand("HLD", "x\r") }
}
@Test func parsesFieldLines() {
    #expect(ResponseLineParser.parse("MDL,SDS200") == .fields(command: "MDL", fields: ["SDS200"]))
    #expect(ResponseLineParser.parse("VER,Version 1.24.00") == .fields(command: "VER", fields: ["Version 1.24.00"]))
    #expect(ResponseLineParser.parse("vol,2\r") == .fields(command: "VOL", fields: ["2"]))
    #expect(ResponseLineParser.parse("") == nil)
}
@Test func reportsStatus() {
    #expect(ResponseLineParser.parse("VOL,OK")?.status == .ok)
    #expect(ResponseLineParser.parse("KEY,NG")?.status == .rejected("KEY,NG"))
    #expect(ResponseLineParser.parse("VOL,2")?.status == nil)
}
```

- [ ] **Step 3: Run `swift test --filter "ScannerCommandTests|ResponseLineParserTests"`**: expect a compile failure (types missing).
- [ ] **Step 4: Implement `ScannerCommand`, `ScannerResponse`, `ResponseStatus`, and `ResponseLineParser`** in the files above. Upper-case command names. Trim `\r\n` and spaces at the line ends only; fields keep their inner spacing.
- [ ] **Step 5: Run the same command**: expect PASS.
- [ ] **Step 6: Commit:** `feat: package scaffold, command encoding, line response parsing`

---

### Task 2: XML tree and UDP datagram assembly

**Files:**
- Create: `Sources/NoctuleKit/Protocol/XMLNode.swift`
- Create: `Sources/NoctuleKit/Protocol/UDPDatagramAssembler.swift`
- Modify: `Sources/NoctuleKit/Protocol/ScannerResponse.swift` (add the `.xml` case)
- Create: `Tests/NoctuleKitTests/UDPDatagramAssemblerTests.swift`

**Interfaces:**
- Consumes: `ScannerResponse`, `ResponseLineParser` (Task 1).
- Produces:
  - `struct XMLNode: Sendable, Equatable { var name: String; var attributes: [String: String]; var children: [XMLNode]; static func parse(_ data: Data) throws -> XMLNode; func child(_ name: String) -> XMLNode? }` (built with `XMLParser`)
  - `struct UDPDatagramAssembler { init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, maxSequenceAge: Duration = .seconds(10), maxDocumentBytes: Int = 4_194_304, maxFragments: Int = 256); mutating func expectXML(for command: String); mutating func feed(_ datagram: Data) -> [ScannerResponse] }`

Assembly rules, from the protocol notes §2 and the `sds200` library:
- Decode as UTF-8 with invalid bytes replaced (`String(decoding:as:)`). Strip NUL characters.
- `CMD,<XML>,payload`: `payload` (leading `\r\n` and spaces trimmed) is one XML document for `CMD`.
- A datagram whose trimmed text starts with `<?xml` or `<ScannerInfo`, `<GLT`, `<MSI`, or `<AST` is bare XML for the most recent command passed to `expectXML(for:)`. If none matches the root, drop it.
- Anything else is split on `\r`/`\n` into lines, each passed through `ResponseLineParser`.
- A root with no `Footer`/`Foot` child is complete: emit it at once.
- With a footer: `No` must be a positive integer. `No == 1` starts a sequence for that command; any other `No` must equal the next expected number, or the sequence is discarded. Merge children, excluding footers, in order under the first fragment's root name and attributes. Emit on `EOT="1"`.
- Discard a sequence that is older than `maxSequenceAge` (checked on every `feed`), that exceeds `maxFragments` or `maxDocumentBytes`, or whose XML fails to parse. Never throw from `feed`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func lineResponses() {
    var a = UDPDatagramAssembler()
    #expect(a.feed(Data("MDL,SDS200\r".utf8)) == [.fields(command: "MDL", fields: ["SDS200"])])
}
@Test func singleDocumentWithoutFooter() throws {
    var a = UDPDatagramAssembler()
    let out = a.feed(Data(#"GSI,<XML>,<?xml version="1.0"?><ScannerInfo Mode="Trunk Scan"><System Name="A"/></ScannerInfo>"#.utf8))
    guard case .xml("GSI", let root) = try #require(out.first) else { Issue.record(); return }
    #expect(root.attributes["Mode"] == "Trunk Scan")
    #expect(root.child("System")?.attributes["Name"] == "A")
}
@Test func mergesFragmentsInOrder() throws {
    var a = UDPDatagramAssembler()
    #expect(a.feed(Data(#"GSI,<XML>,<ScannerInfo Mode="M"><System Name="One"/><Footer No="1" EOT="0"/></ScannerInfo>"#.utf8)).isEmpty)
    let out = a.feed(Data(#"GSI,<XML>,<ScannerInfo><Department Name="Two"/><Footer No="2" EOT="1"/></ScannerInfo>"#.utf8))
    guard case .xml("GSI", let root) = try #require(out.first) else { Issue.record(); return }
    #expect(root.attributes["Mode"] == "M")
    #expect(root.children.map(\.name) == ["System", "Department"])
}
@Test func dropsSequenceGapThenRecovers() {
    var a = UDPDatagramAssembler()
    _ = a.feed(Data(#"GSI,<XML>,<ScannerInfo><System Name="One"/><Footer No="1" EOT="0"/></ScannerInfo>"#.utf8))
    #expect(a.feed(Data(#"GSI,<XML>,<ScannerInfo><System Name="Three"/><Footer No="3" EOT="1"/></ScannerInfo>"#.utf8)).isEmpty)
    #expect(a.feed(Data(#"GSI,<XML>,<ScannerInfo><System Name="B"/></ScannerInfo>"#.utf8)).count == 1)
}
@Test func expiresStaleSequences() {
    // now() is driven by a test clock: advance 11 s between fragment 1 and fragment 2; expect fragment 2 dropped.
}
@Test func bareXMLContinuationUsesExpectedCommand() {
    var a = UDPDatagramAssembler()
    a.expectXML(for: "PSI")
    let out = a.feed(Data(#"<ScannerInfo Mode="X"/>"#.utf8))
    #expect(out.first?.command == "PSI")
}
@Test func malformedXMLIsDropped() {
    var a = UDPDatagramAssembler()
    #expect(a.feed(Data("GSI,<XML>,<ScannerInfo><System".utf8)).isEmpty)
}
@Test func invalidUTF8IsReplacedNotFatal() {
    var a = UDPDatagramAssembler()
    var bytes = Data("STS,0,ab".utf8); bytes.append(0xFF); bytes.append(contentsOf: Data(",x".utf8))
    guard case .fields("STS", let f) = a.feed(bytes).first else { Issue.record(); return }
    #expect(f[1] == "ab\u{FFFD}")
}
```

Write `expiresStaleSequences` with a mutable test clock: a `final class` holding a `ContinuousClock.Instant` behind a `Mutex`, captured by the `now:` closure.

- [ ] **Step 2: Run `swift test --filter UDPDatagramAssemblerTests`**: expect FAIL.
- [ ] **Step 3: Implement `XMLNode` and `UDPDatagramAssembler`** per the rules above, and add `case xml(command: String, root: XMLNode)` to `ScannerResponse`.
- [ ] **Step 4: Run it again**: expect PASS, then run `swift test` for the whole suite: PASS.
- [ ] **Step 5: Commit:** `feat: XML tree and UDP datagram assembly with fragment reassembly`

---

### Task 3: `ScannerInfo` parsing (GSI/PSI)

**Files:**
- Create: `Sources/NoctuleKit/Status/ScannerInfo.swift`
- Create: `Tests/NoctuleKitTests/Fixtures/gsi-trunk-sds200-1.24.00.xml`
- Create: `Tests/NoctuleKitTests/ScannerInfoTests.swift`

**Interfaces:**
- Consumes: `XMLNode` (Task 2).
- Produces:
  - `struct NamedItem: Sendable, Equatable { var name: String; var index: UInt32?; var avoid: Bool?; var hold: Bool?; var attributes: [String: String]; var isProgrammed: Bool }`. `isProgrammed` is `index != ScannerInfo.unprogrammedIndex`; `nil` index counts as programmed.
  - `struct ScannerInfo: Sendable, Equatable` with `static let unprogrammedIndex: UInt32 = 4_294_967_295`; `init(xml root: XMLNode) throws` (throws `ScannerInfoError.unexpectedRoot(String)` unless the root is `ScannerInfo`); and properties:
    `mode: String?`, `screen: String?` (`V_Screen`), `monitorList: NamedItem?`, `system: NamedItem?`, `systemType: String?`, `department: NamedItem?`, `channel: NamedItem?` (from `TGID`, else `ConvFrequency`), `talkgroupID: String?` (`TGID@TGID` with the `TGID:` prefix removed), `unitID: String?` (`UnitID@U_Id` with `UID:` removed), `site: NamedItem?`, `modulation: String?` (`Site@Mod`), `frequencyMHz: Double?` (`SiteFrequency@Freq`, trimmed, `MHz` removed), `toneOrCode: String?` (`SiteFrequency@SAD`), `rssi: Int?`, `signalBars: Int?` (`Sig`), `volume: Int?`, `squelch: Int?`, `attenuatorOn: Bool?`, `recordingOn: Bool?`, `p25Status: String?`, `muted: Bool?` (`Mute == "Mute"`), `raw: XMLNode`.
  - "On"/"Off" attributes map to `true`/`false`. Anything else, or missing, is `nil`.

- [ ] **Step 1: Create the fixture.** Copy the `ScannerInfo` document from protocol notes §4 into `gsi-trunk-sds200-1.24.00.xml`, prefixed with `<?xml version="1.0" encoding="utf-8"?>`.
- [ ] **Step 2: Write the failing tests**

```swift
@Test func parsesRealTrunkCapture() throws {
    let info = try ScannerInfo(xml: XMLNode.parse(fixture("gsi-trunk-sds200-1.24.00.xml")))
    #expect(info.mode == "Trunk Scan"); #expect(info.screen == "trunk_scan")
    #expect(info.system?.name == "LWPC P25-2"); #expect(info.systemType == "P25 Trunk")
    #expect(info.department?.name == "Unknown"); #expect(info.department?.isProgrammed == false)
    #expect(info.channel?.name == "TGID:9"); #expect(info.channel?.isProgrammed == false)
    #expect(info.talkgroupID == "9"); #expect(info.unitID == "7316")
    #expect(info.site?.name == "northside"); #expect(info.modulation == "NFM")
    #expect(info.frequencyMHz == 935.4375); #expect(info.toneOrCode == "NAC 2B4h")
    #expect(info.rssi == -69); #expect(info.signalBars == 5)
    #expect(info.volume == 2); #expect(info.squelch == 1)
    #expect(info.attenuatorOn == false); #expect(info.recordingOn == false); #expect(info.muted == false)
    #expect(info.monitorList?.name == "lakeworks"); #expect(info.monitorList?.isProgrammed == true)
}
@Test func toleratesSparseAndUnknownContent() throws {
    let xml = #"<ScannerInfo Mode="Conventional Scan"><ConvFrequency Name="Fire Disp" Index="12"/><NewThing X="1"/><Property VOL="x"/></ScannerInfo>"#
    let info = try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
    #expect(info.channel?.name == "Fire Disp"); #expect(info.channel?.isProgrammed == true)
    #expect(info.system == nil); #expect(info.volume == nil); #expect(info.rssi == nil)
    #expect(info.raw.child("NewThing") != nil)
}
@Test func rejectsWrongRoot() {
    #expect(throws: ScannerInfoError.unexpectedRoot("GLT")) { try ScannerInfo(xml: XMLNode(name: "GLT", attributes: [:], children: [])) }
}
```

`fixture(_:)` is a test helper that loads `Bundle.module` resources from `Fixtures/`. Put it in `Tests/NoctuleKitTests/Fixtures.swift`.

- [ ] **Step 3: Run `swift test --filter ScannerInfoTests`**: expect FAIL.
- [ ] **Step 4: Implement `ScannerInfo`, `NamedItem`, and `ScannerInfoError`.**
- [ ] **Step 5: Run it again**: expect PASS.
- [ ] **Step 6: Commit:** `feat: parse ScannerInfo status XML`

---

### Task 4: `DisplayStatus` parsing (STS)

**Files:**
- Create: `Sources/NoctuleKit/Status/DisplayStatus.swift`
- Create: `Tests/NoctuleKitTests/Fixtures/sts-trunk-sds200-1.24.00.txt`
- Create: `Tests/NoctuleKitTests/DisplayStatusTests.swift`

**Interfaces:**
- Consumes: `ScannerResponse`, `UDPDatagramAssembler` (Task 2).
- Produces:
  - `struct DisplayStatus: Sendable, Equatable { struct Line: Sendable, Equatable { var text: String; var highlightMask: String; var sizeFlag: Character }; var lines: [Line]; var trailing: [String]; init(fields: [String]) throws; var softKeyLabels: [String] }`
  - `enum DisplayStatusError: Error, Equatable { case tooFewFields(expected: Int, got: Int) }`

Structure, verified on hardware: `fields[0]` is a flag string with one character per display line (N = `fields[0].count`). The next 2N fields are `(text, highlightMask)` pairs. Everything after that is `trailing`. `softKeyLabels` is the last line's text split on runs of spaces, with empty pieces dropped. Line text may contain control characters (`\u{1A}\u{1B}`); keep them.

- [ ] **Step 1: Create the fixture** with the exact bytes captured on 2026-11-08 (since sanitized: real names, frequencies, and IDs replaced with fictional values of the same length; see `Sources/NoctuleKitTestSupport/Fixtures/README.md`). The two `�` characters are where the scanner sent non-UTF-8 glyph bytes.

```bash
python3 -I -c 'open("Tests/NoctuleKitTests/Fixtures/sts-trunk-sds200-1.24.00.txt","w",encoding="utf-8").write("STS,00001010100000000,              Nov.8 13:22 ��  ,                              ,F0:***3****** DATA          \x1a\x1b,                              ,S0:-12345*---   VOL: 2 SQL: 1 ,                              ,D0:----4-----   Tag:--.--.--- ,                              ,Lakeview Water & Power Co. P25,                              ,lakeworks                     ,                              ,                              ,                              ,Northside Primary             ,                              ,ID Searching...               ,                              ,                              ,                              ,                              ,                              ,Sys ID: 4D1h     935.512500MHz,                              ,RFSS ID: 2      Site ID: 7    ,                              ,WACN: ---       NOISE:12183   ,                              ,UID: ---        RSSI:-101dBm  ,                              ,                              ,                              , SYSTEM      DEPT     CHANNEL ,********* ********** *********,1,1,0,0,,,1,OFF,3\r")'
```

- [ ] **Step 2: Write the failing tests**

```swift
@Test func parsesRealCapture() throws {
    var a = UDPDatagramAssembler()
    guard case .fields("STS", let f) = a.feed(fixture("sts-trunk-sds200-1.24.00.txt")).first else { Issue.record(); return }
    let s = try DisplayStatus(fields: f)
    #expect(s.lines.count == 17)
    #expect(s.lines[4].text.hasPrefix("Lakeview Water & Power Co. P25"))
    #expect(s.lines[1].text.contains("\u{1A}\u{1B}"))
    #expect(s.lines[16].highlightMask == "********* ********** *********")
    #expect(s.softKeyLabels == ["SYSTEM", "DEPT", "CHANNEL"])
    #expect(s.trailing == ["1", "1", "0", "0", "", "", "1", "OFF", "3"])
    #expect(s.lines.map(\.sizeFlag) == Array("00001010100000000"))
}
@Test func rejectsTruncated() {
    #expect(throws: DisplayStatusError.tooFewFields(expected: 7, got: 3)) { try DisplayStatus(fields: ["000", "a", "b"]) }
}
```

`expected` is `1 + 2N`. The assembler gets the fixture as raw `Data`, so this also exercises decoding.

- [ ] **Step 3: Run `swift test --filter DisplayStatusTests`**: expect FAIL.
- [ ] **Step 4: Implement `DisplayStatus` and `DisplayStatusError`.**
- [ ] **Step 5: Run it again**: expect PASS.
- [ ] **Step 6: Commit:** `feat: parse STS display status`

---

### Task 5: Scanner models and front-panel keys

**Files:**
- Create: `Sources/NoctuleKit/Models/ScannerModel.swift`
- Create: `Sources/NoctuleKit/Models/FrontPanelKey.swift`
- Create: `Tests/NoctuleKitTests/ScannerModelTests.swift`

**Interfaces:**
- Produces:
  - `enum ScannerModel: String, Sendable, CaseIterable { case sds100 = "SDS100", sds150 = "SDS150", sds200 = "SDS200", bcd436hp = "BCD436HP"; init?(reported: String) }`. `reported` is trimmed and upper-cased; `"SDS150GBT"` maps to `.sds150`.
  - `enum TransportKind: String, Sendable { case network, usbSerial, bluetooth }`
  - `struct ModelProfile: Sendable, Equatable { let model: ScannerModel; let volumeRange: ClosedRange<Int>?; let squelchRange: ClosedRange<Int>?; let transports: Set<TransportKind>; let protocolVerifiedOnHardware: Bool; static func profile(for: ScannerModel) -> ModelProfile }`
  - `enum FrontPanelKey: String, Sendable, CaseIterable` with raw codes: `menu "M"`, `function "F"`, `avoid "L"`, `digit0`…`digit9` `"0"`…`"9"`, `dotNo "."`, `enterYes "E"`, `scrollRight ">"`, `scrollLeft "<"`, `scrollPush "^"`, `volumePush "V"`, `squelchPush "Q"`, `replay "Y"`, `soft1 "A"`, `soft2 "B"`, `soft3 "C"`, `zip "Z"`, `serviceType "T"`, `range "R"`.

Profile values: SDS200 `0...29`/`0...19`, `[.network, .usbSerial]`, verified `true`. SDS100 `0...15`/`0...15`, `[.usbSerial]`, verified `true` (per the `sds200` library). SDS150 `0...15`/`0...15`, `[.usbSerial, .bluetooth]`, verified `false`. BCD436HP `nil`/`nil`, `[.usbSerial]`, verified `false`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func normalizesReportedModels() {
    #expect(ScannerModel(reported: "SDS200") == .sds200)
    #expect(ScannerModel(reported: " sds150gbt ") == .sds150)
    #expect(ScannerModel(reported: "UBC125XLT") == nil)
}
@Test func sds200Profile() {
    let p = ModelProfile.profile(for: .sds200)
    #expect(p.volumeRange == 0...29); #expect(p.squelchRange == 0...19)
    #expect(p.transports == [.network, .usbSerial])
}
@Test func keyCodes() {
    #expect(FrontPanelKey.avoid.rawValue == "L"); #expect(FrontPanelKey.scrollPush.rawValue == "^")
    #expect(FrontPanelKey.allCases.count == 27)
}
```

- [ ] **Step 2: Run `swift test --filter ScannerModelTests`**: expect FAIL.
- [ ] **Step 3: Implement the types.**
- [ ] **Step 4: Run it again**: expect PASS.
- [ ] **Step 5: Commit:** `feat: scanner model profiles and front-panel key codes`

---

### Task 6: Transport protocol, simulated scanner, and `ScannerClient`

**Files:**
- Create: `Sources/NoctuleKit/Transport/ScannerTransport.swift`
- Create: `Sources/NoctuleKit/Client/ScannerClient.swift`
- Create: `Sources/NoctuleKitTestSupport/SimulatedScannerTransport.swift`
- Create: `Tests/NoctuleKitTests/ScannerClientTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  - `protocol ScannerTransport: Sendable { func open() async throws; func send(_ command: ScannerCommand) async throws; var responses: AsyncStream<ScannerResponse> { get }; func close() async }`. Transports deliver fully assembled responses.
  - `actor ScannerClient`:
    - `init(transport: any ScannerTransport, commandTimeout: Duration = .seconds(2))`
    - `func connect() async throws`
    - `func disconnect() async`: sends `PSI,0` if a push is active (best effort), then closes.
    - `func send(_ command: ScannerCommand) async throws -> ScannerResponse`
    - `func modelInfo() async throws -> (reported: String, model: ScannerModel?)`
    - `func firmwareVersion() async throws -> String`: `"Version 1.24.00"` becomes `"1.24.00"`.
    - `func volume() async throws -> Int`, `func setVolume(_ level: Int) async throws`, `func squelch() async throws -> Int`, `func setSquelch(_ level: Int) async throws`
    - `func scannerInfo() async throws -> ScannerInfo` (GSI)
    - `func displayStatus() async throws -> DisplayStatus` (STS)
    - `func press(_ key: FrontPanelKey) async throws`: sends `KEY,<code>,P` and expects `KEY,OK`.
    - `func startPush(interval: Duration = .milliseconds(500)) async throws -> AsyncStream<ScannerInfo>`: sends `PSI,<ms>`, doesn't wait for an ack, and finishes the stream if a `PSI,NG/ERR` arrives.
    - `func stopPush() async throws`: sends `PSI,0` and finishes the stream.
  - `enum ScannerClientError: Error, Equatable { case notConnected; case timeout(command: String); case rejected(command: String, response: String); case unexpectedResponse(command: String) }`
  - In `NoctuleKitTestSupport`: `actor SimulatedScannerTransport: ScannerTransport { init(reply: @escaping @Sendable (ScannerCommand) -> [ScannerResponse]); var sentCommands: [ScannerCommand] { get }; func emit(_ response: ScannerResponse) }` (unsolicited), plus `static func sds200() -> SimulatedScannerTransport`, which answers `MDL`, `VER`, `VOL`, `SQL`, `GSI` (from the Task 3 fixture), `STS` (from the Task 4 fixture), `KEY` (`OK`), and `PSI` (no reply).

Routing rules: only one request is in flight at a time; queue the rest. A response satisfies the pending request when its `command` equals the request's name, except `.xml(command: "PSI", …)`, which always goes to the push stream. Responses that match nothing are dropped. `.rejected` status throws `rejected`. A request with no matching response within `commandTimeout` throws `timeout` and frees the slot.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func readsIdentity() async throws {
    let c = ScannerClient(transport: SimulatedScannerTransport.sds200()); try await c.connect()
    let m = try await c.modelInfo(); #expect(m.model == .sds200)
    #expect(try await c.firmwareVersion() == "1.24.00")
}
@Test func timesOutWhenScannerIsSilent() async throws {
    let c = ScannerClient(transport: SimulatedScannerTransport { _ in [] }, commandTimeout: .milliseconds(100))
    try await c.connect()
    let start = ContinuousClock.now
    await #expect(throws: ScannerClientError.timeout(command: "MDL")) { _ = try await c.modelInfo() }
    #expect(ContinuousClock.now - start < .seconds(1))
}
@Test func pushDoesNotSatisfyPendingCommand() async throws {
    // Transport replies to GSI only after first emitting an unsolicited .xml("PSI", …) push.
    // Expect scannerInfo() to return the GSI document, and the push stream to receive the PSI one.
}
@Test func rejectedCommandThrows() async throws {
    let t = SimulatedScannerTransport { _ in [.fields(command: "VOL", fields: ["NG"])] }
    let c = ScannerClient(transport: t); try await c.connect()
    await #expect(throws: ScannerClientError.rejected(command: "VOL", response: "VOL,NG")) { try await c.setVolume(3) }
}
@Test func pressSendsKeyCommand() async throws {
    let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
    try await c.press(.avoid)
    #expect(await t.sentCommands.last == (try ScannerCommand("KEY", "L", "P")))
}
@Test func disconnectStopsActivePush() async throws {
    let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
    _ = try await c.startPush(interval: .milliseconds(500))
    await c.disconnect()
    let sent = await t.sentCommands
    #expect(sent.contains(try ScannerCommand("PSI", "500")))
    #expect(sent.last == (try ScannerCommand("PSI", "0")))
}
```

- [ ] **Step 2: Run `swift test --filter ScannerClientTests`**: expect FAIL.
- [ ] **Step 3: Implement `ScannerTransport`, `ScannerClient`, `ScannerClientError`, and `SimulatedScannerTransport`.** The client starts one long-lived task in `connect()` that consumes `transport.responses` and routes them. Implement timeouts with a task group racing the reply against `Task.sleep(for:)`.
- [ ] **Step 4: Run it again**: expect PASS. Run it 20 times (`for i in $(seq 20); do swift test --filter ScannerClientTests || break; done`) and expect no flaky failures.
- [ ] **Step 5: Commit:** `feat: ScannerClient with request routing, timeouts, and PSI push`

---

### Task 7: UDP transport and opt-in hardware tests

**Files:**
- Create: `Sources/NoctuleKit/Transport/UDPTransport.swift`
- Create: `Sources/NoctuleDevConfig/DevScannerConfig.swift`
- Create: `Tests/NoctuleKitTests/UDPTransportTests.swift`
- Create: `Tests/NoctuleKitTests/HardwareTests.swift`

**Interfaces:**
- Consumes: `ScannerTransport`, `UDPDatagramAssembler`, `ScannerClient`.
- Produces:
  - `actor UDPTransport: ScannerTransport { init(host: String, port: UInt16 = 50536) }`. It uses `NWConnection` with `.udp`. `send` calls `assembler.expectXML(for:)` for `GSI`/`PSI` (and for `PSI` only when the interval isn't `0`) before writing. Every received datagram goes through one `UDPDatagramAssembler`.
  - `struct DevScannerConfig: Sendable { var host: String; var port: UInt16; static func load(from url: URL) throws -> DevScannerConfig; static func defaultURL(searchingUpFrom: URL) -> URL? }`. It parses `KEY=VALUE` lines, ignoring `#` comments and blank lines. `host` is `SCANNER_HOST`, falling back to `SCANNER_IP`. `port` is `SCANNER_UDP_PORT`, defaulting to `50536`. `defaultURL` walks up from the given directory to find `config/dev-scanner.env`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func loopbackRoundTrip() async throws {
    // Start an NWListener (UDP, 127.0.0.1, port 0) that answers "MDL\r" with "MDL,SDS200\r"
    // and answers "GSI\r" with two fragment datagrams (No=1 EOT=0, then No=2 EOT=1).
    // ScannerClient over UDPTransport(host: "127.0.0.1", port: listenerPort):
    //   modelInfo().model == .sds200; scannerInfo().system?.name == fragment-1 system name.
}
@Test func unreachableScannerTimesOut() async throws {
    // UDPTransport to 127.0.0.1 on an unused port, commandTimeout 200 ms:
    // modelInfo() throws .timeout(command: "MDL") within 1 s.
}
@Test func parsesDevConfig() throws {
    // Write "# c\nSCANNER_HOST=\nSCANNER_IP=192.0.2.10\n" to a temp file.
    // Expect host "192.0.2.10" and port 50536.
}
```

`HardwareTests.swift`: one suite with `.enabled(if: ProcessInfo.processInfo.environment["NOCTULE_HARDWARE_TESTS"] == "1")`. It loads `DevScannerConfig` and runs read-only checks: `modelInfo().model == .sds200`; `firmwareVersion()` isn't empty; `scannerInfo().mode != nil`; `displayStatus().softKeyLabels` isn't empty. Then `startPush` must receive at least one `ScannerInfo` within 3 s, and it must call `stopPush()` in a `defer`-style cleanup that runs even if the expectation fails.

- [ ] **Step 2: Run `swift test --filter "UDPTransportTests"`**: expect FAIL.
- [ ] **Step 3: Implement `UDPTransport` and `DevScannerConfig`.**
- [ ] **Step 4: Run `swift test`**: expect PASS, with hardware tests skipped.
- [ ] **Step 5: Run `NOCTULE_HARDWARE_TESTS=1 swift test --filter HardwareTests`** against the owner's scanner: expect PASS. If the scanner is unreachable, record that and continue; don't retry in a loop.
- [ ] **Step 6: Commit:** `feat: UDP transport, dev config, opt-in hardware tests`

---

### Task 8: `noctule` CLI and project docs

**Files:**
- Modify: `Package.swift` (add the `noctule` executable target)
- Create: `Sources/noctule/main.swift`
- Modify: `AGENTS.md` (Build and test section)
- Modify: `LESSONS.md` (anything learned in Tasks 1–8)

**Interfaces:**
- Consumes: `ScannerClient`, `UDPTransport`, `DevScannerConfig`.
- Produces: `swift run noctule <subcommand> [--host H] [--port P]`. These subcommands are read-only:
  - `info`: prints model, firmware, volume, and squelch, one per line as `key: value`.
  - `status`: one `GSI`, printing system, department, channel, TGID, UID, site, frequency, modulation, tone/code, and RSSI, one per line.
  - `display`: one `STS`, printing each line's text, then a line `soft keys: A | B | C`.
  - `watch [--interval MS] [--count N]`: starts `PSI` and prints one summary line per update (`HH:MM:SS  <system> / <channel>  TG <id>  UID <id>  <freq> MHz  RSSI <n>`). It stops after N updates or on SIGINT. **It always sends `PSI,0` before exiting**: install a `DispatchSource` SIGINT handler that triggers `client.disconnect()`.
  - Without `--host`, the host comes from `DevScannerConfig.defaultURL(searchingUpFrom: currentDirectory)`. If neither is available, print `No scanner address: pass --host or create config/dev-scanner.env (see config/dev-scanner.env.example)` and exit with code 2.

- [ ] **Step 1: Implement `main.swift`.** Parse arguments by hand; there's no ArgumentParser dependency.
- [ ] **Step 2: Run `swift build`**: expect success.
- [ ] **Step 3: Run `swift run noctule info`** against the owner's scanner: expect `model: SDS200` and `firmware: 1.24.00` (or the current version).
- [ ] **Step 4: Run `swift run noctule watch --count 5`**: expect 5 lines. Then run `swift run noctule info` again and confirm no stray `PSI` output arrives, which shows the push stopped.
- [ ] **Step 5: Update `AGENTS.md`.** Replace the Build and test placeholder with `swift build`, `swift test`, `NOCTULE_HARDWARE_TESTS=1 swift test --filter HardwareTests`, and `swift run noctule info|status|display|watch`.
- [ ] **Step 6: Add dated entries to `LESSONS.md`** for anything surprising, such as `PSI` acknowledgement behavior, fragment sizes seen on hardware, or Network.framework quirks.
- [ ] **Step 7: Run `swift test`**: expect PASS.
- [ ] **Step 8: Commit:** `feat: noctule read-only CLI; document build and test commands`
