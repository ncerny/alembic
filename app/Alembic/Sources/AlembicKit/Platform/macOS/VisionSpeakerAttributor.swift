import Foundation
import Vision
import CoreGraphics

/// The real macOS `AttributionProvider` (MVP signal #2 — Phase 5). Consumes
/// `ScreenCaptureKitSource.frames`, throttles inspection to ≈1–2 Hz (SR-6),
/// resolves the meeting app's `SpeakerLabelCatalog` entry once at
/// construction (SR-20/21/23), and — **only if that entry's marker geometry
/// is flagged `markersValidated` (fail closed otherwise: unvalidated ⇒ no
/// attribution ever produced, same structural guarantee as an unknown app)**
/// — tests each catalog candidate's active-tile marker against sampled pixel
/// color, requires exactly one candidate to match (zero or more-than-one ⇒
/// no signal, never a guess — SR-12), OCRs (`RecognizeTextRequest`) only the
/// matched tile's label region, normalizes the name
/// (`SpeakerNameNormalizer`), and turns accepted per-frame detections into
/// bounded, non-overlapping intervals via an explicit sample-state machine
/// recorded into an owned `ActiveSpeakerTimeline` (SR-7).
///
/// `attribution(forThemSegment:)` is **timeline-only** — it only ever calls
/// `ActiveSpeakerTimeline.resolve` and never itself runs OCR, samples a
/// frame, or blocks on the frame-consumption `Task`.
///
/// `Vision`/`CoreGraphics` are imported **only** in this file for this
/// feature (SR-2/NR-2) — no other `AlembicKit` source, at any depth, may
/// import either framework for speaker attribution. (`ScreenCaptureKitSource.
/// swift` already imports `CoreGraphics` for unrelated Phase 4 pixel-buffer
/// work — that pre-existing import is not a violation of this rule; `Vision`
/// itself is new only here.)
public actor VisionSpeakerAttributor: AttributionProvider {

    // MARK: - Configuration

    /// Every tunable this phase introduces. **All numeric defaults below are
    /// documented placeholders pending Phase 7 live tuning (OQ-1/OQ-2)** —
    /// chosen conservatively (reject/skip rather than over-attribute) but
    /// not calibrated against real OCR/capture output.
    public struct Configuration: Sendable, Equatable {
        /// SR-6 throttle: minimum seconds between two inspected frames.
        /// Default `0.75` (~1.3 Hz, inside the ≈1–2 Hz target).
        public let samplingIntervalSeconds: Double
        /// OCR-layer confidence floor — a single low-confidence OCR hit is
        /// rejected here, independent of `timelineConfiguration.minConfidence`'s
        /// separate *resolution*-layer floor. Default `0.4` (deliberately
        /// lower than `ActiveSpeakerTimeline.Configuration.default.minConfidence
        /// == 0.5` — this floor only needs to reject clearly-garbage hits).
        public let minimumOCRConfidence: Double
        /// Sample-state-machine max bridgeable gap (seconds) between two
        /// same-speaker detections before a later detection starts a fresh
        /// interval instead of extending the open one. Default `2.5`, reusing
        /// the exact rationale documented on
        /// `ActiveSpeakerTimeline.Configuration.default.coalesceGap`
        /// ("tolerates one dropped ~1 Hz sample").
        public let maxGapSeconds: Double
        /// Forwarded to `ActiveSpeakerTimeline.init(configuration:)` unchanged
        /// — this phase reuses Phase 2's existing τ/minOverlapFraction/
        /// coalesceGap/retentionWindow defaults rather than introducing a
        /// second copy.
        public let timelineConfiguration: ActiveSpeakerTimeline.Configuration
        /// SR-25 hook: an optional AX-roster name allow-list forwarded to
        /// `SpeakerNameNormalizer`'s conservative snap. Empty by default — no
        /// roster feeder exists yet.
        public let roster: [String]

        public init(
            samplingIntervalSeconds: Double = 0.75,
            minimumOCRConfidence: Double = 0.4,
            maxGapSeconds: Double = 2.5,
            timelineConfiguration: ActiveSpeakerTimeline.Configuration = .default,
            roster: [String] = []
        ) {
            self.samplingIntervalSeconds = Swift.max(0, samplingIntervalSeconds)
            self.minimumOCRConfidence = minimumOCRConfidence.clamped(to: 0...1)
            self.maxGapSeconds = Swift.max(0, maxGapSeconds)
            self.timelineConfiguration = timelineConfiguration
            self.roster = roster
        }

        public static let `default` = Configuration()
    }

    // MARK: - Stored state

    /// Resolved once, at construction (§0.2) — never re-resolved per frame.
    private let catalogEntry: SpeakerLabelCatalog.AppEntry?
    private let meetingTitle: String?
    private let configuration: Configuration
    private var timeline: ActiveSpeakerTimeline
    private var lastSampledFrameTime: Double?
    /// The sample-state machine's cursor (§0.10) — mutated only by
    /// `recordOutcome(_:frameTime:)`, itself only ever called from
    /// `process(frame:)` on the frame-consumption `Task`.
    private var openInterval: OpenInterval?
    /// `nonisolated(unsafe)`: only ever mutated from `init` (before `self`
    /// is shared with any other code — construction is inherently
    /// single-threaded) and from `stop()`/`deinit` (both fully
    /// actor-serialized/exclusive by construction — `deinit` runs only once
    /// no other reference to this actor remains). Swift 6's actor-init
    /// isolation checker otherwise rejects assigning this property from
    /// within `init`'s `Task { [weak self] in ... }` closure (the closure's
    /// capture of `self` is treated as `self` escaping, which downgrades the
    /// rest of `init` to non-isolated) — `nonisolated(unsafe)` is the
    /// correct escape hatch here because the actual safety property (no
    /// concurrent mutation) holds by construction, not because isolation is
    /// truly irrelevant.
    private nonisolated(unsafe) var consumptionTask: Task<Void, Never>?

    /// - Parameters:
    ///   - bundleID: the resolved meeting app's bundle ID (Phase 6 supplies
    ///     the same `CaptureTarget.id` already resolved for
    ///     `ScreenCaptureKitSource.start(target:)`). Looked up against
    ///     `SpeakerLabelCatalog.match(bundleID:)` exactly once, here.
    ///   - meetingTitle: the resolved meeting window's title, exactly as
    ///     `AppModel` resolves it for `ScreenCaptureKitSource.
    ///     setExpectedMeetingTitle(_:)` (same value, same call site — this
    ///     is not a second, independent title resolution). Tested against
    ///     the matched catalog entry's `layoutRequirement` via
    ///     `AppEntry.matchesLayout(meetingTitle:)` — **data**, not
    ///     Teams-specific control flow here (SR-20/21) — before the
    ///     consumption Task is ever spawned. `nil` (title unresolved/
    ///     unavailable) never matches any entry's `layoutRequirement`,
    ///     failing closed the same way an unmatched bundle ID does.
    ///   - frames: `ScreenCaptureKitSource.frames` (or any equivalent
    ///     `AsyncStream<CapturedFrame>`). Consumed by an internal `Task`
    ///     spawned only when `bundleID` resolves to a catalog entry whose
    ///     `markersValidated == true` **and** whose `layoutRequirement`
    ///     matches `meetingTitle` (§0.2a, extended by the live-calibration
    ///     title/layout gate) — otherwise this stream is never read at all,
    ///     so an unmatched app, an unvalidated entry, or a validated entry
    ///     whose layout doesn't match the current meeting can never
    ///     back-pressure or stall the frame producer, or attribute against
    ///     a layout it was never measured for.
    public init(
        bundleID: String,
        meetingTitle: String?,
        frames: AsyncStream<CapturedFrame>,
        configuration: Configuration = .default
    ) {
        let entry = SpeakerLabelCatalog.match(bundleID: bundleID)
        self.catalogEntry = entry
        self.meetingTitle = meetingTitle
        self.configuration = configuration
        self.timeline = ActiveSpeakerTimeline(configuration: configuration.timelineConfiguration)

        // §0.2/§0.2a fail-closed gate, extended with the live-calibration
        // title/layout gate: only a known app whose catalog entry has been
        // explicitly marked `markersValidated` **and** whose
        // `layoutRequirement` matches the currently-resolved `meetingTitle`
        // (data-driven — `AppEntry.matchesLayout(meetingTitle:)`, never a
        // hard-coded Teams-specific `if` here) ever starts the consumption
        // Task. An unknown app (SR-23), a known-but-unvalidated entry, or a
        // validated entry whose meeting-window evidence doesn't match leaves
        // `timeline` permanently empty,
        // so `attribution(forThemSegment:)` always resolves `nil` via
        // `ActiveSpeakerTimeline.resolve`'s existing "no intervals"
        // behavior — structurally, not by convention. This Task is created
        // (and, when spawned, fully assigned to `consumptionTask`)
        // synchronously before `init` returns — a caller that calls
        // `stop()` immediately after construction is guaranteed to observe
        // and cancel it, never racing an async hop.
        if let entry, entry.markersValidated, entry.matchesLayout(meetingTitle: meetingTitle) {
            let task = Task { [weak self] in
                for await frame in frames {
                    guard let self else { return }
                    await self.process(frame: frame)
                }
            }
            self.consumptionTask = task
        } else {
            self.consumptionTask = nil
        }
    }

    /// Cancels the frame-consumption loop. Idempotent. Safe to call even
    /// though `ScreenCaptureKitSource.stop()` already finishes `frames` on
    /// its own schedule — cancellation here only stops mid-flight `await`s
    /// (an in-progress Vision call) promptly rather than waiting for the
    /// stream to finish naturally.
    public func stop() {
        consumptionTask?.cancel()
        consumptionTask = nil
    }

    deinit {
        // Defense-in-depth only: a caller that drops this instance without
        // calling `stop()` must not leak a running Task indefinitely.
        // `Task.cancel()` is a plain, non-async, non-isolated call — legal
        // directly from a (necessarily non-async) actor `deinit`.
        // TODO: `deinit` cannot `await` an in-flight frame-processing Task's
        // actual cancellation/completion (Phase 5 impl-review-1 LOW-1,
        // deferred out of scope in Phase 7 §3 — see that finding for the
        // full rationale). `cancel()` here is best-effort; it does not block
        // on the Task actually finishing.
        consumptionTask?.cancel()
    }

    // MARK: - AttributionProvider (timeline-only query path)

    /// **Timeline-only.** Never touches `openInterval`, never samples a
    /// frame, never runs OCR, and never awaits the consumption `Task` — it
    /// only reads `timeline` (already-recorded, already-bounded intervals)
    /// via the already-proven-pure `ActiveSpeakerTimeline.resolve`.
    public func attribution(forThemSegment window: ClosedRange<Double>) async -> SpeakerAttributionResult? {
        guard let resolution = timeline.resolve(window: window) else { return nil }
        return SpeakerAttributionResult(displayName: resolution.displayName, confidence: resolution.confidence)
    }

    // MARK: - §0.4 Throttle (pure, AlembicCheck-testable)

    /// Pure: `true` iff `frameTime` is due to be sampled given
    /// `lastSampledTime` and `minInterval` (SR-6 — bounds how often a frame
    /// is even *inspected*, independent of OCR's own success rate).
    /// `lastSampledTime == nil` (no frame sampled yet this session) always
    /// samples, provided `frameTime` itself is valid. A non-finite or
    /// **negative** `frameTime`/`lastSampledTime`/`minInterval` (should not
    /// occur for a real `CapturedFrame.sessionTime`, but must never corrupt
    /// state or crash — plan-review-2 MEDIUM-2) is treated as "not due"
    /// rather than trapping or sampling — the safe, conservative default.
    package static func shouldSample(frameTime: Double, lastSampledTime: Double?, minInterval: Double) -> Bool {
        guard frameTime.isFinite, frameTime >= 0, minInterval >= 0 else { return false }
        guard let lastSampledTime else { return true }
        guard lastSampledTime.isFinite, lastSampledTime >= 0 else { return true }
        return frameTime - lastSampledTime >= minInterval
    }

    // MARK: - §0.6 Geometry: UnitRect -> pixel CGRect, outward-rounded, clamped

    /// Pure: converts a top-left-origin, frame-relative `UnitRect` (each
    /// field nominally in `[0, 1]`, but not trusted to stay there) into an
    /// integer pixel rect against `frameWidth`×`frameHeight`, rounding each
    /// edge **outward** (floor the min edge, ceil the max edge) before
    /// clamping to `[0, frameWidth] × [0, frameHeight]`. Returns `nil` for a
    /// degenerate result (zero width/height after clamping, or non-finite/
    /// non-positive `frameWidth`/`frameHeight`) rather than a crop nobody
    /// could use.
    package static func pixelRect(
        for unit: UnitRect,
        frameWidth: Int,
        frameHeight: Int
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        guard unit.x.isFinite, unit.y.isFinite, unit.width.isFinite, unit.height.isFinite else { return nil }

        let widthDouble = Double(frameWidth)
        let heightDouble = Double(frameHeight)

        let minX = (unit.x * widthDouble).rounded(.down)
        let minY = (unit.y * heightDouble).rounded(.down)
        let maxX = ((unit.x + unit.width) * widthDouble).rounded(.up)
        let maxY = ((unit.y + unit.height) * heightDouble).rounded(.up)

        let clampedMinX = Swift.min(Swift.max(minX, 0), widthDouble)
        let clampedMinY = Swift.min(Swift.max(minY, 0), heightDouble)
        let clampedMaxX = Swift.min(Swift.max(maxX, 0), widthDouble)
        let clampedMaxY = Swift.min(Swift.max(maxY, 0), heightDouble)

        let width = clampedMaxX - clampedMinX
        let height = clampedMaxY - clampedMinY
        guard width > 0, height > 0 else { return nil }

        return (
            x: Int(clampedMinX),
            y: Int(clampedMinY),
            width: Int(width),
            height: Int(height)
        )
    }

    /// Pure: converts a **tile-relative** `UnitRect` (e.g. an
    /// `ActiveTileMarker.region`, itself top-left-origin *within the tile*)
    /// into a frame-relative `UnitRect` given the tile's own frame-relative
    /// `UnitRect`, then defers to `pixelRect(for:frameWidth:frameHeight:)`
    /// for the final outward-rounded, clamped pixel conversion.
    package static func pixelRect(
        forTileRelative markerRegion: UnitRect,
        tileRegion: UnitRect,
        frameWidth: Int,
        frameHeight: Int
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard tileRegion.x.isFinite, tileRegion.y.isFinite,
              tileRegion.width.isFinite, tileRegion.height.isFinite,
              markerRegion.x.isFinite, markerRegion.y.isFinite,
              markerRegion.width.isFinite, markerRegion.height.isFinite
        else { return nil }

        let frameRelative = UnitRect(
            x: tileRegion.x + markerRegion.x * tileRegion.width,
            y: tileRegion.y + markerRegion.y * tileRegion.height,
            width: markerRegion.width * tileRegion.width,
            height: markerRegion.height * tileRegion.height
        )
        return pixelRect(for: frameRelative, frameWidth: frameWidth, frameHeight: frameHeight)
    }

    // MARK: - §0.5 BGRA crop (pure, byte-exact, stride-respecting)

    /// Pure: validates `data.count == bytesPerRow * frameHeight` (a short/
    /// malformed `CapturedFrame.pixelData` — e.g. a torn buffer from a race
    /// during teardown — must never be read out of bounds) and that `rect`
    /// lies fully within `[0, frameWidth] × [0, frameHeight]`, then returns a
    /// byte-exact row-major slice of `rect` from `data`, respecting
    /// `bytesPerRow` (never assuming `width * 4`). Returns `nil` on any
    /// precondition failure.
    ///
    /// **Phase 7 §3d fix (Phase 5 impl-review-1 MEDIUM-1, completed by Phase
    /// 7 impl-review-1 MEDIUM-3):** additionally requires
    /// `bytesPerRow >= frameWidth * 4` (mirroring
    /// `ScreenCaptureKitSource.validatedPixelGeometry`'s identical guard) and
    /// performs **every** size/offset addition and multiplication —
    /// including `rect.x + rect.width`, `rect.y + rect.height`, and
    /// `rect.x * bytesPerPixel`, not just the frame-level `bytesPerRow`/
    /// `frameHeight` math — with `multipliedReportingOverflow`/
    /// `addingReportingOverflow`, failing closed (`nil`) rather than
    /// trapping on a malformed/adversarial `CapturedFrame` or `rect` whose
    /// `bytesPerRow`/`frameWidth`/`frameHeight`/`rect.x`/`rect.y`/
    /// `rect.width`/`rect.height` are large enough to overflow `Int` — this
    /// is the exact pixel math `FrameDumpProbe` (Phase 7 §1) also calls via
    /// `averageBGRAColor`, so the diagnostic tool inherits the safe version
    /// rather than a second, unsafe copy.
    package static func croppedBGRA(
        from data: Data,
        frameWidth: Int,
        frameHeight: Int,
        bytesPerRow: Int,
        rect: (x: Int, y: Int, width: Int, height: Int)
    ) -> (data: Data, width: Int, height: Int, bytesPerRow: Int)? {
        guard frameWidth > 0, frameHeight > 0, bytesPerRow > 0 else { return nil }

        // `bytesPerRow` must be wide enough to hold one BGRA row of the
        // *frame's own* declared width — checked overflow-safely before the
        // comparison, since an adversarial `frameWidth` near `Int.max / 4`
        // would otherwise overflow a plain `frameWidth * 4` before this guard
        // ever gets a chance to reject it.
        let (minRowBytes, rowOverflowed) = frameWidth.multipliedReportingOverflow(by: 4)
        guard !rowOverflowed, bytesPerRow >= minRowBytes else { return nil }

        let (declaredByteCount, sizeOverflowed) = bytesPerRow.multipliedReportingOverflow(by: frameHeight)
        guard !sizeOverflowed, data.count == declaredByteCount else { return nil }

        guard rect.width > 0, rect.height > 0 else { return nil }
        guard rect.x >= 0, rect.y >= 0 else { return nil }

        // impl-review-1 MEDIUM-3: `rect.x + rect.width`/`rect.y + rect.height`
        // must be computed overflow-safely too — a malformed/adversarial
        // `rect` with a huge `x`/`width` (or `y`/`height`) could otherwise
        // overflow this bounds check itself before it ever gets a chance to
        // reject the rect, trapping instead of failing closed with `nil`.
        let (rectMaxX, rectMaxXOverflowed) = rect.x.addingReportingOverflow(rect.width)
        guard !rectMaxXOverflowed, rectMaxX <= frameWidth else { return nil }
        let (rectMaxY, rectMaxYOverflowed) = rect.y.addingReportingOverflow(rect.height)
        guard !rectMaxYOverflowed, rectMaxY <= frameHeight else { return nil }

        let bytesPerPixel = 4
        // impl-review-1 MEDIUM-3: `rect.x * bytesPerPixel` (used per-row
        // below to compute each source row's starting byte offset) must
        // also be overflow-checked here, once, rather than left as the
        // plain multiplication the per-row loop previously performed.
        let (rectXBytes, rectXBytesOverflowed) = rect.x.multipliedReportingOverflow(by: bytesPerPixel)
        guard !rectXBytesOverflowed else { return nil }

        let (cropBytesPerRow, cropRowOverflowed) = rect.width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !cropRowOverflowed else { return nil }
        let (cropByteCount, cropSizeOverflowed) = cropBytesPerRow.multipliedReportingOverflow(by: rect.height)
        guard !cropSizeOverflowed else { return nil }

        var cropped = Data(count: cropByteCount)

        let copiedOK: Bool = cropped.withUnsafeMutableBytes { destBuffer in
            data.withUnsafeBytes { sourceBuffer in
                guard let destBase = destBuffer.baseAddress,
                      let sourceBase = sourceBuffer.baseAddress
                else { return false }
                for row in 0..<rect.height {
                    let (rowOffset, rowOffsetOverflowed) = (rect.y + row).multipliedReportingOverflow(by: bytesPerRow)
                    let (sourceOffset, sourceOffsetOverflowed) = rowOffset.addingReportingOverflow(rectXBytes)
                    let destOffset = row * cropBytesPerRow
                    guard !rowOffsetOverflowed, !sourceOffsetOverflowed else { return false }
                    destBase.advanced(by: destOffset)
                        .copyMemory(from: sourceBase.advanced(by: sourceOffset), byteCount: cropBytesPerRow)
                }
                return true
            }
        }
        guard copiedOK else { return nil }

        return (data: cropped, width: rect.width, height: rect.height, bytesPerRow: cropBytesPerRow)
    }

    // MARK: - §0.7 Active-tile marker detection (pure color sampling)

    /// Pure: parses a `"#RRGGBB"` hex string into normalized `[0, 1]` channel
    /// values, or `nil` for any malformed input (wrong length, non-hex
    /// characters, missing `#`) — never traps on a malformed catalog literal.
    package static func parseHexColor(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.hasPrefix("#"), hex.count == 7 else { return nil }
        let digits = hex.dropFirst()
        guard let value = UInt32(digits, radix: 16) else { return nil }
        return (
            r: Double((value >> 16) & 0xFF) / 255.0,
            g: Double((value >> 8) & 0xFF) / 255.0,
            b: Double(value & 0xFF) / 255.0
        )
    }

    /// Pure: averages the B/G/R channels (alpha ignored) over every pixel in
    /// a cropped BGRA buffer, respecting `bytesPerRow` (never assuming
    /// `width * 4`), returning normalized `[0, 1]` channel values. Returns
    /// `nil` for a zero-area region or a buffer that does not match its own
    /// declared geometry (nothing safe to average) rather than dividing by
    /// zero or reading out of bounds.
    ///
    /// **Phase 7 §3d fix (Phase 5 impl-review-1 MEDIUM-1):** additionally
    /// requires `bytesPerRow >= width * 4` and performs the `data.count`
    /// validation with `multipliedReportingOverflow`, failing closed rather
    /// than trapping on adversarial/malformed geometry — see `croppedBGRA`'s
    /// identical fix above for the full rationale (both helpers are reused
    /// as-is by `FrameDumpProbe`, Phase 7 §1).
    package static func averageBGRAColor(
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> (r: Double, g: Double, b: Double)? {
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        let (minRowBytes, rowOverflowed) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflowed, bytesPerRow >= minRowBytes else { return nil }

        let (declaredByteCount, sizeOverflowed) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !sizeOverflowed, data.count == declaredByteCount else { return nil }

        var bSum = 0.0, gSum = 0.0, rSum = 0.0
        let readOK: Bool = data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            for row in 0..<height {
                let rowStart = row * bytesPerRow
                for col in 0..<width {
                    let pixelOffset = rowStart + col * 4
                    bSum += Double(base.load(fromByteOffset: pixelOffset, as: UInt8.self))
                    gSum += Double(base.load(fromByteOffset: pixelOffset + 1, as: UInt8.self))
                    rSum += Double(base.load(fromByteOffset: pixelOffset + 2, as: UInt8.self))
                }
            }
            return true
        }
        guard readOK else { return nil }

        let pixelCount = Double(width * height)
        return (r: rSum / pixelCount / 255.0, g: gSum / pixelCount / 255.0, b: bSum / pixelCount / 255.0)
    }

    /// Pure: `true` iff `sampledColor` is within `marker.colorTolerance` of
    /// `marker.hexColor`, using **max per-channel absolute distance**
    /// (matching `ActiveTileMarker.colorTolerance`'s own doc: "Maximum
    /// allowed per-channel color distance") — not Euclidean distance.
    /// Returns `false` (never matches) if `marker.hexColor` fails to parse —
    /// a malformed catalog literal must degrade to "this marker never
    /// matches", not crash or silently match everything.
    package static func markerMatches(
        _ marker: SpeakerLabelCatalog.ActiveTileMarker,
        sampledColor: (r: Double, g: Double, b: Double)
    ) -> Bool {
        guard let expected = Self.parseHexColor(marker.hexColor) else { return false }
        let distance = Swift.max(
            abs(sampledColor.r - expected.r),
            abs(sampledColor.g - expected.g),
            abs(sampledColor.b - expected.b)
        )
        return distance <= marker.colorTolerance
    }

    // MARK: - §0.8 zero/one/many active-candidate decision (pure, package-visible)

    /// Pure: resolves the zero/one/many active-candidate decision (§0.8)
    /// from the indices of candidates whose marker test matched this frame.
    /// Returns the single matched index iff **exactly one** candidate
    /// matched; `nil` for zero matches (no active tile detected) or two-or-
    /// more matches (ambiguous — SR-12's "must not guess" applies exactly
    /// here, identical in shape to the zero-match case). `package`-visible
    /// (plan-review-2 LOW-1) so `AlembicCheck` can exercise this decision
    /// directly against fabricated per-candidate match booleans, without
    /// needing a full `CapturedFrame`/marker pipeline.
    package static func singleActiveCandidate(matchedCandidateIndices: [Int]) -> Int? {
        guard matchedCandidateIndices.count == 1 else { return nil }
        return matchedCandidateIndices.first
    }

    // MARK: - §0.9 OCR result -> accepted name (pure selection)

    /// One OCR text-line candidate, decoupled from Vision's own
    /// `RecognizedTextObservation`/`RecognizedText` types so `selectName`
    /// below is testable with fabricated values — no live Vision request
    /// needed.
    package struct OCRObservation: Sendable, Equatable {
        package let text: String
        /// Vision's own top-candidate confidence, in `[0, 1]` per Vision's
        /// documented contract; not independently re-validated/clamped here
        /// — `SpeakerAttributionResult.init` already clamps defensively at
        /// the boundary where this becomes a `SpeakerAttributionResult`.
        package let confidence: Double

        package init(text: String, confidence: Double) {
            self.text = text
            self.confidence = confidence
        }
    }

    /// Pure: normalizes and selects the best usable name from `observations`
    /// (already filtered to one label region's OCR results for one sampled
    /// frame). Drops any observation whose `confidence` is below
    /// `minimumConfidence` or whose text normalizes to `nil` (DR-4); if
    /// nothing survives, returns `nil`; otherwise returns the surviving
    /// observation with the highest confidence, tie-broken by
    /// lexicographically smallest normalized name (matching this codebase's
    /// established `ActiveSpeakerTimeline.resolve` tie-break convention).
    package static func selectName(
        from observations: [OCRObservation],
        minimumConfidence: Double,
        roster: [String] = []
    ) -> SpeakerAttributionResult? {
        let survivors: [(name: String, confidence: Double)] = observations.compactMap { observation in
            guard observation.confidence >= minimumConfidence else { return nil }
            guard let normalized = SpeakerNameNormalizer.normalize(observation.text, roster: roster) else { return nil }
            return (name: normalized, confidence: observation.confidence)
        }
        guard !survivors.isEmpty else { return nil }

        let winner = survivors.reduce(survivors[0]) { best, candidate in
            if candidate.confidence != best.confidence {
                return candidate.confidence > best.confidence ? candidate : best
            }
            return candidate.name < best.name ? candidate : best
        }
        return SpeakerAttributionResult(displayName: winner.name, confidence: winner.confidence)
    }

    // MARK: - §0.10 Sample-state machine (pure)

    /// Pure input to `advance` below — the result of one sampled frame's
    /// marker/OCR pipeline, decoupled from *how* that outcome was reached
    /// (zero markers matched, markers were ambiguous, or a matched
    /// candidate's OCR yielded nothing above `selectName`'s floor are all
    /// `.noSignal` — the state machine does not need to distinguish them).
    package enum SampleOutcome: Sendable, Equatable {
        case noSignal
        case detected(name: String, confidence: Double)
    }

    /// The currently "open" (still-extending) speaker interval, tracked as
    /// actor state (`openInterval`) across samples.
    package struct OpenInterval: Sendable, Equatable {
        package let name: String
        package let confidence: Double
        package let start: Double
        package let end: Double

        package init(name: String, confidence: Double, start: Double, end: Double) {
            self.name = name
            self.confidence = confidence
            self.start = start
            self.end = end
        }
    }

    /// Pure: advances the sample-state machine by one sampled frame. Returns
    /// the next `openInterval` state and, if a range should be recorded to
    /// `ActiveSpeakerTimeline` this step, the `(name, confidence, range)` to
    /// record via `timeline.record(name:confidence:in:)`. Never produces a
    /// zero- or negative-length range; never bridges across a gap longer
    /// than `maxGap`; never bridges across a speaker change or a no-signal
    /// sample; never mutates state or produces a recording for a non-finite
    /// or **negative** `frameTime`/`maxGap`/`fallbackLookback` (plan-review-2
    /// MEDIUM-2 — a malformed/clock-skewed timestamp must never corrupt the
    /// timeline with a pre-session or otherwise invalid range).
    package static func advance(
        open: OpenInterval?,
        frameTime: Double,
        outcome: SampleOutcome,
        maxGap: Double,
        fallbackLookback: Double
    ) -> (nextOpen: OpenInterval?, recording: (name: String, confidence: Double, range: ClosedRange<Double>)?) {
        guard frameTime.isFinite, frameTime >= 0, maxGap >= 0, fallbackLookback >= 0 else {
            return (open, nil) // malformed input: no-op, never corrupt state (NR-6)
        }

        switch outcome {
        case .noSignal:
            // Closes on no marker match (HIGH-3): a sampled frame with no
            // unambiguous active tile ends the current speaker's presumed
            // continuation — a *later* detection must not bridge back
            // through this gap.
            return (nil, nil)

        case .detected(let name, let confidence):
            if let open, frameTime <= open.end {
                // Out-of-order/duplicate timestamp: drop, keep state
                // unchanged (never a zero/negative-length recording).
                return (open, nil)
            }
            if let open, open.name == name, frameTime - open.end <= maxGap {
                // Same speaker, continuous within the bounded max gap: extend.
                let range = open.end...frameTime
                let next = OpenInterval(name: name, confidence: confidence, start: open.start, end: frameTime)
                return (next, (name, confidence, range))
            }
            // Fresh start: no prior open interval, a speaker change, or the
            // gap since the last open interval's end exceeded `maxGap` — do
            // not assume the old speaker was still active across an
            // arbitrarily long gap; anchor only `fallbackLookback` back
            // instead.
            //
            // **Phase 7 §3d fix (Phase 5 impl-review-1 MEDIUM-2):** when this
            // fresh start follows a still-open interval for a *different*
            // speaker (`open.name != name`), clamp `start` to `open.end` so
            // the new interval never overlaps the prior speaker's
            // already-recorded range. Without this clamp, a speaker change
            // could anchor `start` at `frameTime - fallbackLookback` — a
            // point that may fall *before* `open.end` — producing two
            // recorded intervals for two different names covering the same
            // wall-clock span, a wrong-name risk (not merely "no
            // attribution"), which conflicts with SR-12's no-guess posture.
            // A same-speaker fresh start after a gap exceeding `maxGap` is
            // unaffected (`open.name == name` skips the clamp): re-opening
            // the same speaker after a long pause is not an overlap risk in
            // the same sense — the clamp only guards a genuine speaker
            // change.
            let rawStart = Swift.max(0, frameTime - fallbackLookback)
            let start: Double
            if let open, open.name != name {
                start = Swift.max(rawStart, open.end)
            } else {
                start = rawStart
            }
            let next = OpenInterval(name: name, confidence: confidence, start: start, end: frameTime)
            guard start < frameTime else {
                // `fallbackLookback == 0` (or frameTime == 0), or the overlap
                // clamp above pinned `start` to `frameTime` itself (e.g.
                // `open.end == frameTime`): no non-empty range to record yet,
                // but still anchor state so the *next* sample (if it
                // continues this speaker) extends from here rather than
                // re-applying the fallback lookback/clamp again.
                return (next, nil)
            }
            return (next, (name, confidence, start...frameTime))
        }
    }

    // MARK: - Live-Vision glue (not independently pure-testable)

    /// The live-Vision glue: gates on the throttle (§0.4), tests every
    /// candidate's marker to determine zero/one/many matches (§0.8), and for
    /// the unambiguous single-match case only, crops that candidate's
    /// `labelRegion`, builds one `CGImage` (§0.5), runs
    /// `RecognizeTextRequest`, maps results to `[OCRObservation]`, and
    /// advances the sample-state machine (§0.10). Never `throws` — every
    /// fallible step degrades to "skip this frame" (§0.11). Checks
    /// cancellation after the throttle decision and immediately before/after
    /// the Vision `await` (plan-review-2 MEDIUM-1) so a `stop()` that races
    /// an in-flight OCR request can never let a late result mutate state —
    /// `recordOutcome(_:frameTime:)` itself re-checks cancellation as a final
    /// guard before any `advance`/`timeline.record` call, regardless of
    /// which path reached it.
    private func process(frame: CapturedFrame) async {
        guard Self.shouldSample(
            frameTime: frame.sessionTime,
            lastSampledTime: lastSampledFrameTime,
            minInterval: configuration.samplingIntervalSeconds
        ) else { return }
        lastSampledFrameTime = frame.sessionTime

        guard !Task.isCancelled else { return } // checkpoint: right after the throttle decision

        // §0.2's invariant: this method only ever runs from the consumption
        // Task, which is only ever spawned when `catalogEntry` is non-nil
        // and validated — this guard is defensive, not load-bearing.
        guard let entry = catalogEntry else { return }

        // §0.8: evaluate every candidate's (cheap, non-OCR) marker test
        // before doing any OCR work.
        var matchedIndices: [Int] = []
        for (index, candidate) in entry.candidates.enumerated() {
            guard candidate.appliesToFrame(
                width: frame.width,
                height: frame.height,
                meetingTitle: meetingTitle
            ) else {
                continue
            }
            let matched = candidate.activeTileMarkers.contains { marker in
                guard let markerPixelRect = Self.pixelRect(
                    forTileRelative: marker.region,
                    tileRegion: candidate.tileRegion,
                    frameWidth: frame.width,
                    frameHeight: frame.height
                ) else { return false }
                guard let cropped = Self.croppedBGRA(
                    from: frame.pixelData,
                    frameWidth: frame.width,
                    frameHeight: frame.height,
                    bytesPerRow: frame.bytesPerRow,
                    rect: markerPixelRect
                ) else { return false }
                guard let sampledColor = Self.averageBGRAColor(
                    data: cropped.data,
                    width: cropped.width,
                    height: cropped.height,
                    bytesPerRow: cropped.bytesPerRow
                ) else { return false }
                return Self.markerMatches(marker, sampledColor: sampledColor)
            }
            if matched { matchedIndices.append(index) }
        }

        guard !matchedIndices.isEmpty else {
            recordOutcome(.noSignal, frameTime: frame.sessionTime)
            return
        }

        var recognized: [SpeakerAttributionResult] = []
        for index in matchedIndices {
            guard !Task.isCancelled else { return }
            if let selected = await recognizeName(
                in: entry.candidates[index],
                frame: frame
            ) {
                recognized.append(selected)
            }
        }

        guard recognized.count == 1, let selected = recognized.first else {
            // Multiple outlined tiles whose labels both resolve are genuine
            // ambiguity/crosstalk. Marker collisions whose label crop contains
            // no usable name are ignored rather than blocking the one
            // evidence-complete candidate.
            recordOutcome(.noSignal, frameTime: frame.sessionTime)
            return
        }
        recordOutcome(
            .detected(name: selected.displayName, confidence: selected.confidence),
            frameTime: frame.sessionTime
        )
    }

    private func recognizeName(
        in candidate: SpeakerLabelCatalog.TileCandidate,
        frame: CapturedFrame
    ) async -> SpeakerAttributionResult? {
        guard let labelPixelRect = Self.pixelRect(
            for: candidate.labelRegion,
            frameWidth: frame.width,
            frameHeight: frame.height
        ) else { return nil }
        guard let croppedLabel = Self.croppedBGRA(
            from: frame.pixelData,
            frameWidth: frame.width,
            frameHeight: frame.height,
            bytesPerRow: frame.bytesPerRow,
            rect: labelPixelRect
        ) else { return nil }

        guard let provider = CGDataProvider(data: croppedLabel.data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGImageByteOrderInfo.order32Little.rawValue)
        guard let cgImage = CGImage(
            width: croppedLabel.width,
            height: croppedLabel.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: croppedLabel.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        guard !Task.isCancelled else { return nil }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // `regionOfInterest` is left at its default (`.fullImage`) — this
        // phase already feeds Vision an exactly-cropped `cgImage` (§0.5), so
        // no additional ROI is applied on top of it.

        do {
            let observations = try await request.perform(on: cgImage)
            guard !Task.isCancelled else { return nil }
            let ocrObservations = observations.compactMap { observation -> OCRObservation? in
                let candidates = observation.topCandidates(
                    candidate.requiresLastFirstSeparator ? 5 : 1
                )
                let selected = candidate.requiresLastFirstSeparator
                    ? candidates.first(where: { $0.string.contains(",") })
                    : candidates.first
                guard let selected else { return nil }
                return OCRObservation(
                    text: selected.string,
                    confidence: Double(selected.confidence)
                )
            }
            return Self.selectName(
                from: ocrObservations,
                minimumConfidence: configuration.minimumOCRConfidence,
                roster: configuration.roster
            )
        } catch {
            return nil
        }
    }

    /// Advances the sample-state machine and, if it produces a recording,
    /// appends it to `timeline`. Re-checks cancellation as the single choke
    /// point every `process(frame:)` code path funnels through before
    /// mutating `openInterval`/`timeline` (plan-review-2 MEDIUM-1) — stronger
    /// than checking only at the call sites, since it applies uniformly
    /// regardless of which branch of `process(frame:)` reached here.
    private func recordOutcome(_ outcome: SampleOutcome, frameTime: Double) {
        guard !Task.isCancelled else { return } // checkpoint: before any advance/timeline.record
        let step = Self.advance(
            open: openInterval,
            frameTime: frameTime,
            outcome: outcome,
            maxGap: configuration.maxGapSeconds,
            fallbackLookback: configuration.samplingIntervalSeconds
        )
        openInterval = step.nextOpen
        if let recording = step.recording {
            timeline.record(name: recording.name, confidence: recording.confidence, in: recording.range)
        }
    }
}

/// Clamps `self` into `range`. Duplicated from `AttributionProvider.swift`/
/// `ActiveSpeakerTimeline.swift`'s identical helper — each file that needs it
/// declares its own `fileprivate` copy, per this codebase's established
/// convention of keeping every file self-contained with no cross-file shared
/// internal API.
///
/// A non-finite input (`NaN`, `+.infinity`, `-.infinity`) is sanitized to
/// `range.lowerBound` before the min/max clamp runs — plain min/max clamping
/// never touches `NaN` (every comparison against `NaN` is `false`).
fileprivate extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard self.isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
