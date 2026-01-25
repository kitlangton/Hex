//
//  ConversationIndicatorView.swift
//  Hex
//
//  Overlay indicator for conversation mode showing bidirectional audio activity.
//

import Inject
import Pow
import SwiftUI

/// An overlay indicator for conversation mode that displays:
/// - Current conversation state
/// - Input (microphone) audio level
/// - Output (speaker) audio level
struct ConversationIndicatorView: View {
    @ObserveInjection var inject

    /// Current state of the conversation session
    let state: ConversationSessionState
    /// Current input audio level (0.0 to 1.0)
    let inputLevel: Float
    /// Current output audio level (0.0 to 1.0)
    let outputLevel: Float

    /// Animation trigger for state changes
    @State private var stateChangeEffect = 0
    /// Animation trigger for shimmer effect during active state
    @State private var shimmerEffect = 0

    private var isHidden: Bool {
        if case .idle = state { return true }
        return false
    }

    private var backgroundColor: Color {
        switch state {
        case .idle:
            return .clear
        case .loading:
            return .blue.mix(with: .black, by: 0.5)
        case .ready:
            return .green.mix(with: .black, by: 0.5)
        case .active(let speaking, let listening):
            if speaking {
                return .green.mix(with: .black, by: 0.4).mix(with: .green, by: CGFloat(outputLevel) * 0.5)
            } else if listening {
                return .blue.mix(with: .black, by: 0.4).mix(with: .blue, by: CGFloat(inputLevel) * 0.5)
            }
            return .purple.mix(with: .black, by: 0.5)
        case .error:
            return .red.mix(with: .black, by: 0.5)
        }
    }

    private var strokeColor: Color {
        switch state {
        case .idle:
            return .clear
        case .loading, .ready:
            return .blue.mix(with: .white, by: 0.1).opacity(0.6)
        case .active(let speaking, _):
            return (speaking ? Color.green : Color.blue).mix(with: .white, by: 0.1).opacity(0.6)
        case .error:
            return .red.mix(with: .white, by: 0.1).opacity(0.6)
        }
    }

    private var innerShadowColor: Color {
        switch state {
        case .idle:
            return .clear
        case .loading, .ready:
            return .blue
        case .active(let speaking, _):
            return speaking ? .green : .blue
        case .error:
            return .red
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Main indicator capsule
            mainIndicator

            // State text
            if !isHidden {
                stateText
                    .transition(.opacity)
            }
        }
        .animation(.bouncy(duration: 0.3), value: state)
        .opacity(isHidden ? 0 : 1)
        .scaleEffect(isHidden ? 0.8 : 1)
        .blur(radius: isHidden ? 4 : 0)
        .enableInjection()
    }

