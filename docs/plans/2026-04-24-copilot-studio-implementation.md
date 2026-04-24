# Copilot Studio Direct Line Integration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the broken PKCE OAuth + Outlook REST API calendar integration with a Copilot Studio agent accessed via Direct Line REST API.

**Architecture:** The plugin sends a natural-language message to a Copilot Studio agent via the Direct Line API. The agent (which already has M365 tenant access) fetches calendar events and returns them. The plugin parses the response into `CalendarEvent[]` and feeds it to the existing `CalendarSync`/`PeopleManager`/`MeetingView` pipeline — those components are unchanged.

**Tech Stack:** Direct Line API v3 (REST), Obsidian `requestUrl`, existing TypeScript codebase

---

### Task 1: Update types — remove OAuth, add Direct Line settings

**Files:**
- Modify: `src/types.ts`

**Step 1: Update the settings interface and defaults**

Replace the M365 OAuth token fields with Direct Line fields:

```typescript
export interface MeetingNotesSettings {
  targetApp: string;
  outputFolder: string;
  vocabularyHints: string[];
  peopleFolderPath: string;
  calendarPollingMinutes: number;
  directLineSecret?: string;
  agentPrompt?: string;
}

export const DEFAULT_SETTINGS: MeetingNotesSettings = {
  targetApp: "Microsoft Teams",
  outputFolder: "Meetings",
  vocabularyHints: [],
  peopleFolderPath: "People",
  calendarPollingMinutes: 5,
  agentPrompt: "List all of my calendar events for today. For each event, include: the subject/title, start time in ISO 8601 format, end time in ISO 8601 format, timezone, all attendees with their names and email addresses, organizer name and email, location, and whether it is an online/Teams meeting with the join URL. Return the data as a JSON array.",
};
```

Remove the `CalendarViewResponse` interface (no longer used — Direct Line responses are parsed differently).

Keep `CalendarEvent`, `GraphAttendee` interfaces exactly as-is — they are the data contract consumed by the rest of the app.

**Step 2: Commit**

```bash
git add src/types.ts
git commit -m "refactor: replace OAuth token settings with Direct Line secret

Remove m365RefreshToken, m365AccessToken, m365TokenExpiry from settings.
Add directLineSecret and agentPrompt fields.
Remove CalendarViewResponse interface."
```

---

### Task 2: Create the CopilotAgent Direct Line client

**Files:**
- Create: `src/copilot-agent.ts`
- Delete: `src/m365-auth.ts`
- Delete: `src/graph-client.ts`

**Step 1: Create `src/copilot-agent.ts`**

This is the core new file. It replaces both `m365-auth.ts` (OAuth) and `graph-client.ts` (API calls). It is a stateless HTTP client that talks to the Direct Line API.

