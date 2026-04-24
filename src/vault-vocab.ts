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
 * Extracts individual words from vault names for speech recognition hints.
 * "Doe, Jane" → ["Doe", "Jane"]
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
