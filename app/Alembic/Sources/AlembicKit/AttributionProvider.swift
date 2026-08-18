import Foundation

/// Foundation-only, `Sendable` query surface for resolving a display name for a
/// finalized `.them` segment's session-relative time window (SR-1).
///
/// Implementations MUST be best-effort and MUST return promptly: `ingest` awaits
/// this call inline on the finalized-event path (Phase 3, SR-17), so an
/// implementation that blocks indefinitely would delay `MeetingSession.stop()`'s
/// drain. Implementations MUST NOT throw for expected "no signal" conditions
/// (missing frame, OCR miss, app not catalogued, timeline below threshold) —
/// return `nil` instead (NR-6). Implementations MAY apply their own internal
/// timeout and return `nil` on expiry.
public protocol AttributionProvider: Sendable {
    /// Resolves a display name + confidence for the `.them` segment spanning
    /// `window` (session-relative seconds, same basis as `TranscriptEvent.start`/
    /// `.end`). Returns `nil` when no name can be determined at or above the
    /// provider's acceptance thresholds.
    func attribution(forThemSegment window: ClosedRange<Double>) async -> SpeakerAttributionResult?
}

/// A resolved `(displayName, confidence)` pair from an `AttributionProvider`.
/// Kept distinct from `TranscriptAttribution` (the on-disk shape): this is the
/// provider's raw output before Phase 3 wraps it as
/// `TranscriptAttribution(source: "vision", confidence:, displayName:)`.
public struct SpeakerAttributionResult: Sendable, Equatable {
    /// Normalized display name (already passed through `SpeakerNameNormalizer`
    /// by the producer — this type does not itself normalize).
    public let displayName: String
    /// Confidence, always in `[0, 1]` (DR-3). `init` **clamps** rather than
    /// rejects: a provider is best-effort (see the protocol doc) and a
    /// slightly out-of-range raw score (e.g. a Vision confidence the caller
    /// forgot to normalize) must not crash or silently propagate an invalid
    /// value into `TranscriptAttribution` once Phase 3 wraps this type —
    /// clamping keeps the invariant unconditionally true at the type
    /// boundary with no failable/throwing init to thread through every call
    /// site.
    public let confidence: Double

    public init(displayName: String, confidence: Double) {
        self.displayName = displayName
        self.confidence = confidence.clamped(to: 0...1)
    }
}

/// Clamps `self` into `range`. Used everywhere this phase enforces DR-3's
/// `confidence ∈ [0, 1]` invariant and non-negative timing configuration —
/// clamping (not throwing/failing) keeps every affected initializer a plain,
/// non-failable `init`. Declared `fileprivate` (not `private`) so this file
/// stays self-contained; `ActiveSpeakerTimeline.swift` declares its own copy
/// rather than sharing an internal API across files.
///
/// A non-finite input (`NaN`, `+.infinity`, `-.infinity`) is sanitized to
/// `range.lowerBound` **before** the min/max clamp runs (Phase 3 §0.1/§0.2
/// remediation of the Phase 2 impl-review-1 MEDIUM finding): plain min/max
/// clamping never touches `NaN`, because every comparison against `NaN`
/// evaluates `false`, so `NaN` would otherwise pass through unclamped and
/// violate the "confidence is always finite and in range" invariant this
/// helper exists to guarantee. Mapping to `range.lowerBound` (`0` for every
/// call site in this file) rather than failing keeps every affected `init`
/// non-failable, and `0` is the safe, conservative value — it can never
/// itself clear a `> 0` threshold, so a non-finite input degrades to
/// "definitely below threshold" rather than silently passing.
fileprivate extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard self.isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Deterministic, hardware-free `AttributionProvider` test double.
///
/// Scripted by exact window match (`ClosedRange<Double>` is `Equatable`, so a
/// dictionary keyed by the caller's exact window works for the fixed windows
/// Phase 3's tests construct). Records every queried window so tests can
/// assert `.you`/volatile events never reach the provider (SR-15).
///
/// An `actor` (not a plain struct) because `queriedWindows` is caller-visible
/// mutable state that must be safely readable after an async test body awaits
/// it — same reasoning `FakeTranscriptionEngine` documents for its
/// `appendedChunks`.
public actor FakeAttributionProvider: AttributionProvider {
    private let script: [ClosedRange<Double>: SpeakerAttributionResult?]
    /// Result returned for a window with no exact script entry. Defaults to
    /// `nil` (no attribution) — the safe default matching NR-6.
    private let defaultResult: SpeakerAttributionResult?
    public private(set) var queriedWindows: [ClosedRange<Double>] = []

    public init(
        script: [ClosedRange<Double>: SpeakerAttributionResult?] = [:],
        defaultResult: SpeakerAttributionResult? = nil
    ) {
        self.script = script
        self.defaultResult = defaultResult
    }

    public func attribution(forThemSegment window: ClosedRange<Double>) async -> SpeakerAttributionResult? {
        queriedWindows.append(window)
        if let scripted = script[window] { return scripted }
        return defaultResult
    }
}


// Phase 7 §3b: the synthetic hang/block/timeout test doubles
// (`SlowAttributionProvider`, `HangingAttributionProvider`,
// `NonCooperativeAttributionProvider`, `GatedAttributionProvider`, plus their
// private `LockedCounter`/`OneShotSignal` helpers) that used to live below
// this line have been relocated to
// `Sources/AlembicCheck/TestAttributionProviders.swift` (Phase 3 impl-review-1
// MEDIUM finding: synthetic hang/block machinery does not belong in
// `AlembicKit`'s shipped public API). `FakeAttributionProvider` above — the
// minimal, non-blocking scripted double — is the only attribution-provider
// test double this file still declares.
