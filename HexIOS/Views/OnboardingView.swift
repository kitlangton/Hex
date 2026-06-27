//
//  OnboardingView.swift
//  HexIOS
//
//  First-run setup (locked design §6, issue X-1): an accent mic header over a
//  5-step checklist. Each step reflects real system state where it can —
//  microphone permission and model download are live-detected; adding the
//  keyboard and enabling Full Access are instructional with a Settings deep
//  link, since the host app can't directly observe those from outside its
//  extension. One primary CTA ("Start dictating") dismisses onboarding.
//
//  Monochrome surfaces + the single iOS-blue accent (Color.accentColor) on the
//  mic header and active/CTA elements. Semantic system colors keep light/dark
//  mode automatic.
//

import AVFoundation
import HexCore
import SwiftData
import SwiftUI
import UIKit

/// First-run onboarding persistence. Backed by the shared App Group so the flag
/// is consistent with the rest of Hex's cross-process state.
enum OnboardingState {
    static let didOnboardKey = "hex.didOnboard"
    static let store = UserDefaults(suiteName: HexAppGroup.identifier) ?? .standard
}

struct OnboardingView: View {
    let model: DictationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Live mic permission state. Re-read whenever the app becomes active so
    /// returning from the system Settings app reflects a freshly granted/denied
    /// permission without a relaunch.
    @State private var micPermission = AVAudioApplication.shared.recordPermission

    private var micGranted: Bool { micPermission == .granted }
    private var modelReady: Bool { model.modelState == .ready }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header

                    VStack(spacing: 12) {
                        keyboardStep
                        fullAccessStep
                        microphoneStep
                        modelStep
                        firstDictationStep
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Set up Hex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { dismiss() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from Settings: refresh mic state and make sure the model
            // download is underway so step 4 can show live progress.
            guard phase == .active else { return }
            micPermission = AVAudioApplication.shared.recordPermission
            Task { await model.prepare() }
        }
        .task { await model.prepare() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(Color.accentColor, in: .circle)

            Text("Welcome to Hex")
                .font(.title2.weight(.bold))

            Text("On-device voice-to-text. Five quick steps and you're dictating anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Steps

    private var keyboardStep: some View {
        StepRow(
            index: 1,
            title: "Add the Hex keyboard",
            detail: "Open Settings ▸ Keyboards ▸ Keyboards and turn on Hex.",
            isComplete: false
        ) {
            openSettingsButton(label: "Open Settings")
        }
    }

    private var fullAccessStep: some View {
        StepRow(
            index: 2,
            title: "Allow Full Access",
            detail: "In the Hex keyboard's settings, enable Full Access so it can reach the microphone session and your transcripts.",
            isComplete: false
        ) {
            openSettingsButton(label: "Open Settings")
        }
    }

    private var microphoneStep: some View {
        StepRow(
            index: 3,
            title: "Microphone access",
            detail: micDetail,
            isComplete: micGranted
        ) {
            switch micPermission {
            case .granted:
                EmptyView()
            case .denied:
                openSettingsButton(label: "Open Settings")
            case .undetermined:
                Button("Grant") {
                    AVAudioApplication.requestRecordPermission { _ in
                        Task { @MainActor in
                            micPermission = AVAudioApplication.shared.recordPermission
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            @unknown default:
                openSettingsButton(label: "Open Settings")
            }
        }
    }

    private var micDetail: String {
        switch micPermission {
        case .granted: "Microphone access is granted."
        case .denied: "Access was denied. Enable it in Settings to dictate."
        case .undetermined: "Hex transcribes entirely on-device — audio never leaves your phone."
        @unknown default: "Microphone access is required to dictate."
        }
    }

    private var modelStep: some View {
        StepRow(
            index: 4,
            title: "Download the model",
            detail: modelDetail,
            isComplete: modelReady
        ) {
            switch model.modelState {
            case .loading:
                if model.modelProgress > 0 {
                    ProgressView(value: model.modelProgress)
                        .frame(width: 64)
                } else {
                    ProgressView()
                }
            case .ready:
                EmptyView()
            case .failed:
                Button("Retry") { Task { await model.prepare() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var modelDetail: String {
        switch model.modelState {
        case .loading:
            model.modelProgress > 0
                ? "Downloading… \(Int(model.modelProgress * 100))%"
                : "Preparing the model (first run downloads ~600MB+). This runs in the background."
        case .ready:
            "\(model.modelName) is ready."
        case .failed(let message):
            "Download failed: \(message)"
        }
    }

    private var firstDictationStep: some View {
        VStack(spacing: 14) {
            StepRow(
                index: 5,
                title: "Try your first dictation",
                detail: "Tap the mic on Home to record a note. From the keyboard in another app, start a session, then swipe back and dictate in place.",
                isComplete: false
            ) {
                EmptyView()
            }

            Button {
                dismiss()
            } label: {
                Text("Start dictating")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.accentColor)
        }
    }

    // MARK: - Helpers

    private func openSettingsButton(label: String) -> some View {
        Button(label) {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// A single onboarding row: numbered/checkmark badge, title + detail, and an
/// optional trailing accessory (button, progress, etc.). Monochrome card; the
/// completed badge picks up the accent to signal "done".
private struct StepRow<Accessory: View>: View {
    let index: Int
    let title: String
    let detail: String
    let isComplete: Bool
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            badge

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            accessory()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var badge: some View {
        if isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
        } else {
            Text("\(index)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: .circle)
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: TranscriptEntry.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return OnboardingView(model: DictationModel(modelContext: container.mainContext))
}
