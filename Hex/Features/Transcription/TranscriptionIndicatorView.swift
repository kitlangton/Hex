//
//  TranscriptionIndicatorView.swift
//  Hex
//

import AppKit
import Combine
import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct TranscriptionIndicatorView: View {
	@ObserveInjection var inject

	enum Status: Equatable {
		case hidden
		case optionKeyPressed
		case recording
		case screenAware
		case transcribing
		case refining(String?)
		case handoff(String, isReady: Bool, hasLaunched: Bool, isDeparting: Bool, isFlying: Bool)
		case prewarming
		case completedTranscript(String)
		case copied(String)
		case hidingCopied(String)
		case microphonePermissionRequired
		case error(String)

		var showsWaveform: Bool {
			switch self {
			case .recording, .screenAware: true
			default: false
			}
		}

		var showsProcessing: Bool {
			switch self {
			case .transcribing, .refining, .handoff(_, isReady: false, hasLaunched: false, isDeparting: false, isFlying: false), .prewarming: true
			default: false
			}
		}

		var isHandoffDeparting: Bool {
			guard case let .handoff(_, _, _, isDeparting, _) = self else { return false }
			return isDeparting
		}

		var isHandoffFlying: Bool {
			guard case let .handoff(_, _, _, _, isFlying) = self else { return false }
			return isFlying
		}

		/// Content must be gone before the departing handoff pill starts shrinking.
		var hidesContentForHandoffDeparture: Bool {
			isHandoffDeparting
		}

		var requestsMicrophonePermissionWhenTapped: Bool {
			self == .microphonePermissionRequired
		}
	}

	private struct Metrics {
		let height: CGFloat
		let waveformWidth: CGFloat

		init(size: IndicatorSize) {
			switch size {
			case .compact:
				height = 22
				waveformWidth = 76
			case .regular:
				height = 28
				waveformWidth = 116
			case .large:
				height = 34
				waveformWidth = 164
			}
		}
	}

	private enum RecordingCapability: Hashable {
		case speakerIdentification
		case systemAudio

		var systemImage: String {
			switch self {
			case .speakerIdentification: "person.2.wave.2"
			case .systemAudio: "speaker.wave.2"
			}
		}

		var label: String {
			switch self {
			case .speakerIdentification: "Speaker identification"
			case .systemAudio: "System audio"
			}
		}
	}

	var status: Status
	var meter: Meter
	var size: IndicatorSize
	var isSpeakerIdentificationActive = false
	var isSystemAudioActive = false
	var availableSize: CGSize = .zero
	var onOpenHistory: () -> Void = {}
	var onOpenAgentHandoff: () -> Void = {}
	var onDismissAgentHandoff: () -> Void = {}
	var onCopyCompletedTranscript: () -> Void = {}
	var onDismissCompletedTranscript: () -> Void = {}
	var onRequestMicrophonePermission: () -> Void = {}
	var onCardSizeChange: (CGSize?, Bool) -> Void = { _, _ in }

	@State private var waveformSamples: [CGFloat] = []
	@State private var isHoveringCompletedTranscript = false
	@State private var handoffDepartureProgress: CGFloat = 0

	private var metrics: Metrics { .init(size: size) }
	private var isHidden: Bool {
		switch status {
		case .hidden, .hidingCopied:
			true
		default:
			false
		}
	}
	private var hiddenScale: CGFloat { status == .hidden ? 0.8 : 1 }
	private var isScreenAware: Bool { status == .screenAware }
	private var activeRecordingCapabilities: [RecordingCapability] {
		guard status.showsWaveform else { return [] }
		var capabilities: [RecordingCapability] = []
		if isSpeakerIdentificationActive {
			capabilities.append(.speakerIdentification)
		}
		if isSystemAudioActive {
			capabilities.append(.systemAudio)
		}
		return capabilities
	}
	private var capabilityIconSize: CGFloat { metrics.height * 0.42 }
	private var capabilityIconSpacing: CGFloat { 4 }
	private var capabilityWaveformSpacing: CGFloat { 6 }
	private var capabilityIndicatorWidth: CGFloat {
		guard !activeRecordingCapabilities.isEmpty else { return 0 }
		return CGFloat(activeRecordingCapabilities.count) * capabilityIconSize
			+ CGFloat(activeRecordingCapabilities.count - 1) * capabilityIconSpacing
			+ capabilityWaveformSpacing
	}
	private var pillCornerRadius: CGFloat { metrics.height * 0.28 }
	private var expandedCardCornerRadius: CGFloat { max(12, pillCornerRadius) }
	private var cardCornerRadius: CGFloat {
		if case .completedTranscript = status { return expandedCardCornerRadius }
		if status.isHandoffDeparting {
			return pillCornerRadius + (metrics.height / 2 - pillCornerRadius) * handoffDepartureProgress
		}
		return pillCornerRadius
	}
	private var opensHistoryWhenTapped: Bool {
		switch status {
		case .hidden, .handoff(_, _, _, _, _), .completedTranscript, .copied, .hidingCopied, .microphonePermissionRequired:
			false
		default:
			true
		}
	}

	private var indicatorWidth: CGFloat {
		switch status {
		case .hidden, .optionKeyPressed:
			metrics.height
		case .recording:
			recordingPillSize.width
		case .screenAware:
			// The added room reveals older waveform samples instead of resetting them.
			// Capability indicators add separate room rather than shrinking the waveform.
			metrics.waveformWidth + 58 + capabilityIndicatorWidth
		case .transcribing, .prewarming:
			// Loading is a continuation of recording, so retain the recording pill's width.
			recordingPillSize.width
		case let .refining(promptName):
			loadingPillWidth(for: refinementLabel(promptName))
		case let .handoff(label, _, _, _, _):
			loadingPillWidth(for: label)
		case let .completedTranscript(text):
			expandedSize(for: text).width
		case .copied, .hidingCopied:
			recordingPillSize.width
		case .microphonePermissionRequired, .error:
			300
		}
	}

	private var indicatorHeight: CGFloat {
		if case let .completedTranscript(text) = status {
			return expandedSize(for: text).height
		}
		return metrics.height
	}

	private var cardSize: CGSize {
		.init(width: indicatorWidth, height: indicatorHeight)
	}

	/// The AppKit hosting panel clips anything outside its bounds. During the
	/// flight, reserve a transparent canvas around the collapsed dot so its
	/// trailing glow remains visible instead of being cut off at the dot's edge.
	private var panelSize: CGSize {
		guard status.isHandoffFlying else { return cardSize }
		return .init(
			width: max(cardSize.width, metrics.height * 14),
			height: max(cardSize.height, metrics.height * 14)
		)
	}

	private var visibleCardSize: CGSize {
		.init(
			width: cardSize.width + (metrics.height - cardSize.width) * handoffDepartureProgress,
			height: cardSize.height
		)
	}

	private func expandedSize(for text: String) -> CGSize {
		let maximumSize = maximumTranscriptCardSize
		return .init(
			width: maximumSize.width,
			height: transcriptCardHeight(for: text, width: maximumSize.width, maximum: maximumSize.height)
		)
	}

	private var maximumTranscriptCardSize: CGSize {
		let proposedWidth = recordingPillSize.width * 3
		let proposedMaximumHeight = metrics.height * 5
		guard availableSize.width > 0, availableSize.height > 0 else {
			return .init(width: proposedWidth, height: proposedMaximumHeight)
		}
		return .init(
			width: min(proposedWidth, max(metrics.height * 4, availableSize.width - 48)),
			height: min(proposedMaximumHeight, max(metrics.height * 3, availableSize.height - 36))
		)
	}

	private func transcriptCardHeight(for text: String, width: CGFloat, maximum: CGFloat) -> CGFloat {
		let textBounds = (text as NSString).boundingRect(
			with: .init(width: max(1, width - 28), height: .greatestFiniteMagnitude),
			options: [.usesLineFragmentOrigin, .usesFontLeading],
			attributes: [.font: NSFont.systemFont(ofSize: 14)],
			context: nil
		)
		let minimum = min(maximum, metrics.height * 2.5)
		return min(maximum, max(minimum, ceil(textBounds.height) + 28))
	}

	private var waveformWidth: CGFloat { metrics.waveformWidth + (isScreenAware ? 24 : 0) }

	/// The copied confirmation reuses the exact recording-pill geometry.
	private var recordingPillSize: CGSize {
		.init(width: metrics.waveformWidth + 20 + capabilityIndicatorWidth, height: metrics.height)
	}

	private func refinementLabel(_ promptName: String?) -> String {
		guard let promptName, !promptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return "Refining"
		}
		return "Rewrite · \(promptName)"
	}

	private func loadingPillWidth(for label: String) -> CGFloat {
		let font = NSFont.systemFont(ofSize: max(10, metrics.height * 0.38), weight: .semibold)
		let labelWidth = (label as NSString).size(withAttributes: [.font: font]).width
		return max(recordingPillSize.width, labelWidth + 72)
	}

	private var accessibilityLabel: String {
		let statusLabel = switch status {
		case .hidden: "Dictation inactive"
		case .optionKeyPressed: "Dictation hotkey pressed"
		case .recording: "Recording"
		case .screenAware: "Screen aware recording"
		case .transcribing: "Transcribing"
		case let .refining(promptName): refinementLabel(promptName)
		case let .handoff(label, _, _, _, _): "Agent handoff: \(label)"
		case .prewarming: "Model prewarming"
		case .completedTranscript: "Transcript ready to copy"
		case .copied: "Transcript copied"
		case .hidingCopied: "Transcript copied"
		case .microphonePermissionRequired: "Microphone access required. Click to grant access."
		case let .error(message): "Error: \(message)"
		}
		guard status.showsWaveform, !activeRecordingCapabilities.isEmpty else { return statusLabel }
		return "\(statusLabel), \(activeRecordingCapabilities.map(\.label).joined(separator: ", "))"
	}

	@ViewBuilder
	var body: some View {
		if status.requestsMicrophonePermissionWhenTapped {
			indicatorBody
				.onTapGesture(perform: onRequestMicrophonePermission)
				.accessibilityAddTraits(.isButton)
				.accessibilityHint("Requests microphone access from macOS")
				.accessibilityAction { onRequestMicrophonePermission() }
		} else if opensHistoryWhenTapped {
			indicatorBody.onTapGesture(perform: onOpenHistory)
		} else if case let .handoff(_, isReady, _, isDeparting, _) = status, isReady, !isDeparting {
			indicatorBody.onTapGesture(perform: onOpenAgentHandoff)
		} else {
			indicatorBody
		}
	}

	private var indicatorBody: some View {
		visualCard
			.opacity(isHidden ? 0 : 1)
			.scaleEffect(hiddenScale)
			.accessibilityLabel(accessibilityLabel)
			.accessibilityHidden(isHidden)
			.onAppear {
				appendMeterSample(meter)
				handoffDepartureProgress = status.isHandoffDeparting ? 1 : 0
				onCardSizeChange(isHidden ? nil : panelSize, status.isHandoffFlying)
			}
			.onChange(of: meter) { _, meter in
				appendMeterSample(meter)
			}
			.onChange(of: status) { oldStatus, newStatus in
				if oldStatus.showsWaveform && !newStatus.showsWaveform {
					waveformSamples.removeAll(keepingCapacity: true)
				}
				if case .completedTranscript = newStatus {
					onCardSizeChange(panelSize, newStatus.isHandoffFlying)
				} else {
					isHoveringCompletedTranscript = false
					onCardSizeChange(isHidden ? nil : panelSize, newStatus.isHandoffFlying)
				}
				updateHandoffDepartureAnimation(for: newStatus)
			}
			.onChange(of: size) { _, _ in
				onCardSizeChange(isHidden ? nil : panelSize, status.isHandoffFlying)
			}
			.enableInjection()
	}

	private var visualCard: some View {
		ZStack {
			cardSurface
				.frame(width: visibleCardSize.width, height: visibleCardSize.height)
				.blur(radius: status.isHandoffFlying ? metrics.height * 0.08 : 0)
				.opacity(status.isHandoffFlying ? 0.72 : 1)
				.overlay {
					// The halo and plume are attached to the existing collapsed card.
					// They never own an independent screen position.
					HandoffCometOrb(diameter: metrics.height, isActive: status.isHandoffFlying)
						.opacity(status.isHandoffFlying ? 1 : 0)
				}

			content
				.frame(width: visibleCardSize.width, height: visibleCardSize.height)
				// The Shift-ended handoff begins its visual departure here. Remove the
				// preceding rewrite/loading label before the pill starts condensing so
				// no text is visible inside the departing ball.
				.opacity(status.hidesContentForHandoffDeparture ? 0 : 1)
				.animation(nil, value: status.hidesContentForHandoffDeparture)
		}
			.frame(width: panelSize.width, height: panelSize.height)
	}

	private func updateHandoffDepartureAnimation(for status: Status) {
		let target: CGFloat = status.isHandoffDeparting ? 1 : 0
		guard handoffDepartureProgress != target else { return }
		withAnimation(.easeInOut(duration: 0.28)) {
			handoffDepartureProgress = target
		}
	}

	private var cardSurface: some View {
		RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
			.fill(backgroundStyle)
			.overlay {
				if usesGlassBackground {
					RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
						.fill(Color(nsColor: .windowBackgroundColor).opacity(0.68))
				}
			}
			.overlay {
				RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
					.stroke(strokeColor, lineWidth: 1)
			}
	}

	@ViewBuilder
	private var content: some View {
		if status.showsWaveform {
			HStack(spacing: 0) {
				if !activeRecordingCapabilities.isEmpty {
					HStack(spacing: capabilityIconSpacing) {
						ForEach(activeRecordingCapabilities, id: \.self) { capability in
							Image(systemName: capability.systemImage)
								.font(.system(size: capabilityIconSize, weight: .semibold))
								.foregroundStyle(.white)
								.frame(width: capabilityIconSize)
								.help(capability.label)
								.accessibilityHidden(true)
						}
					}
					.frame(width: capabilityIndicatorWidth - capabilityWaveformSpacing)
					.padding(.trailing, capabilityWaveformSpacing)
				}

				if isScreenAware {
					Image(systemName: "rectangle.inset.filled")
						.font(.system(size: capabilityIconSize, weight: .semibold))
						.foregroundStyle(.white)
						.padding(.trailing, capabilityWaveformSpacing)
						.help("Screen aware")
						.accessibilityHidden(true)
				}

				PillWaveform(samples: waveformSamples)
					.frame(width: waveformWidth, height: metrics.height - 8)
			}
			.padding(.horizontal, 10)
		} else if case let .refining(promptName) = status {
			LoadingWave(
				label: refinementLabel(promptName),
				width: indicatorWidth - 20,
				height: metrics.height
			)
		} else if case let .handoff(label, isReady, hasLaunched, _, _) = status {
			if isReady || hasLaunched {
				Label(label, systemImage: "checkmark")
					.font(.system(size: max(10, metrics.height * 0.38), weight: .semibold))
					.foregroundStyle(.white)
			} else {
				LoadingWave(
					label: label,
					width: indicatorWidth - 20,
					height: metrics.height
				)
			}
		} else if status.showsProcessing {
			LoadingWave(label: "Processing", width: metrics.waveformWidth, height: metrics.height)
		} else if case let .completedTranscript(text) = status {
			completedTranscript(text)
		} else if case .copied = status {
			copiedLabel
		} else if case .hidingCopied = status {
			copiedLabel
		} else if case .microphonePermissionRequired = status {
			Label("Microphone access required — click to grant access", systemImage: "exclamationmark.triangle.fill")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.white)
				.lineLimit(2)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 10)
		} else if case let .error(message) = status {
			Label(message, systemImage: "exclamationmark.triangle.fill")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.white)
				.lineLimit(2)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 10)
		}
	}

	private func completedTranscript(_ text: String) -> some View {
		ZStack(alignment: .topTrailing) {
			ScrollView(.vertical) {
				VStack(alignment: .leading, spacing: 0) {
					Text(text)
						.font(.system(size: 14))
						.foregroundStyle(.primary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textSelection(.enabled)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(14)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

			if isHoveringCompletedTranscript {
				ZStack(alignment: .topTrailing) {
					Button(action: onCopyCompletedTranscript) {
						ZStack {
							RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
								.fill(.thinMaterial)
								.opacity(0.48)
								.accessibilityHidden(true)

							Label("Click to Copy", systemImage: "doc.on.doc")
								.font(.system(size: 15, weight: .semibold))
								.padding(.horizontal, 18)
								.padding(.vertical, 12)
						}
						.frame(maxWidth: .infinity, maxHeight: .infinity)
					}
					.buttonStyle(.plain)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
					.accessibilityLabel("Copy to Clipboard")
					.accessibilityHint("Copies the completed transcript")

					Button(action: onDismissCompletedTranscript) {
						Image(systemName: "xmark.circle.fill")
							.font(.system(size: 28, weight: .semibold))
							.symbolRenderingMode(.hierarchical)
							.foregroundStyle(.primary)
							.padding(10)
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Dismiss transcript")
					.accessibilityHint("Closes the transcript without copying it")
					.help("Close")
				}
				.clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
		.onHover { isHoveringCompletedTranscript = $0 }
		.accessibilityElement(children: .contain)
	}

	private var copiedLabel: some View {
		Label("Copied", systemImage: "checkmark")
			.font(.system(size: max(10, metrics.height * 0.38), weight: .semibold))
			.foregroundStyle(.white)
	}

	private var backgroundStyle: AnyShapeStyle {
		if case .completedTranscript = status { return AnyShapeStyle(.regularMaterial) }
		return AnyShapeStyle(isHidden ? .clear : Color(nsColor: .octoIndicator))
	}

	private var usesGlassBackground: Bool {
		if case .completedTranscript = status { return true }
		return false
	}

	private var strokeColor: Color {
		if case .completedTranscript = status { return .primary.opacity(0.16) }
		return isHidden ? Color.clear : Color.white.opacity(0.28)
	}

	private func appendMeterSample(_ meter: Meter) {
		guard status.showsWaveform else { return }
		// Typical spoken audio spends most of its time well below the peak meter
		// range. Boost and curve that lower range so normal speech remains legible.
		let boostedLevel = min(max(max(meter.averagePower, meter.peakPower * 0.88) * 7.5, 0), 1)
		let sample = CGFloat(pow(boostedLevel, 0.55))
		waveformSamples.append(sample)
		if waveformSamples.count > 240 {
			waveformSamples.removeFirst(waveformSamples.count - 240)
		}
	}

}

/// Turns the collapsed handoff dot into an edgeless luminous cloud with a
/// curved tracer while its AppKit-hosted window travels toward the menu bar.
private struct HandoffCometOrb: View {
	private struct CloudPuff: Identifiable {
		let id: Int
		let x: CGFloat
		let y: CGFloat
		let size: CGFloat
		let opacity: Double
		let stretch: CGFloat
	}

	let diameter: CGFloat
	let isActive: Bool
	@State private var motion = AgentHandoffMotion.stationary

	private let headPuffs = [
		CloudPuff(id: 10, x: -0.12, y: 0.04, size: 1.18, opacity: 0.88, stretch: 1.02),
		CloudPuff(id: 11, x: 0.18, y: -0.10, size: 0.88, opacity: 0.76, stretch: 0.94),
		CloudPuff(id: 12, x: -0.22, y: -0.17, size: 0.78, opacity: 0.7, stretch: 1.04),
		CloudPuff(id: 13, x: 0.12, y: 0.18, size: 0.76, opacity: 0.62, stretch: 1.08),
		CloudPuff(id: 14, x: -0.14, y: 0.22, size: 0.67, opacity: 0.54, stretch: 0.92)
	]

	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
			let phase = timeline.date.timeIntervalSinceReferenceDate * 7
			let pulse = CGFloat(1 + sin(phase) * 0.035)

			ZStack {
				ForEach(0 ..< 14, id: \.self) { index in
					motionTrailPuff(index: index, pulse: pulse)
				}

				Circle()
					.fill(
						RadialGradient(
							colors: [
								Color(nsColor: .octoIndicator).opacity(0.54),
								Color(nsColor: .octoIndicator).opacity(0.22),
								Color(nsColor: .octoIndicator).opacity(0)
							],
							center: .center,
							startRadius: diameter * 0.12,
							endRadius: diameter * 0.88
						)
					)
					.frame(width: diameter * 2.1 * pulse, height: diameter * 2.1 * pulse)
					.blur(radius: diameter * 0.12)

				ForEach(headPuffs) { puff in
					cloudPuff(puff, pulse: pulse, centerLight: 0.3)
				}

				Circle()
					.fill(
						RadialGradient(
							colors: [
								Color.white.opacity(0.58),
								Color(nsColor: .octoIndicator).opacity(0.52),
								Color(nsColor: .octoIndicator).opacity(0)
							],
							center: UnitPoint(x: 0.38, y: 0.32),
							startRadius: 0,
							endRadius: diameter * 0.42
						)
					)
					.frame(width: diameter * 0.82, height: diameter * 0.82)
					.offset(x: -diameter * 0.04, y: -diameter * 0.04)
					.blur(radius: diameter * 0.04)
			}
		}
		.frame(width: diameter * 14, height: diameter * 14)
		.onReceive(NotificationCenter.default.publisher(for: .agentHandoffMotionUpdated)) { notification in
			guard isActive else { return }
			motion = notification.object as? AgentHandoffMotion ?? .stationary
		}
		.onChange(of: isActive) { _, isActive in
			if !isActive {
				motion = .stationary
			}
		}
		.onDisappear {
			motion = .stationary
		}
		.allowsHitTesting(false)
	}

	private func motionTrailPuff(index: Int, pulse: CGFloat) -> some View {
		let speedStrength = min(1, max(0, motion.speed / 2_400))
		let fraction = CGFloat(index + 1) / 14
		let strength = speedStrength * pow(1 - fraction, 1.15)
		let length = diameter * (0.45 + speedStrength * 4.75)
		let direction = motion.backwardDirection
		let perpendicular = CGSize(width: -direction.height, height: direction.width)
		let lateralDrift = sin(CGFloat(index) * 2.17) * diameter * 0.07 * fraction
		let size = 0.3 + strength * 0.72
		let variation = 1 + CGFloat(index % 4) * 0.045
		return Ellipse()
			.fill(
				RadialGradient(
					colors: [
						Color.white.opacity(Double(strength) * 0.18),
						Color(nsColor: .octoIndicator).opacity(Double(strength) * 0.82),
						Color(nsColor: .octoIndicator).opacity(Double(strength) * 0.3),
						Color(nsColor: .octoIndicator).opacity(0)
					],
					center: .center,
					startRadius: 0,
					endRadius: diameter * size * 0.62
				)
			)
			.frame(
				width: diameter * size * variation * pulse,
				height: diameter * size * 0.8 * pulse
			)
			.offset(
				x: direction.width * length * fraction + perpendicular.width * lateralDrift,
				y: direction.height * length * fraction + perpendicular.height * lateralDrift
			)
			.blur(radius: diameter * (0.08 + (1 - strength) * 0.08))
			.opacity(motion.speed > 1 ? 1 : 0)
	}

	private func cloudPuff(_ puff: CloudPuff, pulse: CGFloat, centerLight: Double) -> some View {
		Ellipse()
			.fill(
				RadialGradient(
					colors: [
						Color.white.opacity(centerLight * puff.opacity),
						Color(nsColor: .octoIndicator).opacity(puff.opacity),
						Color(nsColor: .octoIndicator).opacity(puff.opacity * 0.34),
						Color(nsColor: .octoIndicator).opacity(0)
					],
					center: UnitPoint(x: 0.58, y: 0.42),
					startRadius: 0,
					endRadius: diameter * puff.size * 0.58
				)
			)
			.frame(
				width: diameter * puff.size * puff.stretch * pulse,
				height: diameter * puff.size * 0.82 * pulse
			)
			.offset(x: diameter * puff.x, y: diameter * puff.y)
			.blur(radius: diameter * 0.12)
	}
}

private struct PillWaveform: View {
	let samples: [CGFloat]

	var body: some View {
		Canvas { context, size in
			let barWidth: CGFloat = 3
			let gap: CGFloat = 2
			let capacity = max(1, Int((size.width + gap) / (barWidth + gap)))
			let visibleSamples = samples.suffix(capacity)
			let values = visibleSamples.isEmpty ? Array(repeating: CGFloat(0.04), count: min(capacity, 8)) : Array(visibleSamples)
			let startX = size.width - CGFloat(values.count) * (barWidth + gap) + gap

			for (index, sample) in values.enumerated() {
				let normalized = max(sample, 0.06)
				let barHeight = max(3, normalized * size.height)
				let rect = CGRect(
					x: startX + CGFloat(index) * (barWidth + gap),
					y: (size.height - barHeight) / 2,
					width: barWidth,
					height: barHeight
				)
				context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white.opacity(0.92)))
			}
		}
		.accessibilityHidden(true)
	}
}

struct LoadingSineWave: View {
	let color: Color

	var body: some View {
		TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
			Canvas { context, size in
				// The absolute timeline phase prevents a loader restart when the
				// underlying work moves between lifecycle states.
				let phase = timeline.date.timeIntervalSinceReferenceDate * 6
				let amplitude = max(2, size.height * 0.22)
				let angularFrequency = (CGFloat.pi * 2 * 1.4) / max(size.width, 1)
				var path = Path()

				for x in stride(from: CGFloat.zero, through: size.width, by: 1) {
					let y = size.height / 2 - sin(x * angularFrequency + phase) * amplitude
					if x == 0 {
						path.move(to: .init(x: x, y: y))
					} else {
						path.addLine(to: .init(x: x, y: y))
					}
				}

				context.stroke(path, with: .color(color), lineWidth: 1.5)
			}
		}
		.accessibilityHidden(true)
	}
}

