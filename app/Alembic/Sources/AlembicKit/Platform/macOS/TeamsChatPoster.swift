import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

/// Thin wrapper over the Accessibility (AX) trust APIs.
///
/// Accessibility is an **optional** capability for Alembic: it gates the
/// disclosure auto-post only, and must never gate recording. Kept minimal and
/// Apple-isolated here, mirroring `CaptureAuthorization`.
public enum AccessibilityAuthorization {
    /// Whether this process is currently trusted for Accessibility control.
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Prompts the user to grant Accessibility (opens the System Settings pane
    /// indirectly via the system prompt). Returns the post-call trust state.
    @discardableResult
    public static func requestTrust() -> Bool {
        // The CFString constant `kAXTrustedCheckOptionPrompt` is a global `var`
        // and not concurrency-safe to reference; its documented value is stable.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// System Settings deep-link for the Accessibility pane.
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}

/// Posts a disclosure message into the Microsoft Teams **meeting** chat using
/// local Accessibility UI automation — **no networking**, preserving Alembic's
/// privacy invariant.
///
/// ## How it works (validated against new Teams, `com.microsoft.teams2`)
/// 1. Locate the in-meeting chat compose control: an editable `AXTextArea`
///    whose placeholder is "Type a message", **inside a window subtree that also
///    contains the meeting-chat markers** ("Close chat pane" button / "Meeting
///    chat" heading). This disambiguates it from the main hub's 1:1 chat box,
///    which has an identical compose field.
/// 2. Activate Teams, focus the control, and **type the text via synthesized
///    keystrokes**. (Setting `AXValue` directly does not trigger Teams' web
///    input handling, so the Send action stays disabled — typing does.)
/// 3. Verify the value took, then press Return to send.
///
/// > Manual gate: this delivery path depends on the (Electron/WebView) new-Teams
/// > accessibility tree, which Microsoft changes between releases, and cannot run
/// > headlessly. The *decisions* around it (`DisclosurePolicy`) are unit-tested;
/// > this path is validated by hand on a real Teams call. Every failure falls
/// > back to the clipboard so the user can always paste manually.
public struct TeamsChatPoster: Sendable {

    /// Max depth/visits for the bounded AX search, to keep it cheap and bounded
    /// even against a deep Electron WebArea tree.
    private let maxDepth: Int
    private let maxVisits: Int

    /// How many times to re-scan for the meeting chat before giving up. Right
    /// after joining (or while sitting on the "waiting to join" screen), the
    /// meeting window, its "Chat" toggle, and the compose box appear in the AX
    /// tree only after a short, variable delay — so a single scan races the UI.
    private let findAttempts: Int

    /// Delay between find attempts.
    private let findRetryDelay: Duration

    /// Settle wait after text-landed guard, before the first Return press.
    /// Gives Teams' JS time to commit the input and enable Send.
    private let sendSettleDelay: Duration

    /// Bounded number of Return presses before giving up and reporting failure.
    private let sendAttempts: Int

    /// Wait after each Return before reading back the compose box to check if
    /// the message sent.
    private let sendRetryDelay: Duration

    /// Small gap between Return keyDown and keyUp so Teams' web input handler
    /// treats it as a discrete Enter (send) rather than a too-fast event.
    private let returnKeyDownUpGap: Duration

    public init(
        maxDepth: Int = 80,
        maxVisits: Int = 8000,
        findAttempts: Int = 12,
        findRetryDelay: Duration = .milliseconds(1000),
        sendSettleDelay: Duration = .milliseconds(250),
        sendAttempts: Int = 4,
        sendRetryDelay: Duration = .milliseconds(250),
        returnKeyDownUpGap: Duration = .milliseconds(20)
    ) {
        self.maxDepth = maxDepth
        self.maxVisits = maxVisits
        self.findAttempts = max(1, findAttempts)
        self.findRetryDelay = findRetryDelay
        self.sendSettleDelay = sendSettleDelay
        self.sendAttempts = max(1, sendAttempts)
        self.sendRetryDelay = sendRetryDelay
        self.returnKeyDownUpGap = returnKeyDownUpGap
    }

    /// Copies `text` to the general pasteboard. Always-available fallback that
    /// needs no special permission.
    @MainActor
    public static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Attempts to insert and send `text` in the frontmost Teams meeting chat.
    ///
    /// On any failure (no Accessibility grant, Teams not running, meeting chat
    /// pane not open, or injection rejected) the text is copied to the clipboard
    /// and a `.failed` result is returned so the caller can guide a manual paste.
    @MainActor
    public func post(
        _ text: String,
        bundlePrefix: String = "com.microsoft.teams",
        meetingTitle: String? = nil
    ) async -> DisclosurePolicy.Result {
        guard AccessibilityAuthorization.isTrusted() else {
            Self.copyToClipboard(text)
            return .failed(detail: "Accessibility permission not granted")
        }

        let pids = teamsPIDs(bundlePrefix: bundlePrefix)
        guard !pids.isEmpty else {
            Self.copyToClipboard(text)
            return .failed(detail: "Teams is not running")
        }

        // Retry the scan: the meeting window, its "Chat" toggle, and the compose
        // box land in the AX tree only a moment after the call actually connects,
        // and the timing varies (especially if the user lingers on the "waiting
        // to join" screen). Re-resolve PIDs each pass so a late-launched helper
        // process is picked up too.
        var compose: AXUIElement?
        for attempt in 0..<findAttempts {
            let livePids = teamsPIDs(bundlePrefix: bundlePrefix)
            if let found = findMeetingChatComposeBox(in: livePids, meetingTitle: meetingTitle) {
                compose = found
                break
            }
            if attempt < findAttempts - 1 {
                try? await Task.sleep(for: findRetryDelay)
            }
        }
        guard let compose else {
            Self.copyToClipboard(text)
            return .failed(detail: "the meeting chat panel isn't open")
        }
        activateTeams(bundlePrefix: bundlePrefix)
        try? await Task.sleep(nanoseconds: 200_000_000)

        AXUIElementSetAttributeValue(compose, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 120_000_000)

        typeString(text)
        try? await Task.sleep(nanoseconds: 120_000_000)

        // Verify the text actually landed before sending, so we never fire an
        // empty Return into the chat.
        let readback = copyStringAttr(compose, kAXValueAttribute as String) ?? ""
        let probe = String(text.prefix(12))
        guard !probe.isEmpty, readback.contains(probe) else {
            Self.copyToClipboard(text)
            return .failed(detail: "couldn't enter text into the message box")
        }

        // Teams' web UI enables Send slightly after the AX value updates, so a
        // single Return can race ahead and be dropped (leaving the notice typed
        // but unsent). Settle, then press Return and confirm the box emptied;
        // retry a few times.
        try? await Task.sleep(for: sendSettleDelay)

        for _ in 0..<sendAttempts {
            await sendReturnKey()
            try? await Task.sleep(for: sendRetryDelay)
            let after = copyStringAttr(compose, kAXValueAttribute as String) ?? ""
            if !after.contains(probe) {
                return .posted
            }
        }

        // Exhausted: the notice is typed in the box and on the clipboard, but
        // we couldn't confirm it sent. Report honestly so the status line never
        // claims success — the user can press Enter or paste.
        Self.copyToClipboard(text)
        return .failed(detail: "couldn't confirm the notice sent")
    }

    // MARK: - PID / app resolution

    /// PIDs of the Teams app family (parent + Electron helpers). Uses a loose
    /// prefix match so the canonical bundle id `com.microsoft.teams2` (note: no
    /// dot before the `2`) and its helper bundles are all captured.
    private func teamsPIDs(bundlePrefix: String) -> [pid_t] {
        let prefix = bundlePrefix.lowercased()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bid = app.bundleIdentifier?.lowercased(), bid.hasPrefix(prefix) else { return nil }
            return app.processIdentifier
        }
    }

    /// Brings the regular (GUI) Teams application to the front.
    private func activateTeams(bundlePrefix: String) {
        let prefix = bundlePrefix.lowercased()
        let main = NSWorkspace.shared.runningApplications.first { app in
            app.activationPolicy == .regular
                && (app.bundleIdentifier?.lowercased().hasPrefix(prefix) ?? false)
        }
        main?.activate()
    }

    // MARK: - AX tree search

    /// Finds the compose box belonging to the in-meeting chat pane.
    ///
    /// When `meetingTitle` is provided (the title of the meeting Alembic is
    /// transcribing), only the window whose title matches it is considered — so
    /// the message can never land in a different meeting or a hub chat. The chat
    /// pane is opened automatically (pressing the meeting "Chat" toggle) when it
    /// is not already showing.
    private func findMeetingChatComposeBox(in pids: [pid_t], meetingTitle: String?) -> AXUIElement? {
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            let windows = copyChildren(app) ?? []
            let candidates = matchingWindows(windows, meetingTitle: meetingTitle, app: app)

            for window in candidates {
                // Already open?
                if let compose = composeBoxIfMeetingChat(in: window) { return compose }
                // Closed → press the meeting "Chat" toggle in this window, wait,
                // and re-scan.
                if pressChatToggle(in: window) {
                    usleep(600_000)
                    if let compose = composeBoxIfMeetingChat(in: window) { return compose }
                }
            }
        }
        return nil
    }

