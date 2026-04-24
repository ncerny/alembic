import { requestUrl } from "obsidian";
import type { M365Auth } from "./m365-auth";
import type { CalendarEvent, CalendarViewResponse } from "./types";

const GRAPH_BASE = "https://graph.microsoft.com/v1.0";

export class GraphClient {
  private auth: M365Auth;

  constructor(auth: M365Auth) {
    this.auth = auth;
  }

  /**
   * Fetch today's calendar events with attendee and online meeting data.
   * Returns events sorted by start time.
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
      $select: "subject,start,end,attendees,onlineMeeting,body,location,organizer",
      $orderby: "start/dateTime",
    });

    const url = `${GRAPH_BASE}/me/calendarView?${params.toString()}`;

    try {
      const response = await requestUrl({
        url,
        method: "GET",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
      });

      const data = response.json as CalendarViewResponse;
      return data.value || [];
    } catch (err: any) {
      // Obsidian's requestUrl throws on non-200 — extract details
      const status = err?.status || "unknown";
      let detail = "";
      try {
        const body = typeof err?.response === "string" ? JSON.parse(err.response) : err?.json;
        detail = body?.error?.message || body?.error?.code || JSON.stringify(body?.error);
      } catch {
        detail = err?.message || String(err);
      }

      // Log details for diagnostics on 403
      if (status === 403 || String(detail).includes("403")) {
        console.error("[alembic] Graph API 403 — check token scopes");
      }

      throw new Error(`Graph API ${status}: ${detail}`);
    }
  }
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
