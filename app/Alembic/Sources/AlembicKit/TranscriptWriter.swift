import Foundation

/// Incremental, crash-safe transcript persistence for a single meeting session.
///
/// ## Responsibilities
/// `TranscriptWriter` owns one **canonical `.jsonl`** file per session and
/// appends exactly one line per **finalized** transcript segment, encoded from
/// the stable `FinalizedSegmentDTO` schema. A `FileHandle` is kept open for the
/// life of the session and flushed (`synchronize()`) after every segment, so a
/// crash mid-meeting still leaves a usable, fully parseable transcript on disk.
///
/// Optionally it also emits a human-readable render (`.md`) alongside the
/// canonical file, with lines of the form `[hh:mm:ss] source: text`.
///
/// ## Canonical schema decision
/// The `.jsonl` is **uniform: one `FinalizedSegmentDTO` per line, nothing else.**
/// We deliberately do *not* write a session header/metadata line into the
/// canonical file. Rationale: every line in the canonical transcript must decode
/// independently as a `FinalizedSegmentDTO`, which makes crash recovery and
/// downstream parsing trivial (read line, decode, done — no special-casing line
/// zero). Session-level metadata (start time, title) is recoverable from the
/// file name (`<yyyy-MM-dd_HHmm>-<meeting>.jsonl`) and surfaced via `outputURL`,
/// and richer headers can live in a sidecar later without breaking the line
/// schema.
///
/// ## Concurrency
/// This is an `actor`: all file mutation is actor-isolated, so the orchestrator
/// may call ``append(_:)-(TranscriptEvent)`` concurrently from any task without
/// data races. Compiles clean under Swift 6 strict concurrency.
///
/// ## Privacy
/// Transcripts are **sensitive at rest**. The resolved on-disk location is
/// surfaced via ``outputURL`` (and ``readableURL``) so the UI/orchestrator can
/// show the user exactly where their meeting is stored.
public actor TranscriptWriter {
    /// Resolved location of the canonical `.jsonl` transcript for this session.
    public nonisolated let outputURL: URL

    /// Resolved location of the optional human-readable `.md` render, or `nil`
    /// when readable rendering is disabled for this session.
    public nonisolated let readableURL: URL?

    private let jsonlHandle: FileHandle
    private let readableHandle: FileHandle?
    private let encoder: JSONEncoder
    private var isClosed = false

    /// Number of finalized segments actually persisted (after volatile/empty
    /// filtering). Useful for assertions and orchestrator bookkeeping.
    public private(set) var segmentCount = 0

    /// The most recent error encountered while writing, if any. Writes never
    /// throw out of ``append(_:)-(FinalizedSegmentDTO)`` so a single bad write
    /// can't tear down a live meeting; inspect this for diagnostics.
    public private(set) var lastWriteError: Error?

    // MARK: - Initialization

    /// Opens (creating as needed) the canonical transcript file for a session.
    ///
    /// - Parameters:
    ///   - meetingName: Human-friendly meeting name; sanitized for the file
    ///     system and embedded in the file name.
    ///   - directory: Output directory. Defaults to `~/Documents/Alembic/`.
    ///     Created if missing.
    ///   - date: Session start used for the `<yyyy-MM-dd_HHmm>` file-name stamp.
    ///     Defaults to now. Injectable for deterministic tests.
    ///   - writeReadableRender: When `true`, also opens a sibling `.md` file and
    ///     mirrors each finalized segment as `[hh:mm:ss] source: text`.
    public init(
        meetingName: String,
        directory: URL? = nil,
        date: Date = Date(),
        writeReadableRender: Bool = false
    ) throws {
        let dir = directory ?? TranscriptWriter.defaultDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = TranscriptWriter.fileBaseName(meetingName: meetingName, date: date)
        let jsonlURL = dir.appendingPathComponent(base + ".jsonl")
        self.outputURL = jsonlURL

        FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
        self.jsonlHandle = try FileHandle(forWritingTo: jsonlURL)

        if writeReadableRender {
            let mdURL = dir.appendingPathComponent(base + ".md")
            self.readableURL = mdURL
            FileManager.default.createFile(atPath: mdURL.path, contents: nil)
            self.readableHandle = try FileHandle(forWritingTo: mdURL)
        } else {
            self.readableURL = nil
            self.readableHandle = nil
        }

        let enc = JSONEncoder()
        // Deterministic key order → stable, diffable, testable output.
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    // MARK: - Appending

    /// Persists a finalized `TranscriptEvent`.
    ///
    /// Volatile events are **never** written to the canonical transcript; they
    /// are silently skipped. Empty/whitespace-only text is also skipped. The
    /// event is converted to the canonical schema via `FinalizedSegmentDTO(event:)`.
    public func append(_ event: TranscriptEvent) {
        guard event.kind == .finalized else { return }
        append(FinalizedSegmentDTO(event: event))
    }

    /// Persists a finalized segment DTO as one canonical JSONL line.
    ///
    /// The line is written as a single `write(contentsOf:)` of the full
    /// `"<json>\n"` payload and then flushed, so a crash can never leave a
    /// half-written line that corrupts earlier, already-flushed segments. Text
    /// is trimmed; empty/whitespace-only segments are skipped.
    public func append(_ dto: FinalizedSegmentDTO) {
        guard !isClosed else { return }

        let trimmed = dto.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Re-stamp with the trimmed text so disk content matches the render.
        let normalized = FinalizedSegmentDTO(
            schemaVersion: dto.schemaVersion,
            start: dto.start,
            end: dto.end,
            source: dto.source,
            text: trimmed,
            attribution: dto.attribution
        )

        do {
            var line = try encoder.encode(normalized)
            line.append(0x0A) // '\n'
            // One atomic write of the complete line, then flush to disk.
            try jsonlHandle.write(contentsOf: line)
            try jsonlHandle.synchronize()

            if let readableHandle {
                let rendered = Data((TranscriptWriter.readableLine(for: normalized) + "\n").utf8)
                try readableHandle.write(contentsOf: rendered)
                try readableHandle.synchronize()
            }

            segmentCount += 1
        } catch {
            lastWriteError = error
        }
    }

    // MARK: - Lifecycle

    /// Flushes and closes all open file handles. Idempotent. After `close()`,
    /// further appends are ignored.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        try? jsonlHandle.synchronize()
        try? jsonlHandle.close()
        try? readableHandle?.synchronize()
        try? readableHandle?.close()
    }

    // MARK: - Path & rendering helpers

    /// Default output directory: `~/Documents/Alembic/`.
    public static var defaultDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("Alembic", isDirectory: true)
    }

    /// Builds `<yyyy-MM-dd_HHmm>-<sanitized-meeting>` (no extension).
    static func fileBaseName(meetingName: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let stamp = formatter.string(from: date)
        let safe = sanitize(meetingName)
        return safe.isEmpty ? stamp : "\(stamp)-\(safe)"
    }

    /// Makes a meeting name safe for use as a single file-name component:
    /// strips path separators and other reserved/troublesome characters and
    /// collapses whitespace runs into single hyphens.
    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Disallow path separators, the NUL, and a few characters that are
        // awkward across file systems. Keep it conservative and portable.
        var forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        forbidden.formUnion(.controlCharacters)
        let cleaned = String(String.UnicodeScalarView(
            trimmed.unicodeScalars.map { forbidden.contains($0) ? " " : $0 }
        ))
        // Collapse internal whitespace into single hyphens.
        let parts = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.joined(separator: "-")
    }

    /// Renders a finalized segment as a human-readable line:
    /// `[hh:mm:ss] source: text`, deriving `hh:mm:ss` from the segment `start`
    /// (session-relative seconds).
    static func readableLine(for dto: FinalizedSegmentDTO) -> String {
        "[\(timestamp(from: dto.start))] \(dto.source.rawValue): \(dto.text)"
    }

    /// Formats session-relative seconds as zero-padded `hh:mm:ss`.
    /// Negative inputs are clamped to zero.
    ///
    /// `public` so the SwiftUI layer (menu + live transcript window) renders the
    /// exact same `hh:mm:ss` stamps as the on-disk readable `.md` render, keeping
    /// a single source of truth for elapsed/segment time formatting.
    public static func timestamp(from seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
