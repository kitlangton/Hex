//
//  TranscriptDetailView.swift
//  HexIOS
//
//  History item detail (design §12, scoped): the full transcript + a playback
//  bar for the retained raw audio (play/pause, waveform progress, duration).
//  Speaker labels / timecodes / editing are out of scope for now.
//

import SwiftUI

struct TranscriptDetailView: View {
    let entry: TranscriptEntry
    @State private var audio = AudioPlayer()

    private var audioURL: URL? { AudioStore.url(for: entry.audioFilename) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.kind.systemImage)
                        Text(entry.kind.label)
                        if let app = entry.sourceAppName { Text("· \(app)") }
                        Spacer()
                        Text(entry.date, format: .dateTime.month().day().hour().minute())
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text(entry.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }

            if let url = audioURL {
                PlayerBar(audio: audio)
                    .padding()
                    .background(.bar)
                    .task { audio.load(url) }
                    .onDisappear { audio.stop() }
            }
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlayerBar: View {
    let audio: AudioPlayer

    var body: some View {
        HStack(spacing: 14) {
            Button { audio.toggle() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor, in: .circle)
            }

            Waveform(progress: audio.progress) { fraction in audio.seek(toFraction: fraction) }
                .frame(height: 40)

            Text(timeString)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var timeString: String {
        let secs = Int((audio.isPlaying ? audio.currentTime : audio.duration).rounded())
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

/// A simple bar waveform with progress fill; tap/drag to scrub.
private struct Waveform: View {
    let progress: Double
    let onSeek: (Double) -> Void

    private let bars = 40

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0 ..< bars, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / Double(bars) <= progress ? Color.accentColor : Color(.tertiaryLabel))
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(i, max: geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        onSeek(min(max(value.location.x / geo.size.width, 0), 1))
                    }
            )
        }
    }

    // Deterministic pseudo-waveform so it doesn't reshuffle on each render.
    private func barHeight(_ i: Int, max: CGFloat) -> CGFloat {
        let v = (sin(Double(i) * 1.7) + sin(Double(i) * 0.5) + 2) / 4 // 0…1
        return max * (0.25 + 0.75 * v)
    }
}
