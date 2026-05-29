import Foundation

/// Health of a backpressure-managed pipeline stage.
///
/// Used by the audio-input backpressure accounting to escalate from healthy, to
/// a recoverable warning, to a sustained-loss error (see `AudioInputBackpressure`).
public enum BackpressureHealth: String, Sendable, Equatable, CaseIterable {
    /// No input has been dropped.
    case ok
    /// Some input has been dropped, but not a sustained run — recoverable.
    case warning
    /// Input is being dropped in a sustained run beyond the threshold; finalized
    /// text is being lost and the session should surface a hard error.
    case error
}

/// Backpressure accounting for the **critical** audio-input path.
///
/// ## Why audio input is critical (and volatile results are not)
/// Dropping an audio input buffer means the recognizer never sees that audio, so
/// the corresponding *finalized* transcript text is permanently lost. That is
/// fundamentally different from dropping a *volatile* UI hypothesis (see
/// `VolatileResultBuffer`), which is always superseded by a later result.
///
/// This pure, injectable value type tracks enqueued vs dropped input and
/// escalates health:
/// - any drop at all flips `ok → warning` (a transient hiccup, e.g. a single
///   late buffer the bounded analyzer input stream shed);
/// - a *sustained* run of consecutive drops (>= `sustainedDropThreshold`, i.e.
///   the consumer is persistently behind) escalates to `error`.
///
/// A successful enqueue resets the consecutive-drop run, so an isolated drop
/// followed by recovery stays a warning rather than escalating.
///
/// Kept Foundation-only and value-typed so `AlembicCheck` can exercise the
/// escalation thresholds directly without constructing a live analyzer.
public struct AudioInputBackpressure: Sendable, Equatable {
    /// Total buffers successfully enqueued for analysis.
    public private(set) var enqueued: Int = 0

    /// Total buffers dropped (lost input → lost finalized text).
    public private(set) var dropped: Int = 0

    /// Length of the current run of consecutive drops (reset by any enqueue).
    public private(set) var consecutiveDropped: Int = 0

    /// Number of consecutive drops at which health escalates to `.error`.
    public let sustainedDropThreshold: Int

    /// - Parameter sustainedDropThreshold: consecutive drops that escalate to
    ///   `.error`. Defaults to `10`. Must be `>= 1`.
    public init(sustainedDropThreshold: Int = 10) {
        self.sustainedDropThreshold = Swift.max(1, sustainedDropThreshold)
    }

    /// Records one successfully enqueued buffer and ends any drop run.
    public mutating func recordEnqueued() {
        enqueued += 1
        consecutiveDropped = 0
    }

    /// Records one dropped buffer and extends the current drop run.
    public mutating func recordDropped() {
        dropped += 1
        consecutiveDropped += 1
    }

    /// Current health, derived from the counters and the sustained threshold.
    public var health: BackpressureHealth {
        if consecutiveDropped >= sustainedDropThreshold { return .error }
        if dropped > 0 { return .warning }
        return .ok
    }
}

/// A bounded buffer of pending `TranscriptEvent`s that may shed **volatile**
/// events under pressure but **never** drops finalized ones.
///
/// ## Why this exists (the second, opposite policy)
/// Volatile hypotheses are pure UI sugar: each is superseded by the next, so
/// coalescing/dropping the oldest is safe and keeps the live-caption path from
/// flooding a slow consumer. Finalized segments are the canonical record and are
/// retained unconditionally.
///
/// When `enqueue` pushes the count over `capacity`, the *oldest volatile* event
/// is removed (counted in `droppedVolatile`); if the buffer holds only finalized
/// events it is allowed to exceed capacity rather than lose committed text.
///
/// Pure and value-typed for direct `AlembicCheck` coverage.
public struct VolatileResultBuffer: Sendable, Equatable {
    /// Soft capacity; exceeded only when every pending event is finalized.
    public let capacity: Int

    /// Events awaiting delivery, oldest first.
    public private(set) var pending: [TranscriptEvent] = []

    /// Count of volatile events shed to honor `capacity`.
    public private(set) var droppedVolatile: Int = 0

    /// - Parameter capacity: soft maximum pending events. Must be `>= 1`.
    public init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
    }

    /// Appends an event, shedding the oldest volatile event(s) if over capacity.
    public mutating func enqueue(_ event: TranscriptEvent) {
        pending.append(event)
        while pending.count > capacity {
            guard let oldestVolatile = pending.firstIndex(where: { $0.kind == .volatile }) else {
                // Only finalized events remain — never drop committed text.
                break
            }
            pending.remove(at: oldestVolatile)
            droppedVolatile += 1
        }
    }

    /// Removes and returns all pending events in order (oldest first).
    public mutating func drain() -> [TranscriptEvent] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
