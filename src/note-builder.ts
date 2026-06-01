import { type App, TFolder, normalizePath } from "obsidian";
import { formatTranscriptLines } from "./transcript-format";
import { insertWikilinks } from "./vault-vocab";
import type { MeetingData } from "./types";

export class NoteBuilder {
  private app: App;
  private outputFolder: string;
  private knownNames: string[];

  constructor(app: App, outputFolder: string, knownNames: string[] = []) {
    this.app = app;
    this.outputFolder = outputFolder;
    this.knownNames = knownNames;
  }

  async createMeetingNote(data: MeetingData): Promise<string> {
    await this.ensureFolder();

    const fileName = this.generateFileName(data);
    const content = this.buildNoteContent(data);
    const filePath = normalizePath(`${this.outputFolder}/${fileName}`);

    // Handle duplicate names
    const finalPath = await this.getUniquePath(filePath);

    const file = await this.app.vault.create(finalPath, content);

    // Open the note
    const leaf = this.app.workspace.getLeaf(false);
    await leaf.openFile(file);

    return finalPath;
  }

  private generateFileName(data: MeetingData): string {
    const title = data.summary?.title || data.title || "Meeting";
    const safeTitle = title.replace(/[\\/:*?"<>|]/g, "-").slice(0, 80);
    return `${data.date} ${safeTitle}.md`;
  }

  private buildNoteContent(data: MeetingData): string {
    const summary = data.summary;
    const parts: string[] = [];
    const link = (text: string) => insertWikilinks(text, this.knownNames);

    // Frontmatter
    parts.push("---");
    parts.push("type: meeting");
    parts.push(`date: ${data.date}`);
    parts.push(`title: "${(summary?.title || data.title).replace(/"/g, '\\"')}"`);

    if (summary?.attendees && summary.attendees.length > 0) {
      parts.push("attendees:");
      for (const a of summary.attendees) {
        parts.push(`  - "[[${a}]]"`);
      }
    }

    if (summary?.keyTopics && summary.keyTopics.length > 0) {
      parts.push(`tags: [meeting, ${summary.keyTopics.map((t) => t.toLowerCase().replace(/\s+/g, "-")).join(", ")}]`);
    } else {
      parts.push("tags: [meeting]");
    }

    parts.push(`duration: ${this.formatDurationHuman(data.recordingDuration)}`);
    parts.push("---");
    parts.push("");

    // Title
    parts.push(`# ${summary?.title || data.title}`);
    parts.push("");

    // Summary — insert wikilinks for known names
    if (summary?.summary) {
      parts.push("## Summary");
      parts.push("");
      parts.push(link(summary.summary));
      parts.push("");
    }

    // Key Decisions
    if (summary?.keyDecisions && summary.keyDecisions.length > 0) {
      parts.push("## Key Decisions");
      parts.push("");
      for (const d of summary.keyDecisions) {
        parts.push(`- ${link(d)}`);
      }
      parts.push("");
    }

    // Action Items
    if (summary?.actionItems && summary.actionItems.length > 0) {
      parts.push("## Action Items");
      parts.push("");
      for (const item of summary.actionItems) {
        const due = item.due ? ` (due: ${item.due})` : "";
        const assignee = item.assignee ? `[[${item.assignee}]]: ` : "";
        parts.push(`- [ ] ${assignee}${link(item.task)}${due}`);
      }
      parts.push("");
    }

    // User's notes
    if (data.userNotes.trim()) {
      parts.push("## My Notes");
      parts.push("");
      parts.push(data.userNotes);
      parts.push("");
    }

    // Transcript — insert wikilinks
    if (data.transcript.length > 0) {
      parts.push("## Transcript");
      parts.push("");
      parts.push("<details>");
      parts.push("<summary>Full transcript (click to expand)</summary>");
      parts.push("");
      for (const line of formatTranscriptLines(data.transcript)) {
        parts.push(link(line));
      }
      parts.push("");
      parts.push("</details>");
    }

    return parts.join("\n");
  }

  private async ensureFolder(): Promise<void> {
    const folderPath = normalizePath(this.outputFolder);
    const existing = this.app.vault.getAbstractFileByPath(folderPath);
    if (!existing) {
      await this.app.vault.createFolder(folderPath);
    }
  }

  private async getUniquePath(basePath: string): Promise<string> {
    let path = basePath;
    let counter = 1;

    while (this.app.vault.getAbstractFileByPath(path)) {
      const ext = basePath.slice(basePath.lastIndexOf("."));
      const name = basePath.slice(0, basePath.lastIndexOf("."));
      path = `${name} (${counter})${ext}`;
      counter++;
    }

    return path;
  }

  private formatDurationHuman(seconds: number): string {
    const m = Math.floor(seconds / 60);
    if (m < 60) return `${m}min`;
    const h = Math.floor(m / 60);
    const remainMin = m % 60;
    return `${h}h ${remainMin}min`;
  }
}
