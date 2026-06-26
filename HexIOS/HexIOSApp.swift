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
                    // Keyboard bounce: hexkb://dictate
                    guard url.scheme == "hexkb" else { return }
                    Task { await model.beginKeyboardDictation() }
                }
        }
    }
}
