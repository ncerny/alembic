export interface MeetingNotesSettings {
  targetApp: string;
  outputFolder: string;
  vocabularyHints: string[];
  peopleFolderPath: string;
  calendarPollingMinutes: number;
}

export const DEFAULT_SETTINGS: MeetingNotesSettings = {
  targetApp: "Microsoft Teams",
  outputFolder: "Meetings",
  vocabularyHints: [],
  peopleFolderPath: "People",
  calendarPollingMinutes: 5,
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

// --- Microsoft Graph / Calendar types ---

export interface GraphAttendee {
  emailAddress: {
    name: string;
    address: string;
  };
  type: "required" | "optional" | "resource";
  status?: {
    response: string;
    time?: string;
  };
}

export interface CalendarEvent {
  subject: string;
  start: { dateTime: string; timeZone: string };
  end: { dateTime: string; timeZone: string };
  attendees: GraphAttendee[];
  onlineMeeting?: {
    joinUrl: string;
  };
  organizer?: {
    emailAddress: {
      name: string;
      address: string;
    };
  };
  body?: {
    contentType: string;
    content: string;
  };
  location?: {
    displayName: string;
  };
}

export interface CalendarViewResponse {
  value: CalendarEvent[];
}

export const MEETING_VIEW_TYPE = "alembic-view";
