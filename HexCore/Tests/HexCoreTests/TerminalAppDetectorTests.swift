import XCTest
@testable import HexCore

final class TerminalAppDetectorTests: XCTestCase {

	func testDetectsAppleTerminal() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("com.apple.Terminal"))
	}

	func testDetectsITerm2() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("com.googlecode.iterm2"))
	}

	func testDetectsAlacritty() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("io.alacritty"))
	}

	func testDetectsKitty() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("net.kovidgoyal.kitty"))
	}

	func testDetectsWarpStable() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("dev.warp.Warp-Stable"))
	}

	func testDetectsWarp() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("dev.warp.Warp"))
	}

	func testDetectsHyper() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("co.zeit.hyper"))
	}

	func testDetectsWezTerm() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("com.github.wez.wezterm"))
	}

	func testDetectsBlackBox() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("com.raggesilver.BlackBox"))
	}

	func testDetectsTabby() {
		XCTAssertTrue(TerminalAppDetector.isTerminal("org.tabby"))
	}

	func testReturnsFalseForSafari() {
		XCTAssertFalse(TerminalAppDetector.isTerminal("com.apple.Safari"))
	}

	func testReturnsFalseForSublimeText() {
		XCTAssertFalse(TerminalAppDetector.isTerminal("com.sublimetext.4"))
	}

	func testReturnsFalseForSlack() {
		XCTAssertFalse(TerminalAppDetector.isTerminal("com.tinyspeck.slackmacgap"))
	}

	func testReturnsFalseForNil() {
		XCTAssertFalse(TerminalAppDetector.isTerminal(nil))
	}

	func testReturnsFalseForEmptyString() {
		XCTAssertFalse(TerminalAppDetector.isTerminal(""))
	}
}