```typescript
import { requestUrl } from "obsidian";
import type { CalendarEvent, GraphAttendee } from "./types";

const DIRECT_LINE_BASE = "https://directline.botframework.com/v3/directline";
const POLL_INTERVAL_MS = 1500;
const POLL_TIMEOUT_MS = 30_000;
const MAX_MESSAGES_PER_CONVERSATION = 15;
const TOKEN_LIFETIME_MS = 25 * 60 * 1000; // 25 min (tokens last 30, refresh early)

interface ConversationSession {
  conversationId: string;
  token: string;
  createdAt: number;
  messageCount: number;
}

export class CopilotAgent {
  private secret: string;
  private session: ConversationSession | null = null;

  constructor(secret: string) {
    this.secret = secret;
  }

  updateSecret(secret: string): void {
    this.secret = secret;
    this.session = null;
  }

  isConfigured(): boolean {
    return !!this.secret;
  }

  /**
   * Send a prompt to the Copilot Studio agent and return the response text.
   * Manages conversation lifecycle (create, reuse, rotate).
   */
  async ask(prompt: string): Promise<string> {
    if (!this.secret) {
      throw new Error("Direct Line secret not configured. Set it in Alembic settings.");
    }

    const session = await this.getOrCreateSession();

    // Send the user's message
    await requestUrl({
      url: `${DIRECT_LINE_BASE}/conversations/${session.conversationId}/activities`,
      method: "POST",
      headers: {
        Authorization: `Bearer ${session.token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        type: "message",
        from: { id: "alembic-plugin" },
        text: prompt,
      }),
    });

    session.messageCount++;

    // Poll for the bot's reply
    return this.pollForReply(session);
  }

  /**
   * Send the configured prompt and parse the response into CalendarEvent[].
   */
  async getCalendarEvents(prompt: string): Promise<CalendarEvent[]> {
    const responseText = await this.ask(prompt);
    return parseCalendarResponse(responseText);
  }

  private async getOrCreateSession(): Promise<ConversationSession> {
    if (this.session) {
      const age = Date.now() - this.session.createdAt;
      if (age < TOKEN_LIFETIME_MS && this.session.messageCount < MAX_MESSAGES_PER_CONVERSATION) {
        return this.session;
      }
    }

    // Generate a token from the secret
    const tokenRes = await requestUrl({
      url: `${DIRECT_LINE_BASE}/tokens/generate`,
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.secret}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    });

    const tokenData = tokenRes.json;

    // Start a conversation with the token
    const convRes = await requestUrl({
      url: `${DIRECT_LINE_BASE}/conversations`,
      method: "POST",
      headers: {
        Authorization: `Bearer ${tokenData.token}`,
        "Content-Type": "application/json",
      },
    });

    const convData = convRes.json;

    this.session = {
      conversationId: convData.conversationId,
      token: tokenData.token,
      createdAt: Date.now(),
      messageCount: 0,
    };

    return this.session;
  }

  private async pollForReply(session: ConversationSession): Promise<string> {
    let watermark: string | undefined;
    const deadline = Date.now() + POLL_TIMEOUT_MS;

    while (Date.now() < deadline) {
      const params = watermark ? `?watermark=${watermark}` : "";
      const res = await requestUrl({
        url: `${DIRECT_LINE_BASE}/conversations/${session.conversationId}/activities${params}`,
        method: "GET",
        headers: {
          Authorization: `Bearer ${session.token}`,
          Accept: "application/json",
        },
      });

      const data = res.json;
      watermark = data.watermark;

      // Find bot replies (not from our user ID)
      const botMessages = (data.activities || []).filter(
        (a: any) => a.type === "message" && a.from?.id !== "alembic-plugin",
      );

      if (botMessages.length > 0) {
        // Return the last bot message
        return botMessages[botMessages.length - 1].text || "";
      }

      // Wait before polling again
      await sleep(POLL_INTERVAL_MS);
    }

    throw new Error("Agent did not respond within 30 seconds");
  }
}

/**
 * Parse agent response text into CalendarEvent[].
 * Handles: raw JSON array, JSON in markdown code blocks, or wrapped in an object with a "value"/"events" key.
 */
export function parseCalendarResponse(text: string): CalendarEvent[] {
  // Try to extract JSON from markdown code blocks first
  const codeBlockMatch = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const jsonText = codeBlockMatch ? codeBlockMatch[1].trim() : text.trim();

  // Try parsing the full text as JSON
  let parsed: any;
  try {
    parsed = JSON.parse(jsonText);
  } catch {
    // Try to find a JSON array or object in the text
    const arrayMatch = jsonText.match(/\[[\s\S]*\]/);
    const objectMatch = jsonText.match(/\{[\s\S]*\}/);
    const match = arrayMatch || objectMatch;
    if (!match) {
      console.warn("[alembic] Could not find JSON in agent response:", text.substring(0, 200));
      return [];
    }
    try {
      parsed = JSON.parse(match[0]);
    } catch {
      console.warn("[alembic] Failed to parse extracted JSON:", match[0].substring(0, 200));
      return [];
    }
  }

  // Unwrap common wrapper shapes: { value: [...] }, { events: [...] }
  const events: any[] = Array.isArray(parsed)
    ? parsed
    : Array.isArray(parsed?.value)
      ? parsed.value
      : Array.isArray(parsed?.events)
        ? parsed.events
        : [];

  if (events.length === 0) {
    console.log("[alembic] Agent returned 0 events (or unrecognized format)");
    return [];
  }

  return events.map(normalizeAgentEvent);
}

