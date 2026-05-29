import Foundation

/// A capturable application/source the user can select as the "them" side of a
/// session (e.g. a running Microsoft Teams process).
///
/// This is a platform-neutral descriptor: it intentionally avoids any
/// ScreenCaptureKit / AVFoundation types. The macOS implementation (Phase 3)
/// maps `SCRunningApplication` (bundle id, pid, display name, icon) onto this
/// contract; a future Windows source would map its own process model onto the
/// same fields.
///
/// `Sendable` so targets can be enumerated on a background actor and handed to
/// the `@MainActor` UI. `Identifiable`/`Hashable` so SwiftUI lists and pickers
/// can diff and select them.
public struct CaptureTarget: Sendable, Identifiable, Hashable, Codable {
    /// Stable identifier for the target.
    ///
    /// Prefer the application's bundle identifier (e.g.
    /// `"com.microsoft.teams2"`). When no bundle id is available, callers derive
    /// a stable string from the process id (e.g. `"pid:1234"`). Stability across
    /// an enumeration pass is what matters — it keeps SwiftUI selection sane.
    public let id: String

    /// Human-readable name shown in the picker (e.g. `"Microsoft Teams"`).
    public let displayName: String

    /// Optional platform-neutral icon placeholder.
    ///
    /// The contract does not carry an `NSImage`/`CGImage` (those are Apple
    /// types). Instead, implementations may supply raw encoded image bytes
    /// (e.g. PNG data) that the UI layer turns into a platform image, or leave
    /// it `nil`. Kept deliberately minimal for Phase 2.
    public let iconData: Data?

    public init(id: String, displayName: String, iconData: Data? = nil) {
        self.id = id
        self.displayName = displayName
        self.iconData = iconData
    }
}
