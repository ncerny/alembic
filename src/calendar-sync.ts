import type { App } from "obsidian";
import type { M365Auth } from "./m365-auth";
import { GraphClient } from "./graph-client";
import { PeopleManager } from "./people-manager";
import type { CalendarEvent, GraphAttendee } from "./types";

export class CalendarSync {
  private auth: M365Auth;
  private graphClient: GraphClient;
  private peopleManager: PeopleManager;
  private app: App;
  private events: CalendarEvent[] = [];
  private lastFetch: number = 0;
  private listeners: ((events: CalendarEvent[]) => void)[] = [];
  private _connected = false;

  constructor(auth: M365Auth, app: App, peopleFolderPath: string) {
    this.auth = auth;
    this.app = app;
    this.graphClient = new GraphClient(auth);
    this.peopleManager = new PeopleManager(app, peopleFolderPath);
  }

  /**
   * Subscribe to calendar event updates. Returns an unsubscribe function.
   */
  onEventsUpdate(listener: (events: CalendarEvent[]) => void): () => void {
    this.listeners.push(listener);
    return () => {
      this.listeners = this.listeners.filter((l) => l !== listener);
    };
  }

  private emitEvents(): void {
    this.listeners.forEach((l) => l(this.events));
  }

  /**
   * Fetch today's calendar events and ensure people notes exist.
   * Returns the event list.
   */
  async refresh(): Promise<CalendarEvent[]> {
    try {
      this.events = await this.graphClient.getCalendarView();
      this.lastFetch = Date.now();
      this._connected = true;

      // Auto-create people notes for all attendees
      const allAttendees = this.getAllAttendees();
      if (allAttendees.length > 0) {
        await this.peopleManager.ensurePeopleNotes(allAttendees);
      }

      this.emitEvents();
      return this.events;
    } catch (err) {
      this._connected = false;
      console.error("[alembic] Calendar refresh failed:", err);
      throw err;
    }
  }

  /**
   * Get the current or next upcoming meeting.
   * A meeting is "current" if now is between start and end.
   * Otherwise returns the next upcoming meeting.
   */
  getCurrentOrNextMeeting(): CalendarEvent | null {
    const now = new Date();

    for (const event of this.events) {
      const start = new Date(event.start.dateTime + "Z");
      const end = new Date(event.end.dateTime + "Z");

      // Currently in this meeting
      if (now >= start && now <= end) return event;
    }

    // Find next upcoming
    for (const event of this.events) {
      const start = new Date(event.start.dateTime + "Z");
      if (start > now) return event;
    }

    return null;
  }

  /**
   * Get all attendee names from a specific event (for vocabulary hints).
   */
  getEventAttendeeNames(event: CalendarEvent): string[] {
    const names: string[] = [];
    for (const a of event.attendees) {
      if (a.emailAddress.name) {
        names.push(a.emailAddress.name);
      }
    }
    if (event.organizer?.emailAddress.name) {
      names.push(event.organizer.emailAddress.name);
    }
    return [...new Set(names)];
  }

  /**
   * Extract plain text from HTML body content (strip tags).
   */
  getEventBodyText(event: CalendarEvent): string {
    if (!event.body?.content) return "";
    return stripHtml(event.body.content);
  }

  getEvents(): CalendarEvent[] {
    return this.events;
  }

  /**
   * Returns cached connection status (updated during refresh).
   * Never blocks the main thread.
   */
  isConnected(): boolean {
    return this._connected;
  }

  /**
   * Whether the user has logged in (has a refresh token).
   */
  isConfigured(): boolean {
    return this.auth.hasRefreshToken();
  }

  updatePeopleFolderPath(path: string): void {
    this.peopleManager = new PeopleManager(this.app, path);
  }

  getAuth(): M365Auth {
    return this.auth;
  }

  private getAllAttendees(): GraphAttendee[] {
    const seen = new Set<string>();
    const attendees: GraphAttendee[] = [];

    for (const event of this.events) {
      for (const a of event.attendees) {
        const key = a.emailAddress.address.toLowerCase();
        if (!seen.has(key)) {
          seen.add(key);
          attendees.push(a);
        }
      }
    }

    return attendees;
  }
}

/**
 * Strip HTML tags and decode common entities from calendar body content.
 */
export function stripHtml(html: string): string {
  return html
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/\s+/g, " ")
    .trim();
}
