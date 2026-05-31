import Foundation
// `@preconcurrency`: AVFoundation predates `Sendable`. The only non-`Sendable`
// crossing here is the synchronous `AVAudioConverterInputBlock` (typed
// `@Sendable` by the SDK) which we invoke and complete *inline* during
// `convert(to:error:)` — it never escapes or runs concurrently. Importing with
// `@preconcurrency` treats those false-positive Sendable diagnostics as the
// warnings they are without weakening isolation anywhere else.
@preconcurrency import AVFoundation
import CoreMedia
import Speech

/// macOS `TranscriptionEngine` backed by `SpeechAnalyzer` + `SpeechTranscriber`
/// (macOS 26+), with **one instance per source** for full isolation.
///
/// ## Why per-source isolation
/// "You" (mic) and "them" (meeting audio) each get their own analyzer, builder,
/// and converter. Nothing is shared, so one side stalling or erroring cannot
/// corrupt the other's timeline or backpressure accounting. The shared
/// `SpeechAssetManager` performs the locale + asset preflight *once* before these
/// engines are constructed; an engine assumes its `locale`'s models are present.
///
/// ## Concurrency model (Swift 6 strict)
/// The engine is an `actor`, so all mutable recognizer/converter state is
/// serially isolated without locks and the type is `Sendable` as the contract
/// requires. `results` is a `nonisolated let` `AsyncStream` (same pattern as the
/// capture sources). `append` converts `[Float]` → analyzer format **on the
/// actor's executor** (off any audio callback thread) and only ever *yields* to
/// a bounded continuation — it never blocks the caller's audio path nor `await`s
/// the analyzer. The result-consumption loop runs as an actor-isolated task
/// whose `await` suspension points let `append`/`finish` interleave (actor
/// reentrancy), so `finish()` can drain while the loop is parked awaiting the
/// next result.
///
/// ## Backpressure (two opposite policies)
/// - *Audio input* is **critical**: the `AnalyzerInput` stream is bounded
///   (`bufferingNewest`), and every drop is accounted by `AudioInputBackpressure`
///   (a dropped input = lost finalized text). Sustained drops escalate to an
///   error-level health signal exposed via `health()`.
/// - *Volatile results* are **safe to drop**: handled by the contract's
///   volatile/finalized distinction (see `VolatileResultBuffer` for the UI-side
///   coalescing policy); finalized events are emitted unconditionally.
///
/// ## Timestamps
/// Emitted `TranscriptEvent.start/.end` prefer the recognizer's own audio range
/// and fall back to the engine's audio cursor — never wall clock. Note we feed
/// **untimed** `AnalyzerInput`s (no `bufferStartTime`): on macOS 26, stamping the
/// input with an explicit start time causes `SpeechAnalyzer` to emit no results.
/// Because each engine is fed contiguous audio from session start, the
/// recognizer's `result.range` already lands on the session-relative timeline.
///
/// > Manual gate: the live `SpeechAnalyzer` path cannot run headlessly. Its pure
/// > sub-parts (`TranscriptEventMapper`, `AudioInputCursor`,
/// > `AudioInputBackpressure`) are covered by `AlembicCheck`; continuous >2 min
/// > transcription with `dropped == 0` is validated manually / via file replay.
public actor SpeechAnalyzerEngine: TranscriptionEngine {
    public nonisolated let results: AsyncStream<TranscriptEvent>
    private let resultsContinuation: AsyncStream<TranscriptEvent>.Continuation

    private let source: SourceTag
    private let locale: Locale
    private let clock: SessionClock
    private let inputBufferCapacity: Int

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var consumptionTask: Task<Void, Never>?

    /// Persistent converter (capture format → analyzer format), rebuilt only if
    /// the input format changes (e.g. a device change alters the sample rate).
    private var converter: AVAudioConverter?

    private var cursor = AudioInputCursor()
    private var backpressure: AudioInputBackpressure
    private var lastInputStart: Double = 0
    private var didStart = false
    private var didFinish = false

    /// - Parameters:
    ///   - source: which side this engine transcribes (`you`/`them`); stamped on
    ///     every emitted event.
    ///   - locale: the resolved, asset-installed locale from `SpeechAssetManager`.
    ///   - clock: the session clock (chunks already carry session-relative time;
    ///     retained for symmetry with the capture sources and future use).
    ///   - inputBufferCapacity: bounded `AnalyzerInput` queue depth; overflow is
    ///     counted as critical dropped input.
    ///   - sustainedDropThreshold: consecutive input drops that escalate health
    ///     to `.error`.
    public init(
        source: SourceTag,
        locale: Locale,
        clock: SessionClock,
        inputBufferCapacity: Int = 256,
        sustainedDropThreshold: Int = 10
    ) {
        self.source = source
        self.locale = locale
        self.clock = clock
        self.inputBufferCapacity = Swift.max(1, inputBufferCapacity)
        self.backpressure = AudioInputBackpressure(sustainedDropThreshold: sustainedDropThreshold)
        (results, resultsContinuation) = AsyncStream<TranscriptEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - TranscriptionEngine

    public func start() async throws {
        guard !didStart else { return }
        didStart = true

        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionEngineError.transcriberUnavailable
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionEngineError.noCompatibleAudioFormat
        }
        self.analyzerFormat = format

        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(inputBufferCapacity)
        )
        self.inputBuilder = builder

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        self.analyzer = analyzer

        startConsumption()
        try await analyzer.start(inputSequence: stream)
    }

    public func append(_ chunk: AudioChunk) async {
        // Per-source isolation: ignore audio tagged for the other side.
        guard chunk.source == source else { return }
        guard let builder = inputBuilder else { return }

        // Track a session-relative cursor purely for FALLBACK event timestamps
        // (used only when a result carries no audio range of its own).
        let startSeconds = cursor.bufferStart(for: chunk)
        lastInputStart = startSeconds

        guard let input = makeInputBuffer(from: chunk),
              let converted = convert(input) else {
            // Could not build/convert this chunk — treat as lost input (critical).
            backpressure.recordDropped()
            return
        }

        // IMPORTANT: do NOT pass a `bufferStartTime`. Stamping `AnalyzerInput`
        // with an explicit start time makes SpeechAnalyzer emit *no* results at
        // all (empirically verified on macOS 26 via the EngineProbe harness and
        // the Milestone-0 spike, which also feeds untimed inputs). We feed
        // contiguous audio from session start, so the recognizer's own
        // `result.range` already lands on the session-relative timeline.
        let yieldResult = builder.yield(AnalyzerInput(buffer: converted))
        switch yieldResult {
        case .enqueued:
            backpressure.recordEnqueued()
        case .dropped:
            backpressure.recordDropped()
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    public func finish() async {
        guard !didFinish else { return }
        didFinish = true

        // 1. Signal end of input.
        inputBuilder?.finish()
        inputBuilder = nil

        // 2. Drain: finalize any pending segment through end of input.
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // 3. Await the consumption loop so every trailing finalized result is
        //    emitted before the results stream closes.
        await consumptionTask?.value
        consumptionTask = nil

        // Safety: close the stream even if start() was never called.
        resultsContinuation.finish()
    }

    // MARK: - Health / metrics (for Phase 6 + manual validation)

    /// Current audio-input backpressure counters (enqueued/dropped). The
    /// acceptance gate requires `dropped == 0` under normal load.
    public func metrics() -> AudioInputBackpressure { backpressure }

    /// Current audio-input health (`ok`/`warning`/`error`).
    public func health() -> BackpressureHealth { backpressure.health }

    // MARK: - Result consumption (actor-isolated)

    private func startConsumption() {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runConsumption()
        }
        consumptionTask = task
    }

    private func runConsumption() async {
        guard let transcriber else {
            resultsContinuation.finish()
            return
        }
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                var audioStart: Double?
                var audioEnd: Double?
                let range = result.range
                if range.start.isValid {
                    let s = CMTimeGetSeconds(range.start)
                    if s.isFinite { audioStart = s }
                }
                if range.end.isValid {
                    let e = CMTimeGetSeconds(range.end)
                    if e.isFinite { audioEnd = e }
                }
                emit(text: text, isFinal: result.isFinal, audioStart: audioStart, audioEnd: audioEnd)
            }
        } catch {
            // The result stream errored; fall through and close the stream so
            // consumers unblock. (Recovery policy lives in the Phase 6 orchestrator.)
        }
        resultsContinuation.finish()
    }

    /// Pure-ish hand-off into the shared mapper, isolated on the actor.
    private func emit(text: String, isFinal: Bool, audioStart: Double?, audioEnd: Double?) {
        let recognizer = RecognizerResult(
            text: text,
            isFinal: isFinal,
            audioStart: audioStart,
            audioEnd: audioEnd,
            confidence: nil
        )
        guard let event = TranscriptEventMapper.event(
            from: recognizer,
            source: source,
            fallbackStart: lastInputStart,
            fallbackEnd: cursor.lastEnd
        ) else { return }
        resultsContinuation.yield(event)
    }

    // MARK: - Conversion (persistent converter, off the callback thread)

    /// Wraps a chunk's mono `[Float]` samples in an `AVAudioPCMBuffer` at the
    /// chunk's own sample rate.
    private func makeInputBuffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard chunk.sampleRate > 0, !chunk.samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: chunk.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        let frames = AVAudioFrameCount(chunk.samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        chunk.samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                dst.update(from: base, count: chunk.samples.count)
            }
        }
        return buffer
    }

    /// Converts an input buffer to the analyzer format using a persistent
    /// converter (rebuilt only when the input format changes).
    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let analyzerFormat else { return nil }
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: analyzerFormat)
        }
        guard let converter else { return nil }

        let ratio = analyzerFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity)
        guard let output else { return nil }

        // The converter pulls input lazily; feed our single buffer exactly once,
        // then report `.noDataNow`. `feed` is a reference holder so the
        // `@Sendable`-typed (but synchronously-invoked) input block mutates shared
        // state without a captured-var warning.
        let feed = FeedOnce(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if let buffer = feed.take() {
                status.pointee = .haveData
                return buffer
            }
            status.pointee = .noDataNow
            return nil
        }
        if error != nil { return nil }
        return output.frameLength > 0 ? output : nil
    }
}

/// One-shot input holder for `AVAudioConverter`'s pull block: returns the buffer
/// the first time and `nil` thereafter. A reference type so the synchronous,
/// `@Sendable`-typed input block can consume it without a captured-`var` warning.
private final class FeedOnce: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
