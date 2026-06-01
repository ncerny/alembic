# Alembic

Alembic is a **macOS menu-bar app** that produces real-time, timestamped meeting
transcripts entirely on-device. It captures two audio streams — your microphone
("you") and a meeting app's audio ("them") — runs both through Apple's on-device
speech recognition (macOS 26 `SpeechAnalyzer`), and writes a crash-safe JSONL
transcript to disk as the meeting happens.

**No audio and no transcript data ever leaves the machine.**

```
┌──────────────┐    ┌────────────────────────────────┐    ┌─────────────────────┐
│  Teams Call  │───▶│  ScreenCaptureKit ("them")      │    │                     │
│  (any app)   │    │  + AVAudioEngine mic ("you")     │───▶│  macOS 26           │
└──────────────┘    └────────────────────────────────┘    │  SpeechAnalyzer     │
                                                           │  (on-device)        │
                                                           └──────────┬──────────┘
                                                                      │
                                                                      ▼
                                                       ~/Documents/Alembic/
                                                       2026-06-01_1430-meeting.jsonl
                                                       2026-06-01_1430-meeting.md
```

## Requirements

| Requirement | Notes |
|---|---|
| **macOS 26** or later | `SpeechAnalyzer` / `SpeechTranscriber` and ScreenCaptureKit per-app audio |
| **Xcode Command Line Tools** | `xcode-select --install` — Xcode.app is not required |

## Quick start

```bash
cd app/Alembic
bash build.sh --make-cert   # once: create a stable signing cert (keeps permissions across rebuilds)
bash build.sh --run         # build, sign, verify, launch
```

See [`app/Alembic/README.md`](app/Alembic/README.md) for full build, signing,
test, settings, and transcript format documentation.

## Features

- 🎙 **No bot, no virtual audio device** — ScreenCaptureKit captures per-app audio directly; AVAudioEngine captures the microphone
- 🔒 **Fully on-device** — Apple's `SpeechAnalyzer` runs locally; nothing is transmitted during a meeting
- 🏷 **Vocabulary hints** — bias recognition toward your domain's names via Settings (inline terms, a plain-text file, or a folder of Markdown notes)
- 📄 **Crash-safe output** — each segment is flushed to disk immediately; a crash mid-meeting leaves a fully parseable transcript
- 🧾 **Two formats** — canonical `.jsonl` (one `FinalizedSegmentDTO` per line) and a human-readable `.md` side-car

## Vocabulary hints

On-device speech recognition works best when it knows the words it's likely to
hear. The **Settings** window (menu bar icon → **Settings…**) lets you configure
up to ~500 hint terms that are loaded before each recording session.

Three sources are supported and merged in priority order:

| Source | What to enter | Format |
|---|---|---|
| **Inline** | Comma-separated terms typed directly into the field | `Dynatrace, Kubernetes, Jane Doe` |
| **File** | Path to a plain-text file (use **Browse…** to pick) | One term per line; lines starting with `#` are comments |
| **Folder** | Path to a folder of Markdown notes (use **Browse…** to pick) | File basenames become hints automatically |

When the total exceeds ~500 terms, folder terms are dropped first to stay within
Apple's recommended limit. A **Preview** button shows the per-source counts and
flags truncation before you record.

**Name handling:** multi-word names are expanded automatically. `Jane Doe` adds
`Jane`, `Doe`, and `Jane Doe` as separate hints. `Doe, Jane`
(Last, First format) adds `Doe`, `Jane`, and `Jane Doe`.
Date-prefixed filenames (`2026-06-01 …`) and anything inside an `Archive/`
folder are skipped.

> **Folder tip:** point the folder source at any collection of Markdown notes
> whose filenames are people or project names — they'll automatically bias
> transcription toward whoever and whatever your meetings are about.

## What it produces

```
~/Documents/Alembic/
  2026-06-01_1430-Sprint_Planning.jsonl   ← canonical (one JSON object per line)
  2026-06-01_1430-Sprint_Planning.md      ← [hh:mm:ss] source: text
```

Each JSONL line carries `schemaVersion`, `start`, `end`, `source` (`you`/`them`),
and `text`. See [`app/Alembic/README.md`](app/Alembic/README.md#transcript-output)
for the full schema.

## Repository layout

```
app/Alembic/          ← active project (SwiftPM, macOS 26 menu-bar app)
  Sources/
    AlembicKit/       ← core library: models, session orchestration, transcript writer,
    │                   platform-agnostic contracts + macOS adapters under Platform/macOS/
    Alembic/          ← thin SwiftUI menu-bar shell (AppModel, menus, views, Settings)
    AlembicCheck/     ← authoritative test runner  →  swift run AlembicCheck
  build.sh            ← canonical build / sign / verify entry point
  README.md           ← full technical documentation

src/                  ← legacy TypeScript Obsidian plugin (not actively maintained)
swift-helper/         ← legacy Swift audio capture helper for the Obsidian plugin
docs/plans/           ← historical design documents from the Obsidian plugin era
```

## Privacy

The Swift sources contain no networking code — no `URLSession`, `URLRequest`, or
sockets. The only network activity is a one-time Apple speech model-asset
download; no audio or transcript text is ever transmitted. Static-audit command
and manual validation checklist: [`app/Alembic/MANUAL-VALIDATION.md`](app/Alembic/MANUAL-VALIDATION.md).

## License

MIT
