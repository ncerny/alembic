# Copilot Instructions for Alembic

Alembic is an **Obsidian plugin** (desktop-only, macOS) that captures meeting audio, transcribes locally with Apple's on-device SFSpeechRecognizer, and generates AI-powered meeting notes via GitHub Copilot SDK. It runs inside Obsidian's Electron environment.

## Build Commands

```bash
npm run dev          # Watch mode (esbuild, rebuilds on change)
npm run build        # Production build → main.js

# Swift audio capture helper (macOS only, requires Xcode CLI tools)
cd swift-helper && bash build.sh   # → build/audio-capture.app
```

There are no tests or linters configured.

### Deployment

- The `.app` bundle must be deployed with `rm -rf` first, then `cp -R` — macOS `cp -R` over an existing `.app` bundle merges without replacing nested binaries.
- Workspace builds to `/Users/you/workspace/alembic/main.js`; Obsidian loads from `/Users/you/Documents/Obsidian Vault/.obsidian/plugins/alembic/`.
- Swift helper output is `build/audio-capture.app/` (an app bundle, not a bare binary) — TCC permissions (Speech Recognition) require an app bundle launched via `open -W`.

## Architecture

### Pipeline

The plugin follows a linear processing pipeline orchestrated by `MeetingController`:

```
AudioCapture → Transcriber → Summarizer → NoteBuilder
(ScreenCaptureKit    (on-device         (Copilot SDK)   (Vault API +
 + AVAudioEngine)     SFSpeechRecognizer                  auto-wikilinks)
                      + reset accumulation
                      + vocab hints)
```

Each stage is a separate class in `src/`. The controller manages state transitions through a `MeetingState` enum: `idle → recording → transcribing → summarizing → complete | error`.

### Key Components

- **`main.ts`** — Plugin entry point. Extends `obsidian.Plugin`, registers the view, commands, settings tab, and instantiates `MeetingController`.
- **`src/meeting-controller.ts`** — Orchestrator and state machine. Owns the full recording→note pipeline. Uses an observer pattern (`onStateChange`, `onProgress`, `onDurationUpdate`) to decouple from the UI. Errors are logged with `console.error("[alembic] Pipeline error:", err)` and `emitProgress("Error: ...")` fires before `setState("error")` so the message is visible while the progress container is still shown.
- **`src/audio-capture.ts`** — Spawns the Swift `audio-capture` app bundle as a child process via `open -W`. Communicates via stdout signals (`RECORDING`, `STOPPED`) and stops gracefully with `SIGINT`.
- **`src/transcriber.ts`** — Launches the Swift audio-capture helper in `transcribe` mode, which uses Apple's on-device SFSpeechRecognizer. Parses JSON output into `TranscriptSegment[]`. Passes `--vocabulary` hints from vault scan.
- **`src/summarizer.ts`** — Defines the `LLMProvider` interface. Thin wrapper that delegates to a provider.
- **`src/providers/copilot-sdk.ts`** — Implements `LLMProvider` using `@github/copilot-sdk`. Uses dynamic `import()` since the SDK is marked external in esbuild. Must call `await client.start()` before any API calls to establish the JSON-RPC connection to the SDK subprocess. Auto-selects the cheapest model with enough context window (filters by policy state and max_context_window_tokens, sorts by billing multiplier). Timeout scales with prompt length: `max(180s, prompt_length/500 * 60s)`. Finds `node` and `gh` binaries by checking known paths (`/opt/homebrew/bin`, `/usr/local/bin`, etc.) since Obsidian's Electron environment doesn't have a normal PATH. Gets GitHub token via `gh auth token`.
- **`src/prompts.ts`** — System and user prompt templates. The LLM returns a JSON `MeetingSummary` object (not markdown).
- **`src/note-builder.ts`** — Generates the final markdown file with YAML frontmatter, `[[wikilinks]]` for attendees, and a collapsible transcript section. Uses Obsidian's Vault API to create files. Accepts `knownNames` and applies `insertWikilinks()` to summary text, key decisions, action item tasks, and transcript segments.
- **`src/vault-vocab.ts`** — Scans the entire vault recursively for note names. Provides vocabulary hints for speech recognition (individual words via `vocabToRecognitionHints()`) and auto-wikilinks in generated notes (via `insertWikilinks()`). Excludes date-prefixed notes (matching `^\d{4}-\d{2}-\d{2}`) and anything under an `Archive` folder at any level. Splits "Last, First" basenames into individual words for the recognizer. `insertWikilinks()` handles "Last, First" names by matching "First Last" in natural speech order and uses `[[Last, First|FirstName]]` display syntax. Apple recommends keeping contextualStrings under ~500 terms; a console warning is logged if the vault exceeds this. "Alembic" is always included as a vocabulary hint.
- **`src/meeting-view.ts`** — Sidebar UI panel (extends `obsidian.ItemView`). Built entirely with Obsidian's DOM API — no framework. Progress container stays visible during error state.
- **`swift-helper/AudioCapture.swift`** — macOS ScreenCaptureKit audio capture + on-device transcription via SFSpeechRecognizer. Captures 48kHz stereo from app (via ScreenCaptureKit) + 48kHz mono from mic (via AVAudioEngine), mixes to mono WAV. The `stream()` callback checks `kAudioFormatFlagIsNonInterleaved` and handles both interleaved and non-interleaved data layouts (ScreenCaptureKit delivers non-interleaved stereo, flags=0x29). Diagnostic logging reports app audio format details. Also handles `transcribe` command with reset accumulation for on-device recognition. Accepts `--vocabulary` CLI flag for contextual string hints (comma-separated individual words). Single-file Swift program compiled with `swiftc`, output is an app bundle.

