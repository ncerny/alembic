import Foundation

/// A region expressed as **fractions of the captured frame's width/height**
/// (each in `[0, 1]`), so catalog entries are resolution-independent — Phase 5
/// converts to pixel coordinates against whatever frame size
/// `ScreenCaptureKitSource` actually delivers (OQ-2 is still open on exact
/// resolution; fractional regions avoid coupling the catalog to that answer).
/// Foundation-only by design (no `CGRect` — see the top-level layering rule
/// in `checkFoundationOnlyTopLevelAudit`).
public struct UnitRect: Sendable, Equatable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// `true` iff all four fields fall within `[0, 1]` and the rect has
    /// non-negative extent (`x + width <= 1`, `y + height <= 1`). Used by the
    /// catalog's structural check — not a claim about geometric correctness.
    public var isNormalized: Bool {
        x >= 0 && y >= 0 && width >= 0 && height >= 0 && x + width <= 1 && y + height <= 1
    }

    /// `true` iff `other` is fully contained within `self` (both expressed in
    /// the same coordinate space, e.g. both frame-relative). Used to prove a
    /// `SpeakerLabelCatalog.TileCandidate`'s `labelRegion` sits inside its
    /// `tileRegion` rather than merely floating alongside it. A tiny epsilon
    /// tolerates floating-point literal accumulation (e.g. `0.90 + 0.10`).
    public func contains(_ other: UnitRect) -> Bool {
        let epsilon = 1e-9
        return other.x >= x - epsilon
            && other.y >= y - epsilon
            && (other.x + other.width) <= (x + width) + epsilon
            && (other.y + other.height) <= (y + height) + epsilon
    }
}

/// Per-meeting-app OCR targeting data (SR-20): **what region(s) of a captured
/// frame to run text recognition over, and what marks a tile as the active
/// speaker**, kept as data so a Teams (or future app) UI change only requires
/// updating this table — never the search logic that consumes it (mirrors
/// `MeetingChatMarkers`/`teamsDefaults` in `TeamsChatPoster.swift`).
///
/// **Scope note:** this type supplies *where to look* (`TileCandidate.
/// labelRegion`), *which tile that label belongs to*
/// (`TileCandidate.tileRegion`), *which app* (bundle-prefix matching), and
/// *what active-tile signal to test for* (`TileCandidate.activeTileMarkers`,
/// as data — SR-20). It does **not** perform the pixel comparison itself:
/// reading frame pixels and testing them against a marker's
/// `region`/`hexColor`/`colorTolerance` is `Vision`/`CoreGraphics` work that
/// only Phase 5's `VisionSpeakerAttributor` may perform (SR-2 — the only file
/// allowed to import `Vision`/`CoreGraphics` for this feature). The
/// distinction is data vs. execution, not "marker data doesn't exist yet":
/// SR-20/SR-21 require this catalog to *ship* Teams marker data now, even
/// though nothing in Phase 2 evaluates it against real pixels.
public struct SpeakerLabelCatalog: Sendable {
    public struct FrameSize: Sendable, Equatable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// One active-speaker visual indicator to test for, expressed as data
    /// (SR-20) — e.g. Teams draws a colored highlight/border around the tile
    /// of whoever is currently speaking. `region` is a `UnitRect` *relative to
    /// the tile* (`TileCandidate.tileRegion`), not the full frame — Phase 5
    /// translates it against the tile it is currently scanning.
    ///
    /// **Calibration history (2026-08-18):** an earlier pass of this phase
    /// briefly shipped an `.alwaysActive` marker kind (no pixel signal at
    /// all) for the Teams 1-on-1 primary tile, on the theory that a strict
    /// 1-on-1 call's single tile needs no active-speaker disambiguation. A
    /// human operator directly observing the live call confirmed a visible
    /// outline does exist around the 1-on-1 primary tile — an earlier
    /// frame-dump pass's failure to detect a color match had sampled the
    /// wrong region/color (a 20%-wide left-edge strip at the Phase 2 MVP's
    /// speculative `#6264A7` guess), not evidence that no outline is drawn.
    /// The `.alwaysActive` kind was removed; this type only ever expresses a
    /// measured `.highlightColor` marker. A corrected, narrow, single-pixel-
    /// column re-measurement (`frame x=3`, 1600×1000 frames) then found the
    /// real outline: a 1px-wide vertical purple line at `#797EE5`, present on
    /// active-speaking frames and absent (neutral gray/tan) on inactive
    /// frames — see `teamsDefaults`'s doc comment and
    /// `docs/2-speaker-attribution/calibration-record.md` for the full
    /// evidence. Do not reintroduce an unconditional/"trivially active"
    /// marker kind without new, explicit evidence and sign-off — the type is
    /// deliberately kept capable of a real, measured highlight-color marker
    /// only.
    public struct ActiveTileMarker: Sendable, Equatable {
        /// Sub-region, in tile-relative unit-fractions, where the indicator
        /// is expected (e.g. a thin strip along one edge of the tile, or a
        /// full-perimeter border — geometry is data, not assumed here).
        public let region: UnitRect
        /// Expected indicator color as `"#RRGGBB"`.
        public let hexColor: String
        /// Maximum allowed per-channel color distance, in `[0, 1]`, for a
        /// sampled pixel to still count as a match.
        public let colorTolerance: Double

