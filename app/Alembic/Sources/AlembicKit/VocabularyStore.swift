import Foundation

/// Loads and normalizes vocabulary hints from multiple sources for on-device
/// speech recognition (`AnalysisContext.contextualStrings`).
///
/// Sources are merged in **priority order** so explicitly entered terms are
/// never dropped in favour of folder noise:
/// 1. Inline terms (settings text field)
/// 2. Plain-text vocabulary file (one term per line)
/// 3. Markdown folder scan (`.md` basenames, "Last, First" expansion)
///
/// Apple recommends keeping `contextualStrings` under ~500 terms for optimal
/// recognition quality; the limit is enforced by truncating lower-priority
/// sources first.
public enum VocabularyStore {

    /// Practical limit Apple recommends for `contextualStrings`.
    public static let recommendedMaxTerms = 500

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

    // MARK: - Private helpers

    private static func loadFromFile(_ path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func scanMarkdownFolder(_ path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        let rootURL = URL(fileURLWithPath: path)
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
