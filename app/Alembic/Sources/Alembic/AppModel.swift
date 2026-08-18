import Foundation
import AppKit
import AlembicKit

/// Production composition root + observable owner for the SwiftUI layer.
///
/// `AppModel` is the **only** place in the codebase that wires the
/// platform-neutral ``MeetingSession`` orchestrator to its concrete macOS
/// collaborators (`ScreenCaptureKitSource`, `SpeechAnalyzerEngine`,
/// `SpeechAssetManager`, `TranscriptWriter`). The views observe this object and
/// the `@Observable` ``MeetingSession`` it owns; they never touch platform types
/// or business logic directly.
///
/// ## Why selection lives here (and not on the session)
/// `MeetingSession.selectedTarget` is `private(set)` and only assigned inside
/// `start(target:)`. The menu needs a *pre-start* selection the user can change
/// freely, so the picker binds to ``selectedTarget`` on this model. `Start` then
/// forwards that value into `session.start(target:)`.
///
/// ## Locale resolution (sync factory, async preflight)
/// The session's engine factory is synchronous and non-throwing, but the
/// production engine needs a locale whose speech assets are installed — which is
/// resolved by the *async* `SpeechAssetManager.preflight()`. We bridge the two
/// with a small `Sendable` ``LocaleBox`` captured by the factory: `preflight()`
/// runs (showing progress) before `start`, fills the box, and the factory reads
/// the resolved locale when the session builds its per-source engines.
@MainActor
@Observable
final class AppModel {
    /// Scene id for the live transcript `Window`, opened via `openWindow`.
    static let liveWindowID = "live-transcript"

    /// Scene id for the settings `Window`, opened via `openWindow`.
    static let settingsWindowID = "alembic-settings"

    /// The orchestrator the whole UI binds to. Rebuilt for each new meeting
    /// (a `MeetingSession` is single-shot: it cannot restart after `.saved`).
    private(set) var session: MeetingSession

    /// The user's chosen capture target (the meeting/"them" app). Lives here
    /// because the session only records its selection at `start`.
    var selectedTarget: CaptureTarget?

    /// Human-friendly meeting name embedded in the transcript file name.
    var meetingName: String = "Meeting"

    /// `true` while the one-time speech-asset preflight is running before a
    /// start (drives a "preparing models…" affordance in the UI).
    private(set) var isPreparingModels = false

    /// In-flight model-download progress in `[0, 1]`, when an install is needed.
    private(set) var modelDownloadProgress: Double?

    /// A preflight failure message (unsupported locale / failed asset install),
    /// surfaced separately from the session's own `.error` state.
    private(set) var preparationError: String?

    /// The first-run permissions coordinator. `start()` gates on this; the menu
    /// and onboarding UI bind to it to guide the user through the three grants.
    let permissions = PermissionsModel()

    /// `true` when Alembic should automatically start and stop recording whenever
    /// a known meeting app begins or ends a call.
    private(set) var autoStartEnabled: Bool =
        UserDefaults.standard.bool(forKey: "alembic.autostart.enabled")

    /// The most recent reason a start was blocked or setup failed, mapped to a
    /// clear, actionable ``PermissionGuidance``. `nil` when there's nothing to
    /// surface. Never left as a silent no-op.
    private(set) var startupBlocker: StartupBlocker?

    /// Actionable guidance (message + optional Settings deep-link / restart hint)
    /// for the current ``startupBlocker``, or `nil`.
    var startupGuidance: PermissionGuidance? { startupBlocker?.guidance }

    // MARK: Injected production singletons (not observed)

    @ObservationIgnored private let assetManager = SpeechAssetManager()
    @ObservationIgnored private let localeBox = LocaleBox()
    @ObservationIgnored private let vocabularyBox = VocabularyBox()
    @ObservationIgnored private let contextBox = MeetingContextBox()
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private let teamsChatPoster = TeamsChatPoster()

    /// User-facing status of the most recent transcription-disclosure attempt
    /// (posted / staged to clipboard / skipped / failed), or `nil` when none has
    /// run this launch. Surfaced in the menu so the outcome is never silent.
    private(set) var disclosureStatus: String?

    // MARK: Speaker attribution (not observed except the diagnostic text)

    /// Owns the current `start()` call's `VisionSpeakerAttributor` plus its
    /// background tasks, when speaker attribution was engaged for this run
    /// (`nil` otherwise — the common case until `SpeakerLabelCatalog` ships a
    /// `markersValidated` entry). See `AttributionRuntime` below.
    @ObservationIgnored private var attributionRuntime: AttributionRuntime?

