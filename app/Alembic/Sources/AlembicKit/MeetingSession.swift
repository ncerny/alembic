import Foundation
import Observation

/// The lifecycle state of a `MeetingSession`.
///
/// Drives the UI and the stop/drain handshake. Deliberately `Equatable` so tests
/// can assert the exact sequence of transitions a session moves through:
///
///     idle → selecting → recording → finalizing → saved(URL)
///
/// with `error(message)` reachable from any non-terminal state when a permission
/// or pipeline failure is surfaced.
public enum SessionState: Sendable, Equatable {
    /// No session in progress and no targets loaded yet.
    case idle
    /// Capture targets have been enumerated; awaiting a `start(target:)`.
    case selecting
    /// Live capture + transcription is running.
    case recording
    /// `stop()` has begun the drain: input stopped, engines finishing, writer
    /// not yet closed (it must not close until all finalized results land).
    case finalizing
    /// The session finished cleanly; the associated URL is the canonical
    /// transcript file on disk.
    case saved(URL)
    /// A permission or pipeline error was surfaced. The transcript-so-far has
    /// been flushed/closed on a best-effort basis so partial work survives.
    case error(String)
}

/// The platform-neutral orchestrator that runs one meeting transcription
/// session end to end.
///
/// ## Role
/// `MeetingSession` is the single `@MainActor`, `@Observable` brain that Phase 7's
/// SwiftUI layer binds to directly. It owns:
///
/// - one injected ``AudioSource`` (production: `ScreenCaptureKitSource`; tests:
///   `FakeAudioSource`),
/// - **one `TranscriptionEngine` per `SourceTag`** ("you"/"them"), built lazily
///   via an injected factory (production: `SpeechAnalyzerEngine`; tests:
///   `FakeTranscriptionEngine`), and
/// - one ``TranscriptWriter`` built via an injected factory at `start`.
///
/// It wires `AudioSource.buffers` → the matching engine, and each engine's
/// `results` → the rolling UI transcript **and** the writer (finalized only),
/// merging both sources onto a single session-clock timeline.
///
/// ## Platform neutrality (contract purity)
/// This type is **Foundation-only**. It never imports AVFoundation, CoreMedia,
/// ScreenCaptureKit, or Speech — all Apple specifics stay behind the injected
/// `AudioSource`/`TranscriptionEngine` contracts. Out-of-band capture errors are
/// delivered as plain `String` messages on an injected stream so the orchestrator
/// stays portable.
///
/// ## Concurrency
/// The class is `@MainActor`, so all observable mutation happens on the main
/// actor. Consumption tasks run off the main actor (reading `AsyncStream`s and
/// `await`ing the actor engines/writer) and hop back to `@MainActor` to mutate
/// state by calling the class's isolated methods. Nothing blocks the main thread.
@MainActor
@Observable
public final class MeetingSession {

    // MARK: - Observable UI state

    /// Current lifecycle state (the state machine).
    public private(set) var state: SessionState = .idle

    /// Ordered record of every state the session has entered, oldest first.
    /// Primarily a deterministic test/diagnostic aid for transition assertions.
    public private(set) var stateHistory: [SessionState] = [.idle]

    /// Targets enumerated by ``loadTargets()`` for the user to pick from.
    public private(set) var availableTargets: [CaptureTarget] = []

    /// The target chosen for the active/most recent session.
    public private(set) var selectedTarget: CaptureTarget?

    /// Finalized transcript history, kept sorted on the merged session-clock
    /// timeline (by `start`, tie-broken by source then `end`).
    public private(set) var finalizedTranscript: [TranscriptEvent] = []

    /// The current in-progress (volatile) line per source. Replaced freely as
    /// newer hypotheses arrive; safe to coalesce because volatile text is always
    /// superseded.
    public private(set) var volatileLines: [SourceTag: TranscriptEvent] = [:]

