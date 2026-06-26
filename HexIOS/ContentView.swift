//
//  ContentView.swift
//  HexIOS
//

import SwiftUI

struct ContentView: View {
    let model: DictationModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                modelStatusBanner

                if model.awaitingSwipeBack {
                    swipeBackBanner
                }

                if model.entries.isEmpty {
                    emptyState
                } else {
                    historyList
                }

                Spacer(minLength: 0)

                recordButton
                    .padding(.bottom, 8)
            }
            .padding()
            .navigationTitle("Hex")
            .task { await model.prepare() }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                ),
                presenting: model.errorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { Text($0) }
        }
    }

    @ViewBuilder
    private var modelStatusBanner: some View {
        switch model.modelState {
        case .loading:
            Label {
                Text("Preparing model… (first run downloads it)")
            } icon: {
                ProgressView()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .ready:
            EmptyView()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var swipeBackBanner: some View {
        Label {
            Text("Transcript ready — **swipe back to your app** to insert it.")
        } icon: {
            Image(systemName: "arrow.uturn.backward")
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 12))
        .onTapGesture { model.dismissSwipeBackHint() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Tap **Start Dictation**, speak, then tap **Stop**.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxHeight: .infinity)
    }

    private var historyList: some View {
        List(model.entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
    }

    private var recordButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            HStack {
                if model.phase == .transcribing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                }
                Text(model.recordButtonTitle)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(model.phase == .recording ? Color.red : Color.accentColor, in: .capsule)
            .foregroundStyle(.white)
        }
        .disabled(!model.canRecord && model.phase != .recording)
    }
}

#Preview {
    ContentView(model: DictationModel())
}
