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
    /// The session self-discarded: it was started with a silent-discard window
    /// (auto-started sessions), produced no finalized far-end ("them") speech
    /// within it, and its transcript files were deleted. The associated value
    /// is a short human-readable reason.
    case discarded(String)
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

    /// Resolved human-readable (`.md`) transcript render path, once the writer
    /// is created — `nil` whenever the writer was not configured to produce a
    /// readable render (`writeReadableRender == false`). Mirrors `outputURL`'s
    /// exact assignment/reset lifecycle (resolves phase-3-plan-review-3 LOW
    /// finding): assigned once, at writer-creation time in `start(target:)`,
    /// alongside `outputURL`; preserved, not cleared, across `stop()`/error
    /// teardown so post-`stop()` checks (§2.2) can still read it after `writer`
    /// itself has been nil'd out by `drainAndClose()`/`flushAndClose()`; reset to
    /// `nil` only where `outputURL` is also reset to `nil` today — the silent-
    /// session discard path (`discardIfStillSilent()`), which deletes both files
    /// from disk and must not leave either URL pointing at a now-deleted file.
    public private(set) var readableURL: URL?

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
    /// Optional best-effort name resolver for finalized `.them` segments
    /// (SR-1/SR-14). `nil` (the default) preserves today's behavior exactly —
    /// no query is ever made and every `.them` segment persists unattributed,
    /// byte-identical to pre-feature output (UR-4). Queried only from
    /// `ingest(_:)` for finalized `.them` events (SR-15); never for `.you` or
    /// volatile events.
    @ObservationIgnored private let attributionProvider: (any AttributionProvider)?
    /// Per-segment attribution query budget (SR-17). Defaults to
    /// `Self.defaultAttributionQueryTimeout` (2s, production budget).
    /// Injectable so tests can supply a short, deterministic budget instead
    /// of depending on a real multi-second sleep racing a fixed wall-clock
    /// assertion (§2.4).
    @ObservationIgnored private let attributionQueryTimeout: Duration

    // MARK: - Internal session machinery (not observed)

    @ObservationIgnored private var clock: SessionClock?
    @ObservationIgnored private var engines: [SourceTag: any TranscriptionEngine] = [:]
    @ObservationIgnored private var writer: TranscriptWriter?

    @ObservationIgnored private var bufferTask: Task<Void, Never>?
    @ObservationIgnored private var resultTasks: [SourceTag: Task<Void, Never>] = [:]
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var errorTask: Task<Void, Never>?
    @ObservationIgnored private var discardTask: Task<Void, Never>?

    /// FIFO barrier for finalized-event insertion/writing (SR-14/SR-16). Each
    /// finalized event captures the *current* value of this chain synchronously
    /// (before doing anything async), builds a new link that first resolves its
    /// own attribution concurrently and then awaits the captured predecessor
    /// before calling `insertFinalized`/`writer.append`, and finally publishes
    /// itself as the new chain tail. Because the capture-and-replace happens with
    /// no intervening `await`, the chain's link order is always exactly the order
    /// `ingest` was invoked for finalized events — identical to this phase's
    /// pre-attribution behavior — regardless of how long any individual
    /// attribution query takes. A slow/timed-out first event can never let a
    /// faster later event's insert/write run ahead of it.
    @ObservationIgnored private var ingestionChain: Task<Void, Never>?

    /// Registry of every ingestion-chain link currently in flight, keyed by a
    /// per-link `UUID` — teardown must be able to find and stop *every*
    /// outstanding link, not only the chain's tail. Each link removes its own
    /// entry via `defer` when it finishes, whether it completed normally or was
    /// cancelled — so on the normal-completion path (`drainAndClose()`, after
    /// every `resultTasks` entry has been awaited) this registry is provably
    /// empty and is cleared explicitly; on the error-teardown path
    /// (`flushAndClose()`) every entry is cancelled and the registry is cleared
    /// *before* the writer is closed, so no abandoned link can call
    /// `insertFinalized`/`writer.append` afterward.
    @ObservationIgnored private var ingestionTasks: [UUID: Task<Void, Never>] = [:]

    /// Synchronous MainActor teardown gate. Set to `true` as the very
    /// **first**, synchronous statement in `flushAndClose()` (§1.6) — before
    /// any `await` in that function — so it is visible to any `ingest(_:)`
    /// call already queued on the MainActor executor at the moment teardown
    /// begins, even one that has not yet run at all. Checked at the very top
    /// of `ingest(_:)`, before it does anything else (including before
    /// capturing `ingestionChain` or registering a new `ingestionTasks`
    /// entry), and re-checked by every chain link immediately before
    /// `insertFinalized`/`writer.append`, alongside the existing
    /// `Task.isCancelled`/`Self.isTerminal(state)` guard. This closes a gap
    /// `state` alone cannot: `state` can still read as `.recording` while
    /// `flushAndClose()` is itself mid-`await` (e.g. inside
    /// `audioSource.stop()`/`writer?.close()`), so a same-tick `ingest` call
    /// arriving between teardown's start and the later `fail(...)` call that
    /// finally transitions `state` to `.error` needs a synchronous signal to
    /// consult — otherwise it could create a brand-new, uncancelled
    /// ingestion-chain link never present in the cancelled-and-cleared
    /// `ingestionTasks` registry. Never reset back to `false` —
    /// `flushAndClose()` is only ever used on terminal/error teardown paths,
    /// so a session that has disabled ingestion never resumes it.
    @ObservationIgnored private var ingestionDisabled = false

    /// Session-level circuit breaker: once any attribution query genuinely
    /// times out, `attributed(_:)` skips the provider entirely for every
    /// subsequent finalized `.them` event for the rest of this session. This
    /// bounds the number of abandoned provider query tasks a single session
    /// can ever accumulate to **at most one** — the one whose timeout
    /// tripped the fuse — rather than one per finalized `.them` event for a
    /// provider that hangs on every call.
    @ObservationIgnored private var attributionDisabledAfterTimeout = false

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
    ///   - attributionProvider: optional best-effort name resolver for finalized
    ///     `.them` segments (SR-1/SR-14). `nil` (the default) preserves today's
    ///     behavior exactly — no query is ever made and every `.them` segment
    ///     persists unattributed, byte-identical to pre-feature output (UR-4).
    ///     Queried only from `ingest(_:)` for finalized `.them` events (SR-15);
    ///     never for `.you` or volatile events.
    ///   - attributionQueryTimeout: per-segment attribution query budget (SR-17).
    ///     Defaults to `Self.defaultAttributionQueryTimeout` (2s, production
    ///     budget). Injectable so tests can supply a short, deterministic budget
    ///     instead of depending on a real multi-second sleep racing a fixed
    ///     wall-clock assertion (§2.4).
    public init(
        audioSource: any AudioSource,
        engineFactory: @escaping @Sendable (SourceTag, SessionClock) -> any TranscriptionEngine,
        makeWriter: @escaping @Sendable () throws -> TranscriptWriter,
        meterUpdates: AsyncStream<MeterUpdate>? = nil,
        sourceErrors: AsyncStream<String>? = nil,
        clockOrigin: @escaping @Sendable () -> Double = { 0 },
        attributionProvider: (any AttributionProvider)? = nil,
        attributionQueryTimeout: Duration = MeetingSession.defaultAttributionQueryTimeout
    ) {
        self.audioSource = audioSource
        self.engineFactory = engineFactory
        self.makeWriter = makeWriter
        self.meterUpdates = meterUpdates
        self.sourceErrors = sourceErrors
        self.clockOrigin = clockOrigin
        self.attributionProvider = attributionProvider
        self.attributionQueryTimeout = attributionQueryTimeout
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
    ///
    /// - Parameter discardIfSilentAfter: when non-nil, a watchdog checks the
    ///   transcript after this many seconds; if no finalized far-end ("them")
    ///   event has arrived the session drains, deletes its files, and enters
    ///   `.discarded`. Pass it only for auto-started sessions — a deliberate
    ///   manual recording must never self-destruct.
    public func start(target: CaptureTarget, discardIfSilentAfter: TimeInterval? = nil) async {
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
            readableURL = w.readableURL
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

        if let window = discardIfSilentAfter {
            discardTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(window))
                guard !Task.isCancelled else { return }
                await self?.discardIfStillSilent()
            }
        }
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
        // Teardown gate: checked synchronously, before anything else in this
        // function, including before `elapsedDuration` bookkeeping and before
        // capturing `ingestionChain`/registering a new `ingestionTasks` entry.
        // Once `flushAndClose()` has set this flag, no new ingestion work may
        // start at all — this stops a call already queued on the MainActor
        // executor when teardown begins from creating a fresh, uncancelled
        // chain link that the cancelled-and-cleared `ingestionTasks` registry
        // never saw.
        guard !ingestionDisabled else { return }

        // Advance the displayed duration deterministically from event time.
        elapsedDuration = max(elapsedDuration, event.end)

        switch event.kind {
        case .volatile:
            volatileLines[event.source] = event
        case .finalized:
            // Capture the predecessor and register the new link *synchronously*
            // (no await above this line in the .finalized case) so chain order
            // matches ingest-call order exactly (SR-16 ordering guarantee), and
            // so the link is already visible in `ingestionTasks` before it could
            // possibly be raced by `flushAndClose()`.
            let previous = ingestionChain
            let linkID = UUID()
            let current = Task { [weak self] in
                guard let self else { return }
                // Self-deregister on exit, however this link finishes — normal
                // completion or cancellation — so `ingestionTasks` never grows
                // unbounded and reflects only genuinely in-flight links.
                defer { self.ingestionTasks[linkID] = nil }
                // Attribution may take up to `attributionQueryTimeout`; resolve
                // it concurrently with the predecessor link rather than
                // serially, so one slow provider query does not additionally
                // delay behind *every* prior query's full duration.
                let attributed = await self.attributed(event)
                // FIFO barrier: this link's insert/write never runs before its
                // predecessor's, however long attribution took on either side.
                await previous?.value
                // Cancellation / terminal-state / teardown-gate check.
                // `flushAndClose()` (§1.6) cancels every entry in
                // `ingestionTasks`, including this one, *before* it closes the
                // writer; `Task.cancel()` sets a flag visible to any
                // subsequent `Task.isCancelled` read even if this link is
                // resumed mid-flight. `Self.isTerminal(self.state)` is a
                // second, independent gate (defense in depth against any
                // future teardown path that does not route through
                // `flushAndClose()`), and `self.ingestionDisabled` is a third,
                // synchronous gate that is true even during the pre-terminal
                // window while `flushAndClose()` is itself still mid-`await` —
                // exactly the window a same-tick `ingest` call could otherwise
                // race. A link that fails *any* of the three checks is
                // silently dropped here rather than mutating/writing.
                guard !Task.isCancelled, !Self.isTerminal(self.state), !self.ingestionDisabled else { return }
                self.insertFinalized(attributed)
                self.volatileLines[event.source] = nil
                if let writer = self.writer {
                    await writer.append(attributed)
                    if let writeError = await writer.lastWriteError {
                        self.lastWarning = "Transcript write warning: \(self.message(for: writeError))"
                    }
                }
            }
            ingestionChain = current
            ingestionTasks[linkID] = current
            // Awaiting here (rather than "fire and forget") is required so the
            // per-engine `resultTasks[tag]` loop — and, transitively,
            // `drainAndClose()`'s `await task.value` — still faithfully means
            // "every event this engine emitted is fully ingested" once it
            // completes (unchanged invariant from before this phase).
            await current.value
        }
    }

    /// Resolves attribution for a finalized `.them` event via the injected
    /// `attributionProvider` (SR-14). Returns `event` unchanged for every other
    /// case: no provider injected, wrong source (`.you` — SR-15), the per-session
    /// circuit breaker already tripped, a `nil` result, a genuine timeout
    /// (SR-16), or a resolved result whose sanitized confidence is not a
    /// strictly-positive, finite, in-range value (see the zero-confidence
    /// contract note below). Never throws; never delays beyond
    /// `attributionQueryTimeout` even against a non-cooperative provider (§1.4).
    private func attributed(_ event: TranscriptEvent) async -> TranscriptEvent {
        guard event.kind == .finalized, event.source == .them,
              let attributionProvider,
              !attributionDisabledAfterTimeout else { return event }

        let window = event.start...max(event.start, event.end)
        let outcome = await Self.boundedAttribution(
            provider: attributionProvider,
            window: window,
            timeout: attributionQueryTimeout
        )
        let result: SpeakerAttributionResult?
        switch outcome {
        case .timedOut:
            // Trip the circuit breaker: a genuine timeout means this
            // provider is not honoring its documented "must return promptly"
            // contract, so every subsequent finalized `.them` event for the
            // rest of this session skips the provider entirely rather than
            // issuing another query — bounding the number of abandoned
            // provider tasks a single session can ever accumulate to at most
            // one.
            attributionDisabledAfterTimeout = true
            return event
        case .resolved(let value):
            result = value
        }
        guard let result else { return event }

        // Zero-confidence contract: Phase 2's `SpeakerAttributionResult.init`
        // clamps a non-finite (`NaN`/±infinity) confidence to `0` (§0.1) so
        // the type's invariant ("confidence is always finite and in `0...1`")
        // holds unconditionally. A *well-formed* provider — including
        // `ActiveSpeakerTimeline.resolve`, whose `minConfidence`/
        // `minOverlapFraction` configuration values are always `> 0` —
        // therefore never legitimately returns confidence `0`; a `0` observed
        // here can only mean "a non-finite value was sanitized at
        // construction" or "a test double manufactured it directly." Treating
        // `0` as "no usable signal" (not as "attribute with zero confidence")
        // is the contract this phase commits to: `> 0` is required in
        // addition to `isFinite`/in-range, so a defensively-clamped
        // non-finite result falls through to `event` unchanged exactly like a
        // `nil`/timeout result, and this code never persists a name with a
        // meaningless zero confidence. This is also the defense-in-depth
        // backstop against any future provider that bypasses
        // `SpeakerAttributionResult.init` entirely — a JSONEncoder-non-
        // conforming Double can therefore never reach `TranscriptWriter.append`
        // (which would otherwise silently drop the whole segment — the exact
        // SR-16 violation the Phase 2 review flagged).
        guard result.confidence.isFinite, result.confidence > 0,
              (0...1).contains(result.confidence) else { return event }

        let attribution = TranscriptAttribution(
            source: "vision",
            confidence: result.confidence,
            displayName: result.displayName
        )
        return TranscriptEvent(
            id: event.id, kind: event.kind, source: event.source,
            start: event.start, end: event.end, text: event.text,
            attribution: attribution
        )
    }

    /// Production default per-segment attribution query budget (SR-17).
    /// Chosen generously relative to Phase 5's target OCR throttle (≈1–2 Hz)
    /// and typical ASR finalization latency — a well-behaved provider
    /// (including every Phase 2 `AttributionProvider` conformer and the
    /// eventual `VisionSpeakerAttributor`, which only ever reads its own
    /// in-memory `ActiveSpeakerTimeline`) resolves in microseconds; this
    /// budget exists solely to bound a misbehaving/hung provider's effect on
    /// `stop()`'s drain latency, never to be relied on as a normal-path
    /// delay. `nonisolated`: it is a plain constant with no dependency on any
    /// `MeetingSession` instance state.
    ///
    /// `public` (not `private`) because `init`'s default argument expression
    /// for `attributionQueryTimeout` is evaluated at each call site — Swift
    /// requires a default-argument expression to be at least as accessible
    /// as the initializer itself, so a `private`/`internal` constant here
    /// would not compile as a public default value (the concrete compile
    /// error this access level fixes).
    public nonisolated static let defaultAttributionQueryTimeout: Duration = .seconds(2)

    /// Guards a `CheckedContinuation` so it is resumed exactly once even
    /// though two independent unstructured tasks (the provider query and the
    /// timeout timer, below) race to resume it. `NSLock`-guarded per this
    /// codebase's existing thread-safe-box convention (`LocaleBox`/
    /// `VocabularyBox` in `AppModel.swift`) — `@unchecked Sendable` is safe
    /// here because every mutable access to `didResume` is lock-protected.
    private final class SingleResume: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        /// Returns `true` to exactly the first caller (the race winner);
        /// `false` to every subsequent caller, so only the winner actually
        /// resumes.
        func tryResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if didResume { return false }
            didResume = true
            return true
        }
    }

    /// Thread-safe box holding references to the provider-query task and the
    /// timeout-timer task, so each can cancel the other regardless of which
    /// one is created/observed first. `NSLock`-guarded per this codebase's
    /// thread-safe-box convention; `@unchecked Sendable` is safe because
    /// every access to either stored task is lock-protected.
    ///
    /// Both fields exist (rather than one `TaskBox` per task, each closing
    /// over the other's *local* `let`) to resolve a LOW-severity ordering
    /// race: if the timer task were created first and the query task second,
    /// a vanishingly small/zero injected timeout could fire before the query
    /// task's reference was ever assigned anywhere the timer could observe
    /// it, so the timer would resolve `nil` without being able to cancel a
    /// query it never saw. `boundedAttribution` (below) creates and assigns
    /// `queryTask` on this box *before* the timer task is even constructed,
    /// so the timer's own body — however soon it happens to run — can never
    /// observe `queryTask == nil`.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _queryTask: Task<Void, Never>?
        private var _timerTask: Task<Void, Never>?
        var queryTask: Task<Void, Never>? {
            get { lock.lock(); defer { lock.unlock() }; return _queryTask }
            set { lock.lock(); defer { lock.unlock() }; _queryTask = newValue }
        }
        var timerTask: Task<Void, Never>? {
            get { lock.lock(); defer { lock.unlock() }; return _timerTask }
            set { lock.lock(); defer { lock.unlock() }; _timerTask = newValue }
        }
    }

    /// Outcome of a bounded attribution query (SR-17): distinguishes "the
    /// provider genuinely resolved within `timeout`" (with a `nil` payload
    /// meaning "no attribution," per the provider's own protocol contract)
    /// from "the timeout fired first." This distinction is what lets
    /// `attributed(_:)` trip the circuit breaker (above) only on a genuine
    /// timeout, never on a provider's ordinary "no match" answer.
    private enum AttributionOutcome {
        case resolved(SpeakerAttributionResult?)
        case timedOut
    }

    /// Awaits `provider.attribution(forThemSegment:)` but never waits longer
    /// than `timeout` — **even if the provider ignores Swift concurrency
    /// cancellation** (SR-17). Races the provider's own unstructured task
    /// directly against a timer task through the single `SingleResume`-guarded
    /// continuation gate — **no separate waiter task wraps the query task's
    /// `.value`**: the provider task resumes the continuation itself when it
    /// finishes, and the timer task resumes it itself when it fires, so only
    /// these two tasks ever exist per call. Whichever loses the race is
    /// `cancel()`-ed — a best-effort cooperative signal only, never awaited
    /// again. This function returns as soon as the first of {query finishes,
    /// timeout fires} resumes the continuation.
    ///
    /// **Task-creation order is deliberate** (resolves a LOW-severity ordering
    /// race — see `TaskBox`'s doc comment): the query task is created and
    /// stored on `box` *first*, and only then is the timer task created. This
    /// guarantees the timer's body — no matter how soon it happens to run,
    /// even for a near-zero injected `timeout` — can always observe
    /// `box.queryTask` already set, so the documented "the loser is always
    /// cancelled" guarantee actually holds for the timeout-wins case. The
    /// symmetric case (query resolves before the timer task is even
    /// constructed) is harmless: the query simply has nothing to cancel yet,
    /// and the timer — once it does fire — finds `resume.tryResume()` already
    /// `false` and exits as a no-op.
    ///
    /// **Containment/leaked-work tradeoff, documented explicitly (not a
    /// structured-concurrency guarantee):** if the timer wins, the query task is
    /// abandoned — if the provider truly never returns (or never checks
    /// cancellation), it keeps running for the provider's own (possibly
    /// unbounded) lifetime, consuming one Task/thread-pool slot until it either
    /// finishes on its own or the process exits. This is a deliberate
    /// containment boundary, not a resource-leak fix: the leaked work can never
    /// reach `insertFinalized`/`writer.append` (its eventual result, if any, is
    /// discarded — the `SingleResume` guard guarantees the continuation was
    /// already resumed by the timeout by the time it would arrive), so it cannot
    /// corrupt the transcript, reorder segments, or double-write. **At most one**
    /// such abandoned query task can ever exist per timeout, and — combined with
    /// `attributionDisabledAfterTimeout` above — at most one per *session*, since
    /// the first timeout permanently stops further provider queries for the rest
    /// of that session. `AttributionProvider` conformers are documented (Phase 2)
    /// as MUST-return-promptly for exactly this reason; this mechanism bounds
    /// the *caller's* wait and the *session's* total abandoned work, never the
    /// provider's own resource usage for that one abandoned call.
    nonisolated private static func boundedAttribution(
        provider: any AttributionProvider,
        window: ClosedRange<Double>,
        timeout: Duration
    ) async -> AttributionOutcome {
        let resume = SingleResume()
        let box = TaskBox()
        let winner: SpeakerAttributionResult?? = await withCheckedContinuation { continuation in
            // Create and store the query task FIRST — see the doc comment
            // above and on `TaskBox` for why this ordering matters.
            box.queryTask = Task<Void, Never> {
                let value = await provider.attribution(forThemSegment: window)
                if resume.tryResume() {
                    box.timerTask?.cancel() // best-effort cooperative signal only; never awaited again
                    continuation.resume(returning: .some(value))
                }
            }
            box.timerTask = Task {
                try? await Task.sleep(for: timeout)
                if resume.tryResume() {
                    box.queryTask?.cancel() // best-effort cooperative signal only; never awaited again
                    continuation.resume(returning: .none)
                }
            }
        }
        guard let winner else { return .timedOut }
        return .resolved(winner)
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

        let (savedURL, _) = await drainAndClose()

        // 7: saved.
        if let savedURL {
            transition(to: .saved(savedURL))
        } else {
            transition(to: .error("Session stopped without an output file"))
        }
    }

    /// Steps 2–6 of the drain: stop capture, deliver every chunk, finish both
    /// engines, ingest every finalized result, and only then close the writer.
    /// Returns the canonical and readable transcript URLs (nil when no writer
    /// was open). Shared by `stop()` and the silent-session discard path.
    private func drainAndClose() async -> (canonical: URL?, readable: URL?) {
        discardTask?.cancel()
        discardTask = nil

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

        // Every finalized event's ingestion-chain link has now fully
        // completed (each `resultTasks` entry only finished after every
        // `ingest` call it made — including that call's chain link — itself
        // completed) — clear the FIFO barrier and its registry explicitly on
        // this normal-completion path, both as documentation of the
        // invariant and as a hard reset in case of any programmer error.
        ingestionChain = nil
        ingestionTasks = [:]

        // Live channels can stop now.
        meterTask?.cancel(); meterTask = nil
        errorTask?.cancel(); errorTask = nil

        // 6: close the writer only after every finalized result is consumed.
        let canonical = writer?.outputURL
        let readable = writer?.readableURL
        await writer?.close()
        writer = nil
        return (canonical, readable)
    }

    // MARK: - Silent-session discard (auto-started sessions only)

    /// Watchdog body: if the session is still recording and has produced no
    /// finalized far-end speech, drain it, delete its transcript files, and
    /// transition to `.discarded`. Re-checks after the drain so a first "them"
    /// segment that was in flight while draining is never deleted.
    private func discardIfStillSilent() async {
        guard state == .recording else { return }
        guard !hasFarEndSpeech else { return }

        transition(to: .finalizing)
        let (canonical, readable) = await drainAndClose()

        // Trailing finalized results may have landed during the drain — if any
        // are far-end speech this was a real (quiet-start) meeting; keep it.
        if hasFarEndSpeech {
            if let canonical {
                transition(to: .saved(canonical))
            } else {
                transition(to: .error("Session stopped without an output file"))
            }
            return
        }

        if let canonical { try? FileManager.default.removeItem(at: canonical) }
        if let readable { try? FileManager.default.removeItem(at: readable) }
        outputURL = nil
        readableURL = nil
        transition(to: .discarded("no far-end speech detected"))
    }

    /// Whether any finalized far-end ("them") event has been ingested.
    private var hasFarEndSpeech: Bool {
        finalizedTranscript.contains { $0.source == .them }
    }

    // MARK: - Error handling

    /// Surfaces an out-of-band capture error (e.g. `SCStream` `didStopWithError`)
    /// while still flushing the writer so partial transcripts survive.
    private func handleSourceError(_ message: String) async {
        // Ignore once the session is already terminal.
        if case .saved = state { return }
        if case .error = state { return }
        if case .discarded = state { return }
        await flushAndClose()
        fail(with: "Capture error: \(message)")
    }

    /// Best-effort teardown that flushes and closes the writer and cancels live
    /// tasks, used on error paths so a partial transcript is preserved on disk.
    private func flushAndClose() async {
        // Synchronous teardown gate — MUST be the first statement, before any
        // `await`. Visible to `ingest(_:)`'s entry guard and to every chain
        // link's mutation guard immediately, regardless of how long the rest
        // of this function's teardown work takes or what `state` currently
        // reads as.
        ingestionDisabled = true
        discardTask?.cancel(); discardTask = nil
        bufferTask?.cancel(); bufferTask = nil
        for (_, task) in resultTasks { task.cancel() }
        resultTasks = [:]
        // Cancel and discard every outstanding ingestion-chain link — not
        // only the tail (`ingestionChain`) — before the writer is closed.
        // Each link's own cancellation/terminal-state/teardown-gate guard
        // (in `ingest(_:)`) is what makes this safe even though `cancel()`
        // does not synchronously stop a link that is mid-`await` (e.g.
        // inside `boundedAttribution`): the guard is checked *after* the
        // link resumes, and by the time it resumes both `Task.isCancelled`
        // and `ingestionDisabled` already reflect this teardown, whether or
        // not the session has separately reached a terminal `state` yet.
        for (_, task) in ingestionTasks { task.cancel() }
        ingestionTasks = [:]
        ingestionChain = nil
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
        case .saved, .error, .discarded: return true
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
