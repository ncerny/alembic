import Foundation
import AlembicKit

// MARK: - Phase 7 §3b: synthetic hang/block/timeout AttributionProvider test
// doubles, relocated out of AlembicKit's public API surface.
//
// `SlowAttributionProvider`, `HangingAttributionProvider`,
// `NonCooperativeAttributionProvider`, `GatedAttributionProvider` (plus their
// private `LockedCounter`/`OneShotSignal` helpers) previously shipped as
// `public` types inside `Sources/AlembicKit/AttributionProvider.swift` —
// synthetic hang/block/timeout machinery in the app's production library and
// public API surface (Phase 3 impl-review-1 MEDIUM finding). `AlembicCheck`
// already depends on `AlembicKit` and constructs these types only for its own
// checks, so they belong here instead. `FakeAttributionProvider` (the
// minimal, non-blocking scripted double referenced by the plan/spec) stays in
// `AlembicKit` — it is a plain, deterministic double with no synthetic
// hang/block machinery, unlike the four types below.

// MARK: - Bounded-wait helper (Phase 7 §3c, Phase 3 impl-review-1 MEDIUM)
//
// `waitForFirstFinalizedEvent(_:)` and these providers' own
// `waitUntil...Started()` helpers previously looped/awaited with no timeout,
// so a real regression in session start, `ingest`, or provider dispatch would
// **hang** `AlembicCheck` instead of failing it — worse than a failure, since
// the authoritative runner's entire purpose is "exits non-zero on any
// failure." `waitUntil(timeout:poll:)` below races a polled predicate against
// a deterministic `ContinuousClock` timeout and returns `false` on expiry
// instead of hanging; every affected call site asserts the returned `Bool`
// with `s.expect(...)` rather than looping unconditionally.
func waitUntil(timeout: Duration = .seconds(5), poll: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if await poll() { return true }
        if clock.now >= deadline { return false }
        await Task.yield()
    }
}

/// Thread-safe monotonic counter shared by every attribution-provider test
/// double below that needs to distinguish "this is the first query" from
/// later ones, or simply needs to observe how many queries it received.
/// `NSLock`-guarded per this codebase's existing thread-safe-box convention
/// (`LocaleBox`/`VocabularyBox` in `AppModel.swift`; `TaskBox`/`SingleResume`
/// in `MeetingSession.swift`) — the lock is acquired and released only
/// inside this type's own synchronous methods; no calling code, `async` or
/// otherwise, ever touches the lock itself.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Synchronously increments and returns the new count. Safe to call from
    /// `async` code precisely because it is itself a plain synchronous
    /// method with no `await` inside its locked section.
    @discardableResult
    func incrementAndGet() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    /// Current count, read synchronously.
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// A provider whose *first* query (by arrival order) resolves only after
/// `firstQueryDelay`; every subsequent query resolves immediately. Exists
/// solely to prove `MeetingSession`'s FIFO ingestion chain preserves arrival
/// order even when an earlier event's attribution genuinely takes longer
/// than a later event's. Uses `LockedCounter` (above) for its call counter —
/// no direct `NSLock` call inside this `async` body.
final class SlowAttributionProvider: AttributionProvider, @unchecked Sendable {
    private let counter = LockedCounter()
    private let firstQueryDelay: Duration
    private let firstQueryStarted = OneShotSignal()

    init(firstQueryDelay: Duration) {
        self.firstQueryDelay = firstQueryDelay
    }

    /// Suspends until the first query has been invoked (before its delay
    /// elapses), **bounded** by `timeout` (Phase 7 §3c) — the deterministic
    /// replacement for a fixed `Task.sleep` "head start" guess, and no longer
    /// capable of hanging `AlembicCheck` indefinitely if a regression means
    /// the query never starts at all. Returns `false` on timeout instead of
    /// waiting forever; callers assert the result.
    func waitUntilFirstQueryStarted(timeout: Duration = .seconds(5)) async -> Bool {
        await firstQueryStarted.wait(timeout: timeout)
    }

    func attribution(forThemSegment window: ClosedRange<Double>) async -> SpeakerAttributionResult? {
        let isFirst = counter.incrementAndGet() == 1
        if isFirst {
            firstQueryStarted.resume()
            try? await Task.sleep(for: firstQueryDelay)
            return SpeakerAttributionResult(displayName: "slow", confidence: 0.9)
        }
        return SpeakerAttributionResult(displayName: "instant", confidence: 0.9)
    }
}

/// A provider whose query never returns on its own, using cooperative
/// `Task.sleep` — exists to prove `MeetingSession`'s bounded-attribution
/// timeout (SR-17) bounds a merely-very-slow-but-cancellable provider. Uses
/// the shared `LockedCounter` (above) for `queryCount` — no direct `NSLock`
/// call inside this `async` body — proving the session-level circuit
/// breaker limits the provider to exactly one query per session after its
/// first timeout.
final class HangingAttributionProvider: AttributionProvider, @unchecked Sendable {
    private let counter = LockedCounter()
    var queryCount: Int { counter.value }
    private let blockDuration: Duration

    init(blockDuration: Duration = .seconds(30)) {
        self.blockDuration = blockDuration
    }

    func attribution(forThemSegment window: ClosedRange<Double>) async -> SpeakerAttributionResult? {
        counter.incrementAndGet()
        try? await Task.sleep(for: blockDuration)
        return SpeakerAttributionResult(displayName: "too late", confidence: 1.0)
    }
}