    /// The single most recent `attributionDiagnostics` entry (non-fatal
    /// video-only status, e.g. "no meeting window resolved"), or `nil` when
    /// none has fired this run. A bounded status indicator, not a log —
    /// cleared at the start of every eligible `start()` call.
    private(set) var attributionDiagnostic: String?

    // MARK: Auto-start detector (not observed)

    @ObservationIgnored private var detector: MeetingDetector?
    @ObservationIgnored private var detectorTask: Task<Void, Never>?
    @ObservationIgnored private var consumerTask: Task<Void, Never>?
    /// Non-nil when the current session was started automatically. Used to guard
    /// against stopping a user-initiated session and to allow auto-stop when the
    /// detected call ends.
    @ObservationIgnored private var autoStartedTarget: CaptureTarget?
    /// A confirmed detection that couldn't start yet (model preflight running,
    /// capture target not enumerable). Retried by `detectionRetryTask` so a
    /// meeting is never silently skipped.
    @ObservationIgnored private var pendingDetection: Detection?
    @ObservationIgnored private var detectionRetryTask: Task<Void, Never>?

    /// Auto-started sessions self-discard (files deleted) when no far-end
    /// speech is transcribed within this window — the safety net against
    /// notification-chime false positives. Manual recordings are exempt.
    private static let silentDiscardWindow: TimeInterval = 120

    /// How often and how long to retry a parked detection.
    private static let detectionRetryInterval: TimeInterval = 5
    private static let detectionRetryAttempts = 12

    init() {
        session = AppModel.makeSession(localeBox: localeBox, vocabularyBox: vocabularyBox, contextBox: contextBox)
        meetingName = "Meeting"
        // Read current permission status (no prompts) so the menu reflects what
        // still needs granting before the first Start.
        permissions.refresh()
        // Best-effort initial enumeration so the picker is populated. A denied
        // Screen Recording permission surfaces as `session.state == .error`,
        // recoverable via the menu's "Refresh Targets" action (Phase 8 polish).
        Task { await refreshTargets() }
        if autoStartEnabled { startDetector() }
    }

    // MARK: - Composition root

