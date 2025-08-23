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
      print("Unable to open MediaRemote")
      return nil
    }
    mediaRemoteHandle = handle

    // Get pointer for the "is playing" function.
    guard let playingPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
      print("Unable to find MRMediaRemoteGetNowPlayingApplicationIsPlaying")
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

/// Get a list of installed media player apps we should control
private func getInstalledMediaPlayers() -> [String: String] {
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
}

func pauseAllMediaApplications() async -> [String] {
  // First check which media players are actually installed
  let installedPlayers = getInstalledMediaPlayers()
  if installedPlayers.isEmpty {
    return []
  }

  print("Installed media players: \(installedPlayers.keys.joined(separator: ", "))")

  // Create AppleScript that only targets installed players
  var scriptParts: [String] = ["set pausedPlayers to {}"]

  for (appName, _) in installedPlayers {
    if appName == "VLC" {
      // VLC: only pause if actually playing; wrap in inner try to avoid script errors
      scriptParts.append("""
      try
        if application id "org.videolan.vlc" is running then
          tell application id "org.videolan.vlc"
            try
              if playing is true then
                pause
                set end of pausedPlayers to "VLC"
              end if
            end try
          end tell
        end if
      end try
      """)
    } else {
      // Music / iTunes / Spotify: only pause if actually playing; guard with running check
      scriptParts.append("""
      try
        if application "\(appName)" is running then
          tell application "\(appName)"
            try
              if player state is playing then
                pause
                set end of pausedPlayers to "\(appName)"
              end if
            end try
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
      print("Error pausing media applications: \(error)")
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

  print("Paused media players: \(pausedPlayers.joined(separator: ", "))")

  return pausedPlayers
}

func resumeMediaApplications(_ players: [String]) async {
  guard !players.isEmpty else { return }

  // First check which media players are actually installed
  let installedPlayers = getInstalledMediaPlayers()

  // Only attempt to resume players that are installed
  let validPlayers = players.filter { installedPlayers.keys.contains($0) }
  if validPlayers.isEmpty {
    return
  }

  // Create specific resume script for each player
  var scriptParts: [String] = []

  for player in validPlayers {
    if player == "VLC" {
      // VLC has a different AppleScript interface
      scriptParts.append("""
      try
        tell application id "org.videolan.vlc"
          if it is running then
            tell application id "org.videolan.vlc" to play
          end if
        end tell
      end try
      """)
    } else {
      // Standard interface for Music/iTunes/Spotify
      scriptParts.append("""
      try
        if application "\(player)" is running then
          tell application "\(player)" to play
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
    print("Error resuming media applications: \(error)")
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
      print("Error getting audio devices property size: \(status)")
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
      print("Error getting audio devices: \(status)")
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
    var deviceNamePtr: UnsafeMutableRawPointer = .allocate(byteCount: Int(size), alignment: MemoryLayout<CFString?>.alignment)
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
      print("Error getting device name: \(status)")
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

    // Allocate raw memory based on the actual byte size needed
    let rawBufferList = UnsafeMutableRawPointer.allocate(
      byteCount: Int(propertySize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawBufferList.deallocate() }
    let bufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)

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
      print("Error setting default input device: \(status)")
    } else {
      print("Successfully set input device to: \(deviceID)")
    }
  }

  func requestMicrophoneAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  func startRecording() async {
    // If audio is playing on the default output, pause it.
    if hexSettings.pauseMediaOnRecord {
      // First, pause all media applications using their AppleScript interface.
      pausedPlayers = await pauseAllMediaApplications()
      // If no specific players were paused, pause generic media using the media key.
      if pausedPlayers.isEmpty {
        if await isAudioPlayingOnDefaultOutput() {
          print("Audio is playing on the default output; pausing it for recording.")
          await MainActor.run {
            sendMediaKey()
          }
          didPauseMedia = true
          print("Media was playing; pausing it for recording.")
        }
      } else {
        print("Paused media players: \(pausedPlayers.joined(separator: ", "))")
      }
    }

    // If user has selected a specific microphone, verify it exists and set it as the default input device
    if let selectedDeviceIDString = hexSettings.selectedMicrophoneID,
       let selectedDeviceID = AudioDeviceID(selectedDeviceIDString) {
      // Check if the selected device is still available
      let devices = getAllAudioDevices()
      if devices.contains(selectedDeviceID) && deviceHasInput(deviceID: selectedDeviceID) {
        print("Setting selected input device: \(selectedDeviceID)")
        setInputDevice(deviceID: selectedDeviceID)
      } else {
        // Device no longer available, fall back to system default
        print("Selected device \(selectedDeviceID) is no longer available, using system default")
      }
    } else {
      print("Using default system microphone")
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
      print("Recording started.")
    } catch {
      print("Could not start recording: \(error)")
    }
  }

  func stopRecording() async -> URL {
    recorder?.stop()
    recorder = nil
    stopMeterTask()
    print("Recording stopped.")

    // Resume media if we previously paused specific players
    if !pausedPlayers.isEmpty {
      print("Resuming previously paused players: \(pausedPlayers.joined(separator: ", "))")
      await resumeMediaApplications(pausedPlayers)
      pausedPlayers = []
    }
    // Resume generic media if we paused it with the media key
    else if didPauseMedia {
      await MainActor.run {
        sendMediaKey()
      }
      didPauseMedia = false
      print("Resuming previously paused media.")
    }
    return recordingURL
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
