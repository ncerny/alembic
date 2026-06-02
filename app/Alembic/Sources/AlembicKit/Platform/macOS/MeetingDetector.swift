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
}

// MARK: - MeetingDetector

/// Fuses `AudioProcessMonitor` snapshots, `MeetingDetectionPolicy` debouncing,
/// and (optionally) `WindowTitleProbe` title hints into an `AsyncStream<Detection?>`.
///
/// **Design:** `tick()` is the single synchronous entry point and is public so
/// `AlembicCheck` can drive it deterministically without timing dependencies.
/// The production async `run(wakeUps:)` loop calls `tick()` on every device-
/// activity wake-up from `DeviceActivityMonitor` and on a bounded safety poll.
///
/// **Conflict rules** (delegated to `MeetingAppCatalog.detectInCall`):
/// - Single in-call app → emit it.
/// - Multiple in-call apps: output-active wins; still tied → emit `nil` (no
///   guess — do not auto-start).
///
/// **Thread safety:** `tick()` guards mutable state with `NSLock`.
/// `@unchecked Sendable` because the lock covers all mutation.
public final class MeetingDetector: @unchecked Sendable {

    private let snapshotProvider: @Sendable () -> [AudioProcessState]
    private let nowProvider: @Sendable () -> TimeInterval
    private let titleProbe: (@Sendable ([AudioProcessState]) -> Set<String>)?
    private let safetyPollInterval: TimeInterval

    private let lock = NSLock()
    private var policy: MeetingDetectionPolicy
    private var lastEmittedDetection: Detection?

    public let detections: AsyncStream<Detection?>
    private let detectionsCont: AsyncStream<Detection?>.Continuation

    /// - Parameters:
    ///   - snapshotProvider: Returns current `AudioProcessState` array (excluding own PID).
    ///   - nowProvider: Monotonic clock for `MeetingDetectionPolicy`. Defaults to `systemUptime`.
    ///   - titleProbe: Optional title-hint provider for `requiresTitleConfirmation` apps.
    ///     Receives the current process states; returns confirmed title hint substrings.
    ///   - policy: Initial policy state. Override for testing (e.g. shorter debounces).
    ///   - safetyPollInterval: Interval in seconds for the background safety poll in `run(wakeUps:)`.
    public init(
        snapshotProvider: @escaping @Sendable () -> [AudioProcessState],
        nowProvider: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        titleProbe: (@Sendable ([AudioProcessState]) -> Set<String>)? = nil,
        policy: MeetingDetectionPolicy = MeetingDetectionPolicy(),
        safetyPollInterval: TimeInterval = 12.0
    ) {
        self.snapshotProvider = snapshotProvider
        self.nowProvider = nowProvider
        self.titleProbe = titleProbe
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
    /// - `.some(.some(d))` — detection started; `d` was emitted to `detections`.
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
        let titles: Set<String>
        if confirmedTitles.isEmpty, let probe = titleProbe {
            titles = probe(states)
        } else {
            titles = confirmedTitles
        }

        let matchOrNil = MeetingAppCatalog.detectInCall(processStates: states, confirmedTitles: titles)
        let isInCall = matchOrNil != nil

        let hasOutput: Bool
        if let match = matchOrNil {
            let p = match.canonicalBundlePrefix.lowercased()
            hasOutput = states.contains { s in
                let id = s.bundleID.lowercased()
                return (id == p || id.hasPrefix(p + ".")) && s.isRunningOutput
            }
        } else {
            hasOutput = false
        }

        return lock.withLock {
            let phase = policy.processSample(isInCall: isInCall, now: actualNow)

            // Determine what (if anything) to emit.
            // - .active + match    → emit the Detection (call started or changed)
            // - .idle              → emit nil only if we previously had a Detection
            //                        (signals call ended; debounced by the policy)
            // - .confirming/.ending → return .none (intermediate; no commitment yet)
            let newDetection: Detection?
            switch phase {
            case .active:
                guard let m = matchOrNil else { return .none }
                newDetection = Detection(
                    app: m.app,
                    canonicalBundlePrefix: m.canonicalBundlePrefix,
                    hasOutput: hasOutput
                )
            case .idle where lastEmittedDetection != nil:
                newDetection = nil
            default:
                return .none
            }

            guard newDetection != lastEmittedDetection else { return .none }
            lastEmittedDetection = newDetection
            detectionsCont.yield(newDetection)
            return .some(newDetection)
        }
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

    /// Resets the policy and last-emitted detection. Useful after a session ends
    /// to avoid a stale idle state preventing the next detection cycle.
    public func reset() {
        lock.withLock {
            policy.reset()
            lastEmittedDetection = nil
        }
    }
}
