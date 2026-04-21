export interface MeetingNotesSettings {
  model: string;
  targetApp: string;
  outputFolder: string;
  whisperModelSize: WhisperModelSize;
}

export type WhisperModelSize = "tiny" | "base" | "small" | "medium";

export const DEFAULT_SETTINGS: MeetingNotesSettings = {
  model: "gpt-4o-mini",
  targetApp: "Microsoft Teams",
  outputFolder: "Meetings",
  whisperModelSize: "base",
};

export const AVAILABLE_MODELS = [
  { value: "gpt-4.1", label: "GPT-4.1 (1M context)" },
  { value: "gpt-4o", label: "GPT-4o (128K context)" },
  { value: "gpt-4o-mini", label: "GPT-4o mini (128K, fast)" },
];

export const WHISPER_MODEL_OPTIONS: { value: WhisperModelSize; label: string }[] = [
  { value: "tiny", label: "Tiny (~75MB, fastest, lower accuracy)" },
  { value: "base", label: "Base (~150MB, balanced)" },
  { value: "small", label: "Small (~500MB, better accuracy)" },
  { value: "medium", label: "Medium (~1.5GB, best accuracy)" },
];

export type MeetingState =
  | "idle"
  | "recording"
  | "transcribing"
  | "summarizing"
  | "complete"
  | "error";

export interface TranscriptSegment {
  start: number; // seconds
  end: number;
  text: string;
}

export interface MeetingSummary {
  title: string;
  summary: string;
  keyDecisions: string[];
  actionItems: ActionItem[];
  keyTopics: string[];
  attendees: string[];
}

export interface ActionItem {
  assignee: string;
  task: string;
  due?: string;
}

export interface MeetingData {
  title: string;
  userNotes: string;
  transcript: TranscriptSegment[];
  summary?: MeetingSummary;
  recordingDuration: number;
  date: string;
}

export const MEETING_VIEW_TYPE = "meeting-notes-view";
