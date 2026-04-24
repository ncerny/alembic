import { Notice, Plugin, WorkspaceLeaf } from "obsidian";
import { MeetingNotesSettingTab } from "./src/settings";
import { MeetingView } from "./src/meeting-view";
import { MeetingController } from "./src/meeting-controller";
import { M365Auth } from "./src/m365-auth";
import { CalendarSync } from "./src/calendar-sync";
import {
  DEFAULT_SETTINGS,
  MEETING_VIEW_TYPE,
  type MeetingNotesSettings,
} from "./src/types";

export default class MeetingNotesPlugin extends Plugin {
  settings: MeetingNotesSettings = DEFAULT_SETTINGS;
  controller!: MeetingController;
  calendarSync: CalendarSync | null = null;

  async onload(): Promise<void> {
    await this.loadSettings();

    this.controller = new MeetingController(this);

    // Initialize M365 calendar sync
    const m365Auth = new M365Auth();
    if (m365Auth.isAvailable()) {
      this.calendarSync = new CalendarSync(
        m365Auth,
        this.app,
        this.settings.peopleFolderPath,
      );

      // Initial calendar fetch (non-blocking)
      this.calendarSync.refresh().catch((err) => {
        console.log("[alembic] Calendar sync not available:", err.message);
      });

      // Poll for calendar updates using registerInterval (auto-cleanup on unload)
      const intervalMs = this.settings.calendarPollingMinutes * 60 * 1000;
      this.registerInterval(window.setInterval(() => {
        this.calendarSync?.refresh().catch((err) => {
          console.warn("[alembic] Calendar refresh failed:", err.message);
        });
      }, intervalMs));
    }

    // Register the meeting view
    this.registerView(
      MEETING_VIEW_TYPE,
      (leaf) => new MeetingView(leaf, this),
    );

    // Ribbon icon to open the meeting panel
    this.addRibbonIcon("mic", "Open Alembic", () => {
      this.activateView();
    });

    // Commands
    this.addCommand({
      id: "open-meeting-panel",
      name: "Open meeting panel",
      callback: () => this.activateView(),
    });

    this.addCommand({
      id: "start-recording",
      name: "Start meeting recording",
      callback: () => this.controller.startRecording(),
    });

    this.addCommand({
      id: "stop-recording",
      name: "Stop recording and generate notes",
      callback: () => {
        // Will use whatever is in the meeting view
        const view = this.getMeetingView();
        if (view) {
          // Trigger stop from the view
          this.controller.stopAndProcess("Meeting", "");
        }
      },
    });

    this.addCommand({
      id: "refresh-calendar",
      name: "Refresh calendar events",
      callback: async () => {
        if (!this.calendarSync) {
          new Notice("M365 integration not available — Azure CLI not found");
          return;
        }
        try {
          const events = await this.calendarSync.refresh();
          new Notice(`📅 Found ${events.length} events today`);
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          new Notice(`Calendar refresh failed: ${msg}`, 8000);
        }
      },
    });

    // Settings tab
    this.addSettingTab(new MeetingNotesSettingTab(this.app, this));

    // Check dependencies at startup
    const issues = await this.controller.checkDependencies();
    const errors = issues.filter((i) => i.severity === "error");
    if (errors.length > 0) {
      new Notice(
        `Alembic — missing dependencies:\n` +
          errors.map((e) => `• ${e.dependency}: ${e.message}`).join("\n"),
        10000,
      );
    }
  }

  async onunload(): Promise<void> {
    this.app.workspace.detachLeavesOfType(MEETING_VIEW_TYPE);
  }

  async loadSettings(): Promise<void> {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }

  async saveSettings(): Promise<void> {
    await this.saveData(this.settings);
  }

  private async activateView(): Promise<void> {
    const { workspace } = this.app;

    let leaf: WorkspaceLeaf | null = null;
    const leaves = workspace.getLeavesOfType(MEETING_VIEW_TYPE);

    if (leaves.length > 0) {
      leaf = leaves[0];
    } else {
      leaf = workspace.getRightLeaf(false);
      if (leaf) {
        await leaf.setViewState({
          type: MEETING_VIEW_TYPE,
          active: true,
        });
      }
    }

    if (leaf) {
      workspace.revealLeaf(leaf);
    }
  }

  private getMeetingView(): MeetingView | null {
    const leaves = this.app.workspace.getLeavesOfType(MEETING_VIEW_TYPE);
    if (leaves.length > 0) {
      return leaves[0].view as MeetingView;
    }
    return null;
  }
}
