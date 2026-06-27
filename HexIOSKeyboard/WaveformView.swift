//
//  WaveformView.swift
//  HexIOSKeyboard
//
//  A lightweight, purely-decorative waveform shown while capturing. The keyboard
//  extension cannot read live mic levels (the host app holds the mic), so this is
//  a synthesized animation — it only signals "we're listening", never real audio.
//

import SwiftUI

struct WaveformView: View {
    /// When false the bars rest at a calm baseline (no animation churn).
    var isActive: Bool

    private let barCount = 13
    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: isActive ? 1.0 / 30.0 : nil, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    Capsule()
                        .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 4, height: barHeight(index: index, time: t))
                }
            }
            .frame(height: 34)
            .animation(.easeInOut(duration: 0.08), value: t)
        }
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isActive else { return 6 }
        // Each bar gets its own phase + speed so the wave looks organic.
        let speed = 4.0 + Double(index % 4)
        let offset = Double(index) * 0.6
        let wave = sin(time * speed + offset)
        let normalized = (wave + 1) / 2 // 0...1
        return 8 + CGFloat(normalized) * 26
    }
}
