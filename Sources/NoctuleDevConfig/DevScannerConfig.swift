// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum DevScannerConfigError: Error, Equatable {
    case missingHost
    case invalidPort(String)
}

/// The development scanner's address, read from the git-ignored `config/dev-scanner.env`.
public struct DevScannerConfig: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    /// The RTSP audio server's TCP port: `SCANNER_RTSP_PORT`, default 554.
    public var rtspPort: UInt16

    public init(host: String, port: UInt16 = 50536, rtspPort: UInt16 = 554) {
        self.host = host
        self.port = port
        self.rtspPort = rtspPort
    }

    /// Parses `KEY=VALUE` lines, ignoring blank lines and `#` comments. `host` is
    /// `SCANNER_HOST`, falling back to `SCANNER_IP`; `port` is `SCANNER_UDP_PORT`, default 50536;
    /// `rtspPort` is `SCANNER_RTSP_PORT`, default 554.
    public static func load(from url: URL) throws -> DevScannerConfig {
        let values = try keyValues(from: url)
        let host = [values["SCANNER_HOST"], values["SCANNER_IP"]]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let host else { throw DevScannerConfigError.missingHost }
        var port: UInt16 = 50536
        if let text = values["SCANNER_UDP_PORT"], !text.isEmpty {
            guard let parsed = UInt16(text), parsed != 0 else { throw DevScannerConfigError.invalidPort(text) }
            port = parsed
        }
        var rtspPort: UInt16 = 554
        if let text = values["SCANNER_RTSP_PORT"], !text.isEmpty {
            guard let parsed = UInt16(text), parsed != 0 else { throw DevScannerConfigError.invalidPort(text) }
            rtspPort = parsed
        }
        return DevScannerConfig(host: host, port: port, rtspPort: rtspPort)
    }

    /// `key` from the file (default `SCANNER_SERIAL`, the serial port path for `--serial`; the
    /// SDS100's hardware suites read `SCANNER_SERIAL_SDS100`), or nil when the key is absent, empty
    /// or `auto` (any case; the port finder then decides). Needs no `SCANNER_HOST`, so a
    /// serial-only file is valid. Throws when the file can't be read.
    public static func serialPath(from url: URL, key: String = "SCANNER_SERIAL") throws -> String? {
        guard let value = try keyValues(from: url)[key], !value.isEmpty,
              value.lowercased() != "auto" else { return nil }
        return value
    }

    /// The file's `KEY=VALUE` lines, ignoring blank lines and `#` comments; values are trimmed.
    private static func keyValues(from url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }

    /// Walks up from `start` (a file or directory) looking for `config/dev-scanner.env`.
    public static func defaultURL(searchingUpFrom start: URL) -> URL? {
        let fileManager = FileManager.default
        var directory = start.standardizedFileURL
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            directory = directory.deletingLastPathComponent()
        }
        // Walk by path components: URL.deletingLastPathComponent() on "/" (or a temp path that
        // resolves oddly) can yield "/.." forever instead of stopping at the root.
        var components = directory.pathComponents
        while !components.isEmpty {
            let candidate = NSString.path(withComponents: components + ["config", "dev-scanner.env"])
            if fileManager.fileExists(atPath: candidate) { return URL(fileURLWithPath: candidate) }
            components.removeLast()
        }
        return nil
    }
}
