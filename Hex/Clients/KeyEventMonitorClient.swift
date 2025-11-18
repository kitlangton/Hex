import AppKit
import ApplicationServices
import Carbon
import ComposableArchitecture
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import IOKit
import IOKit.hidsystem
import Sauce

private let logger = HexLog.keyEvent

struct KeyEventMonitorToken: Sendable {
  private let cancelHandler: @Sendable () -> Void

  init(cancel: @escaping @Sendable () -> Void) {
    self.cancelHandler = cancel
  }

  func cancel() {
    cancelHandler()
  }

  static let noop = KeyEventMonitorToken(cancel: {})
}

public extension KeyEvent {
  init(cgEvent: CGEvent, type: CGEventType, isFnPressed: Bool) {
    let keyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
    // Accessing keyboard layout / input source via Sauce must be on main thread.
    let key: Key?
    if cgEvent.type == .keyDown {
      if Thread.isMainThread {
        key = Sauce.shared.key(for: keyCode)
      } else {
        key = DispatchQueue.main.sync { Sauce.shared.key(for: keyCode) }
      }
    } else {
      key = nil
    }

    var modifiers = Modifiers.from(carbonFlags: cgEvent.flags)
    if !isFnPressed {
      modifiers = modifiers.removing(kind: .fn)
    }
    self.init(key: key, modifiers: modifiers)
  }
}

@DependencyClient
struct KeyEventMonitorClient {
  var listenForKeyPress: @Sendable () async -> AsyncThrowingStream<KeyEvent, Error> = { .never }
  var handleKeyEvent: @Sendable (@escaping (KeyEvent) -> Bool) -> KeyEventMonitorToken = { _ in .noop }
  var handleInputEvent: @Sendable (@escaping (InputEvent) -> Bool) -> KeyEventMonitorToken = { _ in .noop }
  var startMonitoring: @Sendable () async -> Void = {}
  var stopMonitoring: @Sendable () -> Void = {}
}

extension KeyEventMonitorClient: DependencyKey {
  static var liveValue: KeyEventMonitorClient {
    let live = KeyEventMonitorClientLive()
    return KeyEventMonitorClient(
      listenForKeyPress: {
        live.listenForKeyPress()
      },
      handleKeyEvent: { handler in
        live.handleKeyEvent(handler)
      },
      handleInputEvent: { handler in
        live.handleInputEvent(handler)
      },
      startMonitoring: {
        live.startMonitoring()
      },
      stopMonitoring: {
        live.stopMonitoring()
      }
    )
  }
}

extension DependencyValues {
  var keyEventMonitor: KeyEventMonitorClient {
    get { self[KeyEventMonitorClient.self] }
    set { self[KeyEventMonitorClient.self] = newValue }
  }
}

class KeyEventMonitorClientLive {
  private var eventTapPort: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var continuations: [UUID: (KeyEvent) -> Bool] = [:]
  private var inputContinuations: [UUID: (InputEvent) -> Bool] = [:]
  private let queue = DispatchQueue(label: "com.kitlangton.Hex.KeyEventMonitor", attributes: .concurrent)
  private var isMonitoring = false
  private var wantsMonitoring = false
  private var accessibilityTrusted = false
  private var inputMonitoringTrusted = false
  private var trustMonitorTask: Task<Void, Never>?
  private var isFnPressed = false
  private var hasPromptedForAccessibilityTrust = false
  @Shared(.hotkeyPermissionState) private var hotkeyPermissionState: HotkeyPermissionState

  private let trustCheckIntervalNanoseconds: UInt64 = 100_000_000 // 100ms

  init() {
    logger.info("Initializing HotKeyClient with CGEvent tap.")
  }

  deinit {
    self.stopMonitoring()
  }

  private var hasRequiredPermissions: Bool {
    queue.sync { accessibilityTrusted && inputMonitoringTrusted }
  }

  private var hasHandlers: Bool {
    queue.sync { !(continuations.isEmpty && inputContinuations.isEmpty) }
  }

