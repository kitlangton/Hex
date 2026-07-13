import Foundation

/// The completed transcript and preferences supplied to the refinement provider.
public struct RefinementRequest: Equatable, Sendable {
	public let text: String
	public let mode: RefinementMode
	public let instructions: String
	public let provider: RefinementProvider
	/// The OpenRouter model identifier. Other providers ignore this value.
	public let modelID: String?

	public init(text: String, mode: RefinementMode, instructions: String, provider: RefinementProvider, modelID: String? = nil) {
		self.text = text
		self.mode = mode
		self.instructions = instructions
		self.provider = provider
		self.modelID = modelID
	}
}
