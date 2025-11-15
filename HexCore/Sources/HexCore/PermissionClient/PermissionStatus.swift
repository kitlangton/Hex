/// Represents the authorization status for a system permission
public enum PermissionStatus: Equatable, Codable, Sendable {
  /// Permission has not been requested yet
  case notDetermined

  /// Permission has been granted by the user
  case granted

  /// Permission has been denied or restricted by the user
  case denied
}
