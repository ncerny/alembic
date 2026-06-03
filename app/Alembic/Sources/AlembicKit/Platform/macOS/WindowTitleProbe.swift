import Foundation
import CoreGraphics

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
}
