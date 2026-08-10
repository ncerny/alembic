import Foundation

// MARK: - Detection

/// The result of a confirmed meeting detection, emitted by `MeetingDetector`
/// when the detection policy reaches the `active` phase.
///
/// `canonicalBundlePrefix` is the specific bundle-ID prefix that matched — use
/// it to resolve a `CaptureTarget` via ScreenCaptureKit (it matches the format
/// of `CaptureTarget.id`).
public struct Detection: Sendable, Equatable {
    /// The matched catalog entry.
    public let app: MeetingApp
    /// The canonical prefix for resolving a `CaptureTarget`.
    public let canonicalBundlePrefix: String
    /// `true` when at least one matching process had output active — higher
    /// confidence that far-end call audio is being received.
    public let hasOutput: Bool
    /// Which evidence tier confirmed this detection (interactive call vs
    /// output-only broadcast).
    public let tier: DetectionTier

    public init(
        app: MeetingApp,
        canonicalBundlePrefix: String,
        hasOutput: Bool,
        tier: DetectionTier = .interactive
    ) {
        self.app = app
        self.canonicalBundlePrefix = canonicalBundlePrefix
        self.hasOutput = hasOutput
        self.tier = tier
    }
}

// MARK: - MeetingDetector

/// Fuses `AudioProcessMonitor` snapshots, `MeetingDetectionPolicy` debouncing,
/// and (optionally) `WindowTitleProbe` hints into an `AsyncStream<Detection?>`.
///
/// **Design:** `tick()` is the single synchronous entry point and is public so
/// `AlembicCheck` can drive it deterministically without timing dependencies.
/// The production async `run(wakeUps:)` loop calls `tick()` on every device-
/// activity wake-up from `DeviceActivityMonitor` and on a bounded safety poll.
///
/// **Tiers** (see `MeetingAppCatalog.detectCandidates`):
/// - `.interactive` evidence confirms after the short start debounce.
/// - `.broadcastCandidate` evidence (output-only town halls) additionally
///   requires a strict meeting-window title from `meetingTitleProvider` and
///   confirms only after the long broadcast debounce — so a notification
///   chime's lingering output stream can never start a session.
///
/// **Stickiness:** once a detection is active, only the detected app's own
/// process family feeds the policy signal. Another catalog app briefly holding
/// audio (a Slack chime during a Teams meeting) cannot end or hijack the
/// session. Interactive sessions persist while the family runs *input* — the
/// mic is held continuously during a call (even muted; verified live via
/// audio-watch) and released instantly at hang-up, so input-drop ends the
/// session within `endDebounce` instead of riding the family's ~11.5 s
/// post-call output linger. Broadcast sessions persist while it runs output.
///
/// **Back-to-back split:** while active, when the app's strict meeting-window
/// title changes to a different non-nil value and stays changed for
/// `titleChangeStability` seconds, the detector emits `nil` followed
/// immediately by a fresh `Detection` — so consecutive meetings with no audio
/// gap still produce separate sessions. A title that *disappears* (window
/// minimized) never triggers a split.
///
/// **Thread safety:** `tick()` guards mutable state with `NSLock`.
/// `@unchecked Sendable` because the lock covers all mutation.
public final class MeetingDetector: @unchecked Sendable {

    private let snapshotProvider: @Sendable () -> [AudioProcessState]
    private let nowProvider: @Sendable () -> TimeInterval
    private let titleProbe: (@Sendable ([AudioProcessState]) -> Set<String>)?
    private let meetingTitleProvider: (@Sendable (MeetingAppMatch) -> String?)?
    private let titleChangeStability: TimeInterval
    private let safetyPollInterval: TimeInterval

    private let lock = NSLock()
    private var policy: MeetingDetectionPolicy
    private var lastEmittedDetection: Detection?
    /// The latched candidate while `policy.phase` is active/ending.
    private var activeCandidate: MeetingAppCatalog.InCallCandidate?
    /// The strict meeting-window title observed for the active session.
    private var currentTitle: String?
    /// A differing title waiting out `titleChangeStability`.
    private var pendingTitle: String?
    private var pendingTitleSince: TimeInterval = 0

    public let detections: AsyncStream<Detection?>
    private let detectionsCont: AsyncStream<Detection?>.Continuation

