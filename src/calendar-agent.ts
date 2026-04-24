import { requestUrl } from "obsidian";
import type { CalendarEvent, GraphAttendee } from "./types";

const REQUEST_TIMEOUT_MS = 30_000;

export class CalendarAgent {
  private flowUrl: string;

  constructor(flowUrl: string) {
    this.flowUrl = flowUrl;
  }

  updateFlowUrl(url: string): void {
    this.flowUrl = url;
  }

  isConfigured(): boolean {
    return !!this.flowUrl;
  }

  /**
   * Fetch today's calendar events from the Power Automate flow.
   */
  async getCalendarEvents(
    startDate?: Date,
    endDate?: Date,
  ): Promise<CalendarEvent[]> {
    if (!this.flowUrl) {
      throw new Error(
        "Calendar flow URL not configured. Set it in Alembic settings.",
      );
    }

    const start = startDate || todayStart();
    const end = endDate || todayEnd();

    const response = await requestUrl({
      url: this.flowUrl,
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        startDateTime: start.toISOString(),
        endDateTime: end.toISOString(),
      }),
      throw: false,
    });

    if (response.status !== 200) {
      throw new Error(
        `Calendar flow returned ${response.status}: ${response.text.substring(0, 200)}`,
      );
    }

    const data = response.json;
    const rawEvents: any[] = Array.isArray(data)
      ? data
      : Array.isArray(data?.value)
        ? data.value
        : [];

    if (rawEvents.length === 0) {
      console.log("[alembic] Flow returned 0 events");
    }

    return rawEvents.map(normalizeEvent);
  }
}

/**
 * Normalize event from Outlook connector format (PascalCase) to our
 * CalendarEvent interface (camelCase). Handles both casings for resilience.
 */
function normalizeEvent(raw: any): CalendarEvent {
  const subject = raw.Subject || raw.subject || "";

  const startDt =
    raw.Start?.DateTime || raw.start?.dateTime || raw.Start || raw.start || "";
  const startTz =
    raw.Start?.TimeZone || raw.start?.timeZone || "UTC";
  const endDt =
    raw.End?.DateTime || raw.end?.dateTime || raw.End || raw.end || "";
  const endTz =
    raw.End?.TimeZone || raw.end?.timeZone || "UTC";

  const rawAttendees = raw.Attendees || raw.attendees || [];
  const attendees: GraphAttendee[] = rawAttendees.map((a: any) => ({
    emailAddress: {
      name: a.EmailAddress?.Name || a.emailAddress?.name || a.name || "",
      address:
        a.EmailAddress?.Address || a.emailAddress?.address || a.email || "",
    },
    type: ((a.Type || a.type || "required") as string).toLowerCase() as
      | "required"
      | "optional"
      | "resource",
    status: (a.Status || a.status)
      ? {
          response: a.Status?.Response || a.status?.response || "",
          time: a.Status?.Time || a.status?.time,
        }
      : undefined,
  }));

  const orgName =
    raw.Organizer?.EmailAddress?.Name ||
    raw.organizer?.emailAddress?.name ||
    "";
  const orgEmail =
    raw.Organizer?.EmailAddress?.Address ||
    raw.organizer?.emailAddress?.address ||
    "";

  const joinUrl =
    raw.OnlineMeetingUrl ||
    raw.onlineMeeting?.joinUrl ||
    raw.onlineMeetingUrl ||
    "";

  const locationName =
    raw.Location?.DisplayName || raw.location?.displayName || "";

  const bodyContent =
    raw.Body?.Content || raw.body?.content || raw.BodyPreview || "";
  const bodyType = raw.Body?.ContentType || raw.body?.contentType || "text";

  return {
    subject,
    start: {
      dateTime: typeof startDt === "string" ? startDt : String(startDt),
      timeZone: startTz,
    },
    end: {
      dateTime: typeof endDt === "string" ? endDt : String(endDt),
      timeZone: endTz,
    },
    attendees,
    organizer:
      orgName || orgEmail
        ? { emailAddress: { name: orgName, address: orgEmail } }
        : undefined,
    onlineMeeting: joinUrl ? { joinUrl } : undefined,
    location: locationName ? { displayName: locationName } : undefined,
    body: bodyContent
      ? { contentType: bodyType, content: bodyContent }
      : undefined,
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
