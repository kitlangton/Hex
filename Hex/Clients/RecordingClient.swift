//
//  RecordingClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AppKit // For NSEvent media key simulation
import AVFoundation
import ComposableArchitecture
import CoreAudio
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let recordingLogger = HexLog.recording
private let mediaLogger = HexLog.media
private typealias CoreAudioPropertyListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Equatable {
  var id: String
  var name: String
  var legacyID: String
}

@DependencyClient
struct RecordingClient {
  var startRecording: @Sendable () async -> Void = {}
  var stopRecording: @Sendable () async -> RecordingStopResult = { .ignored(.noActiveRecording) }
  var requestMicrophoneAccess: @Sendable () async -> Bool = { false }
  var observeAudioLevel: @Sendable () async -> AsyncStream<Meter> = { AsyncStream { _ in } }
  var getAvailableInputDevices: @Sendable () async -> [AudioInputDevice] = { [] }
  var getDefaultInputDeviceName: @Sendable () async -> String? = { nil }
  var warmUpRecorder: @Sendable () async -> Void = {}
  var cleanup: @Sendable () async -> Void = {}
}

extension RecordingClient: DependencyKey {
  static var liveValue: Self {
    let live = RecordingClientLive()
    Task {
      await live.startObservingSystemChanges()
    }
    return Self(
      startRecording: { await live.startRecording() },
      stopRecording: { await live.stopRecording() },
      requestMicrophoneAccess: { await live.requestMicrophoneAccess() },
      observeAudioLevel: { await live.observeAudioLevel() },
      getAvailableInputDevices: { await live.getAvailableInputDevices() },
      getDefaultInputDeviceName: { await live.getDefaultInputDeviceName() },
      warmUpRecorder: { await live.warmUpRecorder() },
      cleanup: { await live.cleanup() }
    )
  }
}

/// Simple structure representing audio metering values.
struct Meter: Equatable {
  let averagePower: Double
  let peakPower: Double
}

enum IgnoredRecordingStopReason: Equatable {
  case staleSession
  case noActiveRecording
}

enum RecordingFailure: Error, Equatable {
  case captureWriteFailed(String)
  case captureFinalizationTimedOut
  case fallbackExportFailed(String)
  case noCapturedAudio
}

extension RecordingFailure: LocalizedError {
  var errorDescription: String? {
    switch self {
    case let .captureWriteFailed(message):
      "Failed to write captured audio: \(message)"
    case .captureFinalizationTimedOut:
      "The microphone did not finish delivering the final audio. Please try again."
    case let .fallbackExportFailed(message):
      "Failed to export recorded audio: \(message)"
    case .noCapturedAudio:
      "Recording stopped without captured audio."
    }
  }
}

enum RecordingStopResult: Equatable {
  case captured(URL)
  case ignored(IgnoredRecordingStopReason)
  case failed(RecordingFailure)
}

// Define function pointer types for the MediaRemote functions.
typealias MRNowPlayingIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
typealias MRMediaRemoteSendCommandFunc = @convention(c) (Int32, CFDictionary?) -> Void

enum MediaRemoteCommand: Int32 {
  case play = 0
  case pause = 1
  case togglePlayPause = 2
}

/// Wraps a few MediaRemote functions.
@Observable
class MediaRemoteController {
  private var mediaRemoteHandle: UnsafeMutableRawPointer?
  private var mrNowPlayingIsPlaying: MRNowPlayingIsPlayingFunc?
  private var mrSendCommand: MRMediaRemoteSendCommandFunc?

  init?() {
    // Open the private framework.
    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) as UnsafeMutableRawPointer? else {
      mediaLogger.error("Unable to open MediaRemote framework")
      return nil
    }
    mediaRemoteHandle = handle

    // Get pointer for the "is playing" function.
    guard let playingPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
      mediaLogger.error("Unable to find MRMediaRemoteGetNowPlayingApplicationIsPlaying symbol")
      return nil
    }
    mrNowPlayingIsPlaying = unsafeBitCast(playingPtr, to: MRNowPlayingIsPlayingFunc.self)

    if let commandPtr = dlsym(handle, "MRMediaRemoteSendCommand") {
      mrSendCommand = unsafeBitCast(commandPtr, to: MRMediaRemoteSendCommandFunc.self)
    } else {
      mediaLogger.error("Unable to find MRMediaRemoteSendCommand symbol")
    }
  }

  deinit {
    if let handle = mediaRemoteHandle {
      dlclose(handle)
    }
  }

  /// Asynchronously refreshes the "is playing" status.
  func isMediaPlaying() async -> Bool {
    guard let isPlayingFunc = mrNowPlayingIsPlaying else { return false }
    return await withCheckedContinuation { continuation in
      isPlayingFunc(DispatchQueue.main) { isPlaying in
        continuation.resume(returning: isPlaying)
      }
    }
  }

  func send(_ command: MediaRemoteCommand) -> Bool {
    guard let sendCommand = mrSendCommand else {
      return false
    }
    sendCommand(command.rawValue, nil)
    return true
  }
}

// Global instance of MediaRemoteController
private let mediaRemoteController = MediaRemoteController()

func isAudioPlayingOnDefaultOutput() async -> Bool {
  // Refresh the state before checking
  return await mediaRemoteController?.isMediaPlaying() ?? false
}

/// Check if an application is installed by looking for its bundle
private func isAppInstalled(bundleID: String) -> Bool {
  let workspace = NSWorkspace.shared
  return workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
}

/// Cached list of installed media players (computed once at first access)
private let installedMediaPlayers: [String: String] = {
  var result: [String: String] = [:]

  if isAppInstalled(bundleID: "com.apple.Music") {
    result["Music"] = "com.apple.Music"
  }

  if isAppInstalled(bundleID: "com.apple.iTunes") {
    result["iTunes"] = "com.apple.iTunes"
  }

  if isAppInstalled(bundleID: "com.spotify.client") {
    result["Spotify"] = "com.spotify.client"
  }

  if isAppInstalled(bundleID: "org.videolan.vlc") {
    result["VLC"] = "org.videolan.vlc"
  }

  return result
}()

// Backoff to avoid spamming AppleScript errors on systems without controllable players
private var mediaControlErrorCount = 0
private var mediaControlDisabled = false

