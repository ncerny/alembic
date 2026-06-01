import Foundation

/// Loads and normalizes vocabulary hints from multiple sources for on-device
/// speech recognition (`AnalysisContext.contextualStrings`).
///
/// The current model is an ordered list of `VocabularySource`s (see
/// `load(sources:)`). Sources are evaluated **in order**, so earlier sources
/// have higher priority when the combined term count exceeds the limit:
/// - `.word`      — a single literal term
/// - `.file`      — plain-text file (one term per line, `#` comments)
/// - `.directory` — file listing (extension dropped, `_`/`-` → spaces)
///
/// Paths may contain spaces and a leading `~` (expanded via
/// `expandingTildeInPath`). A legacy three-key API (`load(filePath:folderPath:
/// inlineTerms:)`) is retained for backward compatibility.
///
/// Apple recommends keeping `contextualStrings` under ~500 terms for optimal
/// recognition quality; the limit is enforced by truncating lower-priority
/// sources first.
public enum VocabularyStore {

    /// Practical limit Apple recommends for `contextualStrings`.
    public static let recommendedMaxTerms = 500

    /// `UserDefaults` key holding the JSON-encoded `[VocabularySource]` list.
    public static let sourcesDefaultsKey = "alembic.vocabulary.sources"

    // MARK: - Source model

    /// A single user-configured vocabulary source.
    ///
    /// Sources are evaluated **in order**, so the first source has the highest
    /// priority when the combined term count exceeds `recommendedMaxTerms`.
    public struct VocabularySource: Codable, Sendable, Equatable, Identifiable {
        /// How the source's `value` is interpreted.
        public enum Kind: String, Codable, Sendable, CaseIterable {
            /// A single literal term added to the custom library.
            case word
            /// A plain-text file whose contents become vocabulary
            /// (one term per line; lines starting with `#` are comments).
            case file
            /// A directory whose file listing becomes vocabulary
            /// (extension dropped, `_`/`-` replaced with spaces).
            case directory
        }

        public var id: UUID
        public var kind: Kind
        /// A term (for `.word`) or a filesystem path (for `.file`/`.directory`).
        /// Paths may contain spaces and a leading `~`.
        public var value: String

        public init(id: UUID = UUID(), kind: Kind, value: String) {
            self.id = id
            self.kind = kind
            self.value = value
        }
    }

    /// The outcome of loading an ordered list of `VocabularySource`s.
    public struct SourceLoadResult: Sendable {
        /// Deduplicated, normalized terms ready for the speech engine.
        public let terms: [String]
        /// `true` if combined sources exceeded `maxTerms` and were truncated.
        public let truncated: Bool
        /// Unique terms contributed by each input source, aligned by index
        /// (pre-truncation contribution).
        public let perSourceTermCounts: [Int]
    }

    /// The outcome of a vocabulary load, including per-source counts.
    public struct LoadResult: Sendable {
        /// Deduplicated, normalized terms ready for the speech engine.
        public let terms: [String]
        /// Number of unique terms contributed from inline settings.
        public let inlineCount: Int
        /// Number of unique terms contributed from the plain-text file.
        public let fileCount: Int
        /// Number of unique terms contributed from the markdown folder scan.
        public let folderCount: Int
        /// `true` if combined sources exceeded `maxTerms` and were truncated.
        public let truncated: Bool
    }

    /// Loads vocabulary from all configured sources and returns a `LoadResult`.
    ///
    /// Safe to call on any thread (pure file I/O + string manipulation).
    ///
    /// - Parameters:
    ///   - filePath: Path to a plain-text file. One term per line; lines
    ///     starting with `#` are treated as comments.
    ///   - folderPath: Path to a directory. `.md` basenames become vocabulary
    ///     terms; date-prefixed notes and `Archive` sub-folders are excluded.
    ///   - inlineTerms: Explicitly configured terms (highest priority).
    ///   - maxTerms: Upper limit on returned terms.
    public static func load(
        filePath: String?,
        folderPath: String?,
        inlineTerms: [String],
        maxTerms: Int = recommendedMaxTerms
    ) -> LoadResult {
        var seen = Set<String>()
        var terms: [String] = []

        func addTerm(_ raw: String) {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 2 else { return }
            guard seen.insert(s.lowercased()).inserted else { return }
            terms.append(s)
        }

        // 1. Inline terms — never truncated first
        for t in inlineTerms { addTerm(t) }
        let inlineCount = terms.count

        // 2. Plain-text vocabulary file
        for t in loadFromFile(filePath) { addTerm(t) }
        let fileCount = terms.count - inlineCount

        // 3. Markdown folder scan — truncated first if needed
        for t in scanMarkdownFolder(folderPath) { addTerm(t) }
        let rawFolderCount = terms.count - inlineCount - fileCount

        // Enforce limit after all sources are merged so priority is respected.
        let truncated = terms.count > maxTerms
        if truncated {
            terms = Array(terms.prefix(maxTerms))
        }
        let folderCount = max(0, terms.count - inlineCount - fileCount)
        _ = rawFolderCount  // acknowledged — used above for folderCount base

        if truncated {
            print("[alembic] Vocabulary hint count (\(terms.count + (terms.count - maxTerms))) " +
                  "exceeds the recommended limit of \(maxTerms). " +
                  "Lower-priority (folder) terms were dropped first.")
        }

        return LoadResult(
            terms: terms,
            inlineCount: inlineCount,
            fileCount: fileCount,
            folderCount: folderCount,
            truncated: truncated
        )
    }

