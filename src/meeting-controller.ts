import { Notice } from "obsidian";
import { existsSync, mkdtempSync } from "fs";
import { homedir, tmpdir } from "os";
import { join } from "path";
import type MeetingNotesPlugin from "../main";
import { AudioCapture } from "./audio-capture";
import { Transcriber } from "./transcriber";
import { Summarizer } from "./summarizer";
import { CopilotSDKProvider } from "./providers/copilot-sdk";
import { NoteBuilder } from "./note-builder";
import { getVaultVocabulary, vocabToRecognitionHints, correctTranscriptNames } from "./vault-vocab";
import { stripHtml } from "./calendar-sync";
import { addListener } from "./listener-utils";
import {
  getPluginDir as getInstalledPluginDir,
  resolveHelperRoot,
} from "./plugin-paths";
import type {
  CalendarEvent,
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
    this.audioCapture = new AudioCapture(this.getHelperDir());
    this.transcriber = new Transcriber(this.getHelperDir());
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

  onStateChange(listener: (state: MeetingState) => void): () => void {
    return addListener(this.stateListeners, listener);
  }

  onProgress(listener: (msg: string) => void): () => void {
    return addListener(this.progressListeners, listener);
  }

  onDurationUpdate(listener: (seconds: number) => void): () => void {
    return addListener(this.durationListeners, listener);
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
    calendarEvent?: CalendarEvent,
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

      // Augment with calendar data if available
      let augmentedTitle = meetingTitle;
      let augmentedNotes = userNotes;

      if (calendarEvent) {
        augmentedTitle = augmentedTitle || calendarEvent.subject;

        // Add attendee names as extra vocabulary hints
        const attendeeNames = calendarEvent.attendees
          .map((a) => a.emailAddress.name)
          .filter(Boolean);
        for (const name of attendeeNames) {
          for (const word of name.split(/\s+/)) {
            if (word.length >= 2) recognitionHints.push(word);
          }
        }

        // Append agenda as context if available
        if (calendarEvent.body?.content) {
          const bodyText = stripHtml(calendarEvent.body.content);
          if (bodyText.length > 10) {
            augmentedNotes = augmentedNotes
              ? `${augmentedNotes}\n\n--- Meeting Agenda ---\n${bodyText}`
              : bodyText;
          }
        }
      }

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

      // Correct misheard names in transcript using vault vocabulary
      this.lastTranscript = this.lastTranscript.map((seg) => ({
        ...seg,
        text: correctTranscriptNames(seg.text, vaultVocab),
      }));

      // Summarize
      this.setState("summarizing");
      this.emitProgress("Generating summary...");

      const transcriptText = this.lastTranscript
        .map((s) => s.text)
        .join("\n");

      const provider = new CopilotSDKProvider(this.getPluginDir());
      const summarizer = new Summarizer(provider);
      this.lastSummary = await summarizer.summarize(transcriptText, augmentedNotes, vaultVocab);

      // Build note
      this.emitProgress("Creating meeting note...");
      const today = new Date().toISOString().split("T")[0];
      const meetingData: MeetingData = {
        title: augmentedTitle || "Meeting",
        userNotes: augmentedNotes,
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

      const vaultVocab = getVaultVocabulary(this.plugin.app);

      // Correct misheard names in transcript
      const correctedTranscript = transcript.map((seg) => ({
        ...seg,
        text: correctTranscriptNames(seg.text, vaultVocab),
      }));

      const transcriptText = correctedTranscript.map((s) => s.text).join("\n");
      const provider = new CopilotSDKProvider(this.getPluginDir());
      const summarizer = new Summarizer(provider);
      const summary = await summarizer.summarize(transcriptText, userNotes, vaultVocab);

      this.emitProgress("Creating meeting note...");
      const today = new Date().toISOString().split("T")[0];
      const meetingData: MeetingData = {
        title: meetingTitle || "Meeting",
        userNotes,
        transcript: correctedTranscript,
        summary,
        recordingDuration: 0,
        date: today,
      };

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
    return getInstalledPluginDir(basePath);
  }

  private getHelperDir(): string {
    return resolveHelperRoot({
      pluginDir: this.getPluginDir(),
      homeDir: process.env.HOME || homedir(),
      helperExists: (helperAppPath) => existsSync(helperAppPath),
    });
  }
}
