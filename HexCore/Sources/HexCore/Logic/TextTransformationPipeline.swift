import Foundation

public struct TextTransformationPipeline: Codable, Equatable, Sendable {
	public var transformations: [Transformation]
	public var isEnabled: Bool
	
	public init(transformations: [Transformation] = [], isEnabled: Bool = true) {
		self.transformations = transformations
		self.isEnabled = isEnabled
	}
	
	/// Execute all enabled transformations in sequence
	public func process(_ text: String) async -> String {
		guard isEnabled else { return text }
		
		var currentText = text
		for transformation in transformations where transformation.isEnabled {
			currentText = await transformation.transform(currentText)
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
