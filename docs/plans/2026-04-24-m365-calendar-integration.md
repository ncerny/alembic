# M365 Calendar Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Integrate Microsoft Graph API to pull calendar events, meeting attendees, and schedule from Outlook/Teams — auto-creating people documents and pre-populating meeting context — using Azure CLI for auth (no app registration, no new dependencies).

**Architecture:** Uses `az account get-access-token` for Microsoft Graph tokens (same pattern as existing `gh auth token` for Copilot). Calls `/me/calendarView` via Obsidian's `requestUrl` to get today's meetings. A `CalendarSync` module polls on interval, a `PeopleManager` auto-creates vault notes for attendees, and the `MeetingController` pre-populates meeting data from calendar events when recording starts.

**Tech Stack:** Azure CLI (`az`), Microsoft Graph REST API v1.0, Obsidian Vault API, `requestUrl`

---

## Context & Constraints

### Environment
- Corporate proxy intercepts HTTPS with self-signed cert
- `REQUESTS_CA_BUNDLE` must be set for `az` CLI calls → use `/Users/you/.config/opencode/corp-cacerts.pem`
- `NODE_EXTRA_CA_CERTS` already set for Node/Electron → Obsidian's `requestUrl` should handle Graph API calls
- Kerberos SSO extension configured via JAMF → `az login` auto-authenticates in browser
- `az` is at `/opt/homebrew/bin/az` (same path-finding pattern as `node`/`gh` in copilot-sdk.ts)

### Auth Pattern (mirrors existing `gh auth token`)
```
az account get-access-token --resource-type ms-graph --query accessToken -o tsv
```
- No app registration needed — uses Microsoft's first-party Azure CLI client
- Delegated permissions only — acts as the signed-in user
- `Calendars.Read` is user-consentable by default (no admin consent)
- Token auto-refreshes; if expired, plugin prompts user to run `az login`

### Graph API Endpoint
```
GET https://graph.microsoft.com/v1.0/me/calendarView
  ?startDateTime={today}T00:00:00Z
  &endDateTime={today}T23:59:59Z
  &$select=subject,start,end,attendees,onlineMeeting,body,location,organizer
  &$orderby=start/dateTime
```

### People Note Convention
- Folder: `People/`
- Naming: `Last, First.md` (matches existing vault-vocab patterns)
- Frontmatter: `type: person`, `email`, `aliases`

### Files to Create
| File | Purpose |
|------|---------|
| `src/m365-auth.ts` | Azure CLI token acquisition, az binary discovery |
| `src/graph-client.ts` | Graph API HTTP calls via `requestUrl` |
| `src/people-manager.ts` | Auto-create/find people notes in vault |
| `src/calendar-sync.ts` | Calendar polling, meeting matching, data pre-population |

### Files to Modify
| File | Changes |
|------|---------|
| `src/types.ts` | Add `CalendarEvent`, `GraphAttendee`, `PersonNote`, settings fields |
| `src/settings.ts` | Add M365 connection section, people folder setting |
| `src/meeting-view.ts` | Add meeting selector dropdown, connection status |
| `src/meeting-controller.ts` | Wire calendar data into recording pipeline |
| `main.ts` | Initialize CalendarSync, register commands |
| `styles.css` | Styles for meeting selector, connection status |
| `esbuild.config.mjs` | No changes needed (no new external deps) |

### No Tests
This project has no test framework configured. Verification is done via `npm run build`.

---

## Task 1: Add Types and Interfaces

**Files:**
- Modify: `src/types.ts`

**Step 1: Add Graph API types and settings fields to `src/types.ts`**

Add these types after the existing `DependencyIssue` interface:

```typescript
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
```

Add `m365Connected` and `peopleFolderPath` to the `MeetingNotesSettings` interface:

```typescript
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
```

**Step 2: Verify build**

Run: `npm run build`
Expected: Successful build (no type errors)

**Step 3: Commit**

```bash
git add src/types.ts
git commit -m "feat: add Graph API types and calendar settings"
```

---

## Task 2: M365 Auth Module

**Files:**
- Create: `src/m365-auth.ts`

**Step 1: Create `src/m365-auth.ts`**

This module discovers the `az` CLI binary and acquires Microsoft Graph tokens. It follows the same pattern as `copilot-sdk.ts` which finds `node`/`gh` binaries by checking known paths.

