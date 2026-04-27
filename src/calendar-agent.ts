import { requestUrl } from "obsidian";
import type { CalendarEvent, GraphAttendee } from "./types";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";

const REQUEST_TIMEOUT_MS = 30_000;
const AZ_PATHS = [
  "/opt/homebrew/bin/az",
  "/usr/local/bin/az",
  "/usr/bin/az",
];
const FLOW_RESOURCE = "https://service.flow.microsoft.com";
const CERT_BUNDLE_PATH = path.join(os.tmpdir(), "alembic-ca-bundle.pem");
const CERT_BUNDLE_MAX_AGE_MS = 24 * 60 * 60 * 1000; // rebuild daily

/**
 * Build a CA bundle from macOS system keychains so `az` can verify
 * corporate proxy certificates that aren't in Python's certifi bundle.
 */
function ensureCertBundle(): string {
  try {
    const stat = fs.statSync(CERT_BUNDLE_PATH);
    if (Date.now() - stat.mtimeMs < CERT_BUNDLE_MAX_AGE_MS) {
      return CERT_BUNDLE_PATH;
    }
  } catch { /* doesn't exist yet */ }

  try {
    const { execFileSync } = require("child_process");
    const keychainCerts = execFileSync(
      "/usr/bin/security",
      ["find-certificate", "-a", "-p",
       "/System/Library/Keychains/SystemRootCertificates.keychain",
       "/Library/Keychains/System.keychain"],
      { encoding: "utf-8", timeout: 10_000 },
    );
    fs.writeFileSync(CERT_BUNDLE_PATH, keychainCerts, "utf-8");
    console.log("[alembic] Built CA bundle from system keychains");
    return CERT_BUNDLE_PATH;
  } catch (e) {
    console.warn("[alembic] Failed to build CA bundle:", e);
    return "";
  }
}

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
   * Get a Bearer token for Power Automate via Azure CLI.
   */
  private async getBearerToken(): Promise<string> {
    const azBin = AZ_PATHS.find((p) => fs.existsSync(p));
    if (!azBin) {
      throw new Error(
        "Azure CLI (az) not found. Install via: brew install azure-cli",
      );
    }

    const certBundle = ensureCertBundle();
    const env: Record<string, string> = { ...process.env } as any;
    if (certBundle) {
      env.REQUESTS_CA_BUNDLE = certBundle;
    }

    const { execFile } = require("child_process");
    return new Promise<string>((resolve, reject) => {
      execFile(
        azBin,
        ["account", "get-access-token", "--resource", FLOW_RESOURCE, "--query", "accessToken", "-o", "tsv"],
        { encoding: "utf-8", timeout: 15_000, env },
        (err: any, stdout: string, stderr: string) => {
          if (err) {
            reject(new Error(`az token failed: ${stderr || err.message}`));
            return;
          }
          const token = stdout.trim();
          if (!token) {
            reject(new Error("az returned empty token. Run: az login"));
            return;
          }
          resolve(token);
        },
      );
    });
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

    const token = await this.getBearerToken();

    // Strip SAS query params — API rejects requests with both SAS and Bearer
    const url = new URL(this.flowUrl);
    url.searchParams.delete("sig");
    url.searchParams.delete("sp");
    url.searchParams.delete("sv");

    const response = await requestUrl({
      url: url.toString(),
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${token}`,
      },
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
