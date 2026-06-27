//
//  RecordingView.swift
//  HexIOS
//
//  Recording modal (locked design §4.2): presented over Home while capturing an
//  in-app note. Red dot + timer, waveform, accent stop, swipe-up to cancel, then
//  a transient Transcribing state. (Waveform is a lively placeholder for V1; real
//  input metering can replace it later.)
//

import SwiftUI

struct RecordingView: View {
    let model: DictationModel
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 28) {
            Text("New note")
                .font(.headline)
                .foregroundStyle(.secondary)

            if model.phase == .transcribing {
                transcribing
            } else {
                timerPill
                waveform
                stopButton
                Text("Tap to stop · swipe up to cancel")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { v in dragOffset = min(0, v.translation.height) }
                .onEnded { v in
                    if v.translation.height < -80 { model.cancelRecording() }
                    withAnimation(.snappy) { dragOffset = 0 }
                }
        )
    }

    private var timerPill: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(elapsedString).monospacedDigit()
            }
            .font(.title3.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: .capsule)
        }
    }

    private var elapsedString: String {
        let start = model.recordingStartedAt ?? Date()
        let secs = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private var waveform: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 6 + level * 50)
            }
        }
        .frame(height: 56)
        .animation(.linear(duration: 0.05), value: model.levels)
    }

    private var stopButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 78, height: 78)
                .background(Color.accentColor, in: .circle)
        }
    }

    private var transcribing: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Transcribing…").foregroundStyle(.secondary)
        }
    }
}
