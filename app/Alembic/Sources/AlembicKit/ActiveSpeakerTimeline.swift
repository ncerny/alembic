import Foundation

/// A pure, in-memory, session-relative store of "who was speaking when" derived
/// from an attribution signal (SR-7), and the dominant-overlap resolver that
/// answers `AttributionProvider` queries against it (SR-9).
///
/// Foundation-only and fully deterministic (SR-13): the real macOS
/// implementation (Phase 5's `VisionSpeakerAttributor`) will hold one instance
/// behind an `NSLock`-guarded `@unchecked Sendable` box (the established
/// `LocaleBox`/`VocabularyBox` pattern) so it can be mutated from an OCR
/// callback and queried from `attribution(forThemSegment:)` across an actor
/// boundary. This type itself has no concurrency of its own — it is a plain
/// value type, which is what keeps it trivially unit-testable here.
public struct ActiveSpeakerTimeline: Sendable, Equatable {

    /// One recorded "name X was the active/dominant speaker during range Y"
    /// observation, at the observation's own confidence.
    public struct Interval: Sendable, Equatable {
        public let range: ClosedRange<Double>
        public let name: String
        /// Always in `[0, 1]` (DR-3) — `init` clamps (see the file-private
        /// `clamped(to:)` helper below); a producer-supplied out-of-range
        /// value (e.g. a raw OCR confidence > 1) must not corrupt
        /// `resolve(window:)`'s weighted-average math or propagate
        /// downstream.
        public let confidence: Double

        public init(range: ClosedRange<Double>, name: String, confidence: Double) {
            self.range = range
            self.name = name
            self.confidence = confidence.clamped(to: 0...1)
        }
    }

    /// The outcome of `resolve(window:)`.
    public struct Resolution: Sendable, Equatable {
        public let displayName: String
        /// Overlap-duration-weighted average confidence of the intervals that
        /// contributed to `displayName`'s winning overlap (see `resolve`).
        public let confidence: Double
        /// Fraction of `window`'s duration covered by `displayName`'s
        /// intervals, in `[0, 1]`.
        public let overlapFraction: Double
    }

    /// Tunable acceptance thresholds and housekeeping bounds. **All default
    /// values below are documented placeholders pending live tuning
    /// (OQ-1, Phase 7)** — they are chosen to be conservative (reject rather
    /// than over-attribute) but are not calibrated against real OCR output.
    public struct Configuration: Sendable, Equatable {
        /// τ (SR-11): minimum accepted resolution confidence. Always in
        /// `[0, 1]` — `init` clamps rather than trapping, so a
        /// slightly-misconfigured literal (e.g. `minConfidence: 1.2`) degrades
        /// to the nearest valid bound instead of crashing at startup.
        public let minConfidence: Double
        /// SR-11/SR-12: minimum accepted dominant-overlap fraction. Always in
        /// `[0, 1]` — clamped identically to `minConfidence`.
        public let minOverlapFraction: Double
        /// SR-9 housekeeping: when appending a new interval whose `name`
        /// matches the timeline's current last interval and whose gap from
        /// that interval's `range.upperBound` is `<= coalesceGap` seconds, the
        /// two intervals are merged into one instead of stored separately.
        /// Bounds timeline growth under a steady, repeatedly-reported same
        /// speaker (e.g. one OCR hit every throttled poll) and tolerates a
        /// single missed poll. Chosen relative to the Phase 5 OCR throttle
        /// target of ≈1–2 Hz (SR-6): 2.5s tolerates one dropped ~1 Hz sample.
        public let coalesceGap: Double
        /// SR-9 housekeeping: intervals whose `range.upperBound` is more than
        /// `retentionWindow` seconds behind the latest recorded time are
        /// dropped on the next `record(...)` call, bounding memory for
        /// arbitrarily long meetings. Segments are attributed shortly after
        /// they finalize, so this only needs to outlive normal ASR
        /// finalization latency with generous headroom.
        public let retentionWindow: Double

