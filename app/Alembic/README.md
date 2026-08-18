# Alembic

Alembic is a **menu-bar-only macOS app** that produces a real-time, timestamped
transcript of a meeting (e.g. Microsoft Teams) entirely **on-device**. It
captures two audio streams — your microphone ("you") and the meeting app's audio
("them") — runs each through Apple's on-device speech recognition, and writes a
canonical transcript to disk as the meeting happens.

There is no cloud component. No audio and no transcript text ever leaves the
machine (see [Privacy](#privacy)).

## Requirements

- **macOS 26 or later.** The app commits fully to macOS 26+ APIs
  (`SpeechAnalyzer` / `SpeechTranscriber`, ScreenCaptureKit per-app audio
  capture). `LSMinimumSystemVersion` is `26.0` and `Package.swift` pins the
  platform to `.macOS("26.0")`.
- **Swift 6 toolchain** via the **Xcode Command Line Tools** (`swift`).
  **Xcode.app is not required** — the build and test commands below run under
  CLT only, and the build script never invokes `xcodebuild`.

## Build

```bash
cd app/Alembic
bash build.sh --make-cert   # ONE TIME: create a stable signing cert (see below)
bash build.sh               # clean release build → assemble → sign → verify
bash build.sh --run         # same, then `open` the built app
bash build.sh --reset-tcc   # clear Alembic's permission grants (re-grant on launch)
bash build.sh --help        # usage
```

`build.sh` is the **canonical packaging entry point**. It:

1. Performs a clean SwiftPM release build (Swift 6 strict concurrency).
2. Assembles `build/Alembic.app` (copies the executable + `Info.plist`).
3. **Codesigns** the bundle — with a stable identity when one is available
   (see [Signing & permissions](#signing--permissions)), otherwise ad-hoc.
4. **Verifies** the signature (`codesign --verify`) before reporting success.
5. Prints run instructions and the transcript output location.

The app is **menu-bar-only** (`LSUIElement`): after launch there is no Dock icon
and no window — look for the Alembic icon in the macOS menu bar.

## Signing & permissions

macOS TCC keys permission grants — **especially Screen Recording** — to the
app's **code signature**. An *ad-hoc* signature (`codesign --sign -`) has no
stable identity: its hash changes on every rebuild, so each rebuilt binary looks
like a brand-new app and **previously-granted permissions stop applying** (System
Settings may still show a stale "Alembic" toggle that no longer matches the
running binary — the app then reports Screen Recording as not granted even though
it looks enabled).

To make grants survive rebuilds, sign with a **stable identity**:

```bash
bash build.sh --make-cert   # creates a persistent self-signed code-signing cert
bash build.sh --run         # auto-detects the cert and signs with it
bash build.sh --reset-tcc   # ONCE: clear stale ad-hoc grants, then re-grant on launch
```

`--make-cert` creates a self-signed certificate named **"Alembic Self-Signed"**
in your login keychain. It is intentionally untrusted by Gatekeeper (irrelevant
for an app you run yourself) but gives the bundle a **stable Designated
Requirement** (`identifier "com.alembic.app" and certificate leaf = H"…"`), so
TCC grants persist across rebuilds. To use a real identity instead:

```bash
ALEMBIC_CODESIGN_IDENTITY="Apple Development: you@example.com" bash build.sh
```


## Test

```bash
cd app/Alembic
swift run AlembicCheck   # AUTHORITATIVE test runner — exits non-zero on failure
```

> **Why `AlembicCheck` and not `swift test`?** Under Command Line Tools only (no
> Xcode.app / no `xctest` host), `swift test` *builds* the swift-testing/XCTest
> suite but does **not execute** it — a deliberately failing test still exits 0.
> `AlembicCheck` is a plain `async @main` executable running a hand-rolled
> assertion harness over `AlembicKit`; it exits **non-zero** on any failure and
> is therefore the real acceptance command for this repo.

## Diagnostics (live probes)

`AlembicCheck` also hosts a small set of **manual, live diagnostics** —
subcommands that talk to real system state (Accessibility, Screen Recording,
the microphone) instead of running the deterministic check suite. None of these
run as part of `swift run AlembicCheck`'s normal (no-argument) invocation, and
none are part of the automated suite.

| Subcommand | Purpose | Requires |
|---|---|---|
| `swift run AlembicCheck audio-watch [seconds]` | Live meter/level watch for the audio pipeline. | Microphone, Screen Recording |
| `swift run AlembicCheck ax-dump [bundle-prefix] [--out path] [--max-visits n]` | Dumps the Accessibility tree of a running app (default: Teams) — used to re-derive `TeamsChatPoster`'s AX markers after a Teams UI update. | Accessibility |
| `swift run AlembicCheck frame-dump [bundle-prefix] [--meeting-title <title-prefix> \| --window-id <CGWindowID> \| --list-windows] [--out <path>] [--frames <n>] [--interval <seconds>] [--include-images]` | Captures live Teams meeting frames — **video only, no microphone/Speech Recognition** — and dumps OCR text/bounding boxes plus the catalogued `SpeakerLabelCatalog` regions and marker colors, to re-derive its geometry after a Teams UI change (SR-22). | **Screen Recording only** |

`frame-dump` details:

- Requires an explicit `--meeting-title <title-prefix>` or `--window-id
  <CGWindowID>` — a bare bundle-prefix is rejected, since Teams has no static
  title hint to resolve a window from. Run with `--list-windows` first (a
  non-capturing, read-only enumeration) to discover the exact title/window ID
  to pass.
- Output is **text/geometry only by default** — no image bytes are written
  unless `--include-images` is passed, and `--include-images` requires an
  explicit `--out` (there is no default output location for image output).
- When `--out` is omitted (text/geometry mode only), output defaults to a
  timestamped subdirectory under the gitignored
  `app/Alembic/.frame-dump-scratch/` diagnostics directory. Any explicit
  `--out` must resolve either outside the repository entirely or under a
  gitignored diagnostics directory — a path inside the repo that isn't
  gitignored is rejected before any capture is attempted.
- Every run prints a sensitive-data warning and writes a `manifest.json`
  listing every file produced, each labeled `"sensitive": true` — the output
  may contain real meeting participant names and on-screen content. Do not
  commit or share it. After a calibration run, confirm cleanup with
  `git status --ignored --short` from the repo root.
- See [MANUAL-VALIDATION.md §10a](MANUAL-VALIDATION.md) for the full one-time
  calibration procedure this tool supports, and
  [`docs/2-speaker-attribution/calibration-record.md`](../../docs/2-speaker-attribution/calibration-record.md)
  for the committed evidence behind any `markersValidated: true` catalog entry.

## Package structure

The app is a single SwiftPM package (`app/Alembic/Package.swift`) with four
targets:

| Target | Kind | Role |
|---|---|---|
| **AlembicKit** | library | Platform-agnostic core + all deterministically testable logic (models, transcript writer, orchestrator/state machine) plus Apple-specific adapters under `Sources/AlembicKit/Platform/macOS/`. Imported by both the app and the test runner. |
| **Alembic** | executable (`@main`) | Thin SwiftUI menu-bar shell. Depends on AlembicKit; kept free of testable business logic so the check runner can cover everything that matters. |
| **AlembicCheck** | executable | **Authoritative** test runner under CLT (see above). |
| **AlembicTests** | test target | swift-testing suite kept for a future full Xcode/CI host. **Not authoritative under CLT** (does not execute there). |

## How to run

1. `bash build.sh` (or `bash build.sh --run`).
2. `open build/Alembic.app`.
3. Click the Alembic icon in the menu bar.
4. Grant the three permissions when prompted (see [Permissions](#permissions)).
5. Pick the Teams (or other meeting app) capture target, then **Start**.
6. Watch live captions for both "you" and "them" with input meters and elapsed
   time. **Stop** to drain and save the transcript.
7. Use **Reveal in Finder** to open the saved transcript.

## Settings

Open Settings from the Alembic menu bar icon → **Settings…**

### Vocabulary hints

Vocabulary hints bias on-device speech recognition toward terms that appear in
your meetings — product names, team member names, project codes. They are
injected via `AnalysisContext.contextualStrings[.general]` before each session
starts. Apple recommends keeping the list under ~500 terms.

Three sources are combined in priority order. When the total exceeds 500, lower-
priority sources are truncated first (folder → file → inline):

| Source | How to configure | Format |
|---|---|---|
| **Inline** | Comma-separated list in the Settings field | `Dynatrace, Kubernetes, Jane Doe` |
| **File** | Path to a plain-text file | One term per line; lines starting with `#` are comments |
| **Folder** | Path to a folder of Markdown files | File basenames become hints; `Last, First` names expand to `First Last` |

The folder source is the same idea as the legacy Obsidian vault scan: point it at
any folder of notes whose filenames are people or project names and they will
automatically bias transcription.

**"Last, First" name expansion:** `Doe, Jane` → `Doe`, `Jane`,
`Jane Doe`. Date-prefixed basenames (`2026-06-01 …`) and anything under
an `Archive/` folder are skipped automatically.

Settings are stored in `UserDefaults` under:
- `alembic.vocabulary.inline`
- `alembic.vocabulary.filePath`
- `alembic.vocabulary.folderPath`

### Speaker attribution

An opt-in **speaker attribution** feature (`docs/2-speaker-attribution/spec.md`)
resolves a display name for far-end (`them`) transcript segments using
on-device Vision OCR of the meeting app's active-speaker tile — never any
network call, never any data leaving the machine.

**Scope as of 2026-08-18:** calibrated for strict macOS Teams 1-on-1,
three-person, and one seven-person 4-over-3 Gallery layout. The Gallery pass captured
two different active speakers plus a no-outline interval, and verified
cropped-label OCR at a 2400-pixel capture ceiling. Candidate frame-aspect and
exact marker-position gates keep shared-content, side-panel, other participant
counts, resized, and unknown layouts fail closed.

- Controlled by the `alembic.attribution.enabled` `@AppStorage` toggle in
  Settings. **Off by default**, and the toggle stays **disabled/greyed out in
  the UI** until `SpeakerLabelCatalog.entries` contains at least one entry with
  `markersValidated == true`. As of the 2026-08-18 calibration pass,
  `teamsDefaults` is validated for the measured 1-on-1, three-person, and Gallery layouts — see
  `AppEntry.matchesLayout(meetingTitle:)`, which `AppModel.start()` and
  `VisionSpeakerAttributor.init` both consult (independently, defense in
  depth) before ever upgrading video capture or starting frame consumption.
  Candidate-specific title, exact frame-size, aspect-ratio, and marker checks
  then select only the measured 1-on-1, three-person, or seven-person Gallery layout.
- See [MANUAL-VALIDATION.md §10](MANUAL-VALIDATION.md) for the completed
  one-time calibration record (§10a), the completed original AC-4 end-to-end validation
  of the original single-segment AC-4 (§10b), and the remaining unsupported
  layouts (§10c). See
  [`docs/2-speaker-attribution/calibration-record.md`](../../docs/2-speaker-attribution/calibration-record.md)
  for the committed, sanitized numeric evidence (frame dimensions, measured
  label-region bounds, title fragment) behind the validated catalog entry's
  geometry/marker literals.
- Tuning knobs are compile-time defaults on each type's `Configuration`
  initializer, not exposed in Settings: `ActiveSpeakerTimeline.Configuration
  .default` (`minConfidence: 0.5`, `minOverlapFraction: 0.6`, `coalesceGap:
  2.5`, `retentionWindow: 600`) and `VisionSpeakerAttributor.Configuration
  .default` (`samplingIntervalSeconds: 0.75`, `minimumOCRConfidence: 0.4`,
  `maxGapSeconds: 2.5`). These are conservative placeholders; live end-to-end
  validation data (§10b) may suggest different values (an open question this
  feature's spec tracks as OQ-1) — adjusting them does not require a code
  change beyond the `Configuration` initializer call sites in
  `Sources/AlembicKit/Platform/macOS/VisionSpeakerAttributor.swift`.

## Transcript output

Transcripts are written to:

```
~/Documents/Alembic/<yyyy-MM-dd_HHmm>-<meeting>.jsonl   (canonical)
~/Documents/Alembic/<yyyy-MM-dd_HHmm>-<meeting>.md      (human-readable)
```

The file name carries the session start stamp and a sanitized meeting name;
session-level metadata is recoverable from the file name rather than an in-file
header. The writer keeps the file handle open and flushes (`synchronize()`)
after every segment, so a crash mid-meeting still leaves a fully parseable
transcript.

### Canonical JSONL schema

The `.jsonl` file is **uniform: exactly one `FinalizedSegmentDTO` per line**,
nothing else (no header line) — every line decodes independently. Only
**finalized** segments are written; volatile (in-progress) hypotheses and
empty/whitespace-only text are never persisted. Keys are emitted in sorted order
for stable, diffable output.

Each line (`FinalizedSegmentDTO`, defined in
`Sources/AlembicKit/TranscriptEvent.swift`):

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | Int | Canonical schema version (currently `1`). |
| `start` | Double | Session-relative start time in seconds (audio-time based). |
| `end` | Double | Session-relative end time in seconds. |
| `source` | String | `"you"` (microphone) or `"them"` (meeting audio). |
| `text` | String | Finalized, trimmed text for the segment. |
| `attribution` | object \| omitted | Optional provenance `{ "source": String, "confidence": Double?, "displayName": String? }`. Omitted from JSON when `nil`; `displayName` (also optional) is likewise omitted when absent. |

Example line:

```json
{"end":4.2,"schemaVersion":1,"source":"you","start":1.0,"text":"Hello everyone"}
```

`attribution.source == "vision"` indicates a name resolved via on-device Vision
OCR of the active-speaker tile (opt-in, Teams only, MVP signal #2 — see
[Speaker attribution](#speaker-attribution) below). Example line with
attribution:

```json
{"attribution":{"confidence":0.82,"displayName":"Jane Doe","source":"vision"},"end":6.4,"schemaVersion":1,"source":"them","start":4.9,"text":"Let's start with the roadmap"}
```

The `.md` render mirrors each finalized segment as `[hh:mm:ss] source: text`,
deriving the timestamp from the segment `start`. When the segment carries a
resolved `attribution.displayName`, the render instead shows
`[hh:mm:ss] <displayName> (<source>): text`.

## Privacy

Alembic's core guarantee is that **no audio and no transcript data leaves the
machine.** Recognition is performed by Apple's **on-device** `SpeechAnalyzer` /
`SpeechTranscriber` stack.

- The Swift sources contain **no networking code** — no `URLSession`,
  `URLRequest`, `NWConnection`/Network.framework, sockets, streams, or HTTP of
  any kind. (Verified by audit; reproduce with the grep in
  [MANUAL-VALIDATION.md](MANUAL-VALIDATION.md).)
- The **only** non-local interaction is Apple's on-device speech **model-asset
  download** (`AssetInventory.assetInstallationRequest(...).downloadAndInstall()`
  in `Sources/AlembicKit/Platform/macOS/SpeechAssetManager.swift`). This is a
  one-time download of model files *from* Apple when they are not already
  installed — **no audio is ever sent to Apple**; recognition runs locally.
- Transcripts are **sensitive at rest**, stored only under `~/Documents/Alembic/`.
  The resolved path is surfaced in the UI ("Reveal in Finder") so you always
  know where your meeting is stored.

## Permissions

Alembic needs **three** macOS permissions, which fail independently and each
gate recording:

| Permission | Why | `Info.plist` usage string |
|---|---|---|
| **Microphone** | Capture your own voice ("you"). | `NSMicrophoneUsageDescription` |
| **Speech Recognition** | On-device transcription. | `NSSpeechRecognitionUsageDescription` |
| **Screen Recording** | Per-app audio capture of the meeting app ("them") via ScreenCaptureKit. | granted at runtime via TCC (no usage string) |

> **Screen Recording restart caveat.** macOS grants Screen Recording but
> `CGPreflightScreenCaptureAccess()` only returns effective *after the app
> relaunches*. Alembic detects this "granted-but-needs-restart" condition and
> surfaces a **"Quit & Reopen"** action (`PermissionState.requiresRestart`)
> rather than a misleading "denied". After relaunching, capture works.

## License / status

Internal project. The legacy Obsidian/TypeScript plugin (`src/*.ts`, `main.ts`,
`swift-helper/`) lives at the repository root and is not part of this SwiftPM
build — it is retained for historical reference only.
