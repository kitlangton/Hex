//
//  AudioPlayer.swift
//  HexIOS
//
//  Small AVAudioPlayer wrapper for playing back a transcript's retained audio
//  (RC-0) in the History detail view. Observable so the player bar reflects
//  play/pause + progress; finish is detected by polling (no delegate needed).
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlayer {
    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var progress: Double { duration > 0 ? currentTime / duration : 0 }

    func load(_ url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        tickTask?.cancel()
    }

    func seek(toFraction fraction: Double) {
        guard let player else { return }
        let clamped = min(max(fraction, 0), 1)
        player.currentTime = clamped * duration
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        tickTask?.cancel()
        isPlaying = false
        currentTime = 0
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, let player = self.player {
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    // Reached the end (vs. an explicit pause, which cancels this task).
                    if self.currentTime >= self.duration - 0.1 {
                        player.currentTime = 0
                        self.currentTime = 0
                    }
                    self.isPlaying = false
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