    /// - Parameters:
    ///   - snapshotProvider: Returns current `AudioProcessState` array (excluding own PID).
    ///   - nowProvider: Monotonic clock for `MeetingDetectionPolicy`. Defaults to `systemUptime`.
    ///   - titleProbe: Optional title-hint provider for `requiresTitleConfirmation` apps.
    ///     Receives the current process states; returns confirmed title hint substrings.
    ///   - meetingTitleProvider: Optional strict meeting-window title lookup for an app
    ///     family (`nil` when only hub/non-meeting windows exist). Enables the broadcast
    ///     tier's title gate and back-to-back title-change splitting.
    ///   - titleChangeStability: Seconds a changed title must persist before splitting.
    ///   - policy: Initial policy state. Override for testing (e.g. shorter debounces).
    ///   - safetyPollInterval: Interval in seconds for the background safety poll in `run(wakeUps:)`.
    public init(
        snapshotProvider: @escaping @Sendable () -> [AudioProcessState],
        nowProvider: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        titleProbe: (@Sendable ([AudioProcessState]) -> Set<String>)? = nil,
        meetingTitleProvider: (@Sendable (MeetingAppMatch) -> String?)? = nil,
        titleChangeStability: TimeInterval = 6.0,
        policy: MeetingDetectionPolicy = MeetingDetectionPolicy(),
        safetyPollInterval: TimeInterval = 3.0
    ) {
        self.snapshotProvider = snapshotProvider
        self.nowProvider = nowProvider
        self.titleProbe = titleProbe
        self.meetingTitleProvider = meetingTitleProvider
        self.titleChangeStability = titleChangeStability
        self.policy = policy
        self.safetyPollInterval = safetyPollInterval
        (detections, detectionsCont) = AsyncStream<Detection?>.makeStream()
    }

    // MARK: - Tick

    /// Processes one detection cycle synchronously.
    ///
    /// Returns:
    /// - `.none` — no change in detection state (nothing emitted).
    /// - `.some(.none)` — detection ended; `nil` was emitted to `detections`.
    /// - `.some(.some(d))` — detection started (or split into a new meeting);
    ///   `d` was emitted to `detections`.
    ///
    /// When `snapshot` is `nil`, calls `snapshotProvider()`.
    /// When `confirmedTitles` is empty and a `titleProbe` was provided, it is
    /// called with the resolved snapshot to fill the confirmed-title set.
    /// When `now` is `nil`, calls `nowProvider()`.
    @discardableResult
    public func tick(
        snapshot: [AudioProcessState]? = nil,
        confirmedTitles: Set<String> = [],
        now: TimeInterval? = nil
    ) -> Detection?? {
        let states = snapshot ?? snapshotProvider()
        let actualNow = now ?? nowProvider()

        return lock.withLock {
            let signal: DetectionSignal
            let candidate: MeetingAppCatalog.InCallCandidate?

            if let active = activeCandidate {
                // Sticky: only the active app's own family feeds the signal.
                signal = Self.stickySignal(for: active, states: states)
                candidate = active
            } else {
                let titles: Set<String>
                if confirmedTitles.isEmpty, let probe = titleProbe {
                    titles = probe(states)
                } else {
                    titles = confirmedTitles
                }
                let resolved = MeetingAppCatalog.resolve(
                    MeetingAppCatalog.detectCandidates(processStates: states, confirmedTitles: titles)
                )
                candidate = resolved
                switch resolved?.tier {
                case .interactive:
                    signal = .interactive
                case .broadcastCandidate:
                    // Output-only evidence needs a real meeting window; a
                    // chime with only hub windows on screen contributes nothing.
                    if let probe = meetingTitleProvider, let match = resolved?.match {
                        signal = probe(match) != nil ? .broadcast : .none
                    } else {
                        signal = .broadcast
                    }
                case nil:
                    signal = .none
                }
            }

            let phase = policy.processSample(signal: signal, now: actualNow)

            switch phase {
            case .active:
                if activeCandidate == nil, let c = candidate {
                    // Newly confirmed: latch the app and emit.
                    activeCandidate = c
                    currentTitle = meetingTitleProvider?(c.match)
                    clearPendingTitle()
                    let d = Detection(
                        app: c.match.app,
                        canonicalBundlePrefix: c.match.canonicalBundlePrefix,
                        hasOutput: c.hasOutput,
                        tier: c.tier
                    )
                    lastEmittedDetection = d
                    detectionsCont.yield(d)
                    return .some(d)
                }
                if let split = evaluateTitleSplit(now: actualNow, states: states) {
                    return split
                }
                return .none

            case .idle:
                guard lastEmittedDetection != nil else {
                    activeCandidate = nil
                    return .none
                }
                activeCandidate = nil
                currentTitle = nil
                clearPendingTitle()
                lastEmittedDetection = nil
                detectionsCont.yield(nil)
                return .some(nil)

            case .confirming, .ending:
                return .none
            }
        }
    }