    /// Builds a fully wired production ``MeetingSession`` around `source`,
    /// optionally injecting `attributionProvider` (Phase 6). Shared by
    /// ``makeSession(localeBox:vocabularyBox:contextBox:)`` (the audio-only,
    /// synchronous, `init()`-time factory) and the attribution-engaged path in
    /// ``start()`` so both construct the engine/writer/clock wiring identically
    /// — this is the single place a ``MeetingSession`` is assembled.
    ///
    /// It:
    /// - feeds `source`'s live `meterUpdates` straight into the orchestrator,
    /// - maps `source`'s typed `errors` channel onto the orchestrator's plain
    ///   `String` error stream (the orchestrator is Apple-free by contract),
    /// - builds one `SpeechAnalyzerEngine` per `SourceTag` against the locale
    ///   resolved by preflight (read from `localeBox` at start time),
    /// - opens a `TranscriptWriter` under `~/Documents/Alembic/`, and
    /// - anchors the session clock origin on the same monotonic host-time basis
    ///   the source uses (`HostClock.now()`), so engine/source times align.
    private static func buildSession(
        source: ScreenCaptureKitSource,
        attributionProvider: (any AttributionProvider)?,
        localeBox: LocaleBox,
        vocabularyBox: VocabularyBox,
        contextBox: MeetingContextBox
    ) -> MeetingSession {
        // Map CaptureSourceError -> String for the platform-neutral orchestrator.
        let sourceErrors = source.errors
        let mappedErrors = AsyncStream<String> { continuation in
            let task = Task {
                for await error in sourceErrors {
                    continuation.yield(error.description)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        let engineFactory: @Sendable (SourceTag, SessionClock) -> any TranscriptionEngine = { tag, clock in
            SpeechAnalyzerEngine(
                source: tag,
                locale: localeBox.locale,
                clock: clock,
                contextualStrings: vocabularyBox.terms
            )
        }

        let makeWriter: @Sendable () throws -> TranscriptWriter = {
            try TranscriptWriter(context: contextBox.context, writeReadableRender: true)
        }

        return MeetingSession(
            audioSource: source,
            engineFactory: engineFactory,
            makeWriter: makeWriter,
            meterUpdates: source.meterUpdates,
            sourceErrors: mappedErrors,
            clockOrigin: { HostClock.now() },
            attributionProvider: attributionProvider
        )
    }

    /// Builds a fully wired production ``MeetingSession`` with an audio-only
    /// `ScreenCaptureKitSource` and no attribution provider — the **only**
    /// factory `init()` calls, and the base (terminal-only-gated) rebuild
    /// factory inside `start()`. Stays synchronous and target-independent
    /// (Phase 6, §0.2): attribution wiring is target-dependent and needs an
    /// `async` step (`setExpectedMeetingTitle`), so it lives in the separate
    /// ``makeAttributionRuntime(target:meetingTitle:)`` factory instead, called
    /// only from `start()`, never from here.
    private static func makeSession(localeBox: LocaleBox, vocabularyBox: VocabularyBox, contextBox: MeetingContextBox) -> MeetingSession {
        buildSession(
            source: ScreenCaptureKitSource(),
            attributionProvider: nil,
            localeBox: localeBox,
            vocabularyBox: vocabularyBox,
            contextBox: contextBox
        )
    }

    /// Builds the attribution-mode capture source plus its owned
    /// ``AttributionRuntime`` for a `start()` call that has already decided
    /// attribution is engaged (§0.4's gate: toggle on, `SpeakerLabelCatalog.
    /// match(bundleID:)?.markersValidated == true`, **and** the resolved
    /// meeting title matches that entry's `layoutRequirement` — §0.5) —
    /// never invoked speculatively, and never from `init()`.
    ///
    /// `setExpectedMeetingTitle(_:)` is called before `source` is used to build
    /// anything else, satisfying the documented "before `start(target:)`"
    /// invariant (`ScreenCaptureKitSource`, Phase 4). The same `meetingTitle`
    /// is also passed to `VisionSpeakerAttributor.init` (one resolution, two
    /// consumers) so the attributor re-asserts the meeting-window gate itself
    /// rather than trusting the caller's gating alone (defense in depth).
    private static func makeAttributionRuntime(
        target: CaptureTarget,
        meetingTitle: String?
    ) async -> (source: ScreenCaptureKitSource, runtime: AttributionRuntime) {
        let source = ScreenCaptureKitSource(mode: .audioPlusAttribution)
        await source.setExpectedMeetingTitle(meetingTitle)
        let attributor = VisionSpeakerAttributor(bundleID: target.id, meetingTitle: meetingTitle, frames: source.frames)
        let runtime = AttributionRuntime(attributor: attributor)
        return (source, runtime)
    }

    // MARK: - Target enumeration

    /// Enumerates capturable apps and auto-selects a likely Teams target.
    func refreshTargets() async {
        await session.loadTargets()
        autoSelectTargetIfNeeded()
    }

    /// Picks a sensible default when nothing valid is selected: a likely Teams
    /// process if present, otherwise the first available target.
    private func autoSelectTargetIfNeeded() {
        let targets = session.availableTargets
        let stillValid = selectedTarget.map { sel in targets.contains { $0.id == sel.id } } ?? false
        guard !stillValid else { return }
        selectedTarget = targets.first(where: ScreenCaptureKitSource.isLikelyTeams) ?? targets.first
    }

    // MARK: - Lifecycle controls

    /// Runs the one-time model preflight (surfacing progress), then starts the
    /// session against the selected target. Rebuilds a fresh session first when
    /// the previous one already reached a terminal state.
    ///
    /// Speaker attribution (Phase 6/7) is engaged for this run only when the
    /// `alembic.attribution.enabled` toggle is on, `SpeakerLabelCatalog.
    /// match(bundleID:)?.markersValidated == true`, **and** the resolved
    /// meeting-window title matches that entry's `layoutRequirement`. The
    /// attributor then applies per-candidate frame-shape and marker gates for
    /// the calibrated 1-on-1 and seven-person Gallery layouts.
    func start() async {
        guard let target = selectedTarget, !isPreparingModels else { return }

        // Explicit active-session guard, duplicating `canStart`'s `session.state`
        // switch verbatim — this must run before any teardown below (in
        // particular the unconditional `attributionRuntime` cleanup) so that
        // teardown is provably never racing an active session, not merely
        // assumed safe. Keep in sync with `canStart`'s `session.state` switch.
        switch session.state {
        case .idle, .selecting, .saved, .error, .discarded: break
        case .recording, .finalizing: return
        }

        // First-run permissions gate: refuse a doomed capture with a clear,
        // actionable message instead of silently no-oping. The three permissions
        // fail independently; surface the most relevant blocker (Screen Recording
        // may need an app restart even after the user grants it).
        permissions.refresh()
        if !permissions.isReadyToRecord {
            startupBlocker = permissions.primaryBlocker
            preparationError = startupBlocker?.guidance.message
            return
        }
        startupBlocker = nil

        if AppModel.isTerminal(session.state) {
            session = AppModel.makeSession(localeBox: localeBox, vocabularyBox: vocabularyBox, contextBox: contextBox)
            await refreshTargets()
        }

        preparationError = nil
        modelDownloadProgress = nil
        isPreparingModels = true

        // Surface install progress while preflight runs.
        let progress = assetManager.progress
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            for await value in progress { self?.modelDownloadProgress = value }
        }

        do {
            let locale = try await assetManager.preflight()
            localeBox.set(locale)
        } catch {
            isPreparingModels = false
            progressTask?.cancel()
            startupBlocker = AppModel.blocker(for: error)
            preparationError = startupBlocker?.guidance.message ?? String(describing: error)
            return
        }

        progressTask?.cancel()

        // Load vocabulary off the main actor (file I/O may be slow for large folders).
        let (sourceCount, vocabResult) = await Task.detached(priority: .userInitiated) {
            let sources = VocabularyStore.configuredSources()
            return (sources.count, VocabularyStore.load(sources: sources))
        }.value
        vocabularyBox.set(vocabResult.terms)
        print("[alembic] Vocabulary loaded: \(vocabResult.terms.count) terms " +
              "from \(sourceCount) source\(sourceCount == 1 ? "" : "s")" +
              "\(vocabResult.truncated ? " (truncated)" : "")")

        // Assemble meeting context off the main actor (CGWindowList can block).
        // isPreparingModels stays true until the context is published so a second
        // start() invocation cannot interleave while the session is still idle.
        // `appMatch` is resolved once and reused for the three `fullTitle` inputs
        // below and for the strict attribution title probe (§0.5) — a distinct
        // lookup/type from `speakerEntry` (the `markersValidated` gate, §0.4):
        // `appMatch` has no `markersValidated` field, `speakerEntry` has no
        // title/hints fields — never conflate the two.
        let attributionEnabled = UserDefaults.standard.bool(forKey: "alembic.attribution.enabled")
        let appMatch = MeetingAppCatalog.match(bundleID: target.id)
        let speakerEntry = SpeakerLabelCatalog.match(bundleID: target.id)

        // Unconditional teardown of any previous run's attribution runtime, for
        // every start() call reaching this point — not only when this run goes
        // on to be gated — so a previously-gated run's runtime/diagnostic never
        // lingers into a subsequent toggle-off or unvalidated-catalog run. Safe
        // by construction of the active-session guard above: no start() call
        // can reach this point while session.state was .recording/.finalizing,
        // so any runtime torn down here was necessarily armed against a session
        // that has already reached a terminal state.
        await attributionRuntime?.cleanup()
        attributionRuntime = nil
        attributionDiagnostic = nil

        // Two independent gates, evaluated in order (§0.4/§0.5): (1) the
        // toggle + calibration gate (unrelated to which specific meeting is
        // about to be joined — cheap, checked first, no window-title probe
        // needed to answer it), then (2) the resolved meeting-window gate
        // (catalog data, not a hard-coded Teams special case —
        // `SpeakerLabelCatalog.AppEntry.matchesLayout(meetingTitle:)`). Both
        // must hold before video is upgraded to `.audioPlusAttribution` or
        // `VisionSpeakerAttributor` is constructed. Per-frame catalog
        // signatures then fail closed for unsupported on-screen layouts.
        let calibrationGated = attributionEnabled && (speakerEntry?.markersValidated ?? false)
        let meetingTitle: String? = calibrationGated
            ? await Task.detached(priority: .userInitiated) {
                appMatch.flatMap { WindowTitleProbe.meetingWindowTitle(for: $0) }
            }.value
            : nil
        let attributionGated = calibrationGated && (speakerEntry?.matchesLayout(meetingTitle: meetingTitle) ?? false)

        // Augmented rebuild (only when attributionGated): construct the
        // attribution-mode capture source + owned runtime and rebuild `session`
        // a second time around it. When !attributionGated, this is skipped
        // entirely — `session` is left exactly as the base rebuild produced it,
        // and `attributionRuntime` stays nil (already cleared above).
        var attributionSource: ScreenCaptureKitSource?
        if attributionGated {
            let (source, runtime) = await AppModel.makeAttributionRuntime(target: target, meetingTitle: meetingTitle)
            session = AppModel.buildSession(
                source: source,
                attributionProvider: runtime.attributor,
                localeBox: localeBox,
                vocabularyBox: vocabularyBox,
                contextBox: contextBox
            )
            attributionRuntime = runtime
            attributionSource = source
        }

        let appHints = appMatch?.app.titleHints ?? []
        let exclusions = appMatch?.app.nonMeetingTitlePrefixes ?? []
        let trailingStrips = appMatch?.app.titleTrailingStrips ?? []
        let windowTitle = await Task.detached(priority: .userInitiated) {
            WindowTitleProbe.fullTitle(forBundleID: target.id, appHints: appHints, exclusions: exclusions, trailingStrips: trailingStrips)
        }.value
        let ctx = MeetingContext(
            windowTitle: windowTitle,
            appDisplayName: target.displayName,
            bundleID: target.id,
            localeIdentifier: localeBox.locale.identifier,
            startDate: Date()
        )
        contextBox.set(ctx)

        // Auto-started sessions get the silent-discard safety net; a deliberate
        // manual recording is never self-destructed.
        let discardWindow: TimeInterval? = autoStartedTarget != nil ? AppModel.silentDiscardWindow : nil
        await session.start(target: target, discardIfSilentAfter: discardWindow)
        isPreparingModels = false

        if attributionGated {
            // Review-4 fix: only arm the runtime's lifecycle when `session.start`
            // actually reached `.recording`. On any other resulting state (engine
            // start / writer-open / capture-start failure all transition to
            // `.error` inside `MeetingSession.start` and return before this
            // point) there is nothing to watch — arming would leave a lifecycle
            // task waiting on a session that is already terminal, so clean up
            // and clear the runtime instead of arming it.
            if case .recording = session.state, let attributionSource {
                attributionRuntime?.armLifecycle(
                    session: session,
                    diagnostics: attributionSource.attributionDiagnostics,
                    onDiagnostic: { [weak self] text in
                        self?.attributionDiagnostic = text
                        print("[alembic] Attribution diagnostic: \(text)")
                    }
                )
            } else {
                // Phase 7 §3e fix (Phase 6 impl-review-1 MEDIUM-1): capture the
                // runtime to clean up and clear `attributionRuntime` in one
                // synchronous step, *before* the `await` below — `isPreparingModels`
                // is already `false` at this point (set just above), so a fast
                // concurrent `start()` call can pass this function's entry guard
                // and construct+assign a *new* `attributionRuntime` while this
                // branch's cleanup is suspended. Re-reading the shared property
                // after that `await` (the previous shape:
                // `await attributionRuntime?.cleanup(); attributionRuntime = nil`)
                // would nil out that newer runtime instead of the one actually
                // being cleaned up, leaking the newer runtime's
                // `VisionSpeakerAttributor`/frame stream. Capturing into a local
                // binding first, and only ever clearing/awaiting on that local
                // capture, makes the hand-off atomic from a concurrent start()'s
                // point of view: it either observes `attributionRuntime == nil`
                // (already handed off here) or the pre-existing runtime — never a
                // runtime this branch is about to silently drop.
                let runtimeToCleanup = attributionRuntime
                attributionRuntime = nil
                attributionDiagnostic = nil
                await runtimeToCleanup?.cleanup()
            }
        }

        // Fire-and-forget: the disclosure poster retries for several seconds
        // while the meeting UI settles, so it must not block start()'s caller
        // (the detection handler) — otherwise back-to-back meeting transitions
        // would stall behind it.
        Task { await maybeDisclose(target: target, meetingTitle: windowTitle) }
    }

    /// Reads the current disclosure configuration from `UserDefaults`.
    private static func disclosureConfig() -> DisclosurePolicy.Config {
        let d = UserDefaults.standard
        let stored = d.string(forKey: DisclosurePolicy.DefaultsKey.message) ?? ""
        // teamsOnly defaults to true when the user has never set it.
        let teamsOnly = d.object(forKey: DisclosurePolicy.DefaultsKey.teamsOnly) == nil
            ? true
            : d.bool(forKey: DisclosurePolicy.DefaultsKey.teamsOnly)
        return DisclosurePolicy.Config(
            enabled: d.bool(forKey: DisclosurePolicy.DefaultsKey.enabled),
            message: stored.isEmpty ? DisclosurePolicy.defaultMessage : stored,
            autoSend: d.bool(forKey: DisclosurePolicy.DefaultsKey.autoSend),
            teamsOnly: teamsOnly
        )
    }

    /// Posts (or stages) the one-time transcription disclosure for the session
    /// that just started, per `DisclosurePolicy`. Runs once per start; the
    /// outcome is published to ``disclosureStatus`` and never silently dropped.
    private func maybeDisclose(target: CaptureTarget, meetingTitle: String?) async {
        let config = AppModel.disclosureConfig()
        let isTeams = target.id.lowercased().hasPrefix("com.microsoft.teams")

        switch DisclosurePolicy.decide(config: config, isTeams: isTeams, alreadyPosted: false) {
        case .skip(let reason):
            disclosureStatus = DisclosurePolicy.Result.skipped(reason: reason).statusMessage
        case .stageToClipboard:
            let text = DisclosurePolicy.renderMessage(template: config.message, meetingTitle: meetingTitle)
            TeamsChatPoster.copyToClipboard(text)
            disclosureStatus = DisclosurePolicy.Result.stagedToClipboard.statusMessage
        case .post:
            let text = DisclosurePolicy.renderMessage(template: config.message, meetingTitle: meetingTitle)
            let result = await teamsChatPoster.post(text, meetingTitle: meetingTitle)
            disclosureStatus = result.statusMessage
        }
    }

    /// Maps a speech-asset preflight error onto an actionable ``StartupBlocker``.
    /// Unknown errors fall back to a generic capture-stopped message so nothing
    /// is ever a silent no-op.
    private static func blocker(for error: Error) -> StartupBlocker {
        switch error {
        case TranscriptionEngineError.localeUnsupported(let id):
            return .localeUnsupported(id)
        case TranscriptionEngineError.assetInstallFailed(let detail):
            return .assetInstallFailed(detail)
        case TranscriptionEngineError.transcriberUnavailable:
            return .assetInstallFailed("on-device speech transcription is unavailable on this device")
        default:
            return .captureStopped(String(describing: error))
        }
    }

    /// Stops the active session and drains all pipelines (writer closes last).
    func stop() async {
        autoStartedTarget = nil
        await session.stop()
    }

    /// Reveals the canonical transcript file in Finder, when one exists.
    func revealTranscript() {
        guard let url = session.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Disclosure (Accessibility capability)

    /// Whether Alembic is currently trusted for Accessibility, required only for
    /// the disclosure *auto-post* path (never for recording).
    var isAccessibilityTrusted: Bool { AccessibilityAuthorization.isTrusted() }

    /// Prompts for Accessibility trust (used by the disclosure settings).
    func requestAccessibilityTrust() { AccessibilityAuthorization.requestTrust() }

    /// Opens the Accessibility pane in System Settings.
    func openAccessibilitySettings() {
        guard let url = URL(string: AccessibilityAuthorization.settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Auto-start

    /// Enables or disables automatic meeting detection, persisting the preference.
    func setAutoStartEnabled(_ enabled: Bool) {
        autoStartEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "alembic.autostart.enabled")
        if enabled { startDetector() } else { stopDetector() }
    }

    private func startDetector() {
        guard detector == nil else { return }
        let audioMonitor = AudioProcessMonitor()
        let det = MeetingDetector(
            snapshotProvider: { audioMonitor.snapshot() },
            titleProbe: { states in
                let confirmApps = MeetingAppCatalog.apps.filter { $0.requiresTitleConfirmation }
                guard !confirmApps.isEmpty else { return [] }
                return WindowTitleProbe.presentHints(for: confirmApps, processStates: states)
            },
            meetingTitleProvider: { match in
                WindowTitleProbe.meetingWindowTitle(for: match)
            }
        )
        detector = det

        let deviceMonitor = DeviceActivityMonitor()
        let (wakeUps, wakeUpsCont) = AsyncStream<Bool>.makeStream()

        detectorTask = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await det.run(wakeUps: wakeUps) }
                group.addTask {
                    for await active in deviceMonitor.stream {
                        guard !Task.isCancelled else { break }
                        wakeUpsCont.yield(active)
                    }
                    wakeUpsCont.finish()
                }
            }
        }

        consumerTask = Task { @MainActor [weak self] in
            for await detection in det.detections {
                await self?.handleDetection(detection)
            }
        }
    }

    private func stopDetector() {
        detectorTask?.cancel()
        consumerTask?.cancel()
        detectionRetryTask?.cancel()
        detectorTask = nil
        consumerTask = nil
        detectionRetryTask = nil
        pendingDetection = nil
        detector = nil
    }

    @MainActor private func handleDetection(_ detection: Detection?) async {
        // Any fresh event supersedes a parked retry.
        detectionRetryTask?.cancel()
        detectionRetryTask = nil
        pendingDetection = nil

        if let d = detection {
            // Don't interrupt any active session (user-initiated or auto-started).
            switch session.state {
            case .recording, .finalizing: return
            default: break
            }
            if await attemptAutoStart(d) { return }
            // Blocked (model preflight mid-flight, target not enumerable yet,
            // permission hiccup): park the detection and keep trying — the
            // detector only emits on *changes*, so bailing here would skip the
            // whole meeting.
            scheduleDetectionRetry(d)
        } else {
            // Detection ended — only auto-stop if this session was auto-started.
            guard autoStartedTarget != nil else { return }
            autoStartedTarget = nil
            await stop()
        }
    }

    /// Tries to begin recording for a confirmed detection. Returns `false`
    /// when blocked so the caller can park and retry.
    @MainActor private func attemptAutoStart(_ d: Detection) async -> Bool {
        guard !isPreparingModels else { return false }

        // Re-enumerate capture targets before auto-starting. The launch-time
        // target list is stale for any meeting app launched after Alembic
        // (e.g. Zoom started later in the day), which previously caused the
        // detection to fire but find no target and silently bail. Rebuild a
        // terminal session first so enumeration runs against a live source.
        if AppModel.isTerminal(session.state) {
            session = AppModel.makeSession(localeBox: localeBox, vocabularyBox: vocabularyBox, contextBox: contextBox)
        }
        await refreshTargets()

        let prefix = d.canonicalBundlePrefix.lowercased()
        let target = session.availableTargets.first(where: { t in
            let id = t.id.lowercased()
            return id == prefix || id.hasPrefix(prefix + ".")
        })
        guard let target else { return false }
        selectedTarget = target
        autoStartedTarget = target
        await start()
        if case .recording = session.state { return true }
        autoStartedTarget = nil
        return false
    }

    /// Retries a parked detection every `detectionRetryInterval` seconds, up
    /// to `detectionRetryAttempts` times. Gives up (with a visible notice)
    /// only after the window is exhausted, or silently when the detection is
    /// superseded or a session starts by other means.
    @MainActor private func scheduleDetectionRetry(_ d: Detection) {
        pendingDetection = d
        detectionRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<AppModel.detectionRetryAttempts {
                try? await Task.sleep(for: .seconds(AppModel.detectionRetryInterval))
                guard let self, !Task.isCancelled else { return }
                guard self.pendingDetection == d else { return }
                switch self.session.state {
                case .recording, .finalizing:
                    self.pendingDetection = nil
                    return
                default: break
                }
                if await self.attemptAutoStart(d) {
                    self.pendingDetection = nil
                    return
                }
            }
            guard let self, self.pendingDetection == d else { return }
            self.pendingDetection = nil
            self.preparationError =
                "Auto-start: detected a \(d.app.displayName) meeting but couldn't begin recording"
        }
    }

