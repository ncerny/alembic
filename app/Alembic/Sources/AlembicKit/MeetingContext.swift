import Foundation

/// Session-level metadata assembled at start time and used for transcript
/// file naming and the human-readable `.md` frontmatter block.
///
/// All properties are optional except `startDate`; callers omit fields they
/// cannot populate rather than passing empty strings.
///
/// Foundation-only: no Apple platform framework imports, fully testable under
/// Command Line Tools via `AlembicCheck`.
public struct MeetingContext: Sendable {
    public let windowTitle: String?
    public let appDisplayName: String?
    public let bundleID: String?
    public let localeIdentifier: String?
    public let startDate: Date
    /// Ordered extra key-value pairs for future fields (attendees, URL, etc.)
    /// without requiring a schema change to `TranscriptWriter` or the writer init.
    public let extra: [(String, String)]

    public init(
        windowTitle: String? = nil,
        appDisplayName: String? = nil,
        bundleID: String? = nil,
        localeIdentifier: String? = nil,
        startDate: Date = Date(),
        extra: [(String, String)] = []
    ) {
        self.windowTitle = windowTitle
        self.appDisplayName = appDisplayName
        self.bundleID = bundleID
        self.localeIdentifier = localeIdentifier
        self.startDate = startDate
        self.extra = extra
    }

    // MARK: - File naming

    /// The name component used in the transcript file name.
    /// Fallback chain: `windowTitle` → `appDisplayName` → `""`.
    /// An empty result lets `TranscriptWriter.fileBaseName` fall back to the bare timestamp.
    public var nameForFile: String {
        windowTitle ?? appDisplayName ?? ""
    }

    // MARK: - YAML frontmatter

