import AppKit
import Carbon
import Dependencies
import DependenciesMacros
import Foundation
import os
import Sauce

private let logger = Logger(subsystem: "com.kitlangton.Hex", category: "KeyEventMonitor")

public struct KeyEvent {
  let key: Key?
  let modifiers: Modifiers
}

public extension KeyEvent {
  init(cgEvent: CGEvent, type _: CGEventType) {
    let keyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
    let key = cgEvent.type == .keyDown ? Sauce.shared.key(for: keyCode) : nil

    let modifiers = Modifiers.from(carbonFlags: cgEvent.flags)
    self.init(key: key, modifiers: modifiers)
  }
}

@DependencyClient
struct KeyEventMonitorClient {
  var listenForKeyPress: @Sendable () async -> AsyncThrowingStream<KeyEvent, Error> = { .never }
  var handleKeyEvent: @Sendable (@escaping (KeyEvent) -> Bool) -> UUID = { _ in UUID() }
  var removeKeyEventHandler: @Sendable (UUID) -> Void = { _ in }
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
      removeKeyEventHandler: { uuid in
        live.removeKeyEventHandler(uuid)
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
  private var isMonitoring = false
  
  // Thread safety: All access to continuations and isMonitoring must be synchronized
  private let lock = NSLock()

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
      
      lock.lock()
      continuations[uuid] = { event in
        continuation.yield(event)
        return false
      }
      let shouldStartMonitoring = continuations.count == 1
      lock.unlock()

      // Start monitoring if this is the first subscription
      if shouldStartMonitoring {
        startMonitoring()
      }

      // Cleanup on cancellation
      continuation.onTermination = { [weak self] _ in
        self?.removeContinuation(uuid: uuid)
      }
    }
  }

  private func removeContinuation(uuid: UUID) {
    lock.lock()
    continuations[uuid] = nil
    let shouldStopMonitoring = continuations.isEmpty
    lock.unlock()

    // Stop monitoring if no more listeners
    if shouldStopMonitoring {
      stopMonitoring()
    }
  }

  func startMonitoring() {
    lock.lock()
    guard !isMonitoring else {
      lock.unlock()
      return
    }
    isMonitoring = true
    lock.unlock()

    // Create an event tap at the HID level to capture keyDown, keyUp, and flagsChanged
    let eventMask =
      ((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue))

    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(eventMask),
        callback: { _, type, cgEvent, userInfo in
          // If the tap is disabled by timeout or by user input, re-enable it to keep
          // the app responsive over long uptimes.
          if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let live = Unmanaged<KeyEventMonitorClientLive>.fromOpaque(userInfo!)
              .takeUnretainedValue() as KeyEventMonitorClientLive?
            {
              if let port = live.eventTapPort {
                CGEvent.tapEnable(tap: port, enable: true)
                logger.info("CGEvent tap was disabled; re-enabled.")
              }
            }
            return Unmanaged.passUnretained(cgEvent)
          }
          guard
            let hotKeyClientLive = Unmanaged<KeyEventMonitorClientLive>
            .fromOpaque(userInfo!)
            .takeUnretainedValue() as KeyEventMonitorClientLive?
          else {
            return Unmanaged.passUnretained(cgEvent)
          }

          let keyEvent = KeyEvent(cgEvent: cgEvent, type: type)
          let handled = hotKeyClientLive.processKeyEvent(keyEvent)

          if handled {
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

  /// Register a key event handler and return a UUID for later removal
  func handleKeyEvent(_ handler: @escaping (KeyEvent) -> Bool) -> UUID {
    let uuid = UUID()
    
    lock.lock()
    continuations[uuid] = handler
    let shouldStartMonitoring = continuations.count == 1
    lock.unlock()

    if shouldStartMonitoring {
      startMonitoring()
    }
    
    return uuid
  }
  
  /// Remove a previously registered key event handler
  func removeKeyEventHandler(_ uuid: UUID) {
    lock.lock()
    continuations[uuid] = nil
    let shouldStopMonitoring = continuations.isEmpty
    lock.unlock()
    
    // Stop monitoring if no more listeners
    if shouldStopMonitoring {
      stopMonitoring()
    }
  }

  private func stopMonitoring() {
    lock.lock()
    guard isMonitoring else {
      lock.unlock()
      return
    }
    isMonitoring = false
    lock.unlock()

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
    var handled = false

    // Create a copy of handlers to avoid holding the lock while calling them
    lock.lock()
    let handlers = Array(continuations.values)
    lock.unlock()
    
    // Process handlers outside the lock to avoid deadlocks
    for handler in handlers {
      if handler(keyEvent) {
        handled = true
      }
    }

    return handled
  }
}