    /// Relaunches the app, used to recover from the Screen Recording
    /// "granted-but-needs-restart" condition. Spawns a detached `open` on the
    /// app bundle (which launchd keeps alive past our termination) and then
    /// quits, so the relaunched process picks up the now-effective grant.
    func quitAndReopen() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    /// Refreshes permission status (no prompts), e.g. when the menu opens.
    func refreshPermissions() {
        permissions.refresh()
        if permissions.isReadyToRecord { startupBlocker = nil }
    }

    // MARK: - Derived UI state

    /// Start is allowed with a target chosen, not mid-preflight, and the session
    /// idle/selecting or already finished (a finished session is rebuilt).
    /// Keep in sync with `start()`'s explicit active-session guard, which
    /// duplicates this `session.state` switch verbatim.
    var canStart: Bool {
        guard selectedTarget != nil, !isPreparingModels else { return false }
        switch session.state {
        case .idle, .selecting, .saved, .error, .discarded: return true
        case .recording, .finalizing: return false
        }
    }

    /// Stop is allowed only while capturing or draining.
    var canStop: Bool {
        switch session.state {
        case .recording, .finalizing: return true
        default: return false
        }
    }

    /// Reveal is allowed once a transcript file path exists.
    var canReveal: Bool { session.outputURL != nil }

