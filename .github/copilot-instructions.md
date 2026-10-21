# Copilot Instructions for Alembic

Alembic is a **macOS menu-bar app** (macOS 26+) that produces real-time,
timestamped meeting transcripts entirely on-device. It captures two audio
streams — microphone ("you") and a meeting app's audio ("them") — runs both
through Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber`, and writes
a crash-safe JSONL transcript to disk as the meeting happens.

**No audio and no transcript data ever leaves the machine.**

The active project is under `app/Alembic/`. The root-level `src/`, `main.ts`,
and `swift-helper/` are a legacy TypeScript Obsidian plugin — retained for
historical reference but **not actively maintained**.

## Build Commands

```bash
cd app/Alembic

bash build.sh --make-cert   # ONE TIME: create a stable self-signed cert (keeps TCC grants across rebuilds)
bash build.sh               # clean release build → assemble → sign → verify
bash build.sh --run         # same, then open the built Alembic.app
bash build.sh --reset-tcc   # clear Alembic's permission grants (useful after switching signing identity)
bash build.sh --help        # usage

swift build -c release      # SwiftPM release build only (no app bundle)
swift run AlembicCheck      # AUTHORITATIVE test runner — exits non-zero on failure
```

> **Why `swift run AlembicCheck` and not `swift test`?**
> Under Command Line Tools only (no Xcode.app), `swift test` builds the test
> target but **does not execute** it — a failing test still exits 0. `AlembicCheck`
> is a plain `async @main` executable that exits non-zero on any failure and is the
> real acceptance command for this repo.

## Package Structure

Single SwiftPM package at `app/Alembic/Package.swift`, four targets:

| Target | Kind | Role |
|---|---|---|
| **AlembicKit** | library | Platform-agnostic core + all testable logic. Apple-framework code (Speech, ScreenCaptureKit, AVFoundation) lives under `Sources/AlembicKit/Platform/macOS/`. Top-level files must stay Foundation-only. |
| **Alembic** | executable (`@main`) | Thin SwiftUI menu-bar shell. `AppModel` is the composition root. Kept free of testable business logic. |
| **AlembicCheck** | executable | Authoritative test runner. Add new check functions here and call them from `runAllChecks`. |
| **AlembicTests** | test target | swift-testing suite — builds but does not execute under CLT. Not authoritative. |

## Architecture

### Key files

- **`Sources/Alembic/AlembicApp.swift`** — `@main` SwiftUI app. Declares `MenuBarExtra` and `Window` scenes (`live-transcript`, `alembic-settings`).
- **`Sources/Alembic/AppModel.swift`** — `@Observable @MainActor` composition root. `makeSession(meetingName:localeBox:vocabularyBox:)` is the only place that wires `MeetingSession` to `ScreenCaptureKitSource` and `SpeechAnalyzerEngine`. Contains `LocaleBox` and `VocabularyBox` (NSLock-guarded thread-safe containers). `settingsWindowID` and `liveWindowID` are the canonical scene IDs.
- **`Sources/Alembic/AlembicMenu.swift`** — Menu-bar pull-down. Opens the live transcript and settings windows.
- **`Sources/Alembic/LiveTranscriptView.swift`** — Real-time caption display + input meters + controls.
- **`Sources/Alembic/SettingsView.swift`** — Vocabulary hint settings (inline terms, file path, folder path). Uses `@AppStorage` and `NSOpenPanel`.
- **`Sources/AlembicKit/MeetingSession.swift`** — Session orchestrator and state machine. Merges "you"/"them" audio sources onto a single session-clock timeline.
- **`Sources/AlembicKit/TranscriptWriter.swift`** — Crash-safe JSONL writer. Flushes after every finalized segment.
- **`Sources/AlembicKit/VocabularyStore.swift`** — Loads vocabulary hints from three sources (inline > file > folder), deduplicates, enforces ~500-term Apple limit, and expands "Last, First" names to natural order. `recommendedMaxTerms = 500`.
- **`Sources/AlembicKit/Platform/macOS/SpeechAnalyzerEngine.swift`** — macOS 26 `SpeechTranscriber` + `SpeechAnalyzer` actor. Accepts `contextualStrings: [String]` at init; calls `analyzer.setContext(_:)` before starting analysis.
- **`Sources/AlembicKit/Platform/macOS/ScreenCaptureKitSource.swift`** — The macOS `AudioSource`: starts `ProcessTapCapture` ("them") + the `AVAudioEngine` mic ("you"). Uses ScreenCaptureKit only for target enumeration and the opt-in attribution video stream.
- **`Sources/AlembicKit/Platform/macOS/ProcessTapCapture.swift`** — Meeting audio via a Core Audio process tap (private, unmuted, tap-only aggregate device) on the app's process family; re-targets as processes come and go. **Never capture audio with an `SCStream`**: an active stream marks the screen as shared and silences notifications for the whole meeting.
- **`Sources/AlembicKit/ContiguousAudioTimeline.swift`** — Keeps the tap and mic streams gap-free from session time 0 (silence heartbeat, gap fill, overlap trim), because `SpeechAnalyzer` times results by audio fed; without it "you" and "them" timestamps drift apart.
- **`Sources/AlembicKit/Platform/macOS/SpeechAssetManager.swift`** — Downloads on-device speech model assets from Apple (one-time; no audio is sent).
- **`Sources/AlembicKit/TranscriptionEngine.swift`** — Protocol. `contextualStrings` is **not** on the protocol — it is `SpeechAnalyzerEngine`-specific.
- **`Sources/AlembicCheck/AlembicCheck.swift`** — All check functions + `runAllChecks`. Add new functions here.

### Audio pipeline

```
ProcessTapCapture ("them")       ──┐
                                   ├──▶  MeetingSession  ──▶  SpeechAnalyzerEngine  ──▶  TranscriptWriter
