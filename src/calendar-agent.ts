import { requestUrl } from "obsidian";
import type { CalendarEvent, GraphAttendee } from "./types";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";

const AZ_PATHS = [
  "/opt/homebrew/bin/az",
  "/usr/local/bin/az",
  "/usr/bin/az",
];
const FLOW_RESOURCE = "https://service.flow.microsoft.com";
const FLOW_API_BASE = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple";
const CERT_BUNDLE_PATH = path.join(os.tmpdir(), "alembic-ca-bundle.pem");
const CERT_BUNDLE_MAX_AGE_MS = 24 * 60 * 60 * 1000; // rebuild daily
const RUN_POLL_INTERVAL_MS = 2_000;
const RUN_POLL_TIMEOUT_MS = 30_000;

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

/**
 * Extract the Power Automate flow ID and environment ID from a flow URL.
 * URL format: https://default{tenantIdNoHyphens}.{num}.environment.api.powerplatform.com:443/
 *   powerautomate/automations/direct/workflows/{flowId}/triggers/manual/paths/invoke?...
 */
function parseFlowUrl(url: string): { flowId: string; envId: string } | null {
  try {
    const u = new URL(url);
    // Extract flow ID from path: .../workflows/{flowId}/...
    const wfMatch = u.pathname.match(/\/workflows\/([a-f0-9]+)\//i);
    if (!wfMatch) return null;

    // Extract tenant ID from hostname: default{tenantNoHyphens}.{num}.environment...
    // The env ID format is "Default-{uuid}" where uuid comes from the hostname
    const hostMatch = u.hostname.match(/^default([a-f0-9]+)\./i);
    if (!hostMatch) return null;

    // Reconstruct the UUID with hyphens: 8-4-4-4-12
    const raw = hostMatch[1];
    const uuid = `${raw.slice(0, 8)}-${raw.slice(8, 12)}-${raw.slice(12, 16)}-${raw.slice(16, 20)}-${raw.slice(20, 32)}`;
    return { flowId: wfMatch[1], envId: `Default-${uuid}` };
  } catch {
    return null;
  }
}

export class CalendarAgent {
  private flowUrl: string;
  private flowId: string | null = null;
  private envId: string | null = null;

  constructor(flowUrl: string) {
    this.flowUrl = flowUrl;
    this.parseIds();
  }

  updateFlowUrl(url: string): void {
    this.flowUrl = url;
    this.parseIds();
  }

  isConfigured(): boolean {
    return !!(this.flowId && this.envId);
  }

  private parseIds(): void {
    const parsed = this.flowUrl ? parseFlowUrl(this.flowUrl) : null;
    this.flowId = parsed?.flowId || null;
    this.envId = parsed?.envId || null;
    if (this.flowUrl && !parsed) {
      console.warn("[alembic] Could not parse flow URL:", this.flowUrl.substring(0, 80));
    }
  }

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
   * Trigger the flow, wait for completion, and return calendar events.
   * Uses the Flow Management API (Bearer auth) instead of the HTTP trigger
   * endpoint (SAS auth), since SAS is disabled by tenant policy.
   */
  async getCalendarEvents(): Promise<CalendarEvent[]> {
    if (!this.flowId || !this.envId) {
      throw new Error(
        "Calendar flow URL not configured. Set it in Alembic settings.",
      );
    }

    const token = await this.getBearerToken();
    const baseUrl = `${FLOW_API_BASE}/environments/${this.envId}/flows/${this.flowId}`;

    // 1. Trigger the flow (dates are calculated inside the flow via utcNow())
    const triggerResp = await requestUrl({
      url: `${baseUrl}/triggers/manual/run?api-version=2016-11-01`,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${token}`,
      },
      body: "{}",
      throw: false,
    });

    if (triggerResp.status !== 200 && triggerResp.status !== 202) {
      throw new Error(
        `Flow trigger failed (${triggerResp.status}): ${triggerResp.text.substring(0, 200)}`,
      );
    }

    // 2. Poll for the latest run to complete
    const runId = await this.pollForCompletion(baseUrl, token);

    // 3. Read the calendar action outputs
    return await this.readRunOutputs(baseUrl, runId, token);
  }

  private async pollForCompletion(baseUrl: string, token: string): Promise<string> {
    const start = Date.now();

    while (Date.now() - start < RUN_POLL_TIMEOUT_MS) {
      const resp = await requestUrl({
        url: `${baseUrl}/runs?$top=1&api-version=2016-11-01`,
        method: "GET",
        headers: { "Authorization": `Bearer ${token}` },
        throw: false,
      });

      if (resp.status === 200) {
        const runs = resp.json?.value || [];
        if (runs.length > 0) {
          const run = runs[0];
          const status = run.properties?.status;
          if (status === "Succeeded") {
            return run.name;
          }
          if (status === "Failed" || status === "Cancelled") {
            throw new Error(`Flow run ${status}`);
          }
        }
      }

      await sleep(RUN_POLL_INTERVAL_MS);
    }

    throw new Error("Flow run timed out after 30s");
  }

  private async readRunOutputs(
    baseUrl: string,
    runId: string,
    token: string,
  ): Promise<CalendarEvent[]> {
    const resp = await requestUrl({
      url: `${baseUrl}/runs/${runId}/actions?api-version=2016-11-01`,
      method: "GET",
      headers: { "Authorization": `Bearer ${token}` },
      throw: false,
    });

    if (resp.status !== 200) {
      throw new Error(`Failed to read run actions: ${resp.status}`);
    }

    // Find the calendar action
    const actions = resp.json?.value || [];
    const calAction = actions.find(
      (a: any) => a.name?.startsWith("Get_calendar") && a.properties?.status === "Succeeded",
    );

    if (!calAction) {
      console.log("[alembic] No calendar action found in run");
      return [];
    }

    // Outputs may be inline or behind an outputsLink
    let events: any[] = [];
    const outputs = calAction.properties?.outputs;
    if (outputs?.body?.value) {
      events = outputs.body.value;
    } else if (calAction.properties?.outputsLink?.uri) {
      // Fetch full outputs from the link (this URL includes its own SAS auth)
      const linkResp = await requestUrl({
        url: calAction.properties.outputsLink.uri,
        method: "GET",
        throw: false,
      });
      if (linkResp.status === 200) {
        const data = linkResp.json;
        events = data?.body?.value || [];
      }
    }

    console.log(`[alembic] Flow returned ${events.length} events`);
    return events.map(normalizeEvent);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Normalize event from Office 365 Outlook connector V3 format.
 * V3 uses camelCase fields and semicolon-separated email strings for attendees.
 */
function normalizeEvent(raw: any): CalendarEvent {
  const subject = raw.Subject || raw.subject || "";

  // V3 uses flat date strings; Graph API uses { dateTime, timeZone } objects
  const startRaw = raw.Start?.DateTime || raw.start?.dateTime || raw.start || raw.Start || "";
  const startTz = raw.Start?.TimeZone || raw.start?.timeZone || raw.timeZone || "UTC";
  const endRaw = raw.End?.DateTime || raw.end?.dateTime || raw.end || raw.End || "";
  const endTz = raw.End?.TimeZone || raw.end?.timeZone || raw.timeZone || "UTC";

  // V3 returns attendees as semicolon-separated email strings
  const attendees = parseAttendees(
    raw.requiredAttendees || raw.RequiredAttendees,
    raw.optionalAttendees || raw.OptionalAttendees,
    raw.resourceAttendees || raw.ResourceAttendees,
    // Also handle Graph-style array format
    raw.Attendees || raw.attendees,
  );

  // Organizer: V3 uses a plain email string, Graph uses { emailAddress: { name, address } }
  const orgRaw = raw.organizer || raw.Organizer || "";
  let organizer: CalendarEvent["organizer"] = undefined;
  if (typeof orgRaw === "string" && orgRaw) {
    organizer = { emailAddress: { name: "", address: orgRaw } };
  } else if (orgRaw?.emailAddress || orgRaw?.EmailAddress) {
    const ea = orgRaw.emailAddress || orgRaw.EmailAddress;
    organizer = {
      emailAddress: { name: ea.Name || ea.name || "", address: ea.Address || ea.address || "" },
    };
  }

  const locationName =
    raw.location || raw.Location?.DisplayName || raw.location?.displayName || "";
  const locationStr = typeof locationName === "string" ? locationName : "";

  const bodyContent =
    raw.body || raw.Body?.Content || raw.body?.content || raw.BodyPreview || "";
  const bodyType = typeof bodyContent === "string" && bodyContent.includes("<")
    ? "html"
    : raw.Body?.ContentType || raw.body?.contentType || "text";

  return {
    subject,
    start: {
      dateTime: typeof startRaw === "string" ? startRaw : String(startRaw),
      timeZone: startTz,
    },
    end: {
      dateTime: typeof endRaw === "string" ? endRaw : String(endRaw),
      timeZone: endTz,
    },
    attendees,
    organizer,
    onlineMeeting: undefined, // V3 doesn't expose join URL directly
    location: locationStr ? { displayName: locationStr } : undefined,
    body: bodyContent
      ? { contentType: bodyType, content: typeof bodyContent === "string" ? bodyContent : "" }
      : undefined,
  };
}

/**
 * Parse attendees from V3's semicolon-separated email strings,
 * or from Graph API's array-of-objects format.
 */
function parseAttendees(
  required?: string | any[],
  optional?: string | any[],
  resource?: string | any[],
  graphStyle?: any[],
): GraphAttendee[] {
  const result: GraphAttendee[] = [];

  // Handle V3 semicolon-separated strings
  if (typeof required === "string") {
    for (const email of splitEmails(required)) {
      result.push({
        emailAddress: { name: "", address: email },
        type: "required",
      });
    }
  }
  if (typeof optional === "string") {
    for (const email of splitEmails(optional)) {
      result.push({
        emailAddress: { name: "", address: email },
        type: "optional",
      });
    }
  }
  if (typeof resource === "string") {
    for (const email of splitEmails(resource)) {
      result.push({
        emailAddress: { name: "", address: email },
        type: "resource",
      });
    }
  }

  // Handle Graph-style array format
  if (Array.isArray(graphStyle) && result.length === 0) {
    for (const a of graphStyle) {
      result.push({
        emailAddress: {
          name: a.EmailAddress?.Name || a.emailAddress?.name || a.name || "",
          address: a.EmailAddress?.Address || a.emailAddress?.address || a.email || "",
        },
        type: ((a.Type || a.type || "required") as string).toLowerCase() as
          | "required"
          | "optional"
          | "resource",
      });
    }
  }

  return result;
}

function splitEmails(s: string): string[] {
  return s
    .split(";")
    .map((e) => e.trim())
    .filter(Boolean);
}
