<!-- markdownlint-disable-file -->
# Task Spec: Speaker Attribution (named "them" speakers)

Numbered requirements baseline for attributing a **named participant** to far-end ("them")
transcript segments, derived entirely from on-device, on-screen signals. Authored from
`docs/2-speaker-attribution/research.md`; precedes the implementation plan.

Requirement keywords **MUST**, **SHOULD**, **MAY** are used per RFC 2119. Each requirement has a
stable ID (`SR-*` functional, `NR-*` non-functional, `DR-*` data/schema, `UR-*` UX). IDs are permanent
once assigned.

---

## 1. Goal & Definitions

The far-end transcript currently tags every remote utterance with the generic `them`. This feature
resolves the **speaking participant's display name** for each finalized `.them` segment and records it
alongside the segment, degrading to plain `them` whenever a name cannot be determined.

* **Attribution** — a `(source, confidence, displayName)` provenance record attached to a
  `TranscriptEvent` / `FinalizedSegmentDTO`.
* **Active-speaker tile** — the meeting-app UI tile visually focused/outlined for the current speaker.
* **`ActiveSpeakerTimeline`** — an in-memory, session-relative store of `(timeRange, name, confidence)`
  intervals produced by the attribution provider.
* **MVP signal (#2)** — Vision OCR of the active-speaker tile name label. This is the only attribution
  signal in scope for this spec (see §7).

---

## 2. Scope

* **In scope:** named attribution of the **`.them`** source only, via on-device Vision OCR of the
  active-speaker tile (signal #2), for **Microsoft Teams** (`com.microsoft.teams2` family) first,
  behind an opt-in setting, persisted additively in the transcript, with graceful fallback to `them`.
* **Explicitly out of scope (this spec):** signal #1 (caption-prefix OCR), signal #3 (AX roster
  dictionary), signal #4 (AX dynamic active-speaker attribute), audio diarization, any network/roster
  API, attribution of the `.you` source, and apps other than Teams. The architecture MUST NOT preclude
  adding these later (see §7 SR-24).

---

## 3. Functional Requirements — Attribution provider

* **SR-1** The system **MUST** define a Foundation-only, `Sendable` `AttributionProvider` protocol in
  `AlembicKit` that, given a `.them` segment's session-relative `[start, end]` window, returns an
  optional `(displayName, confidence)` result.
* **SR-2** The live macOS implementation (`VisionSpeakerAttributor`) **MUST** reside under
  `Sources/AlembicKit/Platform/macOS/` and be the only component importing `Vision` / ScreenCaptureKit
  video for this feature.
* **SR-3** `ScreenCaptureKitSource` **MUST** deliver meeting-window video frames on a stream **separate**
  from the audio path, such that OCR work can never back-pressure, stall, or drop audio delivery.
* **SR-4** Frame delivery **MUST** use the existing `@unchecked Sendable` callback→`AsyncStream` bridge
  pattern (mirroring `StreamAudioOutput`): no non-`Sendable` Apple frame object may cross an actor
  boundary, and the capture callback **MUST NOT** `await` the actor.
* **SR-5** The provider **MUST** run OCR (`RecognizeTextRequest`) over a **catalogued region** of the
  captured frame rather than the whole frame, using per-app label geometry (see SR-20).
* **SR-6** OCR passes **MUST** be throttled to a bounded rate (target ≈1–2 Hz; the exact rate is a
  tuning parameter) to bound CPU/GPU cost; the provider **MUST NOT** run OCR per video frame.
* **SR-7** The provider **MUST** maintain an `ActiveSpeakerTimeline` of `(timeRange, name, confidence)`
  intervals on the **session clock** (same basis as `AudioChunk.startTime` / segment times).
* **SR-8** Capture **MUST** be bounded to the resolved meeting window (via `WindowTitleProbe`/PID
  family resolution) so unrelated on-screen content is never OCR'd.

## 4. Functional Requirements — Timeline → segment assignment

* **SR-9** `ActiveSpeakerTimeline` resolution **MUST** be pure, Foundation-only logic in `AlembicKit`
  (no Apple imports), independently unit-testable via `AlembicCheck`.
* **SR-10** For a segment window `[start, end]`, the timeline **MUST** resolve the name by **dominant
  temporal overlap** (the name whose intervals cover the largest fraction of the window).
* **SR-11** A resolution **MUST** be accepted only when its confidence ≥ a configurable threshold `τ`
  and its dominant-overlap fraction ≥ a configurable minimum; otherwise it resolves to **no name**.
* **SR-12** When a segment straddles a speaker change with no clear dominant speaker (below the overlap
  minimum), the system **MUST** resolve to **no name** (it MUST NOT guess or fabricate a name).
* **SR-13** The timeline resolver **MUST** be deterministic for identical inputs (stable tie-breaking).

## 5. Functional Requirements — Injection & persistence

* **SR-14** `MeetingSession.ingest(_:)` **MUST** be the single injection point: for each **finalized**
  event with `source == .them`, it queries the provider and, on a resolved name, attaches attribution
  **before** `insertFinalized` and `writer.append`.
* **SR-15** Attribution **MUST** be applied only to `.them` finalized events. `.you` events and all
  volatile events **MUST** remain unattributed by this feature.
* **SR-16** A missing, failed, timed-out, or below-threshold lookup **MUST** leave `attribution == nil`
  (or without a `displayName`), and the segment **MUST** persist exactly as it does today (plain
  `them`). Attribution failure **MUST NOT** drop, delay, reorder, or corrupt any segment.
* **SR-17** The provider query in `ingest` **MUST** be non-blocking with respect to the drain/close
  ordering guarantees in `MeetingSession.stop()` (it MUST NOT delay writer close beyond existing
  behavior; a bounded/best-effort lookup is required).
* **SR-18** When a name is attributed, the JSONL line **MUST** carry `attribution.source == "vision"`,
  a `confidence`, and the resolved `displayName` (see DR-1).
* **SR-19** The human-readable `.md` transcript **MUST** render an attributed line with the name (e.g.
  `**Alex Kim (them):**`) and **MUST** fall back to `**them:**` when no name is present.

## 6. Functional Requirements — Per-app catalog (Teams)

* **SR-20** Per-app OCR region + active-tile markers **MUST** be expressed as **data** (a
  `SpeakerLabelCatalog`, mirroring `MeetingChatMarkers.teamsDefaults`), not control flow, so they can
  be re-derived after an app UI update without changing search logic.
* **SR-21** The catalog **MUST** ship Teams (`com.microsoft.teams2` family) markers for MVP and **MUST**
  be structured to add further apps (Zoom/Meet/…) as additional data entries.
* **SR-22** A diagnostic **MUST** exist to re-derive Teams markers from a live meeting (a frame/region
  dump analogous to `AlembicCheck ax-dump`), enabling maintenance when Teams changes its UI.
* **SR-23** When the target app/window is not Teams (or no catalog entry matches), the provider **MUST**
  produce no attribution (segments stay `them`) rather than OCR'ing an unknown layout.

## 7. Forward-compatibility

* **SR-24** The design **MUST** allow signal #1 (caption-prefix OCR) to be added later as an additional
  feeder into the **same** `ActiveSpeakerTimeline` and, when present, as a **higher-confidence
  override**, with **no change** to the `AttributionProvider` protocol, the `ingest` query path, or the
  on-disk schema.
* **SR-25** The design **SHOULD** allow an optional AX roster read (signal #3) to supply a name
  allow-list for normalization, without making attribution depend on the Accessibility permission.

## 8. Data / Schema Requirements

* **DR-1** `TranscriptAttribution` **MUST** gain an **optional** `displayName: String?` field. The
  addition **MUST** be additive: the canonical JSONL `schemaVersion` **MUST** remain `1`, and
  `displayName` **MUST** be omitted from JSON when `nil`.
* **DR-2** Existing persisted transcripts (no `displayName`) **MUST** decode unchanged; existing
  `AlembicCheck` / `CoreModelTests` attribution round-trips (asserting only `source`/`confidence`)
  **MUST** continue to pass.
* **DR-3** `confidence` **MUST** remain within `[0, 1]`.
* **DR-4** `displayName`, when present, **MUST** be a normalized display string (trimmed; "Last, First"
  expanded to natural order via the existing `VocabularyStore` helper; internal OCR jitter collapsed).

## 9. Non-Functional Requirements

* **NR-1 (Privacy invariant)** No networking may be added anywhere in `AlembicKit`/`Alembic`. The audit
  grep in `.github/copilot-instructions.md` (`URLSession|URLRequest|NWConnection|…`) **MUST** remain
  empty. Names **MUST** be derived only from on-device Vision/AX over already-on-screen pixels.
* **NR-2 (Layering)** Top-level `AlembicKit` **MUST** stay Foundation-only; all Vision/ScreenCaptureKit/
  AppKit code stays under `Platform/macOS/`. `MeetingSession` stays Foundation-only and receives the
  provider via injection (like `engineFactory`), wired only in `AppModel.makeSession`.
* **NR-3 (No new permission)** The feature **MUST NOT** introduce a new TCC prompt: it reuses the
  already-granted Screen Recording permission. Any optional AX use reuses the existing (optional)
  Accessibility grant and **MUST NEVER** gate recording.
* **NR-4 (Performance)** Enabling attribution **MUST NOT** measurably degrade audio capture or ASR
  latency; frame capture + OCR overhead **MUST** be bounded (throttled rate, region-only OCR, minimal
  video resolution sufficient for legible name labels).
* **NR-5 (Testability)** All pure logic (timeline resolution, name normalization, catalog matching,
  schema round-trip) **MUST** be covered by `checkX` functions in `AlembicCheck.swift` (the authoritative
  runner). Vision/AX/live-capture paths are validated by manual in-meeting checks (documented in
  `MANUAL-VALIDATION.md`).
* **NR-6 (Robustness)** Provider errors (model unavailable, no frames, OCR failure, window not found)
  **MUST** be caught and treated as "no attribution"; they **MUST NOT** throw into or stop the session.

## 10. UX Requirements

* **UR-1** Attribution **MUST** be **opt-in**, off by default, via an `@AppStorage`-backed toggle in
  `SettingsView` (consistent with existing settings).
* **UR-2** The toggle copy **MUST** state that attribution is on-device and that no data leaves the Mac.
* **UR-3** The UI **SHOULD** indicate that attributed names may be approximate.
* **UR-4** With the toggle off, behavior **MUST** be byte-for-byte identical to today (no video plane
  upgrade, no OCR, no attribution).
* **UR-5** The live transcript view **SHOULD** display the attributed name when present and fall back to
  `them` otherwise, without layout regressions.

## 11. Acceptance Criteria

* **AC-1** `swift run AlembicCheck` passes, including new checks for: timeline dominant-overlap
  resolution (SR-10/11/12/13), name normalization (DR-4), catalog matching (SR-20/23), and the
  `displayName` schema round-trip incl. omission-when-nil and back-compat decode (DR-1/DR-2).
* **AC-2** Static audit: privacy grep (NR-1) returns no matches; no Apple-framework import appears in
  top-level `AlembicKit` (NR-2).
* **AC-3** With the toggle **off**, a recorded session's JSONL/`.md` output is identical to pre-feature
  output (UR-4) — verified by comparing against a baseline capture.
* **AC-4** Manual in-meeting validation (Teams, MVP signal #2), documented in `MANUAL-VALIDATION.md`:
  in an active multi-person Teams call in speaker/grid view, at least one far-end segment is attributed
  with the correct participant name at `source == "vision"`; ambiguous/off-screen cases fall back to
  `them` with no dropped or corrupted segments.
* **AC-5** Injecting a `FakeAttributionProvider` into `MeetingSession` yields attributed `.them`
  finalized events end-to-end (through the writer) and leaves `.you`/volatile events unattributed
  (SR-14/15), verified in `AlembicCheck`.
* **AC-6** A forced provider failure/timeout produces a complete, uncorrupted transcript identical to
  the no-attribution baseline (SR-16/NR-6).

## 12. Open Questions (resolve in PLAN or via §Next-Research in research.md)

* **OQ-1** Concrete values for `τ` (confidence threshold) and the minimum dominant-overlap fraction
  (SR-11) — require live tuning.
* **OQ-2** Exact video resolution / whether to use a periodic higher-res window snapshot vs. a
  continuous low-res `.screen` stream (SR-3/NR-4).
* **OQ-3** Teams active-tile label geometry + how "active" is visually detected per view mode
  (speaker vs. grid) (SR-20) — needs a live frame dump (SR-22).
* **OQ-4** Representation when multiple far-end speakers overlap within one ASR segment (single
  dominant name vs. low-confidence "multiple") (SR-10/12).
