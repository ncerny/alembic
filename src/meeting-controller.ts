import { Notice } from "obsidian";
import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import type MeetingNotesPlugin from "../main";
import { AudioCapture } from "./audio-capture";
import { Transcriber } from "./transcriber";
import { Summarizer } from "./summarizer";
import { CopilotSDKProvider } from "./providers/copilot-sdk";
import { NoteBuilder } from "./note-builder";
import { getVaultVocabulary, vocabToRecognitionHints } from "./vault-vocab";
import type {
  DependencyIssue,
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
  private _dependencyIssues: DependencyIssue[] = [];

  constructor(plugin: MeetingNotesPlugin) {
    this.plugin = plugin;
    this.audioCapture = new AudioCapture(this.getPluginDir());
    this.transcriber = new Transcriber(this.getPluginDir());
  }

  get state(): MeetingState {
    return this._state;
  }

  get dependencyIssues(): DependencyIssue[] {
    return this._dependencyIssues;
  }

  get hasErrors(): boolean {
    return this._dependencyIssues.some((i) => i.severity === "error");
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

  async checkDependencies(): Promise<DependencyIssue[]> {
    const issues: DependencyIssue[] = [];

    // Audio capture helper (also handles transcription now)
    if (!this.audioCapture.isHelperInstalled()) {
      issues.push({
        dependency: "Audio Capture Helper",
        message: "Not found. Build: cd swift-helper && bash build.sh",
        severity: "error",
      });
    }

    this._dependencyIssues = issues;
    return issues;
  }

  async startRecording(): Promise<void> {
    if (this._state !== "idle" && this._state !== "complete" && this._state !== "error") {
      new Notice("Already recording or processing");
      return;
    }

    const targetApp = this.plugin.settings.targetApp;
    if (!targetApp) {
      new Notice("Please set a target application in Alembic settings");
      return;
    }

    if (!this.audioCapture.isHelperInstalled()) {
      new Notice("Audio capture helper not found. Build it: cd swift-helper && bash build.sh");
      return;
    }

    try {
      const tempDir = mkdtempSync(join(tmpdir(), "alembic-"));
      const tempPath = join(tempDir, `recording-${Date.now()}.wav`);
      await this.audioCapture.start(targetApp, tempPath, (seconds) => {
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
    // Pause not supported with ScreenCaptureKit helper
    new Notice("Pause not supported — stop and restart instead");
  }

  async stopAndProcess(
    meetingTitle: string,
    userNotes: string,
  ): Promise<void> {
    if (!this.audioCapture.isRecording) {
      new Notice("No active recording");
      return;
    }

    const recordingDuration = this.audioCapture.duration;

    try {
      // Stop recording — returns the WAV file path
      this.emitProgress("Stopping recording...");
      const wavPath = await this.audioCapture.stop();

      // Transcribe from WAV file path
      this.setState("transcribing");
      this.emitProgress("Transcribing audio...");
      // Collect vocabulary from entire vault (excludes dates, archives)
      const vaultVocab = getVaultVocabulary(this.plugin.app);
      // Speech recognizer needs individual words, not "Last, First"
      const recognitionHints = vocabToRecognitionHints(
        vaultVocab,
        [...this.plugin.settings.vocabularyHints, "Alembic"],
      );

      this.lastTranscript = await this.transcriber.transcribeFile(
        wavPath,
        (msg) => this.emitProgress(msg),
        recognitionHints,
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

      const provider = new CopilotSDKProvider(this.getPluginDir());
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
        vaultVocab,
      );
      const notePath = await noteBuilder.createMeetingNote(meetingData);

      this.setState("complete");
      this.emitProgress(`Note created: ${notePath}`);
      new Notice(`Meeting note created: ${notePath}`);
    } catch (err) {
      console.error("[alembic] Pipeline error:", err);
      const message = err instanceof Error ? err.message : String(err);
      this.emitProgress(`Error: ${message}`);
      this.setState("error");
      new Notice(`Meeting notes error: ${message}`, 10000);
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
      const provider = new CopilotSDKProvider(this.getPluginDir());
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

      const vaultVocab = getVaultVocabulary(this.plugin.app);
      const noteBuilder = new NoteBuilder(
        this.plugin.app,
        this.plugin.settings.outputFolder,
        vaultVocab,
      );
      const notePath = await noteBuilder.createMeetingNote(meetingData);

      this.setState("complete");
      new Notice(`Meeting note created: ${notePath}`);
    } catch (err) {
      console.error("[alembic] Enhance error:", err);
      const message = err instanceof Error ? err.message : String(err);
      this.emitProgress(`Error: ${message}`);
      this.setState("error");
      new Notice(`Error: ${message}`, 10000);
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
    return `${basePath}/.obsidian/plugins/alembic`;
  }
}