    /// Generates a YAML frontmatter block (`---\n…\n---\n`) for the `.md` render.
    ///
    /// Nil/empty fields are omitted. All scalar values are double-quoted with
    /// full escape handling to neutralise hostile window titles (newlines, `---`,
    /// `:`, `#`, quotes, backslashes, emoji, other control characters).
    /// Extra keys are also quoted to prevent key injection.
    public func yamlFrontmatter() -> String {
        var lines: [String] = ["---"]

        if let title = windowTitle, !title.isEmpty {
            lines.append("title: \(MeetingContext.yamlQuote(title))")
        }
        if let app = appDisplayName, !app.isEmpty {
            lines.append("app: \(MeetingContext.yamlQuote(app))")
        }
        if let bid = bundleID, !bid.isEmpty {
            lines.append("bundleID: \(MeetingContext.yamlQuote(bid))")
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        lines.append("startTime: \(MeetingContext.yamlQuote(isoFormatter.string(from: startDate)))")

        if let locale = localeIdentifier, !locale.isEmpty {
            lines.append("locale: \(MeetingContext.yamlQuote(locale))")
        }
        for (key, value) in extra {
            lines.append("\(MeetingContext.yamlQuote(key)): \(MeetingContext.yamlQuote(value))")
        }

        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Title selection (pure, CLT-testable)

    /// Strips a known app-name suffix from a window title.
    ///
    /// Many Electron apps (Teams, Slack) append the app name to every window
    /// title — e.g. `"Standup | Microsoft Teams"`. Stripping it produces a clean
    /// meeting name for transcript file names and YAML frontmatter.
    ///
    /// Only the first matching suffix in `strips` is removed. If the result
    /// would be empty the original title is returned unchanged.
    public static func applyTrailingStrips(to title: String, strips: [String]) -> String {
        for strip in strips {
            if title.hasSuffix(strip) {
                let stripped = title.dropLast(strip.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? title : stripped
            }
        }
        return title
    }

    /// Strips known leading chrome from a window title — e.g. Teams' pre-join
    /// lobby `"Meeting join | Standup | Microsoft Teams"` → `"Standup | Microsoft
    /// Teams"` — so the lobby and the joined meeting window name the same
    /// meeting. Mirrors `applyTrailingStrips`: only the first matching prefix
    /// is removed, and a strip that would leave an empty title is skipped.
    public static func applyLeadingStrips(to title: String, strips: [String]) -> String {
        for strip in strips {
            if title.hasPrefix(strip) {
                let stripped = title.dropFirst(strip.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? title : stripped
            }
        }
        return title
    }

    /// `true` when the title's leading ` | ` segment is a bare URL or
    /// host/path (e.g. `"teams.microsoft.com/v2/"`, a transient webview title
    /// shown while a call is being set up). Such a title is never a meeting
    /// name, so `bestTitle` treats it as excluded for every app.
    ///
    /// Requires no whitespace and either a URL scheme separator or a dotted
    /// hostname followed by a `/` path, so ordinary meeting subjects
    /// (which contain spaces) and bare dotted words never match.
    public static func isURLLikeTitle(_ title: String) -> Bool {
        let leading = leadingSegment(of: title)
        guard !leading.isEmpty, !leading.contains(where: \.isWhitespace) else { return false }
        if leading.contains("://") { return true }
        guard let slash = leading.firstIndex(of: "/") else { return false }
        let labels = leading[..<slash].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    /// Every candidate that qualifies as a meeting window under the strict
    /// (detection) rules — non-empty, leading segment not in `exclusions`, not
    /// URL-like — normalized to the meeting-name form `meetingWindowTitle`
    /// produces (leading chrome stripped, then the trailing app suffix).
    /// Order-preserving and de-duplicated.
    ///
    /// The detector uses this over *all* of an app's windows (including
    /// minimized and other-Space ones) to ask "does the latched meeting window
    /// still exist?", which is what gates a back-to-back split.
    public static func normalizedMeetingTitles(
        from candidates: [String],
        exclusions: [String],
        leadingStrips: [String],
        trailingStrips: [String]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in candidates {
            let candidate = applyLeadingStrips(to: raw, strips: leadingStrips)
            guard !candidate.isEmpty, !isExcluded(candidate, exclusions: exclusions) else { continue }
            let name = applyTrailingStrips(to: candidate, strips: trailingStrips)
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    /// The trimmed first ` | `-delimited segment of a window title.
    private static func leadingSegment(of title: String) -> String {
        title.components(separatedBy: " | ")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? title
    }

    /// Whether a candidate is a non-meeting window: its leading segment is a
    /// catalogued exclusion, or it is URL-like chrome.
    private static func isExcluded(_ candidate: String, exclusions: [String]) -> Bool {
        exclusions.contains(leadingSegment(of: candidate)) || isURLLikeTitle(candidate)
    }

    /// Picks the best window title from a set of candidates.
    ///
    /// Selection rules (in priority order):
    /// 1. Drop any candidate whose leading ` | `-delimited segment (trimmed)
    ///    exactly matches an entry in `exclusions` (e.g. Teams hub sections
    ///    like "Chat" or "Calendar"), or that is URL-like chrome
    ///    (`isURLLikeTitle`). When `exclusionFallback` is `true`
    ///    (default) and every non-empty candidate is excluded, the exclusion
    ///    step is skipped and the full non-empty set is used so a title is
    ///    never lost. When `false`, all-excluded returns `nil` — the strict
    ///    mode detection uses to ask "does a real meeting window exist?".
    /// 2. The first remaining candidate whose text contains one of `appHints`.
    /// 3. When `preferFrontmost` is `true`, the first remaining candidate
    ///    (callers pass candidates in front-to-back z-order, so this is the
    ///    frontmost window); otherwise the longest remaining candidate.
    /// 4. `nil` when `candidates` is empty or all are empty.
    ///
    /// `preferFrontmost` exists because a verbose hub page (e.g. a calendar
    /// event detail page left open behind the call) can be *longer* than the
    /// real meeting window's title. During a live meeting the meeting window is
    /// frontmost, so taking the frontmost qualifying window picks the real
    /// meeting name instead of the longest stray hub title.
    ///
    /// This function is pure and Foundation-only so it can be exercised by
    /// `AlembicCheck` without a live window server.
    public static func bestTitle(
        from candidates: [String],
        appHints: [String] = [],
        exclusions: [String] = [],
        preferFrontmost: Bool = false,
        exclusionFallback: Bool = true
    ) -> String? {
        let nonempty = candidates.filter { !$0.isEmpty }
        guard !nonempty.isEmpty else { return nil }

        let filtered = nonempty.filter { !isExcluded($0, exclusions: exclusions) }
        let pool: [String]
        if filtered.isEmpty {
            // Naming mode falls back so a title is never lost; strict
            // (detection) mode reports that no meeting window exists.
            guard exclusionFallback else { return nil }
            pool = nonempty
        } else {
            pool = filtered
        }

        if !appHints.isEmpty {
            if let preferred = pool.first(where: { c in appHints.contains { c.contains($0) } }) {
                return preferred
            }
        }
        if preferFrontmost {
            return pool.first
        }
        return pool.max(by: { $0.count < $1.count })
    }

    // MARK: - YAML scalar escaping

    /// Wraps a string in YAML double-quoted scalar syntax, escaping backslashes,
    /// double-quotes, and all C0 + DEL control characters.
    ///
    /// The resulting string is safe to embed as a YAML value or key regardless
    /// of content (newlines, `---`, `#`, `:`, emoji, arbitrary Unicode).
    public static func yamlQuote(_ raw: String) -> String {
        var result = "\""
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x5C: result += "\\\\"         // backslash → \\
            case 0x22: result += "\\\""          // double-quote → \"
            case 0x0A: result += "\\n"           // newline
            case 0x0D: result += "\\r"           // carriage return
            case 0x09: result += "\\t"           // tab
            case 0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result += String(scalar)
            }
        }
        result += "\""
        return result
    }
}