    /// Latest meter reading per source, when a meter stream was injected.
    public private(set) var meterLevels: [SourceTag: MeterLevel] = [:]

    /// Session-relative elapsed duration in seconds, derived deterministically
    /// from the latest event time (no wall-clock dependency).
    public private(set) var elapsedDuration: TimeInterval = 0

    /// Resolved canonical transcript file path, once the writer is created.
    public private(set) var outputURL: URL?

    /// A soft, non-fatal warning surfaced to the UI (e.g. a single failed disk
    /// write reported by the writer's `lastWriteError`). Does not stop the
    /// session.
    public private(set) var lastWarning: String?

    // MARK: - Injected collaborators (not observed)

    @ObservationIgnored private let audioSource: any AudioSource
    @ObservationIgnored private let engineFactory: @Sendable (SourceTag, SessionClock) -> any TranscriptionEngine
    @ObservationIgnored private let makeWriter: @Sendable () throws -> TranscriptWriter
    @ObservationIgnored private let meterUpdates: AsyncStream<MeterUpdate>?
    @ObservationIgnored private let sourceErrors: AsyncStream<String>?
    @ObservationIgnored private let clockOrigin: @Sendable () -> Double

    // MARK: - Internal session machinery (not observed)

    @ObservationIgnored private var clock: SessionClock?
    @ObservationIgnored private var engines: [SourceTag: any TranscriptionEngine] = [:]
    @ObservationIgnored private var writer: TranscriptWriter?

    @ObservationIgnored private var bufferTask: Task<Void, Never>?
    @ObservationIgnored private var resultTasks: [SourceTag: Task<Void, Never>] = [:]
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var errorTask: Task<Void, Never>?

    /// Continuations waiting for the session to reach a terminal state.
    @ObservationIgnored private var terminalWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Initialization

    /// - Parameters:
    ///   - audioSource: the (platform) audio source to capture from.
    ///   - engineFactory: builds one transcription engine for a given
    ///     `SourceTag` + `SessionClock`. Called once per source at `start`.
    ///   - makeWriter: builds the per-session `TranscriptWriter`. Called once at
    ///     `start`; throwing here surfaces as `.error`.
    ///   - meterUpdates: optional live meter stream (production sources expose
    ///     one); drives `meterLevels` when present.
    ///   - sourceErrors: optional stream of out-of-band capture error messages;
    ///     the first message transitions the session to `.error` while still
    ///     flushing the writer.
    ///   - clockOrigin: supplies the session-clock origin (seconds). Defaults to
    ///     `0`, which suits replay/fake sources whose times are already
    ///     session-relative; a production wiring can pass a monotonic reference.
    public init(
        audioSource: any AudioSource,
        engineFactory: @escaping @Sendable (SourceTag, SessionClock) -> any TranscriptionEngine,
        makeWriter: @escaping @Sendable () throws -> TranscriptWriter,
        meterUpdates: AsyncStream<MeterUpdate>? = nil,
        sourceErrors: AsyncStream<String>? = nil,
        clockOrigin: @escaping @Sendable () -> Double = { 0 }
    ) {
        self.audioSource = audioSource
        self.engineFactory = engineFactory
        self.makeWriter = makeWriter
        self.meterUpdates = meterUpdates
        self.sourceErrors = sourceErrors
        self.clockOrigin = clockOrigin
    }

    // MARK: - Target selection

    /// Enumerates capturable targets and moves to `.selecting`.
    ///
    /// Never throws: an enumeration failure (e.g. denied screen-recording
    /// permission) is surfaced as `.error(message)` so the UI can react.
    public func loadTargets() async {
        do {
            let targets = try await audioSource.availableTargets()
            availableTargets = targets
            transition(to: .selecting)
        } catch {
            fail(with: "Failed to load targets: \(message(for: error))")
        }
    }

    // MARK: - Start