```typescript
import { execFileSync } from "child_process";
import { existsSync } from "fs";

const AZ_PATHS = [
  "/opt/homebrew/bin/az",
  "/usr/local/bin/az",
  "/usr/bin/az",
];

// Corporate proxy CA cert — az CLI needs REQUESTS_CA_BUNDLE
const CA_CERT_PATHS = [
  `${process.env.HOME}/.config/opencode/corp-cacerts.pem`,
  `${process.env.HOME}/certs/cacert.pem`,
];

export class M365Auth {
  private azPath: string | null = null;
  private caCertPath: string | null = null;

  constructor() {
    this.azPath = AZ_PATHS.find((p) => existsSync(p)) || null;
    this.caCertPath = CA_CERT_PATHS.find((p) => existsSync(p)) ||
      process.env.REQUESTS_CA_BUNDLE || null;
  }

  isAvailable(): boolean {
    return this.azPath !== null;
  }

  /**
   * Get a Microsoft Graph access token via Azure CLI.
   * Returns null if not logged in or az is unavailable.
   */
  getAccessToken(): string | null {
    if (!this.azPath) return null;

    try {
      const env: Record<string, string> = { ...process.env } as Record<string, string>;
      if (this.caCertPath) {
        env.REQUESTS_CA_BUNDLE = this.caCertPath;
      }

      const token = execFileSync(this.azPath, [
        "account", "get-access-token",
        "--resource-type", "ms-graph",
        "--query", "accessToken",
        "-o", "tsv",
      ], {
        encoding: "utf-8",
        timeout: 10000,
        env,
      }).trim();

      return token || null;
    } catch (err) {
      console.error("[alembic] Failed to get M365 token:", err);
      return null;
    }
  }

  /**
   * Check if the user is logged in to Azure CLI.
   */
  isLoggedIn(): boolean {
    if (!this.azPath) return false;

    try {
      const env: Record<string, string> = { ...process.env } as Record<string, string>;
      if (this.caCertPath) {
        env.REQUESTS_CA_BUNDLE = this.caCertPath;
      }

      execFileSync(this.azPath, ["account", "show"], {
        encoding: "utf-8",
        timeout: 5000,
        env,
      });
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Get the login command for the user to run.
   */
  getLoginCommand(): string {
    return "az login --scope https://graph.microsoft.com/.default";
  }

  getAzPath(): string | null {
    return this.azPath;
  }
}
```

**Step 2: Verify build**

Run: `npm run build`
Expected: Successful build

**Step 3: Commit**

```bash
git add src/m365-auth.ts
git commit -m "feat: add M365 auth module using Azure CLI"
```

---

## Task 3: Graph Client

**Files:**
- Create: `src/graph-client.ts`

**Step 1: Create `src/graph-client.ts`**

Thin wrapper around `requestUrl` for Microsoft Graph API calls. Returns typed calendar events.

```typescript
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
```

**Step 2: Verify build**

Run: `npm run build`
Expected: Successful build

**Step 3: Commit**

```bash
git add src/graph-client.ts
git commit -m "feat: add Graph client for calendar view API"
```

---

## Task 4: People Manager

**Files:**
- Create: `src/people-manager.ts`

**Step 1: Create `src/people-manager.ts`**

Creates and finds people notes in the vault. Handles the "Display Name" → "Last, First" conversion. Checks for existing notes before creating duplicates.

