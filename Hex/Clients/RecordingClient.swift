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
}

extension RecordingClient: DependencyKey {
  static var liveValue: Self {
    let live = RecordingClientLive()
    return Self(
      startRecording: { await live.startRecording() },
      stopRecording: { await live.stopRecording() },
      requestMicrophoneAccess: { await live.requestMicrophoneAccess() },
      observeAudioLevel: { await live.observeAudioLevel() },
      getAvailableInputDevices: { await live.getAvailableInputDevices() }
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

/// Wraps a few MediaRemote functions.
@Observable
class MediaRemoteController {
  private var mediaRemoteHandle: UnsafeMutableRawPointer?
  private var mrNowPlayingIsPlaying: MRNowPlayingIsPlayingFunc?

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
  }

  deinit {
    if let handle = mediaRemoteHandle {
      dlclose(handle)
    }
  }

  /// Asynchronously refreshes the "is playing" status.
  func isMediaPlaying() async -> Bool {
    await withCheckedContinuation { continuation in
      mrNowPlayingIsPlaying?(DispatchQueue.main) {  isPlaying in
        continuation.resume(returning: isPlaying)
      }
    }
  }
}

// Global instance of MediaRemoteController
private let mediaRemoteController = MediaRemoteController()

func isAudioPlayingOnDefaultOutput() async -> Bool {
  // Refresh the state before checking
  await mediaRemoteController?.isMediaPlaying() ?? false
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

  mediaLogger.debug("Installed media players: \(installedMediaPlayers.keys.joined(separator: ", "), privacy: .public)")
  
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
      mediaLogger.error("Failed to pause media apps: \(error, privacy: .public)")
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
    
  mediaLogger.notice("Paused media players: \(pausedPlayers.joined(separator: ", "), privacy: .public)")
  
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
    mediaLogger.error("Failed to resume media apps: \(error, privacy: .public)")
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
  private let (meterStream, meterContinuation) = AsyncStream<Meter>.makeStream()
  private var meterTask: Task<Void, Never>?

  @Shared(.hexSettings) var hexSettings: HexSettings

  /// Tracks whether media was paused using the media key when recording started.
  private var didPauseMedia: Bool = false

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
  
  // MARK: - Core Audio Helpers
  
  /// Get all available audio devices
  private func getAllAudioDevices() -> [AudioDeviceID] {
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    
    // Get the property data size
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      recordingLogger.error("AudioObjectGetPropertyDataSize failed: \(status, privacy: .public)")
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
        recordingLogger.error("AudioObjectGetPropertyData failed while listing devices: \(status, privacy: .public)")
        return []
      }
    
    return deviceIDs
  }
  
  /// Get device name for the given device ID
  private func getDeviceName(deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceNameCFString,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    
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
        recordingLogger.error("Failed to fetch device name: \(status, privacy: .public)")
        return nil
      }
    
    return deviceName as String?
  }
  
  /// Check if device has input capabilities
  private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    
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
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      size,
      &device
    )
    
    if status != 0 {
      recordingLogger.error("Failed to set default input device: \(status, privacy: .public)")
    } else {
      recordingLogger.notice("Selected input device set to \(deviceID, privacy: .public)")
    }
  }

  func requestMicrophoneAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  // MARK: - Volume Control

  /// Mutes system volume and returns the previous volume level
  private func muteSystemVolume() async -> Float {
    let currentVolume = getSystemVolume()
    setSystemVolume(0)
    recordingLogger.notice("Muted system volume (was \(currentVolume, format: .fixed(precision: 2)))")
    return currentVolume
  }

  /// Restores system volume to the specified level
  private func restoreSystemVolume(_ volume: Float) async {
    setSystemVolume(volume)
    recordingLogger.notice("Restored system volume to \(volume, format: .fixed(precision: 2))")
  }

  /// Gets the default output device ID
  private func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    if status != 0 {
      recordingLogger.error("Failed to get default output device: \(status, privacy: .public)")
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
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &volume
    )

    if status != 0 {
      recordingLogger.error("Failed to get system volume: \(status, privacy: .public)")
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
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectSetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      size,
      &newVolume
    )

    if status != 0 {
      recordingLogger.error("Failed to set system volume: \(status, privacy: .public)")
    }
  }

  func startRecording() async {
    // Handle audio behavior based on user preference
    switch hexSettings.recordingAudioBehavior {
    case .pauseMedia:
      // Pause media in background - don't block recording from starting
      Task {
        // First, pause all media applications using their AppleScript interface.
        let paused = await pauseAllMediaApplications()
        self.updatePausedPlayers(paused)

        // If no specific players were paused, pause generic media using the media key.
        if paused.isEmpty {
          if await isAudioPlayingOnDefaultOutput() {
            mediaLogger.notice("Detected active audio on default output; sending media pause")
            await MainActor.run {
              sendMediaKey()
            }
            self.setDidPauseMedia(true)
            mediaLogger.notice("Paused media via media key fallback")
          }
        } else {
          mediaLogger.notice("Paused media players: \(paused.joined(separator: ", "), privacy: .public)")
        }
      }

    case .mute:
      // Mute system volume in background
      Task {
        let volume = await self.muteSystemVolume()
        self.setPreviousVolume(volume)
      }

    case .doNothing:
      // No audio handling
      break
    }

    // If user has selected a specific microphone, verify it exists and set it as the default input device
    if let selectedDeviceIDString = hexSettings.selectedMicrophoneID,
       let selectedDeviceID = AudioDeviceID(selectedDeviceIDString) {
      // Check if the selected device is still available
      let devices = getAllAudioDevices()
      if devices.contains(selectedDeviceID) && deviceHasInput(deviceID: selectedDeviceID) {
        recordingLogger.debug("Setting selected input device to \(selectedDeviceID, privacy: .public)")
        setInputDevice(deviceID: selectedDeviceID)
      } else {
        // Device no longer available, fall back to system default
        recordingLogger.notice("Selected device \(selectedDeviceID, privacy: .public) missing; using system default")
      }
    } else {
      recordingLogger.debug("Using default system microphone")
    }

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    do {
      recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
      recorder?.isMeteringEnabled = true
      recorder?.record()
      startMeterTask()
      recordingLogger.notice("Recording started")
    } catch {
      recordingLogger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
    }
  }

  func stopRecording() async -> URL {
    recorder?.stop()
    recorder = nil
    stopMeterTask()
    recordingLogger.notice("Recording stopped")

    // Resume audio in background - don't block stop from completing
    let playersToResume = pausedPlayers
    let shouldResumeMedia = didPauseMedia
    let volumeToRestore = previousVolume

    if !playersToResume.isEmpty || shouldResumeMedia || volumeToRestore != nil {
      Task {
        // Restore volume if it was muted
        if let volume = volumeToRestore {
          await self.restoreSystemVolume(volume)
        }
        // Resume media if we previously paused specific players
        else if !playersToResume.isEmpty {
          mediaLogger.notice("Resuming players: \(playersToResume.joined(separator: ", "), privacy: .public)")
          await resumeMediaApplications(playersToResume)
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

    return recordingURL
  }

  // Actor state update helpers
  private func updatePausedPlayers(_ players: [String]) {
    pausedPlayers = players
  }

  private func setDidPauseMedia(_ value: Bool) {
    didPauseMedia = value
  }

  private func setPreviousVolume(_ volume: Float) {
    previousVolume = volume
  }

  private func clearMediaState() {
    pausedPlayers = []
    didPauseMedia = false
    previousVolume = nil
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
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}
