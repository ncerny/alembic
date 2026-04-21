import { Notice } from "obsidian";
import type MeetingNotesPlugin from "../main";
import { AudioCapture } from "./audio-capture";
import { Transcriber } from "./transcriber";
import { Summarizer } from "./summarizer";
import { CopilotSDKProvider } from "./providers/copilot-sdk";
import { NoteBuilder } from "./note-builder";
import type {
  MeetingData,
  MeetingState,
  MeetingSummary,
  TranscriptSegment,
} from "./types";

export class MeetingController {
  private plugin: MeetingNotesPlugin;
  private audioCapture: AudioCapture;
  private transcriber: Transcriber;
  private _state: MeetingState = "idle";
  private stateListeners: ((state: MeetingState) => void)[] = [];
  private progressListeners: ((msg: string) => void)[] = [];
  private durationListeners: ((seconds: number) => void)[] = [];
  private lastTranscript: TranscriptSegment[] = [];
  private lastSummary: MeetingSummary | null = null;

  constructor(plugin: MeetingNotesPlugin) {
    this.plugin = plugin;
    this.audioCapture = new AudioCapture();
    this.transcriber = new Transcriber(this.getPluginDir());
  }

  get state(): MeetingState {
    return this._state;
  }

  get duration(): number {
    return this.audioCapture.duration;
  }

  onStateChange(listener: (state: MeetingState) => void): void {
    this.stateListeners.push(listener);
  }

  onProgress(listener: (msg: string) => void): void {
    this.progressListeners.push(listener);
  }

  onDurationUpdate(listener: (seconds: number) => void): void {
    this.durationListeners.push(listener);
  }

  private setState(state: MeetingState): void {
    this._state = state;
    this.stateListeners.forEach((l) => l(state));
  }

  private emitProgress(msg: string): void {
    this.progressListeners.forEach((l) => l(msg));
  }

  async startRecording(): Promise<void> {
    if (this._state !== "idle" && this._state !== "complete" && this._state !== "error") {
      new Notice("Already recording or processing");
      return;
    }

    const deviceId = this.plugin.settings.audioDeviceId;
    if (!deviceId) {
      new Notice("Please select an audio device in Meeting Notes settings");
      return;
    }

    try {
      await this.audioCapture.start(deviceId, (seconds) => {
        this.durationListeners.forEach((l) => l(seconds));
      });
      this.setState("recording");
      new Notice("Recording started");
    } catch (err) {
      this.setState("error");
      new Notice(`Failed to start recording: ${err}`);
    }
  }

  pauseRecording(): void {
    if (this.audioCapture.isRecording) {
      this.audioCapture.pause();
    } else if (this.audioCapture.isPaused) {
      this.audioCapture.resume();
    }
  }

  async stopAndProcess(
    meetingTitle: string,
    userNotes: string,
  ): Promise<void> {
    if (!this.audioCapture.isRecording && !this.audioCapture.isPaused) {
      new Notice("No active recording");
      return;
    }

    const recordingDuration = this.audioCapture.duration;

    try {
      // Stop recording
      this.emitProgress("Stopping recording...");
      const audioBlob = await this.audioCapture.stop();

      // Transcribe
      this.setState("transcribing");
      this.emitProgress("Transcribing audio...");
      this.lastTranscript = await this.transcriber.transcribe(
        audioBlob,
        this.plugin.settings.whisperModelSize,
        (msg) => this.emitProgress(msg),
      );

      if (this.lastTranscript.length === 0) {
        new Notice("No speech detected in recording");
        this.setState("idle");
        return;
      }

      // Summarize
      this.setState("summarizing");
      this.emitProgress("Generating summary...");

      const transcriptText = this.lastTranscript
        .map((s) => s.text)
        .join("\n");

      const provider = new CopilotSDKProvider(this.plugin.settings.model);
      const summarizer = new Summarizer(provider);
      this.lastSummary = await summarizer.summarize(transcriptText, userNotes);

      // Build note
      this.emitProgress("Creating meeting note...");
      const today = new Date().toISOString().split("T")[0];
      const meetingData: MeetingData = {
        title: meetingTitle || "Meeting",
        userNotes,
        transcript: this.lastTranscript,
        summary: this.lastSummary,
        recordingDuration,
        date: today,
      };

      const noteBuilder = new NoteBuilder(
        this.plugin.app,
        this.plugin.settings.outputFolder,
      );
      const notePath = await noteBuilder.createMeetingNote(meetingData);

      this.setState("complete");
      this.emitProgress(`Note created: ${notePath}`);
      new Notice(`Meeting note created: ${notePath}`);
    } catch (err) {
      this.setState("error");
      const message = err instanceof Error ? err.message : String(err);
      this.emitProgress(`Error: ${message}`);
      new Notice(`Meeting notes error: ${message}`);
    }
  }

  async enhanceOnly(
    meetingTitle: string,
    userNotes: string,
    transcript: TranscriptSegment[],
  ): Promise<void> {
    try {
      this.setState("summarizing");
      this.emitProgress("Generating summary...");

      const transcriptText = transcript.map((s) => s.text).join("\n");
      const provider = new CopilotSDKProvider(this.plugin.settings.model);
      const summarizer = new Summarizer(provider);
      const summary = await summarizer.summarize(transcriptText, userNotes);

      this.emitProgress("Creating meeting note...");
      const today = new Date().toISOString().split("T")[0];
      const meetingData: MeetingData = {
        title: meetingTitle || "Meeting",
        userNotes,
        transcript,
        summary,
        recordingDuration: 0,
        date: today,
      };

      const noteBuilder = new NoteBuilder(
        this.plugin.app,
        this.plugin.settings.outputFolder,
      );
      const notePath = await noteBuilder.createMeetingNote(meetingData);

      this.setState("complete");
      new Notice(`Meeting note created: ${notePath}`);
    } catch (err) {
      this.setState("error");
      const message = err instanceof Error ? err.message : String(err);
      new Notice(`Error: ${message}`);
    }
  }

  reset(): void {
    this.setState("idle");
    this.lastTranscript = [];
    this.lastSummary = null;
  }

  private getPluginDir(): string {
    const adapter = this.plugin.app.vault.adapter as any;
    const basePath = adapter.getBasePath?.() || "";
    return `${basePath}/.obsidian/plugins/obsidian-meeting-notes`;
  }
}
