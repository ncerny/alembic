import { type App, TFolder, TFile } from "obsidian";

const DATE_PREFIX_RE = /^\d{4}-\d{2}-\d{2}/;
const MAX_RECOMMENDED_HINTS = 500;

/**
 * Scans the entire vault recursively and returns note basenames as vocabulary,
 * excluding date-prefixed notes and anything under "Archive" folders.
 */
export function getVaultVocabulary(app: App): string[] {
  const names: string[] = [];

  function scanFolder(folder: TFolder) {
    for (const child of folder.children) {
      if (child instanceof TFolder) {
        if (child.name.toLowerCase() === "archive") continue;
        scanFolder(child);
      } else if (child instanceof TFile && child.extension === "md") {
        if (DATE_PREFIX_RE.test(child.basename)) continue;
        names.push(child.basename);
      }
    }
  }

  const root = app.vault.getRoot();
  scanFolder(root);

  if (names.length > MAX_RECOMMENDED_HINTS) {
    console.warn(
      `[alembic] ${names.length} vocabulary terms from vault — ` +
      `Apple recommends <${MAX_RECOMMENDED_HINTS} for optimal speech recognition. ` +
      `Consider archiving unused notes.`,
    );
  }

  return names;
}

/**
 * Extracts vocabulary hints from vault names for speech recognition.
 * Includes both individual words AND full name phrases for better recognition.
 * "Doe, Jane" → ["Doe", "Jane", "Jane Doe"]
 * "Kubernetes" → ["Kubernetes"]
 * Deduplicates and filters short words.
 */
export function vocabToRecognitionHints(
  vaultNames: string[],
  manualHints: string[],
): string[] {
  const hints = new Set<string>();

  for (const hint of manualHints) {
    if (hint.length >= 2) hints.add(hint);
  }

  for (const name of vaultNames) {
    // Split on comma, space, or both — extract individual name parts
    const parts = name.split(/[,\s]+/).filter((p) => p.length >= 2);
    for (const part of parts) {
      hints.add(part);
    }

    // For "Last, First" names, also include "First Last" as a phrase —
    // contextualStrings works better with full phrases than isolated words
    if (name.includes(",")) {
      const commaParts = name.split(/,\s*/);
      if (commaParts.length === 2) {
        const [last, first] = commaParts;
        if (first.length >= 2 && last.length >= 2) {
          hints.add(`${first} ${last}`);
        }
      }
    }
  }

  return [...hints];
}

/**
 * Replaces mentions of known names in text with [[wikilinks]].
 * For "Last, First" names, matches either "First Last" or "First" or "Last"
 * (first name alone if unique enough). Links to the full vault note name.
 */
export function insertWikilinks(text: string, knownNames: string[]): string {
  if (knownNames.length === 0) return text;

  let result = text;

  // First pass: match "First Last" patterns → link to "Last, First"
  const lastFirstNames = knownNames.filter((n) => n.includes(","));
  for (const fullName of lastFirstNames) {
    const parts = fullName.split(/,\s*/);
    if (parts.length === 2) {
      const [last, first] = parts;
      // Match "First Last" (natural speech order)
      const escaped = `${first.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s+${last.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`;
      const pattern = new RegExp(
        `(?<!\\[\\[)\\b(${escaped})\\b(?!\\]\\])`,
        "gi",
      );
      result = result.replace(pattern, `[[${fullName}]]`);
    }
  }

  // Second pass: match individual names — sort longest first
  const sorted = [...knownNames].sort((a, b) => b.length - a.length);

  for (const name of sorted) {
    // For "Last, First" names, try matching just the first name
    if (name.includes(",")) {
      const parts = name.split(/,\s*/);
      if (parts.length === 2) {
        const [last, first] = parts;
        // Match first name alone (min 3 chars to avoid false positives)
        for (const part of [first, last]) {
          if (part.length >= 3) {
            const escaped = part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
            const pattern = new RegExp(
              `(?<!\\[\\[)(?<!\\[\\[[^\\]]*?)\\b(${escaped})\\b(?![^\\[]*?\\]\\])`,
              "gi",
            );
            result = result.replace(pattern, `[[${name}|${part}]]`);
          }
        }
      }
    } else {
      // Simple name — direct match
      const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const pattern = new RegExp(
        `(?<!\\[\\[)(?<!\\[\\[[^\\]]*?)\\b(${escaped})\\b(?![^\\[]*?\\]\\])`,
        "gi",
      );
      result = result.replace(pattern, `[[${name}]]`);
    }
  }

  return result;
}

/**
 * Phonetically normalize a string for comparison.
 * Collapses sounds that SFSpeechRecognizer commonly confuses.
 */
