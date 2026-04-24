# Copilot Studio Agent Integration Design

## Problem

The Alembic plugin needs to pull calendar events (subject, attendees, times) from the user's M365 tenant to auto-populate meeting context and create people notes. Direct API access via OAuth (PKCE, Azure CLI, or any first-party client ID) is blocked by the corporate tenant's AADSTS65002 preauthorization policy. No app registration with a client secret is available.

## Approach

Use a **Copilot Studio agent** that already has M365 tenant access as a proxy. The plugin communicates with the agent via the **Direct Line REST API** — simple HTTP calls authenticated with a secret key. No OAuth, no tokens, no app registration.

## Architecture

```
Plugin (Obsidian)                     Microsoft Cloud
─────────────────                     ───────────────
                   Direct Line API
CopilotAgent ─────────────────────► Copilot Studio Agent
  (new class)    POST /activities       │
       │         GET  /activities       │ Power Automate /
       │              ◄────────────────  M365 Connector
       ▼                                │
CalendarSync                         Calendar Data
  (existing)                         (today's events)
       │
       ▼
PeopleManager
  (existing)
```

### What changes

- **`m365-auth.ts`** — deleted (no more PKCE, tokens, localhost server)
- **`graph-client.ts`** — replaced with **`copilot-agent.ts`** (Direct Line REST client)
- **`calendar-sync.ts`** — swap `GraphClient` dependency for `CopilotAgent`
- **Settings** — replace OAuth Connect/Disconnect with a "Direct Line Secret" text field
- **Types** — remove `m365RefreshToken/AccessToken/TokenExpiry`, add `directLineSecret` and `agentPrompt`

### What stays the same

- `CalendarSync` orchestration, observer pattern, polling
- `PeopleManager` auto-creating people notes
- `meeting-view.ts` event list UI
- `CalendarEvent` and `GraphAttendee` interfaces

## CopilotAgent — Direct Line Client

`src/copilot-agent.ts` replaces both `m365-auth.ts` and `graph-client.ts`. Stateless HTTP client — no tokens to refresh, no OAuth flows.

### Request lifecycle

1. Generate a Direct Line token from the secret (POST `/tokens/generate`)
2. Start a conversation (POST `/conversations`)
3. Send a message requesting today's calendar as JSON
4. Poll for response (GET `/conversations/{id}/activities?watermark=...`)
5. Parse the agent's reply — extract JSON from the response text
6. Normalize to `CalendarEvent[]` and return

### Conversation management

- One active conversation at a time, cached with its token expiry
- Token lasts 30 minutes; new conversation created on expiry
- New conversation started after 15 messages (Direct Line limit is 20)
- Abandoned conversations auto-clean after 10 minutes

### Response parsing

The agent may return natural language with embedded JSON, or structured JSON directly. Parsing strategy:

1. Try `JSON.parse` on full response text
2. If that fails, extract the first `[...]` or `{...}` block via regex
3. If that also fails, return empty array and log warning

### Timeouts

- 30-second timeout on polling for agent response
- Stale data preserved on timeout (no crash, next poll retries)

## Settings

```
Microsoft 365 Integration
─────────────────────────
Direct Line Secret: [•••••••••••••••••••]
  ↳ Paste from Copilot Studio → Settings → Channels → Direct Line

Prompt (optional): [List my calendar events for today...]
  ↳ Customize if your agent expects a specific command

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
directLineSecret?: string;
agentPrompt?: string;
```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| 403 (invalid secret) | Log error, show in meeting view, `isConnected()` → false |
| Network timeout (30s) | Skip poll cycle, keep stale events, log warning |
| Agent unresponsive | Same as timeout |
| Unparseable response | Log raw response at debug level, return empty array |
| Conversation expired | Auto-create new conversation on next poll |
| Rate limit approached | Start new conversation after 15 messages |

## Privacy

- No audio, transcript, or meeting content sent to the agent
- Only calendar metadata requested (subject, times, attendees, location)
- Direct Line secret stored in Obsidian's `data.json` (local file)
