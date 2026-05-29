import Foundation

/// Whether a transcript result is still being revised or has been committed.
///
/// - `volatile`:  an in-progress hypothesis that may change or be superseded;
///   safe to drop/coalesce for UI (see Phase 4 backpressure policy).
/// - `finalized`: a committed segment that will not change; this is what the
///   Phase 5 writer appends to the canonical `.jsonl`.
public enum TranscriptKind: String, Sendable, Codable, Hashable, CaseIterable {
    case volatile
    case finalized
}

/// Swappable provenance metadata for a `TranscriptEvent`.
///
/// Designed now, populated later. The Phase 2 contract ships `attribution` as an
/// **optional, additive** value type so later phases can attach speaker/source
/// provenance *without changing the contract*:
///
/// - `"asr"`     — the speech recognizer itself (default today).
/// - `"vision"`  — speaker attribution via Vision OCR (deferred; research §9
///   Approach C / Out of Scope).
/// - `"graph"`   — Microsoft Graph roster names (deferred).
///
/// Carrying a free-form `source: String` plus an optional `confidence` keeps the
/// field forward-compatible: new providers add new `source` tokens and richer
/// confidence without a schema break. `Codable` so it can ride along in the
/// canonical JSONL when present.
public struct TranscriptAttribution: Sendable, Codable, Hashable {
    /// Provider that produced this attribution (e.g. `"asr"`, `"vision"`,
    /// `"graph"`). Free-form by design so new providers don't break the schema.
    public let source: String

    /// Optional confidence in `[0, 1]`, when the provider supplies one.
    public let confidence: Double?

    public init(source: String, confidence: Double? = nil) {
        self.source = source
        self.confidence = confidence
    }
}

/// A transcription result emitted by a `TranscriptionEngine`.
///
/// Times are **session-relative seconds** (audio-time based via `SessionClock`),
/// matching `AudioChunk.startTime` and the canonical JSONL schema. Fully value
/// typed and therefore `Sendable`, so events flow from each engine's isolated
/// state to the orchestrator and writer across actor boundaries.
///
/// The whole type is `Codable`. Finalized events are what the Phase 5 writer
/// serializes; volatile events are typically UI-only. When a stable on-disk
/// schema is needed independent of this in-memory shape, `FinalizedSegmentDTO`
/// (below) provides it.
public struct TranscriptEvent: Sendable, Codable, Hashable, Identifiable {
    /// Stable identity for SwiftUI diffing of the live transcript. Not
    /// serialized as part of the canonical segment schema.
    public let id: UUID

    /// Whether this result is `volatile` (in-progress) or `finalized`.
    public let kind: TranscriptKind

    /// Which side of the conversation this text is attributed to.
    public let source: SourceTag

    /// Session-relative start time in seconds.
    public let start: Double

    /// Session-relative end time in seconds.
    public let end: Double

    /// The recognized text for this segment.
    public let text: String

    /// Optional, swappable provenance metadata (see `TranscriptAttribution`).
    /// `nil` until a provider populates it.
    public let attribution: TranscriptAttribution?

    public init(
        id: UUID = UUID(),
        kind: TranscriptKind,
        source: SourceTag,
        start: Double,
        end: Double,
        text: String,
        attribution: TranscriptAttribution? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.start = start
        self.end = end
        self.text = text
        self.attribution = attribution
    }
}

/// Canonical on-disk shape for a **finalized** transcript segment.
///
/// This is the data transfer object the Phase 5 writer appends to the canonical
/// `.jsonl` (one segment per line). It is deliberately decoupled from
/// `TranscriptEvent` so the on-disk schema can evolve independently of the
/// in-memory/UI model: it carries an explicit `schemaVersion`, omits UI-only
/// fields like `id` and `kind`, and uses stable key names.
public struct FinalizedSegmentDTO: Sendable, Codable, Hashable {
    /// Schema version of the canonical JSONL line. Bump on breaking changes.
    public let schemaVersion: Int

    /// Session-relative start time in seconds.
    public let start: Double

    /// Session-relative end time in seconds.
    public let end: Double

    /// Which side of the conversation this text is attributed to.
    public let source: SourceTag

    /// The finalized text for this segment.
    public let text: String

    /// Optional provenance metadata; omitted from JSON when `nil`.
    public let attribution: TranscriptAttribution?

    /// The current canonical schema version.
    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = FinalizedSegmentDTO.currentSchemaVersion,
        start: Double,
        end: Double,
        source: SourceTag,
        text: String,
        attribution: TranscriptAttribution? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.start = start
        self.end = end
        self.source = source
        self.text = text
        self.attribution = attribution
    }

    /// Builds the canonical DTO from a finalized `TranscriptEvent`.
    ///
    /// - Precondition (debug only): `event.kind == .finalized`. Volatile events
    ///   should not be persisted to the canonical transcript.
    public init(event: TranscriptEvent, schemaVersion: Int = FinalizedSegmentDTO.currentSchemaVersion) {
        assert(event.kind == .finalized, "Only finalized events belong in the canonical transcript")
        self.init(
            schemaVersion: schemaVersion,
            start: event.start,
            end: event.end,
            source: event.source,
            text: event.text,
            attribution: event.attribution
        )
    }
}