    /// SF Symbol for the menu-bar item; filled while actively recording/draining.
    var menuBarSymbol: String {
        switch session.state {
        case .recording, .finalizing: return "waveform.circle.fill"
        default: return "waveform"
        }
    }

    /// Session-relative elapsed time as `hh:mm:ss` (reuses the writer's formatter
    /// so the menu, window, and on-disk readable render agree exactly).
    var elapsedString: String { TranscriptWriter.timestamp(from: session.elapsedDuration) }

    /// One-line status for the menu and window header.
    var statusText: String {
        if isPreparingModels {
            if let progress = modelDownloadProgress, progress < 1 {
                return "Preparing models… \(Int((progress * 100).rounded()))%"
            }
            return "Preparing models…"
        }
        if let preparationError { return "Setup error: \(preparationError)" }
        switch session.state {
        case .idle: return "Idle"
        case .selecting: return "Ready — choose a target"
        case .recording: return "Recording — \(elapsedString)"
        case .finalizing: return "Finalizing…"
        case .saved: return "Saved — \(elapsedString)"
        case .error(let message): return "Error: \(message)"
        case .discarded(let reason): return "Discarded — \(reason)"
        }
    }

    private static func isTerminal(_ state: SessionState) -> Bool {
        switch state {
        case .saved, .error, .discarded: return true
        default: return false
        }
    }
}

