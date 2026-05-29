import Foundation

/// A platform-neutral block of captured audio.
///
/// This is the **portability boundary** of Alembic: non-`Sendable` Apple
/// audio-buffer types and audio/media time types are
/// converted/copied into an `AudioChunk` at the capture boundary (Phase 3) so
/// nothing Apple-specific crosses an actor boundary. A future Windows source can
/// produce the exact same type from WASAPI loopback.
///
/// ### Sample format
/// `samples` are **mono**, **normalized 32-bit float** PCM in roughly `[-1, 1]`.
/// Stereo/interleaved sources must downmix before constructing a chunk;
/// `channelCount` records the *original* channel count for diagnostics but
/// `samples` is always a single mono channel.
///
/// ### Timestamp representation (one chosen representation)
/// `startTime` is the **session-relative start time in seconds** (a plain
/// `Double`), derived from audio time via `SessionClock` — *not* wall clock.
/// We use seconds (not nanoseconds) to match `TranscriptEvent.start`/`.end` and
/// the canonical JSONL schema, keeping one consistent unit across the contract.
///
/// `Sendable` by construction (`[Float]`, `Double`, `Int`, `SourceTag` are all
/// value types), so chunks move freely from the capture actor to each engine.
public struct AudioChunk: Sendable, Hashable {
    /// Mono, normalized 32-bit float PCM samples (approximately `[-1, 1]`).
    public let samples: [Float]

    /// Sample rate in hertz (e.g. `48000`, `16000`).
    public let sampleRate: Double

    /// Original channel count of the captured audio prior to mono downmix.
    /// `samples` itself is always a single mono channel.
    public let channelCount: Int

    /// Which side of the conversation produced this audio.
    public let source: SourceTag

    /// Session-relative start time, in seconds, of the first sample in
    /// `samples`. Derived from audio time via `SessionClock`; never wall clock.
    public let startTime: Double

    public init(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        source: SourceTag,
        startTime: Double
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.source = source
        self.startTime = startTime
    }

    /// Duration of the chunk in seconds, derived from sample count and rate.
    /// Returns `0` when `sampleRate` is non-positive.
    public var duration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    /// Session-relative end time, in seconds (`startTime + duration`).
    public var endTime: Double {
        startTime + duration
    }
}
