import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Security

private let coachKeychainLogger = HexLog.coach

@DependencyClient
struct KeychainClient {
	var read: @Sendable (_ account: String) async -> String? = { _ in nil }
	var write: @Sendable (_ account: String, _ value: String) async throws -> Void
	var delete: @Sendable (_ account: String) async throws -> Void
}

extension KeychainClient: DependencyKey {
	static let service = "com.conglei.HexCoach"

	static var liveValue: Self {
		.init(
			read: { account in
				KeychainStorage.read(account: account)
			},
			write: { account, value in
				try KeychainStorage.write(account: account, value: value)
			},
			delete: { account in
				try KeychainStorage.delete(account: account)
			}
		)
	}

	static var testValue: Self {
		let store = LockIsolated<[String: String]>([:])
		return .init(
			read: { account in store.withValue { $0[account] } },
			write: { account, value in store.withValue { $0[account] = value } },
			delete: { account in
				store.withValue { _ = $0.removeValue(forKey: account) }
			}
		)
	}
}

extension DependencyValues {
	var keychain: KeychainClient {
		get { self[KeychainClient.self] }
		set { self[KeychainClient.self] = newValue }
	}
}

private enum KeychainStorage {
	static func read(account: String) -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: KeychainClient.service,
			kSecAttrAccount as String: account,
			kSecMatchLimit as String: kSecMatchLimitOne,
			kSecReturnData as String: true
		]
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
			if status != errSecItemNotFound {
				coachKeychainLogger.error("Keychain read failed for \(account, privacy: .public): OSStatus \(status)")
			}
			return nil
		}
		return value
	}

	static func write(account: String, value: String) throws {
		guard let data = value.data(using: .utf8) else { return }

		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: KeychainClient.service,
			kSecAttrAccount as String: account
		]

		let attributes: [String: Any] = [
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
		]

		let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if updateStatus == errSecSuccess { return }
		if updateStatus != errSecItemNotFound {
			throw KeychainError.osStatus(updateStatus)
		}

		var addQuery = query
		for (k, v) in attributes { addQuery[k] = v }
		let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
		guard addStatus == errSecSuccess else {
			throw KeychainError.osStatus(addStatus)
		}
	}

	static func delete(account: String) throws {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: KeychainClient.service,
			kSecAttrAccount as String: account
		]
		let status = SecItemDelete(query as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw KeychainError.osStatus(status)
		}
	}
}

enum KeychainError: Error, LocalizedError {
	case osStatus(OSStatus)

	var errorDescription: String? {
		switch self {
		case .osStatus(let s):
			return "Keychain error (OSStatus \(s))"
		}
	}
}
