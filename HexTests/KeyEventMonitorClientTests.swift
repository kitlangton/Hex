import XCTest

@testable import Hex

final class KeyEventMonitorClientTests: XCTestCase {
  func testStartingInputMonitoringWithDeniedPermissionsDoesNotReenterStateQueue() async throws {
    let monitor = KeyEventMonitorClientLive(
      accessibilityTrustCheck: { false },
      accessibilityTrustPrompt: { false },
      inputMonitoringTrustCheck: { false }
    )

    let token = monitor.handleInputEvent { _ in false }
    try await Task.sleep(for: .milliseconds(100))
    token.cancel()
  }
}
