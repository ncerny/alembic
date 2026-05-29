import Foundation

/// A point-in-time input-level reading for one audio source.
///
/// Platform-neutral and `Sendable` so the capture boundary (Phase 3) can compute
/// it from a mono `[Float]` block and ship it to the `@MainActor` UI (Phases
/// 6/7) without exposing any Apple meter types. Both values are in the same units
/// as the underlying normalized PCM samples (roughly `[0, 1]`).
public struct MeterLevel: Sendable, Hashable {
    /// Root-mean-square (average) level — good for a smooth VU-style meter.
    public let rms: Float

    /// Peak absolute amplitude over the block — good for clip indication.
    public let peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    /// Silence (both `rms` and `peak` are `0`).
    public static let silent = MeterLevel(rms: 0, peak: 0)

    /// Computes the level of a mono sample block using `AudioMath`.
    public static func measuring(_ samples: [Float]) -> MeterLevel {
        MeterLevel(rms: AudioMath.rms(samples), peak: AudioMath.peak(samples))
    }
}

/// A meter reading tagged with the source it came from.
///
/// Sources expose an `AsyncStream<MeterUpdate>` so the orchestrator/UI can render
/// independent live meters for the local mic (`.you`) and the meeting audio
/// (`.them`) without reaching into capture internals. Designed now (Phase 3),
/// consumed later (Phases 6/7).
public struct MeterUpdate: Sendable, Hashable {
    /// Which side of the conversation this reading describes.
    public let source: SourceTag

    /// The level measured for the most recent audio block from `source`.
    public let level: MeterLevel

    public init(source: SourceTag, level: MeterLevel) {
        self.source = source
        self.level = level
    }
}