```typescript
import { type App, TFile, TFolder, normalizePath } from "obsidian";
import type { GraphAttendee } from "./types";

export class PeopleManager {
  private app: App;
  private folderPath: string;

  constructor(app: App, folderPath: string) {
    this.app = app;
    this.folderPath = folderPath;
  }

  /**
   * Ensure people notes exist for all attendees.
   * Returns the list of vault names (for vocabulary hints).
   */
  async ensurePeopleNotes(attendees: GraphAttendee[]): Promise<string[]> {
    await this.ensureFolder();

    const createdNames: string[] = [];

    for (const attendee of attendees) {
      const displayName = attendee.emailAddress.name;
      const email = attendee.emailAddress.address;

      if (!displayName || !email) continue;

      const vaultName = this.toVaultName(displayName);
      if (!vaultName) continue;

      const existing = this.findPersonNote(vaultName, email);
      if (existing) {
        createdNames.push(existing.basename);
        continue;
      }

      // Create a new person note
      const filePath = normalizePath(`${this.folderPath}/${vaultName}.md`);
      const content = this.buildPersonNote(displayName, email);

      try {
        await this.app.vault.create(filePath, content);
        createdNames.push(vaultName);
        console.log(`[alembic] Created person note: ${filePath}`);
      } catch (err) {
        // File may already exist — race condition or naming overlap
        console.warn(`[alembic] Could not create ${filePath}:`, err);
      }
    }

    return createdNames;
  }

  /**
   * Convert "First Last" display name to "Last, First" vault name.
   * Handles multi-part last names and single names.
   */
  toVaultName(displayName: string): string | null {
    const trimmed = displayName.trim();
    if (!trimmed) return null;

    // Already in "Last, First" format
    if (trimmed.includes(",")) return trimmed;

    const parts = trimmed.split(/\s+/);
    if (parts.length === 1) return parts[0];

    // "First Last" → "Last, First"
    const first = parts.slice(0, -1).join(" ");
    const last = parts[parts.length - 1];
    return `${last}, ${first}`;
  }

  /**
   * Find an existing person note by vault name or email.
   */
  private findPersonNote(vaultName: string, email: string): TFile | null {
    const folderPath = normalizePath(this.folderPath);
    const folder = this.app.vault.getAbstractFileByPath(folderPath);
    if (!(folder instanceof TFolder)) return null;

    const target = vaultName.toLowerCase();
    const emailLower = email.toLowerCase();

    for (const child of folder.children) {
      if (!(child instanceof TFile) || child.extension !== "md") continue;

      // Match by basename
      if (child.basename.toLowerCase() === target) return child;

      // Match by email in filename (fallback)
      if (child.basename.toLowerCase().includes(emailLower.split("@")[0])) {
        return child;
      }
    }

    return null;
  }

  private buildPersonNote(displayName: string, email: string): string {
    const parts: string[] = [];
    parts.push("---");
    parts.push("type: person");
    parts.push(`email: "${email}"`);
    parts.push(`aliases: ["${displayName}"]`);
    parts.push("---");
    parts.push("");
    parts.push(`# ${displayName}`);
    parts.push("");
    return parts.join("\n");
  }

  private async ensureFolder(): Promise<void> {
    const folderPath = normalizePath(this.folderPath);
    const existing = this.app.vault.getAbstractFileByPath(folderPath);
    if (!existing) {
      await this.app.vault.createFolder(folderPath);
    }
  }
}
```

**Step 2: Verify build**

Run: `npm run build`
Expected: Successful build

**Step 3: Commit**

```bash
git add src/people-manager.ts
git commit -m "feat: add people manager for auto-creating vault notes"
```

---

## Task 5: Calendar Sync Module

**Files:**
- Create: `src/calendar-sync.ts`

**Step 1: Create `src/calendar-sync.ts`**

Orchestrates calendar polling, caches today's events, matches current meeting, and provides data for the UI and recording pipeline.

```typescript
import type { App } from "obsidian";
import type { M365Auth } from "./m365-auth";
import { GraphClient } from "./graph-client";
import { PeopleManager } from "./people-manager";
import type { CalendarEvent, GraphAttendee } from "./types";

export class CalendarSync {
  private auth: M365Auth;
  private graphClient: GraphClient;
  private peopleManager: PeopleManager;
  private events: CalendarEvent[] = [];
  private lastFetch: number = 0;
  private listeners: ((events: CalendarEvent[]) => void)[] = [];

  constructor(auth: M365Auth, app: App, peopleFolderPath: string) {
    this.auth = auth;
    this.graphClient = new GraphClient(auth);
    this.peopleManager = new PeopleManager(app, peopleFolderPath);
  }

