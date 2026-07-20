//
//  SoundEffect.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import SwiftUI

// Thank you. Never mind then.What a beautiful idea.
public enum SoundEffect: String, CaseIterable {
  case pasteTranscript
  case startRecording
  case stopRecording
  case cancel

  public var fileName: String {
    self.rawValue
  }

  var fileExtension: String {
    "mp3"
  }
}

@DependencyClient
public struct SoundEffectsClient {
  public var play: @Sendable (SoundEffect) -> Void
  public var stop: @Sendable (SoundEffect) -> Void
  public var stopAll: @Sendable () -> Void
  public var preloadSounds: @Sendable () async -> Void
  public var setEnabled: @Sendable (Bool) async -> Void
}

extension SoundEffectsClient: DependencyKey {
  public static var liveValue: SoundEffectsClient {
    let live = SoundEffectsClientLive()
    return SoundEffectsClient(
      play: { soundEffect in
        Task { await live.play(soundEffect) }
      },
      stop: { soundEffect in
        Task { await live.stop(soundEffect) }
      },
      stopAll: {
        Task { await live.stopAll() }
      },
      preloadSounds: {
        await live.preloadSounds()
      },
      setEnabled: { enabled in
        await live.setEnabled(enabled)
      }
    )
  }
}

public extension DependencyValues {
  var soundEffects: SoundEffectsClient {
    get { self[SoundEffectsClient.self] }
    set { self[SoundEffectsClient.self] = newValue }
  }
}

actor SoundEffectsClientLive {
  private let logger = HexLog.sound
  private let baselineVolume = HexSettings.baseSoundEffectsVolume

  private let engine = AVAudioEngine()
  @Shared(.hexSettings) var hexSettings: HexSettings
  private var playerNodes: [SoundEffect: AVAudioPlayerNode] = [:]
  private var audioBuffers: [SoundEffect: AVAudioPCMBuffer] = [:]
  private var activePlaybackTokens: [SoundEffect: UUID] = [:]
  private var playbackTimeoutTasks: [SoundEffect: Task<Void, Never>] = [:]

  func play(_ soundEffect: SoundEffect) {
    guard hexSettings.soundEffectsEnabled else { return }
    guard let player = playerNodes[soundEffect], let buffer = audioBuffers[soundEffect] else {
      logger.error("Requested sound \(soundEffect.rawValue) not preloaded")
      return
    }
    prepareEngineIfNeeded()
    let clampedVolume = min(max(hexSettings.soundEffectsVolume, 0), baselineVolume)
    player.volume = Float(clampedVolume)
    let playbackToken = UUID()
    activePlaybackTokens[soundEffect] = playbackToken
    player.stop()
    player.scheduleBuffer(
      buffer,
      at: nil,
      options: [],
      completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      Task {
        await self?.playbackFinished(soundEffect, token: playbackToken)
      }
    }
    player.play()

    // The played-back callback is the normal shutdown path. Keep a short duration-based
    // fallback in case a route change prevents AVAudioPlayerNode from delivering it.
    playbackTimeoutTasks[soundEffect]?.cancel()
    let playbackDuration = Double(buffer.frameLength) / buffer.format.sampleRate
    playbackTimeoutTasks[soundEffect] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(playbackDuration + 0.5))
      guard !Task.isCancelled else { return }
      await self?.playbackFinished(soundEffect, token: playbackToken)
    }
  }

  private func playbackFinished(_ soundEffect: SoundEffect, token: UUID) {
    guard activePlaybackTokens[soundEffect] == token else { return }
    playbackTimeoutTasks[soundEffect]?.cancel()
    playbackTimeoutTasks[soundEffect] = nil
    activePlaybackTokens[soundEffect] = nil
    playerNodes[soundEffect]?.stop()
    if activePlaybackTokens.isEmpty {
      stopEngineIfNeeded()
    }
  }

  func stop(_ soundEffect: SoundEffect) {
    playerNodes[soundEffect]?.stop()
    playbackTimeoutTasks[soundEffect]?.cancel()
    playbackTimeoutTasks[soundEffect] = nil
    activePlaybackTokens[soundEffect] = nil
    if activePlaybackTokens.isEmpty {
      stopEngineIfNeeded()
    }
  }

  func stopAll() {
    playerNodes.values.forEach { $0.stop() }
    playbackTimeoutTasks.values.forEach { $0.cancel() }
    playbackTimeoutTasks.removeAll()
    activePlaybackTokens.removeAll()
    stopEngineIfNeeded()
  }

  func preloadSounds() async {
    guard !isSetup else { return }

    for soundEffect in SoundEffect.allCases {
      loadSound(soundEffect)
    }

    isSetup = true
  }

  func setEnabled(_: Bool) async {
    await preloadSounds()

    // No prewarm on enable: play() starts the engine lazily and playback completion
    // releases the output route again.
    if !hexSettings.soundEffectsEnabled {
      stopAll()
    }
  }

  private var isSetup = false

  private func loadSound(_ soundEffect: SoundEffect) {
    guard let url = Bundle.main.url(
      forResource: soundEffect.fileName,
      withExtension: soundEffect.fileExtension
    ) else {
      logger.error("Missing sound resource \(soundEffect.fileName).\(soundEffect.fileExtension)")
      return
    }

    do {
      let file = try AVAudioFile(forReading: url)
      let frameCount = AVAudioFrameCount(file.length)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
        logger.error("Failed to allocate buffer for \(soundEffect.rawValue)")
        return
      }
      try file.read(into: buffer)
      audioBuffers[soundEffect] = buffer

      let player = AVAudioPlayerNode()
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
      playerNodes[soundEffect] = player
    } catch {
      logger.error("Failed to load sound \(soundEffect.rawValue): \(error.localizedDescription)")
    }
  }

  private func prepareEngineIfNeeded() {
    guard !engine.isRunning else { return }
    engine.prepare()
    if #available(macOS 13.0, *) {
      engine.isAutoShutdownEnabled = false
    }
    do {
      try engine.start()
    } catch {
      logger.error("Failed to start AVAudioEngine: \(error.localizedDescription)")
    }
  }

  private func stopEngineIfNeeded() {
    guard engine.isRunning else { return }
    engine.stop()
    logger.debug("Sound effects engine stopped")
  }

  deinit {
    playerNodes.values.forEach {
      $0.stop()
      engine.detach($0)
    }
    engine.stop()
  }
}
