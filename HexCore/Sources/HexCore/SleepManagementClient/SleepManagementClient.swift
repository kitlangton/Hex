import Dependencies
import DependenciesMacros

/// Client for managing system sleep prevention during critical operations.
///
/// On macOS, this uses IOKit power assertions to prevent the display from sleeping
/// while operations like voice recording are in progress.
///
/// The client manages assertion lifecycle internally - calling `preventSleep` multiple times
/// will automatically release any previous assertion before creating a new one.
///
/// ## Usage
///
/// ```swift
/// @Dependency(\.sleepManagement) var sleepManagement
///
/// // Prevent sleep during recording
/// await sleepManagement.preventSleep(reason: "Voice Recording")
/// // Recording in progress...
/// await sleepManagement.allowSleep()
/// ```
@DependencyClient
public struct SleepManagementClient: Sendable {
  /// Prevent the system from sleeping.
  ///
  /// If sleep is already being prevented, this will release the old assertion
  /// and create a new one with the updated reason.
  ///
  /// - Parameter reason: A human-readable string describing why sleep is being prevented
  public var preventSleep: @Sendable (_ reason: String) async -> Void = { _ in }

  /// Allow the system to sleep again by releasing any active assertion.
  ///
  /// Safe to call even if no assertion is active.
  public var allowSleep: @Sendable () async -> Void = {}
}

extension DependencyValues {
  /// Access the sleep management client dependency.
  public var sleepManagement: SleepManagementClient {
    get { self[SleepManagementClient.self] }
    set { self[SleepManagementClient.self] = newValue }
  }
}
