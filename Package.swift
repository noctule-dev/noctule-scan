// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import PackageDescription

let package = Package(
    name: "NoctuleScan",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "NoctuleKit", targets: ["NoctuleKit"]),
        .library(name: "NoctuleStore", targets: ["NoctuleStore"]),
        .library(name: "NoctuleAppCore", targets: ["NoctuleAppCore"]),
        .executable(name: "noctule", targets: ["noctule"]),
        .executable(name: "noctule-mock-scanner", targets: ["noctule-mock-scanner"]),
        .executable(name: "NoctuleScan", targets: ["NoctuleScan"]),
    ],
    targets: [
        // IOKit lists USB serial ports (`IOKitSerialPortFinder`, macOS only).
        .target(name: "NoctuleKit", linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]),
        .target(
            name: "NoctuleKitTestSupport",
            dependencies: ["NoctuleKit"],
            resources: [.copy("Fixtures")]
        ),
        // Loopback fakes of the scanner (audio servers, UDP control, and the composed MockSDS200),
        // for tests and for developing features without the real scanner.
        .target(name: "NoctuleMockScanner", dependencies: ["NoctuleKit"], resources: [.copy("Scenarios")]),
        .executableTarget(name: "noctule-mock-scanner", dependencies: ["NoctuleMockScanner"]),
        .testTarget(name: "NoctuleMockScannerTests", dependencies: ["NoctuleMockScanner", "NoctuleKit", "NoctuleKitTestSupport"]),
        .target(name: "NoctuleDevConfig"),
        // Speaker playback (AVAudioEngine). Kept out of NoctuleKit so the shared code never imports AVFAudio.
        .target(name: "NoctuleAudioPlayback", dependencies: ["NoctuleKit"], linkerSettings: [.linkedFramework("AVFAudio")]),
        .testTarget(name: "NoctuleAudioPlaybackTests", dependencies: ["NoctuleAudioPlayback", "NoctuleKit"]),
        // Line-in capture (AVAudioEngine on an input device, through a sink node) and the pipeline that
        // turns its buffers into recorder chunks and meter levels. Kept out of NoctuleKit so the shared
        // code never imports AVFAudio; macOS only for now.
        .target(name: "NoctuleAudioCapture", dependencies: ["NoctuleKit"],
                linkerSettings: [.linkedFramework("AVFAudio"), .linkedFramework("CoreAudio", .when(platforms: [.macOS]))]),
        .testTarget(name: "NoctuleAudioCaptureTests", dependencies: ["NoctuleAudioCapture", "NoctuleKit", "NoctuleMockScanner", "NoctuleKitTestSupport"]),
        // Station model, hit log and settings storage. No UI frameworks, so it builds for iOS.
        .target(name: "NoctuleStore", dependencies: ["NoctuleKit"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "NoctuleStoreTests", dependencies: ["NoctuleStore", "NoctuleKit", "NoctuleMockScanner", "NoctuleKitTestSupport"]),
        // The app's view-model layer. No SwiftUI/AppKit/AVFAudio, so it builds for iOS.
        .target(name: "NoctuleAppCore", dependencies: ["NoctuleKit", "NoctuleStore"]),
        // The Mac app (SwiftUI + AppKit). `scripts/build-app.sh` wraps this executable in
        // `build/Noctule Scan.app` with `Resources/Info.plist` and the icon compiled
        // from the branding folder's `AppIcon.icon`, or the placeholder (`scripts/compile-app-icon.sh`). macOS only.
        .executableTarget(name: "NoctuleScan",
                          dependencies: ["NoctuleAppCore", "NoctuleAudioPlayback", "NoctuleAudioCapture", "NoctuleStore", "NoctuleKit"]),
        // Unit tests of the app's own logic (`@testable import` of the executable; macOS only).
        .testTarget(name: "NoctuleScanTests",
                    dependencies: ["NoctuleScan", "NoctuleAppCore", "NoctuleAudioCapture", "NoctuleKit", "NoctuleStore",
                                   "NoctuleMockScanner", "NoctuleKitTestSupport"]),
        .testTarget(name: "NoctuleAppCoreTests", dependencies: ["NoctuleAppCore", "NoctuleMockScanner", "NoctuleKitTestSupport"]),
        .target(name: "NoctuleCLICore", dependencies: ["NoctuleKit", "NoctuleDevConfig", "NoctuleStore"]),
        .executableTarget(name: "noctule", dependencies: ["NoctuleCLICore", "NoctuleKit", "NoctuleDevConfig", "NoctuleAudioPlayback", "NoctuleAudioCapture", "NoctuleStore"]),
        .testTarget(
            name: "NoctuleCLICoreTests",
            dependencies: ["NoctuleCLICore", "NoctuleKit", "NoctuleKitTestSupport", "NoctuleDevConfig", "NoctuleStore"]
        ),
        // Launches the built `noctule` binary against loopback fakes (control UDP, RTSP, and RTP)
        // and against the `noctule-mock-scanner` executable; also launches the `NoctuleScan` app.
        .testTarget(name: "NoctuleCLIIntegrationTests",
                    dependencies: ["noctule", "noctule-mock-scanner", "NoctuleScan", "NoctuleKit", "NoctuleMockScanner",
                                   "NoctuleStore"]),
        .testTarget(
            name: "NoctuleKitTests",
            dependencies: ["NoctuleKit", "NoctuleKitTestSupport", "NoctuleDevConfig", "NoctuleMockScanner"]
        ),
    ]
)
