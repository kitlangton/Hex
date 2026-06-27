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
                    guard url.scheme == "hexkb" else { return }
                    Task {
                        switch url.host {
                        case "startSession": await model.startKeyboardSession()
                        default: await model.beginKeyboardDictation() // one-shot fallback
                        }
                    }
                }
        }
    }
}
