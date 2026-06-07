import ApplicationServices
import AppKit
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let liveTextInsertionLogger = HexLog.pasteboard

@DependencyClient
struct LiveTextInsertionClient {
  /// Capture focus synchronously on the hotkey event path, before async work runs.
  var prepareNow: @Sendable () -> Bool = { false }
  var prepare: @Sendable () async -> Bool = { false }
  var begin: @Sendable () async -> Bool = { false }
  var update: @Sendable (String) async -> Bool = { _ in false }
  var finalize: @Sendable (String) async -> Bool = { _ in false }
  var revert: @Sendable () async -> Void = {}
  var isActive: @Sendable () async -> Bool = { false }
  var isKeystrokeUpdateInFlight: @Sendable () -> Bool = { false }
}

extension LiveTextInsertionClient: DependencyKey {
  static var liveValue: Self {
    let live = LiveTextInsertionClientLive()
    return .init(
      prepareNow: {
        if Thread.isMainThread {
          return MainActor.assumeIsolated { live.prepareNow() }
        }
        return DispatchQueue.main.sync { live.prepareNow() }
      },
      prepare: { await live.prepare() },
      begin: { await live.begin() },
      update: { text in await live.update(text) },
      finalize: { text in await live.finalize(text) },
      revert: { await live.revert() },
      isActive: { await live.isActive() },
      isKeystrokeUpdateInFlight: {
        if Thread.isMainThread {
          return MainActor.assumeIsolated { live.isKeystrokeUpdateInFlight }
        }
        return DispatchQueue.main.sync { live.isKeystrokeUpdateInFlight }
      }
    )
  }
}

extension DependencyValues {
  var liveTextInsertion: LiveTextInsertionClient {
    get { self[LiveTextInsertionClient.self] }
    set { self[LiveTextInsertionClient.self] = newValue }
  }
}

final class LiveTextInsertionClientLive {
  private enum Session {
    case accessibility(element: AXUIElement, bundleID: String?, state: LiveTextInsertionState)
    case keystroke(bundleID: String?)
  }

  @MainActor private var session: Session?
  @MainActor private var insertedText = ""
  @MainActor private var keystrokeUpdateChain: Task<Bool, Never>?
  @MainActor private var keystrokeUpdateGeneration = 0
  @MainActor private var pendingKeystrokeText: String?
  @MainActor private(set) var isKeystrokeUpdateInFlight = false
  private let pasteboard = PasteboardClientLive()

  private static let hexBundleIdentifiers: Set<String> = [
    "com.kitlangton.Hex",
    "com.kitlangton.Hex.debug",
  ]

  @MainActor
  func prepareNow() -> Bool {
    prepare()
  }

  @MainActor
  func prepare() -> Bool {
    resetSession()

    if let captured = FocusedTextFieldEditor.captureFromFrontmostApp(
      excludingBundleIdentifiers: Self.hexBundleIdentifiers
    ) {
      session = .accessibility(
        element: captured.element,
        bundleID: captured.bundleID,
        state: captured.state
      )
      liveTextInsertionLogger.notice(
        "Live text insertion prepared mode=accessibility app=\(captured.bundleID ?? "unknown") prefixChars=\(captured.state.prefix.count) suffixChars=\(captured.state.suffix.count)"
      )
      return true
    }

    let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    guard let bundleID, !Self.hexBundleIdentifiers.contains(bundleID) else {
      liveTextInsertionLogger.notice(
        "Live text insertion prepare failed: frontmost app is Hex or missing"
      )
      return false
    }

    if let selectedTextElement = FocusedTextFieldEditor.captureSelectedTextElement(
      excludingBundleIdentifiers: Self.hexBundleIdentifiers
    ) {
      session = .accessibility(
        element: selectedTextElement.element,
        bundleID: selectedTextElement.bundleID,
        state: selectedTextElement.state
      )
      liveTextInsertionLogger.notice(
        "Live text insertion prepared mode=accessibility-selected-text app=\(selectedTextElement.bundleID ?? "unknown")"
      )
      return true
    }

    session = .keystroke(bundleID: bundleID)
    liveTextInsertionLogger.notice(
      "Live text insertion prepared mode=keystroke app=\(bundleID)"
    )
    return true
  }

