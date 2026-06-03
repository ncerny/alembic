import Foundation
import CoreGraphics
import AppKit

/// Reads open window titles to confirm or disambiguate meeting detections.
///
/// Used by `MeetingDetector` to unlock entries marked
/// `requiresTitleConfirmation: true` (e.g. Google Meet in a browser) and to
/// disambiguate Zoom Settings audio previews from real calls.
///
/// Requires the Screen Recording permission that Alembic already holds for
/// `ScreenCaptureKit`; no additional permission is needed.
public struct WindowTitleProbe: Sendable {

    /// Returns the subset of each app's `titleHints` strings that are
    /// currently present in at least one on-screen window title.
    ///
    /// Only windows belonging to processes in `processStates` are considered,
    /// which limits the search to apps already detected by CoreAudio and
    /// avoids matching unrelated browser tabs.
    public static func presentHints(
        for apps: [MeetingApp],
        processStates: [AudioProcessState]
    ) -> Set<String> {
        let activePIDs = Set(processStates.map { $0.pid })
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var found = Set<String>()
        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  activePIDs.contains(ownerPID),
                  let title = window[kCGWindowName as String] as? String else { continue }
            for app in apps {
                for hint in app.titleHints where title.contains(hint) {
                    found.insert(hint)
                }
            }
        }
        return found
    }

    /// Returns the best window title for the given bundle ID, or `nil` when no
    /// usable title is available.
    ///
    /// Title selection:
    /// 1. Resolves the canonical bundle-ID prefix via `MeetingAppCatalog` so a
    ///    helper bundle (e.g. `com.microsoft.teams2.modulehost`) matches the
    ///    parent process family.
    /// 2. Collects PIDs of all running apps whose bundle ID is the canonical
    ///    prefix or a dot-delimited child of it (covers Electron helper processes
    ///    that often own the titled window).
    /// 3. Finds all on-screen window titles owned by those PIDs.
    /// 4. Delegates ranking to the pure `MeetingContext.bestTitle(from:appHints:)`.
    ///
    /// Uses the Screen Recording permission Alembic already holds; no new
    /// permission is required.
    public static func fullTitle(forBundleID bundleID: String, appHints: [String] = [], exclusions: [String] = []) -> String? {
        var candidatePIDs: Set<Int32> = []

        // If the id is a raw PID reference (e.g. "pid:1234"), use it directly.
        if bundleID.hasPrefix("pid:"), let pid = Int32(bundleID.dropFirst(4)) {
            candidatePIDs.insert(pid)
        } else {
            // Resolve the canonical parent prefix (longest matching prefix) so a
            // helper bundle maps back to the parent app family.
            let canonicalPrefix: String
            if let match = MeetingAppCatalog.match(bundleID: bundleID) {
                canonicalPrefix = match.canonicalBundlePrefix.lowercased()
            } else {
                canonicalPrefix = bundleID.lowercased()
            }

            // Collect PIDs of all running apps in the same family.
            for app in NSWorkspace.shared.runningApplications {
                guard let bid = app.bundleIdentifier else { continue }
                let lowBid = bid.lowercased()
                if lowBid == canonicalPrefix || lowBid.hasPrefix(canonicalPrefix + ".") {
                    candidatePIDs.insert(app.processIdentifier)
                }
            }
        }

        guard !candidatePIDs.isEmpty else { return nil }

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var candidates: [String] = []
        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  candidatePIDs.contains(ownerPID),
                  let title = window[kCGWindowName as String] as? String,
                  !title.isEmpty else { continue }
            candidates.append(title)
        }

        return MeetingContext.bestTitle(from: candidates, appHints: appHints, exclusions: exclusions)
    }
}
