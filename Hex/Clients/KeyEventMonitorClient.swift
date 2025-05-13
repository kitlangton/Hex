import AppKit
import Carbon
import Dependencies
import DependenciesMacros
import Foundation
import os
import Sauce

private let logger = Logger(subsystem: "com.kitlangton.Hex", category: "KeyEventMonitor")

/// Thread-safe wrapper for interacting with the Sauce library
/// This ensures all Sauce operations happen on the main thread
/// to prevent "_dispatch_assert_queue_fail" errors
enum SafeSauce {
    /// Thread-safe way to call Sauce methods from any thread
    static func performOnMainThread<T>(_ operation: @escaping () -> T) -> T {
        // If we're already on the main thread, just perform the operation
        if Thread.isMainThread {
            return operation()
        }
        
        // Otherwise dispatch to main thread and wait for result
        return DispatchQueue.main.sync {
            operation()
        }
    }
    
    // Convenience methods that handle thread switching automatically
    static func safeKey(for keyCode: Int) -> Key? {
        performOnMainThread { Sauce.shared.key(for: keyCode) }
    }
    
    static func safeKeyCode(for key: Key) -> CGKeyCode {
        performOnMainThread { Sauce.shared.keyCode(for: key) }
    }
}

public struct KeyEvent {
  let key: Key?
  let modifiers: Modifiers
}

public extension KeyEvent {
  init(cgEvent: CGEvent, type _: CGEventType) {
    let keyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
    // Use our thread-safe wrapper to prevent _dispatch_assert_queue_fail
    let key: Key? = cgEvent.type == .keyDown ? SafeSauce.safeKey(for: keyCode) : nil

    let modifiers = Modifiers.from(carbonFlags: cgEvent.flags)
    self.init(key: key, modifiers: modifiers)
  }
}

@DependencyClient
struct KeyEventMonitorClient {
  var listenForKeyPress: @Sendable () async -> AsyncThrowingStream<KeyEvent, Error> = { .never }
  var handleKeyEvent: @Sendable (@escaping (KeyEvent) -> Bool) -> Void = { _ in }
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
      continuations[uuid] = { event in
        continuation.yield(event)
        return false
      }

      // Start monitoring if this is the first subscription
      if continuations.count == 1 {
        startMonitoring()
      }

      // Cleanup on cancellation
      continuation.onTermination = { [weak self] _ in
        self?.removeContinuation(uuid: uuid)
      }
    }
  }

  private func removeContinuation(uuid: UUID) {
    continuations[uuid] = nil

    // Stop monitoring if no more listeners
    if continuations.isEmpty {
      stopMonitoring()
    }
  }

  func startMonitoring() {
    guard !isMonitoring else { return }
    isMonitoring = true

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

  // TODO: Handle removing the handler from the continuations on deinit/cancellation
  func handleKeyEvent(_ handler: @escaping (KeyEvent) -> Bool) {
    let uuid = UUID()
    continuations[uuid] = handler

    if continuations.count == 1 {
      startMonitoring()
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
    var handled = false

    for continuation in continuations.values {
      if continuation(keyEvent) {
        handled = true
      }
    }

    return handled
  }
}