/// Owns a single `start()` call's `VisionSpeakerAttributor` plus its two
/// background tasks (a session-end lifecycle watcher and a diagnostics
/// consumer), so there is exactly one place — ``cleanup()`` — that cancels
/// everything for a given attribution-engaged run (Phase 6, §0.7).
///
/// `VisionSpeakerAttributor` is a concrete type with its own `stop()` —
/// `AttributionProvider` (the protocol `MeetingSession` holds) has no `stop()`,
/// so `MeetingSession` structurally cannot call it. `MeetingSession.stop()` and
/// its error paths all eventually finish `ScreenCaptureKitSource.frames`, so
/// the attributor's frame-consumption loop does terminate on its own — but
/// calling `.stop()` explicitly cancels an in-flight `RecognizeTextRequest`
/// immediately rather than waiting for the stream to finish naturally.
///
/// `@unchecked Sendable`: every access to this type happens from `AppModel`,
/// which is `@MainActor`-isolated — there is never more than one thread
/// touching a given instance. The `@unchecked` conformance is what lets
/// `AppModel.start()` (and its `attributionRuntime?.cleanup()` calls) `await`
/// this class's async methods without the compiler requiring proof the type
/// itself synchronizes concurrent access, which it does not need to given
/// that single-actor discipline.
private final class AttributionRuntime: @unchecked Sendable {
    let attributor: VisionSpeakerAttributor
    private var diagnosticsTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?

