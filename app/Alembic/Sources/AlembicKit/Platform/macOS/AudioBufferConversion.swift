import Foundation
import AVFoundation
import CoreMedia

/// Conversion from non-`Sendable` Apple audio buffers to plain mono `[Float]`,
/// performed **at the capture callback boundary** so nothing Apple-specific ever
/// crosses an actor boundary (the Swift 6 isolation rule from the plan).
///
/// All channel-extraction + downmix delegates to the pure `AudioMath` helpers in
/// the core, which is where the deterministic checks live. These functions only
/// own the Apple-buffer plumbing (reading `CMBlockBuffer` bytes, interpreting the
/// `AudioStreamBasicDescription` flags, indexing `floatChannelData`).
enum AudioBufferConversion {

    /// A decoded audio block: mono normalized float samples plus the metadata the
    /// `AudioChunk` needs and the presentation time used for session-relative
    /// timestamping.
    struct DecodedBlock {
        let monoSamples: [Float]
        let sampleRate: Double
        let originalChannelCount: Int
        /// Host-time presentation seconds (`CMTimeGetSeconds`), or `nil` for the
        /// mic path which carries its time separately via `AVAudioTime`.
        let presentationSeconds: Double?
    }

    /// Decode an `SCStream` audio `CMSampleBuffer` into a mono block.
    ///
    /// Handles both interleaved and non-interleaved layouts by inspecting
    /// `kAudioFormatFlagIsNonInterleaved` (the helper's `flags=0x29` stereo case
    /// is non-interleaved). Returns `nil` if the buffer cannot be read.
    static func decode(sampleBuffer: CMSampleBuffer) -> DecodedBlock? {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let channelCount = Int(asbd.mChannelsPerFrame)
        let sampleRate = asbd.mSampleRate
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard channelCount > 0 else { return nil }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let mono: [Float] = data.withUnsafeBytes { raw -> [Float] in
            let floats = raw.bindMemory(to: Float.self)
            // Guard against truncated buffers.
            let available = floats.count
            guard available >= frameCount * channelCount else {
                return []
            }
            if channelCount == 1 {
                return Array(floats.prefix(frameCount))
            }
            if nonInterleaved {
                var channels = [[Float]]()
                channels.reserveCapacity(channelCount)
                for ch in 0..<channelCount {
                    let start = ch * frameCount
                    channels.append(Array(floats[start..<(start + frameCount)]))
                }
                return AudioMath.downmixChannelsToMono(channels)
            } else {
                let interleaved = Array(floats[0..<(frameCount * channelCount)])
                return AudioMath.downmixInterleavedToMono(interleaved, channelCount: channelCount)
            }
        }
        guard !mono.isEmpty else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsSeconds = pts.isValid ? CMTimeGetSeconds(pts) : nil

        return DecodedBlock(
            monoSamples: mono,
            sampleRate: sampleRate,
            originalChannelCount: channelCount,
            presentationSeconds: ptsSeconds
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
