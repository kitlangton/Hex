import Foundation
import HexCore

/// Applies word removals and remappings to a raw transcription, mirroring the
/// pipeline used by the live recording flow. Used both by the recording handler
/// and by history retry so retried rows produce the same processed text as a
/// fresh recording.
struct TranscriptTextProcessor {
    /// - Parameters:
    ///   - raw: Output from the transcription engine.
    ///   - settings: Current `HexSettings` snapshot (read from shared state).
    ///   - bypassFilters: When `true`, returns input unchanged. Used by the recording
    ///     path when the remapping scratchpad is focused so the user can preview raw output.
    static func process(
        _ raw: String,
        settings: HexSettings,
        bypassFilters: Bool
    ) -> String {
        guard !bypassFilters else { return raw }
        var output = raw
        if settings.wordRemovalsEnabled {
            output = WordRemovalApplier.apply(output, removals: settings.wordRemovals)
        }
        output = WordRemappingApplier.apply(output, remappings: settings.wordRemappings)
        return output
    }
}
