// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Dispatch
import Foundation
import Synchronization
import NoctuleAudioPlayback
import NoctuleCLICore
import NoctuleKit
import NoctuleStore

// `noctule listen --station` on a USB station with an audio input (Plan 19; line-in design §7): the
// input alone, played, recorded and metered. It opens no serial port, takes no station lock, sends
// the scanner nothing, and never reads or writes the RTSP cooldown record, so `log` can run on the
// same station beside it. Nonisolated, as ListenCommand.swift is: the signal handlers run on a
// global queue and touch only the Sendable values passed to them.

/// Everything this run writes to stderr, in one order: the status lines (`LineInListenStatus`) and,
/// with `--meter`, the meter (`MeterOutput`: in place on a terminal, a line a second otherwise).
final class LineInListenScreen: Sendable {
    private struct State {
        var status: LineInListenStatus
        var output: MeterOutput
    }
    private let state: Mutex<State>

    init(config: LineInConfig, isTerminal: Bool) {
        state = Mutex(State(status: LineInListenStatus(config: config), output: MeterOutput(isTerminal: isTerminal)))
    }

    /// Takes a state of the source and prints its line; true when the run must end (the line said why).
    func handle(_ lineInState: LineInState) -> Bool {
        state.withLock { s in
            switch s.status.handle(lineInState) {
            case .none: return false
            case .print(let line):
                write(s.output.status(line))
                return false
            case .fail(let line):
                write(s.output.status(line))
                return true
            }
        }
    }

    /// The input has streamed at least once in this run.
    var hasStreamed: Bool { state.withLock { $0.status.hasStreamed } }

    func handle(_ level: LineInLevel) {
        state.withLock { $0.status.handle(level) }
    }

    /// Draws the meter, unless the input isn't streaming (no stale bar while it is missing).
    func drawMeter() {
        state.withLock { s in
            guard let line = s.status.meterLine(at: .now) else { return }
            write(s.output.meter(line))
        }
    }

    func status(_ line: String) {
        state.withLock { s in write(s.output.status(line)) }
    }

    /// Ends a meter line still drawn in place.
    func finish() {
        state.withLock { s in write(s.output.finish()) }
    }

    /// `fputs` (a closed pipe is just an error; SIGPIPE is ignored in main.swift).
    private func write(_ text: String) {
        guard !text.isEmpty else { return }
        fputs(text, stderr)
        fflush(stderr)
    }
}

enum LineInListen {
    /// Runs `listen --station` on a line-in and returns the exit status: 0 after `--seconds`, 128 +
    /// signo on a stop signal, 1 when the input can't be opened (denied, the kill-switch, or a
    /// failure before it ever streamed) or a recording or playback fails. A missing input is a wait,
    /// not a failure, and so is one that fails after it has streamed: the source watches for it and
    /// streams again when it is back. On every path the source is stopped and the WAV closed
    /// before this returns; a run that fails before the input ever streamed removes it. Nothing is
    /// read from or written for `station` here.
    static func run(station: Station, config: LineInConfig, source: any LineInSource, options: ListenOptions,
                    meter: Bool) async -> Int32 {
        let screen = LineInListenScreen(config: config, isTerminal: isatty(STDERR_FILENO) != 0)
        let control = ListenControl(stillClosing: { screen.status("audio: still closing the audio input…") })
        let signalSources = installListenSignalHandlers(control: control)
        defer { signalSources.forEach { $0.cancel() } }

        var recorder: ListenRecorder?
        if let path = options.record {
            do {
                recorder = try ListenRecorder(url: URL(fileURLWithPath: path))
            } catch {
                screen.status("audio: can't write \(path): \(error)")
                return 1
            }
        }

        // Follow the source before starting it, so its first states are seen.
        let chunks = source.chunks, levels = source.levels, states = source.states
        let statesTask = Task {
            for await state in states {
                if screen.handle(state) { control.request(.inputFailed) }
            }
        }
        let levelsTask = Task {
            for await level in levels { screen.handle(level) }
        }

        // Fan the chunks out to the recorder and the player, as `ListenCommand` does.
        let (playChunks, playContinuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(250))
        let play = options.play
        let pumpTask = Task { [recorder] in
            var recording = recorder != nil
            for await chunk in chunks {
                if recording, let recorder {
                    do { try await recorder.append(chunk.samples) } catch {
                        recording = false
                        control.request(.recordFailed("\(error)"))
                    }
                }
                if play { playContinuation.yield(chunk) }
            }
            playContinuation.finish()
            // The source finishes its chunks only when stopped; an earlier end is a failure.
            control.request(.streamEnded)
        }

        var player: AudioPlayer?
        var playTask: Task<Void, Never>?
        if play {
            let p = AudioPlayer(prefillSamples: AudioPlayer.lineInPrefillSamples)
            player = p
            playTask = Task {
                do { try await p.play(playChunks) } catch {
                    control.request(.playbackFailed("\(error)"))
                }
            }
        } else {
            playContinuation.finish()
        }

        let flushTask = recorder.map { recorder in
            Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    do { try await recorder.flush() } catch {
                        control.request(.recordFailed("\(error)"))
                        return
                    }
                }
            }
        }
        let meterTask = meter ? Task {
            let interval = LineInTextMeter.redrawInterval(isTerminal: isatty(STDERR_FILENO) != 0)
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                screen.drawMeter()
            }
        } : nil
        let timerTask = options.seconds.map { seconds in
            Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                control.request(.elapsed)
            }
        }

        // Not awaited, as the runner doesn't: a start may wait on the permission prompt, and a stop
        // signal must not wait on it.
        Task { await source.start() }

        var reason = ListenStop.streamEnded
        for await stop in control.stops {
            reason = stop
            break
        }

        // Shutdown, in order: stop the source (which finishes its three streams), drain the tasks
        // that follow them, stop the player, end the meter's line, then close the WAV.
        control.beginClosing()
        timerTask?.cancel()
        flushTask?.cancel()
        meterTask?.cancel()
        await source.stop()
        await statesTask.value
        await levelsTask.value
        await pumpTask.value
        await flushTask?.value
        await meterTask?.value
        player?.stop()
        await playTask?.value
        screen.finish()

        var code: Int32
        switch reason {
        case .elapsed: code = 0
        case .interrupted: code = control.interruptExitCode
        case .inputFailed: code = 1
        case .streamEnded:
            code = 1
            if !control.isInterrupted { screen.status("audio: the audio input ended unexpectedly") }
        case .playbackFailed(let message):
            code = 1
            screen.status("audio: playback failed: \(message)")
        case .recordFailed(let message):
            code = 1
            screen.status("audio: recording failed: \(message)")
        }
        if let recorder, let path = options.record {
            do { try await recorder.close() } catch {
                screen.status("audio: couldn't finish \(path): \(error)")
                code = 1
            }
            // A run that fails before the input ever streamed (the kill-switch, a denial) recorded
            // nothing: leave no empty WAV behind.
            if code != 0, !control.isInterrupted, !screen.hasStreamed {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        // A stop signal at any point reports as an interrupt (as RTSP `listen` does).
        return control.isInterrupted ? control.interruptExitCode : code
    }
}
