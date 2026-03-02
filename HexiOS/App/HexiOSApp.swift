import ComposableArchitecture
import SwiftUI

@main
struct HexiOSApp: App {
  @State private var store = Store(initialState: IOSAppFeature.State()) {
    IOSAppFeature()
  }

  var body: some Scene {
    WindowGroup {
      MainTabView(store: store)
    }
  }
}
