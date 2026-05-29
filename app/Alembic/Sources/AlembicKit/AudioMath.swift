import Foundation

/// Pure, hardware-free audio sample math shared by every platform source.
///
/// These helpers are deliberately platform-neutral (`[Float]` in, `[Float]` /
/// `Float` out) and Foundation-only so they can be unit-checked deterministically
/// by `AlembicCheck` without touching ScreenCaptureKit / AVFoundation. The macOS
/// capture boundary (Phase 3) extracts raw float channels from Apple buffers and
/// then delegates the actual mixing/metering to these functions.
public enum AudioMath {

    // MARK: - Metering

    /// Root-mean-square level of a mono sample block, in the same units as the
    /// samples (roughly `[0, 1]` for normalized PCM). Returns `0` for empty input.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Double = 0
        for s in samples { sumOfSquares += Double(s) * Double(s) }
        return Float((sumOfSquares / Double(samples.count)).squareRoot())
    }

    /// Peak absolute amplitude of a mono sample block. Returns `0` for empty input.
    public static func peak(_ samples: [Float]) -> Float {
        var peak: Float = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
        }
        return peak
    }

    // MARK: - Downmix

    /// Downmix **interleaved** multi-channel float PCM to mono by averaging the
    /// channels of each frame.
    ///
    /// Interleaved layout means samples alternate per channel:
    /// `[c0f0, c1f0, c0f1, c1f1, …]`. This mirrors the capture path used when an
    /// `SCStream` / mic buffer reports `kAudioFormatFlagIsNonInterleaved == 0`.
    ///
    /// - Parameters:
    ///   - interleaved: the raw interleaved sample buffer.
    ///   - channelCount: number of channels (>= 1). Values <= 1 return the input
    ///     unchanged.
    public static func downmixInterleavedToMono(_ interleaved: [Float], channelCount: Int) -> [Float] {
        guard channelCount > 1 else { return interleaved }
        let frames = interleaved.count / channelCount
        guard frames > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        let inv = Float(1) / Float(channelCount)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = frame * channelCount
            for ch in 0..<channelCount { sum += interleaved[base + ch] }
            mono[frame] = sum * inv
        }
        return mono
    }

    /// Downmix **non-interleaved** (channel-major) float PCM to mono by averaging
    /// the per-frame value across channels.
    ///
    /// `channels[c]` holds all frames for channel `c` (the layout an
    /// `SCStream` reports when `kAudioFormatFlagIsNonInterleaved` is set, e.g.
    /// the helper's `flags=0x29` stereo case). All channels are expected to be the
    /// same length; the shortest channel bounds the frame count defensively.
    public static func downmixChannelsToMono(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let frames = channels.reduce(first.count) { Swift.min($0, $1.count) }
        guard frames > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        let inv = Float(1) / Float(channels.count)
        for frame in 0..<frames {
            var sum: Float = 0
            for ch in channels { sum += ch[frame] }
            mono[frame] = sum * inv
        }
        return mono
    }
}
