import Foundation

/// Platform-neutral, value-typed intermediate representation of a single
/// recognizer result.
///
/// ## Why this exists
/// The real macOS recognizer (`SpeechTranscriber.Result`) carries Apple types
/// (`AttributedString`, `CMTimeRange`) that cannot cross the contract boundary
/// and cannot be exercised headlessly. The macOS engine
/// (`Sources/AlembicKit/Platform/macOS/SpeechAnalyzerEngine.swift`) flattens each
/// live result into this Foundation-only struct *immediately*, then everything
/// downstream — including the volatile/finalized → `TranscriptEvent` mapping — is
/// pure and deterministically testable via `AlembicCheck`.
///
/// Times are **session-relative audio seconds** (already converted from the Apple
/// `CMTimeRange` by the platform layer), or `nil` when the recognizer did not
/// attach an audio time range to this result.
public struct RecognizerResult: Sendable, Hashable {
    /// The recognized text for this result (already extracted from the
    /// recognizer's rich string).
    public let text: String

    /// `true` when the recognizer has committed this segment (`finalized`);
    /// `false` for an in-progress hypothesis (`volatile`).
    public let isFinal: Bool

    /// Session-relative audio start time in seconds, when the recognizer
    /// supplied an audio time range; otherwise `nil`.
    public let audioStart: Double?

    /// Session-relative audio end time in seconds, when the recognizer supplied
    /// an audio time range; otherwise `nil`.
    public let audioEnd: Double?

    /// Optional confidence in `[0, 1]` when the recognizer supplies one.
    public let confidence: Double?

    public init(
        text: String,
        isFinal: Bool,
        audioStart: Double? = nil,
        audioEnd: Double? = nil,
        confidence: Double? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.confidence = confidence
    }
}

/// Pure mapping from a `RecognizerResult` to a contract `TranscriptEvent`.
///
/// This is the deterministically testable heart of the engine's result path:
/// given a flattened recognizer result (and the fallback session-relative window
/// the engine has observed so far), it decides `kind`, stamps session-relative
/// `start`/`end`, attaches the engine's `source`, and records `"asr"`
/// attribution. No Apple types, no I/O — exercised directly by `AlembicCheck`.
public enum TranscriptEventMapper {

    /// Builds a `TranscriptEvent` from a recognizer result.
    ///
    /// - Parameters:
    ///   - result: the flattened recognizer result.
    ///   - source: the engine's `SourceTag` (`you`/`them`); stamped on the event.
    ///   - fallbackStart: session-relative start to use when the result carries
    ///     no audio range (typically the engine's current input cursor).
    ///   - fallbackEnd: session-relative end to use when the result carries no
    ///     audio range.
    /// - Returns: a `TranscriptEvent`, or `nil` when the trimmed text is empty
    ///   (empty hypotheses are never emitted or persisted).
    ///
    /// ### Timestamps
    /// Prefers the result's own audio range when present; otherwise falls back to
    /// the supplied session-relative window. `end` is clamped to be `>= start` so
    /// downstream consumers never see a negative-duration segment even if the
    /// recognizer reports a degenerate range.
    public static func event(
        from result: RecognizerResult,
        source: SourceTag,
        fallbackStart: Double,
        fallbackEnd: Double
    ) -> TranscriptEvent? {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let start = result.audioStart ?? fallbackStart
        let rawEnd = result.audioEnd ?? fallbackEnd
        let end = Swift.max(start, rawEnd)

        return TranscriptEvent(
            kind: result.isFinal ? .finalized : .volatile,
            source: source,
            start: start,
            end: end,
            text: trimmed,
            attribution: TranscriptAttribution(source: "asr", confidence: result.confidence)
        )
    }
}

/// A monotonic, session-relative audio-time cursor for feeding `AnalyzerInput`.
///
/// ## Why this exists
/// The engine must stamp each analyzer input with a **session-relative audio
/// time** (`AudioChunk.startTime`), never wall clock. This pure value type
/// centralizes — and makes testable — the gap/overlap policy:
///
/// - **Normal flow / silence gaps:** a chunk whose `startTime` is at or ahead of
///   the cursor is honored exactly, so genuine silence gaps are preserved on the
///   timeline (the analyzer sees the real elapsed audio time).
/// - **Overlap / dropped-buffer recovery / device changes:** a chunk whose
///   `startTime` is *behind* the cursor (out of order, or after a clock glitch)
///   is clamped to the cursor so audio time never moves backwards into the
///   analyzer, which would corrupt result ordering.
///
/// The cursor advances to the end of whichever window it returned.
public struct AudioInputCursor: Sendable, Equatable {
    /// The furthest session-relative audio time consumed so far, in seconds.
    public private(set) var lastEnd: Double

    public init(lastEnd: Double = 0) {
        self.lastEnd = lastEnd
    }

    /// Returns the session-relative `bufferStartTime` (seconds) to feed
    /// `AnalyzerInput` for `chunk`, applying the monotonic gap/overlap policy and
    /// advancing the cursor by the chunk's duration.
    public mutating func bufferStart(for chunk: AudioChunk) -> Double {
        let start = Swift.max(chunk.startTime, lastEnd)
        lastEnd = Swift.max(lastEnd, start + chunk.duration)
        return start
    }
}