    /// Starts a session against `target`: builds the clock + two engines + the
    /// writer, begins capture, and spins up the consumption tasks. On any setup
    /// failure the session transitions to `.error` (best-effort flushing any
    /// writer already opened) rather than crashing.
    public func start(target: CaptureTarget) async {
        guard state == .idle || state == .selecting else { return }

        selectedTarget = target
        finalizedTranscript = []
        volatileLines = [:]
        meterLevels = [:]
        elapsedDuration = 0
        lastWarning = nil

        let sessionClock = SessionClock(originSeconds: clockOrigin())
        clock = sessionClock

        // Build one engine per source via the injected factory.
        let you = engineFactory(.you, sessionClock)
        let them = engineFactory(.them, sessionClock)
        engines = [.you: you, .them: them]

        // Start engines independently so one failing surfaces a clear error.
        do {
            for (_, engine) in engines {
                try await engine.start()
            }
        } catch {
            fail(with: "Engine failed to start: \(message(for: error))")
            return
        }

        // Open the transcript writer.
        do {
            let w = try makeWriter()
            writer = w
            outputURL = w.outputURL
        } catch {
            fail(with: "Could not open transcript file: \(message(for: error))")
            return
        }

        // Begin capture.
        do {
            try await audioSource.start(target: target)
        } catch {
            await flushAndClose()
            fail(with: "Capture failed to start: \(message(for: error))")
            return
        }

        startConsumptionTasks()
        transition(to: .recording)
    }

    private func startConsumptionTasks() {
        // Route each captured chunk to the engine matching its source tag.
        // Detached so the stream consumption runs OFF the main actor; each hop
        // back into the @MainActor session is an explicit `await`.
        let source = audioSource
        let routed = engines
        bufferTask = Task.detached {
            for await chunk in source.buffers {
                if let engine = routed[chunk.source] {
                    await engine.append(chunk)
                }
            }
        }

        // One results task per engine: hop back to @MainActor to mutate state.
        for (tag, engine) in engines {
            resultTasks[tag] = Task.detached { [weak self] in
                for await event in engine.results {
                    await self?.ingest(event)
                }
            }
        }

        // Optional live meters.
        if let meterUpdates {
            meterTask = Task.detached { [weak self] in
                for await update in meterUpdates {
                    await self?.applyMeter(update)
                }
            }
        }

        // Optional out-of-band capture errors → surface and flush.
        if let sourceErrors {
            errorTask = Task.detached { [weak self] in
                for await message in sourceErrors {
                    await self?.handleSourceError(message)
                    break // first fatal error is enough
                }
            }
        }
    }

    // MARK: - Event ingestion (@MainActor)

    /// Folds one engine result into the observable transcript state.
    private func ingest(_ event: TranscriptEvent) async {
        // Advance the displayed duration deterministically from event time.
        elapsedDuration = max(elapsedDuration, event.end)

        switch event.kind {
        case .volatile:
            volatileLines[event.source] = event
        case .finalized:
            insertFinalized(event)
            // The just-finalized text supersedes any volatile line for it.
            volatileLines[event.source] = nil
            if let writer {
                await writer.append(event)
                if let writeError = await writer.lastWriteError {
                    lastWarning = "Transcript write warning: \(message(for: writeError))"
                }
            }
        }
    }

    /// Inserts a finalized event into the merged timeline, keeping it sorted by
    /// session-clock `start`, tie-broken by source (`you` before `them`) then
    /// `end`. Stable for equal keys (appended after equal existing entries).
    private func insertFinalized(_ event: TranscriptEvent) {
        let index = finalizedTranscript.firstIndex { Self.orderedBefore(event, $0) }
        if let index {
            finalizedTranscript.insert(event, at: index)
        } else {
            finalizedTranscript.append(event)
        }
    }

    /// Total order on the merged timeline: `start` asc, then source rank
    /// (`you` < `them`), then `end` asc.
    static func orderedBefore(_ a: TranscriptEvent, _ b: TranscriptEvent) -> Bool {
        if a.start != b.start { return a.start < b.start }
        let ra = sourceRank(a.source), rb = sourceRank(b.source)
        if ra != rb { return ra < rb }
        return a.end < b.end
    }