    /// The windows to consider for a given meeting title, most-specific first.
    ///
    /// - With a title: windows whose AX title matches it (Teams appends
    ///   " | Microsoft Teams", so a prefix/contains match is used).
    /// - Without a title: the focused window first, then the rest.
    private func matchingWindows(
        _ windows: [AXUIElement],
        meetingTitle: String?,
        app: AXUIElement
    ) -> [AXUIElement] {
        let ordered = orderedWindows(app: app, windows: windows)
        guard let title = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return ordered
        }
        let matches = ordered.filter { window in
            guard let wt = copyStringAttr(window, kAXTitleAttribute as String) else { return false }
            return windowTitle(wt, matches: title)
        }
        return matches.isEmpty ? ordered : matches
    }

    /// Whether an AX window title corresponds to the captured meeting title.
    /// Handles Teams' " | Microsoft Teams" suffix and minor whitespace drift.
    private func windowTitle(_ axTitle: String, matches meetingTitle: String) -> Bool {
        let lhs = axTitle.lowercased()
        let rhs = meetingTitle.lowercased()
        return lhs == rhs || lhs.hasPrefix(rhs + " |") || lhs.contains(rhs)
    }

    /// Presses the meeting control-bar "Chat" toggle inside `window` to open the
    /// chat pane. Matches an `AXButton` whose description is exactly "Chat"
    /// (distinct from the hub's "Chat (⌘ 2)" / "Chat with Copilot"). Returns
    /// whether a toggle was pressed.
    @discardableResult
    private func pressChatToggle(in window: AXUIElement) -> Bool {
        guard let toggle = findChatToggle(in: window) else { return false }
        return AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success
    }

    private func findChatToggle(in window: AXUIElement) -> AXUIElement? {
        var visits = 0
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while let (element, depth) = stack.popLast() {
            if visits >= maxVisits { break }
            visits += 1
            if isChatToggle(element) { return element }
            guard depth < maxDepth, let children = copyChildren(element) else { continue }
            for child in children { stack.append((child, depth + 1)) }
        }
        return nil
    }

    private func isChatToggle(_ element: AXUIElement) -> Bool {
        guard copyStringAttr(element, kAXRoleAttribute as String) == (kAXButtonRole as String) else {
            return false
        }
        return copyStringAttr(element, kAXDescriptionAttribute as String)?
            .caseInsensitiveCompare("Chat") == .orderedSame
    }

    /// Returns `windows` with the app's focused window first, if present.
    private func orderedWindows(app: AXUIElement, windows: [AXUIElement]) -> [AXUIElement] {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focusedWindow = focused else {
            return windows
        }
        let fw = unsafeDowncast(focusedWindow as AnyObject, to: AXUIElement.self)
        return [fw] + windows.filter { CFEqual($0, fw) == false }
    }

    /// If `window`'s subtree contains the meeting-chat markers, returns its
    /// compose box; otherwise `nil`.
    private func composeBoxIfMeetingChat(in window: AXUIElement) -> AXUIElement? {
        var visits = 0
        var foundMarker = false
        var compose: AXUIElement?
        var stack: [(AXUIElement, Int)] = [(window, 0)]

        while let (element, depth) = stack.popLast() {
            if visits >= maxVisits { break }
            visits += 1

            if isMeetingChatMarker(element) { foundMarker = true }
            if compose == nil, isComposeBox(element) { compose = element }
            if foundMarker, compose != nil { return compose }

            guard depth < maxDepth, let children = copyChildren(element) else { continue }
            for child in children { stack.append((child, depth + 1)) }
        }
        return foundMarker ? compose : nil
    }

    /// A node that only exists in the in-meeting chat pane.
    private func isMeetingChatMarker(_ element: AXUIElement) -> Bool {
        let role = copyStringAttr(element, kAXRoleAttribute as String)
        let desc = copyStringAttr(element, kAXDescriptionAttribute as String)
        let title = copyStringAttr(element, kAXTitleAttribute as String)
        if role == (kAXButtonRole as String), desc?.caseInsensitiveCompare("Close chat pane") == .orderedSame {
            return true
        }
        if title?.caseInsensitiveCompare("Meeting chat") == .orderedSame { return true }
        return false
    }

    /// Heuristic match for the chat compose control.
    private func isComposeBox(_ element: AXUIElement) -> Bool {
        guard let role = copyStringAttr(element, kAXRoleAttribute as String),
              role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) else {
            return false
        }
        let hints = [
            copyStringAttr(element, kAXPlaceholderValueAttribute as String),
            copyStringAttr(element, kAXDescriptionAttribute as String),
            copyStringAttr(element, kAXTitleAttribute as String),
        ].compactMap { $0?.lowercased() }
        return hints.contains { $0.contains("message") }
    }

    // MARK: - Keystroke synthesis

    /// Types `text` into the focused control via synthesized Unicode key events,
    /// chunked to respect `keyboardSetUnicodeString` length limits.
    private func typeString(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        let chunkSize = 16
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            let chunk = Array(units[index..<end])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.post(tap: .cghidEventTap)
            }
            index = end
        }
    }

    /// Synthesizes a Return key press to send the staged message. The small gap
    /// between key-down and key-up gives Teams' web input handler time to treat
    /// it as a discrete Enter (send) rather than dropping a too-fast event.
    private func sendReturnKey() async {
        let returnKeyCode: CGKeyCode = 36
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(for: returnKeyDownUpGap)
        CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - AX attribute helpers

    private func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func copyStringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
