// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AVFAudio
import Foundation
import Observation

/// One loaded recording. `AVWAVPlayer` is the real one; tests use a fake.
@MainActor
protocol WAVPlayer: AnyObject {
    var duration: TimeInterval { get }
    /// Called once when playback reaches the end (not after `stop()`).
    var onFinish: (@MainActor () -> Void)? { get set }
    func play() -> Bool
    func stop()
}

/// `AVAudioPlayer` on a recording file (the hit log's WAVs are 16-bit 8 kHz mono).
@MainActor
final class AVWAVPlayer: NSObject, WAVPlayer, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: (@MainActor () -> Void)?

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    var duration: TimeInterval { player.duration }
    func play() -> Bool { player.play() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}

/// Plays the hit log's recordings, one at a time: a single transmission (`play`, `toggle`) or a
/// list in order (`playAll`). Starting anything stops what was playing. A file that can't be
/// opened is skipped (in a play-all, the next one starts) and `problem` says why. The window
/// calls `stop()` when it closes.
@MainActor @Observable
final class WAVPlayback {
    struct Item: Equatable, Sendable {
        var id: UUID
        var url: URL
    }

    /// The hit whose recording is playing, if any.
    private(set) var playingID: UUID?
    /// A `playAll` is in progress.
    private(set) var isPlayingAll = false
    /// Why the last file couldn't be played; cleared by the next play.
    private(set) var problem: String?

    @ObservationIgnored private var player: (any WAVPlayer)?
    @ObservationIgnored private var queue: [Item] = []
    @ObservationIgnored private let makePlayer: @MainActor (URL) throws -> any WAVPlayer

    init(makePlayer: @escaping @MainActor (URL) throws -> any WAVPlayer = { try AVWAVPlayer(url: $0) }) {
        self.makePlayer = makePlayer
    }

    /// The recording's length, read the same way playback opens it.
    static func duration(of url: URL) throws -> TimeInterval {
        try AVAudioPlayer(contentsOf: url).duration
    }

    func play(_ item: Item) { start([item], all: false) }

    /// Plays `items` one after another, in the order given.
    func playAll(_ items: [Item]) { start(items, all: true) }

    /// Stops `item` if it is playing, else plays it.
    func toggle(_ item: Item) {
        if playingID == item.id { stop() } else { play(item) }
    }

    func stop() {
        queue = []
        let current = player
        player = nil
        current?.onFinish = nil
        current?.stop()
        playingID = nil
        isPlayingAll = false
    }

    /// Stops playback if it is playing (or about to play) one of `ids`.
    func stop(ifAnyOf ids: Set<UUID>) {
        if let playingID, ids.contains(playingID) { stop(); return }
        queue.removeAll { ids.contains($0.id) }
    }

    private func start(_ items: [Item], all: Bool) {
        stop()
        problem = nil
        queue = items
        isPlayingAll = all
        advance()
    }

    private func advance() {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            let name = item.url.lastPathComponent
            do {
                let next = try makePlayer(item.url)
                next.onFinish = { [weak self, weak next] in
                    guard let self, let next, self.player === next else { return }
                    self.advance()
                }
                player = next
                playingID = item.id
                if next.play() { return }
                player = nil
                problem = "Couldn't play \(name)."
            } catch {
                problem = FileManager.default.fileExists(atPath: item.url.path)
                    ? "Couldn't play \(name): \(error.localizedDescription)"
                    : "The recording \(name) is missing."
            }
        }
        player = nil
        playingID = nil
        isPlayingAll = false
    }
}
#endif
