import Foundation
import Security

/// Stores optional refinement credentials outside the JSON settings file.
private enum RefinementAPIKeyStore {
	private static let account = "api-key"

	static func read(service: String) -> String? {
		var query = baseQuery(service: service)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
			  let data = result as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	static func save(_ key: String, service: String) throws {
		let data = Data(key.utf8)
		let query = baseQuery(service: service)
		let attributes = [kSecValueData as String: data]
		let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if status == errSecItemNotFound {
			var newItem = query
			newItem[kSecValueData as String] = data
			let addStatus = SecItemAdd(newItem as CFDictionary, nil)
			guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
		} else if status != errSecSuccess {
			throw KeychainError(status: status)
		}
	}

	static func delete(service: String) throws {
		let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
	}

	private struct KeychainError: LocalizedError {
		let status: OSStatus
		var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? }
	}

	private static func baseQuery(service: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
	}
}

/// Stores the optional Gemini credential outside the JSON settings file.
enum GeminiAPIKeyStore {
	private static let service = "com.kitlangton.Hex.gemini"

	static func read() -> String? { RefinementAPIKeyStore.read(service: service) }
	static func save(_ key: String) throws { try RefinementAPIKeyStore.save(key, service: service) }
	static func delete() throws { try RefinementAPIKeyStore.delete(service: service) }
}

/// Stores the optional OpenRouter credential outside the JSON settings file.
enum OpenRouterAPIKeyStore {
	private static let service = "com.kitlangton.Hex.openrouter"

	static func read() -> String? { RefinementAPIKeyStore.read(service: service) }
	static func save(_ key: String) throws { try RefinementAPIKeyStore.save(key, service: service) }
	static func delete() throws { try RefinementAPIKeyStore.delete(service: service) }
}
