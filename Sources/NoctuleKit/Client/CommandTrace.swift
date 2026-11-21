// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization

/// An opt-in, process-wide trace of what goes over the wire, for diagnosing a scanner that misbehaves on
/// hardware (`NOCTULE_TRACE`, installed by the shells). Off by default, and then `log` costs one lock and
/// never evaluates its message. Every line carries `t=<ms since the sink was installed>`. **Lines never hold
/// a list, system, department, site or channel name, a frequency or a talkgroup**: only command names,
/// indexes, keys, counts, sizes and times, since the owner sends the file to us.
public enum CommandTrace {
    private struct State {
        var sink: (@Sendable (String) -> Void)?
        var started = ContinuousClock.now
    }

    private static let state = Mutex(State())

    /// Sets the sink (nil turns the trace off). Meant to be called once at startup.
    public static func install(_ sink: (@Sendable (String) -> Void)?) {
        state.withLock {
            $0.sink = sink
            $0.started = .now
        }
    }

    /// Whether the environment asks for the trace: `NOCTULE_TRACE` set to anything non-empty. Unlike the
    /// test-only overrides it is honoured with the standard settings too (it is read-only diagnostics).
    public static func isRequested(_ environment: [String: String]) -> Bool {
        !(environment["NOCTULE_TRACE"] ?? "").isEmpty
    }

    public static var isOn: Bool { state.withLock { $0.sink != nil } }

    /// Writes `message` to the sink, stamped; with no sink the message isn't evaluated.
    public static func log(_ message: @autoclosure () -> String) {
        guard let (sink, started) = state.withLock({ state in state.sink.map { ($0, state.started) } }) else { return }
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        sink(String(format: "t=%.3f ", ms) + message())
    }

    /// Whole milliseconds from `start` to now, for "after N ms".
    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// A request as the trace names it: the command and its arguments, except that a long argument list (the
    /// quick-key sets' 100 values) is summarised by the positions that aren't "0".
    static func describe(_ command: ScannerCommand) -> String {
        let arguments = command.arguments
        guard arguments.count > 4 else { return ([command.name] + arguments).joined(separator: ",") }
        let count = min(100, arguments.count)
        let leading = arguments.dropLast(count)
        let set = arguments.suffix(count).enumerated().filter { $0.element != "0" }
            .map { "\($0.offset)=\($0.element)" }
        let summary = "[\(count) values: \(set.isEmpty ? "none" : set.joined(separator: ", "))]"
        return ([command.name] + leading + [summary]).joined(separator: ",")
    }

    /// A response's shape, never its text: `xml <root> children=<n>`, `fields=<n>`, or a lone status.
    static func shape(_ response: ScannerResponse) -> String {
        switch response {
        case .xml(_, let root):
            return "xml \(root.name) children=\(root.children.count)"
        case .fields(_, let fields):
            if fields.count == 1, ["OK", "NG", "ERR", "ERROR"].contains(fields[0]) { return fields[0] }
            return "fields=\(fields.count)"
        }
    }
}
