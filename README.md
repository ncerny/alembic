# Alembic

Distill meetings into knowledge. Capture audio directly from Microsoft Teams (or any app), transcribe locally with Whisper, and generate AI-powered summaries using GitHub Copilot — all without leaving Obsidian.

## How It Works

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Teams Call   │────▶│  Capture     │────▶│  Whisper     │────▶│  Copilot     │
│  (any app)   │     │  Audio       │     │  Transcribe  │     │  Summarize   │
└──────────────┘     └──────┬───────┘     └──────────────┘     └──────┬───────┘
                            │                                         │
                    macOS ScreenCaptureKit                    GitHub Copilot SDK
                    No bot · No virtual device               Your existing license
                            │                                         │
                            ▼                                         ▼
                    ┌─────────────────────────────────────────────────────────┐
                    │                  Obsidian Vault                         │
                    │                                                         │
                    │  📄 2026-04-21 Sprint Planning.md                       │
                    │  ├── Summary, Key Decisions, Action Items               │
                    │  ├── [[Person]] wikilinks, tags, frontmatter            │
                    │  ├── Your notes from during the meeting                 │
                    │  └── Full transcript (collapsible)                      │
                    └─────────────────────────────────────────────────────────┘
```

**Key features:**

- 🎙 **No bot, no virtual audio device** — uses macOS ScreenCaptureKit to capture audio directly from Teams, Zoom, or any app
- 🔒 **Privacy-first** — audio is transcribed locally with Whisper; only text is sent to the LLM
- ✍️ **Human-AI hybrid** — jot notes during the meeting to guide what the AI focuses on
- 🔗 **Obsidian-native** — creates linked notes with frontmatter, `[[wikilinks]]`, action items, and tags

---

## Prerequisites

| Requirement                      | How to install                                                     |
| -------------------------------- | ------------------------------------------------------------------ |
| **macOS 13+** (Ventura or later) | Required for ScreenCaptureKit                                      |
| **Xcode Command Line Tools**     | `xcode-select --install`                                           |
| **Whisper.cpp**                  | `brew install whisper-cpp`                                         |
| **GitHub Copilot CLI**           | `gh extension install github/gh-copilot`                           |
| **GitHub Copilot license**       | [github.com/features/copilot](https://github.com/features/copilot) |

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/ncerny/alembic.git
cd alembic
```

### 2. Install dependencies and build

```bash
npm install
npm run build
```

### 3. Build the audio capture helper

```bash
cd swift-helper
bash build.sh
cd ..
```

This compiles the Swift helper that captures per-app audio using macOS ScreenCaptureKit.

### 4. Install into Obsidian

Copy the plugin files to your vault's plugin directory:

```bash
VAULT_PATH="$HOME/path-to-your-vault"
PLUGIN_DIR="$VAULT_PATH/.obsidian/plugins/alembic"

mkdir -p "$PLUGIN_DIR"
cp main.js manifest.json styles.css "$PLUGIN_DIR/"
cp build/audio-capture "$PLUGIN_DIR/"
```

### 5. Enable the plugin

1. Open Obsidian → Settings → Community Plugins
2. Turn off **Restricted Mode** if prompted
3. Find **Alembic** in the list and enable it

### 6. Grant permissions

On first use, macOS will prompt you to grant **Screen Recording** permission to Obsidian. This is required for ScreenCaptureKit to capture audio from other apps.

> System Settings → Privacy & Security → Screen Recording → Enable **Obsidian**

---

## Usage

### Recording a meeting

1. **Open the meeting panel** — click the 🎙 microphone icon in the left ribbon, or use the command palette: `Alembic: Open meeting panel`
2. **Start your Teams/Zoom call** as normal
3. **Click Record** — the plugin captures audio from the target app (default: Microsoft Teams)
4. **Take notes** — jot down key points in the notes area during the meeting. These guide what the AI focuses on in the summary.
5. **Click Stop** — recording ends and the plugin automatically:
   - Transcribes the audio locally with Whisper
   - Sends the transcript + your notes to GitHub Copilot for summarization
   - Creates a structured meeting note in your vault

### Generated meeting note

The plugin creates a note like `Meetings/2026-04-21 Sprint Planning.md`:

