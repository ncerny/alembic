import Foundation
import ApplicationServices
import AppKit
import AlembicKit

/// Live diagnostic: `swift run AlembicCheck ax-dump [bundle-prefix] [--out <path>] [--max-visits <n>]`
///
/// Walks the Accessibility tree of every window belonging to the target app
/// family (default: Microsoft Teams) and writes an indented dump of each
/// element's role, subrole, title, description, placeholder, value, and
/// available actions. Run it **during a live Teams meeting with the chat pane
/// open** to re-derive the markers `TeamsChatPoster` needs after a Teams UI
/// update (compose-box placeholder, "Close chat pane" button, chat toggle,
/// etc.).
///
/// Requirements:
/// - The process that runs this (your terminal) must be trusted for
///   Accessibility: System Settings → Privacy & Security → Accessibility.
/// - Expect the sweep itself to briefly stress Teams — it is the same
///   synchronous AX IPC the poster performs; that's fine for a one-off.
enum AXDumpProbe {

    static func run(arguments: [String]) async {
        var bundlePrefix = "com.microsoft.teams"
        var outPath: String?
        var maxVisits = 20_000
        let maxDepth = 100

        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--out":
                outPath = iterator.next()
            case "--max-visits":
                maxVisits = iterator.next().flatMap(Int.init) ?? maxVisits
            default:
                bundlePrefix = arg
            }
        }

        guard AXIsProcessTrusted() else {
            print("""
            ax-dump: this process is not trusted for Accessibility.
            Grant your terminal app access in System Settings → Privacy & Security → Accessibility, then re-run.
            """)
            exit(1)
        }

        let prefix = bundlePrefix.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.lowercased().hasPrefix(prefix) ?? false
        }
        guard !apps.isEmpty else {
            print("ax-dump: no running app matches bundle prefix \"\(bundlePrefix)\"")
            exit(1)
        }

        var out = "ax-dump for \(bundlePrefix) — \(Date())\n"
        var visits = 0

        for app in apps {
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            guard let windows = copyChildren(axApp), !windows.isEmpty else { continue }
            out += "\n=== pid \(pid) (\(app.bundleIdentifier ?? "?")) — \(windows.count) window(s) ===\n"

            for (index, window) in windows.enumerated() {
                let title = stringAttr(window, kAXTitleAttribute as String) ?? "<untitled>"
                out += "\n--- window[\(index)] \"\(title)\" ---\n"
                dump(window, depth: 0, maxDepth: maxDepth, maxVisits: maxVisits, visits: &visits, into: &out)
                if visits >= maxVisits {
                    out += "\n[truncated: reached --max-visits \(maxVisits)]\n"
                    break
                }
            }
            if visits >= maxVisits { break }
        }

        let destination = outPath ?? FileManager.default.currentDirectoryPath + "/alembic-ax-dump.txt"
        do {
            try out.write(toFile: destination, atomically: true, encoding: .utf8)
            print("ax-dump: \(visits) element(s) visited; written to \(destination)")
        } catch {
            print("ax-dump: could not write \(destination): \(error)")
            print(out)
        }
    }

    // MARK: - Tree walk

    private static func dump(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxVisits: Int,
        visits: inout Int,
        into out: inout String
    ) {
        guard visits < maxVisits, depth <= maxDepth else { return }
        visits += 1

        let role = stringAttr(element, kAXRoleAttribute as String) ?? "?"
        var line = String(repeating: "  ", count: depth) + role
        if let subrole = stringAttr(element, kAXSubroleAttribute as String) { line += "/\(subrole)" }
        if let title = stringAttr(element, kAXTitleAttribute as String), !title.isEmpty {
            line += " title=\"\(clip(title))\""
        }
        if let desc = stringAttr(element, kAXDescriptionAttribute as String), !desc.isEmpty {
            line += " desc=\"\(clip(desc))\""
        }
        if let placeholder = stringAttr(element, kAXPlaceholderValueAttribute as String), !placeholder.isEmpty {
            line += " placeholder=\"\(clip(placeholder))\""
        }
        if let value = stringAttr(element, kAXValueAttribute as String), !value.isEmpty {
            line += " value=\"\(clip(value))\""
        }
        if let actions = actionNames(element), !actions.isEmpty {
            line += " actions=[\(actions.joined(separator: ","))]"
        }
        out += line + "\n"

        guard let children = copyChildren(element) else { return }
        for child in children {
            dump(child, depth: depth + 1, maxDepth: maxDepth, maxVisits: maxVisits, visits: &visits, into: &out)
            if visits >= maxVisits { return }
        }
    }

    // MARK: - AX helpers

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func stringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func actionNames(_ element: AXUIElement) -> [String]? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return nil }
        return names as? [String]
    }

    private static func clip(_ s: String, max: Int = 60) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "\\n")
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }
}