    init(attributor: VisionSpeakerAttributor) {
        self.attributor = attributor
    }

    /// Starts the diagnostics consumer and the session-end watcher. Captures
    /// the *specific* session/attributor this runtime was built for as locals,
    /// so a later resumption can never be misdirected at a different runtime's
    /// session — even if `AppModel` has since rebuilt `session`/
    /// `attributionRuntime` again.
    func armLifecycle(
        session: MeetingSession,
        diagnostics: AsyncStream<CaptureSourceError>,
        onDiagnostic: @escaping @MainActor @Sendable (String) -> Void
    ) {
        let watchedSession = session
        let watchedAttributor = attributor
        lifecycleTask = Task {
            await watchedSession.waitUntilFinished()
            // `waitUntilFinished()` is a plain checked-continuation wait with no
            // cancellation handler — cancelling this Task does NOT make the
            // await above return early; it only prevents the `.stop()` call
            // below from running once the (uncancelled) await does eventually
            // resume. This guard is what makes cancellation safe, not a
            // property of `waitUntilFinished()` itself.
            guard !Task.isCancelled else { return }
            await watchedAttributor.stop()
        }
        diagnosticsTask = Task {
            for await diagnostic in diagnostics {
                guard !Task.isCancelled else { break }
                await onDiagnostic(diagnostic.description)
            }
        }
    }

