//
//  HomeView.swift
//  HexIOS
//
//  Home tab. Two ways to make text, sized by how much state each carries:
//  dictation (keyboard, in other apps) is a single bit — on/off — so it lives in
//  a compact header toggle; the in-app "New note" capture is the action you take
//  here, so it's the hero. Monochrome surfaces; the single accent marks whatever
//  is live or tappable. A Recent preview rounds it out (full list lives in History).
//

import SwiftData
import SwiftUI

struct HomeView: View {
    let model: DictationModel
    @Query(sort: \TranscriptEntry.date, order: .reverse) private var entries: [TranscriptEntry]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if let status = statusLine {
                        Text(status.text)
                            .font(.footnote)
                            .foregroundStyle(status.accent ? Color.accentColor : Color.secondary)
                            .padding(.top, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    newNoteHero
                        .padding(.top, 44)
                        .padding(.bottom, 48)

                    if !entries.isEmpty { recentSection }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: Binding(
                get: { model.phase != .idle },
                set: { presented in
                    if !presented && model.phase == .recording { model.cancelRecording() }
                }
            )) {
                RecordingView(model: model)
            }
        }
    }

    // MARK: Header — brand + compact dictation toggle

    private var header: some View {
        HStack {
            Text("Hex")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Dictation", isOn: dictationBinding)
                .toggleStyle(DictationPillToggleStyle())
                .disabled(model.modelState != .ready)
                .opacity(model.modelState == .ready ? 1 : 0.5)
        }
    }

    /// The dictation toggle is the whole Flow Session in one bit: turning it on
    /// starts the continuous keyboard session (then the user swipes back to their
    /// app); turning it off ends it. No timers, no separate "End" button.
    private var dictationBinding: Binding<Bool> {
        Binding(
            get: { model.sessionActive },
            set: { on in
                if on {
                    Task { await model.startKeyboardSession() }
                } else {
                    model.endSession()
                }
            }
        )
    }

    /// One quiet line under the header, by priority: model progress, then the
    /// swipe-back hint while dictation is live, otherwise nothing.
    private var statusLine: (text: String, accent: Bool)? {
        switch model.modelState {
        case .loading:
            return (model.modelProgress > 0
                ? "Downloading model… \(Int(model.modelProgress * 100))%"
                : "Preparing model… first run downloads ~600MB", false)
        case .failed:
            return ("Model unavailable", false)
        case .ready:
            return model.sessionActive
                ? ("Swipe back, then tap the Hex mic to dictate", true)
                : nil
        }
    }

    // MARK: New note — the in-app capture hero

    private var newNoteHero: some View {
        VStack(spacing: 14) {
            Button {
                Task { await model.toggleRecording() }
            } label: {
                Image(systemName: micSymbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(model.phase == .recording ? Color.red : Color.accentColor, in: .circle)
            }
            .disabled(!model.canRecord && model.phase != .recording)

            VStack(spacing: 3) {
                Text("New note").font(.callout.weight(.medium))
                Text(captionText).font(.footnote).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var micSymbol: String {
        switch model.phase {
        case .idle: "mic.fill"
        case .recording: "stop.fill"
        case .transcribing: "ellipsis"
        }
    }

    private var captionText: String {
        switch model.phase {
        case .idle: "Records & saves here"
        case .recording: "Listening… tap to stop"
        case .transcribing: "Transcribing…"
        }
    }

    // MARK: Recent — last few transcripts, kind shown by icon

    private var recentEntries: [TranscriptEntry] { Array(entries.prefix(3)) }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(Array(recentEntries.enumerated()), id: \.element.persistentModelID) { index, entry in
                HStack(spacing: 12) {
                    Image(systemName: entry.kind.systemImage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(entry.text)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(entry.date, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.vertical, 11)

                if index < recentEntries.count - 1 { Divider() }
            }
        }
    }
}

/// Compact pill toggle for dictation: a status dot, the label, and a small
/// switch, tinted with the accent when live. Custom-drawn so it stays small in
/// the header rather than the full-width system switch.
private struct DictationPillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Button {
            withAnimation(.snappy(duration: 0.2)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(on ? Color.accentColor : Color.secondary)
                    .frame(width: 7, height: 7)
                configuration.label
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                miniSwitch(on: on)
            }
            .padding(.vertical, 5)
            .padding(.leading, 11)
            .padding(.trailing, 7)
            .background(
                on ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                   : AnyShapeStyle(Color(.secondarySystemBackground)),
                in: .capsule
            )
            .overlay(
                Capsule().strokeBorder(
                    on ? Color.accentColor.opacity(0.35) : Color(.separator),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    private func miniSwitch(on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Color.accentColor : Color(.systemGray3))
                .frame(width: 32, height: 19)
            Circle()
                .fill(.white)
                .frame(width: 15, height: 15)
                .padding(2)
        }
    }
}
