import Foundation

/// A platform-neutral source of captured audio.
///
/// Implementations isolate all platform specifics behind this contract so the
/// orchestrator, persistence, and UI never touch ScreenCaptureKit/AVFoundation.
/// On macOS this is `ScreenCaptureKitSource` (Phase 3); a future Windows port
/// supplies a WASAPI-loopback implementation against the same protocol.
///
/// ### Concurrency
/// The protocol refines `Sendable` so a source can be created off the main actor
/// and shared with the `@MainActor` orchestrator. Implementations own their
/// mutable capture state behind an actor / serial executor and must convert
/// non-`Sendable` Apple buffers into `Sendable` `AudioChunk`s *before* yielding
/// them on `buffers`, so nothing Apple-specific crosses an actor boundary.
///
/// All produced timestamps are session-relative (see `SessionClock`).
public protocol AudioSource: Sendable {
    /// Enumerates the capturable targets (e.g. running apps such as Teams) the
    /// user can choose from. May prompt for / require capture authorization.
    func availableTargets() async throws -> [CaptureTarget]

    /// Begins capturing audio for the given target. The implementation maps the
    /// target's audio (and, for the macOS source, the local mic) into tagged
    /// `AudioChunk`s delivered via `buffers`.
    func start(target: CaptureTarget) async throws

    /// The stream of captured audio chunks, each tagged with its `SourceTag`.
    ///
    /// A single stream multiplexes both sides ("you" and "them"); consumers
    /// route by `AudioChunk.source`. The stream finishes after `stop()`.
    var buffers: AsyncStream<AudioChunk> { get }

    /// Stops capture and finishes the `buffers` stream. Idempotent.
    func stop() async
}