    @ViewBuilder
    private var mainIndicator: some View {
        HStack(spacing: 16) {
            // Input (microphone) indicator
            AudioLevelIndicator(
                level: inputLevel,
                icon: "mic.fill",
                color: .blue,
                label: "Listening",
                size: 40
            )
            .opacity(state.isActive ? 1 : 0.5)

            // Divider
            if state.isActive {
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 30)
            }

            // Output (speaker) indicator
            AudioLevelIndicator(
                level: outputLevel,
                icon: "speaker.wave.2.fill",
                color: .green,
                label: "Speaking",
                size: 40
            )
            .opacity(state.isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(backgroundColor.shadow(.inner(color: innerShadowColor, radius: 4)))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(strokeColor, lineWidth: 1)
                        .blendMode(.screen)
                }
        }
        .shadow(
            color: innerShadowColor.opacity(0.3),
            radius: 8
        )
        .changeEffect(.glow(color: innerShadowColor.opacity(0.5), radius: 8), value: stateChangeEffect)
        .changeEffect(.shine(angle: .degrees(0), duration: 0.6), value: shimmerEffect)
        .compositingGroup()
        .task(id: state.isActive) {
            stateChangeEffect += 1
            while state.isActive, !Task.isCancelled {
                shimmerEffect += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var stateText: some View {
        switch state {
        case .idle:
            EmptyView()

        case .loading(let progress):
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                Text("Loading model... \(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())

        case .active(let speaking, let listening):
            HStack(spacing: 6) {
                if listening {
                    Image(systemName: "ear.fill")
                        .foregroundStyle(.blue)
                }
                if speaking {
                    Image(systemName: "waveform")
                        .foregroundStyle(.green)
                }
                Text(speaking && listening ? "Conversing" : speaking ? "Speaking" : "Listening")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .lineLimit(1)
        }
    }
}

// MARK: - Compact Variant

/// A compact conversation indicator for menu bar or small spaces
struct CompactConversationIndicatorView: View {
    @ObserveInjection var inject

    let state: ConversationSessionState
    let inputLevel: Float
    let outputLevel: Float

    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            statusIcon
                .frame(width: 16, height: 16)

            // Audio level bars
            if state.isActive {
                HStack(spacing: 4) {
                    CompactAudioLevelIndicator(level: inputLevel, color: .blue, barCount: 3)
                    CompactAudioLevelIndicator(level: outputLevel, color: .green, barCount: 3)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(state.isActive ? Color.black.opacity(0.3) : Color.clear)
        )
        .animation(.easeOut(duration: 0.2), value: state.isActive)
        .enableInjection()
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .idle:
            Image(systemName: "person.wave.2")
                .foregroundStyle(.secondary)
        case .loading:
            ProgressView()
                .scaleEffect(0.5)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .active(let speaking, let listening):
            if speaking {
                Image(systemName: "waveform")
                    .foregroundStyle(.green)
            } else if listening {
                Image(systemName: "ear.fill")
                    .foregroundStyle(.blue)
            } else {
                Image(systemName: "person.wave.2.fill")
                    .foregroundStyle(.purple)
            }
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Previews

#Preview("Conversation Indicator States") {
    VStack(spacing: 24) {
        ConversationIndicatorView(
            state: .idle,
            inputLevel: 0,
            outputLevel: 0
        )

        ConversationIndicatorView(
            state: .loading(progress: 0.45),
            inputLevel: 0,
            outputLevel: 0
        )

        ConversationIndicatorView(
            state: .ready,
            inputLevel: 0,
            outputLevel: 0
        )

        ConversationIndicatorView(
            state: .active(speaking: false, listening: true),
            inputLevel: 0.6,
            outputLevel: 0
        )

        ConversationIndicatorView(
            state: .active(speaking: true, listening: true),
            inputLevel: 0.3,
            outputLevel: 0.7
        )

        ConversationIndicatorView(
            state: .error("Connection failed"),
            inputLevel: 0,
            outputLevel: 0
        )
    }
    .padding(40)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Compact Indicators") {
    VStack(spacing: 16) {
        CompactConversationIndicatorView(
            state: .idle,
            inputLevel: 0,
            outputLevel: 0
        )

        CompactConversationIndicatorView(
            state: .active(speaking: false, listening: true),
            inputLevel: 0.5,
            outputLevel: 0
        )

        CompactConversationIndicatorView(
            state: .active(speaking: true, listening: true),
            inputLevel: 0.3,
            outputLevel: 0.6
        )
    }
    .padding(20)
}

#Preview("Live Demo") {
    LiveConversationIndicatorDemo()
}

private struct LiveConversationIndicatorDemo: View {
    @State private var state: ConversationSessionState = .idle
    @State private var inputLevel: Float = 0
    @State private var outputLevel: Float = 0

    var body: some View {
        VStack(spacing: 32) {
            ConversationIndicatorView(
                state: state,
                inputLevel: inputLevel,
                outputLevel: outputLevel
            )

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("State").font(.headline)

                HStack(spacing: 8) {
                    Button("Idle") { state = .idle }
                    Button("Loading") { state = .loading(progress: 0.5) }
                    Button("Ready") { state = .ready }
                    Button("Listening") { state = .active(speaking: false, listening: true) }
                    Button("Speaking") { state = .active(speaking: true, listening: false) }
                    Button("Both") { state = .active(speaking: true, listening: true) }
                    Button("Error") { state = .error("Test error") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Input Level")
                        .frame(width: 80, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(inputLevel) },
                        set: { inputLevel = Float($0) }
                    ), in: 0...1)
                }

                HStack {
                    Text("Output Level")
                        .frame(width: 80, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(outputLevel) },
                        set: { outputLevel = Float($0) }
                    ), in: 0...1)
                }
            }
            .frame(width: 300)
        }
        .padding(40)
        .task {
            // Simulate random audio when active
            while !Task.isCancelled {
                if state.isActive {
                    inputLevel = Float.random(in: 0.1...0.7)
                    outputLevel = Float.random(in: 0...0.5)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
