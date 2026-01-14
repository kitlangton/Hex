import Foundation

/// Known SenseVoice Core ML bundles that Hex supports.
public enum SenseVoiceModel: String, CaseIterable, Sendable {
  case small = "sensevoice-small-coreml"

  public var identifier: String { rawValue }
}
