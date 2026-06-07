import CoreGraphics

/// Tags CGEvents posted by Hex during live text insertion so our event tap ignores them.
/// Untagged synthetic Shift/Cmd events look like hotkey releases for modifier-only bindings.
enum SyntheticKeyboardEvent {
  static let userData: Int64 = 0x48455801

  static func tag(_ event: CGEvent?) {
    event?.setIntegerValueField(.eventSourceUserData, value: userData)
  }

  static func isTagged(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) == userData
  }
}
