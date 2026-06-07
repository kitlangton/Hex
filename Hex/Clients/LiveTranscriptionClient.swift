//
//  LiveTranscriptionClient.swift
//  Hex
//

import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio
#endif

struct LiveTranscriptionUpdate: Equatable, Sendable {
  let text: String
  let isConfirmed: Bool
}

@DependencyClient
struct LiveTranscriptionClient {
  var isSupported: @Sendable (String) async -> Bool = { _ in false }
  var prepare: @Sendable (String) async throws -> Void = { _ in }
  var start: @Sendable (String) async throws -> Void = { _ in }
  var feedAudio: @Sendable (AVAudioPCMBuffer) async -> Void = { _ in }
  var observeUpdates: @Sendable () async -> AsyncStream<LiveTranscriptionUpdate> = { AsyncStream { _ in } }
  var finish: @Sendable () async throws -> String = { "" }
  var cancel: @Sendable () async -> Void = {}
}

extension LiveTranscriptionClient: DependencyKey {
  static var liveValue: Self {
    let live = LiveTranscriptionClientLive()
    return Self(
      isSupported: { await live.isSupported($0) },
      prepare: { try await live.prepare(modelName: $0) },
      start: { try await live.start(modelName: $0) },
      feedAudio: { await live.feedAudio($0) },
      observeUpdates: { await live.observeUpdates() },
      finish: { try await live.finish() },
      cancel: { await live.cancel() }
    )
  }

  static let testValue = Self()
}

extension DependencyValues {
  var liveTranscription: LiveTranscriptionClient {
    get { self[LiveTranscriptionClient.self] }
    set { self[LiveTranscriptionClient.self] = newValue }
  }
}

#if canImport(FluidAudio)

actor LiveTranscriptionClientLive {
  private let logger = HexLog.parakeet
  private var manager: StreamingAsrManager?
  private var bridgeTask: Task<Void, Never>?
  private var updateStream: AsyncStream<LiveTranscriptionUpdate>?
  private var updateContinuation: AsyncStream<LiveTranscriptionUpdate>.Continuation?
  private var cachedModels: AsrModels?
  private var cachedVariant: ParakeetModel?
  private var fedBufferCount = 0

  init() {
    resetUpdateStream()
  }

  private func resetUpdateStream() {
    updateContinuation?.finish()
    let (stream, continuation) = AsyncStream<LiveTranscriptionUpdate>.makeStream()
    updateStream = stream
    updateContinuation = continuation
  }

  func isSupported(_ modelName: String) -> Bool {
    ParakeetModel(rawValue: modelName) != nil
  }

  func observeUpdates() -> AsyncStream<LiveTranscriptionUpdate> {
    updateStream ?? AsyncStream { _ in }
  }

  func prepare(modelName: String) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else { return }
    if cachedVariant == variant, cachedModels != nil { return }

    logger.notice("Preparing live transcription models variant=\(variant.identifier)")
    let models = try await AsrModels.downloadAndLoad(version: variant.asrVersion)
    cachedModels = models
    cachedVariant = variant
    logger.notice("Live transcription models ready variant=\(variant.identifier)")
  }

  private func models(for variant: ParakeetModel) async throws -> AsrModels {
    if cachedVariant == variant, let cachedModels {
      return cachedModels
    }
    let models = try await AsrModels.downloadAndLoad(version: variant.asrVersion)
    cachedModels = models
    cachedVariant = variant
    return models
  }

  func start(modelName: String) async throws {
    await cancelSessionOnly()
    resetUpdateStream()

    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "LiveTranscription",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Live transcription is not supported for model \(modelName)"]
      )
    }

    let models = try await models(for: variant)
    let config = streamingConfig(for: variant)
    let manager = StreamingAsrManager(config: config)
    try await manager.start(models: models, source: .microphone)
    self.manager = manager
    fedBufferCount = 0

    logger.notice("Live transcription started variant=\(variant.identifier)")

    bridgeTask = Task { [updateContinuation, logger] in
      guard let updateContinuation else { return }
      var updateCount = 0
      for await update in await manager.transcriptionUpdates {
        guard !Task.isCancelled else { break }

        let confirmed = await manager.confirmedTranscript
        let volatile = await manager.volatileTranscript
        var parts: [String] = []
        if !confirmed.isEmpty { parts.append(confirmed) }
        if !volatile.isEmpty { parts.append(volatile) }

        let displayText = parts.isEmpty ? update.text : parts.joined(separator: " ")
        guard !displayText.isEmpty else { continue }

        updateCount += 1
        if updateCount == 1 {
          logger.notice("Live transcription first update chars=\(displayText.count)")
        }

        updateContinuation.yield(
          LiveTranscriptionUpdate(text: displayText, isConfirmed: update.isConfirmed)
        )
      }
    }
  }

  func feedAudio(_ buffer: AVAudioPCMBuffer) async {
    guard let manager else { return }
    fedBufferCount += 1
    if fedBufferCount == 1 {
      logger.notice("Live transcription feeding first audio buffer frames=\(buffer.frameLength)")
    }
    await manager.streamAudio(buffer)
  }

  func finish() async throws -> String {
    guard let manager else { return "" }

    let result = try await manager.finish()
    self.manager = nil
    bridgeTask?.cancel()
    bridgeTask = nil
    logger.notice(
      "Live transcription finished textLength=\(result.count) fedBuffers=\(self.fedBufferCount)"
    )
    return result
  }

  func cancel() async {
    await cancelSessionOnly()
  }

  private func cancelSessionOnly() async {
    bridgeTask?.cancel()
    bridgeTask = nil
    await manager?.cancel()
    manager = nil
    fedBufferCount = 0
    resetUpdateStream()
  }

  private func streamingConfig(for variant: ParakeetModel) -> StreamingAsrConfig {
    switch variant {
    case .englishV2, .multilingualV3:
      return StreamingAsrConfig(
        chunkSeconds: 0.35,
        hypothesisChunkSeconds: 0.35,
        leftContextSeconds: 0.2,
        rightContextSeconds: 0.1,
        minContextForConfirmation: 0.35,
        confirmationThreshold: 0.45
      )
    }
  }
}

private extension ParakeetModel {
  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2: return .v2
    case .multilingualV3: return .v3
    }
  }
}

#else

actor LiveTranscriptionClientLive {
  func isSupported(_: String) -> Bool { false }
  func prepare(modelName _: String) async throws {}
  func observeUpdates() -> AsyncStream<LiveTranscriptionUpdate> { AsyncStream { _ in } }
  func start(modelName _: String) async throws {}
  func feedAudio(_: AVAudioPCMBuffer) async {}
  func finish() async throws -> String { "" }
  func cancel() async {}
}

#endif