    private static func sourceRank(_ tag: SourceTag) -> Int {
        switch tag {
        case .you: return 0
        case .them: return 1
        }
    }

    private func applyMeter(_ update: MeterUpdate) {
        meterLevels[update.source] = update.level
    }

    // MARK: - Stop / drain state machine

    /// Stops the session and drains every pipeline **in order** so no finalized
    /// text is ever lost:
    ///
    /// 1. `state = .finalizing`
    /// 2. `audioSource.stop()` — finishes the `buffers` stream
    /// 3. await the buffer-routing task — all captured chunks delivered
    /// 4. `engine.finish()` for **both** engines — drains their results
    /// 5. await both results tasks — every finalized event ingested + written
    /// 6. **only now** `writer.close()`
    /// 7. `state = .saved(outputURL)`
    ///
    /// The writer is never closed before all finalized results are consumed —
    /// the key acceptance criterion for this phase.
    public func stop() async {
        guard state == .recording else { return }
        transition(to: .finalizing)

        // 2 + 3: stop capture, then ensure every chunk reached its engine.
        await audioSource.stop()
        await bufferTask?.value
        bufferTask = nil

        // 4: finish both engines (drains their results streams).
        for (_, engine) in engines {
            await engine.finish()
        }

        // 5: await both results tasks so ALL finalized events are ingested and
        // written before we touch the file handle.
        for (_, task) in resultTasks {
            await task.value
        }
        resultTasks = [:]

        // Live channels can stop now.
        meterTask?.cancel(); meterTask = nil
        errorTask?.cancel(); errorTask = nil

        // 6: close the writer only after every finalized result is consumed.
        let savedURL = writer?.outputURL
        await writer?.close()
        writer = nil

        // 7: saved.
        if let savedURL {
            transition(to: .saved(savedURL))
        } else {
            transition(to: .error("Session stopped without an output file"))
        }
    }

    // MARK: - Error handling

    /// Surfaces an out-of-band capture error (e.g. `SCStream` `didStopWithError`)
    /// while still flushing the writer so partial transcripts survive.
    private func handleSourceError(_ message: String) async {
        // Ignore once the session is already terminal.
        if case .saved = state { return }
        if case .error = state { return }
        await flushAndClose()
        fail(with: "Capture error: \(message)")
    }

    /// Best-effort teardown that flushes and closes the writer and cancels live
    /// tasks, used on error paths so a partial transcript is preserved on disk.
    private func flushAndClose() async {
        bufferTask?.cancel(); bufferTask = nil
        for (_, task) in resultTasks { task.cancel() }
        resultTasks = [:]
        meterTask?.cancel(); meterTask = nil
        errorTask?.cancel(); errorTask = nil
        await audioSource.stop()
        await writer?.close()
        writer = nil
    }

    /// Transitions to `.error(message)` (idempotent across terminal states).
    private func fail(with message: String) {
        if case .saved = state { return }
        transition(to: .error(message))
    }

    // MARK: - Transition bookkeeping & waiting

    private func transition(to newState: SessionState) {
        state = newState
        stateHistory.append(newState)
        if Self.isTerminal(newState) {
            let waiters = terminalWaiters
            terminalWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    private static func isTerminal(_ state: SessionState) -> Bool {
        switch state {
        case .saved, .error: return true
        default: return false
        }
    }

    /// Deterministic test/UI hook that completes once the session reaches a
    /// terminal state (`saved` or `error`). Avoids any reliance on sleeps.
    public func waitUntilFinished() async {
        if Self.isTerminal(state) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            terminalWaiters.append(continuation)
        }
    }

    // MARK: - Helpers

    private func message(for error: Error) -> String {
        String(describing: error)
    }
}