/// A provider that blocks a plain (non-Swift-concurrency) thread
/// synchronously via a `DispatchQueue`-dispatched closure, which **does not
/// respond to `Task.cancel()` at all** — exists to prove the bounded-
/// attribution redesign's caller-side timeout bound holds even against a
/// provider that makes cancellation entirely ineffective. Uses the shared
/// `LockedCounter` (above) for `queryCount` — no direct `NSLock` call inside
/// this `async` body.
///
/// **Swift 6 validity note:** `Thread.sleep(forTimeInterval:)` is `noasync`
/// under Swift 6 and cannot be called directly inside this `async`
/// function's body. The blocking sleep instead runs inside the synchronous
/// (non-`async`) closure passed to `DispatchQueue.global().async` — a valid,
/// compiling call site for `Thread.sleep` — and this `async` function only
/// `await`s the `CheckedContinuation` that closure resumes once its real,
/// thread-blocking sleep elapses. The abandoned continuation (and the
/// blocked dispatch-queue thread) remains outstanding for the rest of
/// `blockDuration` after `boundedAttribution`'s timeout fires — a documented
/// containment tradeoff, acceptable for a short, single-run check process
/// given the small, injected `blockDuration` used by callers (hundreds of
/// milliseconds, not the production-representative default).
final class NonCooperativeAttributionProvider: AttributionProvider, @unchecked Sendable {
    private let counter = LockedCounter()
    var queryCount: Int { counter.value }
    private let blockDuration: Duration

    init(blockDuration: Duration = .seconds(30)) {
        self.blockDuration = blockDuration
    }

    func attribution(forThemSegment window: ClosedRange<Double>) async -> SpeakerAttributionResult? {
        counter.incrementAndGet()
        let seconds = Double(blockDuration.components.seconds)
            + Double(blockDuration.components.attoseconds) / 1e18
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                Thread.sleep(forTimeInterval: seconds) // valid here: synchronous, non-async closure
                continuation.resume(returning: SpeakerAttributionResult(displayName: "too late", confidence: 1.0))
            }
        }
    }
}

/// A one-shot async signal: `wait()` suspends until `resume()` is called,
/// exactly once, regardless of which happens first. `NSLock`-guarded per
/// this codebase's thread-safe-box convention (`TaskBox`/`SingleResume` in
/// `MeetingSession.swift`; `LockedCounter`, above) — the lock only ever
/// guards this type's own synchronous internal state; `resume()` is a plain
/// synchronous method and `wait()`'s only `await` happens *outside* any
/// locked section, so no `NSLock` call is ever made directly from `async`
/// code.
private final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Synchronously resumes any waiter, or records that the signal already
    /// fired so a later `wait()` call returns immediately instead of hanging.
    func resume() {
        let toResume: CheckedContinuation<Void, Never>?
        lock.lock()
        if isSignaled {
            toResume = nil
        } else {
            isSignaled = true
            toResume = continuation
            continuation = nil
        }
        lock.unlock()
        toResume?.resume()
    }

    /// Suspends until `resume()` is called — or returns immediately if it
    /// already was — with no timeout. Kept private/unbounded on purpose: the
    /// bounded, `Bool`-returning `wait(timeout:)` below is the only surface
    /// `AlembicCheck`'s own checks call (Phase 7 §3c); this raw form is used
    /// only internally, always raced against a timeout by the caller below.
    private func waitUnbounded() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isSignaled {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    /// Bounded wait (Phase 7 §3c): races `waitUnbounded()` against a
    /// deterministic `timeout` using a `TaskGroup`, returning `true` iff the
    /// signal fired first. Never hangs regardless of whether `resume()` is
    /// ever called — a genuine regression that never signals now fails the
    /// calling check instead of hanging `AlembicCheck` indefinitely.
    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.waitUnbounded(); return true }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// A provider whose query suspends indefinitely until explicitly released —
/// exists to let a check deterministically prove both "the query has
/// genuinely started" (via `waitUntilQueryStarted()`) and "resuming an
/// abandoned, already-torn-down query never causes a late mutation" (via
/// `release()`), without depending on `Task.sleep`-based timing guesses.
final class GatedAttributionProvider: AttributionProvider, @unchecked Sendable {
    private let started = OneShotSignal()
    private let released = OneShotSignal()

    init() {}

    /// Suspends until `attribution(forThemSegment:)` has actually been
    /// invoked — the deterministic replacement for guessing "the query has
    /// probably started by now" via a fixed `Task.sleep`. **Bounded** by
    /// `timeout` (Phase 7 §3c); returns `false` on expiry instead of hanging.
    func waitUntilQueryStarted(timeout: Duration = .seconds(5)) async -> Bool {
        await started.wait(timeout: timeout)
    }

    /// Lets the in-flight query return its (necessarily too-late) result.
    /// Call only *after* teardown and post-teardown state/file assertions
    /// have already run, so the assertions that follow genuinely prove
    /// "resuming this abandoned link produces no late mutation", rather than
    /// merely "we didn't happen to observe one within an arbitrary window".
    func release() { released.resume() }

    func attribution(forThemSegment window: ClosedRange<Double>) async -> SpeakerAttributionResult? {
        started.resume()
        // Discarded on purpose: this call's own contract is "wait for
        // `release()`", not "wait up to 30s and give up" — the 30s bound is
        // only a safety net against a check that forgets to call `release()`
        // at all, not a condition this method itself needs to branch on.
        _ = await released.wait(timeout: .seconds(30))
        return SpeakerAttributionResult(displayName: "too late", confidence: 1.0)
    }
}
