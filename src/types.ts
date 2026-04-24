export interface MeetingNotesSettings {
  targetApp: string;
  outputFolder: string;
  vocabularyHints: string[];
}

export const DEFAULT_SETTINGS: MeetingNotesSettings = {
  targetApp: "Microsoft Teams",
  outputFolder: "Meetings",
  vocabularyHints: [],
};

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

export interface DependencyIssue {
  dependency: string;
  message: string;
  severity: "error" | "warning";
}

export const MEETING_VIEW_TYPE = "alembic-view";
