import Foundation

public struct LLMProviderPreferences: Sendable, Equatable {
    public var preferredProviderID: String?
    public var preferredModelID: String?

    public init(preferredProviderID: String? = nil, preferredModelID: String? = nil) {
        self.preferredProviderID = preferredProviderID
        self.preferredModelID = preferredModelID
    }
}
