//
//  HomeView.swift
//  HexIOS
//
//  Home tab (locked design §4.1): keyboard-ready status pill, a "New note"
//  capture card (records & saves in-app, never switches apps), and a Recent
//  preview. Monochrome surfaces; the single accent is on the mic + live signals.
//

import SwiftData
import SwiftUI

struct HomeView: View {
    let model: DictationModel
    @Query(sort: \TranscriptEntry.date, order: .reverse) private var entries: [TranscriptEntry]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusPill

                    if model.sessionActive { sessionBanner }
                    if model.awaitingSwipeBack { swipeBackBanner }

                    newNoteCard

                    if !entries.isEmpty { recentSection }
                }
                .padding()
            }
            .navigationTitle("Hex")
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

    // MARK: Status

    private var statusPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
            Text(statusText)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(model.modelState == .ready ? Color.accentColor : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(pillBackground, in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        switch model.modelState {
        case .loading:
            model.modelProgress > 0
                ? "Downloading model… \(Int(model.modelProgress * 100))%"
                : "Preparing model… (first run downloads ~600MB+)"
        case .ready: "Keyboard ready · \(model.modelName)"
        case .failed: "Model unavailable"
        }
    }

    private var pillBackground: some ShapeStyle {
        model.modelState == .ready ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                                   : AnyShapeStyle(Color(.secondarySystemBackground))
    }

    // MARK: New note

    private var newNoteCard: some View {
        VStack(spacing: 12) {
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

            Text(captionText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.separator))
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
        case .idle: "New note — records & saves here. Won't switch apps."
        case .recording: "Listening… tap to stop."
        case .transcribing: "Transcribing…"
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(entries.prefix(3)) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.kind.systemImage)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.text).lineLimit(2)
                        Text(entry.date, style: .time)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Session banners

    private var sessionBanner: some View {
        HStack {
            Label("Flow session active", systemImage: "dot.radiowaves.left.and.right")
                .font(.footnote).foregroundStyle(Color.accentColor)
            Spacer()
            Button("End", role: .destructive) { model.endSession() }
                .font(.footnote)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    private var swipeBackBanner: some View {
        Label {
            Text("Session started — **swipe back to your app** and dictate from the Hex keyboard.")
        } icon: {
            Image(systemName: "arrow.uturn.backward")
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))
        .onTapGesture { model.dismissSwipeBackHint() }
    }
}
