@preconcurrency import AppKit
import AVFoundation
import Dependencies
import Foundation

extension PermissionClient: DependencyKey {
  public static var liveValue: Self {
    let live = PermissionClientLive()
    return Self(
      microphoneStatus: { await live.microphoneStatus() },
      accessibilityStatus: { live.accessibilityStatus() },
      requestMicrophone: { await live.requestMicrophone() },
      requestAccessibility: { await live.requestAccessibility() },
      openMicrophoneSettings: { await live.openMicrophoneSettings() },
      openAccessibilitySettings: { await live.openAccessibilitySettings() },
      observeAppActivation: { live.observeAppActivation() }
    )
  }
}

/// Live implementation of the PermissionClient.
///
/// This actor manages permission checking, requesting, and app activation monitoring.
/// It uses NotificationCenter to observe app lifecycle events and provides an AsyncStream
/// for reactive permission updates.
actor PermissionClientLive {
  private let (activationStream, activationContinuation) = AsyncStream<AppActivation>.makeStream()
  private nonisolated(unsafe) var observations: [Any] = []

  init() {
    // Subscribe to app activation notifications
    let didBecomeActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task {
        self?.activationContinuation.yield(.didBecomeActive)
      }
    }

    let willResignActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task {
        self?.activationContinuation.yield(.willResignActive)
      }
    }

    observations = [didBecomeActiveObserver, willResignActiveObserver]
  }

  deinit {
    observations.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // MARK: - Microphone Permissions

  func microphoneStatus() async -> PermissionStatus {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return .granted
    case .denied, .restricted:
      return .denied
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .denied
    }
  }

  func requestMicrophone() async -> Bool {
    await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  func openMicrophoneSettings() async {
    await MainActor.run {
      _ = NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
      )
    }
  }

  // MARK: - Accessibility Permissions

  nonisolated func accessibilityStatus() -> PermissionStatus {
    // Check without prompting (kAXTrustedCheckOptionPrompt: false)
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
  }

  func requestAccessibility() async {
    // First, trigger the system prompt (on main actor for safety)
    await MainActor.run {
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }

    // Also open System Settings (the prompt alone is insufficient on modern macOS)
    await openAccessibilitySettings()
  }

  func openAccessibilitySettings() async {
    await MainActor.run {
      _ = NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
      )
    }
  }

  // MARK: - Reactive Monitoring

  nonisolated func observeAppActivation() -> AsyncStream<AppActivation> {
    activationStream
  }
}
