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

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Equatable {
  var id: String
  var name: String
}

@DependencyClient
struct RecordingClient {
  var startRecording: @Sendable () async -> Void = {}
  var stopRecording: @Sendable () async -> URL = { URL(fileURLWithPath: "") }
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

actor RecordingClientLive {
  private var recorder: AVAudioRecorder?
  private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")
  private var isRecorderPrimedForNextSession = false
  private var lastPrimedDeviceID: AudioDeviceID?
  private var recordingSessionID: UUID?
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

  @Shared(.hexSettings) var hexSettings: HexSettings

  /// Tracks whether media was paused using the media key when recording started.
  private var didPauseMedia: Bool = false

  /// Tracks whether media was toggled via MediaRemote
  private var didPauseViaMediaRemote: Bool = false

  /// Tracks which specific media players were paused
  private var pausedPlayers: [String] = []

  /// Tracks previous system volume when muted for recording
  private var previousVolume: Float?

  // Cache to store already-processed device information
  private var deviceCache: [AudioDeviceID: (hasInput: Bool, name: String?)] = [:]
  private var lastDeviceCheck = Date(timeIntervalSince1970: 0)
  
  /// Gets all available input devices on the system
  func getAvailableInputDevices() async -> [AudioInputDevice] {
    // Reset cache if it's been more than 5 minutes since last full refresh
    let now = Date()
    if now.timeIntervalSince(lastDeviceCheck) > 300 {
      deviceCache.removeAll()
      lastDeviceCheck = now
    }
    
    // Get all available audio devices
    let devices = getAllAudioDevices()
    var inputDevices: [AudioInputDevice] = []
    
    // Filter to only input devices and convert to our model
    for device in devices {
      let hasInput: Bool
      let name: String?
      
      // Check cache first to avoid expensive Core Audio calls
      if let cached = deviceCache[device] {
        hasInput = cached.hasInput
        name = cached.name
      } else {
        hasInput = deviceHasInput(deviceID: device)
        name = hasInput ? getDeviceName(deviceID: device) : nil
        deviceCache[device] = (hasInput, name)
      }
      
      if hasInput, let deviceName = name {
        inputDevices.append(AudioInputDevice(id: String(device), name: deviceName))
      }
    }
    
    return inputDevices
  }

  /// Gets the current system default input device name
  func getDefaultInputDeviceName() async -> String? {
    guard let deviceID = getDefaultInputDevice() else { return nil }
    if let cached = deviceCache[deviceID], cached.hasInput, let name = cached.name {
      return name
    }
    let name = getDeviceName(deviceID: deviceID)
    if let name {
      deviceCache[deviceID] = (hasInput: true, name: name)
    }
    return name
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
    var address = audioPropertyAddress(kAudioDevicePropertyDeviceNameCFString)
    
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
        recordingLogger.error("Failed to fetch device name: \(status)")
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
    mediaControlTask?.cancel()
    mediaControlTask = nil

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
        await self.updatePausedPlayers(paused, sessionID: sessionID)

        // If no specific players were paused, pause generic media using the media key.
        guard await self.isCurrentSession(sessionID) else { return }
        if paused.isEmpty {
          if await isAudioPlayingOnDefaultOutput() {
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
        await self.setPreviousVolume(volume, sessionID: sessionID)
      }

    case .doNothing:
      // No audio handling
      break
    }

    // Determine target input device (custom selection or system default)
    let targetDeviceID: AudioDeviceID? = {
      if let selectedDeviceIDString = hexSettings.selectedMicrophoneID,
         let selectedDeviceID = AudioDeviceID(selectedDeviceIDString) {
        // Verify the selected device is still available
        let devices = getAllAudioDevices()
        if devices.contains(selectedDeviceID) && deviceHasInput(deviceID: selectedDeviceID) {
          return selectedDeviceID
        } else {
          recordingLogger.notice("Selected device \(selectedDeviceID) missing; using system default")
          return nil
        }
      }
      return nil  // Use system default
    }()

    // Get current default input device
    let currentDefaultDevice = getDefaultInputDevice()
    if let primedDevice = lastPrimedDeviceID, primedDevice != currentDefaultDevice {
      recordingLogger.notice("Default input changed from \(primedDevice) to \(currentDefaultDevice ?? 0); invalidating primed state")
      invalidatePrimedState()
    }

    // Only change device if target differs from current default
    if let target = targetDeviceID {
      if target != currentDefaultDevice {
        recordingLogger.notice("Switching input device from \(currentDefaultDevice ?? 0) to \(target)")
        setInputDevice(deviceID: target)
        // Invalidate primed state since device changed - recorder was prepared for old device
        invalidatePrimedState()
      } else {
        recordingLogger.debug("Device \(target) already set as default, skipping setInputDevice()")
      }
    } else {
      recordingLogger.debug("Using system default microphone")
    }

    do {
      let recorder = try ensureRecorderReadyForRecording()
      guard recorder.record() else {
        recordingLogger.error("AVAudioRecorder refused to start recording")
        endRecordingSession()
        return
      }
      startMeterTask()
      recordingLogger.notice("Recording started")
    } catch {
      recordingLogger.error("Failed to start recording: \(error.localizedDescription)")
      endRecordingSession()
    }
  }

  func stopRecording() async -> URL {
    let wasRecording = recorder?.isRecording == true
    recorder?.stop()
    stopMeterTask()
    endRecordingSession()
    if wasRecording {
      recordingLogger.notice("Recording stopped")
    } else {
      recordingLogger.notice("stopRecording() called while recorder was idle")
    }

    var exportedURL = recordingURL
    var didCopyRecording = false
    do {
      exportedURL = try duplicateCurrentRecording()
      didCopyRecording = true
    } catch {
      isRecorderPrimedForNextSession = false
      recordingLogger.error("Failed to copy recording: \(error.localizedDescription)")
    }

    if didCopyRecording {
      do {
        try primeRecorderForNextSession()
      } catch {
        isRecorderPrimedForNextSession = false
        recordingLogger.error("Failed to prime recorder: \(error.localizedDescription)")
      }
    }

    // Resume audio in background - don't block stop from completing
    let playersToResume = pausedPlayers
    let shouldResumeMedia = didPauseMedia
    let shouldResumeViaMediaRemote = didPauseViaMediaRemote
    let volumeToRestore = previousVolume

    if !playersToResume.isEmpty || shouldResumeMedia || shouldResumeViaMediaRemote || volumeToRestore != nil {
      Task {
        // Restore volume if it was muted
        if let volume = volumeToRestore {
          await self.restoreSystemVolume(volume)
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

        // Clear the flags
        self.clearMediaState()
      }
    }

    return exportedURL
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
    do {
      try primeRecorderForNextSession()
    } catch {
      recordingLogger.error("Failed to warm up recorder: \(error.localizedDescription)")
    }
  }

  /// Release recorder resources. Call on app termination.
  func cleanup() {
    endRecordingSession()
    if let recorder = recorder {
      if recorder.isRecording {
        recorder.stop()
      }
      self.recorder = nil
    }
    isRecorderPrimedForNextSession = false
    lastPrimedDeviceID = nil
    recordingLogger.notice("RecordingClient cleaned up")
  }
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}