func pauseAllMediaApplications() async -> [String] {
  if mediaControlDisabled { return [] }
  // Use cached list of installed media players
  if installedMediaPlayers.isEmpty {
    return []
  }

  mediaLogger.debug("Installed media players: \(installedMediaPlayers.keys.joined(separator: ", "))")
  
  // Create AppleScript that only targets installed players
  var scriptParts: [String] = ["set pausedPlayers to {}"]

  for (appName, _) in installedMediaPlayers {
    if appName == "VLC" {
      // VLC: check running, then pause if currently playing
      scriptParts.append("""
      try
        if application \"VLC\" is running then
          tell application \"VLC\"
            if playing then
              pause
              set end of pausedPlayers to \"VLC\"
            end if
          end tell
        end if
      end try
      """)
    } else {
      // Music / iTunes / Spotify: check running outside of tell, then query player state
      scriptParts.append("""
      try
        if application \"\(appName)\" is running then
          tell application \"\(appName)\"
            if player state is playing then
              pause
              set end of pausedPlayers to \"\(appName)\"
            end if
          end tell
        end if
      end try
      """)
    }
  }
  
  scriptParts.append("return pausedPlayers")
  let script = scriptParts.joined(separator: "\n\n")
  
  let appleScript = NSAppleScript(source: script)
  var error: NSDictionary?
  guard let resultDescriptor = appleScript?.executeAndReturnError(&error) else {
    if let error = error {
      mediaLogger.error("Failed to pause media apps: \(error)")
      mediaControlErrorCount += 1
      if mediaControlErrorCount >= 3 { mediaControlDisabled = true }
    }
    return []
  }
  
  // Convert AppleScript list to Swift array
  var pausedPlayers: [String] = []
  let count = resultDescriptor.numberOfItems
  
  if count > 0 {
    for i in 1...count {
      if let item = resultDescriptor.atIndex(i)?.stringValue {
        pausedPlayers.append(item)
      }
    }
  }
    
  mediaLogger.notice("Paused media players: \(pausedPlayers.joined(separator: ", "))")
  
  return pausedPlayers
}

func resumeMediaApplications(_ players: [String]) async {
  guard !players.isEmpty else { return }

  // Only attempt to resume players that are installed
  let validPlayers = players.filter { installedMediaPlayers.keys.contains($0) }
  if validPlayers.isEmpty {
    return
  }
  
  // Create specific resume script for each player
  var scriptParts: [String] = []
  
  for player in validPlayers {
    if player == "VLC" {
      scriptParts.append("""
      try
        if application id \"org.videolan.vlc\" is running then
          tell application id \"org.videolan.vlc\" to play
        end if
      end try
      """)
    } else {
      scriptParts.append("""
      try
        if application \"\(player)\" is running then
          tell application \"\(player)\" to play
        end if
      end try
      """)
    }
  }
  
  let script = scriptParts.joined(separator: "\n\n")
  
  let appleScript = NSAppleScript(source: script)
  var error: NSDictionary?
  appleScript?.executeAndReturnError(&error)
  if let error = error {
    mediaLogger.error("Failed to resume media apps: \(error)")
  }
}

/// Simulates a media key press (the Play/Pause key) by posting a system-defined NSEvent.
/// This toggles the state of the active media app.
private func sendMediaKey() {
  let NX_KEYTYPE_PLAY: UInt32 = 16
  func postKeyEvent(down: Bool) {
    let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
    let data1 = Int((NX_KEYTYPE_PLAY << 16) | (down ? 0xA << 8 : 0xB << 8))
    if let event = NSEvent.otherEvent(with: .systemDefined,
                                      location: .zero,
                                      modifierFlags: flags,
                                      timestamp: 0,
                                      windowNumber: 0,
                                      context: nil,
                                      subtype: 8,
                                      data1: data1,
                                      data2: -1)
    {
      event.cgEvent?.post(tap: .cghidEventTap)
    }
  }
  postKeyEvent(down: true)
  postKeyEvent(down: false)
}

// MARK: - RecordingClientLive Implementation

/// A system transition that makes warm capture pointless (nobody dictates at a locked or
/// sleeping screen). Tracked as separate sources so a wake while the screen is still locked
/// stays suspended until the unlock arrives.
private enum CaptureSuspensionSource: String {
  case systemSleep = "system-sleep"
  case displaySleep = "display-sleep"
  case screenLock = "screen-lock"
}

private enum ScreenLockNotifications {
  static let locked = Notification.Name("com.apple.screenIsLocked")
  static let unlocked = Notification.Name("com.apple.screenIsUnlocked")
}