        public init(region: UnitRect, hexColor: String, colorTolerance: Double) {
            self.region = region
            self.hexColor = hexColor
            self.colorTolerance = colorTolerance
        }
    }

    /// Binds one OCR label region to the tile that contains it, plus the
    /// active-tile markers to test for that tile.
    ///
    /// This is the data Phase 5 needs to translate a tile-relative
    /// `ActiveTileMarker` into frame pixel coordinates for a given candidate
    /// label **without any hard-coded Teams layout assumption**: `tileRegion`
    /// and `labelRegion` are both frame-relative `UnitRect`s produced by this
    /// catalog, so Phase 5 only has to (1) OCR `labelRegion`, and (2) if OCR
    /// finds a name there, test `activeTileMarkers` (tile-relative) against
    /// `tileRegion`. No geometry is inferred or hard-coded by the consumer.
    public struct TileCandidate: Sendable, Equatable {
        /// Optional fail-closed frame-shape signature for the layout this
        /// candidate belongs to. Teams window titles do not identify Gallery
        /// versus shared-content views, but their measured capture aspect
        /// ratios differ. A candidate outside this range is never tested.
        public let frameAspectRatioRange: ClosedRange<Double>?
        /// Optional exact captured size required for layouts whose geometry
        /// has only been validated at one WindowServer composition size.
        public let requiredFrameSize: FrameSize?
        /// Optional title signature for layouts Teams identifies in window
        /// chrome independently of frame geometry.
        public let requiredMeetingTitleFragment: String?
        /// When true, OCR must retain Teams' visible `Last, First` separator.
        /// This rejects low-quality alternatives that drop the comma and make
        /// name order or token boundaries ambiguous.
        public let requiresLastFirstSeparator: Bool
        /// Frame-relative unit rect of the tile containing this candidate's
        /// label — the region whose border/background `activeTileMarkers`
        /// are tested against.
        public let tileRegion: UnitRect
        /// Frame-relative unit rect of the name-label strip to OCR within
        /// this tile. Tried in priority order alongside sibling candidates
        /// (e.g. the single speaker-view label first, then grid-view
        /// tile-label regions); Phase 5 stops at the first candidate whose
        /// `labelRegion` yields a recognized name above its own OCR
        /// confidence floor. **Never the full frame** (SR-5 requires OCR
        /// over a catalogued region, not the whole frame).
        public let labelRegion: UnitRect
        /// Active-tile visual markers to test for this candidate's tile
        /// (SR-20/SR-21), tried in order the same way sibling candidates are.
        /// Non-empty for every shipped candidate — a candidate with a label
        /// region but no markers cannot express "is this tile active",
        /// which is insufficient for SR-20.
        public let activeTileMarkers: [ActiveTileMarker]

        public init(
            frameAspectRatioRange: ClosedRange<Double>? = nil,
            requiredFrameSize: FrameSize? = nil,
            requiredMeetingTitleFragment: String? = nil,
            requiresLastFirstSeparator: Bool = false,
            tileRegion: UnitRect,
            labelRegion: UnitRect,
            activeTileMarkers: [ActiveTileMarker]
        ) {
            self.frameAspectRatioRange = frameAspectRatioRange
            self.requiredFrameSize = requiredFrameSize
            self.requiredMeetingTitleFragment = requiredMeetingTitleFragment
            self.requiresLastFirstSeparator = requiresLastFirstSeparator
            self.tileRegion = tileRegion
            self.labelRegion = labelRegion
            self.activeTileMarkers = activeTileMarkers
        }

