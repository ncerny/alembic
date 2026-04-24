import { requestUrl } from "obsidian";
import type { M365Auth } from "./m365-auth";
import type { CalendarEvent, GraphAttendee } from "./types";

const OUTLOOK_API = "https://outlook.office365.com/api/v2.0";

export class GraphClient {
  private auth: M365Auth;

  constructor(auth: M365Auth) {
    this.auth = auth;
  }

  /**
   * Fetch today's calendar events with attendee and online meeting data.
   * Uses Outlook REST API v2.0 (PascalCase), normalizes to camelCase.
   */
  async getCalendarView(
    startDate?: Date,
    endDate?: Date,
  ): Promise<CalendarEvent[]> {
    const token = await this.auth.getAccessToken();
    if (!token) {
      throw new Error(
        "Not authenticated to Microsoft 365. " +
        "Use the Connect button in Alembic settings.",
      );
    }

    const start = startDate || todayStart();
    const end = endDate || todayEnd();

    const params = new URLSearchParams({
      startDateTime: start.toISOString(),
      endDateTime: end.toISOString(),
      $select: "Subject,Start,End,Attendees,Body,Location,Organizer,IsOnlineMeeting,OnlineMeetingUrl",
      $orderby: "Start/DateTime",
    });

    const url = `${OUTLOOK_API}/me/calendarview?${params.toString()}`;

    try {
      const response = await requestUrl({
        url,
        method: "GET",
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/json",
        },
      });

      const data = response.json;
      const rawEvents = data.value || [];
      return rawEvents.map(normalizeEvent);
    } catch (err: any) {
      const status = err?.status || "unknown";
      let detail = "";
      try {
        const body = typeof err?.response === "string" ? JSON.parse(err.response) : err?.json;
        detail = body?.error?.message || body?.error?.code || JSON.stringify(body?.error);
      } catch {
        detail = err?.message || String(err);
      }

      throw new Error(`Calendar API ${status}: ${detail}`);
    }
  }
}

/**
 * Normalize Outlook REST API PascalCase response to our camelCase interfaces.
 */
function normalizeEvent(raw: any): CalendarEvent {
  const attendees: GraphAttendee[] = (raw.Attendees || []).map((a: any) => ({
    emailAddress: {
      name: a.EmailAddress?.Name || "",
      address: a.EmailAddress?.Address || "",
    },
    type: (a.Type || "required").toLowerCase() as "required" | "optional" | "resource",
    status: a.Status ? {
      response: a.Status.Response || "",
      time: a.Status.Time,
    } : undefined,
  }));

  return {
    subject: raw.Subject || "",
    start: {
      dateTime: raw.Start?.DateTime || "",
      timeZone: raw.Start?.TimeZone || "UTC",
    },
    end: {
      dateTime: raw.End?.DateTime || "",
      timeZone: raw.End?.TimeZone || "UTC",
    },
    attendees,
    onlineMeeting: raw.OnlineMeetingUrl
      ? { joinUrl: raw.OnlineMeetingUrl }
      : undefined,
    organizer: raw.Organizer?.EmailAddress ? {
      emailAddress: {
        name: raw.Organizer.EmailAddress.Name || "",
        address: raw.Organizer.EmailAddress.Address || "",
      },
    } : undefined,
    body: raw.Body ? {
      contentType: raw.Body.ContentType || "",
      content: raw.Body.Content || "",
    } : undefined,
    location: raw.Location?.DisplayName ? {
      displayName: raw.Location.DisplayName,
    } : undefined,
  };
}

function todayStart(): Date {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
}

function todayEnd(): Date {
  const d = new Date();
  d.setHours(23, 59, 59, 999);
  return d;
}