actor RecordingClientLive {
  private struct AudioHardwareObserver {
    let selector: AudioObjectPropertySelector
    let reason: String
    let listener: CoreAudioPropertyListenerBlock
  }

  private enum RecordingBackend: String {
    case captureEngine = "capture-engine"
    case recorderFallback = "recorder-fallback"
  }

  private struct ActiveRecordingSession {
    let startedAt: Date
    let mode: CaptureRecordingMode
    let backend: RecordingBackend
  }

  private var recorder: AVAudioRecorder?
  private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")
  private var isRecorderPrimedForNextSession = false
  private var lastPrimedDeviceID: AudioDeviceID?
  private var recordingSessionID: UUID?
  private var activeRecordingSession: ActiveRecordingSession?
  private var lastRecordingEndedAt: Date?
  private var deferredCaptureRestartReason: String?
  private var environmentChangeDebounceTask: Task<Void, Never>?
  private var mediaControlTask: Task<Void, Never>?
  private let recorderSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
  ]
  private let (meterStream, meterContinuation) = AsyncStream<Meter>.makeStream()
  private var meterTask: Task<Void, Never>?
  private lazy var captureController = SuperFastCaptureController(
    meterContinuation: meterContinuation,
    onEngineConfigurationChange: { [weak self] generation in
      Task {
        await self?.enqueueCaptureEnvironmentChange(
          reason: "capture-engine-configuration-changed",
          captureGeneration: generation
        )
      }
    }
  )
  private var captureControllerDeviceID: AudioDeviceID?
  private var captureControllerNeedsRestartReason: String?
  private var notificationObservers: [NSObjectProtocol] = []
  private var distributedNotificationObservers: [NSObjectProtocol] = []
  private var audioHardwareObservers: [AudioHardwareObserver] = []
  private var isObservingSystemChanges = false
  /// Active reasons warm capture is suspended. The warm engine is torn down while any
  /// source is active and rearmed when the last one clears, which also avoids a whole
  /// class of stale-engine-across-sleep bugs.
  private var captureSuspensionSources: Set<CaptureSuspensionSource> = []

  private var isCaptureSuspended: Bool { !captureSuspensionSources.isEmpty }

  @Shared(.hexSettings) var hexSettings: HexSettings

  /// Tracks whether media was paused using the media key when recording started.
  private var didPauseMedia: Bool = false

  /// Tracks whether media was toggled via MediaRemote
  private var didPauseViaMediaRemote: Bool = false

  /// Tracks which specific media players were paused
  private var pausedPlayers: [String] = []

  /// Tracks previous system volume when muted for recording
  private var previousVolume: Float?

  /// Gets all available input devices on the system
  func getAvailableInputDevices() async -> [AudioInputDevice] {
    // Get all available audio devices
    let devices = getAllAudioDevices()
    var inputDevices: [AudioInputDevice] = []
    
    // Filter to only input devices and convert to our model
    for device in devices {
      if deviceHasInput(deviceID: device),
         let deviceUID = getDeviceUID(deviceID: device),
         let deviceName = getDeviceName(deviceID: device) {
        inputDevices.append(AudioInputDevice(id: deviceUID, name: deviceName, legacyID: String(device)))
      }
    }
    
    return inputDevices
  }

  /// Gets the current system default input device name
  func getDefaultInputDeviceName() async -> String? {
    guard let deviceID = getDefaultInputDevice() else { return nil }
    return getDeviceName(deviceID: deviceID)
  }
  
  // MARK: - Core Audio Helpers

  /// Creates an AudioObjectPropertyAddress with common defaults.
  private func audioPropertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: element
    )
  }

  func startObservingSystemChanges() {
    guard !isObservingSystemChanges else { return }
    isObservingSystemChanges = true

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    notificationObservers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.resumeWarmCapture(source: .systemSleep, reason: "system-wake") }
      }
    )
    notificationObservers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.resumeWarmCapture(source: .displaySleep, reason: "display-wake") }
      }
    )
    notificationObservers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.suspendWarmCapture(source: .systemSleep) }
      }
    )
    notificationObservers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.screensDidSleepNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.suspendWarmCapture(source: .displaySleep) }
      }
    )

    let distributedCenter = DistributedNotificationCenter.default()
    distributedNotificationObservers.append(
      distributedCenter.addObserver(
        forName: ScreenLockNotifications.locked,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.suspendWarmCapture(source: .screenLock) }
      }
    )
    distributedNotificationObservers.append(
      distributedCenter.addObserver(
        forName: ScreenLockNotifications.unlocked,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.resumeWarmCapture(source: .screenLock, reason: "screen-unlocked") }
      }
    )

    let center = NotificationCenter.default
    notificationObservers.append(
      center.addObserver(
        forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.enqueueCaptureEnvironmentChange(reason: "capture-device-connected") }
      }
    )
    notificationObservers.append(
      center.addObserver(
        forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.enqueueCaptureEnvironmentChange(reason: "capture-device-disconnected") }
      }
    )

    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDefaultInputDevice,
      reason: "default-input-changed"
    )
    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDefaultOutputDevice,
      reason: "default-output-changed"
    )
    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDevices,
      reason: "audio-devices-changed"
    )

    recordingLogger.notice("Installed recording environment observers")
  }

  private func installAudioHardwareObserver(
    selector: AudioObjectPropertySelector,
    reason: String
  ) {
    let listener: CoreAudioPropertyListenerBlock = { _, _ in
      Task { await self.enqueueCaptureEnvironmentChange(reason: reason) }
    }

    var address = audioPropertyAddress(selector)
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      DispatchQueue.main,
      listener
    )

    if status == noErr {
      audioHardwareObservers.append(
        AudioHardwareObserver(selector: selector, reason: reason, listener: listener)
      )
    } else {
      recordingLogger.error("Failed to install audio observer reason=\(reason) status=\(status)")
    }
  }

  private func enqueueCaptureEnvironmentChange(
    reason: String,
    captureGeneration: Int? = nil
  ) {
    environmentChangeDebounceTask?.cancel()
    environmentChangeDebounceTask = Task { [self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      if let captureGeneration,
         !captureController.isCurrentGeneration(captureGeneration)
      {
        return
      }
      handleCaptureEnvironmentChange(reason: reason)
    }
  }

  private func stopObservingSystemChanges() {
    guard isObservingSystemChanges else { return }
    isObservingSystemChanges = false
    environmentChangeDebounceTask?.cancel()
    environmentChangeDebounceTask = nil

    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    notificationObservers.removeAll()

    for observer in distributedNotificationObservers {
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    distributedNotificationObservers.removeAll()

    for observer in audioHardwareObservers {
      var address = audioPropertyAddress(observer.selector)
      let status = AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        DispatchQueue.main,
        observer.listener
      )
      if status != noErr {
        recordingLogger.error("Failed to remove audio observer reason=\(observer.reason) status=\(status)")
      }
    }
    audioHardwareObservers.removeAll()
  }

  /// Synchronous on purpose: no awaits means no actor reentrancy, so the recording-state
  /// snapshot below cannot go stale while this method runs.
  private func handleCaptureEnvironmentChange(reason: String) {
    let currentInputDevice = getDefaultInputDevice()
    let currentOutputDevice = getDefaultOutputDevice()
    let isRecorderRecording = recorder?.isRecording == true
    let isEngineRecording = captureController.isRecording
    let isRecordingActive = isRecorderRecording || isEngineRecording

    recordingLogger.notice(
      "Capture environment changed reason=\(reason) activeRecording=\(isRecordingActive) input=\(self.describeDevice(currentInputDevice)) output=\(self.describeDevice(currentOutputDevice)) captureEngineArmed=\(self.captureController.isRunning) primed=\(self.isRecorderPrimedForNextSession)"
    )

    if isRecordingActive {
      invalidatePrimedState()
      if isEngineRecording {
        let activeInputDevice = applyPreferredInputDevice()
        // Only disturb an active recording when its capture path is actually affected:
        // the input device changed, or the engine already died (configuration change).
        // Output-only changes (plugging in headphones) must not cause an audio gap.
        let inputChanged = activeInputDevice != captureControllerDeviceID
        let engineDisrupted = !captureController.isRunning
        guard inputChanged || engineDisrupted else {
          recordingLogger.debug("Environment change does not affect active capture; ignoring reason=\(reason)")
          return
        }
        // Rebuild the engine in place so capture continues onto the same file. Leaving the
        // stale engine "running" against the old route silently captured nothing for the
        // rest of the recording (#251, #252, #218, #226).
        do {
          try captureController.restartPreservingRecording(reason: reason)
          captureControllerDeviceID = activeInputDevice
          captureControllerNeedsRestartReason = nil
          deferredCaptureRestartReason = nil
          recordingLogger.notice(
            "Rebuilt capture engine mid-recording reason=\(reason) input=\(self.describeDevice(activeInputDevice))"
          )
          return
        } catch {
          recordingLogger.error(
            "Mid-recording capture engine rebuild failed reason=\(reason): \(error.localizedDescription); deferring restart"
          )
        }
      }
      deferredCaptureRestartReason = reason
      recordingLogger.notice("Deferring capture restart until current recording stops reason=\(reason)")
      return
    }

    deferredCaptureRestartReason = nil

    if isCaptureSuspended {
      tearDownWarmCapture(reason: "suspended-\(reason)")
      recordingLogger.notice("Capture suspended (screen locked/asleep); deferring engine rebuild reason=\(reason)")
      return
    }

    if hexSettings.superFastModeEnabled {
      releaseRecorder(reason: "environment-change-\(reason)")
      let activeInputDevice = applyPreferredInputDevice()
      // Skip the rebuild when nothing that matters changed. Device events arrive in
      // bursts (a Bluetooth connect fires devices-changed, default-input-changed,
      // default-output-changed, and more over 1-2s); once the first event settles the
      // engine on the right device, the rest become no-ops here.
      if captureController.isRunning,
         activeInputDevice == captureControllerDeviceID,
         captureControllerNeedsRestartReason == nil
      {
        recordingLogger.debug("Capture engine unaffected by environment change; skipping rebuild reason=\(reason)")
        return
      }
      do {
        // Rebuild immediately instead of deferring to the next recording: a stale engine
        // left running against the old route kept coreaudiod churning while idle (#209)
        // and made the first post-change recording unreliable (#251, #252).
        try ensureCaptureControllerReady(
          for: activeInputDevice,
          reason: "environment-change-\(reason)",
          forceRestart: true
        )
        captureControllerNeedsRestartReason = nil
        recordingLogger.notice(
          "Rebuilt capture engine after environment change reason=\(reason) input=\(self.describeDevice(activeInputDevice))"
        )
      } catch {
        stopCaptureController(reason: "environment-rebuild-failed-\(reason)")
        captureControllerNeedsRestartReason = reason
        recordingLogger.error(
          "Capture engine rebuild failed reason=\(reason): \(error.localizedDescription); will retry on next recording"
        )
      }
      return
    }

    _ = applyPreferredInputDevice()
    stopCaptureController(reason: reason)
    releaseRecorder(reason: "environment-change-\(reason)")
    recordingLogger.debug("Standard mode uses on-demand capture startup after reason=\(reason)")
  }

  /// Records that a lock/sleep transition happened and tears down the warm engine unless a
  /// recording is in flight (the recording keeps running; teardown happens after it stops
  /// via finalizeCaptureStateAfterRecording).
  private func suspendWarmCapture(source: CaptureSuspensionSource) {
    guard captureSuspensionSources.insert(source).inserted else { return }
    guard recorder?.isRecording != true, !captureController.isRecording else {
      recordingLogger.notice("Lock/sleep during active recording; capture continues, suspending after stop source=\(source.rawValue)")
      return
    }
    tearDownWarmCapture(reason: "suspend-\(source.rawValue)")
    recordingLogger.notice("Suspended warm capture source=\(source.rawValue)")
  }

  private func resumeWarmCapture(source: CaptureSuspensionSource, reason: String) {
    captureSuspensionSources.remove(source)
    guard !isCaptureSuspended else {
      // Woke up but e.g. the screen is still locked; stay suspended until unlock.
      recordingLogger.notice("Still suspended after \(reason); remaining sources=\(self.captureSuspensionSources.map(\.rawValue).joined(separator: ","))")
      return
    }
    recordingLogger.notice("Resuming warm capture reason=\(reason)")
    enqueueCaptureEnvironmentChange(reason: reason)
  }

  private func tearDownWarmCapture(reason: String) {
    captureControllerNeedsRestartReason = reason
    guard captureController.isRunning || recorder != nil else { return }
    stopCaptureController(reason: reason)
    releaseRecorder(reason: reason)
  }

  /// Restores idle capture state after a recording ends: applies any environment change
  /// that arrived mid-recording, then re-suspends if the screen locked or slept while the
  /// recording was running.
  private func finalizeCaptureStateAfterRecording() {
    if let deferredCaptureRestartReason {
      recordingLogger.notice("Applying deferred capture restart reason=\(deferredCaptureRestartReason)")
      handleCaptureEnvironmentChange(reason: "deferred-\(deferredCaptureRestartReason)")
    }
    if isCaptureSuspended {
      tearDownWarmCapture(reason: "post-recording-suspend")
      recordingLogger.notice("Suspended warm capture after recording (screen locked/asleep)")
    }
  }

  /// Get all available audio devices
  private func getAllAudioDevices() -> [AudioDeviceID] {
    var propertySize: UInt32 = 0
    var address = audioPropertyAddress(kAudioHardwarePropertyDevices)
    
    // Get the property data size
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      recordingLogger.error("AudioObjectGetPropertyDataSize failed: \(status)")
      return []
    }
    
    // Calculate device count
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    
    // Get the device IDs
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize,
      &deviceIDs
    )
    
      if status != 0 {
        recordingLogger.error("AudioObjectGetPropertyData failed while listing devices: \(status)")
        return []
      }
    
    return deviceIDs
  }
  
  /// Get device name for the given device ID
  private func getDeviceName(deviceID: AudioDeviceID) -> String? {
    getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
  }

  /// Get the persistent device UID for the given device ID
  private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
    getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
  }

  private func getDeviceStringProperty(
    deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var address = audioPropertyAddress(selector)
    
    var deviceName: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let deviceNamePtr: UnsafeMutableRawPointer = .allocate(byteCount: Int(size), alignment: MemoryLayout<CFString?>.alignment)
    defer { deviceNamePtr.deallocate() }
    
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      deviceNamePtr
    )
    
    if status == 0 {
        deviceName = deviceNamePtr.load(as: CFString?.self)
    }
    
      if status != 0 {
        recordingLogger.error("Failed to fetch device property \(selector): \(status)")
        return nil
      }
    
    return deviceName as String?
  }
  
  /// Check if device has input capabilities
  private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
    var address = audioPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
    
    var propertySize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      return false
    }
    
    let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
    defer { bufferList.deallocate() }
    
    let getStatus = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &propertySize,
      bufferList
    )
    
    if getStatus != 0 {
      return false
    }
    
    // Check if we have any input channels
    let buffersPointer = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffersPointer.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
  }
  
  /// Set device as the default input device
  private func setInputDevice(deviceID: AudioDeviceID) {
    var device = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      size,
      &device
    )
    
    if status != 0 {
      recordingLogger.error("Failed to set default input device: \(status)")
    } else {
      recordingLogger.notice("Selected input device set to \(deviceID)")
    }
  }

  func requestMicrophoneAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  // MARK: - Input Device Query

  /// Gets the current default input device ID
  private func getDefaultInputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    if status != 0 {
      recordingLogger.error("Failed to get default input device: \(status)")
      return nil
    }

    return deviceID
  }

  private func resolvePreferredInputDevice() -> AudioDeviceID? {
    guard let selectedMicrophoneID = hexSettings.selectedMicrophoneID else { return nil }
    if let deviceID = getDeviceID(uid: selectedMicrophoneID),
       deviceHasInput(deviceID: deviceID) {
      return deviceID
    }

    if let legacyDeviceID = AudioDeviceID(selectedMicrophoneID),
       deviceHasInput(deviceID: legacyDeviceID) {
      return legacyDeviceID
    }

    recordingLogger.notice("Selected device \(selectedMicrophoneID) missing; using system default")
    return nil
  }

  private func getDeviceID(uid: String) -> AudioDeviceID? {
    var address = audioPropertyAddress(kAudioHardwarePropertyDeviceForUID)
    var deviceUID = uid as CFString
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &deviceUID) { pointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<CFString>.size),
        pointer,
        &size,
        &deviceID
      )
    }

    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private func formatDuration(_ duration: TimeInterval?) -> String {
    guard let duration else { return "n/a" }
    return String(format: "%.3fs", duration)
  }

  private func describeDevice(_ deviceID: AudioDeviceID?) -> String {
    guard let deviceID else { return "none" }
    if let name = getDeviceName(deviceID: deviceID) {
      return "\(name) [\(deviceID)]"
    }
    return "unknown [\(deviceID)]"
  }

  private func logRecordingStartRequest(mode: CaptureRecordingMode, inputDeviceID: AudioDeviceID?) {
    let idleDuration = lastRecordingEndedAt.map { Date().timeIntervalSince($0) }
    let outputDeviceID = getDefaultOutputDevice()
    recordingLogger.notice(
      "Recording requested mode=\(mode.rawValue) idle=\(self.formatDuration(idleDuration)) input=\(self.describeDevice(inputDeviceID)) output=\(self.describeDevice(outputDeviceID)) fallbackPrimed=\(self.isRecorderPrimedForNextSession)"
    )
  }

  private func currentCaptureMode() -> CaptureRecordingMode {
    hexSettings.superFastModeEnabled ? .superFast : .standard
  }

  @discardableResult
  private func applyPreferredInputDevice() -> AudioDeviceID? {
    let targetDeviceID = resolvePreferredInputDevice()
    let currentDefaultDevice = getDefaultInputDevice()

    if let primedDevice = lastPrimedDeviceID, primedDevice != currentDefaultDevice {
      recordingLogger.notice("Default input changed from \(primedDevice) to \(currentDefaultDevice ?? 0); invalidating primed state")
      invalidatePrimedState()
    }

    if let targetDeviceID {
      if targetDeviceID != currentDefaultDevice {
        recordingLogger.notice("Switching input device from \(currentDefaultDevice ?? 0) to \(targetDeviceID)")
        setInputDevice(deviceID: targetDeviceID)
        invalidatePrimedState()
      } else {
        recordingLogger.debug("Device \(targetDeviceID) already set as default, skipping setInputDevice()")
      }
    } else {
      recordingLogger.debug("Using system default microphone")
    }

    return getDefaultInputDevice()
  }

  private func makeCaptureRecordingURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")
  }

  nonisolated static func shouldIgnoreStopRequest(
    snapshotSessionID: UUID?,
    currentSessionID: UUID?
  ) -> Bool {
    guard let snapshotSessionID else { return false }
    return currentSessionID != snapshotSessionID
  }

  private func ensureCaptureControllerReady(
    for deviceID: AudioDeviceID?,
    reason: String,
    forceRestart: Bool = false
  ) throws {
    if forceRestart || captureControllerDeviceID != deviceID {
      recordingLogger.notice(
        "Restarting capture engine reason=\(reason) previousInput=\(self.describeDevice(self.captureControllerDeviceID)) newInput=\(self.describeDevice(deviceID)) force=\(forceRestart)"
      )
      stopCaptureController(reason: forceRestart ? "restart-\(reason)" : "input-device-changed")
    }

    try captureController.startIfNeeded(
      reason: reason,
      keepWarmBuffer: currentCaptureMode().keepsWarmBuffer
    )
    captureControllerDeviceID = deviceID
  }

  private func ensureCaptureControllerReadyAfterDeferredRestart(
    for deviceID: AudioDeviceID?,
    reason: String
  ) throws {
    let deferredReason = captureControllerNeedsRestartReason
    try ensureCaptureControllerReady(
      for: deviceID,
      reason: deferredReason.map { "deferred-\($0)-\(reason)" } ?? reason,
      forceRestart: deferredReason != nil
    )
    captureControllerNeedsRestartReason = nil
  }

  private func stopCaptureController(reason: String) {
    captureController.stop(reason: reason)
    captureControllerDeviceID = nil
  }

  private func releaseRecorder(reason: String) {
    if recorder != nil {
      recordingLogger.notice(
        "Releasing recorder reason=\(reason) primed=\(self.isRecorderPrimedForNextSession) input=\(self.describeDevice(self.lastPrimedDeviceID))"
      )
    }
    stopMeterTask()
    if recorder?.isRecording == true {
      recorder?.stop()
    }
    recorder = nil
    invalidatePrimedState()
  }

  // MARK: - Input Device Mute Detection & Fix

  /// Checks if the input device is muted at the Core Audio device level
  private func isInputDeviceMuted(_ deviceID: AudioDeviceID) -> Bool {
    var address = audioPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)

    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
    if status != noErr {
      // Property not supported on this device
      return false
    }
    return muted == 1
  }

  /// Unmutes the input device at the Core Audio device level
  private func unmuteInputDevice(_ deviceID: AudioDeviceID) {
    var address = audioPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    var muted: UInt32 = 0
    let size = UInt32(MemoryLayout<UInt32>.size)

    let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muted)
    if status == noErr {
      recordingLogger.warning("Input device \(deviceID) was muted at device level - automatically unmuted")
    } else {
      recordingLogger.error("Failed to unmute input device \(deviceID): \(status)")
    }
  }

  /// Checks and fixes muted input device before recording
  private func ensureInputDeviceUnmuted() {
    guard let deviceID = getDefaultInputDevice() else { return }
    if isInputDeviceMuted(deviceID) {
      recordingLogger.error("⚠️ Input device \(deviceID) is MUTED at Core Audio level! This causes silent recordings.")
      unmuteInputDevice(deviceID)
    }
  }

  // MARK: - Volume Control

  /// Mutes system volume and returns the previous volume level
  private func muteSystemVolume() async -> Float {
    let currentVolume = getSystemVolume()
    setSystemVolume(0)
    recordingLogger.notice("Muted system volume (was \(String(format: "%.2f", currentVolume)))")
    return currentVolume
  }

  /// Restores system volume to the specified level
  private func restoreSystemVolume(_ volume: Float) async {
    setSystemVolume(volume)
    recordingLogger.notice("Restored system volume to \(String(format: "%.2f", volume))")
  }

  /// Gets the default output device ID
  private func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    if status != 0 {
      recordingLogger.error("Failed to get default output device: \(status)")
      return nil
    }

    return deviceID
  }

  /// Gets the current system output volume (0.0 to 1.0)
  private func getSystemVolume() -> Float {
    guard let deviceID = getDefaultOutputDevice() else {
      return 0.0
    }

    var volume: Float32 = 0.0
    var size = UInt32(MemoryLayout<Float32>.size)
    var address = audioPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)

    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &volume
    )

    if status != 0 {
      recordingLogger.error("Failed to get system volume: \(status)")
      return 0.0
    }

    return volume
  }

  /// Sets the system output volume (0.0 to 1.0)
  private func setSystemVolume(_ volume: Float) {
    guard let deviceID = getDefaultOutputDevice() else {
      return
    }

    var newVolume = volume
    let size = UInt32(MemoryLayout<Float32>.size)
    var address = audioPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)

    let status = AudioObjectSetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      size,
      &newVolume
    )

    if status != 0 {
      recordingLogger.error("Failed to set system volume: \(status)")
    }
  }

  func startRecording() async {
    let sessionID = UUID()
    recordingSessionID = sessionID
    // A pending environment-change debounce is superseded: the start path below applies
    // device preferences and re-arms the engine itself, and letting the stale task fire
    // into the new recording would force a pointless mid-recording rebuild.
    environmentChangeDebounceTask?.cancel()
    environmentChangeDebounceTask = nil
    mediaControlTask?.cancel()
    mediaControlTask = nil

    // `stopRecording()` awaits capture finalization and therefore releases this actor. Do not
    // let a rapid next hotkey press replace the file that is still draining final PCM frames.
    await captureController.waitForPendingFinish()
    guard !Task.isCancelled, recordingSessionID == sessionID else {
      recordingLogger.notice("Ignoring recording start superseded while finalizing prior capture")
      return
    }

    // Handle audio behavior based on user preference
    switch hexSettings.recordingAudioBehavior {
    case .pauseMedia:
      // Pause media in background - don't block recording from starting
      mediaControlTask = Task { [sessionID] in
        guard await self.isCurrentSession(sessionID) else { return }
        if await self.pauseUsingMediaRemoteIfPossible(sessionID: sessionID) {
          return
        }

        // First, pause all media applications using their AppleScript interface.
        let paused = await pauseAllMediaApplications()
        guard await self.isCurrentSession(sessionID) else {
          await resumeMediaApplications(paused)
          return
        }
        await self.updatePausedPlayers(paused, sessionID: sessionID)

        // If no specific players were paused, pause generic media using the media key.
        guard await self.isCurrentSession(sessionID) else { return }
        if paused.isEmpty {
          if await isAudioPlayingOnDefaultOutput() {
            guard await self.isCurrentSession(sessionID) else { return }
            mediaLogger.notice("Detected active audio on default output; sending media pause")
            await MainActor.run {
              sendMediaKey()
            }
            await self.setDidPauseMedia(true, sessionID: sessionID)
            mediaLogger.notice("Paused media via media key fallback")
          }
        } else {
          mediaLogger.notice("Paused media players: \(paused.joined(separator: ", "))")
        }
      }

    case .mute:
      // Mute system volume in background
      mediaControlTask = Task { [sessionID] in
        guard await self.isCurrentSession(sessionID) else { return }
        let volume = await self.muteSystemVolume()
        guard await self.isCurrentSession(sessionID) else {
          await self.restoreSystemVolume(volume)
          return
        }
        await self.setPreviousVolume(volume, sessionID: sessionID)
      }

    case .doNothing:
      // No audio handling
      break
    }

    let activeInputDevice = applyPreferredInputDevice()
    // Check the actual active device after applying the user's preferred input.
    ensureInputDeviceUnmuted()
    let mode = currentCaptureMode()
    logRecordingStartRequest(mode: mode, inputDeviceID: activeInputDevice)
    let startRequestAt = Date()

    do {
      try ensureCaptureControllerReadyAfterDeferredRestart(for: activeInputDevice, reason: "startRecording")
      let recordingURL = makeCaptureRecordingURL()
      try captureController.beginRecording(to: recordingURL, requestedAt: startRequestAt, mode: mode)
      let startedAt = Date()
      activeRecordingSession = ActiveRecordingSession(
        startedAt: startedAt,
        mode: mode,
        backend: .captureEngine
      )
      recordingLogger.notice(
        "Recording started mode=\(mode.rawValue) backend=\(RecordingBackend.captureEngine.rawValue) startup=\(self.formatDuration(startedAt.timeIntervalSince(startRequestAt)))"
      )
      return
    } catch {
      recordingLogger.error("Failed to start capture engine for mode=\(mode.rawValue): \(error.localizedDescription); falling back to AVAudioRecorder")
      stopCaptureController(reason: "capture-engine-start-failed")
    }

    do {
      let recorder = try ensureRecorderReadyForRecording()
      let recordCallStartedAt = Date()
      guard recorder.record() else {
        recordingLogger.error("AVAudioRecorder refused to start recording")
        endRecordingSession()
        return
      }
      let startedAt = Date()
      activeRecordingSession = ActiveRecordingSession(
        startedAt: startedAt,
        mode: mode,
        backend: .recorderFallback
      )
      startMeterTask()
      recordingLogger.notice(
        "Recording started mode=\(mode.rawValue) backend=\(RecordingBackend.recorderFallback.rawValue) recordCall=\(self.formatDuration(Date().timeIntervalSince(recordCallStartedAt))) totalStart=\(self.formatDuration(startedAt.timeIntervalSince(startRequestAt)))"
      )
    } catch {
      recordingLogger.error("Failed to start recording: \(error.localizedDescription)")
      clearActiveRecordingMetadata()
      endRecordingSession()
    }
  }

  func stopRecording() async -> RecordingStopResult {
    let stopSessionID = recordingSessionID
    let activeSession = activeRecordingSession

    let captureFinishResult = await captureController.finishRecording(
      clearBuffer: currentCaptureMode() == .superFast
    )

    if Self.shouldIgnoreStopRequest(
      snapshotSessionID: stopSessionID,
      currentSessionID: recordingSessionID
    ) {
      recordingLogger.notice("Ignoring stale stop request after a newer recording session started")
      return .ignored(.staleSession)
    }

    switch captureFinishResult {
    case .finalizing:
      recordingLogger.notice("Ignoring duplicate stop while capture engine finalization is already in progress")
      return .ignored(.staleSession)

    case let .captured(captureURL):
      let stoppedAt = Date()
      let session = activeSession ?? ActiveRecordingSession(
        startedAt: stoppedAt,
        mode: currentCaptureMode(),
        backend: .captureEngine
      )
      let recordingDuration = stoppedAt.timeIntervalSince(session.startedAt)
      stopMeterTask()
      endRecordingSession()
      clearActiveRecordingMetadata()
      lastRecordingEndedAt = stoppedAt
      recordingLogger.notice(
        "Recording stopped mode=\(session.mode.rawValue) backend=\(session.backend.rawValue) duration=\(self.formatDuration(recordingDuration))"
      )

      if !hexSettings.superFastModeEnabled {
        stopCaptureController(reason: "mode-disabled-after-stop")
        releaseRecorder(reason: "capture-engine-stop")
      }

      finalizeCaptureStateAfterRecording()
      await resumeMediaIfNeeded()
      return .captured(captureURL)

    case let .failed(error):
      let stoppedAt = Date()
      stopMeterTask()
      endRecordingSession()
      clearActiveRecordingMetadata()
      lastRecordingEndedAt = stoppedAt
      if !hexSettings.superFastModeEnabled {
        stopCaptureController(reason: "mode-disabled-after-stop-failed")
        releaseRecorder(reason: "capture-engine-stop-failed")
      }
      finalizeCaptureStateAfterRecording()
      await resumeMediaIfNeeded()
      return .failed(error)

    case .idle:
      break
    }

    let stoppedAt = Date()
    let session = activeSession ?? ActiveRecordingSession(
      startedAt: stoppedAt,
      mode: currentCaptureMode(),
      backend: .recorderFallback
    )
    let recordingDuration = stoppedAt.timeIntervalSince(session.startedAt)
    let wasRecording = recorder?.isRecording == true
    guard session.backend == .recorderFallback, wasRecording else {
      recordingLogger.notice("stopRecording() called without an active recorder fallback; skipping stale recording.wav export")
      stopMeterTask()
      endRecordingSession()
      clearActiveRecordingMetadata()
      lastRecordingEndedAt = stoppedAt
      finalizeCaptureStateAfterRecording()
      await resumeMediaIfNeeded()
      return .ignored(.noActiveRecording)
    }
    recorder?.stop()
    stopMeterTask()
    endRecordingSession()
    clearActiveRecordingMetadata()
    lastRecordingEndedAt = stoppedAt
    recordingLogger.notice("Recording stopped mode=\(session.mode.rawValue) backend=\(session.backend.rawValue) duration=\(self.formatDuration(recordingDuration))")

    let exportedURL: URL
    do {
      exportedURL = try duplicateCurrentRecording()
    } catch {
      isRecorderPrimedForNextSession = false
      recordingLogger.error("Failed to copy recording: \(error.localizedDescription)")
      releaseRecorder(reason: "fallback-export-failed")
      FileManager.default.removeItemIfExists(at: recordingURL)
      finalizeCaptureStateAfterRecording()
      await resumeMediaIfNeeded()
      return .failed(.fallbackExportFailed(error.localizedDescription))
    }
    releaseRecorder(reason: "fallback-stop")

    if !hexSettings.superFastModeEnabled {
      stopCaptureController(reason: "standard-stop")
    }

    finalizeCaptureStateAfterRecording()
    await resumeMediaIfNeeded()

    return .captured(exportedURL)
  }

  private func resumeMediaIfNeeded() async {
    let playersToResume = pausedPlayers
    let shouldResumeMedia = didPauseMedia
    let shouldResumeViaMediaRemote = didPauseViaMediaRemote
    let volumeToRestore = previousVolume

    clearMediaState()

    // Restore volume if it was muted
    if let volume = volumeToRestore {
      await restoreSystemVolume(volume)
    }
    // Resume media if we previously paused specific players
    else if !playersToResume.isEmpty {
      mediaLogger.notice("Resuming players: \(playersToResume.joined(separator: ", "))")
      await resumeMediaApplications(playersToResume)
    }
    else if shouldResumeViaMediaRemote {
      if mediaRemoteController?.send(.play) == true {
        mediaLogger.notice("Resuming media via MediaRemote")
      } else {
        mediaLogger.error("Failed to resume via MediaRemote; falling back to media key")
        await MainActor.run {
          sendMediaKey()
        }
      }
    }
    // Resume generic media if we paused it with the media key
    else if shouldResumeMedia {
      await MainActor.run {
        sendMediaKey()
      }
      mediaLogger.notice("Resuming media via media key")
    }
  }

  // Actor state update helpers
  private func isCurrentSession(_ sessionID: UUID) -> Bool {
    recordingSessionID == sessionID
  }

  private func endRecordingSession() {
    recordingSessionID = nil
    mediaControlTask?.cancel()
    mediaControlTask = nil
  }

  private func clearActiveRecordingMetadata() {
    activeRecordingSession = nil
  }

  private func invalidatePrimedState() {
    isRecorderPrimedForNextSession = false
    lastPrimedDeviceID = nil
  }

  private func updatePausedPlayers(_ players: [String], sessionID: UUID) {
    guard recordingSessionID == sessionID else { return }
    pausedPlayers = players
  }

  private func setDidPauseMedia(_ value: Bool, sessionID: UUID) {
    guard recordingSessionID == sessionID else { return }
    didPauseMedia = value
  }

  private func setDidPauseViaMediaRemote(_ value: Bool, sessionID: UUID) {
    guard recordingSessionID == sessionID else { return }
    didPauseViaMediaRemote = value
  }

  private func setPreviousVolume(_ volume: Float, sessionID: UUID) {
    guard recordingSessionID == sessionID else { return }
    previousVolume = volume
  }

  private func clearMediaState() {
    pausedPlayers = []
    didPauseMedia = false
    didPauseViaMediaRemote = false
    previousVolume = nil
  }

  @discardableResult
  private func pauseUsingMediaRemoteIfPossible(sessionID: UUID) async -> Bool {
    guard let controller = mediaRemoteController else {
      return false
    }

    let isPlaying = await controller.isMediaPlaying()
    guard isPlaying else {
      return false
    }
    guard isCurrentSession(sessionID), !Task.isCancelled else { return false }

    guard controller.send(.pause) else {
      mediaLogger.error("Failed to send MediaRemote pause command")
      return false
    }

    setDidPauseViaMediaRemote(true, sessionID: sessionID)
    mediaLogger.notice("Paused media via MediaRemote")
    return true
  }

  private enum RecorderPreparationError: Error {
    case failedToPrepareRecorder
    case missingRecordingOnDisk
  }

  private func ensureRecorderReadyForRecording() throws -> AVAudioRecorder {
    let recorder = try recorderOrCreate()

    if !isRecorderPrimedForNextSession {
      recordingLogger.notice("Recorder NOT primed, calling prepareToRecord() now")
      guard recorder.prepareToRecord() else {
        throw RecorderPreparationError.failedToPrepareRecorder
      }
    } else {
      recordingLogger.notice("Recorder already primed, skipping prepareToRecord()")
    }

    isRecorderPrimedForNextSession = false
    return recorder
  }

  private func recorderOrCreate() throws -> AVAudioRecorder {
    if let recorder {
      return recorder
    }

    let recorder = try AVAudioRecorder(url: recordingURL, settings: recorderSettings)
    recorder.isMeteringEnabled = true
    self.recorder = recorder
    return recorder
  }

  private func duplicateCurrentRecording() throws -> URL {
    let fm = FileManager.default

    guard fm.fileExists(atPath: recordingURL.path) else {
      throw RecorderPreparationError.missingRecordingOnDisk
    }

    let exportURL = recordingURL
      .deletingLastPathComponent()
      .appendingPathComponent("hex-recording-\(UUID().uuidString).wav")

    if fm.fileExists(atPath: exportURL.path) {
      try fm.removeItem(at: exportURL)
    }

    try fm.copyItem(at: recordingURL, to: exportURL)
    return exportURL
  }

  private func primeRecorderForNextSession() throws {
    let recorder = try recorderOrCreate()
    guard recorder.prepareToRecord() else {
      isRecorderPrimedForNextSession = false
      lastPrimedDeviceID = nil
      throw RecorderPreparationError.failedToPrepareRecorder
    }

    isRecorderPrimedForNextSession = true
    lastPrimedDeviceID = getDefaultInputDevice()
    recordingLogger.debug("Recorder primed for device \(self.lastPrimedDeviceID ?? 0)")
  }

  func startMeterTask() {
    meterTask = Task {
      while !Task.isCancelled, let r = self.recorder, r.isRecording {
        r.updateMeters()
        let averagePower = r.averagePower(forChannel: 0)
        let averageNormalized = pow(10, averagePower / 20.0)
        let peakPower = r.peakPower(forChannel: 0)
        let peakNormalized = pow(10, peakPower / 20.0)
        meterContinuation.yield(Meter(averagePower: Double(averageNormalized), peakPower: Double(peakNormalized)))
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  func stopMeterTask() {
    meterTask?.cancel()
    meterTask = nil
  }

  func observeAudioLevel() -> AsyncStream<Meter> {
    meterStream
  }

  func warmUpRecorder() async {
    guard activeRecordingSession == nil, recorder?.isRecording != true, !captureController.isRecording else {
      recordingLogger.notice("Skipping recorder warm-up while recording is active")
      return
    }
    guard !isCaptureSuspended else {
      recordingLogger.notice("Skipping recorder warm-up while capture is suspended (screen locked/asleep)")
      return
    }
    let activeInputDevice = applyPreferredInputDevice()

    if hexSettings.superFastModeEnabled {
      releaseRecorder(reason: "warm-up-super-fast")
      do {
        try ensureCaptureControllerReadyAfterDeferredRestart(for: activeInputDevice, reason: "warmUpRecorder")
      } catch {
        recordingLogger.error("Failed to arm capture engine for super fast mode: \(error.localizedDescription)")
      }
      return
    }

    stopCaptureController(reason: "warm-up-standard")
    releaseRecorder(reason: "warm-up-standard")
    recordingLogger.debug("Standard mode uses on-demand capture engine startup; skipping idle recorder priming")
  }

  /// Release recorder resources. Call on app termination.
  func cleanup() async {
    endRecordingSession()
    await resumeMediaIfNeeded()
    stopObservingSystemChanges()
    stopCaptureController(reason: "cleanup")
    releaseRecorder(reason: "cleanup")
    recordingLogger.notice("RecordingClient cleaned up")
  }
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}
