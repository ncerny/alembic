import { App, PluginSettingTab, Setting } from "obsidian";
import type MeetingNotesPlugin from "../main";
import {
  AVAILABLE_MODELS,
  WHISPER_MODEL_OPTIONS,
  type MeetingNotesSettings,
} from "./types";

export class MeetingNotesSettingTab extends PluginSettingTab {
  plugin: MeetingNotesPlugin;

  constructor(app: App, plugin: MeetingNotesPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();

    containerEl.createEl("h2", { text: "Meeting Notes Settings" });

    // LLM Model selection
    new Setting(containerEl)
      .setName("Copilot model")
      .setDesc("LLM model for meeting summarization (requires GitHub Copilot CLI)")
      .addDropdown((dropdown) => {
        for (const model of AVAILABLE_MODELS) {
          dropdown.addOption(model.value, model.label);
        }
        dropdown.setValue(this.plugin.settings.model);
        dropdown.onChange(async (value) => {
          this.plugin.settings.model = value;
          await this.plugin.saveSettings();
        });
      });

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

    // Whisper model size
    new Setting(containerEl)
      .setName("Whisper model size")
      .setDesc("Larger models are more accurate but slower and use more disk space")
      .addDropdown((dropdown) => {
        for (const opt of WHISPER_MODEL_OPTIONS) {
          dropdown.addOption(opt.value, opt.label);
        }
        dropdown.setValue(this.plugin.settings.whisperModelSize);
        dropdown.onChange(async (value) => {
          this.plugin.settings.whisperModelSize =
            value as MeetingNotesSettings["whisperModelSize"];
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
        <li><strong>Whisper.cpp</strong> — Install via: <code>brew install whisper-cpp</code></li>
        <li><strong>Audio capture helper</strong> — Build the Swift helper: <code>cd swift-helper && bash build.sh</code></li>
        <li><strong>Screen Recording permission</strong> — macOS will prompt on first capture</li>
      </ol>
      <p><strong>How it works:</strong></p>
      <p>The plugin uses macOS ScreenCaptureKit to capture audio directly from the target application (e.g., Teams). 
      No virtual audio device needed — just grant Screen Recording permission when prompted.</p>
    `;
  }
}
