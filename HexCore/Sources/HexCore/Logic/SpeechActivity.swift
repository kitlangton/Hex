import Foundation

/// Peak audio levels observed during a recording session or PCM snapshot.
public struct SpeechActivityMetrics: Equatable, Sendable {
  public var peakRMS: Double
  public var peakSample: Double

  public init(peakRMS: Double, peakSample: Double) {
    self.peakRMS = peakRMS
    self.peakSample = peakSample
  }

  public static let zero = SpeechActivityMetrics(peakRMS: 0, peakSample: 0)

  public mutating func merge(_ other: SpeechActivityMetrics) {
    peakRMS = max(peakRMS, other.peakRMS)
    peakSample = max(peakSample, other.peakSample)
  }

  /// Computes peak RMS and sample magnitude for normalized float32 mono PCM.
  public static func analyze(samples: [Float]) -> SpeechActivityMetrics {
    guard !samples.isEmpty else { return .zero }

    var sumOfSquares: Double = 0
    var peak: Double = 0
    for sample in samples {
      let magnitude = Double(abs(sample))
      sumOfSquares += Double(sample) * Double(sample)
      peak = max(peak, magnitude)
    }

    let rms = sqrt(sumOfSquares / Double(samples.count))
    return SpeechActivityMetrics(peakRMS: rms, peakSample: peak)
  }
}

/// Detects whether captured audio likely contains speech vs silence/noise.
public enum SpeechActivityGate {
  /// Both must be met for normal speech — Bluetooth idle noise often spikes peak without sustained RMS.
  public static let minimumPeakRMS: Double = 0.015
  public static let minimumPeakSample: Double = 0.050
  /// Quieter speech still needs both RMS and peak to avoid BT spike false positives.
  public static let whisperPeakRMS: Double = 0.008
  public static let whisperPeakSample: Double = 0.038
  /// Louder evidence required before accepting hallucination-prone short phrases.
  public static let strongPeakRMS: Double = 0.030
  public static let strongPeakSample: Double = 0.10
  /// Trailing window used to detect current speech vs earlier audio in a growing preview buffer.
  public static let previewRecentWindow: TimeInterval = 0.75
  /// Longer window — keeps transcribing through brief between-word pauses.
  public static let previewHoldWindow: TimeInterval = 1.5
  /// Window size for estimating a noise floor from the quietest segments.
  public static let noiseAnalysisWindow: TimeInterval = 0.25
  /// Recent speech RMS must exceed the noise floor by this factor (weak speech only).
  public static let minimumSpeechToNoiseRatio: Double = 1.6

  public static func hasWhisperActivity(_ metrics: SpeechActivityMetrics) -> Bool {
    guard metrics.peakRMS >= whisperPeakRMS, metrics.peakSample >= whisperPeakSample else {
      return false
    }
    // Require sustained energy — BT idle noise often spikes peak without RMS.
    return metrics.peakRMS >= metrics.peakSample * 0.12
  }

  public static func hasSpeechActivity(_ metrics: SpeechActivityMetrics) -> Bool {
    hasWhisperActivity(metrics)
      || (metrics.peakRMS >= minimumPeakRMS && metrics.peakSample >= minimumPeakSample)
  }

  public static func hasStrongSpeechActivity(_ metrics: SpeechActivityMetrics) -> Bool {
    metrics.peakRMS >= strongPeakRMS && metrics.peakSample >= strongPeakSample
  }

  /// Returns metrics for the trailing window and whether preview transcription should run.
  public static func evaluatePreviewActivity(
    samples: [Float],
    sampleRate: Double = 16_000
  ) -> (metrics: SpeechActivityMetrics, hasActivity: Bool) {
    let recentSamples = recentSlice(
      samples,
      sampleRate: sampleRate,
      windowDuration: previewRecentWindow
    )
    let recentMetrics = SpeechActivityMetrics.analyze(samples: recentSamples)

    if windowHasSpeechActivity(
      samples: samples,
      sampleRate: sampleRate,
      windowDuration: previewRecentWindow,
      metrics: recentMetrics
    ) {
      return (recentMetrics, true)
    }

    let holdSamples = recentSlice(
      samples,
      sampleRate: sampleRate,
      windowDuration: previewHoldWindow
    )
    let holdMetrics = SpeechActivityMetrics.analyze(samples: holdSamples)
    if windowHasSpeechActivity(
      samples: samples,
      sampleRate: sampleRate,
      windowDuration: previewHoldWindow,
      metrics: holdMetrics
    ) {
      return (recentMetrics, true)
    }

    return (recentMetrics, false)
  }