AVAudioEngine mic ("you")        ──┘      (per-source)        (per-source, macOS 26)     (JSONL + .md)
```

### macOS 26 Speech API details

- `SpeechAnalyzer(modules:options:)` — convenience init (no `analysisContext:` param).
- `SpeechAnalyzer.setContext(_ newContext: AnalysisContext) async throws` — call **after** creating the analyzer, **before** `start(inputSequence:)`.
- `AnalysisContext()` — `@objc init()`, reference type, `Sendable`.
- `AnalysisContext.contextualStrings` — `[ContextualStringsTag: [String]]` read-write property.
- `AnalysisContext.ContextualStringsTag.general` — correct key for general vocabulary biasing.
- Feed `AnalyzerInput(buffer:)` without `bufferStartTime` — explicit timestamps produce zero results.
- Apple recommends <500 terms for `contextualStrings`; exceeding this may degrade quality.
- `SpeechAnalyzer` is long-lived (do **not** restart mid-session); a single analyzer handles the full recording.

### Vocabulary injection (UserDefaults keys)

| Key | Role |
|---|---|
| `alembic.vocabulary.inline` | Comma-separated string of highest-priority terms |
| `alembic.vocabulary.filePath` | Path to a plain-text file (one term per line, `#` comments) |
| `alembic.vocabulary.folderPath` | Path to a Markdown folder (basenames → hints) |

`VocabularyBox` is filled in `AppModel.start()` via `Task.detached(priority: .userInitiated)` to avoid blocking the main actor. It is read synchronously by the `@Sendable` engine factory inside `makeSession`.

### Transcript output

```
~/Documents/Alembic/<yyyy-MM-dd_HHmm>-<meeting>.jsonl   ← canonical
~/Documents/Alembic/<yyyy-MM-dd_HHmm>-<meeting>.md      ← human-readable
```

Each JSONL line is a `FinalizedSegmentDTO`: `schemaVersion`, `start`, `end`,
`source` (`you`/`them`), `text`, optional `attribution`.

## Conventions

- **Foundation-only in top-level AlembicKit** — Apple-framework imports (AVFoundation, CoreMedia, ScreenCaptureKit, Speech, CoreGraphics) go only under `Sources/AlembicKit/Platform/`.
- **SwiftUI + AppKit for UI** — `SettingsView` uses `NSOpenPanel` (AppKit), which is fine in the `Alembic` executable target. `AlembicKit` has no UI code.
- **Thread-safe boxes via NSLock** — `LocaleBox` and `VocabularyBox` use an `NSLock`-guarded property and are `@unchecked Sendable`. Follow this pattern for any new cross-actor shared state.
- **Add checks to AlembicCheck** — pure deterministic logic (parsing, math, state machines) belongs in a `checkX` function in `AlembicCheck.swift`, called from `runAllChecks`. This is the only test mechanism that executes under CLT.
- **No networking in AlembicKit or Alembic** — `URLSession`, `URLRequest`, sockets, etc. are prohibited in both targets. The privacy guarantee is enforced by convention and verified by static audit.
- **Composition root is `AppModel.makeSession`** — only this function wires live platform implementations to `MeetingSession`. Tests use `FakeAudioSource` and `FakeTranscriptionEngine`.

## CI & releases

- `.github/workflows/ci.yml` — PRs and pushes to `main` on `macos-26`: `swift run AlembicCheck`, privacy grep, `bash build.sh`.
- `.github/workflows/release.yml` — release-please (Conventional Commits drive semver: `fix` → patch, `feat` → minor, breaking → minor pre-1.0), running as a GitHub App (`RELEASE_APP_CLIENT_ID` var, `RELEASE_APP_PRIVATE_KEY` secret). Release PRs are auto-approved (GITHUB_TOKEN) and auto-merged (App token) once CI passes, so merging a `feat`/`fix` ships a release. Merging tags `vX.Y.Z`; the build job signs with "Alembic Self-Signed" from the `ALEMBIC_SIGNING_P12_*` secrets and attaches `Alembic-X.Y.Z-macos-arm64.zip` + `.sha256`.
- `main` ruleset: PR + passing `Build and check` required (0 approvals — sole maintainer; admin bypass).
- Don't hand-edit the version: release-please updates `.release-please-manifest.json`, `CHANGELOG.md`, and `Info.plist` (`x-release-please-version` marker). Actions are pinned by commit SHA.

## Signing & TCC

- Ad-hoc signing (`codesign --sign -`) changes the code hash on every rebuild, breaking TCC Screen Recording grants.
- `bash build.sh --make-cert` creates a stable self-signed identity; grants survive rebuilds.
- After switching from ad-hoc to a stable identity, run `bash build.sh --reset-tcc` once to clear stale grants.
- Screen Recording requires an app relaunch after the initial grant (`CGPreflightScreenCaptureAccess()` only returns `true` after relaunch). Alembic surfaces this as `PermissionState.requiresRestart`.
- System Audio Recording (`kTCCServiceAudioCapture`, `NSAudioCaptureUsageDescription`) has no public status API; `CapturePreflight` uses the TCC SPI (`dlsym`) and requests explicitly — the implicit prompt Core Audio raises at tap start is easily missed. Process taps can't be exercised from `swift run` (the terminal lacks the usage string); test them in the signed app bundle.

## Privacy invariant

The Swift sources contain no networking code. Verify at any time:

```bash
grep -rniE 'URLSession|URLRequest|NWConnection|Network\.|Socket|https?://|WebSocket' Sources/
# Expected: no matches
```

The only network activity is a one-time Apple speech model-asset download
(`SpeechAssetManager`). No audio or transcript text is transmitted.

