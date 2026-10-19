import Foundation

/// Keeps one capture stream on a single gap-free, overlap-free timeline that
/// starts at session time 0.
///
/// `SpeechAnalyzer` timestamps results by the amount of audio it has been fed
/// (inputs are deliberately untimed — see `SpeechAnalyzerEngine.append`), so
/// each source must deliver **contiguous** audio anchored at session time 0
/// for its transcript times to be session times — and for "you" and "them"
/// to line up with each other. Capture never starts exactly at 0 (target
/// lookup, tap setup, and engine start come first), a Core Audio process tap
/// delivers nothing until the app actually produces sound, and the mic can
/// pause across an input-device change. This type restores contiguity, and
/// both the mic path and the meeting-audio tap use it:
///
/// - `fillSilence(through:sampleRate:)`, driven by a heartbeat, advances the
///   timeline with silence in real time while the capture delivers nothing.
/// - `place(_:sampleRate:at:)` positions captured samples: a gap since the
///   cursor is filled with silence first, and a head that overlaps audio
///   already emitted (silence padded just before the audio arrived) is trimmed.
///   Differences within `tolerance` are absorbed as clock jitter.
/// - A gap longer than `maxGap` (the machine slept, or the heartbeat stalled)
///   is not padded — that would mean allocating minutes or hours of silence.
///   The timeline instead skips ahead (`skew`), compressing the gap exactly as
///   the microphone path does across sleep, so both sides stay aligned.
///
/// Pure and Foundation-only; exercised by `AlembicCheck`.
public struct ContiguousAudioTimeline: Sendable {

    /// One run of samples to emit, positioned on the contiguous timeline.
    public struct Segment: Sendable, Equatable {
        public let samples: [Float]
        public let sampleRate: Double
        /// Session seconds at which `samples` begins on the contiguous timeline.
        public let start: Double
        /// `true` for padding the timeline synthesized, `false` for captured audio.
        public let isSilence: Bool
    }

    /// Session seconds of audio emitted so far (the next segment's start).
    public private(set) var cursor: Double = 0
    /// Total gap time skipped instead of padded (sleep / stalls).
    public private(set) var skew: Double = 0

    public let tolerance: Double
    public let maxGap: Double

    public init(tolerance: Double = 0.02, maxGap: Double = 10) {
        self.tolerance = tolerance
        self.maxGap = maxGap
    }

    /// Positions captured `samples` that began at session time `start` and
    /// returns the segments to emit, in order: silence filling any gap since
    /// the cursor, then the samples minus any head already covered.
    public mutating func place(_ samples: [Float], sampleRate: Double, at start: Double) -> [Segment] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        let effectiveStart = start - skew
        var segments: [Segment] = []

        if effectiveStart > cursor + maxGap {
            skew += effectiveStart - cursor
        } else if effectiveStart > cursor + tolerance,
                  let gap = fillSilence(through: start, sampleRate: sampleRate) {
            segments.append(gap)
        }

        var body = samples
        if effectiveStart < cursor - tolerance {
            let overlap = Int(((cursor - effectiveStart) * sampleRate).rounded())
            guard overlap < body.count else { return segments }
            body.removeFirst(overlap)
        }
        segments.append(Segment(samples: body, sampleRate: sampleRate, start: cursor, isSilence: false))
        cursor += Double(body.count) / sampleRate
        return segments
    }

    /// Silence covering the timeline from the cursor up to session time
    /// `time`, or `nil` when the cursor is already there. A gap beyond
    /// `maxGap` is skipped (see the type docs) rather than padded.
    public mutating func fillSilence(through time: Double, sampleRate: Double) -> Segment? {
        guard sampleRate > 0 else { return nil }
        let effectiveTime = time - skew
        guard effectiveTime > cursor else { return nil }
        if effectiveTime - cursor > maxGap {
            skew += effectiveTime - cursor
            return nil
        }
        let count = Int(((effectiveTime - cursor) * sampleRate).rounded())
        guard count > 0 else { return nil }
        let segment = Segment(
            samples: [Float](repeating: 0, count: count),
            sampleRate: sampleRate,
            start: cursor,
            isSilence: true
        )
        cursor += Double(count) / sampleRate
        return segment
    }
}