    // MARK: - Source-based loading

    /// Loads vocabulary from an ordered list of sources and returns a
    /// `SourceLoadResult`. Earlier sources have higher priority when the
    /// combined term count exceeds `maxTerms`.
    ///
    /// Safe to call on any thread (pure file I/O + string manipulation).
    public static func load(
        sources: [VocabularySource],
        maxTerms: Int = recommendedMaxTerms
    ) -> SourceLoadResult {
        var seen = Set<String>()
        var terms: [String] = []
        var perSourceTermCounts = [Int](repeating: 0, count: sources.count)

        func addTerm(_ raw: String) -> Bool {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 2 else { return false }
            guard seen.insert(s.lowercased()).inserted else { return false }
            terms.append(s)
            return true
        }

        for (index, source) in sources.enumerated() {
            let candidates: [String]
            switch source.kind {
            case .word:
                candidates = [source.value]
            case .file:
                candidates = loadFromFile(source.value)
            case .directory:
                candidates = termsFromDirectory(source.value)
            }
            var count = 0
            for candidate in candidates where addTerm(candidate) { count += 1 }
            perSourceTermCounts[index] = count
        }

        let truncated = terms.count > maxTerms
        if truncated {
            terms = Array(terms.prefix(maxTerms))
        }

        return SourceLoadResult(
            terms: terms,
            truncated: truncated,
            perSourceTermCounts: perSourceTermCounts
        )
    }

    // MARK: - Source persistence

    /// Decodes a JSON string (as stored in `UserDefaults`) into sources.
    /// Returns an empty array for empty or malformed input.
    public static func decodeSources(_ json: String) -> [VocabularySource] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([VocabularySource].self, from: data)) ?? []
    }

    /// Encodes sources to a JSON string suitable for `UserDefaults`.
    public static func encodeSources(_ sources: [VocabularySource]) -> String {
        guard let data = try? JSONEncoder().encode(sources),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    /// Builds sources from the legacy single-value settings keys, preserving
    /// priority order (inline words → file → folder).
    public static func migratedSources(
        inline: String?,
        filePath: String?,
        folderPath: String?
    ) -> [VocabularySource] {
        var result: [VocabularySource] = []
        if let inline {
            let words = inline
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for word in words {
                result.append(VocabularySource(kind: .word, value: word))
            }
        }
        if let filePath, !filePath.isEmpty {
            result.append(VocabularySource(kind: .file, value: filePath))
        }
        if let folderPath, !folderPath.isEmpty {
            result.append(VocabularySource(kind: .directory, value: folderPath))
        }
        return result
    }

    /// Resolves the configured sources from `UserDefaults`, falling back to a
    /// one-time migration of the legacy `inline`/`filePath`/`folderPath` keys
    /// when the new sources key has never been written.
    public static func configuredSources(defaults: UserDefaults = .standard) -> [VocabularySource] {
        let json = defaults.string(forKey: sourcesDefaultsKey) ?? ""
        if !json.isEmpty {
            return decodeSources(json)
        }
        return migratedSources(
            inline: defaults.string(forKey: "alembic.vocabulary.inline"),
            filePath: defaults.string(forKey: "alembic.vocabulary.filePath"),
            folderPath: defaults.string(forKey: "alembic.vocabulary.folderPath")
        )
    }

    // MARK: - Private helpers

    private static func loadFromFile(_ path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else { return [] }
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func scanMarkdownFolder(_ path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let datePrefixRE = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}"#)
        var hints: [String] = []

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.lowercased() == "archive" {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            let basename = fileURL.deletingPathExtension().lastPathComponent
            if let re = datePrefixRE,
               !re.matches(in: basename, range: NSRange(basename.startIndex..., in: basename)).isEmpty {
                continue
            }
            hints.append(contentsOf: expandName(basename))
        }

        return hints
    }

    /// Lists the regular files directly inside `path` and converts each filename
    /// into a vocabulary term: the extension is dropped and `_`/`-` characters
    /// are replaced with spaces (collapsing any resulting runs of whitespace).
    private static func termsFromDirectory(_ path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        let url = URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var terms: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }
            let basename = entry.deletingPathExtension().lastPathComponent
            terms.append(normalizeFilename(basename))
        }
        return terms
    }

    /// Replaces `_`/`-` with spaces and collapses runs of whitespace.
    public static func normalizeFilename(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// Expands a note basename into recognition hints.
    ///
    /// - `"Doe, Jane"` → `["Doe", "Jane", "Jane Doe"]`
    /// - `"Jane Doe"` → `["Jane", "Doe", "Jane Doe"]`
    /// - `"Kubernetes"` → `["Kubernetes"]`
    public static func expandName(_ name: String) -> [String] {
        var results: [String] = []

        if name.contains(",") {
            let parts = name
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 2 }
            results.append(contentsOf: parts)
            if parts.count == 2 {
                // Provide "First Last" phrase — contextualStrings works well
                // with full names in natural speech order.
                results.append("\(parts[1]) \(parts[0])")
            }
        } else {
            let parts = name
                .components(separatedBy: .whitespaces)
                .filter { $0.count >= 2 }
            results.append(contentsOf: parts)
            if parts.count >= 2 {
                results.append(name)
            }
        }

        return results
    }
}
