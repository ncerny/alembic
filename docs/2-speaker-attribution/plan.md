<!-- markdownlint-disable-file -->
# Task Plan: Speaker Attribution (named "them" speakers)

Execution plan for `docs/2-speaker-attribution/spec.md`, grounded in
`docs/2-speaker-attribution/research.md`. Phased so that **end-to-end attribution works with a fake
provider (Phases 1–3) before any Vision/capture work (Phases 4–6)**, keeping every phase independently
verifiable via the authoritative runner `swift run AlembicCheck`.

**Guiding constraints (from SPEC):** privacy invariant intact (NR-1), Foundation-only top-level +
Apple code under `Platform/macOS/` (NR-2), no new TCC prompt (NR-3), attribution is strictly orthogonal
to ASR — any failure degrades to plain `them` and never drops/reorders/corrupts a segment
(SR-16/NR-6), opt-in and off-by-default with a byte-identical off state (UR-1/UR-4).

---

## Phased Overview

| Phase | Deliverable | Spec coverage | Apple imports? |
|---|---|---|---|
| 1 | Additive `displayName` schema + `.md` render | DR-1..4, SR-18/19, UR-5 | No (pure) |
| 2 | Pure core: provider protocol, timeline, normalizer, catalog data | SR-1, SR-9..13, SR-20/21, DR-4, SR-24/25 | No (pure) |
| 3 | `MeetingSession.ingest` injection + fake-provider E2E | SR-14..17, SR-15, NR-2/NR-6 | No (pure) |
| 4 | `ScreenCaptureKitSource` video-frame stream (gated) | SR-3/4/8, NR-3/4, UR-4 | Yes |
| 5 | `VisionSpeakerAttributor` OCR impl (Teams, signal #2) | SR-2/5/6/7/23 | Yes |
| 6 | Settings toggle + `AppModel.makeSession` wiring | UR-1..5, NR-2/NR-3 | Yes (AppKit) |
| 7 | Frame-dump diagnostic + manual validation + tuning | SR-22, AC-4, OQ-1..4, NR-5 | Yes |

Phases 1→3 are the critical path and land a fully-tested attribution pipeline (fake provider). Phases
4→6 supply the real macOS signal behind the opt-in toggle. Phase 7 is live tuning + maintenance tooling.

---

## Phase 1 — Additive schema + human-readable render

**Goal:** carry a speaker name through the model, the canonical JSONL, and the `.md` render, additively.

**Changes:**
* `Sources/AlembicKit/TranscriptEvent.swift`
  * Add `public let displayName: String?` to `TranscriptAttribution` (default `nil` in `init`).
    Confirm `Codable` omits it when `nil` (struct of optionals already encodes that way; add a check).
  * No change to `schemaVersion` (stays `1`) — the field is optional/omitted (DR-1).
* `Sources/AlembicKit/TranscriptWriter.swift`
  * Update `readableLine(for:)`: when `dto.attribution?.displayName` is non-empty, render
    `"[hh:mm:ss] <name> (<source>): <text>"`; otherwise keep today's `"[hh:mm:ss] <source>: <text>"`
    (SR-19/UR-5). Keep canonical JSONL as the untouched `FinalizedSegmentDTO` encoding.
* `Sources/AlembicCheck/AlembicCheck.swift`
  * New checks: `displayName` round-trips (present + omitted-when-nil), back-compat decode of a legacy
    line with no `displayName`, and `readableLine` renders both the named and unnamed forms (DR-1/DR-2).

**Validation:** `swift run AlembicCheck` green; manual grep confirms `schemaVersion` unchanged.
**Spec:** DR-1, DR-2, DR-3 (unchanged bound re-asserted), SR-18, SR-19, UR-5.

---

## Phase 2 — Pure attribution core (Foundation-only)

**Goal:** all non-Apple attribution logic, fully unit-tested, with a fake provider for later phases.

**New files (all `Sources/AlembicKit/`, Foundation-only):**
* `AttributionProvider.swift` — `public protocol AttributionProvider: Sendable`, e.g.
  `func name(forThemSegment range: ClosedRange<Double>) async -> AttributionResult?` where
  `AttributionResult = (displayName: String, confidence: Double)`. (SR-1). Query is `async` and
  best-effort; implementations must return promptly (SR-17).
* `ActiveSpeakerTimeline.swift` — value type storing `[(range: ClosedRange<Double>, name: String,
  confidence: Double)]`; `resolve(window:)` returns the **dominant-overlap** name subject to
  `minOverlapFraction` and `minConfidence` (τ), else `nil`; deterministic tie-break (e.g. earliest
  interval, then lexical). Includes an `append`/merge that coalesces adjacent same-name intervals and
  bounds retained history to the session. (SR-9/10/11/12/13, OQ-1/OQ-4).
* `SpeakerNameNormalizer.swift` — trims, collapses OCR jitter, expands "Last, First" → natural order
  (reuse the existing helper in `VocabularyStore`; refactor it to a shared function if needed), and
  optionally snaps to a supplied roster allow-list within an edit-distance bound (SR-25 hook, unused in
  MVP). (DR-4).
* `SpeakerLabelCatalog.swift` — **data** describing, per meeting-app family, the OCR region(s) and
  active-tile markers; ships a Teams (`com.microsoft.teams2*`) entry. Mirrors
  `MeetingChatMarkers.teamsDefaults`: markers are data, not control flow (SR-20/21). Includes a
  `match(bundleID:)` returning the entry or `nil` (SR-23).
* Test double `FakeAttributionProvider` (in `AlembicKit` or the check target) returning scripted
  results for E2E tests.

**Checks (`AlembicCheck.swift`):** `checkActiveSpeakerTimeline` (dominant overlap, threshold reject,
straddle→nil, determinism), `checkSpeakerNameNormalizer` (trim/jitter/"Last, First"), `checkSpeakerLabelCatalog`
(Teams match + unknown→nil). (NR-5, AC-1).

**Validation:** `swift run AlembicCheck` green.
**Spec:** SR-1, SR-9–13, SR-20/21, SR-24 (protocol shaped to accept future feeders), SR-25 (hook), DR-4.

---

## Phase 3 — `MeetingSession.ingest` injection + end-to-end (fake provider)

**Goal:** wire the provider into the one choke point and prove attributed `.them` events flow through
the writer, with `.you`/volatile untouched and failures degrading cleanly.

**Changes (`Sources/AlembicKit/MeetingSession.swift`, Foundation-only):**
* Add an **optional** injected `attributionProvider: (any AttributionProvider)?` to `init` (default
  `nil`, preserving all existing call sites/tests). (NR-2, UR-4 at the model layer).
* In `ingest(_:)`, for `event.kind == .finalized && event.source == .them` **and** a provider is
  present: `await` a **bounded/best-effort** `provider.name(forThemSegment:)`; on a result, rebuild the
  event with `attribution = TranscriptAttribution(source: "vision", confidence:, displayName:)` **before**
  `insertFinalized` + `writer.append`. On `nil`/throw/timeout: proceed unchanged (SR-16/NR-6).
* Guarantee the lookup cannot delay `stop()`'s drain/close ordering beyond current behavior — the query
  runs inline in the already-awaited `ingest` on the finalized path; document the bounded-time
  expectation on the protocol (SR-17). (If needed, wrap with a small timeout helper.)

**Checks (`AlembicCheck.swift`):**
* `checkAttributionInjectionEndToEnd`: build a `MeetingSession` with `FakeAudioSource`,
  `FakeTranscriptionEngine`, an in-memory writer probe, and a `FakeAttributionProvider`; assert
  finalized `.them` events land attributed with `source == "vision"` + name; `.you`/volatile stay nil
  (SR-14/15, AC-5).
* `checkAttributionFailureIsInert`: provider that always returns `nil`/throws → transcript identical to
  the no-provider baseline; no dropped/reordered segments (SR-16/NR-6, AC-6).

**Validation:** `swift run AlembicCheck` green; existing MeetingSession checks still pass (nil default).
**Spec:** SR-14, SR-15, SR-16, SR-17, NR-2, NR-6, AC-5, AC-6.

> **Milestone:** after Phase 3, attribution is fully functional and tested with a fake provider. The
> remaining phases only supply the real on-screen signal.

---

## Phase 4 — Video-frame stream in `ScreenCaptureKitSource` (gated)

**Goal:** deliver meeting-window frames on a stream separate from audio, only when attribution is
enabled; off state stays byte-identical to today (2×2 throwaway plane, audio-only output).

**Changes (`Sources/AlembicKit/Platform/macOS/ScreenCaptureKitSource.swift`):**
* Add an **opt-in capture mode** (e.g. `start(target:attributionEnabled:)` or an injected flag) so that
  when disabled, `config.width/height` stay `2×2`, no `.screen` output is registered, and behavior is
  unchanged (UR-4).
* When enabled: set a real (but minimal-sufficient) `config.width/height`, register a `.screen`
  `StreamFrameOutput` (new `@unchecked Sendable` `SCStreamOutput`, modeled on `StreamAudioOutput`) that
  converts each `CMSampleBuffer` → a `Sendable` frame snapshot (e.g. `CVPixelBuffer`-backed value +
  session-clock timestamp) and `yield`s to a new `nonisolated let frames: AsyncStream<CapturedFrame>`;
  the callback never `await`s the actor (SR-3/SR-4).
* Bound capture to the meeting window/PID family (reuse `WindowTitleProbe`/PID resolution) so unrelated
  content is excluded (SR-8).
* Keep the audio path and its QoS exactly as-is; frames are an independent stream so OCR back-pressure
  cannot affect audio (SR-3, NR-4).
* Decide resolution vs. periodic-snapshot per OQ-2 (default: low-res continuous `.screen` at the
  existing 1 fps cap, upscaled only if OCR fidelity requires — settle in Phase 7 tuning).

**Validation:** `swift build -c release`; `swift run AlembicCheck` green (no behavioral checks here —
this is Apple-only capture); manual smoke that audio capture is unaffected with the flag off and on.
**Spec:** SR-3, SR-4, SR-8, NR-3, NR-4, UR-4.

---

## Phase 5 — `VisionSpeakerAttributor` (Teams, signal #2)

**Goal:** the real provider: OCR the active-speaker tile label over catalogued regions and build the
`ActiveSpeakerTimeline`.

**New file (`Sources/AlembicKit/Platform/macOS/VisionSpeakerAttributor.swift`):**
* Conforms to `AttributionProvider`; owns the `ActiveSpeakerTimeline` (thread-safe via the established
  `NSLock`-guarded `@unchecked Sendable` box pattern, per `LocaleBox`/`VocabularyBox`).
* Consumes `ScreenCaptureKitSource.frames`; throttles OCR to ≈1–2 Hz (SR-6); for each sampled frame,
  looks up the Teams catalog entry (SR-23 — unknown app ⇒ produce nothing), runs `RecognizeTextRequest`
  over the catalogued active-tile region, detects the active tile per the entry's markers/geometry, and
  extracts + normalizes the name (SpeakerNameNormalizer), appending `(timeRange, name, confidence)` with
  OCR confidence as the base value (SR-5/SR-7).
* `name(forThemSegment:)` delegates to `ActiveSpeakerTimeline.resolve` (SR-1).
* All errors (model unavailable, no frames, OCR failure, window not found) are swallowed → no
  attribution (NR-6).
* `import Vision` (+ CoreMedia/CoreVideo) stays isolated to this file (NR-2/SR-2).

**Validation:** `swift build -c release` green; pure logic already covered in Phase 2; the Vision/live
path is validated manually in Phase 7 (SR/NR per NR-5).
**Spec:** SR-2, SR-5, SR-6, SR-7, SR-23.

---

## Phase 6 — Settings toggle + `AppModel` wiring

**Goal:** user-facing opt-in and composition-root wiring; off state is a no-op.

**Changes:**
* `Sources/Alembic/SettingsView.swift` — add an `@AppStorage`-backed toggle
  (e.g. `alembic.attribution.enabled`, default `false`) with copy stating on-device / no data leaves the
  Mac and that names may be approximate (UR-1/UR-2/UR-3).
* `Sources/Alembic/AppModel.swift` — in `makeSession`, when the toggle is on, construct a
  `VisionSpeakerAttributor`, put `ScreenCaptureKitSource` in attribution-capture mode, and pass the
  provider into `MeetingSession(init:)`; when off, pass `nil` and leave capture in the 2×2 audio-only
  mode (UR-4). Reads the toggle at session start (consistent with how `LocaleBox`/`VocabularyBox` are
  filled). Wiring stays only here (NR-2).
* `Sources/Alembic/LiveTranscriptView.swift` — show the attributed name when present, fall back to
  `them`, no layout regression (UR-5).

**Validation:** build + launch; toggle off ⇒ output identical to baseline (AC-3); toggle on ⇒ frames
flow to the attributor. `swift run AlembicCheck` green.
**Spec:** UR-1, UR-2, UR-3, UR-4, UR-5, NR-2, NR-3.

---

## Phase 7 — Diagnostic, manual validation, tuning

**Goal:** maintenance tooling + close the open questions with live data.

**Changes:**
* `Sources/AlembicCheck/` — a `frame-dump`/`region-dump` subcommand (analogous to `ax-dump`) that, from
  a live Teams meeting, captures a frame and dumps OCR observations + bounding boxes so the Teams
  active-tile region/markers in `SpeakerLabelCatalog` can be (re-)derived after UI changes (SR-22).
* `app/Alembic/MANUAL-VALIDATION.md` — add a section: enable the toggle, join a multi-person Teams call
  (speaker + grid view), confirm at least one far-end segment is attributed with the correct name at
  `source == "vision"`, and ambiguous/off-screen cases fall back to `them` with no dropped segments
  (AC-4).
* Tune `τ` (min confidence) and `minOverlapFraction` (OQ-1), settle resolution/snapshot strategy (OQ-2),
  finalize Teams tile geometry/active detection (OQ-3), and the multi-speaker-per-segment representation
  (OQ-4); fold decisions back into `SpeakerLabelCatalog` + `ActiveSpeakerTimeline` defaults.

**Validation:** manual in-meeting per AC-4; privacy grep + layering audit (AC-2); off-toggle baseline
diff (AC-3).
**Spec:** SR-22, AC-2, AC-3, AC-4, OQ-1..4, NR-5.

---

## Requirements Coverage Matrix

| Requirement | Phase(s) |
|---|---|
| SR-1 | 2 |
| SR-2 | 5 |
| SR-3, SR-4, SR-8 | 4 |
| SR-5, SR-6, SR-7 | 5 |
| SR-9–SR-13 | 2 |
| SR-14–SR-17 | 3 |
| SR-15 | 3 |
| SR-18, SR-19 | 1 |
| SR-20, SR-21 | 2 |
| SR-22, SR-23 | 5, 7 (SR-22 in 7; SR-23 in 5) |
| SR-24, SR-25 | 2 |
| DR-1–DR-4 | 1 (DR-4 also 2) |
| NR-1 | all (audit in 7) |
| NR-2 | 2, 3, 5, 6 |
| NR-3 | 4, 6 |
| NR-4 | 4 |
| NR-5 | 1, 2, 3, 7 |
| NR-6 | 3, 5 |
| UR-1–UR-5 | 6 (UR-5 also 1) |
| AC-1 | 1, 2 |
| AC-2, AC-3, AC-4 | 7 |
| AC-5, AC-6 | 3 |

---

## Risks & Mitigations

* **New-Teams AX/UI churn breaks tile detection.** Mitigation: markers/geometry are **data**
  (`SpeakerLabelCatalog`) re-derivable via the Phase-7 frame-dump; failure path is inert (`them`).
* **OCR fidelity on small overlay type.** Mitigation: tune resolution (OQ-2) + `minimumTextHeightFraction`;
  the whole feature is opt-in and degrades to `them`.
* **Performance/thermals from continuous OCR.** Mitigation: separate frame stream (never blocks audio),
  ≈1–2 Hz throttle, region-only OCR, minimal resolution (SR-3/SR-6/NR-4).
* **Accidental privacy regression.** Mitigation: Vision/AX only, no networking; AC-2 grep gate every PR.
* **Schema drift.** Mitigation: additive optional field, `schemaVersion` unchanged, back-compat decode
  test (DR-1/DR-2).

---

## Definition of Done

* All phases' `AlembicCheck` checks pass (`swift run AlembicCheck` exits 0).
* Privacy grep (NR-1) and layering audit (NR-2) clean; `schemaVersion` still `1`.
* Toggle **off** ⇒ output byte-identical to pre-feature baseline (AC-3).
* Manual Teams validation (AC-4) demonstrates correct named attribution with graceful `them` fallback.
* No unrelated changes; docs (`MANUAL-VALIDATION.md`, README schema table) updated for `displayName`.