  @MainActor
  func begin() -> Bool {
    if session != nil { return true }
    return prepare()
  }

  @MainActor
  func update(_ text: String) async -> Bool {
    guard let session else { return false }

    switch session {
    case let .accessibility(element, bundleID, state):
      var mutableState = state
      let previousInsertedLength = mutableState.insertedText.count
      let newValue = mutableState.update(with: text)
      guard FocusedTextFieldEditor.apply(
        to: element,
        state: mutableState,
        value: newValue,
        previousInsertedLength: previousInsertedLength
      ) else {
        liveTextInsertionLogger.debug(
          "Live text insertion accessibility update failed app=\(bundleID ?? "unknown") chars=\(text.count)"
        )
        return false
      }

      self.session = .accessibility(element: element, bundleID: bundleID, state: mutableState)
      insertedText = text
      liveTextInsertionLogger.notice("Live text insertion updated mode=accessibility chars=\(text.count)")
      return true

    case let .keystroke(bundleID):
      pendingKeystrokeText = text
      keystrokeUpdateGeneration &+= 1
      let generation = keystrokeUpdateGeneration
      isKeystrokeUpdateInFlight = true
      let priorChain = keystrokeUpdateChain
      let updateTask = Task { @MainActor in
        if let priorChain {
          _ = await priorChain.value
        }

        defer {
          if self.keystrokeUpdateGeneration == generation {
            self.isKeystrokeUpdateInFlight = false
          }
        }

        var lastSucceeded = false
        while let targetText = self.pendingKeystrokeText {
          self.pendingKeystrokeText = nil
          let previousText = self.insertedText
          lastSucceeded = await self.pasteboard.replaceLiveText(
            targetBundleID: bundleID,
            previousText: previousText,
            newText: targetText
          )
          if lastSucceeded {
            self.insertedText = targetText
          } else if !previousText.isEmpty {
            liveTextInsertionLogger.debug(
              "Live text insertion keystroke replace failed; keeping previous snapshot chars=\(previousText.count)"
            )
          }
        }
        return lastSucceeded
      }
      keystrokeUpdateChain = updateTask
      guard await updateTask.value else {
        liveTextInsertionLogger.debug(
          "Live text insertion keystroke update failed app=\(bundleID ?? "unknown") chars=\(text.count)"
        )
        return false
      }
      liveTextInsertionLogger.notice("Live text insertion updated mode=keystroke chars=\(text.count)")
      return true
    }
  }

  @MainActor
  func finalize(_ text: String) async -> Bool {
    guard session != nil else { return false }
    let succeeded = await update(text)
    if succeeded {
      resetSession()
      liveTextInsertionLogger.notice("Live text insertion finalized chars=\(text.count)")
    }
    return succeeded
  }

  @MainActor
  func revert() async {
    guard let session, !insertedText.isEmpty else {
      resetSession()
      return
    }

    switch session {
    case let .accessibility(element, _, state):
      let restored = state.revertedValue()
      _ = FocusedTextFieldEditor.apply(
        to: element,
        state: LiveTextInsertionState(
          prefix: state.prefix,
          suffix: state.suffix,
          insertedText: ""
        ),
        value: restored,
        cursorLocation: state.revertedCursorLocation
      )
      liveTextInsertionLogger.notice("Live text insertion reverted mode=accessibility")

    case .keystroke(let bundleID):
      let revertCount = insertedText.count
      pasteboard.activateApplication(bundleIdentifier: bundleID)
      if revertCount > 0 {
        await pasteboard.selectBackwardAndDeleteForRevert(count: revertCount)
      }
      liveTextInsertionLogger.notice("Live text insertion reverted mode=keystroke")
    }

    resetSession()
  }

  @MainActor
  func isActive() -> Bool {
    session != nil
  }

  @MainActor
  private func resetSession() {
    keystrokeUpdateChain?.cancel()
    keystrokeUpdateChain = nil
    keystrokeUpdateGeneration &+= 1
    isKeystrokeUpdateInFlight = false
    session = nil
    insertedText = ""
    pendingKeystrokeText = nil
  }
}

private struct CapturedTextField {
  let element: AXUIElement
  let bundleID: String?
  let state: LiveTextInsertionState
}

