import { Notice, Plugin, WorkspaceLeaf } from "obsidian";
import { MeetingNotesSettingTab } from "./src/settings";
import { MeetingView } from "./src/meeting-view";
import { MeetingController } from "./src/meeting-controller";
import { M365Auth, type TokenData } from "./src/m365-auth";
import { CalendarSync } from "./src/calendar-sync";
import {
  DEFAULT_SETTINGS,
  MEETING_VIEW_TYPE,
  type MeetingNotesSettings,
} from "./src/types";

export default class MeetingNotesPlugin extends Plugin {
  settings: MeetingNotesSettings = DEFAULT_SETTINGS;
  controller!: MeetingController;
  calendarSync!: CalendarSync;
  private m365Auth!: M365Auth;

  async onload(): Promise<void> {
    await this.loadSettings();

    this.controller = new MeetingController(this);

    // Initialize M365 auth with saved tokens
    const savedTokenData: TokenData | null = this.settings.m365RefreshToken
      ? {
          accessToken: this.settings.m365AccessToken || "",
          refreshToken: this.settings.m365RefreshToken,
          expiresAt: this.settings.m365TokenExpiry || 0,
        }
      : null;

    this.m365Auth = new M365Auth(savedTokenData, async (tokenData) => {
      if (tokenData) {
        this.settings.m365AccessToken = tokenData.accessToken;
        this.settings.m365RefreshToken = tokenData.refreshToken;
        this.settings.m365TokenExpiry = tokenData.expiresAt;
      } else {
        delete this.settings.m365AccessToken;
        delete this.settings.m365RefreshToken;
        delete this.settings.m365TokenExpiry;
      }
      await this.saveSettings();
    });

    this.calendarSync = new CalendarSync(
      this.m365Auth,
      this.app,
      this.settings.peopleFolderPath,
    );

    // Initial calendar fetch if we have a token (non-blocking)
    if (this.m365Auth.hasRefreshToken()) {
      this.calendarSync.refresh().catch((err) => {
        console.log("[alembic] Calendar sync not available:", err.message);
      });
    }

    // Poll for calendar updates
    const intervalMs = this.settings.calendarPollingMinutes * 60 * 1000;
    this.registerInterval(window.setInterval(() => {
      if (this.m365Auth.hasRefreshToken()) {
        this.calendarSync.refresh().catch((err) => {
          console.warn("[alembic] Calendar refresh failed:", err.message);
        });
      }
    }, intervalMs));

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
        const view = this.getMeetingView();
        if (view) {
          const title = view.getTitle() || "Meeting";
          const notes = view.getNotes();
          const event = view.getSelectedEvent();
          this.controller.stopAndProcess(title, notes, event ?? undefined);
        }
      },
    });

    this.addCommand({
      id: "refresh-calendar",
      name: "Refresh calendar events",
      callback: async () => {
        if (!this.m365Auth.hasRefreshToken()) {
          new Notice("M365 not connected — use Connect button in settings");
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
    this.m365Auth.cancelLogin();
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