    /// Sticky persistence signal for the latched app (must hold `lock`).
    private static func stickySignal(
        for candidate: MeetingAppCatalog.InCallCandidate,
        states: [AudioProcessState]
    ) -> DetectionSignal {
        var hasInput = false
        var hasOutput = false
        for state in states {
            let id = state.bundleID.lowercased()
            let inFamily = candidate.match.app.bundlePrefixes.contains { prefix in
                let p = prefix.lowercased()
                return id == p || id.hasPrefix(p + ".")
            }
            guard inFamily else { continue }
            hasInput = hasInput || state.isRunningInput
            hasOutput = hasOutput || state.isRunningOutput
        }
        switch candidate.tier {
        case .interactive:
            // Input is the end-of-call signal. Empirically verified via
            // audio-watch on a live Teams call (2026-08-10): mute/unmute never
            // touches the family's CoreAudio input state, hang-up releases it
            // instantly, and a helper process then runs output-only for
            // ~11.5 s (the end-call sound linger). Keying persistence on
            // input ends the session ~3-4 s after hang-up instead of riding
            // the linger to ~15-17 s. A mid-call input gap (audio-device
            // switch) shorter than endDebounce re-enters .active harmlessly.
            return hasInput ? .interactive : .none
        case .broadcastCandidate:
            return hasOutput ? .broadcast : .none
        }
    }

    /// Back-to-back split check while active (must hold `lock`).
    ///
    /// Returns the emitted value when a split occurred, else `nil`.
    private func evaluateTitleSplit(now: TimeInterval, states: [AudioProcessState]) -> Detection?? {
        guard let c = activeCandidate, let probe = meetingTitleProvider else { return nil }
        let title = probe(c.match)

        guard let title else {
            // Window gone/minimized — not a meeting change.
            clearPendingTitle()
            return nil
        }
        guard let current = currentTitle else {
            // Title appeared late (e.g. window restored); adopt it.
            currentTitle = title
            clearPendingTitle()
            return nil
        }
        guard title != current else {
            clearPendingTitle()
            return nil
        }

        if pendingTitle != title {
            pendingTitle = title
            pendingTitleSince = now
            return nil
        }
        guard now - pendingTitleSince >= titleChangeStability else { return nil }

        // Stable new title → split into a fresh detection for the new meeting.
        currentTitle = title
        clearPendingTitle()
        let hasOutput = states.contains { state in
            let id = state.bundleID.lowercased()
            let inFamily = c.match.app.bundlePrefixes.contains { prefix in
                let p = prefix.lowercased()
                return id == p || id.hasPrefix(p + ".")
            }
            return inFamily && state.isRunningOutput
        }
        detectionsCont.yield(nil)
        let d = Detection(
            app: c.match.app,
            canonicalBundlePrefix: c.match.canonicalBundlePrefix,
            hasOutput: hasOutput,
            tier: c.tier
        )
        lastEmittedDetection = d
        detectionsCont.yield(d)
        return .some(d)
    }

    private func clearPendingTitle() {
        pendingTitle = nil
        pendingTitleSince = 0
    }

    // MARK: - Async run loop (production)

    /// Drives the detection loop until the task is cancelled.
    ///
    /// Runs two concurrent children inside a `TaskGroup`:
    /// 1. Wake-up loop — calls `tick()` on every event from `wakeUps`.
    /// 2. Safety poll — calls `tick()` every `safetyPollInterval` seconds to
    ///    catch any device events that were missed.
    ///
    /// Finishes `detections` on exit so consumers see a clean end-of-stream.
    public func run(wakeUps: AsyncStream<Bool>) async {
        await withTaskGroup(of: Void.self) { [self] group in
            group.addTask {
                for await _ in wakeUps {
                    guard !Task.isCancelled else { break }
                    self.tick()
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(self.safetyPollInterval))
                    guard !Task.isCancelled else { break }
                    self.tick()
                }
            }
        }
        detectionsCont.finish()
    }

    /// Resets the policy and all latched detection state. Useful after a
    /// session ends to avoid a stale idle state preventing the next cycle.
    public func reset() {
        lock.withLock {
            policy.reset()
            lastEmittedDetection = nil
            activeCandidate = nil
            currentTitle = nil
            clearPendingTitle()
        }
    }
}
