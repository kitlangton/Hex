import ComposableArchitecture
import HexCore
import SwiftUI

struct RecordingView: View {
  let store: StoreOf<IOSTranscriptionFeature>
  let micPermission: PermissionStatus
  let onRequestMic: () -> Void

  var body: some View {
    NavigationStack {
      ZStack {
        Color(.systemGroupedBackground)
          .ignoresSafeArea()

        VStack(spacing: 32) {
          Spacer()

          // Status text
          statusLabel

          // Record button
          recordButton

          // Model status
          modelStatusView

          Spacer()
        }
        .padding()

        // Transcription result overlay
        if store.lastTranscriptionResult != nil || store.transcriptionError != nil {
          TranscriptionResultView(store: store)
        }
      }
      .navigationTitle("Hex")
      .navigationBarTitleDisplayMode(.inline)
      .task { store.send(.task) }
    }
  }

  @ViewBuilder
  private var statusLabel: some View {
    Group {
      if micPermission == .denied {
        Label("Microphone access denied", systemImage: "mic.slash")
          .foregroundStyle(.red)
      } else if micPermission == .notDetermined {
        Button(action: onRequestMic) {
          Label("Tap to allow microphone", systemImage: "mic.badge.plus")
        }
        .buttonStyle(.bordered)
      } else if !store.modelBootstrapState.isModelReady {
        if store.modelBootstrapState.progress > 0 && store.modelBootstrapState.progress < 1 {
          VStack(spacing: 8) {
            Text("Downloading model...")
              .foregroundStyle(.secondary)
            ProgressView(value: store.modelBootstrapState.progress)
              .frame(maxWidth: 200)
          }
        } else {
          Text("Model not ready")
            .foregroundStyle(.secondary)
        }
      } else if store.isTranscribing {
        HStack(spacing: 8) {
          ProgressView()
          Text("Transcribing...")
        }
        .foregroundStyle(.secondary)
      } else if store.isRecording {
        Text("Recording...")
          .foregroundStyle(.red)
          .font(.headline)
      } else {
        Text("Hold to record")
          .foregroundStyle(.secondary)
      }
    }
    .font(.body)
    .animation(.default, value: store.isRecording)
  }

  @ViewBuilder
  private var recordButton: some View {
    let isEnabled = micPermission == .granted
      && store.modelBootstrapState.isModelReady
      && !store.isTranscribing

    ZStack {
      // Audio level ring
      if store.isRecording {
        Circle()
          .stroke(Color.red.opacity(0.3), lineWidth: 4)
          .scaleEffect(1.0 + CGFloat(store.meter.peakPower) * 0.5)
          .animation(.easeOut(duration: 0.1), value: store.meter.peakPower)
          .frame(width: 160, height: 160)
      }

      Circle()
        .fill(store.isRecording ? Color.red : Color.accentColor)
        .frame(width: 120, height: 120)
        .scaleEffect(store.isRecording ? 1.15 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: store.isRecording)
        .shadow(color: (store.isRecording ? Color.red : Color.accentColor).opacity(0.3), radius: 12)

      Image(systemName: "mic.fill")
        .font(.system(size: 40))
        .foregroundStyle(.white)
    }
    .opacity(isEnabled ? 1.0 : 0.4)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          if !store.isRecording && isEnabled {
            store.send(.startRecording)
          }
        }
        .onEnded { _ in
          if store.isRecording {
            store.send(.stopRecording)
          }
        }
    )
    .accessibilityLabel(store.isRecording ? "Stop recording" : "Hold to record")
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private var modelStatusView: some View {
    if let name = store.modelBootstrapState.modelDisplayName {
      Text(name)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}