/**
 * Normalize a calendar event from the agent response to our CalendarEvent interface.
 * Handles various naming conventions (camelCase, PascalCase, snake_case, natural-language keys).
 */
function normalizeAgentEvent(raw: any): CalendarEvent {
  const subject = raw.subject || raw.Subject || raw.title || raw.Title || "";

  const startDt = raw.start?.dateTime || raw.Start?.DateTime || raw.startTime || raw.start_time || raw.start || "";
  const startTz = raw.start?.timeZone || raw.Start?.TimeZone || raw.timeZone || raw.timezone || "UTC";
  const endDt = raw.end?.dateTime || raw.End?.DateTime || raw.endTime || raw.end_time || raw.end || "";
  const endTz = raw.end?.timeZone || raw.End?.TimeZone || raw.timeZone || raw.timezone || "UTC";

  const rawAttendees = raw.attendees || raw.Attendees || [];
  const attendees: GraphAttendee[] = rawAttendees.map((a: any) => {
    // Handle various attendee shapes
    const name = a.emailAddress?.name || a.EmailAddress?.Name || a.name || a.Name || "";
    const address = a.emailAddress?.address || a.EmailAddress?.Address || a.email || a.Email || a.address || "";
    const type = (a.type || a.Type || "required").toLowerCase();
    return {
      emailAddress: { name, address },
      type: type as "required" | "optional" | "resource",
    };
  });

  const organizerName = raw.organizer?.emailAddress?.name || raw.Organizer?.EmailAddress?.Name || raw.organizer?.name || raw.organizerName || "";
  const organizerEmail = raw.organizer?.emailAddress?.address || raw.Organizer?.EmailAddress?.Address || raw.organizer?.email || raw.organizerEmail || "";

  const joinUrl = raw.onlineMeeting?.joinUrl || raw.joinUrl || raw.onlineMeetingUrl || raw.OnlineMeetingUrl || "";
  const locationName = raw.location?.displayName || raw.Location?.DisplayName || raw.location || raw.Location || "";

  const bodyContent = raw.body?.content || raw.Body?.Content || raw.bodyPreview || raw.BodyPreview || "";
  const bodyType = raw.body?.contentType || raw.Body?.ContentType || "text";

  return {
    subject,
    start: { dateTime: typeof startDt === "string" ? startDt : String(startDt), timeZone: startTz },
    end: { dateTime: typeof endDt === "string" ? endDt : String(endDt), timeZone: endTz },
    attendees,
    organizer: organizerName || organizerEmail ? { emailAddress: { name: organizerName, address: organizerEmail } } : undefined,
    onlineMeeting: joinUrl ? { joinUrl } : undefined,
    location: (typeof locationName === "string" && locationName) ? { displayName: locationName } : undefined,
    body: bodyContent ? { contentType: bodyType, content: bodyContent } : undefined,
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
```

**Step 2: Delete old files**

```bash
rm src/m365-auth.ts src/graph-client.ts
```

**Step 3: Commit**

```bash
git add src/copilot-agent.ts
git rm src/m365-auth.ts src/graph-client.ts
git commit -m "feat: add CopilotAgent Direct Line client, remove OAuth + Outlook REST

New src/copilot-agent.ts replaces both m365-auth.ts and graph-client.ts.
Talks to Copilot Studio agent via Direct Line API v3.
Parses natural language responses into CalendarEvent[].
Handles conversation lifecycle, session reuse, and flexible JSON parsing."
```

---

### Task 3: Update CalendarSync to use CopilotAgent

**Files:**
- Modify: `src/calendar-sync.ts`

**Step 1: Replace M365Auth + GraphClient dependencies with CopilotAgent**

The full updated file:

```typescript
import type { App } from "obsidian";
import { CopilotAgent } from "./copilot-agent";
import { PeopleManager } from "./people-manager";
import type { CalendarEvent, GraphAttendee } from "./types";

export class CalendarSync {
  private agent: CopilotAgent;
  private peopleManager: PeopleManager;
  private app: App;
  private events: CalendarEvent[] = [];
  private lastFetch: number = 0;
  private listeners: ((events: CalendarEvent[]) => void)[] = [];
  private _connected = false;
  private agentPrompt: string;

  constructor(agent: CopilotAgent, app: App, peopleFolderPath: string, agentPrompt: string) {
    this.agent = agent;
    this.app = app;
    this.peopleManager = new PeopleManager(app, peopleFolderPath);
    this.agentPrompt = agentPrompt;
  }

  onEventsUpdate(listener: (events: CalendarEvent[]) => void): () => void {
    this.listeners.push(listener);
    return () => {
      this.listeners = this.listeners.filter((l) => l !== listener);
    };
  }

  private emitEvents(): void {
    this.listeners.forEach((l) => l(this.events));
  }

  async refresh(): Promise<CalendarEvent[]> {
    try {
      this.events = await this.agent.getCalendarEvents(this.agentPrompt);
      this.lastFetch = Date.now();
      this._connected = true;

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

  getCurrentOrNextMeeting(): CalendarEvent | null {
    const now = new Date();

    for (const event of this.events) {
      const start = new Date(event.start.dateTime);
      const end = new Date(event.end.dateTime);
      if (now >= start && now <= end) return event;
    }

    for (const event of this.events) {
      const start = new Date(event.start.dateTime);
      if (start > now) return event;
    }

    return null;
  }

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

  getEventBodyText(event: CalendarEvent): string {
    if (!event.body?.content) return "";
    return stripHtml(event.body.content);
  }

  getEvents(): CalendarEvent[] {
    return this.events;
  }

  isConnected(): boolean {
    return this._connected;
  }

  isConfigured(): boolean {
    return this.agent.isConfigured();
  }

  updatePeopleFolderPath(path: string): void {
    this.peopleManager = new PeopleManager(this.app, path);
  }

  updateAgentPrompt(prompt: string): void {
    this.agentPrompt = prompt;
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
```

**Key changes:**
- Constructor takes `CopilotAgent` instead of `M365Auth`
- Constructor takes `agentPrompt` string
- `refresh()` calls `agent.getCalendarEvents(prompt)` instead of `graphClient.getCalendarView()`
- `isConfigured()` delegates to `agent.isConfigured()` (checks for non-empty secret)
- Removed `getAuth()` method (no auth object to expose)
- Added `updateAgentPrompt()` method
- Removed the `"Z"` suffix appended to dateTime in `getCurrentOrNextMeeting()` — the agent's response format may vary

**Step 2: Commit**

```bash
git add src/calendar-sync.ts
git commit -m "refactor: update CalendarSync to use CopilotAgent

Replace M365Auth + GraphClient with CopilotAgent dependency.
Constructor now takes agent and prompt string.
Remove getAuth() method, add updateAgentPrompt()."
```

---

### Task 4: Update settings UI

**Files:**
- Modify: `src/settings.ts`

**Step 1: Replace OAuth buttons with Direct Line secret field**

Replace the entire M365 Integration section (lines 67-107) with:

```typescript
    // --- Microsoft 365 Integration ---
    containerEl.createEl("h3", { text: "Microsoft 365 Integration" });

    new Setting(containerEl)
      .setName("Direct Line secret")
      .setDesc(
        "Paste your Copilot Studio agent's Direct Line secret. " +
        "Find it in Copilot Studio → Settings → Channels → Direct Line.",
      )
      .addText((text) => {
        text.setPlaceholder("Enter Direct Line secret…");
        text.setValue(this.plugin.settings.directLineSecret || "");
        text.inputEl.type = "password";
        text.onChange(async (value) => {
          this.plugin.settings.directLineSecret = value || undefined;
          await this.plugin.saveSettings();
          this.plugin.updateAgent();
        });
      });

    new Setting(containerEl)
      .setName("Agent prompt")
      .setDesc(
        "The message sent to your Copilot Studio agent to request calendar data. " +
        "Customize if your agent expects a specific command or format.",
      )
      .addTextArea((text) => {
        text.setValue(this.plugin.settings.agentPrompt || "");
        text.inputEl.rows = 4;
        text.inputEl.cols = 40;
        text.onChange(async (value) => {
          this.plugin.settings.agentPrompt = value;
          await this.plugin.saveSettings();
          this.plugin.calendarSync.updateAgentPrompt(value);
        });
      });
```

Also update the import at line 1 — remove `Notice` if no longer used (check: the vocab hints section doesn't use it, but we should keep it available for potential future use. Actually, check — `Notice` is imported and used in the OAuth section. After removing OAuth, it's not used in settings anymore. Remove it from the import).

Updated import line:

```typescript
import { App, PluginSettingTab, Setting } from "obsidian";
```

And remove the import of `MeetingNotesPlugin` type reference to `calendarSync.getAuth()` — the settings file no longer needs auth access.

**Step 2: Commit**

```bash
git add src/settings.ts
git commit -m "refactor: replace OAuth UI with Direct Line secret field

Remove Connect/Disconnect buttons and OAuth flow.
Add Direct Line secret (password field) and agent prompt (textarea).
Remove unused Notice import."
```

---

### Task 5: Update main.ts plugin entry point

**Files:**
- Modify: `main.ts`

**Step 1: Replace M365Auth with CopilotAgent wiring**

The key changes:
- Import `CopilotAgent` instead of `M365Auth`/`TokenData`
- Remove all token persistence logic (lines 25-44)
- Create `CopilotAgent` from `directLineSecret` setting
- Update `calendarSync` construction to pass agent + prompt
- Replace `m365Auth.hasRefreshToken()` checks with `agent.isConfigured()`
- Add `updateAgent()` public method (called by settings when secret changes)
- Remove `m365Auth.cancelLogin()` from `onunload()`

Full updated file:

```typescript
import { Notice, Plugin, WorkspaceLeaf } from "obsidian";
import { MeetingNotesSettingTab } from "./src/settings";
import { MeetingView } from "./src/meeting-view";
import { MeetingController } from "./src/meeting-controller";
import { CopilotAgent } from "./src/copilot-agent";
import { CalendarSync } from "./src/calendar-sync";
import {
  DEFAULT_SETTINGS,
  MEETING_VIEW_TYPE,
  type MeetingNotesSettings,
} from "./src/types";

export default class MeetingNotesPlugin extends Plugin {
  settings: MeetingNotesSettings = DEFAULT_SETTINGS;
  controller!: MeetingController;
  calendarSync!: CalendarSync;
  private agent!: CopilotAgent;

  async onload(): Promise<void> {
    await this.loadSettings();

    this.controller = new MeetingController(this);

    // Initialize Direct Line agent
    this.agent = new CopilotAgent(this.settings.directLineSecret || "");
    this.calendarSync = new CalendarSync(
      this.agent,
      this.app,
      this.settings.peopleFolderPath,
      this.settings.agentPrompt || DEFAULT_SETTINGS.agentPrompt!,
    );

    // Initial calendar fetch if configured (non-blocking)
    if (this.agent.isConfigured()) {
      this.calendarSync.refresh().catch((err) => {
        console.log("[alembic] Calendar sync not available:", err.message);
      });
    }

    // Poll for calendar updates
    const intervalMs = this.settings.calendarPollingMinutes * 60 * 1000;
    this.registerInterval(window.setInterval(() => {
      if (this.agent.isConfigured()) {
        this.calendarSync.refresh().catch((err) => {
          console.warn("[alembic] Calendar refresh failed:", err.message);
        });
      }
    }, intervalMs));

    // Register the meeting view
    this.registerView(
      MEETING_VIEW_TYPE,
      (leaf) => new MeetingView(leaf, this),
    );

    // Ribbon icon to open the meeting panel
    this.addRibbonIcon("mic", "Open Alembic", () => {
      this.activateView();
    });

    // Commands
    this.addCommand({
      id: "open-meeting-panel",
      name: "Open meeting panel",
      callback: () => this.activateView(),
    });

    this.addCommand({
      id: "start-recording",
      name: "Start meeting recording",
      callback: () => this.controller.startRecording(),
    });

    this.addCommand({
      id: "stop-recording",
      name: "Stop recording and generate notes",
      callback: () => {
        const view = this.getMeetingView();
        if (view) {
          const title = view.getTitle() || "Meeting";
          const notes = view.getNotes();
          const event = view.getSelectedEvent();
          this.controller.stopAndProcess(title, notes, event ?? undefined);
        }
      },
    });

    this.addCommand({
      id: "refresh-calendar",
      name: "Refresh calendar events",
      callback: async () => {
        if (!this.agent.isConfigured()) {
          new Notice("Direct Line secret not configured — set it in Alembic settings");
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

    // Settings tab
    this.addSettingTab(new MeetingNotesSettingTab(this.app, this));

    // Check dependencies at startup
    const issues = await this.controller.checkDependencies();
    const errors = issues.filter((i) => i.severity === "error");
    if (errors.length > 0) {
      new Notice(
        `Alembic — missing dependencies:\n` +
          errors.map((e) => `• ${e.dependency}: ${e.message}`).join("\n"),
        10000,
      );
    }
  }

  async onunload(): Promise<void> {
    this.app.workspace.detachLeavesOfType(MEETING_VIEW_TYPE);
  }

  /** Called by settings when the Direct Line secret changes. */
  updateAgent(): void {
    this.agent.updateSecret(this.settings.directLineSecret || "");
  }

  async loadSettings(): Promise<void> {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }

  async saveSettings(): Promise<void> {
    await this.saveData(this.settings);
  }

  private async activateView(): Promise<void> {
    const { workspace } = this.app;

    let leaf: WorkspaceLeaf | null = null;
    const leaves = workspace.getLeavesOfType(MEETING_VIEW_TYPE);

    if (leaves.length > 0) {
      leaf = leaves[0];
    } else {
      leaf = workspace.getRightLeaf(false);
      if (leaf) {
        await leaf.setViewState({
          type: MEETING_VIEW_TYPE,
          active: true,
        });
      }
    }

    if (leaf) {
      workspace.revealLeaf(leaf);
    }
  }

  private getMeetingView(): MeetingView | null {
    const leaves = this.app.workspace.getLeavesOfType(MEETING_VIEW_TYPE);
    if (leaves.length > 0) {
      return leaves[0].view as MeetingView;
    }
    return null;
  }
}
```

**Step 2: Commit**

```bash
git add main.ts
git commit -m "refactor: wire up CopilotAgent in plugin entry point

Replace M365Auth with CopilotAgent. Remove all token persistence.
Add updateAgent() method for settings to call when secret changes.
Remove cancelLogin() from onunload()."
```

---

### Task 6: Build, deploy, and verify

**Files:**
- No source changes — build and deploy

**Step 1: Build**

```bash
npm run build
```

Expected: Build succeeds, `main.js` generated.

**Step 2: Deploy to Obsidian plugin directory**

```bash
rm -rf "/Users/you/Documents/Obsidian Vault/.obsidian/plugins/alembic/"
mkdir -p "/Users/you/Documents/Obsidian Vault/.obsidian/plugins/alembic/"
cp main.js manifest.json styles.css "/Users/you/Documents/Obsidian Vault/.obsidian/plugins/alembic/"
cp -R build/audio-capture.app "/Users/you/Documents/Obsidian Vault/.obsidian/plugins/alembic/"
```

**Step 3: Commit everything**

```bash
git add -A
git commit -m "build: compile and deploy Copilot Studio integration"
```

**Step 4: Push**

```bash
git push origin main
```
