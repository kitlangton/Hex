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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { url in
                    // Keyboard session bounce: hexkb://startSession
                    guard url.scheme == "hexkb", url.host == "startSession" else { return }
                    Task { await model.startKeyboardSession() }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Hands-free entry (App Intent / Action Button / Siri): the
                    // intent opens the app and flags a request; honor it on activation.
                    guard phase == .active, PendingAppAction.consumeStartSession() else { return }
                    Task { await model.startKeyboardSession() }
                }
        }
    }
}
