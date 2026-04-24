import { type App, TFile, TFolder, normalizePath } from "obsidian";
import type { GraphAttendee } from "./types";

export class PeopleManager {
  private app: App;
  private folderPath: string;

  constructor(app: App, folderPath: string) {
    this.app = app;
    this.folderPath = folderPath;
  }

  /**
   * Ensure people notes exist for all attendees.
   * Returns the list of vault names (for vocabulary hints).
   */
  async ensurePeopleNotes(attendees: GraphAttendee[]): Promise<string[]> {
    await this.ensureFolder();

    const createdNames: string[] = [];

    for (const attendee of attendees) {
      const displayName = attendee.emailAddress.name;
      const email = attendee.emailAddress.address;

      if (!displayName || !email) continue;

      const vaultName = this.toVaultName(displayName);
      if (!vaultName) continue;

      const existing = this.findPersonNote(vaultName, email);
      if (existing) {
        createdNames.push(existing.basename);
        continue;
      }

      // Create a new person note
      const filePath = normalizePath(`${this.folderPath}/${vaultName}.md`);
      const content = this.buildPersonNote(displayName, email);

      try {
        await this.app.vault.create(filePath, content);
        createdNames.push(vaultName);
        console.log(`[alembic] Created person note: ${filePath}`);
      } catch (err) {
        // File may already exist — race condition or naming overlap
        console.warn(`[alembic] Could not create ${filePath}:`, err);
      }
    }

    return createdNames;
  }

  /**
   * Convert "First Last" display name to "Last, First" vault name.
   * Handles multi-part last names and single names.
   */
  toVaultName(displayName: string): string | null {
    const trimmed = displayName.trim();
    if (!trimmed) return null;

    // Already in "Last, First" format
    if (trimmed.includes(",")) return trimmed;

    const parts = trimmed.split(/\s+/);
    if (parts.length === 1) return parts[0];

    // "First Last" → "Last, First"
    const first = parts.slice(0, -1).join(" ");
    const last = parts[parts.length - 1];
    return `${last}, ${first}`;
  }

  /**
   * Find an existing person note by vault name or email.
   */
  private findPersonNote(vaultName: string, email: string): TFile | null {
    const folderPath = normalizePath(this.folderPath);
    const folder = this.app.vault.getAbstractFileByPath(folderPath);
    if (!(folder instanceof TFolder)) return null;

    const target = vaultName.toLowerCase();
    const emailLower = email.toLowerCase();

    for (const child of folder.children) {
      if (!(child instanceof TFile) || child.extension !== "md") continue;

      // Match by basename
      if (child.basename.toLowerCase() === target) return child;

      // Match by email in filename (fallback)
      if (child.basename.toLowerCase().includes(emailLower.split("@")[0])) {
        return child;
      }
    }

    return null;
  }

  private buildPersonNote(displayName: string, email: string): string {
    const parts: string[] = [];
    parts.push("---");
    parts.push("type: person");
    parts.push(`email: "${email}"`);
    parts.push(`aliases: ["${displayName}"]`);
    parts.push("---");
    parts.push("");
    parts.push(`# ${displayName}`);
    parts.push("");
    return parts.join("\n");
  }

  private async ensureFolder(): Promise<void> {
    const folderPath = normalizePath(this.folderPath);
    const existing = this.app.vault.getAbstractFileByPath(folderPath);
    if (!existing) {
      await this.app.vault.createFolder(folderPath);
    }
  }
}
