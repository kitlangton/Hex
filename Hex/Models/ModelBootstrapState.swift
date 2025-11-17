import ComposableArchitecture

struct ModelBootstrapState: Equatable {
    var isModelReady: Bool = true
    var progress: Double = 1
	var lastError: String?
	var modelIdentifier: String?
	var modelDisplayName: String?
}

extension SharedReaderKey
	where Self == InMemoryKey<ModelBootstrapState>.Default
{
	static var modelBootstrapState: Self {
		Self[
			.inMemory("modelBootstrapState"),
			default: .init()
		]
	}
}