  private static func windowHasSpeechActivity(
    samples: [Float],
    sampleRate: Double,
    windowDuration: TimeInterval,
    metrics: SpeechActivityMetrics
  ) -> Bool {
    guard hasSpeechActivity(metrics) else { return false }

    if hasStrongSpeechActivity(metrics) || hasWhisperActivity(metrics) {
      return true
    }

    if metrics.peakSample >= 0.10, metrics.peakRMS >= minimumPeakRMS {
      return true
    }

    let noiseFloor = estimatedNoiseFloorRMS(
      samples: samples,
      sampleRate: sampleRate,
      analysisDuration: min(windowDuration * 4, Double(samples.count) / sampleRate)
    )
    let requiredRMS = max(minimumPeakRMS, noiseFloor * minimumSpeechToNoiseRatio)
    return metrics.peakRMS >= requiredRMS
  }

  public static func recentSlice(
    _ samples: [Float],
    sampleRate: Double,
    windowDuration: TimeInterval
  ) -> [Float] {
    let windowSamples = max(1, Int((windowDuration * sampleRate).rounded(.up)))
    guard !samples.isEmpty else { return [] }
    let startIndex = max(0, samples.count - windowSamples)
    return Array(samples[startIndex...])
  }

  /// 25th-percentile RMS of overlapping windows — approximates background noise floor.
  public static func estimatedNoiseFloorRMS(
    samples: [Float],
    sampleRate: Double = 16_000,
    windowDuration: TimeInterval = noiseAnalysisWindow,
    analysisDuration: TimeInterval? = nil
  ) -> Double {
    let analysisSamples: [Float]
    if let analysisDuration {
      analysisSamples = recentSlice(
        samples,
        sampleRate: sampleRate,
        windowDuration: analysisDuration
      )
    } else {
      analysisSamples = samples
    }

    let windowSamples = max(1, Int((windowDuration * sampleRate).rounded(.up)))
    let hopSamples = max(1, windowSamples / 2)
    guard analysisSamples.count >= windowSamples else {
      return SpeechActivityMetrics.analyze(samples: analysisSamples).peakRMS
    }

    var windowLevels: [Double] = []
    windowLevels.reserveCapacity(analysisSamples.count / hopSamples)
    var startIndex = 0
    while startIndex + windowSamples <= analysisSamples.count {
      let window = Array(analysisSamples[startIndex ..< startIndex + windowSamples])
      windowLevels.append(SpeechActivityMetrics.analyze(samples: window).peakRMS)
      startIndex += hopSamples
    }

    guard !windowLevels.isEmpty else { return 0 }
    windowLevels.sort()
    // Use the quietest 10% of windows — 25th percentile stays too high during speech.
    let quietIndex = max(0, windowLevels.count / 10)
    return windowLevels[quietIndex]
  }
}

/// Common Parakeet/Whisper phrases on silent or padded audio.
public enum SilentTranscriptionFilter {
  private static let hallucinatedPhrases: Set<String> = [
    "thank you",
    "thanks",
    "thank you for watching",
    "thanks for watching",
    "okay",
    "ok",
    "ok ay",
    "yeah",
    "yes",
    "no",
    "uh",
    "um",
    "hmm",
    "hello",
    "hi",
    "bye",
    "goodbye",
    "you",
    "the",
    "so",
    "well",
    "right",
    "subscribe",
  ]

  public static let maxShortPreviewCharsWithoutStrongSpeech = 8

  public static func normalized(_ text: String) -> String {
    text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
  }

  public static func isLikelyHallucination(_ text: String) -> Bool {
    let normalized = normalized(text)
    guard !normalized.isEmpty else { return false }
    return hallucinatedPhrases.contains(normalized)
  }

  /// Accept real speech; reject silence/noise and common silent-audio hallucinations.
  public static func shouldAcceptTranscription(
    text: String,
    metrics: SpeechActivityMetrics
  ) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if isLikelyHallucination(trimmed) {
      return SpeechActivityGate.hasStrongSpeechActivity(metrics)
    }

    if trimmed.count <= maxShortPreviewCharsWithoutStrongSpeech {
      return SpeechActivityGate.hasStrongSpeechActivity(metrics)
    }

    return SpeechActivityGate.hasSpeechActivity(metrics)
  }
}
