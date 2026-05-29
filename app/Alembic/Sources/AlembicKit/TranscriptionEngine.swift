import Foundation

/// A platform-neutral streaming transcription engine.
///
/// One engine instance is created per source ("you" and "them") for full
/// isolation — no shared analyzer/converter state. The engine consumes
/// platform-neutral `AudioChunk`s and converts them to whatever the underlying
/// recognizer needs *internally* (Phase 4: a persistent AVFoundation audio
/// converter feeding `SpeechAnalyzer`/`SpeechTranscriber`), so the contract
/// stays Apple-free.
///
/// ### Concurrency
/// Refines `Sendable` so engines can be owned by the `@MainActor` orchestrator
/// yet run their recognition off the main actor. Implementations keep mutable
/// recognizer state behind an actor / serial executor and must never `await`
/// the analyzer from an audio callback thread.
///
/// All emitted `TranscriptEvent` times are session-relative audio time (see
/// `SessionClock`), not wall clock.
public protocol TranscriptionEngine: Sendable {
    /// Prepares the engine (loads/validates models, builds the analyzer). Assets
    /// are expected to be preflighted once by a shared manager before start.
    func start() async throws

    /// Feeds a platform-neutral audio chunk for transcription. The
    /// implementation converts to its native buffer/format internally. Should
    /// not block the caller's audio path.
    func append(_ chunk: AudioChunk) async

    /// The stream of transcription results: `volatile` hypotheses followed by
    /// `finalized` segments. Finishes after `finish()` has fully drained.
    var results: AsyncStream<TranscriptEvent> { get }

    /// Signals end of input and drains remaining results: finalizes any pending
    /// segment and finishes the `results` stream. Await completion before
    /// treating the transcript as complete.
    func finish() async
}
