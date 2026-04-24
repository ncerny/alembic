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
    const token = this.auth.getAccessToken();
    if (!token) {
      throw new Error(
        "Not authenticated to Microsoft 365. " +
        `Run: ${this.auth.getLoginCommand()}`,
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

    const response = await requestUrl({
      url,
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
    });

    if (response.status !== 200) {
      throw new Error(`Graph API error: ${response.status} ${response.text}`);
    }

    const data = response.json as CalendarViewResponse;
    return data.value || [];
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
