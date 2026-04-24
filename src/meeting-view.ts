import { ItemView, WorkspaceLeaf, setIcon } from "obsidian";
import type MeetingNotesPlugin from "../main";
import { formatDuration } from "./audio-capture";
import { MEETING_VIEW_TYPE, type CalendarEvent, type DependencyIssue, type MeetingState } from "./types";

export class MeetingView extends ItemView {
  private plugin: MeetingNotesPlugin;
  private titleInput: HTMLInputElement | null = null;
  private notesArea: HTMLTextAreaElement | null = null;
  private timerEl: HTMLElement | null = null;
  private statusDot: HTMLElement | null = null;
  private statusText: HTMLElement | null = null;
  private progressContainer: HTMLElement | null = null;
  private progressBar: HTMLElement | null = null;
  private progressLabel: HTMLElement | null = null;
  private recordBtn: HTMLButtonElement | null = null;
  private stopBtn: HTMLButtonElement | null = null;
  private enhanceBtn: HTMLButtonElement | null = null;
  private warningsEl: HTMLElement | null = null;
  private calendarSection: HTMLElement | null = null;
  private selectedEvent: CalendarEvent | null = null;
  private unsubCalendar?: () => void;

  constructor(leaf: WorkspaceLeaf, plugin: MeetingNotesPlugin) {
    super(leaf);
    this.plugin = plugin;
  }

  getViewType(): string {
    return MEETING_VIEW_TYPE;
  }

  getDisplayText(): string {
    return "Alembic";
  }

  getIcon(): string {
    return "mic";
  }

  async onOpen(): Promise<void> {
    const container = this.contentEl.createDiv({ cls: "meeting-view-container" });

    // Status indicator
    const statusRow = container.createDiv({ cls: "status-indicator" });
    this.statusDot = statusRow.createSpan({ cls: "status-dot idle" });
    this.statusText = statusRow.createSpan({ text: "Ready" });

    // Dependency warnings
    this.warningsEl = container.createDiv({ cls: "dependency-warnings" });
    this.renderDependencyWarnings(this.plugin.controller.dependencyIssues);

    // Calendar events section
    this.calendarSection = container.createDiv({ cls: "calendar-section" });
    this.renderCalendarSection();

    // Listen for calendar updates
    const calendarSync = this.plugin.calendarSync;
    if (calendarSync) {
      this.unsubCalendar = calendarSync.onEventsUpdate(() => this.renderCalendarSection());
    }

    // Meeting title
    this.titleInput = container.createEl("input", {
      cls: "meeting-title-input",
      placeholder: "Meeting title...",
      type: "text",
    }) as HTMLInputElement;

    // Recording controls
    const controlsRow = container.createDiv({ cls: "recording-controls" });

    this.recordBtn = controlsRow.createEl("button", {
      cls: "mod-cta",
      text: "Record",
    });
    setIcon(this.recordBtn.createSpan(), "mic");
    this.recordBtn.addEventListener("click", () => this.onRecord());

    this.stopBtn = controlsRow.createEl("button", {
      text: "Stop",
    });
    this.stopBtn.disabled = true;
    setIcon(this.stopBtn.createSpan(), "square");
    this.stopBtn.addEventListener("click", () => this.onStop());

    this.timerEl = controlsRow.createSpan({
      cls: "recording-timer",
      text: "00:00",
    });

    // Device indicator
    const deviceIndicator = container.createDiv({ cls: "device-indicator" });
    const appName = this.plugin.settings.targetApp || "No app selected";
    deviceIndicator.setText(`🎙 Capturing: ${appName}`);

    // Notes area
    container.createEl("label", {
      text: "Your notes (guides AI summary):",
      attr: { style: "font-size: 0.85em; color: var(--text-muted);" },
    });

    this.notesArea = container.createEl("textarea", {
      cls: "notes-area",
      placeholder:
        "Jot down key points during the meeting.\nThese will guide the AI summary...",
    }) as HTMLTextAreaElement;

    // Progress
    this.progressContainer = container.createDiv({ cls: "progress-container" });
    const bar = this.progressContainer.createDiv({ cls: "progress-bar" });
    this.progressBar = bar.createDiv({ cls: "progress-bar-fill" });
    this.progressBar.style.width = "0%";
    this.progressLabel = this.progressContainer.createDiv({ cls: "progress-label" });

    // Enhance button
    const actionRow = container.createDiv({ cls: "action-buttons" });
    this.enhanceBtn = actionRow.createEl("button", {
      cls: "mod-cta enhance-btn",
      text: "✨ Enhance Notes",
    });
    this.enhanceBtn.disabled = true;
    this.enhanceBtn.addEventListener("click", () => this.onEnhance());

    // Wire up controller events
    this.plugin.controller.onStateChange((state) => this.updateUI(state));
    this.plugin.controller.onDurationUpdate((seconds) => {
      if (this.timerEl) {
        this.timerEl.setText(formatDuration(seconds));
      }
    });
    this.plugin.controller.onProgress((msg) => {
      if (this.progressLabel) this.progressLabel.setText(msg);
    });
  }

  private async onRecord(): Promise<void> {
    await this.plugin.controller.startRecording();
  }

  private async onStop(): Promise<void> {
    const title = this.titleInput?.value || "";
    const notes = this.notesArea?.value || "";
    await this.plugin.controller.stopAndProcess(title, notes, this.selectedEvent ?? undefined);
  }