    /// Cancels both background tasks and stops the attributor immediately.
    /// Called on every path that discards this runtime, whether or not
    /// `armLifecycle` ever ran (a `session.start` that fails to reach
    /// `.recording`; `AppModel`'s rebuild-cancel-previous path at the top of
    /// every `start()` call).
    func cleanup() async {
        diagnosticsTask?.cancel()
        lifecycleTask?.cancel()
        await attributor.stop()
    }
}

/// Thread-safe, `Sendable` holder for the preflight-resolved `Locale`.
///
/// The session's engine factory is `@Sendable` and synchronous, so it cannot
/// `await` the asset preflight. Instead it captures this box; `AppModel.start`
/// resolves the locale via `SpeechAssetManager.preflight()` and stores it here
/// **before** calling `session.start`, so the factory reads the installed locale
/// when it lazily builds each per-source engine. Defaults to `Locale.current`.
final class LocaleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Locale = .current

    var locale: Locale {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Locale) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

/// Thread-safe, `Sendable` holder for the session-start vocabulary terms.
///
/// Follows the same bridge pattern as `LocaleBox`: `AppModel.start` loads
/// vocabulary off-actor and stores it here **before** `session.start`, so the
/// `@Sendable` engine factory can read it synchronously when the session builds
/// its per-source `SpeechAnalyzerEngine` instances.
final class VocabularyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []

    var terms: [String] {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: [String]) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

/// Thread-safe, `Sendable` holder for the session-start meeting context.
///
/// Follows the same bridge pattern as `LocaleBox` and `VocabularyBox`:
/// `AppModel.start` assembles the context off-actor and stores it here
/// **before** `session.start`, so the `@Sendable` `makeWriter` factory reads
/// the published context synchronously when the session opens its transcript.
final class MeetingContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MeetingContext = MeetingContext()

    var context: MeetingContext {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: MeetingContext) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

private extension String {
    /// Returns `nil` when the string is empty (convenience for optional paths).
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