        public func appliesToFrame(width: Int, height: Int, meetingTitle: String? = nil) -> Bool {
            guard width > 0, height > 0 else { return false }
            if let requiredFrameSize {
                guard width == requiredFrameSize.width, height == requiredFrameSize.height else {
                    return false
                }
            }
            if let requiredMeetingTitleFragment {
                guard let meetingTitle,
                      meetingTitle.contains(requiredMeetingTitleFragment)
                else { return false }
            }
            guard let frameAspectRatioRange else { return true }
            guard frameAspectRatioRange.lowerBound.isFinite,
                  frameAspectRatioRange.upperBound.isFinite,
                  frameAspectRatioRange.lowerBound > 0,
                  frameAspectRatioRange.lowerBound <= frameAspectRatioRange.upperBound
            else { return false }
            return frameAspectRatioRange.contains(Double(width) / Double(height))
        }
    }

    /// Meeting-window evidence required before any frame consumption starts.
    /// Candidate-level `frameAspectRatioRange` values then select the
    /// calibrated on-screen layout from the captured frame itself.
    public struct LayoutRequirement: Sendable, Equatable {
        /// Optional exact substring required in the resolved meeting-window
        /// title. `nil` accepts any non-empty resolved title; a missing or
        /// empty title always fails closed.
        public let requiredMeetingTitleFragment: String?
        /// Human-readable layout name, for diagnostics/docs only — never
        /// parsed or matched against.
        public let layoutName: String
        /// Remote-participant counts represented by the measured candidate
        /// sets. This is evidence metadata, not a runtime participant counter.
        public let supportedRemoteParticipantCounts: [Int]

        public init(
            requiredMeetingTitleFragment: String?,
            layoutName: String,
            supportedRemoteParticipantCounts: [Int]
        ) {
            self.requiredMeetingTitleFragment = requiredMeetingTitleFragment
            self.layoutName = layoutName
            self.supportedRemoteParticipantCounts = supportedRemoteParticipantCounts
        }
    }

    public struct AppEntry: Sendable, Equatable {
        public let displayName: String
        /// Bundle-ID prefixes, matched with the same dot-delimited,
        /// longest-prefix, case-insensitive rule as
        /// `MeetingAppCatalog.match(bundleID:)` (duplicated here, not shared,
        /// so this file stays a self-contained data table — see the
        /// duplication rationale below `match(bundleID:)`).
        public let bundlePrefixes: [String]
        /// Tile/label/marker triples, in priority order (e.g. the single
        /// speaker-view tile first, then each grid-view tile). Phase 5 tries
        /// them in order, OCRing each `labelRegion` and testing
        /// `activeTileMarkers` against the matching `tileRegion`.
        public let candidates: [TileCandidate]
        /// Fail-closed meeting-window gate consulted in addition to
        /// `markersValidated` before frame consumption starts.
        public let layoutRequirement: LayoutRequirement
        /// **Phase 5 fail-closed gate (§0.2a).** `true` only once this
        /// entry's `candidates`/`activeTileMarkers` geometry has been
        /// re-derived and confirmed against a *live* capture (Phase 7's
        /// frame-dump diagnostic, SR-22) — never inferred, never defaulted.
        /// No default value is offered on `init`: every call site (including
        /// `teamsDefaults`) must state this explicitly, so a newly added
        /// catalog entry cannot silently inherit "validated" by omission.
        /// While `false`, `VisionSpeakerAttributor` never starts its frame-
        /// consumption `Task` for this entry — the same structural "no
        /// attribution ever produced" guarantee as an unmatched bundle ID
        /// (SR-12/SR-23). This is a one-line, additive, non-behavior-changing
        /// field: `match(bundleID:)`, `candidateRegions`, and
        /// `activeTileMarkers` are otherwise unchanged.
        public let markersValidated: Bool

        public init(
            displayName: String,
            bundlePrefixes: [String],
            candidates: [TileCandidate],
            layoutRequirement: LayoutRequirement,
            markersValidated: Bool
        ) {
            self.displayName = displayName
            self.bundlePrefixes = bundlePrefixes
            self.candidates = candidates
            self.layoutRequirement = layoutRequirement
            self.markersValidated = markersValidated
        }