@MainActor
private enum FocusedTextFieldEditor {
  private static let editableRoles: Set<String> = [
    kAXTextFieldRole as String,
    kAXTextAreaRole as String,
    kAXComboBoxRole as String,
    "AXSearchField",
    "AXWebArea",
  ]

  static func captureFromFrontmostApp(
    excludingBundleIdentifiers: Set<String>
  ) -> CapturedTextField? {
    if let systemWide = captureSystemWideFocusedElement(excludingBundleIdentifiers: excludingBundleIdentifiers) {
      return systemWide
    }

    if let frontmost = NSWorkspace.shared.frontmostApplication,
       let bundleID = frontmost.bundleIdentifier,
       !excludingBundleIdentifiers.contains(bundleID),
       let captured = capture(in: frontmost.processIdentifier, bundleID: bundleID)
    {
      return captured
    }

    for app in NSWorkspace.shared.runningApplications where app.isActive {
      guard let bundleID = app.bundleIdentifier,
            !excludingBundleIdentifiers.contains(bundleID),
            let captured = capture(in: app.processIdentifier, bundleID: bundleID)
      else { continue }
      return captured
    }

    return nil
  }

  static func captureSelectedTextElement(
    excludingBundleIdentifiers: Set<String>
  ) -> CapturedTextField? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var focusedElementRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedElementRef
    ) == .success,
      let focusedElementRef
    else {
      return nil
    }

    let element = focusedElementRef as! AXUIElement
    guard let pid = processID(of: element),
          let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
          !excludingBundleIdentifiers.contains(bundleID),
          canSetSelectedText(on: element)
    else {
      return nil
    }

    return CapturedTextField(
      element: element,
      bundleID: bundleID,
      state: LiveTextInsertionState(prefix: "", suffix: "")
    )
  }

  private static func captureSystemWideFocusedElement(
    excludingBundleIdentifiers: Set<String>
  ) -> CapturedTextField? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var focusedElementRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedElementRef
    ) == .success,
      let focusedElementRef
    else {
      return nil
    }

    let element = focusedElementRef as! AXUIElement
    guard let pid = processID(of: element),
          let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
          !excludingBundleIdentifiers.contains(bundleID),
          let state = captureState(from: element)
    else {
      return nil
    }

    return CapturedTextField(element: element, bundleID: bundleID, state: state)
  }

  private static func capture(in processID: pid_t, bundleID: String) -> CapturedTextField? {
    let appElement = AXUIElementCreateApplication(processID)

    if let focused = focusedElement(in: appElement),
       let state = captureState(from: focused)
    {
      return CapturedTextField(element: focused, bundleID: bundleID, state: state)
    }

    if let window = focusedWindow(in: appElement),
       let editable = findEditableElement(in: window),
       let state = captureState(from: editable)
    {
      return CapturedTextField(element: editable, bundleID: bundleID, state: state)
    }

    return nil
  }

  private static func captureState(from element: AXUIElement) -> LiveTextInsertionState? {
    guard elementSupportsTextEditing(element) else { return nil }

    if let fullValue = readValue(from: element),
       let selection = readSelectedRange(from: element),
       let initialState = LiveTextInsertionLogic.snapshot(
         fullValue: fullValue,
         selectionLocation: selection.location,
         selectionLength: selection.length
       )
    {
      return initialState
    }

    if readSelectedRange(from: element) != nil || canSetSelectedText(on: element) {
      return LiveTextInsertionState(prefix: "", suffix: "")
    }

    return nil
  }

  static func apply(
    to element: AXUIElement,
    state: LiveTextInsertionState,
    value: String,
    cursorLocation: Int? = nil,
    previousInsertedLength: Int = 0
  ) -> Bool {
    guard elementSupportsTextEditing(element) else { return false }

    let targetCursor = cursorLocation ?? state.cursorLocation
    let insertionStart = max(0, targetCursor - state.insertedText.count)

    if previousInsertedLength > 0 {
      let replaceRange = CFRange(location: insertionStart, length: previousInsertedLength)
      guard setSelectedRange(replaceRange, on: element) else { return false }
      guard AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextAttribute as CFString,
        state.insertedText as CFString
      ) == .success else {
        return false
      }
      return setSelectedRange(CFRange(location: targetCursor, length: 0), on: element)
    }

    if let selection = readSelectedRange(from: element) {
      let replaceRange = CFRange(location: selection.location, length: selection.length)
      if setSelectedRange(replaceRange, on: element),
         AXUIElementSetAttributeValue(
           element,
           kAXSelectedTextAttribute as CFString,
           state.insertedText as CFString
         ) == .success
      {
        return setSelectedRange(
          CFRange(location: selection.location + state.insertedText.count, length: 0),
          on: element
        )
      }
    }

    if setValue(value, on: element) {
      return setSelectedRange(CFRange(location: targetCursor, length: 0), on: element)
    }

    let fallbackRange = CFRange(
      location: readSelectedRange(from: element)?.location ?? 0,
      length: 0
    )
    guard setSelectedRange(fallbackRange, on: element) else { return false }
    return AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      state.insertedText as CFString
    ) == .success
  }

  private static func focusedElement(in appElement: AXUIElement) -> AXUIElement? {
    var focusedElementRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedElementRef
    ) == .success,
      let focusedElementRef
    else {
      return nil
    }
    return (focusedElementRef as! AXUIElement)
  }

  private static func focusedWindow(in appElement: AXUIElement) -> AXUIElement? {
    var windowRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedWindowAttribute as CFString,
      &windowRef
    ) == .success,
      let windowRef
    else {
      return nil
    }
    return (windowRef as! AXUIElement)
  }

  private static func findEditableElement(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth <= 12 else { return nil }

    if elementSupportsTextEditing(root), captureState(from: root) != nil {
      return root
    }

    guard let children = childElements(of: root) else { return nil }

    for child in children {
      if editableRoles.contains(role(of: child) ?? ""),
         elementSupportsTextEditing(child),
         captureState(from: child) != nil
      {
        return child
      }
    }

    for child in children {
      if let match = findEditableElement(in: child, depth: depth + 1) {
        return match
      }
    }

    return nil
  }

  private static func childElements(of element: AXUIElement) -> [AXUIElement]? {
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement]
    else {
      return nil
    }
    return children
  }

  private static func role(of element: AXUIElement) -> String? {
    var roleRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
      return nil
    }
    return roleRef as? String
  }

  private static func processID(of element: AXUIElement) -> pid_t? {
    var pid = pid_t(0)
    guard AXUIElementGetPid(element, &pid) == .success else { return nil }
    return pid
  }

  private static func canSetSelectedText(on element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
      && settable.boolValue
  }

  private static func elementSupportsTextEditing(_ element: AXUIElement) -> Bool {
    if copyBoolAttribute(element, "AXEditableText" as CFString) == true {
      return true
    }

    if canSetSelectedText(on: element) {
      return true
    }

    var value: CFTypeRef?
    let supportsText = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
    let supportsSelectedText = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
    if supportsText || supportsSelectedText {
      return true
    }

    if let role = role(of: element), editableRoles.contains(role) {
      return true
    }

    return false
  }

  private static func copyBoolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success else {
      return nil
    }
    if let boolValue = valueRef as? Bool {
      return boolValue
    }
    if let number = valueRef as? NSNumber {
      return number.boolValue
    }
    return nil
  }

  private static func readValue(from element: AXUIElement) -> String? {
    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success else {
      return nil
    }

    if let string = valueRef as? String {
      return string
    }
    if let attributed = valueRef as? NSAttributedString {
      return attributed.string
    }
    return nil
  }

  private static func readSelectedRange(from element: AXUIElement) -> CFRange? {
    var rangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue,
          CFGetTypeID(rangeValue) == AXValueGetTypeID()
    else {
      return nil
    }

    let axValue = rangeValue as! AXValue
    guard AXValueGetType(axValue) == .cfRange else { return nil }

    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }

  private static func setValue(_ value: String, on element: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success
  }

  private static func setSelectedRange(_ range: CFRange, on element: AXUIElement) -> Bool {
    var mutableRange = range
    guard let axRange = AXValueCreate(AXValueType.cfRange, &mutableRange) else { return false }
    return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success
  }
}
