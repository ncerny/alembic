import Foundation

/// A deterministic, hardware-free `TranscriptionEngine` test seam.
///
/// ## Why this exists
/// The real macOS engine (`SpeechAnalyzerEngine`) needs speech models and a
/// runtime that cannot run headlessly, so it can only be *compile*-verified under
/// Command Line Tools. The Phase 6 orchestrator, however, must be testable for
/// real: source→engine routing, volatile-vs-finalized handling, and the
/// drain-on-finish handshake. `FakeTranscriptionEngine` emits a *scripted*
/// sequence of `TranscriptEvent`s and finishes its `results` stream only after
/// `finish()` drains — exactly the contract Phase 6 depends on.
///
/// Lives in `AlembicKit` (not `Platform/macOS`) because it is platform-neutral
/// and used by `AlembicCheck`.
///
/// ## Behaviour
/// - `start()` records that the engine started (a second call is a no-op).
/// - `append(_:)` is accepted but does not influence output — the script is the
///   single source of truth so tests stay deterministic regardless of timing.
/// - `results` delivers the scripted events **in order**, then stays open until
///   `finish()`.
/// - `finish()` yields any not-yet-emitted scripted events (the "drain"), then
///   finishes `results`. Idempotent.
///
/// Modeled as an `actor` so its lifecycle state is isolated and the type
/// satisfies `TranscriptionEngine: Sendable` without locks.
public actor FakeTranscriptionEngine: TranscriptionEngine {
    public nonisolated let results: AsyncStream<TranscriptEvent>
    private let continuation: AsyncStream<TranscriptEvent>.Continuation

    private let script: [TranscriptEvent]
    /// When `true`, `start()` emits the whole script immediately; when `false`,
    /// the script is held back and flushed by `finish()` (models a stop drain
    /// that releases buffered finalized text).
    private let emitOnStart: Bool

    private var nextIndex = 0
    private var didStart = false
    private var didFinish = false

    /// Records each chunk handed to `append`, so orchestrator tests can assert
    /// the engine was actually fed.
    public private(set) var appendedChunks: [AudioChunk] = []

    /// - Parameters:
    ///   - script: the events to emit, in order.
    ///   - emitOnStart: when `true` (default), emit the full script on `start()`;
    ///     when `false`, hold the script until `finish()` drains it.
    public init(script: [TranscriptEvent], emitOnStart: Bool = true) {
        self.script = script
        self.emitOnStart = emitOnStart
        (results, continuation) = AsyncStream<TranscriptEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public func start() async throws {
        guard !didStart else { return }
        didStart = true
        if emitOnStart {
            emitRemaining()
        }
    }

    public func append(_ chunk: AudioChunk) async {
        appendedChunks.append(chunk)
    }

    public func finish() async {
        guard !didFinish else { return }
        didFinish = true
        // Drain any events the script held back, then close the stream — the
        // exact "no trailing utterance lost" guarantee Phase 6 relies on.
        emitRemaining()
        continuation.finish()
    }

    private func emitRemaining() {
        while nextIndex < script.count {
            continuation.yield(script[nextIndex])
            nextIndex += 1
        }
    }
}
