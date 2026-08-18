import Foundation

/// Pure name-normalization for OCR-derived (or any future signal's) speaker
/// names, applied by a provider **before** constructing a
/// `SpeakerAttributionResult` / recording an `ActiveSpeakerTimeline` interval
/// (DR-4). `TranscriptAttribution.displayName` itself does not normalize —
/// only producers do, per its existing doc comment (Phase 1).
public enum SpeakerNameNormalizer {

    /// Optional roster-snapping tunables (SR-25 hook — unused by any MVP
    /// caller in this repo; wired for a future AX-roster feeder). Deliberately
    /// conservative: this feature's fallback principle is "uncertain
    /// attribution stays `them`", not "guess the closest roster name" — see
    /// the roster-snap rule documented on `normalize(_:roster:rosterConfiguration:)`.
    public struct RosterConfiguration: Sendable, Equatable {
        /// Maximum Levenshtein edit distance (case-insensitive) to snap a
        /// normalized name onto a roster entry's canonical spelling/casing.
        /// This is an upper bound only — the length-aware rule below can
        /// require a *tighter* effective distance for short names; it never
        /// loosens this value.
        public let maxEditDistance: Int
        /// Names shorter than this (after normalization, before snapping)
        /// are never snapped, regardless of `maxEditDistance` — a short OCR
        /// string (e.g. a 2-character fragment) is disproportionately likely
        /// to sit within edit distance 1–2 of an unrelated roster entry by
        /// chance, so snapping it would violate the "no guessing" principle.
        public let minLengthForSnap: Int

        public init(maxEditDistance: Int = 2, minLengthForSnap: Int = 4) {
            self.maxEditDistance = maxEditDistance
            self.minLengthForSnap = minLengthForSnap
        }
        public static let `default` = RosterConfiguration()
    }

    /// Characters known to appear as OCR noise around a name label (bullets,
    /// separators, list markers) and safe to strip only from the **ends** of
    /// the string — never from the interior, so legitimate punctuation inside
    /// a name (`O'Brien`, `Jean-Luc`, `Mary-Jane`) is untouched.
    private static let jitterCharacters = CharacterSet(charactersIn: "•|·-–—:*\u{2022}\u{00B7}")
    private static let teamsRoleMarkers = [
        " (Contractor", " Contractor",
        " (External", " External",
        " (Guest", " Guest"
    ]

    /// Normalizes `raw` into a display-ready name, or `nil` if nothing usable
    /// remains after cleanup (DR-4). Steps, in order:
    /// 1. Trim leading/trailing whitespace/newlines and end-only jitter
    ///    characters (bullets, pipes, dashes, colons, asterisks).
    /// 2. Collapse internal runs of whitespace to a single space.
    /// 3. Expand "Last, First" → natural order via
    ///    `VocabularyStore.naturalOrder(from:)` (reused, not reimplemented).
    /// 4. If `roster` is non-empty **and** the result of steps 1–3 is at least
    ///    `rosterConfiguration.minLengthForSnap` characters, attempt a
    ///    conservative roster snap (case-insensitive Levenshtein, length-aware
    ///    distance cap, unique-closest-match required — ambiguous or
    ///    too-short input is left as the normalized string, never guessed);
    ///    otherwise leave the name as-is (SR-25 — the hook is present but
    ///    never exercised until a roster feeder exists).
    /// 5. Reject (`nil`) if the final string's length is `< 2`.
    ///
    /// **Roster snapping rule** (conservative by construction — this
    /// feature's fallback principle is "stay `them` when unsure", never
    /// guess):
    /// 1. If `roster` is empty, or the normalized name has fewer than
    ///    `rosterConfiguration.minLengthForSnap` characters, skip snapping
    ///    entirely — return the normalized name unchanged.
    /// 2. Otherwise compute the **effective distance cap** as
    ///    `min(rosterConfiguration.maxEditDistance, name.count / 3)` — a
    ///    length-aware cap so a short-but-snap-eligible name still requires a
    ///    proportionally closer match than a long name.
    /// 3. Compute the case-insensitive Levenshtein distance from the
    ///    normalized name to every roster entry; let `minDistance` be the
    ///    smallest.
    /// 4. If `minDistance > effectiveDistanceCap`, no snap.
    /// 5. **Ambiguity check:** if more than one roster entry ties for
    ///    `minDistance`, no snap — a tie means the roster cannot disambiguate
    ///    the OCR'd name, and snapping to whichever happens to appear first
    ///    would be a silent guess, not a resolution.
    /// 6. Otherwise return the single roster entry achieving `minDistance`,
    ///    verbatim (its canonical casing/spelling), not the OCR'd string.
    public static func normalize(
        _ raw: String,
        roster: [String] = [],
        rosterConfiguration: RosterConfiguration = .default
    ) -> String? {
        let jitterAndWhitespace = CharacterSet.whitespacesAndNewlines.union(jitterCharacters)
        // Trimmed twice defensively: a jitter character hiding behind
        // whitespace (e.g. a jitter/whitespace/jitter sandwich) is still
        // removed even though `trimmingCharacters(in:)` already removes runs
        // from both ends in one call.
        var cleaned = raw
            .trimmingCharacters(in: jitterAndWhitespace)
            .trimmingCharacters(in: jitterAndWhitespace)

        // Collapse internal whitespace runs to a single space.
        cleaned = cleaned
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
            .joined(separator: " ")

        guard !cleaned.isEmpty else { return nil }

        for marker in teamsRoleMarkers {
            if let range = cleaned.range(of: marker, options: .caseInsensitive) {
                cleaned.removeSubrange(range.lowerBound...)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard !cleaned.isEmpty else { return nil }

        // "Last, First" → natural order, via the shared VocabularyStore helper.
        let naturalOrdered = VocabularyStore.naturalOrder(from: cleaned)

        let snapped = rosterSnap(
            naturalOrdered,
            roster: roster,
            configuration: rosterConfiguration
        )

        guard snapped.count >= 2 else { return nil }
        return snapped
    }

    // MARK: - Roster snapping

    private static func rosterSnap(
        _ name: String,
        roster: [String],
        configuration: RosterConfiguration
    ) -> String {
        guard !roster.isEmpty, name.count >= configuration.minLengthForSnap else { return name }

        let effectiveDistanceCap = Swift.min(configuration.maxEditDistance, name.count / 3)

        var minDistance = Int.max
        var closest: [String] = []
        for candidate in roster {
            let distance = levenshteinDistance(name.lowercased(), candidate.lowercased())
            if distance < minDistance {
                minDistance = distance
                closest = [candidate]
            } else if distance == minDistance {
                closest.append(candidate)
            }
        }

        guard minDistance <= effectiveDistanceCap else { return name }
        // Ambiguity check: snapping requires a *unique* closest roster entry.
        guard closest.count == 1, let uniqueMatch = closest.first else { return name }
        return uniqueMatch
    }

    /// Standard O(n·m) DP case-insensitive edit distance over `Character`
    /// arrays. Not exposed publicly — an implementation detail of
    /// `normalize`; exercised indirectly via `normalize(_:roster:...)`.
    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var previousRow = Array(0...bChars.count)
        var currentRow = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            currentRow[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                currentRow[j] = Swift.min(
                    previousRow[j] + 1,       // deletion
                    currentRow[j - 1] + 1,    // insertion
                    previousRow[j - 1] + cost // substitution
                )
            }
            previousRow = currentRow
        }
        return previousRow[bChars.count]
    }
}
