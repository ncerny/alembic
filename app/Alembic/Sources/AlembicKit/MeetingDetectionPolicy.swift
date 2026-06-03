import Foundation

// MARK: - DetectionPhase

/// The phase of the meeting-detection state machine.
public enum DetectionPhase: Equatable, Sendable {
    /// No active meeting signal.
    case idle
    /// A candidate signal arrived; waiting for `startDebounce` to confirm.
    case confirming
    /// A meeting is confirmed active.
    case active
    /// The signal dropped; waiting for `endDebounce` before declaring end-of-call.
    case ending
}

// MARK: - MeetingDetectionPolicy

/// Pure, Foundation-only meeting-presence state machine.
///
/// Feed timestamped boolean samples ("is a known meeting app currently holding
/// audio?") via `processSample(isInCall:now:)`. The policy tracks elapsed time
/// using an injected monotonic clock value (`now`) and transitions between
/// phases only after the configured debounce windows.
///
/// ## State transitions
///
/// ```
/// idle ──(true)──▶ confirming ──(elapsed ≥ startDebounce)──▶ active
///                  ◀──(false)───────┘                          │
///                                                            ending ──(elapsed ≥ endDebounce)──▶ idle
///                                                              ▲──(true)──┘ (re-enter during ending → active)
/// ```
///
/// ## Monotonic clock requirement
/// `now` must be monotonically non-decreasing across calls. Use
/// `ProcessInfo.processInfo.systemUptime` or host-time seconds, never
/// wall-clock time (which can jump).
public struct MeetingDetectionPolicy: Sendable {

    /// Seconds of sustained in-call signal required before transitioning
    /// `confirming → active`. Default: 4 seconds.
    public let startDebounce: TimeInterval

    /// Seconds of sustained no-call signal required before transitioning
    /// `ending → idle`. Default: 8 seconds.
    public let endDebounce: TimeInterval

    /// Current phase of the state machine.
    public private(set) var phase: DetectionPhase

    /// Monotonic timestamp when the current phase was entered.
    private var phaseEnteredAt: TimeInterval

    public init(
        startDebounce: TimeInterval = 4.0,
        endDebounce: TimeInterval = 8.0
    ) {
        self.startDebounce = startDebounce
        self.endDebounce = endDebounce
        self.phase = .idle
        self.phaseEnteredAt = 0
    }

    /// Feeds one boolean sample into the state machine and returns the
    /// resulting `DetectionPhase` after applying transition logic.
    ///
    /// - Parameters:
    ///   - isInCall: `true` when a known meeting app currently holds audio.
    ///   - now: Monotonic timestamp in seconds (e.g.
    ///     `ProcessInfo.processInfo.systemUptime`). Must be non-decreasing.
    @discardableResult
    public mutating func processSample(isInCall: Bool, now: TimeInterval) -> DetectionPhase {
        switch phase {
        case .idle:
            if isInCall {
                phase = .confirming
                phaseEnteredAt = now
            }

        case .confirming:
            if !isInCall {
                // False alarm — signal dropped before debounce; back to idle.
                phase = .idle
                phaseEnteredAt = now
            } else if now - phaseEnteredAt >= startDebounce {
                phase = .active
                phaseEnteredAt = now
            }

        case .active:
            if !isInCall {
                phase = .ending
                phaseEnteredAt = now
            }

        case .ending:
            if isInCall {
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

    /// Resets the state machine to `idle`.
    public mutating func reset() {
        phase = .idle
        phaseEnteredAt = 0
    }
}
