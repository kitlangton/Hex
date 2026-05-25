import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import UserNotifications

private let coachNotifyLogger = HexLog.coach

@DependencyClient
struct CoachNotifier {
	var requestAuthorization: @Sendable () async -> Void
	var postFeedback: @Sendable (_ title: String, _ body: String) async -> Void
	var postError: @Sendable (_ title: String, _ body: String) async -> Void
}

extension CoachNotifier: DependencyKey {
	static var liveValue: Self {
		.init(
			requestAuthorization: {
				let center = UNUserNotificationCenter.current()
				do {
					_ = try await center.requestAuthorization(options: [.alert, .sound])
				} catch {
					coachNotifyLogger.error("Notification authorization failed: \(String(describing: error), privacy: .public)")
				}
			},
			postFeedback: { title, body in
				await post(title: title, body: body, identifierPrefix: "coach.feedback")
			},
			postError: { title, body in
				await post(title: title, body: body, identifierPrefix: "coach.error")
			}
		)
	}

	static var testValue: Self {
		.init(
			requestAuthorization: { },
			postFeedback: { _, _ in },
			postError: { _, _ in }
		)
	}

	private static func post(title: String, body: String, identifierPrefix: String) async {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default

		let request = UNNotificationRequest(
			identifier: "\(identifierPrefix).\(UUID().uuidString)",
			content: content,
			trigger: nil
		)
		do {
			try await UNUserNotificationCenter.current().add(request)
		} catch {
			coachNotifyLogger.error("Failed to post notification: \(String(describing: error), privacy: .public)")
		}
	}
}

extension DependencyValues {
	var coachNotifier: CoachNotifier {
		get { self[CoachNotifier.self] }
		set { self[CoachNotifier.self] = newValue }
	}
}
