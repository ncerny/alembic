# Power Automate Calendar Integration Design

## Problem

The Alembic plugin needs to pull calendar events (subject, attendees, times) from the user's M365 tenant to auto-populate meeting context and create people notes. Direct API access via OAuth is blocked by AADSTS65002 preauthorization policy. No app registration is available. Direct Line channel is admin-disabled. Copilot Studio Agents SDK requires an app registration with `CopilotStudio.Copilots.Invoke` permission.

## Approach

Use a **Power Automate cloud flow** with an HTTP Request trigger. The flow uses the **Office 365 Outlook connector** (pre-authorized in the tenant) to fetch calendar events and returns them as JSON. The plugin makes one HTTP POST per refresh cycle. No OAuth, no app registration, no Direct Line.

## Architecture

```
Plugin (Obsidian)                     Power Platform
─────────────────                     ──────────────
                    HTTP POST
CalendarAgent ──────────────────────► Power Automate Flow
  (new class)       (one call)          │
       │                                │ Office 365 Outlook
       │          HTTP 200 + JSON       │ connector (V4)
       │  ◄─────────────────────────   Calendar Events
       ▼
CalendarSync (existing)
       │
       ▼
PeopleManager (existing)
```

### What changes

- **`m365-auth.ts`** — deleted (no more PKCE, tokens, localhost server)
- **`graph-client.ts`** — replaced with **`calendar-agent.ts`** (single HTTP POST client)
- **`calendar-sync.ts`** — swap `GraphClient` dependency for `CalendarAgent`
- **Settings** — replace OAuth Connect/Disconnect with a "Flow URL" text field
- **Types** — remove `m365RefreshToken/AccessToken/TokenExpiry`, add `calendarFlowUrl`

### What stays the same

- `CalendarSync` orchestration, observer pattern, polling
- `PeopleManager` auto-creating people notes
- `meeting-view.ts` event list UI
- `CalendarEvent` and `GraphAttendee` interfaces

## CalendarAgent — HTTP Client

`src/calendar-agent.ts` replaces both `m365-auth.ts` and `graph-client.ts`. Stateless single-request HTTP client.

### Request lifecycle

1. POST to the flow URL with `{ startDateTime, endDateTime }` in the body
2. Receive JSON response containing calendar events
3. Normalize response to `CalendarEvent[]` and return

### Response format

The Office 365 Outlook connector returns events in Graph/Outlook format (PascalCase). The flow returns them directly. The normalizer handles both PascalCase and camelCase field names for resilience.

## Settings

```
Microsoft 365 Integration
─────────────────────────
Calendar Flow URL: [•••••••••••••••••••]
  ↳ Paste your Power Automate HTTP trigger URL

People folder: [People]
Calendar poll interval: [5] minutes
```

### Settings type changes

```typescript
// Removed
m365RefreshToken?: string;
m365AccessToken?: string;
m365TokenExpiry?: number;

// Added
calendarFlowUrl?: string;
```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Invalid/expired flow URL | Log error, `isConnected()` → false |
| Network timeout (30s) | Skip poll cycle, keep stale events, log warning |
| Non-200 response | Log status + body, throw to caller |
| Empty/malformed JSON | Return empty array, log warning |

## Privacy

- No audio, transcript, or meeting content sent to the flow
- Only date range sent in request body
- Flow URL stored in Obsidian's `data.json` (local file)

## Power Automate Flow Setup (User Instructions)

1. Go to make.powerautomate.com → Create → Instant cloud flow
2. Add trigger: "When an HTTP request is received"
   - Request body schema: `{ "startDateTime": "string", "endDateTime": "string" }`
3. Add action: "Get calendar view of events (V4)" from Office 365 Outlook
   - Start time: `triggerBody()['startDateTime']`
   - End time: `triggerBody()['endDateTime']`
4. Add action: "Response" — Status 200, Body: `body('Get_calendar_view_of_events_(V4)')`
5. Save → Copy the HTTP POST URL → Paste into Alembic settings
