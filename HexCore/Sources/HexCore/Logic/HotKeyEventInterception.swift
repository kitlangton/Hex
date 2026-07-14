public enum HotKeyEventInterception {
	public static func shouldIntercept(
		output: HotKeyProcessor.Output?,
		keyEvent: KeyEvent,
		hotkey: HotKey,
		useDoubleTapOnly: Bool
	) -> Bool {
		switch output {
		case .startRecording:
			return useDoubleTapOnly || keyEvent.key != nil
		case .stopRecording:
			// A locked recording stops on key-down. Consume the matching hotkey so
			// it is not inserted into the destination app, but preserve unrelated
			// keys that can also stop a short accidental recording.
			return hotkey.matches(keyEvent)
		case .cancel:
			return true
		case .discard:
			return false
		case nil:
			return keyEvent.key != nil && hotkey.matches(keyEvent)
		}
	}
}