```markdown
---
type: meeting
date: 2026-04-21
title: 'Sprint Planning - Q2 Goals'
attendees:
  - '[[Jane Doe]]'
  - '[[Bob Smith]]'
tags: [meeting, sprint-planning, q2-goals]
duration: 45min
---

# Sprint Planning - Q2 Goals

## Summary

The team discussed Q2 priorities and agreed to focus on...

## Key Decisions

- Prioritize the API redesign over the dashboard overhaul
- Hire two additional engineers by end of May

## Action Items

- [ ] [[Jane Doe]]: Draft Q2 roadmap (due: 2026-04-28)
- [ ] [[Bob Smith]]: Review budget allocation (due: 2026-04-25)

## My Notes

Your notes from during the meeting appear here...

## Transcript

<details>
<summary>Full transcript (click to expand)</summary>

[00:00] So let's get started with the sprint planning...
[00:15] I think we should focus on the API first...

</details>
```

### Command palette

| Command                             | Description                              |
| ----------------------------------- | ---------------------------------------- |
| `Open meeting panel`                | Open the sidebar meeting view            |
| `Start meeting recording`           | Begin capturing audio                    |
| `Stop recording and generate notes` | Stop, transcribe, summarize, create note |

---

## Configuration

Open Settings → Alembic:

| Setting                | Description                      | Default           |
| ---------------------- | -------------------------------- | ----------------- |
| **Copilot model**      | LLM model for summarization      | `gpt-4o-mini`     |
| **Target application** | App to capture audio from        | `Microsoft Teams` |
| **Output folder**      | Where meeting notes are created  | `Meetings`        |
| **Whisper model size** | Transcription accuracy vs. speed | `base`            |

### Whisper model sizes

| Model    | Size   | Speed   | Accuracy |
| -------- | ------ | ------- | -------- |
| `tiny`   | ~75MB  | Fastest | Lower    |
| `base`   | ~150MB | Fast    | Good     |
| `small`  | ~500MB | Medium  | Better   |
| `medium` | ~1.5GB | Slow    | Best     |

The Whisper model is downloaded automatically on first use.

---

## Architecture

```
alembic/
├── main.ts                      # Plugin entry point
├── src/
│   ├── types.ts                 # Shared types & interfaces
│   ├── settings.ts              # Plugin settings tab
│   ├── audio-capture.ts         # Spawns Swift helper for audio capture
│   ├── transcriber.ts           # Whisper.cpp integration & VTT parsing
│   ├── summarizer.ts            # LLM provider interface
│   ├── providers/
│   │   └── copilot-sdk.ts       # GitHub Copilot SDK provider
│   ├── prompts.ts               # Summarization prompt templates
│   ├── note-builder.ts          # Meeting note markdown generation
│   ├── meeting-controller.ts    # Orchestrator state machine
│   └── meeting-view.ts          # Sidebar UI panel
├── swift-helper/
│   ├── AudioCapture.swift       # macOS ScreenCaptureKit audio capture
│   └── build.sh                 # Build script for Swift helper
├── styles.css                   # UI styles
└── manifest.json                # Obsidian plugin manifest
```

### Data flow

1. **Audio capture** — Swift helper uses ScreenCaptureKit to capture audio from the target app → writes 16kHz mono WAV
2. **Transcription** — Whisper.cpp processes the WAV file locally → produces timestamped VTT transcript
3. **Summarization** — GitHub Copilot SDK merges transcript + user notes → returns structured JSON summary
4. **Note creation** — Note builder generates markdown with YAML frontmatter, wikilinks, action items → saves to vault

### Privacy model

| Data            | Where it goes                                       |
| --------------- | --------------------------------------------------- |
| Audio           | Stays on your machine. Deleted after transcription. |
| Transcript text | Sent to GitHub Copilot LLM for summarization        |
| Meeting notes   | Stored in your Obsidian vault (local files)         |

---

## Development

### Dev mode (watch for changes)

```bash
npm run dev
```

### Production build

```bash
npm run build
```

### Rebuild Swift helper

```bash
cd swift-helper && bash build.sh
```

---

## Roadmap

- [ ] Windows support (WASAPI audio capture)
- [ ] Calendar integration (MS Graph API — auto-create notes from calendar events)
- [ ] Pull post-meeting Teams transcripts (speaker-attributed via Graph API)
- [ ] M365 Copilot Meeting Insights integration
- [ ] Entity extraction & auto-linking to existing vault notes
- [ ] Dataview integration & meeting analytics
- [ ] Community plugin submission

## License

MIT
