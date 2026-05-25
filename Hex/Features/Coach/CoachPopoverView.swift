import AppKit
import ComposableArchitecture
import HexCore
import Inject
import MarkdownUI
import SwiftUI

struct StreamingPreview: Equatable, Sendable {
	let transcriptID: UUID
	let transcript: String
	let timestamp: Date
	var streamingText: String
}

struct CoachPopoverView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<CoachFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header

			Divider()

			content

			Divider()

			footer
		}
		.frame(width: 520, height: 600)
		.enableInjection()
	}

	@ViewBuilder
	private var content: some View {
		if let streaming = store.streamingPreview {
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					streamingSection(streaming)
				}
				.padding(20)
			}
		} else if let latest = store.feedbackHistory.items.first {
			ScrollView {
				VStack(alignment: .leading, spacing: 24) {
					latestSection(latest)
					if store.feedbackHistory.items.count > 1 {
						recentSection
					}
				}
				.padding(20)
			}
		} else {
			emptyState
		}
	}

	// MARK: - Streaming preview

	private func streamingSection(_ preview: StreamingPreview) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 8) {
				ProgressView().controlSize(.small)
				Text("Coach is analyzing…")
					.font(.subheadline.weight(.semibold))
				Spacer()
				Text(preview.timestamp.formatted(date: .omitted, time: .shortened))
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			VStack(alignment: .leading, spacing: 4) {
				Text("You said")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
				Text(preview.transcript)
					.font(.callout)
					.italic()
			}

			VStack(alignment: .leading, spacing: 4) {
				if preview.streamingText.isEmpty {
					Text("Waiting for first token…")
						.font(.callout)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(10)
						.background(
							RoundedRectangle(cornerRadius: 6)
								.fill(Color.secondary.opacity(0.08))
						)
				} else {
					Markdown(preview.streamingText)
						.markdownTextStyle { FontSize(.em(0.95)) }
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
		}
	}

	// MARK: - Header

	private var header: some View {
		HStack {
			Image(systemName: "ear.and.waveform")
				.font(.title2)
			VStack(alignment: .leading, spacing: 2) {
				Text("Pronunciation Coach")
					.font(.headline)
				Text(store.hexSettings.coach.enabled
					 ? "Listening for recordings ≥ \(store.hexSettings.coach.thresholdSec)s"
					 : "Currently off")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: Binding(
				get: { store.hexSettings.coach.enabled },
				set: { store.send(.setEnabled($0)) }
			))
			.labelsHidden()
			.toggleStyle(.switch)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
	}

	// MARK: - Empty state

	private var emptyState: some View {
		VStack(spacing: 12) {
			Spacer()
			Image(systemName: "tray")
				.font(.largeTitle)
				.foregroundStyle(.tertiary)
			Text("No feedback yet")
				.font(.headline)
			Text(store.hexSettings.coach.enabled
				 ? "Dictate for at least \(store.hexSettings.coach.thresholdSec) seconds and feedback will appear here."
				 : "Turn the coach on to start getting pronunciation tips.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 40)
			Spacer()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// MARK: - Latest

	@ViewBuilder
	private func latestSection(_ entry: CoachFeedbackEntry) -> some View {
		if entry.feedback.isStructured {
			structuredLatestSection(entry)
		} else if !entry.feedback.rawMarkdown.isEmpty {
			rawMarkdownLatestSection(entry)
		} else {
			structuredLatestSection(entry) // fall through to whatever we have
		}
	}

	private func rawMarkdownLatestSection(_ entry: CoachFeedbackEntry) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline) {
				Text("Latest")
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.secondary)
				Spacer()
				Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			VStack(alignment: .leading, spacing: 4) {
				Text("You said")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
				Text(entry.transcript)
					.font(.callout)
					.italic()
			}

			Markdown(entry.feedback.rawMarkdown)
				.markdownTextStyle { FontSize(.em(0.95)) }
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private func structuredLatestSection(_ entry: CoachFeedbackEntry) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline) {
				Text("Latest")
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.secondary)
				Spacer()
				Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			HStack(alignment: .center, spacing: 14) {
				ZStack {
					Circle()
						.stroke(Color.secondary.opacity(0.2), lineWidth: 4)
					Circle()
						.trim(from: 0, to: CGFloat(entry.feedback.overallScore) / 10)
						.stroke(scoreColor(entry.feedback.overallScore), style: StrokeStyle(lineWidth: 4, lineCap: .round))
						.rotationEffect(.degrees(-90))
					Text("\(entry.feedback.overallScore)")
						.font(.title3.weight(.semibold))
				}
				.frame(width: 48, height: 48)

				Text(entry.feedback.summary)
					.font(.callout)
			}

			rewriteSection(entry)

			if !entry.feedback.issues.isEmpty {
				VStack(alignment: .leading, spacing: 10) {
					ForEach(Array(entry.feedback.issues.enumerated()), id: \.offset) { _, issue in
						issueRow(issue)
					}
				}
			}

			if !entry.feedback.wins.isEmpty {
				VStack(alignment: .leading, spacing: 4) {
					Text("Wins")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.secondary)
					ForEach(Array(entry.feedback.wins.enumerated()), id: \.offset) { _, win in
						HStack(alignment: .firstTextBaseline, spacing: 6) {
							Image(systemName: "checkmark.circle.fill")
								.foregroundStyle(.green)
								.font(.caption)
							Text(win)
								.font(.callout)
						}
					}
				}
			}
		}
	}

	@ViewBuilder
	private func rewriteSection(_ entry: CoachFeedbackEntry) -> some View {
		let normalized = normalize(entry.feedback.nativeRewrite)
		let hasRewrite = !normalized.isEmpty
		let alreadyNative = hasRewrite && normalize(entry.transcript) == normalized

		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Text("Native phrasing")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
				if alreadyNative {
					Text("Already native-level")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.green)
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(
							Capsule().fill(Color.green.opacity(0.15))
						)
				}
				Spacer()
				if hasRewrite, !alreadyNative {
					Button {
						copyToPasteboard(entry.feedback.nativeRewrite)
					} label: {
						Label("Copy", systemImage: "doc.on.doc")
					}
					.buttonStyle(.borderless)
					.font(.caption2)
				}
			}

			VStack(alignment: .leading, spacing: 6) {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Text("You")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.secondary)
						.frame(width: 44, alignment: .leading)
					Text(entry.transcript)
						.font(.callout)
				}
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Text("Native")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.green)
						.frame(width: 44, alignment: .leading)
					if hasRewrite {
						Text(entry.feedback.nativeRewrite)
							.font(.callout)
					} else {
						Text("—")
							.font(.callout)
							.foregroundStyle(.secondary)
					}
				}
			}
			.padding(10)
			.background(
				RoundedRectangle(cornerRadius: 6)
					.fill(Color.secondary.opacity(0.08))
			)
		}
	}

	private func normalize(_ s: String) -> String {
		s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	private func copyToPasteboard(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}

	private func issueRow(_ issue: Issue) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(issue.wordOrPhrase)
				.font(.callout.weight(.semibold))
			HStack(spacing: 6) {
				Text("You:")
					.font(.caption).foregroundStyle(.secondary)
				Text(issue.whatYouSaid)
					.font(.system(.caption, design: .monospaced))
				Text("→")
					.font(.caption).foregroundStyle(.secondary)
				Text("Target:")
					.font(.caption).foregroundStyle(.secondary)
				Text(issue.whatToSay)
					.font(.system(.caption, design: .monospaced))
			}
			Text(issue.tip)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(10)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(Color.secondary.opacity(0.08))
		)
	}

	// MARK: - Recent

	private var recentSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Recent")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.secondary)

			ForEach(Array(store.feedbackHistory.items.dropFirst().prefix(10).enumerated()), id: \.offset) { _, entry in
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					Text("\(entry.feedback.overallScore)/10")
						.font(.caption.monospacedDigit())
						.frame(width: 40, alignment: .leading)
						.foregroundStyle(scoreColor(entry.feedback.overallScore))
					Text(entry.feedback.summary)
						.font(.caption)
						.lineLimit(1)
						.truncationMode(.tail)
					Spacer()
					Text(entry.timestamp.formatted(.relative(presentation: .numeric)))
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
			}
		}
	}

	// MARK: - Footer

	private var footer: some View {
		HStack {
			if let error = store.lastError {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
				Text(error)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			} else if store.hexSettings.coach.enabled, !store.apiKeyLast4.keys.contains(store.hexSettings.coach.provider) {
				Image(systemName: "key.slash")
					.foregroundStyle(.orange)
				Text("Add an API key in Settings to start coaching.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} else {
				Text("\(store.feedbackHistory.items.count) session\(store.feedbackHistory.items.count == 1 ? "" : "s")")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Spacer()

			if !store.inFlightTranscriptIDs.isEmpty {
				ProgressView().controlSize(.small)
				Text("Analyzing…")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
	}

	// MARK: - Helpers

	private func scoreColor(_ score: Int) -> Color {
		switch score {
		case ...4: return .red
		case 5...7: return .orange
		default: return .green
		}
	}
}
