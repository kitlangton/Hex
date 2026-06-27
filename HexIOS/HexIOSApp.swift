//
//  HexIOSApp.swift
//  HexIOS
//
//  Created by Conglei Shi on 6/26/26.
//

import SwiftUI

@main
struct HexIOSApp: App {
    @State private var model = DictationModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { url in
                    // Keyboard session bounce: hexkb://startSession
                    guard url.scheme == "hexkb", url.host == "startSession" else { return }
                    Task { await model.startKeyboardSession() }
                }
        }
    }
}