  onEventsUpdate(listener: (events: CalendarEvent[]) => void): void {
    this.listeners.push(listener);
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

      // Auto-create people notes for all attendees
      const allAttendees = this.getAllAttendees();
      if (allAttendees.length > 0) {
        await this.peopleManager.ensurePeopleNotes(allAttendees);
      }

      this.emitEvents();
      return this.events;
    } catch (err) {
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
    // Simple HTML tag stripping — good enough for meeting agendas
    return event.body.content
      .replace(/<[^>]*>/g, " ")
      .replace(/&nbsp;/g, " ")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/\s+/g, " ")
      .trim();
  }

  getEvents(): CalendarEvent[] {
    return this.events;
  }

  isConnected(): boolean {
    return this.auth.isAvailable() && this.auth.getAccessToken() !== null;
  }

  isAzAvailable(): boolean {
    return this.auth.isAvailable();
  }

  getLoginCommand(): string {
    return this.auth.getLoginCommand();
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
```

**Step 2: Verify build**

Run: `npm run build`
Expected: Successful build

**Step 3: Commit**

```bash
git add src/calendar-sync.ts
git commit -m "feat: add calendar sync with polling and people management"
```

---

## Task 6: Update Settings UI

**Files:**
- Modify: `src/settings.ts`

**Step 1: Add M365 connection section and people folder setting**

Add a new section to the settings tab after the existing vocabulary hints section. This shows connection status, login instructions, and the people folder path.

The settings tab needs the `CalendarSync` instance to check connection status. Pass it via the plugin reference (the plugin will expose `calendarSync` as a property — done in Task 8).

Add after the vocabulary hints `Setting`:

```typescript
// --- Microsoft 365 Integration ---
containerEl.createEl("h3", { text: "Microsoft 365 Integration" });

// Connection status
const m365Status = containerEl.createDiv({ cls: "setting-item-description" });
const calendarSync = this.plugin.calendarSync;
if (!calendarSync?.isAzAvailable()) {
  m365Status.innerHTML = `<p>⛔ Azure CLI not found. Install: <code>brew install azure-cli</code></p>`;
} else if (!calendarSync?.isConnected()) {
  m365Status.innerHTML = `
    <p>⚠️ Not connected to Microsoft 365.</p>
    <p>Run in terminal: <code>${calendarSync.getLoginCommand()}</code></p>
  `;
} else {
  m365Status.innerHTML = `<p>✅ Connected to Microsoft 365</p>`;
}

// People folder
new Setting(containerEl)
  .setName("People folder")
  .setDesc("Folder where person notes are auto-created from meeting attendees")
  .addText((text) => {
    text.setPlaceholder("People");
    text.setValue(this.plugin.settings.peopleFolderPath);
    text.onChange(async (value) => {
      this.plugin.settings.peopleFolderPath = value || "People";
      await this.plugin.saveSettings();
    });
  });

// Calendar polling interval
new Setting(containerEl)
  .setName("Calendar polling interval")
  .setDesc("How often to refresh calendar events (in minutes)")
  .addText((text) => {
    text.setPlaceholder("5");
    text.setValue(String(this.plugin.settings.calendarPollingMinutes));
    text.onChange(async (value) => {
      const num = parseInt(value) || 5;
      this.plugin.settings.calendarPollingMinutes = Math.max(1, Math.min(60, num));
      await this.plugin.saveSettings();
    });
  });
```

**Step 2: Verify build**

Run: `npm run build`
Expected: May fail until Task 8 adds `calendarSync` to the plugin class. That's OK — this task can be committed alongside Task 8.

**Step 3: Commit** (deferred to Task 8)

---

## Task 7: Update Meeting View

**Files:**
- Modify: `src/meeting-view.ts`
- Modify: `styles.css`

**Step 1: Add meeting selector and connection status to meeting view**

Add a calendar events section between the status indicator and the meeting title input. When connected, shows today's meetings as clickable items. When a meeting is selected, auto-populates the title input with the meeting subject.

Key additions to `MeetingView`:
- A `calendarSection` div showing connection status or today's meetings
- A dropdown/list of meetings with times and attendee count
- Clicking a meeting fills in the title and stores the selected event
- A `selectedEvent` property for the controller to access

Add new private fields:

```typescript
private calendarSection: HTMLElement | null = null;
private selectedEvent: CalendarEvent | null = null;
```

In `onOpen()`, after the warnings section and before the title input, add:

```typescript
// Calendar events section
this.calendarSection = container.createDiv({ cls: "calendar-section" });
this.renderCalendarSection();

// Listen for calendar updates
if (this.plugin.calendarSync) {
  this.plugin.calendarSync.onEventsUpdate(() => this.renderCalendarSection());
}
```

Add the `renderCalendarSection` method:

```typescript
private renderCalendarSection(): void {
  if (!this.calendarSection) return;
  this.calendarSection.empty();

  const calendarSync = this.plugin.calendarSync;
  if (!calendarSync || !calendarSync.isAzAvailable()) return;

  if (!calendarSync.isConnected()) {
    const hint = this.calendarSection.createDiv({ cls: "calendar-hint" });
    hint.setText("📅 Connect M365 for auto-populated meetings");
    return;
  }

  const events = calendarSync.getEvents();
  if (events.length === 0) {
    const hint = this.calendarSection.createDiv({ cls: "calendar-hint" });
    hint.setText("📅 No meetings today");
    return;
  }

  const label = this.calendarSection.createDiv({ cls: "calendar-label" });
  label.setText("📅 Today's meetings:");

  for (const event of events) {
    const startTime = new Date(event.start.dateTime + "Z");
    const endTime = new Date(event.end.dateTime + "Z");
    const timeStr = `${formatTime(startTime)}–${formatTime(endTime)}`;
    const attendeeCount = event.attendees.length;
    const isTeams = !!event.onlineMeeting?.joinUrl;

    const row = this.calendarSection.createDiv({
      cls: `calendar-event${this.selectedEvent === event ? " selected" : ""}`,
    });

    const timeEl = row.createSpan({ cls: "event-time", text: timeStr });
    const titleEl = row.createSpan({ cls: "event-title", text: event.subject });
    const metaEl = row.createSpan({
      cls: "event-meta",
      text: `${attendeeCount} attendees${isTeams ? " • Teams" : ""}`,
    });

    row.addEventListener("click", () => {
      this.selectedEvent = event;
      if (this.titleInput) {
        this.titleInput.value = event.subject;
      }
      this.renderCalendarSection();
    });
  }
}
```

Add `formatTime` helper (outside the class):

```typescript
function formatTime(date: Date): string {
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}
```

Expose the selected event for the controller:

```typescript
getSelectedEvent(): CalendarEvent | null {
  return this.selectedEvent;
}
```

Update `onStop()` to pass the selected event:

```typescript
private async onStop(): Promise<void> {
  const title = this.titleInput?.value || "";
  const notes = this.notesArea?.value || "";
  await this.plugin.controller.stopAndProcess(title, notes, this.selectedEvent ?? undefined);
}
```

**Step 2: Add CSS styles to `styles.css`**

```css
/* Calendar section */
.meeting-view-container .calendar-section {
  margin-bottom: 4px;
}

.meeting-view-container .calendar-hint {
  font-size: 0.8em;
  color: var(--text-faint);
  padding: 4px 0;
}

.meeting-view-container .calendar-label {
  font-size: 0.8em;
  color: var(--text-muted);
  margin-bottom: 4px;
  font-weight: 600;
}

.meeting-view-container .calendar-event {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 8px;
  padding: 6px 8px;
  border-radius: 4px;
  cursor: pointer;
  font-size: 0.85em;
  border: 1px solid transparent;
  transition: background 0.15s, border-color 0.15s;
}

.meeting-view-container .calendar-event:hover {
  background: var(--background-modifier-hover);
}

.meeting-view-container .calendar-event.selected {
  background: var(--background-modifier-hover);
  border-color: var(--interactive-accent);
}

.meeting-view-container .event-time {
  color: var(--text-muted);
  font-family: var(--font-monospace);
  font-size: 0.9em;
  white-space: nowrap;
}

.meeting-view-container .event-title {
  font-weight: 500;
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.meeting-view-container .event-meta {
  color: var(--text-faint);
  font-size: 0.85em;
  width: 100%;
}
```

**Step 3: Verify build**

Run: `npm run build`
Expected: May fail until Task 8 adds `calendarSync` to the plugin. Commit together.

---

## Task 8: Wire Everything Together

**Files:**
- Modify: `main.ts`
- Modify: `src/meeting-controller.ts`

**Step 1: Update `main.ts` to initialize CalendarSync**

Add imports and the `calendarSync` property:

```typescript
import { M365Auth } from "./src/m365-auth";
import { CalendarSync } from "./src/calendar-sync";
```

Add to the class:

```typescript
calendarSync: CalendarSync | null = null;
```

In `onload()`, after `this.controller = new MeetingController(this);`:

```typescript
// Initialize M365 calendar sync
const m365Auth = new M365Auth();
if (m365Auth.isAvailable()) {
  this.calendarSync = new CalendarSync(
    m365Auth,
    this.app,
    this.settings.peopleFolderPath,
  );

  // Initial calendar fetch (non-blocking)
  this.calendarSync.refresh().catch((err) => {
    console.log("[alembic] Calendar sync not available:", err.message);
  });

  // Poll for calendar updates
  const intervalMs = this.settings.calendarPollingMinutes * 60 * 1000;
  this.registerInterval(window.setInterval(() => {
    this.calendarSync?.refresh().catch((err) => {
      console.warn("[alembic] Calendar refresh failed:", err.message);
    });
  }, intervalMs));
}
```

Add a command to manually refresh calendar:

```typescript
this.addCommand({
  id: "refresh-calendar",
  name: "Refresh calendar events",
  callback: async () => {
    if (!this.calendarSync) {
      new Notice("M365 integration not available — Azure CLI not found");
      return;
    }
    try {
      const events = await this.calendarSync.refresh();
      new Notice(`📅 Found ${events.length} events today`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      new Notice(`Calendar refresh failed: ${msg}`, 8000);
    }
  },
});
```

**Step 2: Update `MeetingController.stopAndProcess` to accept calendar event**

Add the optional `CalendarEvent` parameter and use it to enhance the pipeline:

```typescript
async stopAndProcess(
  meetingTitle: string,
  userNotes: string,
  calendarEvent?: CalendarEvent,
): Promise<void> {
```

Before the summarization step, if a calendar event is provided, augment the data:

```typescript
// Augment with calendar data if available
let augmentedTitle = meetingTitle;
let augmentedNotes = userNotes;
let calendarAttendeeNames: string[] = [];

if (calendarEvent) {
  augmentedTitle = augmentedTitle || calendarEvent.subject;

  // Add attendee names for vocabulary/correction
  calendarAttendeeNames = calendarEvent.attendees
    .map((a) => a.emailAddress.name)
    .filter(Boolean);

  // Append agenda as context if available
  if (calendarEvent.body?.content) {
    const bodyText = calendarEvent.body.content
      .replace(/<[^>]*>/g, " ")
      .replace(/\s+/g, " ")
      .trim();
    if (bodyText && bodyText.length > 10) {
      augmentedNotes = augmentedNotes
        ? `${augmentedNotes}\n\n--- Meeting Agenda ---\n${bodyText}`
        : bodyText;
    }
  }
}
```

Pass calendar attendee names as additional vocabulary hints to the recognizer (merged with vault vocab).

**Step 3: Verify build**

Run: `npm run build`
Expected: Successful build. This is the integration point — all tasks come together here.

**Step 4: Commit all integration changes**

```bash
git add main.ts src/meeting-controller.ts src/meeting-view.ts src/settings.ts styles.css
git commit -m "feat: wire M365 calendar integration into plugin pipeline"
```

---

## Task 9: Deploy and Verify

**Files:** None (deployment only)

**Step 1: Production build**

Run: `npm run build`
Expected: Successful build with no warnings

**Step 2: Deploy to plugin directory**

```bash
cp main.js "/Users/you/Documents/Obsidian Vault/.obsidian/plugins/alembic/main.js"
cp styles.css "/Users/you/Documents/Obsidian Vault/.obsidian/plugins/alembic/styles.css"
```

**Step 3: Test Azure CLI token**

```bash
REQUESTS_CA_BUNDLE=~/.config/opencode/corp-cacerts.pem az login --scope https://graph.microsoft.com/.default
REQUESTS_CA_BUNDLE=~/.config/opencode/corp-cacerts.pem az account get-access-token --resource-type ms-graph --query accessToken -o tsv | head -c 20
```
Expected: First 20 chars of a JWT token

**Step 4: Commit deployment**

```bash
git add -A
git commit -m "feat: M365 calendar integration — complete implementation"
```

---

## Dependency Graph

```
Task 1 (Types)
  ├── Task 2 (M365 Auth) ─────┐
  ├── Task 3 (Graph Client) ───┤
  ├── Task 4 (People Manager) ─┤
  └── Task 5 (Calendar Sync) ──┤
                                ├── Task 6 (Settings UI)
                                ├── Task 7 (Meeting View)
                                └── Task 8 (Wire Together)
                                      └── Task 9 (Deploy & Verify)
```

Tasks 2-5 are independent of each other (all depend on Task 1).
Tasks 6-8 depend on Tasks 2-5.
Task 9 depends on all previous tasks.
