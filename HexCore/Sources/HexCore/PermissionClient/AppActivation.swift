/// App lifecycle activation events
public enum AppActivation: Equatable, Sendable {
  /// The app became the active application
  case didBecomeActive

  /// The app will resign active status
  case willResignActive
}
