import Foundation

/// Pure, deterministic conversion of a fixed mono sample buffer into
/// session-relative `AudioChunk`s.
///
/// This is the platform-neutral core of the capture boundary's timestamp math,
/// factored out so it can be unit-checked without any hardware (the spike's
/// `feedFile` idea, made testable). The macOS source applies the *same* rule:
/// each chunk's `startTime` is `clock.sessionTime(forPlatformTime: P)` where `P`
/// is the platform (host-time) seconds of that chunk's first sample.
///
/// Given a contiguous mono buffer captured starting at platform time
/// `firstSamplePlatformTime`, sample `n` occurs at `firstSamplePlatformTime + n /
/// sampleRate`, so chunk `k` (of `framesPerChunk` samples) starts at platform
/// time `firstSamplePlatformTime + (k * framesPerChunk) / sampleRate`, mapped
/// through the clock.
public enum AudioChunkFactory {

    /// Slices `samples` into chunks of `framesPerChunk` and assigns each a
    /// session-relative `startTime` derived from the session clock.
    ///
    /// - Parameters:
    ///   - samples: contiguous mono normalized float PCM.
    ///   - sampleRate: sample rate in hertz (> 0).
    ///   - source: the `SourceTag` to stamp on every produced chunk.
    ///   - clock: the session clock providing the shared origin.
    ///   - firstSamplePlatformTime: platform (host-time) seconds of `samples[0]`.
    ///     Defaults to `clock.originSeconds` so the first chunk starts at `0`.
    ///   - framesPerChunk: chunk size in frames (> 0).
    /// - Returns: chunks in time order; the trailing chunk may be shorter.
    public static func chunks(
        fromMonoSamples samples: [Float],
        sampleRate: Double,
        source: SourceTag,
        clock: SessionClock,
        firstSamplePlatformTime: Double? = nil,
        framesPerChunk: Int
    ) -> [AudioChunk] {
        guard sampleRate > 0, framesPerChunk > 0, !samples.isEmpty else { return [] }
        let origin = firstSamplePlatformTime ?? clock.originSeconds
        var chunks: [AudioChunk] = []
        var start = 0
        while start < samples.count {
            let end = Swift.min(start + framesPerChunk, samples.count)
            let slice = Array(samples[start..<end])
            let platformTime = origin + Double(start) / sampleRate
            chunks.append(
                AudioChunk(
                    samples: slice,
                    sampleRate: sampleRate,
                    channelCount: 1,
                    source: source,
                    startTime: clock.sessionTime(forPlatformTime: platformTime)
                )
            )
            start = end
        }
        return chunks
    }
}
