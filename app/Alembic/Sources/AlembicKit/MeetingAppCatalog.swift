import Foundation

// MARK: - MeetingApp

/// A known meeting application and its audio-detection rules.
///
/// All properties are Foundation-only and `Sendable`; this type requires no
/// Apple platform frameworks and is fully testable in `AlembicCheck`.
public struct MeetingApp: Sendable, Equatable {
    /// Human-readable app name shown in the UI.
    public let displayName: String

    /// Bundle-ID prefixes that identify this app and its helper/renderer
    /// processes. Use dot-delimited prefix matching (see `MeetingAppCatalog.match`):
    /// prefix `P` matches bundle ID `B` iff `B == P` or `B.hasPrefix(P + ".")`.
    public let bundlePrefixes: [String]

    /// When `true`, this app holds audio outside of calls (e.g. Zoom
    /// Settings → Audio preview), so at least one matching process must have
    /// `isRunningOutput == true` before the app is considered in-call.
    public let requiresOutput: Bool

    /// When `true`, at least one matching process must also have
    /// `isRunningInput == true` before the app counts as *interactively*
    /// in-call. Combined with `requiresOutput`, this is the strong signal for
    /// a real two-way call: notification chimes never run the mic, so they can
    /// hold output (Electron keeps the output unit alive ~10–15 s after a
    /// sound) without ever satisfying this gate.
    public let requiresInput: Bool

    /// When `true`, output-only activity (mic never running — e.g. a town
    /// hall / live event the user attends view-only) may still produce a
    /// detection, but only as a `.broadcastCandidate`: the detection policy
    /// applies a much longer start debounce, and the detector additionally
    /// requires a meeting window whose title survives
    /// `nonMeetingTitlePrefixes` strictly.
    public let broadcastEligible: Bool

    /// When `true`, a window-title confirmation from `WindowTitleProbe`
    /// (Phase 7) is required before this entry can produce a detection.
    ///
    /// Entries with this flag are present in the catalog but **cannot match
    /// on bundle ID alone** — this prevents generic browser/WebKit helper
    /// audio from being mistaken for a meeting.
    public let requiresTitleConfirmation: Bool

    /// Window-title substrings used by `WindowTitleProbe` (Phase 7) to
    /// confirm or disambiguate detections.
    public let titleHints: [String]

    /// Leading ` | `-delimited window-title segments that identify non-meeting
    /// windows for this app (e.g. Teams hub sections like "Chat", "Calendar").
    ///
    /// `MeetingContext.bestTitle` uses these as exclusions: any candidate whose
    /// first ` | `-delimited segment (trimmed) exactly matches one of these
    /// strings is dropped before title ranking. If all candidates are excluded,
    /// the function falls back to the standard ranking over the original
    /// candidates so a title is never lost.
    public let nonMeetingTitlePrefixes: [String]

    /// Suffixes to strip from the end of the selected window title before using
    /// it as a meeting name (e.g. `" | Microsoft Teams"`).
    ///
    /// Many Electron apps append the app name to every window title. Stripping
    /// it produces a clean meeting name in transcript file names and YAML
    /// frontmatter (e.g. `"Standup | Microsoft Teams"` → `"Standup"`).
    /// Applied after `bestTitle` ranking; only the first matching suffix is
    /// stripped. If stripping would leave an empty string the original title is
    /// kept unchanged.
    public let titleTrailingStrips: [String]

    public init(
        displayName: String,
        bundlePrefixes: [String],
        requiresOutput: Bool = false,
        requiresInput: Bool = false,
        broadcastEligible: Bool = false,
        requiresTitleConfirmation: Bool = false,
        titleHints: [String] = [],
        nonMeetingTitlePrefixes: [String] = [],
        titleTrailingStrips: [String] = []
    ) {
        self.displayName = displayName
        self.bundlePrefixes = bundlePrefixes
        self.requiresOutput = requiresOutput
        self.requiresInput = requiresInput
        self.broadcastEligible = broadcastEligible
        self.requiresTitleConfirmation = requiresTitleConfirmation
        self.titleHints = titleHints
        self.nonMeetingTitlePrefixes = nonMeetingTitlePrefixes
        self.titleTrailingStrips = titleTrailingStrips
    }
}

// MARK: - MeetingAppMatch

/// The result of matching a bundle ID against the catalog.
///
/// `canonicalBundlePrefix` is the specific prefix that matched — the
/// canonical bundle ID for the capturable parent process (e.g.
/// `com.microsoft.teams2` for a helper bundle
/// `com.microsoft.teams2.modulehost`). Use this value when resolving to a
/// `CaptureTarget` via ScreenCaptureKit.
public struct MeetingAppMatch: Sendable, Equatable {
    /// The matched catalog entry.
    public let app: MeetingApp
    /// The matched prefix, suitable for resolving to a SCK `CaptureTarget`.
    public let canonicalBundlePrefix: String
}

// MARK: - AudioProcessState

