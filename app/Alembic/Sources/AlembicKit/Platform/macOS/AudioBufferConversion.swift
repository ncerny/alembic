import Foundation
import AVFoundation
import CoreAudio

/// Conversion from non-`Sendable` Apple audio buffers to plain mono `[Float]`,
/// performed **at the capture callback boundary** so nothing Apple-specific ever
/// crosses an actor boundary (the Swift 6 isolation rule from the plan).
///
/// All channel-extraction + downmix delegates to the pure `AudioMath` helpers in
/// the core, which is where the deterministic checks live. These functions only
/// own the Apple-buffer plumbing (walking an `AudioBufferList`, indexing
/// `floatChannelData`).
enum AudioBufferConversion {

    /// A decoded audio block: mono normalized float samples plus the metadata the
    /// `AudioChunk` needs and the presentation time used for session-relative
    /// timestamping.
    struct DecodedBlock {
        let monoSamples: [Float]
        let sampleRate: Double
        let originalChannelCount: Int
        /// Host-time seconds of the block's first frame (the tap IOProc's input
        /// timestamp), or `nil` for the mic path, which carries its time
        /// separately via `AVAudioTime`.
        let presentationSeconds: Double?
    }

    /// Decode a process-tap `AudioBufferList` (Float32 PCM, as delivered to the
    /// aggregate device's IOProc) into a mono block.
    ///
    /// Reads each buffer's samples and `mNumberChannels` and delegates the
    /// layout-agnostic downmix to `AudioMath.downmixBuffersToMono`, so one
    /// interleaved buffer and N non-interleaved buffers both decode correctly.
    /// Returns `nil` when the list carries no samples.
    static func decode(
        bufferList: UnsafePointer<AudioBufferList>,
        sampleRate: Double,
        hostSeconds: Double?
    ) -> DecodedBlock? {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var buffers: [(samples: [Float], channelCount: Int)] = []
        var channelCount = 0
        for buffer in list {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let channels = max(Int(buffer.mNumberChannels), 1)
            buffers.append((
                samples: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)),
                channelCount: channels
            ))
            channelCount += channels
        }
        let mono = AudioMath.downmixBuffersToMono(buffers)
        guard !mono.isEmpty, sampleRate > 0 else { return nil }
        return DecodedBlock(
            monoSamples: mono,
            sampleRate: sampleRate,
            originalChannelCount: channelCount,
            presentationSeconds: hostSeconds
        )
    }

    /// Decode an `AVAudioPCMBuffer` from the mic tap into a mono block.
    ///
    /// `AVAudioPCMBuffer.floatChannelData` is always non-interleaved (channel
    /// pointers), so we extract per-channel arrays and downmix via `AudioMath`.
    static func decode(pcmBuffer: AVAudioPCMBuffer) -> DecodedBlock? {
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0, let channelData = pcmBuffer.floatChannelData else { return nil }
        let channelCount = Int(pcmBuffer.format.channelCount)
        guard channelCount > 0 else { return nil }

        let mono: [Float]
        if channelCount == 1 {
            mono = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        } else {
            var channels = [[Float]]()
            channels.reserveCapacity(channelCount)
            for ch in 0..<channelCount {
                channels.append(Array(UnsafeBufferPointer(start: channelData[ch], count: frames)))
            }
            mono = AudioMath.downmixChannelsToMono(channels)
        }
        guard !mono.isEmpty else { return nil }

        return DecodedBlock(
            monoSamples: mono,
            sampleRate: pcmBuffer.format.sampleRate,
            originalChannelCount: channelCount,
            presentationSeconds: nil
        )
    }
}
