import Foundation
import os

public struct TextTransformationPipeline: Codable, Equatable, Sendable {
	public struct Executor {
		public var runLLM: @Sendable (LLMTransformationConfig, String) async throws -> String

		public init(runLLM: @escaping @Sendable (LLMTransformationConfig, String) async throws -> String) {
			self.runLLM = runLLM
		}
	}

	public var transformations: [Transformation]
	public var isEnabled: Bool
	
	public init(transformations: [Transformation] = [], isEnabled: Bool = true) {
		self.transformations = transformations
		self.isEnabled = isEnabled
	}
	
	/// Execute all enabled transformations in sequence
	public func process(_ text: String, executor: Executor? = nil) async throws -> String {
		guard isEnabled else { return text }
		
		var currentText = text
		for transformation in transformations where transformation.isEnabled {
			switch transformation.type {
			case .llm(let config):
				guard let executor else { continue }
				do {
					currentText = try await executor.runLLM(config, currentText)
				} catch is CancellationError {
                    throw CancellationError()
                } catch {
					HexLog.transcription.error("LLM transformation failed: \(error.localizedDescription)")
					continue
				}
			default:
				currentText = await transformation.transform(currentText)
			}
		}
		return currentText
	}
	
	/// Move transformation from one index to another
	public mutating func move(from sourceIndex: Int, to destinationIndex: Int) {
		guard sourceIndex != destinationIndex,
			  transformations.indices.contains(sourceIndex),
			  transformations.indices.contains(destinationIndex) else {
			return
		}
		
		let item = transformations.remove(at: sourceIndex)
		transformations.insert(item, at: destinationIndex)
	}
}
