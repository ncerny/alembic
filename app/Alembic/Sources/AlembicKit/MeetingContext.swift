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

    /// Picks the best window title from a set of candidates.
    ///
    /// Selection rules (in priority order):
    /// 1. The first candidate whose text contains one of `appHints`.
    /// 2. The longest non-empty candidate.
    /// 3. `nil` when `candidates` is empty or all are empty.
    ///
    /// This function is pure and Foundation-only so it can be exercised by
    /// `AlembicCheck` without a live window server.
    public static func bestTitle(from candidates: [String], appHints: [String] = []) -> String? {
        let nonempty = candidates.filter { !$0.isEmpty }
        guard !nonempty.isEmpty else { return nil }

        if !appHints.isEmpty {
            if let preferred = nonempty.first(where: { c in appHints.contains { c.contains($0) } }) {
                return preferred
            }
        }
        return nonempty.max(by: { $0.count < $1.count })
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