        public init(
            minConfidence: Double = 0.5,
            minOverlapFraction: Double = 0.6,
            coalesceGap: Double = 2.5,
            retentionWindow: Double = 600
        ) {
            self.minConfidence = minConfidence.clamped(to: 0...1)
            self.minOverlapFraction = minOverlapFraction.clamped(to: 0...1)
            self.coalesceGap = Swift.max(0, coalesceGap)
            self.retentionWindow = Swift.max(0, retentionWindow)
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration
    /// Kept sorted by `range.lowerBound` ascending; ties broken by insertion
    /// order (stable). `record(...)` is the only mutator and maintains this
    /// invariant even for a caller that reports observations out of order
    /// (see `record`'s doc) — retention trimming below assumes a globally
    /// correct "most recent" bound, not merely the last-appended element.
    public private(set) var intervals: [Interval] = []

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - record

    /// Records one observation. Coalesces with the current last interval when
    /// `name` matches and the gap is within `configuration.coalesceGap` (SR-9
    /// housekeeping), otherwise inserts a new interval in its sorted position.
    /// Trims intervals older than `configuration.retentionWindow` relative to
    /// the latest end time recorded so far.
    ///
    /// Real callers (Phase 5's `VisionSpeakerAttributor`) report observations
    /// in capture order, so the common path is an append. However, `intervals`
    /// is a documented-sorted public property, so a call that reports a
    /// `range` starting before the current last interval's start (out of
    /// order) is not treated as an error: it is inserted at the correct
    /// sorted position instead of being appended out of place, which would
    /// silently corrupt the sorted invariant retention trimming (and any
    /// future consumer of `intervals`) relies on.
    ///
    /// Not thread-safe by design (see the type doc) — callers needing
    /// cross-actor mutation own their own lock (Phase 5).
    public mutating func record(name: String, confidence: Double, in range: ClosedRange<Double>) {
        guard !intervals.isEmpty else {
            intervals.append(Interval(range: range, name: name, confidence: confidence))
            return
        }

        let lastIndex = intervals.count - 1
        let last = intervals[lastIndex]
        let isMonotonic = range.lowerBound >= last.range.lowerBound

        if last.name == name,
           isMonotonic,
           range.lowerBound - last.range.upperBound <= configuration.coalesceGap {
            let mergedRange = last.range.lowerBound...Swift.max(last.range.upperBound, range.upperBound)
            // Duration-weighted average; a zero-duration (point) sample
            // weighs as one sample-unit rather than 0 so it is never
            // silently erased from the average.
            let lastWeight = Swift.max(last.range.upperBound - last.range.lowerBound, 0)
            let newWeight = Swift.max(range.upperBound - range.lowerBound, 0)
            let effectiveLastWeight = lastWeight > 0 ? lastWeight : 1
            let effectiveNewWeight = newWeight > 0 ? newWeight : 1
            let mergedConfidence =
                (last.confidence * effectiveLastWeight + confidence * effectiveNewWeight)
                / (effectiveLastWeight + effectiveNewWeight)
            intervals[lastIndex] = Interval(range: mergedRange, name: name, confidence: mergedConfidence)
        } else if isMonotonic {
            // In-order, non-coalesced observation: append keeps `intervals`
            // sorted with no extra work.
            intervals.append(Interval(range: range, name: name, confidence: confidence))
        } else {
            // Out-of-order observation: insert at the position that keeps
            // `intervals` sorted by `range.lowerBound` ascending (ties go
            // after any existing equal-lowerBound entries, preserving
            // insertion-order stability for the documented invariant).
            var insertionIndex = intervals.count
            for i in 0..<intervals.count where intervals[i].range.lowerBound > range.lowerBound {
                insertionIndex = i
                break
            }
            intervals.insert(Interval(range: range, name: name, confidence: confidence), at: insertionIndex)
        }

        trim()
    }

    /// Drops intervals whose `range.upperBound` is more than
    /// `configuration.retentionWindow` behind the latest `range.upperBound`
    /// recorded across the whole timeline (not merely `intervals.last`,
    /// which — after an out-of-order insertion — is not guaranteed to be the
    /// interval with the greatest `upperBound`).
    ///
    /// Filters the **entire** array rather than stopping at the first
    /// non-stale element scanned from the front (Phase 7 §3a fix, Phase 2
    /// impl-review-1 LOW finding): `intervals` is sorted by
    /// `range.lowerBound`, but `range.upperBound` is not guaranteed monotonic
    /// with that sort order (e.g. a long early interval — large
    /// `upperBound`, small `lowerBound` — followed by a short later one —
    /// small `upperBound`, larger `lowerBound`). A prefix-stop
    /// `while intervals.first is stale { removeFirst() }` loop would stop at
    /// the long early interval (not stale) while leaving the short later one
    /// (genuinely stale) in place behind it. A full filter has no such
    /// position dependency and removes every stale interval regardless of
    /// where it sits in the sorted order.
    private mutating func trim() {
        guard let mostRecentUpperBound = intervals.map(\.range.upperBound).max() else { return }
        let cutoff = mostRecentUpperBound - configuration.retentionWindow
        intervals.removeAll { $0.range.upperBound < cutoff }
    }

    // MARK: - resolve

    /// Resolves the dominant-overlap name for `window` (SR-10), rejecting
    /// below `configuration.minConfidence`/`minOverlapFraction` (SR-11), and
    /// returning `nil` for a straddled/ambiguous window with no clear
    /// dominant speaker (SR-12). Deterministic for identical
    /// `(intervals, configuration, window)` (SR-13) — see the tie-break rule
    /// below.
    public func resolve(window: ClosedRange<Double>) -> Resolution? {
        let windowDuration = Swift.max(window.upperBound - window.lowerBound, 0)

        // Zero-length window (instantaneous segment, start == end — should
        // not occur for real ASR segments but must not crash): treat overlap
        // as containment. If exactly one distinct name touches the point,
        // accept it (fraction 1.0) subject to minConfidence only; if more
        // than one distinct name touches the same point, that is
        // definitionally maximally ambiguous → nil.
        if windowDuration == 0 {
            let touching = intervals.filter { $0.range.contains(window.lowerBound) }
            let distinctNames = Set(touching.map(\.name))
            guard distinctNames.count == 1, let name = distinctNames.first else { return nil }
            let matching = touching.filter { $0.name == name }
            let confidence = matching.map(\.confidence).reduce(0, +) / Double(matching.count)
            guard confidence >= configuration.minConfidence else { return nil }
            return Resolution(displayName: name, confidence: confidence, overlapFraction: 1.0)
        }

        // Normal case: bucket each interval's window-clipped sub-range by
        // name, preserving first-appearance order (the existing
        // determinism/tie-break guarantee below relies on scanning
        // `intervals` in stored chronological order), then compute the
        // *union* duration and a union-consistent weighted confidence sum
        // per name via `unionOverlap` (fixes the Phase 2 impl-review-1
        // MEDIUM finding: two overlapping same-name intervals — e.g. a
        // duplicate or out-of-order-inserted observation — previously summed
        // their raw overlap durations directly, double-counting the same
        // wall-clock time and inflating `totalOverlap` past the window's
        // true covered duration).
        var order: [String] = []
        var clippedByName: [String: [(range: ClosedRange<Double>, confidence: Double)]] = [:]
        for interval in intervals where interval.range.overlaps(window) {
            let clippedLower = Swift.max(interval.range.lowerBound, window.lowerBound)
            let clippedUpper = Swift.min(interval.range.upperBound, window.upperBound)
            // `ClosedRange.overlaps` reports `true` for ranges that only
            // touch at a shared endpoint (e.g. 0...10 and 10...12), which
            // yields a zero-duration clip: a zero-duration touch carries no
            // actual temporal signal and must not be accumulated (otherwise
            // it could "win" with totalOverlap == 0 and divide-by-zero
            // below). Preserved exactly as before — now checked at the
            // clip/bucket step rather than the old direct-summation site.
            guard clippedUpper > clippedLower else { continue }
            if clippedByName[interval.name] == nil {
                order.append(interval.name)
                clippedByName[interval.name] = []
            }
            clippedByName[interval.name]?.append((range: clippedLower...clippedUpper, confidence: interval.confidence))
        }

        var accumulated: [(name: String, totalOverlap: Double, weightedConfidenceSum: Double)] = []
        for name in order {
            guard let clipped = clippedByName[name] else { continue }
            let (duration, weightedConfidenceSum) = Self.unionOverlap(clipped)
            guard duration > 0 else { continue }
            accumulated.append((name: name, totalOverlap: duration, weightedConfidenceSum: weightedConfidenceSum))
        }

        guard !accumulated.isEmpty else { return nil }

        // Winner selection, in order: highest totalOverlap; tie → highest
        // weighted-average confidence; tie → lexicographically smallest name
        // (a final, total, deterministic tie-break — SR-13). `firstSeenIndex`
        // is deliberately not part of this chain: for two *distinct* names
        // accumulated by the ordered scan above, their first-seen positions
        // are never equal, so a first-seen tie-break would never actually be
        // reached and would silently mask the case this tie-break exists to
        // handle (identical overlap and confidence).
        let winner = accumulated.reduce(accumulated[0]) { best, candidate in
            if candidate.totalOverlap != best.totalOverlap {
                return candidate.totalOverlap > best.totalOverlap ? candidate : best
            }
            let candidateAvg = candidate.weightedConfidenceSum / candidate.totalOverlap
            let bestAvg = best.weightedConfidenceSum / best.totalOverlap
            if candidateAvg != bestAvg {
                return candidateAvg > bestAvg ? candidate : best
            }
            return candidate.name < best.name ? candidate : best
        }

        let overlapFraction = (winner.totalOverlap / windowDuration).clamped(to: 0...1)
        // Never divides by zero — every entry reaching this point has
        // totalOverlap > 0 (guaranteed by the `guard overlapDuration > 0`
        // above and the `!accumulated.isEmpty` guard).
        let resolvedConfidence = winner.weightedConfidenceSum / winner.totalOverlap

        guard overlapFraction >= configuration.minOverlapFraction,
              resolvedConfidence >= configuration.minConfidence else { return nil }

        return Resolution(displayName: winner.name, confidence: resolvedConfidence, overlapFraction: overlapFraction)
    }

    /// Merges one name's window-clipped sub-ranges and returns the union
    /// duration plus a duration-weighted confidence sum computed over the
    /// *merged* (non-overlapping) segments, so a wall-clock second covered by
    /// two overlapping same-name intervals is counted exactly once (fixes
    /// the Phase 2 impl-review-1 double-counting finding).
    ///
    /// Tie policy for overlapping confidence (undocumented by the spec, so
    /// chosen here for internal consistency): where two or more sub-ranges
    /// cover the same merged segment, that segment's confidence is the
    /// duration-weighted average of every contributing sub-range's own
    /// confidence, weighted by that sub-range's own (pre-merge) duration —
    /// mirroring `record(...)`'s existing duration-weighted-average
    /// coalescing policy elsewhere in this file, rather than introducing a
    /// different blending rule.
    private static func unionOverlap(
        _ clipped: [(range: ClosedRange<Double>, confidence: Double)]
    ) -> (duration: Double, weightedConfidenceSum: Double) {
        guard !clipped.isEmpty else { return (0, 0) }
        let sorted = clipped.sorted { $0.range.lowerBound < $1.range.lowerBound }

        var totalDuration = 0.0
        var totalWeightedConfidence = 0.0

        // Sweep-merge overlapping/adjacent sub-ranges into disjoint merged
        // segments. `mergedCoveredDuration`/`mergedWeightedConfidenceSum`
        // accumulate over each *contributing* sub-range's own duration
        // (which may itself overlap another contributor's), so the final
        // average is duration-weighted across contributors — only the
        // finalized segment's `(mergedUpper - mergedLower)` span (never the
        // sum of contributor durations) is added to `totalDuration`, which
        // is what prevents the double-count this fix targets.
        var mergedLower = sorted[0].range.lowerBound
        var mergedUpper = sorted[0].range.upperBound
        var mergedCoveredDuration = mergedUpper - mergedLower
        var mergedWeightedConfidenceSum = mergedCoveredDuration * sorted[0].confidence

        func finalizeMergedSegment() {
            let duration = mergedUpper - mergedLower
            guard duration > 0 else { return }
            let averageConfidence = mergedCoveredDuration > 0
                ? mergedWeightedConfidenceSum / mergedCoveredDuration
                : 0
            totalDuration += duration
            totalWeightedConfidence += duration * averageConfidence
        }

        for entry in sorted.dropFirst() {
            let entryDuration = entry.range.upperBound - entry.range.lowerBound
            if entry.range.lowerBound <= mergedUpper {
                // Overlaps (or is exactly adjacent to) the current merged
                // segment: fold its confidence in, weighted by its own
                // duration, and extend the merged upper bound if it reaches
                // further. Two disjoint-but-touching sub-ranges (no actual
                // overlap) merge harmlessly here too — their combined span
                // equals the sum of their individual durations either way,
                // so the non-overlapping path is unaffected by this change.
                mergedWeightedConfidenceSum += entryDuration * entry.confidence
                mergedCoveredDuration += entryDuration
                mergedUpper = Swift.max(mergedUpper, entry.range.upperBound)
            } else {
                // Disjoint from the current merged segment: finalize it and
                // start a new one.
                finalizeMergedSegment()
                mergedLower = entry.range.lowerBound
                mergedUpper = entry.range.upperBound
                mergedCoveredDuration = entryDuration
                mergedWeightedConfidenceSum = entryDuration * entry.confidence
            }
        }
        finalizeMergedSegment()

        return (totalDuration, totalWeightedConfidence)
    }
}

/// Clamps `self` into `range`. Duplicated from `AttributionProvider.swift`'s
/// identical helper — each file that needs it declares its own `fileprivate`
/// copy, keeping every file self-contained with no cross-file shared internal
/// API (this phase's established convention).
///
/// A non-finite input (`NaN`, `+.infinity`, `-.infinity`) is sanitized to
/// `range.lowerBound` before the min/max clamp runs (Phase 3 §0.2 remediation
/// of the Phase 2 impl-review-1 MEDIUM finding — see
/// `AttributionProvider.swift`'s identical helper for the full rationale).
fileprivate extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard self.isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
