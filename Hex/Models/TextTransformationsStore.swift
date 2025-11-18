import ComposableArchitecture
import Dependencies
import Foundation
import HexCore

// Re-export types for convenience inside the app target.
typealias TextTransformationsState = HexCore.TextTransformationsState
typealias TextTransformationPipeline = HexCore.TextTransformationPipeline
typealias Transformation = HexCore.Transformation
typealias TransformationType = HexCore.TransformationType
typealias ReplaceTextConfig = HexCore.ReplaceTextConfig
typealias TransformationStack = HexCore.TransformationStack
typealias LLMProvider = HexCore.LLMProvider

extension SharedReaderKey
	where Self == FileStorageKey<TextTransformationsState>.Default
{
	static var textTransformations: Self {
		Self[
			.fileStorage(.textTransformationsURL),
			default: .init()
		]
	}
}

extension URL {
	static var textTransformationsURL: URL {
		get {
			let base = (try? URL.hexApplicationSupport) ?? URL.documentsDirectory
			return base.appending(component: "text_transformations.json")
		}
	}
}
