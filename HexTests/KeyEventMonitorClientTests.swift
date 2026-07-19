import XCTest

@testable import Hex

final class KeyEventMonitorClientTests: XCTestCase {
  func testRegisteringFirstHandlerWhenInputMonitoringIsDeniedDoesNotReenterQueue() {
    let monitor = KeyEventMonitorClientLive(
      accessibilityTrustProvider: { false },
      accessibilityTrustPrompt: { false },
      inputMonitoringTrustProvider: { false }
    )

    let token = monitor.handleKeyEvent { _ in false }

    XCTAssertTrue(monitor.readState { true })
    token.cancel()
  }
}