        /// Pure, data-driven meeting-window gate. Candidate-level frame-shape
        /// checks perform the on-screen layout selection later.
        public func matchesLayout(meetingTitle: String?) -> Bool {
            guard let meetingTitle, !meetingTitle.isEmpty else { return false }
            guard let requiredFragment = layoutRequirement.requiredMeetingTitleFragment else {
                return true
            }
            return meetingTitle.contains(requiredFragment)
        }

        /// Convenience: every candidate's `labelRegion`, in priority order —
        /// for callers that only need "where to OCR" without the
        /// tile/marker binding. Derived, not stored, so it can never drift
        /// from `candidates`.
        public var candidateRegions: [UnitRect] { candidates.map(\.labelRegion) }

        /// Convenience: every candidate's `activeTileMarkers`, flattened in
        /// candidate priority order. Derived, not stored, so it can never
        /// drift from `candidates`.
        public var activeTileMarkers: [ActiveTileMarker] { candidates.flatMap(\.activeTileMarkers) }
    }

    /// Live-calibrated Teams candidates. Pass #1 measured the strict
    /// 1600×1000 1-on-1 layout and `#797EE5` left outline. Pass #2 measured
    /// the 2400×926 seven-person 4-over-3 Gallery layout, two distinct active
    /// speakers, a no-outline silent frame, cropped-label OCR, and the
    /// `#8288FC` top outline. Frame-aspect signatures and exact marker
    /// geometry keep shared-content, side-panel, resized, and unknown layouts
    /// fail closed. Sanitized evidence is in the calibration record.
    private static let teamsGalleryAspectRatio = 2.57...2.61

    private static func teamsGalleryCandidate(
        tileXPixels: Double,
        tileYPixels: Double,
        tileHeightPixels: Double,
        labelYPixels: Double
    ) -> TileCandidate {
        TileCandidate(
            frameAspectRatioRange: teamsGalleryAspectRatio,
            requiredFrameSize: FrameSize(width: 2400, height: 926),
            requiresLastFirstSeparator: true,
            tileRegion: UnitRect(
                x: tileXPixels / 2400.0,
                y: tileYPixels / 926.0,
                width: 600.0 / 2400.0,
                height: tileHeightPixels / 926.0
            ),
            labelRegion: UnitRect(
                x: tileXPixels / 2400.0,
                y: labelYPixels / 926.0,
                width: 360.0 / 2400.0,
                height: 49.0 / 926.0
            ),
            activeTileMarkers: [
                ActiveTileMarker(
                    region: UnitRect(
                        x: 5.0 / 600.0,
                        y: 1.5 / tileHeightPixels,
                        width: 590.0 / 600.0,
                        height: 0.25 / tileHeightPixels
                    ),
                    hexColor: "#8288FC",
                    colorTolerance: 0.09
                )
            ]
        )
    }

    private static func teamsThreePersonCandidate(
        tileXPixels: Double,
        tileYPixels: Double,
        tileWidthPixels: Double,
        tileHeightPixels: Double,
        labelYPixels: Double,
        labelHeightPixels: Double,
        markerColor: String
    ) -> TileCandidate {
        TileCandidate(
            frameAspectRatioRange: teamsGalleryAspectRatio,
            requiredFrameSize: FrameSize(width: 2400, height: 926),
            requiresLastFirstSeparator: true,
            tileRegion: UnitRect(
                x: tileXPixels / 2400.0,
                y: tileYPixels / 926.0,
                width: tileWidthPixels / 2400.0,
                height: tileHeightPixels / 926.0
            ),
            labelRegion: UnitRect(
                x: tileXPixels / 2400.0,
                y: labelYPixels / 926.0,
                width: 450.0 / 2400.0,
                height: labelHeightPixels / 926.0
            ),
            activeTileMarkers: [
                ActiveTileMarker(
                    region: UnitRect(
                        x: 1.5 / tileWidthPixels,
                        y: 6.0 / tileHeightPixels,
                        width: 0.25 / tileWidthPixels,
                        height: (tileHeightPixels - 12.0) / tileHeightPixels
                    ),
                    hexColor: markerColor,
                    colorTolerance: 0.09
                )
            ]
        )
    }

