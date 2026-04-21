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

    // Audio device selection
    new Setting(containerEl)
      .setName("Audio input device")
      .setDesc("Select the audio device to capture (e.g., BlackHole for system audio)")
      .addDropdown(async (dropdown) => {
        dropdown.addOption("", "Loading devices...");

        try {
          const devices = await navigator.mediaDevices.enumerateDevices();
          const audioInputs = devices.filter((d) => d.kind === "audioinput");

          dropdown.selectEl.empty();
          dropdown.addOption("", "Select a device...");

          for (const device of audioInputs) {
            const label = device.label || `Device ${device.deviceId.slice(0, 8)}`;
            dropdown.addOption(device.deviceId, label);
          }

          dropdown.setValue(this.plugin.settings.audioDeviceId);
          dropdown.onChange(async (value) => {
            this.plugin.settings.audioDeviceId = value;
            await this.plugin.saveSettings();
          });
        } catch {
          dropdown.selectEl.empty();
          dropdown.addOption("", "Microphone access denied");
        }
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
        <li><strong>BlackHole</strong> (macOS) — Install for system audio capture: <code>brew install blackhole-2ch</code></li>
        <li><strong>Whisper.cpp</strong> — Downloaded automatically on first use</li>
      </ol>
      <p><strong>Audio routing (macOS):</strong></p>
      <ol>
        <li>Open <em>Audio MIDI Setup</em></li>
        <li>Create a <em>Multi-Output Device</em> with your speakers + BlackHole</li>
        <li>Set it as your system output</li>
        <li>Select "BlackHole 2ch" as the audio input device above</li>
      </ol>
    `;
  }
}
