//
//  ContentView.swift
//  HexIOS
//
//  Root tab bar (locked design §2): Home / History / Settings. On iOS 26 this
//  renders as the floating pill tab bar automatically. Owns model lifecycle
//  (prepare) and the global error alert.
//

import SwiftUI

struct ContentView: View {
    let model: DictationModel

    var body: some View {
        TabView {
            HomeView(model: model)
                .tabItem { Label("Home", systemImage: "mic") }

            HistoryView(model: model)
                .tabItem { Label("History", systemImage: "clock") }

            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.accentColor)
        .task { await model.prepare() }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }
}

#Preview {
    ContentView(model: DictationModel())
}
