import Foundation

// MARK: - DetectionTier

/// How confident the audio evidence for a candidate detection is.
public enum DetectionTier: Sendable, Equatable {
    /// The app's full audio gate is satisfied (for Teams/Zoom/Slack:
    /// mic input AND output running) — a real two-way call.
    case interactive
    /// Output-only activity on a `broadcastEligible` app (e.g. a town hall the
    /// user attends view-only). Requires the long broadcast debounce plus a
    /// strict meeting-window title before it may become a detection.
    case broadcastCandidate
}

// MARK: - DetectionSignal

/// One timestamped sample fed into `MeetingDetectionPolicy`.
public enum DetectionSignal: Sendable, Equatable {
    /// No meeting-app audio evidence.
    case none
    /// Output-only evidence on a broadcast-eligible app.
    case broadcast
    /// Full interactive-call evidence.
    case interactive
}

// MARK: - DetectionPhase

/// The phase of the meeting-detection state machine.
public enum DetectionPhase: Equatable, Sendable {
    /// No active meeting signal.
    case idle
    /// A candidate signal arrived; waiting for its start debounce to confirm.
    case confirming
    /// A meeting is confirmed active.
    case active
    /// The signal dropped; waiting for `endDebounce` before declaring end-of-call.
    case ending
}

// MARK: - MeetingDetectionPolicy

/// Pure, Foundation-only meeting-presence state machine.
///
/// Feed timestamped `DetectionSignal` samples via
/// `processSample(signal:now:)`. The policy tracks elapsed time using an
/// injected monotonic clock value (`now`) and transitions between phases only
/// after the configured debounce windows.
///
/// ## State transitions
///
/// ```
/// idle ──(signal)──▶ confirming ──(elapsed ≥ debounce for current signal)──▶ active
///                    ◀──(none)────────┘                                        │
///                                                                            ending ──(elapsed ≥ endDebounce)──▶ idle
///                                                                              ▲──(signal)──┘ (re-enter during ending → active)
/// ```
///
/// The confirming debounce depends on the *current* signal: `.interactive`
/// confirms after `startDebounce`; `.broadcast` only after the much longer
/// `broadcastStartDebounce` (a notification chime's lingering output stream
/// must never outlast it). A signal that upgrades broadcast → interactive
/// mid-confirming keeps its already-elapsed time, so it confirms as soon as
/// the interactive threshold is met.
///
/// ## Monotonic clock requirement
/// `now` must be monotonically non-decreasing across calls. Use
/// `ProcessInfo.processInfo.systemUptime` or host-time seconds, never
/// wall-clock time (which can jump).
public struct MeetingDetectionPolicy: Sendable {

    /// Seconds of sustained interactive signal required before transitioning
    /// `confirming → active`. Default: 4 seconds.
    public let startDebounce: TimeInterval

    /// Seconds of sustained broadcast (output-only) signal required before
    /// transitioning `confirming → active`. Must comfortably exceed the
    /// ~10–15 s Electron/Chromium post-sound output linger. Default: 30 seconds.
    public let broadcastStartDebounce: TimeInterval

    /// Seconds of sustained no-call signal required before transitioning
    /// `ending → idle`. Kept short so the session finalizes promptly after the
    /// call ends. Default: 3 seconds.
    public let endDebounce: TimeInterval

    /// Current phase of the state machine.
    public private(set) var phase: DetectionPhase

    /// Monotonic timestamp when the current phase was entered.
    private var phaseEnteredAt: TimeInterval

    public init(
        startDebounce: TimeInterval = 4.0,
        broadcastStartDebounce: TimeInterval = 30.0,
        endDebounce: TimeInterval = 3.0
    ) {
        self.startDebounce = startDebounce
        self.broadcastStartDebounce = broadcastStartDebounce
        self.endDebounce = endDebounce
        self.phase = .idle
        self.phaseEnteredAt = 0
    }

    /// Feeds one signal sample into the state machine and returns the
    /// resulting `DetectionPhase` after applying transition logic.
    ///
    /// - Parameters:
    ///   - signal: the current in-call evidence (see `DetectionSignal`).
    ///   - now: Monotonic timestamp in seconds (e.g.
    ///     `ProcessInfo.processInfo.systemUptime`). Must be non-decreasing.
    @discardableResult
    public mutating func processSample(signal: DetectionSignal, now: TimeInterval) -> DetectionPhase {
        switch phase {
        case .idle:
            if signal != .none {
                phase = .confirming
                phaseEnteredAt = now
            }

        case .confirming:
            switch signal {
            case .none:
                // False alarm — signal dropped before debounce; back to idle.
                phase = .idle
                phaseEnteredAt = now
            case .interactive, .broadcast:
                // The threshold follows the *current* signal, so an upgrade
                // (broadcast → interactive) counts its already-elapsed time.
                let threshold = signal == .interactive ? startDebounce : broadcastStartDebounce
                if now - phaseEnteredAt >= threshold {
                    phase = .active
                    phaseEnteredAt = now
                }
            }

        case .active:
            if signal == .none {
                phase = .ending
                phaseEnteredAt = now
            }

        case .ending:
            if signal != .none {
                // Signal returned during end-debounce (e.g. mute/unmute blip).
                phase = .active
                phaseEnteredAt = now
            } else if now - phaseEnteredAt >= endDebounce {
                phase = .idle
                phaseEnteredAt = now
            }
        }
        return phase
    }

    /// Boolean compatibility shim: `true` maps to `.interactive`.
    @discardableResult
    public mutating func processSample(isInCall: Bool, now: TimeInterval) -> DetectionPhase {
        processSample(signal: isInCall ? .interactive : .none, now: now)
    }

    /// Resets the state machine to `idle`.
    public mutating func reset() {
        phase = .idle
        phaseEnteredAt = 0
    }
}