### Provider Pattern

New LLM providers can be added by implementing the `LLMProvider` interface from `src/summarizer.ts`:

```typescript
interface LLMProvider {
  summarize(transcript: string, userNotes: string): Promise<MeetingSummary>;
}
```

### Privacy Model

Audio stays on the user's machine and is deleted after transcription. Transcription uses Apple's on-device SFSpeechRecognizer — no audio leaves the machine. Only transcript text is sent to the LLM (via GitHub Copilot) for summarization. Meeting notes are local markdown files in the Obsidian vault.

**Do NOT send audio to external services** (including Apple's server-side SFSpeechRecognizer) — meetings may contain sensitive corporate data. Transcription must remain on-device.

### Transcription Constraints

- **whisper.cpp / whisper-cli is NOT viable** — model files are hosted on HuggingFace, which is blocked by the corporate proxy. No GitHub-hosted mirrors of Whisper models are available.
- **Apple server-side SFSpeechRecognizer is NOT acceptable** — sends raw audio to Apple servers. Incompatible with corporate data sensitivity requirements.
- **On-device SFSpeechRecognizer limitations** — quality is lower than server-side alternatives but keeps everything local. Raw 48kHz audio is fed directly to the recognizer; the framework handles format conversion internally.
- **On-device SFSpeechRecognizer resets mid-file for longer audio** — the transcriber accumulates text across resets by monitoring partial results. When partial text suddenly gets much shorter with different content, the current segment is saved and a new one begins. When the final result is empty (common with on-device mode), the best partial result is used instead. `shouldReportPartialResults = true` is required.
- **contextualStrings API** accepts vocabulary hints to bias recognition toward domain-specific terms. Keep under ~500 terms for optimal recognition.
- **Planned alternative: Teams transcript pull** — for Teams meetings, retrieve speaker-attributed transcripts via Microsoft Graph API post-meeting. Data stays within the M365 corporate tenant. See Planned Modules.

### Planned Modules (Not Yet Implemented)

The plugin is being built in phases. These modules are planned but do not exist yet:

- **`CalendarSync`** — MS Graph OAuth (MSAL PKCE via local loopback + `electron.shell.openExternal()`) for calendar polling, meeting detection, and auto-note creation from calendar events.
- **`GraphLinker` (partially implemented)** — Auto-wikilinking from vault note names is implemented in `vault-vocab.ts`. Remaining work: deeper entity extraction beyond vault name matching (e.g., project names, topics not yet in the vault).
- **Graph API transcript pull** — Retrieve speaker-attributed WebVTT transcripts from Teams post-meeting as a supplement to local on-device transcription. Preferred transcription source for Teams meetings — data stays within M365 corporate tenant.
- **M365 Copilot Meeting Insights** — Pull pre-computed meeting summaries when the user has a Copilot license.
- **Windows audio capture** — WASAPI-based equivalent of the macOS ScreenCaptureKit helper.

### Multi-Provider Direction

The `LLMProvider` interface is designed to support multiple backends. The current implementation uses `@github/copilot-sdk`. Planned providers include Azure OpenAI (`@azure/openai`) for enterprise and M365 Meeting Insights via Graph API. New providers go in `src/providers/` and are selected via settings.

## Conventions

- **Obsidian API only for UI** — all DOM manipulation uses Obsidian's `createEl`, `createDiv`, `Setting`, `setIcon`, etc. No React, no framework.
- **External dependencies are dynamic imports** — `@github/copilot-sdk` is marked external in esbuild and loaded at runtime via `await import()`. Follow this pattern for any new runtime dependency that Obsidian provides or that shouldn't be bundled.
- **CSS uses Obsidian variables** — styles in `styles.css` reference Obsidian's CSS custom properties (`var(--text-muted)`, `var(--color-red)`, etc.) for theme compatibility. Never use hardcoded colors.
- **Types are centralized** — all shared interfaces, type aliases, constants, and defaults live in `src/types.ts`.
- **Temp files are always cleaned up** — audio WAV and VTT files are deleted in `finally` blocks after processing. Maintain this pattern.
- **Child process communication** — the Swift helper uses stdout for structured signals and stderr for logging. The Node side reads stdout line-by-line for state transitions.
- **Use `requestUrl` for HTTP** — Obsidian's `requestUrl` is the cross-platform-safe way to make HTTP requests from a plugin. Use it instead of `fetch` or Node's `http`.
- **Use `processFrontMatter` for frontmatter updates** — when modifying an existing note's frontmatter, use `this.app.fileManager.processFrontMatter(file, (fm) => { ... })` for atomic updates instead of string manipulation.
- **Use `registerInterval` for polling** — background tasks like calendar polling should use `this.registerInterval(window.setInterval(...))` so Obsidian cleans them up on plugin unload.

## Meeting Note Target Format

The generated meeting notes use YAML frontmatter with `[[wikilinks]]` for graph integration. The full target schema (some fields not yet implemented):

```yaml
---
type: meeting
date: 2026-04-21
title: "Sprint Planning - Q2 Goals"
attendees:
  - "[[Jane Doe]]"
  - "[[Bob Smith]]"
projects:                    # planned — not yet implemented
  - "[[Project Alpha]]"
source: teams                # planned — not yet implemented
meeting-id: "AAMkAGI2..."   # planned — for Graph API linking
tags: [meeting, sprint-planning]
duration: 45min
---
```

Action items in the note body use Obsidian task format: `- [ ] [[Assignee]]: Task (due: YYYY-MM-DD)`
