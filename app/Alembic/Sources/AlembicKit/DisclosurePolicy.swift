import Foundation

/// Pure, Foundation-only logic for the optional "meeting is being transcribed"
/// disclosure that Alembic can post into a meeting chat.
///
/// ## Why this lives in the contract layer (Foundation-only)
/// Like `PermissionLogic`, every *decision* here is deterministic and unit
/// tested in `AlembicCheck`: how a configuration + detection becomes a
/// post/stage/skip decision, how the message template is rendered, and what
/// user-facing status each outcome produces. The live Accessibility UI
/// automation that actually inserts the text into Teams lives behind a manual
/// gate in `Platform/macOS/TeamsChatPoster.swift` (it cannot run headlessly and
/// must never import a UI framework here).
///
/// ## Privacy
/// Nothing in this type or its platform companion performs any networking — the
/// disclosure is delivered entirely on-device via local UI automation (or the
/// clipboard fallback), preserving Alembic's no-networking invariant.
public enum DisclosurePolicy {

    /// Default disclosure text. Phrased for a *workplace* context: it states the
    /// transcription is local and not uploaded, frames it as personal notes
    /// (without "personal use only", which can imply stepping outside sanctioned
    /// processes), and invites anyone to object.
    public static let defaultMessage =
        "Heads up — I'm transcribing this locally on my machine for my own "
        + "notes; nothing is uploaded. Let me know if anyone prefers I stop."

    /// Upper bound on the rendered message length. Keeps a pasted/posted line
    /// reasonable and avoids flooding a chat with a runaway template.
    public static let maxMessageLength = 500

    /// Placeholder substituted with the detected meeting title in a template.
    public static let meetingPlaceholder = "{meeting}"

    // MARK: - UserDefaults keys (read by the app layer; centralized here)

    public enum DefaultsKey {
        public static let enabled = "alembic.disclosure.enabled"
        public static let message = "alembic.disclosure.message"
        public static let autoSend = "alembic.disclosure.autoSend"
        public static let teamsOnly = "alembic.disclosure.teamsOnly"
    }

    /// Immutable configuration snapshot, assembled by the app from UserDefaults.
    public struct Config: Sendable, Equatable {
        /// Master switch. When `false`, no disclosure is ever attempted.
        public let enabled: Bool
        /// The message template (may contain ``meetingPlaceholder``).
        public let message: String
        /// When `true`, automatically post into the meeting chat; when `false`,
        /// stage the text to the clipboard for the user to paste manually.
        public let autoSend: Bool
        /// When `true` (default), only act for Microsoft Teams meetings — the
        /// only app whose chat-posting path is supported in v1.
        public let teamsOnly: Bool

        public init(
            enabled: Bool = false,
            message: String = DisclosurePolicy.defaultMessage,
            autoSend: Bool = false,
            teamsOnly: Bool = true
        ) {
            self.enabled = enabled
            self.message = message
            self.autoSend = autoSend
            self.teamsOnly = teamsOnly
        }
    }

    /// What the policy decided to do for a given session start.
    public enum Decision: Sendable, Equatable {
        /// Attempt an automatic post via the platform poster.
        case post
        /// Copy the rendered text to the clipboard and prompt the user to paste.
        case stageToClipboard
        /// Do nothing; `reason` is a short, user-facing explanation.
        case skip(reason: String)
    }

    /// The outcome of an attempted disclosure, surfaced to the UI (never silent).
    public enum Result: Sendable, Equatable {
        case posted
        case stagedToClipboard
        case skipped(reason: String)
        case failed(detail: String)

        /// Short, user-facing status line.
        public var statusMessage: String {
            switch self {
            case .posted:
                return "Posted transcription notice to the meeting chat."
            case .stagedToClipboard:
                return "Transcription notice copied — paste it into the meeting chat."
            case .skipped(let reason):
                return "Transcription notice skipped: \(reason)."
            case .failed(let detail):
                return "Couldn't post the transcription notice (\(detail)). "
                    + "It was copied to the clipboard — paste it into the chat."
            }
        }
    }

    // MARK: - Decision

    /// Decides whether and how to disclose for a session start.
    ///
    /// - Parameters:
    ///   - config: the user's disclosure configuration.
    ///   - isTeams: whether the detected meeting app is Microsoft Teams.
    ///   - alreadyPosted: whether a disclosure was already delivered for the
    ///     current session (the once-per-session guard).
    public static func decide(
        config: Config,
        isTeams: Bool,
        alreadyPosted: Bool
    ) -> Decision {
        guard config.enabled else { return .skip(reason: "disabled in settings") }
        guard !alreadyPosted else { return .skip(reason: "already disclosed this meeting") }
        if config.teamsOnly && !isTeams {
            return .skip(reason: "only supported for Microsoft Teams")
        }
        return config.autoSend ? .post : .stageToClipboard
    }

    // MARK: - Rendering

    /// Renders the final disclosure text from a template.
    ///
    /// - Substitutes ``meetingPlaceholder`` with `meetingTitle` (or removes it
    ///   when no title is available).
    /// - Falls back to ``defaultMessage`` when the template is blank.
    /// - Collapses internal whitespace runs (including newlines) to single
    ///   spaces so the result is a single clean chat line.
    /// - Truncates to ``maxMessageLength`` on a word boundary where possible.
    public static func renderMessage(template: String, meetingTitle: String? = nil) -> String {
        let base = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultMessage
            : template

        let title = (meetingTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let substituted = base.replacingOccurrences(of: meetingPlaceholder, with: title)

        let collapsed = substituted
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return truncate(collapsed, to: maxMessageLength)
    }

    /// Truncates `text` to at most `limit` characters, preferring a word
    /// boundary and appending an ellipsis when truncation occurs.
    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let hardEnd = text.index(text.startIndex, offsetBy: limit)
        let head = text[text.startIndex..<hardEnd]
        if let lastSpace = head.lastIndex(of: " ") {
            return head[head.startIndex..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
        }
        return head + "…"
    }
}
