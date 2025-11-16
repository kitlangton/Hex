import AppKit
import Carbon
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os
import Sauce

private let logger = Logger(subsystem: "com.kitlangton.Hex", category: "KeyEventMonitor")

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
  var handleKeyEvent: @Sendable (@escaping (KeyEvent) -> Bool) -> Void = { _ in }
  var handleInputEvent: @Sendable (@escaping (InputEvent) -> Bool) -> Void = { _ in }
  var startMonitoring: @Sendable () async -> Void = {}
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
  private let enableModifierDiagnostics = ProcessInfo.processInfo.environment["HEX_DIAG_MODIFIERS"] == "1"
  private var isFnPressed = false

  init() {
    logger.info("Initializing HotKeyClient with CGEvent tap.")
  }

  deinit {
    self.stopMonitoring()
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
        self?.removeContinuation(uuid: uuid)
      }
    }
  }

  private func removeContinuation(uuid: UUID) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.continuations[uuid] = nil
      let shouldStop = self.continuations.isEmpty && self.inputContinuations.isEmpty

      // Stop monitoring if no more listeners
      if shouldStop {
        self.stopMonitoring()
      }
    }
  }

  func startMonitoring() {
    guard !isMonitoring else { return }
    isMonitoring = true

    if enableModifierDiagnostics {
      logger.info("ModifierDiag enabled; logging flagsChanged events.")
    }

    // Create an event tap at the HID level to capture keyDown, keyUp, flagsChanged, and mouse events
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

          // Check if it's a mouse event
          if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            let handled = hotKeyClientLive.processInputEvent(.mouseClick)
            return handled ? nil : Unmanaged.passUnretained(cgEvent)
          }

          hotKeyClientLive.updateFnStateIfNeeded(type: type, cgEvent: cgEvent)

          // Otherwise it's a keyboard event
          let keyEvent = KeyEvent(cgEvent: cgEvent, type: type, isFnPressed: hotKeyClientLive.isFnPressed)
          hotKeyClientLive.logModifierDiagnostics(eventType: type, cgEvent: cgEvent, keyEvent: keyEvent)
          let handledByKeyHandler = hotKeyClientLive.processKeyEvent(keyEvent)
          let handledByInputHandler = hotKeyClientLive.processInputEvent(.keyboard(keyEvent))

          if handledByKeyHandler || handledByInputHandler {
            return nil
          } else {
            return Unmanaged.passUnretained(cgEvent)
          }
        },
        userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
      )
    else {
      isMonitoring = false
      logger.error("Failed to create event tap.")
      return
    }

    eventTapPort = eventTap

    // Create a RunLoop source and add it to the current run loop
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    self.runLoopSource = runLoopSource

    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)

    logger.info("Started monitoring key events via CGEvent tap.")
  }

  // TODO: Handle removing the handler from the continuations on deinit/cancellation
  func handleKeyEvent(_ handler: @escaping (KeyEvent) -> Bool) {
    let uuid = UUID()

    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.continuations[uuid] = handler
      let shouldStart = self.continuations.count == 1 && self.inputContinuations.isEmpty

      if shouldStart {
        self.startMonitoring()
      }
    }
  }

  func handleInputEvent(_ handler: @escaping (InputEvent) -> Bool) {
    let uuid = UUID()

    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.inputContinuations[uuid] = handler
      let shouldStart = self.inputContinuations.count == 1 && self.continuations.isEmpty

      if shouldStart {
        self.startMonitoring()
      }
    }
  }

  private func stopMonitoring() {
    guard isMonitoring else { return }
    isMonitoring = false

    if let runLoopSource = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      self.runLoopSource = nil
    }

    if let eventTapPort = eventTapPort {
      CGEvent.tapEnable(tap: eventTapPort, enable: false)
      self.eventTapPort = nil
    }

    logger.info("Stopped monitoring key events via CGEvent tap.")
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

// MARK: - Diagnostics
extension KeyEventMonitorClientLive {
  private func updateFnStateIfNeeded(type: CGEventType, cgEvent: CGEvent) {
    guard type == .flagsChanged else { return }
    let keyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
    guard keyCode == kVK_Function else { return }
    isFnPressed = cgEvent.flags.contains(.maskSecondaryFn)
  }

  private enum DeviceModifierMask: UInt64 {
    case leftControl = 0x00000001
    case leftShift = 0x00000002
    case rightShift = 0x00000004
    case leftCommand = 0x00000008
    case rightCommand = 0x00000010
    case leftOption = 0x00000020
    case rightOption = 0x00000040
    case rightControl = 0x00002000
  }

  private func logModifierDiagnostics(eventType: CGEventType, cgEvent: CGEvent, keyEvent: KeyEvent) {
    guard enableModifierDiagnostics, eventType == .flagsChanged else { return }

    let keyCode = cgEvent.getIntegerValueField(.keyboardEventKeycode)
    let flags = cgEvent.flags.rawValue
    let keyCodeHex = String(format: "0x%02llX", keyCode)
    let flagsHex = String(format: "0x%08llX", flags)

    logger.info(
      "ModifierDiag type=\(eventType.rawValue, privacy: .public) keyCode=\(keyCodeHex, privacy: .public) flags=\(flagsHex, privacy: .public) devices=\(self.deviceSideDescription(flags: flags), privacy: .public) mods=\(self.modifiersDescription(keyEvent.modifiers), privacy: .public)"
    )
  }

  private func deviceSideDescription(flags: UInt64) -> String {
    var sides: [String] = []
    if flags & DeviceModifierMask.leftControl.rawValue != 0 { sides.append("leftControl") }
    if flags & DeviceModifierMask.leftShift.rawValue != 0 { sides.append("leftShift") }
    if flags & DeviceModifierMask.rightShift.rawValue != 0 { sides.append("rightShift") }
    if flags & DeviceModifierMask.leftCommand.rawValue != 0 { sides.append("leftCommand") }
    if flags & DeviceModifierMask.rightCommand.rawValue != 0 { sides.append("rightCommand") }
    if flags & DeviceModifierMask.leftOption.rawValue != 0 { sides.append("leftOption") }
    if flags & DeviceModifierMask.rightOption.rawValue != 0 { sides.append("rightOption") }
    if flags & DeviceModifierMask.rightControl.rawValue != 0 { sides.append("rightControl") }
    return sides.isEmpty ? "-" : sides.joined(separator: ",")
  }

  private func modifiersDescription(_ modifiers: Modifiers) -> String {
    let names = modifiers.sorted.map { modifier -> String in
      switch modifier.kind {
      case .command: return modifier.side == .either ? "command" : "command-\(modifier.side.displayName.lowercased())"
      case .option: return modifier.side == .either ? "option" : "option-\(modifier.side.displayName.lowercased())"
      case .shift: return modifier.side == .either ? "shift" : "shift-\(modifier.side.displayName.lowercased())"
      case .control: return modifier.side == .either ? "control" : "control-\(modifier.side.displayName.lowercased())"
      case .fn: return "fn"
      }
    }
    return names.isEmpty ? "-" : names.joined(separator: "+")
  }
}