    public static let teamsDefaults = AppEntry(
        displayName: "Microsoft Teams",
        bundlePrefixes: ["com.microsoft.teams", "com.microsoft.teams2"],
        candidates: [
            TileCandidate(
                frameAspectRatioRange: 1.58...1.62,
                requiredMeetingTitleFragment: ":: 1 on 1",
                tileRegion: UnitRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0),
                labelRegion: UnitRect(x: 0.0, y: 0.965, width: 0.12, height: 0.035),
                activeTileMarkers: [
                    ActiveTileMarker(
                        region: UnitRect(x: 3.0 / 1600.0, y: 120.0 / 1000.0, width: 1.0 / 1600.0, height: 840.0 / 1000.0),
                        hexColor: "#797EE5",
                        colorTolerance: 0.09
                    )
                ]
            ),
            teamsGalleryCandidate(
                tileXPixels: 0,
                tileYPixels: 158,
                tileHeightPixels: 336,
                labelYPixels: 445
            ),
            teamsGalleryCandidate(
                tileXPixels: 600,
                tileYPixels: 158,
                tileHeightPixels: 336,
                labelYPixels: 445
            ),
            teamsGalleryCandidate(
                tileXPixels: 1200,
                tileYPixels: 158,
                tileHeightPixels: 336,
                labelYPixels: 445
            ),
            teamsGalleryCandidate(
                tileXPixels: 1800,
                tileYPixels: 158,
                tileHeightPixels: 336,
                labelYPixels: 445
            ),
            teamsGalleryCandidate(
                tileXPixels: 300,
                tileYPixels: 495,
                tileHeightPixels: 337,
                labelYPixels: 780
            ),
            teamsGalleryCandidate(
                tileXPixels: 900,
                tileYPixels: 495,
                tileHeightPixels: 337,
                labelYPixels: 780
            ),
            teamsGalleryCandidate(
                tileXPixels: 1500,
                tileYPixels: 495,
                tileHeightPixels: 337,
                labelYPixels: 780
            ),
            teamsThreePersonCandidate(
                tileXPixels: 1200,
                tileYPixels: 99,
                tileWidthPixels: 764,
                tileHeightPixels: 396,
                labelYPixels: 445,
                labelHeightPixels: 49,
                markerColor: "#898FFE"
            ),
            teamsThreePersonCandidate(
                tileXPixels: 818,
                tileYPixels: 495,
                tileWidthPixels: 764,
                tileHeightPixels: 431,
                labelYPixels: 875,
                labelHeightPixels: 51,
                markerColor: "#8086EA"
            )
        ],
        layoutRequirement: LayoutRequirement(
            requiredMeetingTitleFragment: nil,
            layoutName: "macOS Teams calibrated 1-on-1, three-person, and seven-person Gallery layouts",
            supportedRemoteParticipantCounts: [1, 2, 6]
        ),
        markersValidated: true
    )

    /// The authoritative list; add further apps (Zoom/Meet/…) as additional
    /// entries (SR-21) — no change to `match(bundleID:)` required.
    public static let entries: [AppEntry] = [teamsDefaults]

    /// Longest dot-delimited bundle-prefix match, case-insensitive — same
    /// semantics as `MeetingAppCatalog.match(bundleID:)`. Returns `nil` when
    /// no entry matches (SR-23: unknown app ⇒ no attribution, never a guess).
    ///
    /// Duplicated (not shared with `MeetingAppCatalog.match`), by design:
    /// `MeetingAppCatalog.match` returns a `MeetingAppMatch` tied to
    /// `MeetingApp` (detection rules — `requiresOutput`/`requiresInput`/etc. —
    /// irrelevant to OCR targeting). Rather than couple this file to that
    /// unrelated type, or generalize `MeetingAppCatalog`'s matching into a
    /// shared free function (out of this phase's scope), the ~10-line
    /// longest-prefix matcher is duplicated verbatim in style, keeping this
    /// file a fully self-contained, data-first table per SR-20.
    public static func match(bundleID: String) -> AppEntry? {
        let id = bundleID.lowercased()
        var best: (entry: AppEntry, prefixLength: Int)?
        for entry in entries {
            for prefix in entry.bundlePrefixes {
                let p = prefix.lowercased()
                guard id == p || id.hasPrefix(p + ".") else { continue }
                if best == nil || p.count > best!.prefixLength {
                    best = (entry, p.count)
                }
            }
        }
        return best?.entry
    }
}