  private async onEnhance(): Promise<void> {
    // For future use: enhance notes without a new recording
    const title = this.titleInput?.value || "";
    const notes = this.notesArea?.value || "";

    if (!notes.trim()) {
      return;
    }

    // Treat user notes as the transcript and enhance
    await this.plugin.controller.enhanceOnly(title, notes, []);
  }

  private updateUI(state: MeetingState): void {
    // Status dot
    if (this.statusDot) {
      this.statusDot.className = "status-dot";
      switch (state) {
        case "idle":
          this.statusDot.addClass("idle");
          break;
        case "recording":
          this.statusDot.addClass("recording");
          break;
        case "transcribing":
        case "summarizing":
          this.statusDot.addClass("processing");
          break;
        case "complete":
          this.statusDot.addClass("done");
          break;
        case "error":
          this.statusDot.addClass("idle");
          break;
      }
    }

    // Status text
    const labels: Record<MeetingState, string> = {
      idle: "Ready",
      recording: "Recording...",
      transcribing: "Transcribing...",
      summarizing: "Generating summary...",
      complete: "Done!",
      error: "Error",
    };
    if (this.statusText) {
      this.statusText.setText(labels[state]);
    }

    // Button states
    const isRecording = state === "recording";
    const isProcessing = state === "transcribing" || state === "summarizing";
    const isIdle = state === "idle" || state === "complete" || state === "error";

    if (this.recordBtn) {
      this.recordBtn.disabled = !isIdle || this.plugin.controller.hasErrors;
    }
    if (this.stopBtn) {
      this.stopBtn.disabled = !isRecording;
    }
    if (this.enhanceBtn) {
      this.enhanceBtn.disabled = isRecording || isProcessing;
    }

    // Progress visibility — keep visible during error so message is readable
    if (this.progressContainer) {
      if (isProcessing || state === "error") {
        this.progressContainer.addClass("visible");
        if (this.progressBar) {
          this.progressBar.style.width = isProcessing ? "100%" : "0%";
        }
      } else {
        this.progressContainer.removeClass("visible");
      }
    }

    // Timer styling
    if (this.timerEl) {
      if (isRecording) {
        this.timerEl.addClass("is-recording");
      } else {
        this.timerEl.removeClass("is-recording");
      }
    }

    // Reset timer on idle
    if (isIdle && state !== "complete" && this.timerEl) {
      this.timerEl.setText("00:00");
    }
  }

  private renderDependencyWarnings(issues: DependencyIssue[]): void {
    if (!this.warningsEl) return;
    this.warningsEl.empty();

    if (issues.length === 0) {
      this.warningsEl.style.display = "none";
      return;
    }

    this.warningsEl.style.display = "";
    const hasErrors = issues.some((i) => i.severity === "error");
    this.warningsEl.toggleClass("has-errors", hasErrors);

    for (const issue of issues) {
      const row = this.warningsEl.createDiv({ cls: `dep-issue dep-${issue.severity}` });
      const icon = issue.severity === "error" ? "⛔" : "⚠️";
      row.setText(`${icon} ${issue.dependency}: ${issue.message}`);
    }

    // Disable record button if critical deps are missing
    if (this.recordBtn && hasErrors) {
      this.recordBtn.disabled = true;
    }
  }

  getSelectedEvent(): CalendarEvent | null {
    return this.selectedEvent;
  }

  getTitle(): string {
    return this.titleInput?.value || "";
  }

  getNotes(): string {
    return this.notesArea?.value || "";
  }

  private isEventSelected(event: CalendarEvent): boolean {
    if (!this.selectedEvent) return false;
    return this.selectedEvent.subject === event.subject &&
      this.selectedEvent.start.dateTime === event.start.dateTime;
  }

  private renderCalendarSection(): void {
    if (!this.calendarSection) return;
    this.calendarSection.empty();

    const calendarSync = this.plugin.calendarSync;
    if (!calendarSync || !calendarSync.isAzAvailable()) return;

    if (!calendarSync.isConnected()) {
      const hint = this.calendarSection.createDiv({ cls: "calendar-hint" });
      hint.setText("📅 Connect M365 for auto-populated meetings");
      return;
    }

    const events = calendarSync.getEvents();
    if (events.length === 0) {
      const hint = this.calendarSection.createDiv({ cls: "calendar-hint" });
      hint.setText("📅 No meetings today");
      return;
    }

    const label = this.calendarSection.createDiv({ cls: "calendar-label" });
    label.setText("📅 Today's meetings:");

    for (const event of events) {
      const startTime = new Date(event.start.dateTime + "Z");
      const endTime = new Date(event.end.dateTime + "Z");
      const timeStr = `${formatTime(startTime)}–${formatTime(endTime)}`;
      const attendeeCount = event.attendees.length;
      const isTeams = !!event.onlineMeeting?.joinUrl;

      const row = this.calendarSection.createDiv({
        cls: `calendar-event${this.isEventSelected(event) ? " selected" : ""}`,
      });

      row.createSpan({ cls: "event-time", text: timeStr });
      row.createSpan({ cls: "event-title", text: event.subject });
      row.createSpan({
        cls: "event-meta",
        text: `${attendeeCount} attendees${isTeams ? " • Teams" : ""}`,
      });

      row.addEventListener("click", () => {
        this.selectedEvent = event;
        if (this.titleInput) {
          this.titleInput.value = event.subject;
        }
        this.renderCalendarSection();
      });
    }
  }

  async onClose(): Promise<void> {
    this.unsubCalendar?.();
  }
}

function formatTime(date: Date): string {
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}
