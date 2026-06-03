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

    public init(
        displayName: String,
        bundlePrefixes: [String],
        requiresOutput: Bool = false,
        requiresTitleConfirmation: Bool = false,
        titleHints: [String] = []
    ) {
        self.displayName = displayName
        self.bundlePrefixes = bundlePrefixes
        self.requiresOutput = requiresOutput
        self.requiresTitleConfirmation = requiresTitleConfirmation
        self.titleHints = titleHints
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
            ]
        ),
        MeetingApp(
            displayName: "Zoom",
            bundlePrefixes: ["us.zoom.xos"],
            requiresOutput: true,    // Zoom holds the mic during Settings → Audio preview
            titleHints: ["Zoom Meeting"]
        ),
        MeetingApp(
            displayName: "Slack",
            bundlePrefixes: ["com.tinyspeck.slackmacgap"]
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

    /// Returns the highest-confidence in-call `MeetingAppMatch`, or `nil` when
    /// no active meeting is detected.
    ///
    /// **Caller responsibility:** the `processStates` array must already
    /// exclude Alembic's own PID.
    ///
    /// Rules per app per prefix:
    /// - `requiresTitleConfirmation: true` → skipped unless `confirmedTitles`
    ///   contains an overlapping `titleHints` substring.
    /// - `requiresOutput: true` → at least one matching process must have
    ///   `isRunningOutput == true` (Zoom mic-preview guard).
    /// - Default OR gate → `isRunningInput || isRunningOutput`.
    ///
    /// **Conflict resolution** (multiple apps in-call simultaneously):
    /// - Single match → return it.
    /// - Multiple matches → prefer the one with `isRunningOutput`; if still
    ///   tied, return `nil` (do not guess).
    ///
    /// The `canonicalBundlePrefix` of the returned `MeetingAppMatch` is always
    /// a prefix from the matched app's own `bundlePrefixes` list and is
    /// suitable for resolving to a `CaptureTarget` via ScreenCaptureKit.
    public static func detectInCall(
        processStates: [AudioProcessState],
        confirmedTitles: Set<String> = []
    ) -> MeetingAppMatch? {
        struct Candidate {
            let app: MeetingApp
            let canonicalBundlePrefix: String
            let hasOutput: Bool
        }

        var candidates: [Candidate] = []

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
                let hasOutput = relevant.contains { $0.isRunningOutput }
                let inCall: Bool
                if app.requiresOutput {
                    inCall = hasOutput
                } else {
                    inCall = relevant.contains { $0.isRunningInput || $0.isRunningOutput }
                }
                if inCall {
                    candidates.append(Candidate(app: app, canonicalBundlePrefix: prefix, hasOutput: hasOutput))
                    break  // one match per app is sufficient
                }
            }
        }

        switch candidates.count {
        case 0:
            return nil
        case 1:
            return MeetingAppMatch(app: candidates[0].app, canonicalBundlePrefix: candidates[0].canonicalBundlePrefix)
        default:
            let withOutput = candidates.filter { $0.hasOutput }
            guard withOutput.count == 1 else { return nil }
            return MeetingAppMatch(app: withOutput[0].app, canonicalBundlePrefix: withOutput[0].canonicalBundlePrefix)
        }
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
