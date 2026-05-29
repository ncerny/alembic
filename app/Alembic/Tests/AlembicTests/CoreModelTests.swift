import Foundation
import Testing
import AlembicKit

/// Phase 2 tests: exercise the platform-agnostic core models. These run without
/// any live capture/recognition and validate construction, raw values, and the
/// canonical `Codable` round-trips the Phase 5 writer relies on.
struct CoreModelTests {
    // MARK: SourceTag

    @Test
    func sourceTagRawValuesAreStable() {
        #expect(SourceTag.you.rawValue == "you")
        #expect(SourceTag.them.rawValue == "them")
        #expect(SourceTag.allCases.count == 2)
    }

    @Test
    func sourceTagRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(SourceTag.them)
        let decoded = try JSONDecoder().decode(SourceTag.self, from: data)
        #expect(decoded == .them)
        // String-backed: encodes to a bare JSON string.
        #expect(String(data: data, encoding: .utf8) == "\"them\"")
    }

    // MARK: AudioChunk

    @Test
    func audioChunkComputesDurationAndEndTime() {
        let chunk = AudioChunk(
            samples: Array(repeating: 0, count: 480),
            sampleRate: 48_000,
            channelCount: 2,
            source: .you,
            startTime: 1.5
        )
        // 480 samples at 48kHz = 0.01s
        #expect(abs(chunk.duration - 0.01) < 1e-9)
        #expect(abs(chunk.endTime - 1.51) < 1e-9)
        #expect(chunk.source == .you)
        #expect(chunk.channelCount == 2)
    }

    @Test
    func audioChunkDurationIsZeroForNonPositiveSampleRate() {
        let chunk = AudioChunk(samples: [0, 0, 0], sampleRate: 0, channelCount: 1, source: .them, startTime: 0)
        #expect(chunk.duration == 0)
        #expect(chunk.endTime == 0)
    }

    // MARK: SessionClock

    @Test
    func sessionClockProducesSessionRelativeTime() {
        let clock = SessionClock(originSeconds: 100)
        #expect(clock.sessionTime(forPlatformTime: 102.5) == 2.5)
        // Default origin is zero.
        #expect(SessionClock().sessionTime(forPlatformTime: 7) == 7)
    }

    // MARK: TranscriptEvent + attribution

    @Test
    func transcriptEventCarriesSwappableAttribution() {
        let event = TranscriptEvent(
            kind: .finalized,
            source: .them,
            start: 0,
            end: 1,
            text: "hello",
            attribution: TranscriptAttribution(source: "asr", confidence: 0.92)
        )
        #expect(event.attribution?.source == "asr")
        #expect(event.attribution?.confidence == 0.92)

        // Attribution is optional / additive: defaults to nil.
        let bare = TranscriptEvent(kind: .volatile, source: .you, start: 0, end: 0.5, text: "hi")
        #expect(bare.attribution == nil)
    }

    @Test
    func transcriptEventRoundTripsThroughCodable() throws {
        let event = TranscriptEvent(
            kind: .finalized,
            source: .you,
            start: 1.0,
            end: 2.0,
            text: "round trip",
            attribution: TranscriptAttribution(source: "vision", confidence: nil)
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: data)
        #expect(decoded == event)
        #expect(decoded.attribution?.source == "vision")
    }

    // MARK: FinalizedSegmentDTO (canonical JSONL shape)

    @Test
    func finalizedSegmentDTORoundTripsThroughCodable() throws {
        let dto = FinalizedSegmentDTO(
            start: 3.25,
            end: 4.75,
            source: .them,
            text: "canonical line",
            attribution: TranscriptAttribution(source: "asr", confidence: 0.8)
        )
        let data = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(FinalizedSegmentDTO.self, from: data)
        #expect(decoded == dto)
        #expect(decoded.schemaVersion == FinalizedSegmentDTO.currentSchemaVersion)
    }

    @Test
    func finalizedSegmentDTODerivesFromFinalizedEvent() {
        let event = TranscriptEvent(kind: .finalized, source: .you, start: 5, end: 6, text: "done")
        let dto = FinalizedSegmentDTO(event: event)
        #expect(dto.start == 5)
        #expect(dto.end == 6)
        #expect(dto.source == .you)
        #expect(dto.text == "done")
        #expect(dto.schemaVersion == FinalizedSegmentDTO.currentSchemaVersion)
    }

    // MARK: CaptureTarget

    @Test
    func captureTargetIsIdentifiableAndHashable() {
        let a = CaptureTarget(id: "com.microsoft.teams2", displayName: "Microsoft Teams")
        let b = CaptureTarget(id: "com.microsoft.teams2", displayName: "Microsoft Teams")
        #expect(a == b)
        #expect(a.id == "com.microsoft.teams2")
        #expect(a.iconData == nil)
        #expect(Set([a, b]).count == 1)
    }
}