private struct LoadingWave: View {
	let label: String
	let width: CGFloat
	let height: CGFloat

	var body: some View {
		HStack(spacing: 8) {
			LoadingSineWave(color: .white.opacity(0.92))
			.frame(width: min(width * 0.35, 44), height: height)

			Text(label)
				.font(.system(size: max(10, height * 0.38), weight: .semibold))
				.foregroundStyle(.white)
		}
		.frame(width: width + 20, height: height)
		.accessibilityHidden(true)
	}
}

private enum LongRecordingCancellationAlert {
	@MainActor
	static func present() -> NSApplication.ModalResponse {
		let alert = NSAlert()
		alert.messageText = "Cancel long recording?"
		alert.informativeText = "This recording has been running for a while. Cancelling will stop it without transcribing it."
		alert.addButton(withTitle: "Keep Recording")
		alert.addButton(withTitle: "Cancel Recording")
		alert.buttons.last?.hasDestructiveAction = true

		if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
			let window = alert.window
			window.setFrameOrigin(
				.init(
					x: screen.visibleFrame.midX - window.frame.width / 2,
					y: screen.visibleFrame.midY - window.frame.height / 2
				)
			)
		}

		return alert.runModal()
	}
}

// MARK: - View

struct TranscriptionIndicatorOverlayView: View {
	@Bindable var store: StoreOf<TranscriptionFeature>
	@ObserveInjection var inject
	@Shared(.hexSettings) var hexSettings: HexSettings
	let onOpenHistory: () -> Void
	let onPillSizeChange: (CGSize?, Bool) -> Void
	let onAgentHandoffDeparture: () -> Void
	@State private var currentPillSize: CGSize?

