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

    // MARK: Auto-start detector (not observed)

    @ObservationIgnored private var detector: MeetingDetector?
    @ObservationIgnored private var detectorTask: Task<Void, Never>?
    @ObservationIgnored private var consumerTask: Task<Void, Never>?
    /// Non-nil when the current session was started automatically. Used to guard
    /// against stopping a user-initiated session and to allow auto-stop when the
    /// detected call ends.
    @ObservationIgnored private var autoStartedTarget: CaptureTarget?

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

    /// Builds a fully wired production ``MeetingSession``.
    ///
    /// This is the single bridge between SwiftUI/AppKit and the macOS platform
    /// adapters. It:
    /// - uses `ScreenCaptureKitSource` as the audio source,
    /// - feeds the source's live `meterUpdates` straight into the orchestrator,
    /// - maps the source's typed `errors` channel onto the orchestrator's plain
    ///   `String` error stream (the orchestrator is Apple-free by contract),
    /// - builds one `SpeechAnalyzerEngine` per `SourceTag` against the locale
    ///   resolved by preflight (read from `localeBox` at start time),
    /// - opens a `TranscriptWriter` under `~/Documents/Alembic/`, and
    /// - anchors the session clock origin on the same monotonic host-time basis
    ///   the source uses (`HostClock.now()`), so engine/source times align.
    private static func makeSession(localeBox: LocaleBox, vocabularyBox: VocabularyBox, contextBox: MeetingContextBox) -> MeetingSession {
        let source = ScreenCaptureKitSource()

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
            clockOrigin: { HostClock.now() }
        )
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
    func start() async {
        guard let target = selectedTarget, !isPreparingModels else { return }

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
        let appHints = MeetingAppCatalog.match(bundleID: target.id)?.app.titleHints ?? []
        let exclusions = MeetingAppCatalog.match(bundleID: target.id)?.app.nonMeetingTitlePrefixes ?? []
        let windowTitle = await Task.detached(priority: .userInitiated) {
            WindowTitleProbe.fullTitle(forBundleID: target.id, appHints: appHints, exclusions: exclusions)
        }.value
        let ctx = MeetingContext(
            windowTitle: windowTitle,
            appDisplayName: target.displayName,
            bundleID: target.id,
            localeIdentifier: localeBox.locale.identifier,
            startDate: Date()
        )
        contextBox.set(ctx)

        await session.start(target: target)
        isPreparingModels = false
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
        detectorTask = nil
        consumerTask = nil
        detector = nil
    }

    @MainActor private func handleDetection(_ detection: Detection?) async {
        if let d = detection {
            // Don't interrupt any active session (user-initiated or auto-started).
            switch session.state {
            case .recording, .finalizing: return
            default: break
            }
            guard !isPreparingModels else { return }

            let prefix = d.canonicalBundlePrefix.lowercased()
            let target = session.availableTargets.first(where: { t in
                let id = t.id.lowercased()
                return id == prefix || id.hasPrefix(prefix + ".")
            })
            guard let target else { return }
            selectedTarget = target
            autoStartedTarget = target
            await start()
        } else {
            // Detection ended — only auto-stop if this session was auto-started.
            guard autoStartedTarget != nil else { return }
            autoStartedTarget = nil
            await stop()
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
    var canStart: Bool {
        guard selectedTarget != nil, !isPreparingModels else { return false }
        switch session.state {
        case .idle, .selecting, .saved, .error: return true
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
        }
    }

    private static func isTerminal(_ state: SessionState) -> Bool {
        switch state {
        case .saved, .error: return true
        default: return false
        }
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