/// A snapshot of one audio process's activity, as populated by
/// `AudioProcessMonitor` (Phase 2) and consumed by
/// `MeetingAppCatalog.isInCall(processStates:)`.
///
/// The caller (Phase 2) is responsible for excluding Alembic's own PID
/// before building the snapshot array.
public struct AudioProcessState: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(
        pid: Int32,
        bundleID: String,
        isRunningInput: Bool,
        isRunningOutput: Bool
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

// MARK: - MeetingAppCatalog

/// Catalog of known meeting apps and their audio-detection rules.
///
/// All functions are pure and Foundation-only; they can be called from any
/// context and are fully testable in `AlembicCheck` without platform imports.
///
/// **Intentional omissions:**
/// - **Discord** — manual-only this iteration. Discord holds the mic whenever
///   connected to a voice channel (even when muted or using PTT), producing
///   consistent false positives for audio-activity detection.
/// - **Generic browser / WebKit helpers** — present with
///   `requiresTitleConfirmation: true` so they can **never** produce a
///   detection on bundle ID alone. Google Meet in a browser is unlocked only
///   when `WindowTitleProbe` (Phase 7) confirms a "Meet –" tab title.
public enum MeetingAppCatalog {

    /// The authoritative list of known meeting apps.
    public static let apps: [MeetingApp] = [
        MeetingApp(
            displayName: "Microsoft Teams",
            bundlePrefixes: [
                "com.microsoft.teams",   // Teams classic
                "com.microsoft.teams2",  // Teams new (covers .modulehost, .helper, etc.)
            ],
            requiresOutput: true,    // notification chimes hold output for 10-15s
            requiresInput: true,     // ...but never the mic; a real call runs both
            broadcastEligible: true, // town halls / live events: output-only, slow tier
            nonMeetingTitlePrefixes: [
                "Chat", "Activity", "Calendar", "Calls",
                "Teams and Channels", "Files", "Microsoft Teams",
                // Picture-in-picture call overlay; its leading segment is chrome
                // ("Meeting compact view | <real name> | Microsoft Teams"), so it
                // must be dropped in favour of the full call/meeting window.
                "Meeting compact view",
            ],
            titleTrailingStrips: [" | Microsoft Teams"]
        ),
        MeetingApp(
            displayName: "Zoom",
            bundlePrefixes: ["us.zoom.xos"],
            requiresOutput: true,    // Zoom holds the mic during Settings → Audio preview
            requiresInput: true,     // speaker test / previews hold output without a call
            broadcastEligible: true, // webinars: attendee mic never runs
            titleHints: ["Zoom Meeting"]
        ),
        MeetingApp(
            displayName: "Slack",
            bundlePrefixes: ["com.tinyspeck.slackmacgap"],
            requiresOutput: true,    // Slack plays notification sounds all day
            requiresInput: true      // huddles always run the mic; no broadcast mode
        ),
        // Generic browser / WebKit helpers — gated behind title confirmation.
        // These cover Google Meet in Chrome or Safari, but MUST NOT fire on
        // bundle ID alone. Discord web and other non-meeting browser tabs run
        // in the same renderer family.
        MeetingApp(
            displayName: "Google Meet (browser)",
            bundlePrefixes: [
                "com.google.Chrome.helper",
                "com.apple.WebKit.WebContent",
                "com.apple.WebKit.GPU",
            ],
            requiresTitleConfirmation: true,
            titleHints: ["Meet –"]
        ),
    ]

    // MARK: - Bundle-ID matching

    /// Returns the `MeetingAppMatch` whose prefix is the **longest**
    /// dot-delimited match for `bundleID`, or `nil` if no entry matches.
    ///
    /// Dot-delimited matching: prefix `P` matches `B` iff `B == P` or
    /// `B.hasPrefix(P + ".")`. This prevents `com.foo.bar` from matching
    /// `com.foo.barbaz`.
    ///
    /// Bundle IDs are compared case-insensitively; the original-case prefix
    /// is preserved in `MeetingAppMatch.canonicalBundlePrefix`.
    public static func match(bundleID: String) -> MeetingAppMatch? {
        let id = bundleID.lowercased()
        var best: MeetingAppMatch? = nil
        for app in apps {
            for prefix in app.bundlePrefixes {
                let p = prefix.lowercased()
                guard id == p || id.hasPrefix(p + ".") else { continue }
                if best == nil || p.count > best!.canonicalBundlePrefix.count {
                    best = MeetingAppMatch(app: app, canonicalBundlePrefix: prefix)
                }
            }
        }
        return best
    }

    /// Resolves a bundle ID (including helper/renderer variants) to its
    /// parent `MeetingAppMatch`. The `canonicalBundlePrefix` is suitable
    /// for resolving a SCK `CaptureTarget`. Equivalent to `match(bundleID:)`.
    public static func resolveParent(bundleID: String) -> MeetingAppMatch? {
        match(bundleID: bundleID)
    }

    // MARK: - In-call detection

    /// One app's current in-call evidence, produced by `detectCandidates`.
    public struct InCallCandidate: Sendable, Equatable {
        public let match: MeetingAppMatch
        /// `.interactive` when the app's full audio gate is satisfied;
        /// `.broadcastCandidate` when only output is running and the app is
        /// `broadcastEligible` (needs the slow debounce + title gate upstream).
        public let tier: DetectionTier
        public let hasInput: Bool
        public let hasOutput: Bool
    }

    /// Returns every catalog app with in-call evidence in `processStates`.
    ///
    /// **Caller responsibility:** the `processStates` array must already
    /// exclude Alembic's own PID.
    ///
    /// Rules per app per prefix:
    /// - `requiresTitleConfirmation: true` → skipped unless `confirmedTitles`
    ///   contains an overlapping `titleHints` substring.
    /// - `requiresInput`/`requiresOutput` gates must all be satisfied for an
    ///   `.interactive` candidate (default OR gate when neither is set).
    /// - `broadcastEligible: true` + output running (gates not satisfied) →
    ///   `.broadcastCandidate`.
    public static func detectCandidates(
        processStates: [AudioProcessState],
        confirmedTitles: Set<String> = []
    ) -> [InCallCandidate] {
        var candidates: [InCallCandidate] = []

        for app in apps {
            if app.requiresTitleConfirmation {
                let confirmed = app.titleHints.contains { hint in
                    confirmedTitles.contains { $0.contains(hint) }
                }
                guard confirmed else { continue }
            }
            for prefix in app.bundlePrefixes {
                let p = prefix.lowercased()
                let relevant = processStates.filter { state in
                    let id = state.bundleID.lowercased()
                    return id == p || id.hasPrefix(p + ".")
                }
                guard !relevant.isEmpty else { continue }
                let hasInput = relevant.contains { $0.isRunningInput }
                let hasOutput = relevant.contains { $0.isRunningOutput }

                let interactive: Bool
                switch (app.requiresInput, app.requiresOutput) {
                case (true, true):   interactive = hasInput && hasOutput
                case (false, true):  interactive = hasOutput
                case (true, false):  interactive = hasInput
                case (false, false): interactive = hasInput || hasOutput
                }

                let tier: DetectionTier?
                if interactive {
                    tier = .interactive
                } else if app.broadcastEligible && hasOutput {
                    tier = .broadcastCandidate
                } else {
                    tier = nil
                }
                if let tier {
                    candidates.append(InCallCandidate(
                        match: MeetingAppMatch(app: app, canonicalBundlePrefix: prefix),
                        tier: tier,
                        hasInput: hasInput,
                        hasOutput: hasOutput
                    ))
                    break  // one match per app is sufficient
                }
            }
        }
        return candidates
    }

    /// Resolves `detectCandidates` output to at most one winner.
    ///
    /// **Conflict resolution:**
    /// - Interactive candidates always outrank broadcast candidates.
    /// - Single survivor → return it.
    /// - Multiple interactive → prefer the sole one with output; still tied →
    ///   `nil` (do not guess).
    /// - Multiple broadcast-only → `nil` (do not guess).
    public static func resolve(_ candidates: [InCallCandidate]) -> InCallCandidate? {
        let interactive = candidates.filter { $0.tier == .interactive }
        if !interactive.isEmpty {
            if interactive.count == 1 { return interactive[0] }
            let withOutput = interactive.filter { $0.hasOutput }
            return withOutput.count == 1 ? withOutput[0] : nil
        }
        let broadcast = candidates.filter { $0.tier == .broadcastCandidate }
        return broadcast.count == 1 ? broadcast[0] : nil
    }

    /// Returns the highest-confidence in-call `MeetingAppMatch`, or `nil` when
    /// no active meeting is detected. Convenience over
    /// `resolve(detectCandidates(…))` — note that a `.broadcastCandidate`
    /// result here is *raw evidence*; the detection policy still applies the
    /// long broadcast debounce and title gate before it becomes a meeting.
    public static func detectInCall(
        processStates: [AudioProcessState],
        confirmedTitles: Set<String> = []
    ) -> MeetingAppMatch? {
        resolve(detectCandidates(processStates: processStates, confirmedTitles: confirmedTitles))?.match
    }

    /// Returns the first known meeting app currently in a call, or `nil`.
    ///
    /// Convenience wrapper around `detectInCall(processStates:confirmedTitles:)`
    /// for callers that only need the `MeetingApp` (not the canonical prefix).
    public static func isInCall(processStates: [AudioProcessState]) -> MeetingApp? {
        detectInCall(processStates: processStates)?.app
    }

    // MARK: - ScreenCaptureKit compatibility shim

    /// Bundle-ID prefixes for Microsoft Teams across its variants.
    ///
    /// This is the single source of truth; `ScreenCaptureKitSource` delegates
    /// to this property rather than maintaining its own list.
    public static var teamsBundleIDHints: [String] {
        apps.first { $0.displayName == "Microsoft Teams" }?.bundlePrefixes ?? []
    }
}