  private func setMonitoringIntent(_ value: Bool) {
    queue.async(flags: .barrier) { [weak self] in
      self?.wantsMonitoring = value
    }
  }

  private func desiredMonitoringState() -> Bool {
    queue.sync {
      wantsMonitoring
        && accessibilityTrusted
        && inputMonitoringTrusted
        && !(continuations.isEmpty && inputContinuations.isEmpty)
    }
  }

  /// Provide a stream of key events.
  func listenForKeyPress() -> AsyncThrowingStream<KeyEvent, Error> {
    AsyncThrowingStream { continuation in
      let uuid = UUID()

      queue.async(flags: .barrier) { [weak self] in
        guard let self = self else { return }
        self.continuations[uuid] = { event in
          continuation.yield(event)
          return false
        }
        let shouldStart = self.continuations.count == 1 && self.inputContinuations.isEmpty

        // Start monitoring if this is the first subscription
        if shouldStart {
          self.startMonitoring()
        }
      }

      // Cleanup on cancellation
      continuation.onTermination = { [weak self] _ in
        self?.removeHandlerContinuation(uuid: uuid)
      }
    }
  }

  private func removeHandlerContinuation(uuid: UUID) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.continuations[uuid] = nil
      if self.continuations.isEmpty && self.inputContinuations.isEmpty {
        self.stopMonitoring()
      }
    }
  }

  private func removeInputContinuation(uuid: UUID) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.inputContinuations[uuid] = nil
      if self.continuations.isEmpty && self.inputContinuations.isEmpty {
        self.stopMonitoring()
      }
    }
  }

  func startMonitoring() {
    setMonitoringIntent(true)
    startTrustMonitorIfNeeded()
    refreshTrustedFlag(promptIfUntrusted: true)
    Task { [weak self] in
      await self?.refreshMonitoringState(reason: "startMonitoring")
    }
  }
  // TODO: Handle removing the handler from the continuations on deinit/cancellation
  func handleKeyEvent(_ handler: @escaping (KeyEvent) -> Bool) -> KeyEventMonitorToken {
    let uuid = UUID()

    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.continuations[uuid] = handler
      let shouldStart = self.continuations.count == 1 && self.inputContinuations.isEmpty

      if shouldStart {
        self.startMonitoring()
      }
    }

    return KeyEventMonitorToken { [weak self] in
      self?.removeHandlerContinuation(uuid: uuid)
    }
  }

  func handleInputEvent(_ handler: @escaping (InputEvent) -> Bool) -> KeyEventMonitorToken {
    let uuid = UUID()

    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.inputContinuations[uuid] = handler
      let shouldStart = self.inputContinuations.count == 1 && self.continuations.isEmpty

      if shouldStart {
        self.startMonitoring()
      }
    }

    return KeyEventMonitorToken { [weak self] in
      self?.removeInputContinuation(uuid: uuid)
    }
  }

  func stopMonitoring() {
    setMonitoringIntent(false)
    Task { [weak self] in
      await self?.refreshMonitoringState(reason: "stopMonitoring")
    }
    cancelTrustMonitorIfNeeded()
  }

  private func startTrustMonitorIfNeeded() {
    queue.async(flags: .barrier) { [weak self] in
      guard let self else { return }
      guard self.trustMonitorTask == nil else { return }
      self.trustMonitorTask = Task { [weak self] in
        await self?.watchPermissions()
      }
    }
  }

  private func cancelTrustMonitorIfNeeded() {
    queue.async(flags: .barrier) { [weak self] in
      guard let self else { return }
      guard !self.wantsMonitoring else { return }
      self.trustMonitorTask?.cancel()
      self.trustMonitorTask = nil
    }
  }

  // no separate helper; handled inline above

  private func watchPermissions() async {
    var last = (
      accessibility: currentAccessibilityTrust(),
      input: currentInputMonitoringTrust()
    )
    await handlePermissionChange(accessibility: last.accessibility, input: last.input, reason: "initial")

    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: trustCheckIntervalNanoseconds)
      let current = (
        accessibility: currentAccessibilityTrust(),
        input: currentInputMonitoringTrust()
      )

      if current.accessibility != last.accessibility || current.input != last.input {
        let combinedBefore = last.accessibility && last.input
        let combinedAfter = current.accessibility && current.input
        let reason: String
        if combinedAfter && !combinedBefore {
          reason = "regained"
        } else if !combinedAfter && combinedBefore {
          reason = "revoked"
        } else {
          reason = "updated"
        }
        await handlePermissionChange(accessibility: current.accessibility, input: current.input, reason: reason)
        last = current
      } else if current.accessibility && current.input {
        await ensureTapIsRunning()
      }
    }
  }

  private func handlePermissionChange(accessibility: Bool, input: Bool, reason: String) async {
    setPermissionFlags(accessibility: accessibility, input: input)
    logger.notice("Permission update: accessibility=\(accessibility), inputMonitoring=\(input), reason=\(reason)")
    if accessibility && input {
      logger.notice("Keyboard monitoring permissions granted (\(reason)).")
    } else {
      if !accessibility {
        logger.error("Accessibility permission missing (\(reason)); suspending tap.")
      }
      if !input {
        logger.error("Input Monitoring permission missing (\(reason)); waiting for approval before restarting hotkeys.")
      }
    }
    await refreshMonitoringState(reason: "trust_\(reason)")
  }

  private func ensureTapIsRunning() async {
    guard desiredMonitoringState() else { return }
    await activateTapOnMain(reason: "watchdog_keepalive")
  }

  private func refreshMonitoringState(reason: String) async {
    let shouldMonitor = desiredMonitoringState()
    if shouldMonitor {
      await activateTapOnMain(reason: reason)
    } else {
      await deactivateTapOnMain(reason: reason)
    }
  }

  private func setPermissionFlags(accessibility: Bool, input: Bool) {
    queue.async(flags: .barrier) { [weak self] in
      self?.accessibilityTrusted = accessibility
      self?.inputMonitoringTrusted = input
    }
    recordSharedPermissionState(accessibility: accessibility, input: input)
  }

  private func recordSharedPermissionState(accessibility: Bool, input: Bool) {
    $hotkeyPermissionState.withLock {
      $0.accessibility = accessibility ? .granted : .denied
      $0.inputMonitoring = input ? .granted : .denied
      $0.lastUpdated = Date()
    }
  }

  private func activateTapOnMain(reason: String) async {
    await MainActor.run {
      self.activateTapIfNeeded(reason: reason)
    }
  }

  private func deactivateTapOnMain(reason: String) async {
    await MainActor.run {
      self.deactivateTap(reason: reason)
    }
  }

  @MainActor
  private func activateTapIfNeeded(reason: String) {
    guard !isMonitoring else { return }
    guard hasHandlers else { return }

    let accessibilityTrusted = currentAccessibilityTrust()
    let inputMonitoringTrusted = currentInputMonitoringTrust()
    setPermissionFlags(accessibility: accessibilityTrusted, input: inputMonitoringTrusted)
    guard accessibilityTrusted else {
      logger.error("Cannot start key event monitoring (reason: \(reason)); accessibility permission is not granted.")
      return
    }

    guard inputMonitoringTrusted else {
      logger.error("Input Monitoring permission missing; cannot start key event monitoring (reason: \(reason)).")
      return
    }

    let eventMask =
      ((1 << CGEventType.keyDown.rawValue)
       | (1 << CGEventType.keyUp.rawValue)
       | (1 << CGEventType.flagsChanged.rawValue)
       | (1 << CGEventType.leftMouseDown.rawValue)
       | (1 << CGEventType.rightMouseDown.rawValue)
       | (1 << CGEventType.otherMouseDown.rawValue))

    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(eventMask),
        callback: { _, type, cgEvent, userInfo in
          guard
            let hotKeyClientLive = Unmanaged<KeyEventMonitorClientLive>
            .fromOpaque(userInfo!)
            .takeUnretainedValue() as KeyEventMonitorClientLive?
          else {
            return Unmanaged.passUnretained(cgEvent)
          }

          if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            hotKeyClientLive.handleTapDisabledEvent(type)
            return Unmanaged.passUnretained(cgEvent)
          }

          guard hotKeyClientLive.hasRequiredPermissions else {
            return Unmanaged.passUnretained(cgEvent)
          }

          if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            _ = hotKeyClientLive.processInputEvent(.mouseClick)
            return Unmanaged.passUnretained(cgEvent)
          }

          hotKeyClientLive.updateFnStateIfNeeded(type: type, cgEvent: cgEvent)

          let keyEvent = KeyEvent(cgEvent: cgEvent, type: type, isFnPressed: hotKeyClientLive.isFnPressed)
          let handledByKeyHandler = hotKeyClientLive.processKeyEvent(keyEvent)
          let handledByInputHandler = hotKeyClientLive.processInputEvent(.keyboard(keyEvent))

          return (handledByKeyHandler || handledByInputHandler) ? nil : Unmanaged.passUnretained(cgEvent)
        },
        userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
      )
    else {
      logger.error("Failed to create event tap (reason: \(reason)).")
      return
    }

    eventTapPort = eventTap

    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    self.runLoopSource = runLoopSource

    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    isMonitoring = true
    logger.info("Started monitoring key events via CGEvent tap (reason: \(reason)).")
  }

  @MainActor
  private func deactivateTap(reason: String) {
    guard isMonitoring || eventTapPort != nil else { return }

    if let runLoopSource = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      self.runLoopSource = nil
    }

    if let eventTapPort = eventTapPort {
      CGEvent.tapEnable(tap: eventTapPort, enable: false)
      self.eventTapPort = nil
    }

    isMonitoring = false
    logger.info("Suspended key event monitoring (reason: \(reason)).")
  }

  private func handleTapDisabledEvent(_ type: CGEventType) {
    let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
    logger.error("Event tap disabled by \(reason); scheduling restart.")
    Task { [weak self] in
      guard let self else { return }
      await self.refreshMonitoringState(reason: "tap_disabled_\(reason)")
    }
  }

  private func processKeyEvent(_ keyEvent: KeyEvent) -> Bool {
    // Read with concurrent access (no barrier)
    let handlers = queue.sync { Array(continuations.values) }

    var handled = false
    for continuation in handlers {
      if continuation(keyEvent) {
        handled = true
      }
    }

    return handled
  }

  private func processInputEvent(_ inputEvent: InputEvent) -> Bool {
    // Read with concurrent access (no barrier)
    let handlers = queue.sync { Array(inputContinuations.values) }

    var handled = false
    for continuation in handlers {
      if continuation(inputEvent) {
        handled = true
      }
    }

    return handled
  }
}

extension KeyEventMonitorClientLive {
  private func updateFnStateIfNeeded(type: CGEventType, cgEvent: CGEvent) {
    guard type == .flagsChanged else { return }
    let keyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
    guard keyCode == kVK_Function else { return }
    isFnPressed = cgEvent.flags.contains(.maskSecondaryFn)
  }

  private func refreshTrustedFlag(promptIfUntrusted: Bool) {
    var accessibilityTrusted = currentAccessibilityTrust()
    if !accessibilityTrusted && promptIfUntrusted && !hasPromptedForAccessibilityTrust {
      accessibilityTrusted = requestAccessibilityTrustPrompt()
      hasPromptedForAccessibilityTrust = true
      logger.notice("Prompted for accessibility trust")
    }

    let inputMonitoringTrusted = currentInputMonitoringTrust()
    setPermissionFlags(accessibility: accessibilityTrusted, input: inputMonitoringTrusted)
  }

  private func currentAccessibilityTrust() -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary)
  }

  private func requestAccessibilityTrustPrompt() -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
  }

  private func currentInputMonitoringTrust() -> Bool {
    IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
  }

  // Intentionally no request helper: creating the event tap prompts macOS 15+ for Input Monitoring
  // the same way older versions did, while we still track status for UI.
}