function phoneticNormalize(s: string): string {
  return s
    .toLowerCase()
    .replace(/^c(?=[aeiouklr])/g, "k")  // hard C → K (Smith → Koty)
    .replace(/ce|ci/g, "se")             // soft C → S
    .replace(/ph/g, "f")
    .replace(/ck/g, "k")
    .replace(/ght/g, "t")
    .replace(/gh(?=[^aeiou]|$)/g, "")    // silent gh
    .replace(/([aeiou])\1+/g, "$1")      // collapse double vowels
    .replace(/z/g, "s")
    .replace(/y$/g, "i");                // trailing y → i (Johnny/Adli)
}

/**
 * Simple Levenshtein distance between two strings.
 */
function levenshtein(a: string, b: string): number {
  const m = a.length;
  const n = b.length;
  const dp: number[][] = Array.from({ length: m + 1 }, () =>
    Array(n + 1).fill(0),
  );

  for (let i = 0; i <= m; i++) dp[i][0] = i;
  for (let j = 0; j <= n; j++) dp[0][j] = j;

  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      dp[i][j] = Math.min(
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + cost,
      );
    }
  }

  return dp[m][n];
}

/**
 * Extract consonant skeleton of a word (drops vowels).
 * Useful for catching truncated names: "Jane" → "dlz", "Johnny" → "dl"
 */
function consonantSkeleton(s: string): string {
  return s.toLowerCase().replace(/[aeiou]/g, "");
}

/**
 * Extracts unique name parts (first names, last names) from vault names.
 * Returns a map of lowercase name → original casing.
 */
function buildNameMap(knownNames: string[]): Map<string, string> {
  const nameMap = new Map<string, string>();

  for (const name of knownNames) {
    if (name.includes(",")) {
      const parts = name.split(/,\s*/);
      if (parts.length === 2) {
        const [last, first] = parts;
        if (first.length >= 3) nameMap.set(first.toLowerCase(), first);
        if (last.length >= 3) nameMap.set(last.toLowerCase(), last);
      }
    } else {
      const parts = name.split(/\s+/).filter((p) => p.length >= 3);
      for (const part of parts) {
        nameMap.set(part.toLowerCase(), part);
      }
    }
  }

  return nameMap;
}

/**
 * Corrects misheard names in transcript text using fuzzy matching against
 * known vault names. Uses phonetic normalization + Levenshtein distance.
 *
 * Example: "Smith mentioned the deployment" → "Schmidt mentioned the deployment"
 * (when "Schmidt" is a known vault name)
 */
export function correctTranscriptNames(
  text: string,
  knownNames: string[],
): string {
  if (knownNames.length === 0) return text;

  const nameMap = buildNameMap(knownNames);
  if (nameMap.size === 0) return text;

  // Build phonetic versions of known names for faster comparison
  const phoneticNames = new Map<string, { original: string; phonetic: string; skeleton: string }>();
  for (const [lower, original] of nameMap) {
    phoneticNames.set(lower, {
      original,
      phonetic: phoneticNormalize(lower),
      skeleton: consonantSkeleton(lower),
    });
  }

  // Match whole words that might be misheard names (capitalized, 3+ chars)
  return text.replace(/\b[A-Z][a-z]{2,}\b/g, (word) => {
    const wordLower = word.toLowerCase();

    // Skip if it's already an exact match for a known name
    if (nameMap.has(wordLower)) return nameMap.get(wordLower)!;

    const wordPhonetic = phoneticNormalize(wordLower);
    const wordSkeleton = consonantSkeleton(wordLower);

    let bestMatch: string | null = null;
    let bestScore = Infinity;

    for (const [, { original, phonetic, skeleton }] of phoneticNames) {
      const maxLen = Math.max(wordLower.length, original.length);

      // Skip if lengths are too different (> 40% difference)
      if (Math.abs(wordLower.length - original.length) > maxLen * 0.4) {
        continue;
      }

      // Primary: phonetic edit distance (normalized by max length)
      const dist = levenshtein(wordPhonetic, phonetic);
      const normalizedDist = dist / Math.max(wordPhonetic.length, phonetic.length);

      // Match if normalized distance ≤ 0.45 (about 2 edits per 5 chars)
      if (normalizedDist <= 0.45 && dist < bestScore) {
        bestScore = dist;
        bestMatch = original;
        continue;
      }

      // Fallback: consonant skeleton match for truncated names
      // "Johnny" skeleton "dl" vs "Jane" skeleton "dlz" — distance 1
      // Require first letter to match to avoid false positives (e.g., "Daily" → "Jane")
      if (wordSkeleton.length >= 2 && skeleton.length >= 2 &&
          wordLower[0] === original.toLowerCase()[0]) {
        const skelDist = levenshtein(wordSkeleton, skeleton);
        const skelNorm = skelDist / Math.max(wordSkeleton.length, skeleton.length);
        if (skelNorm <= 0.35 && skelDist < bestScore) {
          bestScore = skelDist;
          bestMatch = original;
        }
      }
    }

    if (bestMatch) {
      console.log(`[alembic] Name correction: "${word}" → "${bestMatch}" (distance: ${bestScore})`);
      return bestMatch;
    }

    return word;
  });
}
