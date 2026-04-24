import { App, PluginSettingTab, Setting } from "obsidian";
import type MeetingNotesPlugin from "../main";
import type { MeetingNotesSettings } from "./types";

export class MeetingNotesSettingTab extends PluginSettingTab {
  plugin: MeetingNotesPlugin;

  constructor(app: App, plugin: MeetingNotesPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();

    containerEl.createEl("h2", { text: "Alembic Settings" });

    // Target application
    new Setting(containerEl)
      .setName("Target application")
      .setDesc("Application to capture audio from (e.g., Microsoft Teams, Zoom)")
      .addText((text) => {
        text.setPlaceholder("Microsoft Teams");
        text.setValue(this.plugin.settings.targetApp);
        text.onChange(async (value) => {
          this.plugin.settings.targetApp = value || "Microsoft Teams";
          await this.plugin.saveSettings();
        });
      });

    // Output folder
    new Setting(containerEl)
      .setName("Output folder")
      .setDesc("Folder where meeting notes will be created")
      .addText((text) => {
        text.setPlaceholder("Meetings");
        text.setValue(this.plugin.settings.outputFolder);
        text.onChange(async (value) => {
          this.plugin.settings.outputFolder = value || "Meetings";
          await this.plugin.saveSettings();
        });
      });

    // Vocabulary hints
    new Setting(containerEl)
      .setName("Extra vocabulary hints")
      .setDesc(
        "Comma-separated terms to add beyond what's auto-detected from vault notes " +
        "(e.g., acronyms, brand names not in your vault). All vault note names are " +
        "automatically included — notes under Archive folders and date-prefixed notes are excluded.",
      )
      .addTextArea((text) => {
        text.setPlaceholder("Dynatrace, Splunk, Kubernetes, Zabbix");
        text.setValue(this.plugin.settings.vocabularyHints.join(", "));
        text.inputEl.rows = 3;
        text.inputEl.cols = 40;
        text.onChange(async (value) => {
          this.plugin.settings.vocabularyHints = value
            .split(",")
            .map((s) => s.trim())
            .filter((s) => s.length > 0);
          await this.plugin.saveSettings();
        });
      });

    // Setup help section
    containerEl.createEl("h3", { text: "Setup Guide" });

    const setupDiv = containerEl.createDiv({ cls: "setting-item-description" });
    setupDiv.innerHTML = `
      <p><strong>Prerequisites:</strong></p>
      <ol>
        <li><strong>GitHub Copilot CLI</strong> — Install and authenticate: <code>gh extension install github/gh-copilot</code></li>
        <li><strong>Audio capture helper</strong> — Build the Swift helper: <code>cd swift-helper && bash build.sh</code></li>
        <li><strong>Screen Recording permission</strong> — macOS will prompt on first capture</li>
        <li><strong>Speech Recognition permission</strong> — macOS will prompt on first transcription</li>
      </ol>
      <p><strong>How it works:</strong></p>
      <p>The plugin uses macOS ScreenCaptureKit to capture audio from the target application, 
      Apple's on-device Speech Recognition for transcription (no internet required), 
      and GitHub Copilot for AI summarization.</p>
    `;
  }
}
