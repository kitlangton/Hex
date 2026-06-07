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
  /// Minimum RMS for float32 mono PCM at 16 kHz (disconnected/silent mics stay well below this).
  public static let minimumPeakRMS: Double = 0.012
  /// Short spikes from padding/click noise can exceed RMS while still not being speech.
  public static let minimumPeakSample: Double = 0.04

  public static func hasSpeechActivity(_ metrics: SpeechActivityMetrics) -> Bool {
    metrics.peakRMS >= minimumPeakRMS || metrics.peakSample >= minimumPeakSample
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

  /// Accept real speech always; reject silence and common silent-audio hallucinations.
  public static func shouldAcceptTranscription(
    text: String,
    metrics: SpeechActivityMetrics
  ) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if SpeechActivityGate.hasSpeechActivity(metrics) { return true }
    return !isLikelyHallucination(trimmed)
  }
}
