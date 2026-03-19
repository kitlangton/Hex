import Foundation

/// Detects terminal applications that don't support Cmd+Z undo for text input.
public enum TerminalAppDetector {

	private static let terminalBundleIDs: Set<String> = [
		"com.apple.Terminal",
		"com.googlecode.iterm2",
		"io.alacritty",
		"net.kovidgoyal.kitty",
		"dev.warp.Warp-Stable",
		"dev.warp.Warp",
		"co.zeit.hyper",
		"com.github.wez.wezterm",
		"com.raggesilver.BlackBox",
		"org.tabby",
	]

	public static func isTerminal(_ bundleID: String?) -> Bool {
		guard let bundleID else { return false }
		return terminalBundleIDs.contains(bundleID)
	}
}