	var status: TranscriptionIndicatorView.Status {
		if let presentation = store.completedTranscriptPresentation {
			switch presentation {
			case let .expanded(text): return .completedTranscript(text)
			case let .copied(text): return .copied(text)
			case let .hidingCopied(text): return .hidingCopied(text)
			}
		} else if store.isMicrophonePermissionRequired {
			return .microphonePermissionRequired
		} else if let error = store.error {
			return .error(error)
		} else if let handoff = store.agentHandoffPresentation {
			return .handoff(
				handoff.label,
				isReady: handoff.isReady,
				hasLaunched: handoff.hasLaunched,
				isDeparting: handoff.isDeparting,
				isFlying: handoff.isFlying
			)
		} else if store.isScreenAwareModeActive {
			return .screenAware
		} else if store.isRefining || (store.isTranscribing && store.forcedRefinementMode != nil) {
			return .refining(store.rewritePromptForRefinement?.name)
		} else if store.isTranscribing {
			return .transcribing
		} else if store.isRecording {
			return .recording
		} else if store.isPrewarming {
			return .prewarming
		} else {
			return .hidden
		}
	}

	var body: some View {
		let indicatorStatus = status
		TranscriptionIndicatorView(
			status: indicatorStatus,
			meter: indicatorStatus.showsWaveform ? store.meter : .init(averagePower: 0, peakPower: 0),
			size: hexSettings.indicatorSize,
			isSpeakerIdentificationActive: store.activeSpeakerIdentificationEnabled,
			isSystemAudioActive: store.activeSystemAudioEnabled,
			onOpenHistory: onOpenHistory,
			onOpenAgentHandoff: { store.send(.openAgentHandoff) },
			onDismissAgentHandoff: { store.send(.dismissAgentHandoff) },
			onCopyCompletedTranscript: { store.send(.copyCompletedTranscript) },
			onDismissCompletedTranscript: { store.send(.dismissCompletedTranscript) },
			onRequestMicrophonePermission: { store.send(.requestMicrophonePermission) },
			onCardSizeChange: { size, preservingCenter in
				currentPillSize = size
				onPillSizeChange(size, preservingCenter)
			}
		)
		.animation(.snappy(duration: 0.22), value: indicatorStatus)
		.animation(.snappy(duration: 0.22), value: hexSettings.indicatorSize)
		.onChange(of: hexSettings.indicatorLocation) { _, _ in
			onPillSizeChange(currentPillSize, false)
		}
		.onChange(of: indicatorStatus.isHandoffFlying) { _, isFlying in
			if isFlying {
				onAgentHandoffDeparture()
			}
		}
		.onDisappear { onPillSizeChange(nil, false) }
		.onChange(of: store.isLongRecordingCancellationConfirmationPresented) { _, isPresented in
			guard isPresented else { return }

			DispatchQueue.main.async {
				guard store.isLongRecordingCancellationConfirmationPresented else { return }
				switch LongRecordingCancellationAlert.present() {
				case .alertSecondButtonReturn:
					store.send(.confirmLongRecordingCancellation)
				default:
					store.send(.dismissLongRecordingCancellationConfirmation)
				}
			}
		}
		.task {
			await store.send(.task).finish()
		}
		.enableInjection()
	}
}

#Preview("Transcription Indicator") {
	VStack(spacing: 16) {
		TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.5, peakPower: 0.75), size: .regular)
		TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.5, peakPower: 0.75), size: .regular, isSpeakerIdentificationActive: true)
		TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.5, peakPower: 0.75), size: .regular, isSystemAudioActive: true)
		TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.5, peakPower: 0.75), size: .regular, isSpeakerIdentificationActive: true, isSystemAudioActive: true)
		TranscriptionIndicatorView(status: .screenAware, meter: .init(averagePower: 0.5, peakPower: 0.75), size: .regular)
		TranscriptionIndicatorView(status: .screenAware, meter: .init(averagePower: 0.5, peakPower: 0.75), size: .regular, isSpeakerIdentificationActive: true, isSystemAudioActive: true)
		TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0), size: .regular)
	}
	.padding(40)
	.background(.black)
}
