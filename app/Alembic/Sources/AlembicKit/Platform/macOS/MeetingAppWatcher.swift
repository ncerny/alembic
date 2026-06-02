import Foundation
import AppKit

/// Tracks which known meeting apps are currently running via NSWorkspace
/// launch/terminate notifications.
///
/// This is contextual information for `MeetingDetector` — it is **not** a
/// call signal by itself. Knowing that Teams is running avoids wasting a full
/// `AudioProcessMonitor.snapshot()` when no meeting app is even open.
///
/// Thread-safe via `NSLock`; `@unchecked Sendable` because the lock guards
/// all mutable state.
public final class MeetingAppWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var _present: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    /// The canonical bundle prefixes of meeting apps currently running.
    public var present: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _present
    }

    public init() {
        let initial = Self.prefixes(from: NSWorkspace.shared.runningApplications)
        lock.lock(); _present = initial; lock.unlock()

        let nc = NSWorkspace.shared.notificationCenter
        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            self?.handleLaunch(notification)
        }
        let terminateObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            self?.handleTerminate(notification)
        }
        observers = [launchObs, terminateObs]
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
    }

    // MARK: - Handlers

    private func handleLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bid = app.bundleIdentifier,
              let match = MeetingAppCatalog.match(bundleID: bid) else { return }
        lock.lock(); _present.insert(match.canonicalBundlePrefix); lock.unlock()
    }

    private func handleTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bid = app.bundleIdentifier,
              let match = MeetingAppCatalog.match(bundleID: bid) else { return }
        lock.lock(); _present.remove(match.canonicalBundlePrefix); lock.unlock()
    }

    // MARK: - Helpers

    private static func prefixes(from apps: [NSRunningApplication]) -> Set<String> {
        var result = Set<String>()
        for app in apps {
            guard let bid = app.bundleIdentifier,
                  let match = MeetingAppCatalog.match(bundleID: bid) else { continue }
            result.insert(match.canonicalBundlePrefix)
        }
        return result
    }
}
