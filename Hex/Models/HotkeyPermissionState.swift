import ComposableArchitecture
import Foundation
import HexCore

struct HotkeyPermissionState: Codable, Equatable {
  var accessibility: PermissionStatus = .notDetermined
  var inputMonitoring: PermissionStatus = .notDetermined
  var lastUpdated: Date = .distantPast
}

extension SharedReaderKey where Self == InMemoryKey<HotkeyPermissionState>.Default {
  static var hotkeyPermissionState: Self {
    Self[
      .inMemory("hotkeyPermissionState"),
      default: .init()
    ]
  }
}
