//
//  HexWidgetsLiveActivity.swift
//  HexWidgets
//
//  Flow Session Live Activity (P3-3): a persistent "mic hot · MM:SS left"
//  indicator on the Lock Screen + Dynamic Island while a dictation session is
//  active, with an interactive End button. Uses the shared FlowSessionAttributes
//  from HexCore.
//

import ActivityKit
import AppIntents
import HexCore
import SwiftUI
import WidgetKit

struct HexWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlowSessionAttributes.self) { context in
            // Lock Screen / banner
            HStack(spacing: 12) {
                micGlyph(context).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hex dictation").font(.headline)
                    countdown(context).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                endButton.buttonStyle(.bordered).tint(.accentColor)
            }
            .padding()
            .activitySystemActionForegroundColor(.accentColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { micGlyph(context).font(.title3) }
                DynamicIslandExpandedRegion(.trailing) { countdown(context).font(.title3) }
                DynamicIslandExpandedRegion(.center) {
                    Text("Hex dictation").font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    endButton.buttonStyle(.bordered).tint(.accentColor)
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.tint)
            } compactTrailing: {
                countdown(context).monospacedDigit()
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.tint)
            }
            .keylineTint(.accentColor)
        }
    }

    private var endButton: some View {
        Button(intent: EndFlowSessionIntent()) {
            Label("End", systemImage: "stop.fill")
        }
    }

    private func micGlyph(_ context: ActivityViewContext<FlowSessionAttributes>) -> some View {
        Image(systemName: context.state.isCapturing ? "waveform" : "mic.fill")
            .foregroundStyle(.tint)
    }

    @ViewBuilder
    private func countdown(_ context: ActivityViewContext<FlowSessionAttributes>) -> some View {
        if let endsAt = context.state.endsAt, endsAt > Date() {
            Text(timerInterval: Date() ... endsAt, countsDown: true)
        } else {
            Text("mic hot")
        }
    }
}

#Preview("Flow Session", as: .content, using: FlowSessionAttributes()) {
    HexWidgetsLiveActivity()
} contentStates: {
    FlowSessionAttributes.ContentState(endsAt: Date().addingTimeInterval(600), isCapturing: false)
    FlowSessionAttributes.ContentState(endsAt: Date().addingTimeInterval(600), isCapturing: true)
}
