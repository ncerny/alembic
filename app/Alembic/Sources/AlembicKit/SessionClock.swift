import Foundation

/// The single per-session time origin for an Alembic recording session.
///
/// ## Why this exists
/// Every `AudioChunk` and `TranscriptEvent` timestamp in the platform-agnostic
/// core is **session-relative** — measured in seconds from one fixed origin per
/// session — *not* wall-clock time. This guarantees that the two independent
/// pipelines ("you" and "them") can be merged onto a single timeline, and that
/// transcripts are reproducible regardless of when they were captured.
///
/// ## The contract (mapping rules live in Phases 3/4)
/// `SessionClock` itself holds only the origin and the conventions. The actual
/// mapping from Apple time types to session-relative seconds is implemented in
/// the platform sources:
///
/// - **macOS AudioSource (Phase 3):** derive each chunk's `startTime` from
///   sample-buffer presentation time (ScreenCaptureKit) and audio host/sample
///   time (mic), each subtracting this clock's origin so both
///   streams share one zero point.
/// - **macOS TranscriptionEngine (Phase 4):** feed `AnalyzerInput` with
///   session-relative times so `start`/`end` on `TranscriptEvent` are audio-time
///   based, not wall-clock based.
///
/// Deliberately Apple-free: the origin is stored as a plain `Double`/`Int64`
/// host reference, never an Apple audio/media time type. Implementations
/// capture the
/// platform time at session start and convert through this type's helpers.
///
/// `Sendable` so the clock can be shared (read-only) across the capture actor,
/// the engines, and the orchestrator.
public struct SessionClock: Sendable, Hashable {
    /// The session's time origin expressed as a platform-neutral reference in
    /// seconds.
    ///
    /// This is whatever monotonic reference the platform source chooses (e.g.
    /// mach host time converted to seconds). Its absolute value is meaningless
    /// outside the session; only differences from it matter. All public
    /// timestamps in the core are computed as `platformTime - originSeconds`.
    public let originSeconds: Double

    /// Creates a clock anchored at the given platform-neutral origin (seconds).
    ///
    /// - Parameter originSeconds: The monotonic reference captured at session
    ///   start. Defaults to `0`, which is useful for tests and replay sources
    ///   whose inputs are already session-relative.
    public init(originSeconds: Double = 0) {
        self.originSeconds = originSeconds
    }

    /// Converts a platform-neutral absolute time (seconds) into a
    /// session-relative time (seconds from the origin).
    ///
    /// Implementations in Phases 3/4 call this after converting their Apple time
    /// type to seconds, keeping all Apple specifics out
    /// of the core.
    public func sessionTime(forPlatformTime platformSeconds: Double) -> Double {
        platformSeconds - originSeconds
    }
}
