import { Plugin, WorkspaceLeaf } from "obsidian";
import { MeetingNotesSettingTab } from "./src/settings";
import { MeetingView } from "./src/meeting-view";
import { MeetingController } from "./src/meeting-controller";
import {
  DEFAULT_SETTINGS,
  MEETING_VIEW_TYPE,
  type MeetingNotesSettings,
} from "./src/types";

export default class MeetingNotesPlugin extends Plugin {
  settings: MeetingNotesSettings = DEFAULT_SETTINGS;
  controller!: MeetingController;

  async onload(): Promise<void> {
    await this.loadSettings();

    this.controller = new MeetingController(this);

    // Register the meeting view
    this.registerView(
      MEETING_VIEW_TYPE,
      (leaf) => new MeetingView(leaf, this),
    );

    // Ribbon icon to open the meeting panel
    this.addRibbonIcon("mic", "Open Meeting Notes", () => {
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

    // Settings tab
    this.addSettingTab(new MeetingNotesSettingTab(this.app, this));
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
