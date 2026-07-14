import AppKit
import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct SettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@State private var localEventMonitor: Any?
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus
	let inputMonitoringPermission: PermissionStatus
  
	var body: some View {
		Form {
			if microphonePermission != .granted
				|| accessibilityPermission != .granted
				|| inputMonitoringPermission != .granted {
				PermissionsSectionView(
					store: store,
					microphonePermission: microphonePermission,
					accessibilityPermission: accessibilityPermission,
					inputMonitoringPermission: inputMonitoringPermission
				)
			}

			ModelSectionView(store: store, shouldFlash: store.shouldFlashModelSection)
			// Only show language picker for WhisperKit models (not Parakeet)
			if ParakeetModel(rawValue: store.hexSettings.selectedModel) == nil {
				LanguageSectionView(store: store)
			}

			HotKeySectionView(store: store)
			RefinementSectionView(store: store)
          
			if microphonePermission == .granted {
				MicrophoneSelectionSectionView(store: store)
			}

			SoundSectionView(store: store)
			GeneralSectionView(store: store)
			HistorySectionView(store: store)
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
		.onAppear(perform: installHotKeyCaptureCancellationMonitor)
		.onDisappear {
			store.send(.cancelHotKeyCapture)
			removeHotKeyCaptureCancellationMonitor()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
			store.send(.cancelHotKeyCapture)
		}
		.enableInjection()
	}

	private func installHotKeyCaptureCancellationMonitor() {
		guard localEventMonitor == nil else { return }

		localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
			guard store.hotKeyCaptureTarget != nil else { return event }
			store.send(.cancelHotKeyCapture)
			return event
		}
	}

	private func removeHotKeyCaptureCancellationMonitor() {
		if let localEventMonitor {
			NSEvent.removeMonitor(localEventMonitor)
			self.localEventMonitor = nil
		}
	}
}

// MARK: - Shared Styles

extension Text {
	/// Applies caption font with secondary color, commonly used for helper/description text in settings.
	func settingsCaption() -> some View {
		self.font(.caption).foregroundStyle(.secondary)
	}
}
