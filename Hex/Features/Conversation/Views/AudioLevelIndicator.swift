//
//  AudioLevelIndicator.swift
//  Hex
//
//  Reusable audio level visualization component for conversation mode.
//

import Inject
import SwiftUI

/// A reusable audio level indicator with animated visualization.
///
/// Displays an icon with a pulsing circular background that responds to audio levels.
struct AudioLevelIndicator: View {
    @ObserveInjection var inject

    /// The current audio level (0.0 to 1.0)
    let level: Float
    /// SF Symbol name for the icon
    let icon: String
    /// Primary color for the indicator
    let color: Color
    /// Optional label text below the indicator
    let label: String?
    /// Size of the indicator circle
    var size: CGFloat = 44

    init(
        level: Float,
        icon: String,
        color: Color,
        label: String? = nil,
        size: CGFloat = 44
    ) {
        self.level = level
        self.icon = icon
        self.color = color
        self.label = label
        self.size = size
    }

    private var normalizedLevel: Float {
        min(1, max(0, level))
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Base circle (background)
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: size, height: size)

                // Inner pulse circle (level-reactive)
                Circle()
                    .fill(color.opacity(Double(normalizedLevel * 0.6)))
                    .frame(
                        width: size * CGFloat(0.5 + normalizedLevel * 0.5),
                        height: size * CGFloat(0.5 + normalizedLevel * 0.5)
                    )

                // Outer glow ring (level-reactive)
                Circle()
                    .stroke(color.opacity(Double(normalizedLevel * 0.4)), lineWidth: 2)
                    .frame(
                        width: size * CGFloat(0.7 + normalizedLevel * 0.3),
                        height: size * CGFloat(0.7 + normalizedLevel * 0.3)
                    )
                    .blur(radius: 1)

                // Icon
                Image(systemName: icon)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(color)
            }
            .animation(.easeOut(duration: 0.1), value: level)

            if let label {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .enableInjection()
    }
}

// MARK: - Compact Variant

/// A compact inline audio level indicator without label
struct CompactAudioLevelIndicator: View {
    @ObserveInjection var inject

    let level: Float
    let color: Color
    var barCount: Int = 4
    var spacing: CGFloat = 2
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 16

    private var normalizedLevel: Float {
        min(1, max(0, level))
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let threshold = Float(index) / Float(barCount)
                let isActive = normalizedLevel > threshold
                let barHeight = maxHeight * CGFloat(0.3 + 0.7 * (Float(index + 1) / Float(barCount)))

                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(isActive ? color : color.opacity(0.2))
                    .frame(width: barWidth, height: barHeight)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .enableInjection()
    }
}

// MARK: - Waveform Variant

/// A waveform-style audio level indicator
struct WaveformAudioLevelIndicator: View {
    @ObserveInjection var inject

    let level: Float
    let color: Color
    var barCount: Int = 5
    var spacing: CGFloat = 2
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 20

    @State private var animationPhase: CGFloat = 0

    private var normalizedLevel: Float {
        min(1, max(0, level))
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let phase = sin(animationPhase + CGFloat(index) * 0.8)
                let heightMultiplier = 0.3 + 0.7 * Double(normalizedLevel) * (0.5 + 0.5 * phase)

                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color)
                    .frame(width: barWidth, height: maxHeight * heightMultiplier)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .task {
            while !Task.isCancelled {
                withAnimation(.linear(duration: 0.1)) {
                    animationPhase += 0.3
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        .enableInjection()
    }
}

// MARK: - Previews

#Preview("Audio Level Indicators") {
    VStack(spacing: 24) {
        // Standard indicators
        HStack(spacing: 24) {
            AudioLevelIndicator(
                level: 0.0,
                icon: "mic.fill",
                color: .blue,
                label: "Silent"
            )

            AudioLevelIndicator(
                level: 0.3,
                icon: "mic.fill",
                color: .blue,
                label: "Low"
            )

            AudioLevelIndicator(
                level: 0.7,
                icon: "mic.fill",
                color: .blue,
                label: "Medium"
            )

            AudioLevelIndicator(
                level: 1.0,
                icon: "mic.fill",
                color: .blue,
                label: "High"
            )
        }

        Divider()

        // Speaker indicators
        HStack(spacing: 24) {
            AudioLevelIndicator(
                level: 0.2,
                icon: "speaker.wave.2.fill",
                color: .green,
                label: "Output"
            )

            AudioLevelIndicator(
                level: 0.6,
                icon: "speaker.wave.2.fill",
                color: .green,
                label: "Speaking"
            )
        }

        Divider()

        // Compact indicators
        HStack(spacing: 16) {
            CompactAudioLevelIndicator(level: 0.2, color: .blue)
            CompactAudioLevelIndicator(level: 0.5, color: .blue)
            CompactAudioLevelIndicator(level: 0.8, color: .blue)
        }

        Divider()

        // Waveform indicators
        HStack(spacing: 16) {
            WaveformAudioLevelIndicator(level: 0.3, color: .green)
            WaveformAudioLevelIndicator(level: 0.7, color: .green)
        }
    }
    .padding(40)
}

#Preview("Live Demo") {
    LiveAudioLevelDemo()
}

private struct LiveAudioLevelDemo: View {
    @State private var inputLevel: Float = 0
    @State private var outputLevel: Float = 0

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 32) {
                AudioLevelIndicator(
                    level: inputLevel,
                    icon: "mic.fill",
                    color: .blue,
                    label: "Listening"
                )

                AudioLevelIndicator(
                    level: outputLevel,
                    icon: "speaker.wave.2.fill",
                    color: .green,
                    label: "Speaking"
                )
            }

            Divider()

            VStack(spacing: 8) {
                HStack {
                    Text("Input Level")
                    Slider(value: Binding(
                        get: { Double(inputLevel) },
                        set: { inputLevel = Float($0) }
                    ), in: 0...1)
                }

                HStack {
                    Text("Output Level")
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
            // Simulate random audio levels
            while !Task.isCancelled {
                inputLevel = Float.random(in: 0...0.6)
                outputLevel = Float.random(in: 0...0.4)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}
