//
//  ContentView.swift
//  HexIOS
//
//  Root tab bar (locked design §2): Home / History / Settings. On iOS 26 this
//  renders as the floating pill tab bar automatically. Owns model lifecycle
//  (prepare) and the global error alert.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    let model: DictationModel

    /// First-run flag (stored in the shared App Group so the keyboard can read it
    /// later if needed). When false, onboarding is presented full-screen.
    @AppStorage(OnboardingState.didOnboardKey, store: OnboardingState.store)
    private var didOnboard = false
    @State private var showOnboarding = false

    var body: some View {
        TabView {
            HomeView(model: model)
                .tabItem { Label("Home", systemImage: "mic") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }

            SettingsView(model: model, showOnboarding: $showOnboarding)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.accentColor)
        .task { await model.prepare() }
        .onAppear { if !didOnboard { showOnboarding = true } }
        .fullScreenCover(isPresented: $showOnboarding, onDismiss: { didOnboard = true }) {
            OnboardingView(model: model)
        }
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
    let container = try! ModelContainer(
        for: TranscriptEntry.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ContentView(model: DictationModel(modelContext: container.mainContext))
        .modelContainer(container)
}
