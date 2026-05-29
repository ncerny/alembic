import Foundation

/// Static metadata for the Alembic app.
///
/// Centralized here so the value can be referenced from UI and asserted in
/// tests without instantiating SwiftUI scenes.
public enum AlembicInfo {
    /// Human-readable app name shown in the menu bar.
    public static let displayName = "Alembic"

    /// Bundle identifier; must match `CFBundleIdentifier` in `Info.plist`.
    public static let bundleIdentifier = "com.alembic.app"
}
