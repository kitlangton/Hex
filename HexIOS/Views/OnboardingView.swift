//
//  OnboardingView.swift
//  HexIOS
//
//  First-run setup (locked design §6, issue X-1). Progressive: shows ONE step at
//  a time (so it's not overwhelming) and auto-advances as each completes. All
//  three steps are live-detected:
//   • Keyboard — confirmed when the keyboard runs with Full Access (it posts an
//     .keyboardActive signal + an App Group flag, which it can only do with Full
//     Access). A confirm field lets the user prove it instantly.
//   • Microphone — AVAudioApplication.recordPermission.
//   • Model — DictationModel.modelState / progress.
//
//  Monochrome surfaces + the single iOS-blue accent (Color.accentColor).
//

import AVFoundation
import HexCore
import SwiftData
import SwiftUI
import UIKit

/// First-run onboarding persistence (shared App Group, consistent with the rest
/// of Hex's cross-process state).
enum OnboardingState {
    static let didOnboardKey = "hex.didOnboard"
    static let store = UserDefaults(suiteName: HexAppGroup.identifier) ?? .standard
}

struct OnboardingView: View {
    let model: DictationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var micPermission = AVAudioApplication.shared.recordPermission
    @State private var keyboardReady = KeyboardPresence.lastActive(appGroupIdentifier: HexAppGroup.identifier) != nil
    @State private var confirmText = ""

    private enum Step: Int, CaseIterable { case keyboard, microphone, model }

    private var micGranted: Bool { micPermission == .granted }
    private var modelReady: Bool { model.modelState == .ready }

    private func isComplete(_ step: Step) -> Bool {
        switch step {
        case .keyboard: keyboardReady
        case .microphone: micGranted
        case .model: modelReady
        }
    }

    /// The first incomplete step, or nil when everything's done.
    private var currentStep: Step? { Step.allCases.first { !isComplete($0) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                header
                progressDots
                Spacer(minLength: 0)
                Group {
                    if let step = currentStep {
                        stepCard(step)
                    } else {
                        allSetCard
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            .animation(.snappy, value: currentStep)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Skip") { dismiss() } } }
        }
        .task { await model.prepare() }
        .task { await observeKeyboardActive() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            micPermission = AVAudioApplication.shared.recordPermission
            if !keyboardReady {
                keyboardReady = KeyboardPresence.lastActive(appGroupIdentifier: HexAppGroup.identifier) != nil
            }
        }
    }

    /// Live confirmation: the keyboard posts `.keyboardActive` the moment it runs
    /// with Full Access (e.g. when the user switches to it in the confirm field).
    private func observeKeyboardActive() async {
        let observer = DarwinSignalObserver([.keyboardActive])
        for await _ in observer.stream() { keyboardReady = true }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Color.accentColor, in: .circle)
            Text("Welcome to Hex")
                .font(.title2.weight(.bold))
        }
        .padding(.top, 8)
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(isComplete(step) ? Color.accentColor : Color(.tertiarySystemFill))
                    .frame(width: isComplete(step) ? 22 : 8, height: 8)
            }
        }
        .animation(.snappy, value: keyboardReady)
        .animation(.snappy, value: micGranted)
        .animation(.snappy, value: modelReady)
    }

    // MARK: - Step card

    @ViewBuilder
    private func stepCard(_ step: Step) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon(step))
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title(step)).font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text(detail(step))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions(step)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private func icon(_ step: Step) -> String {
        switch step {
        case .keyboard: "keyboard"
        case .microphone: "mic.fill"
        case .model: "arrow.down.circle"
        }
    }

    private func title(_ step: Step) -> String {
        switch step {
        case .keyboard: "Set up the Hex keyboard"
        case .microphone: "Allow microphone access"
        case .model: "Download the model"
        }
    }

    private func detail(_ step: Step) -> String {
        switch step {
        case .keyboard:
            "In Settings ▸ Keyboards, add Hex and turn on Allow Full Access. Then tap the box below and switch to the Hex keyboard (🌐) — it'll confirm here automatically."
        case .microphone:
            switch micPermission {
            case .denied: "Access was denied. Enable it in Settings to dictate."
            default: "Hex transcribes entirely on-device — your audio never leaves the phone."
            }
        case .model:
            switch model.modelState {
            case .loading:
                model.modelProgress > 0
                    ? "Downloading… \(Int(model.modelProgress * 100))%"
                    : "First run downloads the model (~600MB+). This happens in the background."
            case .ready: "\(model.modelName) is ready."
            case .failed(let message): "Download failed: \(message)"
            }
        }
    }

    @ViewBuilder
    private func actions(_ step: Step) -> some View {
        switch step {
        case .keyboard:
            VStack(spacing: 10) {
                openSettingsButton("Open Keyboard Settings")
                TextField("Tap here, then switch to the Hex keyboard", text: $confirmText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        case .microphone:
            switch micPermission {
            case .undetermined:
                Button("Allow microphone") {
                    AVAudioApplication.requestRecordPermission { _ in
                        Task { @MainActor in micPermission = AVAudioApplication.shared.recordPermission }
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.accentColor)
            case .denied:
                openSettingsButton("Open Settings")
            default:
                EmptyView()
            }
        case .model:
            switch model.modelState {
            case .loading:
                if model.modelProgress > 0 {
                    ProgressView(value: model.modelProgress).frame(maxWidth: 200)
                } else {
                    ProgressView()
                }
            case .failed:
                Button("Retry") { Task { await model.prepare() } }
                    .buttonStyle(.bordered).controlSize(.large)
            case .ready:
                EmptyView()
            }
        }
    }

    // MARK: - Done

    private var allSetCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("You're all set").font(.title2.weight(.bold))
            Text("Dictate a note from Home, or switch to the Hex keyboard in any app and start a session.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("Start dictating").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(.accentColor)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private func openSettingsButton(_ label: String) -> some View {
        Button(label) {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .buttonStyle(.bordered).controlSize(.large)
    }
}

#Preview {
    let container = try! ModelContainer(
        for: TranscriptEntry.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return OnboardingView(model: DictationModel(modelContext: container.mainContext))
}
