<!-- markdownlint-disable-file -->
# Task Research: Speaker Attribution (name the "them" speaker instead of just "them")

Investigate how Alembic can attribute a **named speaker** to far-end ("them") transcript
segments, replacing the generic `them` tag with the actual participant name (e.g.
"Alex Kim"). The premise in the task: Alembic already captures the meeting window's
video via ScreenCaptureKit, and the meeting UI visually indicates who is speaking
(active-speaker tile outline/focus, name labels, and/or the app's own live captions),
so that on-screen signal could drive name attribution — entirely on-device.

## Task Implementation Requests

* Attribute far-end speech to a **named participant** rather than the generic `them`.
* Use the already-captured meeting-window video (active-speaker focus / name labels) as the
  attribution signal where possible.
* Persist the attributed name in the transcript (the schema already reserves a slot).
* Keep the privacy invariant intact: **on-device only, no networking**, `AlembicKit` top level
  stays Foundation-only, Apple-framework code under `Platform/macOS/`.

## Scope and Success Criteria

* Scope: macOS 26 menu-bar app under `app/Alembic/`. Attribution of the **"them"** source only
  ("you" is already the local user and needs no attribution). Does not change the audio-capture,
  ASR, or clock/timeline design; it augments finalized `.them` segments with a name.
* Assumptions:
  * Public APIs strongly preferred; the app is self-signed (not sandboxed) but must avoid private SPI.
  * Apple-framework code stays under `Sources/AlembicKit/Platform/macOS/`; top-level `AlembicKit`
    stays Foundation-only.
  * No networking anywhere (privacy invariant). Rules out Microsoft Graph / Zoom / Meet roster APIs.
  * The `attribution` field on `TranscriptEvent`/`FinalizedSegmentDTO` already exists and was
    explicitly designed for a `"vision"` provider (see `TranscriptEvent.swift` doc comment).
* Success Criteria:
  * A clear, ranked recommendation of attribution signals (reliability vs. permission/complexity cost).
  * Concrete integration points in the existing architecture (`ScreenCaptureKitSource`,
    `MeetingSession.ingest`, `TranscriptAttribution`).
  * Identified permission/TCC implications, per-app fragility, and UX/accuracy tradeoffs.
  * An explicitly scoped MVP + fallback behavior when a name cannot be resolved (must degrade to
    `them`, never block or corrupt the transcript).

## Outline

1. Current capture/attribution flow (codebase) — what a name-attribution feature must hook into.
2. Candidate attribution signals (external API research):
   - Accessibility (AX) tree readout of the active speaker / roster.
   - Vision OCR (`RecognizeTextRequest`) on the captured meeting-window frame.
   - The meeting app's **own** live captions (already carry speaker names) via OCR/AX.
   - Roster/network APIs (Graph/Zoom) — evaluated only to reject on privacy grounds.
3. Alternatives analysis + recommended approach (ranked).
4. Integration plan + permission/UX/accuracy considerations.
5. Potential next research (live-meeting validation items).

## Potential Next Research

* **Live in-meeting AX dump for active-speaker markers.** Run `swift run AlembicCheck ax-dump`
  during a live Teams/Zoom call (grid + speaker view, someone actively talking) and inspect whether
  the active-speaker tile exposes a stable, *dynamically-updating* AX attribute (e.g. an
  `AXDescription` containing the name plus a "speaking" state, `AXSelected`, or an announced
  value). External research (2024–2025) reports the new Teams (`com.microsoft.teams2`, Electron/
  WebView) AX tree is **inconsistent** for live speaker state — this must be verified on *this*
  machine/version before committing to an AX-primary design.
* **Vision OCR fidelity on a live active-speaker tile.** Bump the SCStream video plane to a real
  resolution (currently `2x2`), capture the active-speaker region, and measure `RecognizeTextRequest`
  accuracy/latency on the name label and on the app's own live-caption speaker prefix. Confirm the
  on-device model handles small overlay type and mixed backgrounds.
* **Per-app label geometry catalog.** Determine, per meeting app (Teams / Zoom / Meet / Slack /
  Discord), *where* the active-speaker name renders (bottom-left of the focused tile, caption
  strip, etc.) and whether a name is shown at all in each view mode. This is the equivalent of the
  detection catalog: data, not code.
* **Name → identity normalization.** Decide how to reconcile OCR/AX name strings across frames
  (dedup, fuzzy-match, "First Last" vs "Last, First", initials-only tiles) and how to represent
  "multiple far-end speakers in one segment" or "unknown".
* **Attribution timing model.** Decide how a time-windowed active-speaker signal maps onto an ASR
  segment `[start, end]` that may straddle a speaker change (assign dominant speaker, split, or mark
  low-confidence). Overlap with the ASR finalization boundary needs empirical tuning.

## Research Executed

### Codebase — current attribution & capture flow

* **Attribution slot already exists and is designed for this feature.**
  `Sources/AlembicKit/TranscriptEvent.swift` defines
  `TranscriptAttribution { source: String; confidence: Double? }`, carried as an optional,
  additive field on both `TranscriptEvent` and the on-disk `FinalizedSegmentDTO`. Its doc comment
  explicitly reserves `"vision"` — *"speaker attribution via Vision OCR (deferred)"* — and `"graph"`
  for roster names (deferred). It is `Codable` and omitted from JSON when `nil`, so adding an
  attribution provider is a **non-breaking, additive** change (`schemaVersion` stays 1; consumers
  that ignore `attribution` are unaffected). Round-trip is covered by `AlembicCheck` and
  `CoreModelTests`.
  * **Gap:** `TranscriptAttribution` currently carries only `source` + `confidence`. It has **no
    field for the attributed name**. A name would need either a new optional field (e.g.
    `displayName: String?`) or an overload of `SourceTag`. This is a small, additive schema decision
    to make in SPEC/PLAN — the existing tests assert only `source`/`confidence`, so adding an
    optional field is backward-compatible.

* **`SourceTag` is a binary you/them.** `source: SourceTag` (`.you` / `.them`) is the coarse
  attribution today. Named attribution layers *on top of* `.them`; it does not replace `SourceTag`
  (the you/them split still drives the two-engine pipeline and the merged-timeline tie-break in
  `MeetingSession.orderedBefore`).

* **Single choke point for injecting attribution.** `MeetingSession.ingest(_ event:)`
  (`MeetingSession.swift:298`) is the *only* place a finalized event is inserted into the timeline
  and appended to the writer:
  ```
  case .finalized:
      insertFinalized(event)
      volatileLines[event.source] = nil
      if let writer { await writer.append(event) ; ... }
  ```
  A name-attribution provider can be queried here, keyed by the event's `source == .them` and its
  `[start, end]` window, to rewrite `event` with a populated `attribution` before `insertFinalized`
  and `writer.append`. This keeps attribution **orthogonal** to the ASR engines (which never learn
  about names) and means a missing/failed lookup simply leaves `attribution == nil` → the segment
  degrades to plain `them`. `MeetingSession` is Foundation-only, so the provider must be injected as
  a `Sendable` protocol (like the existing `engineFactory`), with the Apple/Vision implementation
  living under `Platform/macOS/`.

* **The video plane is currently disabled.** `ScreenCaptureKitSource.start` sets
  `config.capturesAudio = true` and deliberately shrinks the video to `config.width = 2`,
  `config.height = 2`, `config.minimumFrameInterval = 1 fps`, and registers **only**
  `addStreamOutput(output, type: .audio, …)` — there is *no* `.screen` output consumer. A comment at
  `ScreenCaptureKitSource.swift:171` already anticipates this feature: *"it will matter if a future
  phase adds video/OCR speaker attribution."* So enabling attribution-via-OCR requires: (a) a real
  capture resolution (or a periodic higher-res snapshot), (b) a `.screen` output sink analogous to
  `StreamAudioOutput`, and (c) an OCR consumer. **Important:** the current `2x2` frame carries no
  usable pixels, so the "we already capture the screen" premise is only true structurally — the
  pipeline exists but is intentionally producing throwaway frames today.

* **Established platform patterns to reuse.**
  * AX access is already wired: `AccessibilityAuthorization` (`AXIsProcessTrusted` /
    `AXTrustedCheckOptionPrompt`, in `TeamsChatPoster.swift`) and a full AX tree walker
    (`AXDumpProbe.swift`, `AlembicCheck ax-dump`) that reads `role`, `subrole`, `title`,
    `description`, `value`, `actions`. Accessibility is already treated as an **optional** capability
    that "must never gate recording" — the same posture fits attribution (never block the transcript).
  * `TeamsChatPoster` already demonstrates the fragility model for Teams' Electron AX tree: UI markers
    are stored as **data** (`MeetingChatMarkers.teamsDefaults`), re-derived via `ax-dump` after Teams
    updates, with a manual-validation gate. Any AX-based speaker readout inherits this exact
    "markers are data, re-derive per release" maintenance model.
  * `WindowTitleProbe` shows the `CGWindowListCopyWindowInfo` + PID-family pattern (already using the
    granted Screen Recording permission) for locating the meeting window — useful to bound an OCR
    region to the right window.
  * The `StreamAudioOutput` `@unchecked Sendable` callback→`AsyncStream` bridge is the precedent for a
    `.screen`/frame output that hands `Sendable` results across the actor boundary.

* **Privacy invariant.** No networking exists in `Sources/`; the audit grep in
  `.github/copilot-instructions.md` must stay clean. This is the single hardest constraint on this
  feature: it **rules out all roster/directory APIs** (Microsoft Graph, Zoom REST, Google People)
  because they require network calls. Attribution must be derived purely from on-screen/on-device
  signals.

### External Research — candidate attribution signals

#### 1. Accessibility (AX) active-speaker / roster readout

* Teams (and Zoom/Meet) visually mark the active speaker (tile outline/focus) and render the
  participant's name on the tile and in the roster.
* **Finding (2024–2025):** the *new* Teams client on macOS (Electron/WebView) exposes an
  **inconsistent / partially-broken AX tree**; the active-speaker state is often **not** surfaced as
  a reliably-updating AX attribute (no dependable `AXSelected`/`AXValueChanged`/custom "speaking"
  attribute), and reverse-parent traversal is broken in some versions. VoiceOver users are advised
  not to rely on programmatic active-speaker cues. Source: Microsoft Tech Community discussion
  "enable Accessibility Tree on macOS in the new Teams", plus Teams accessibility docs.
* **Consequence:** AX can likely read the **static roster names** (participant list) reliably, but
  the **dynamic "who is speaking right now"** signal is unreliable-to-absent in new Teams. AX alone
  cannot robustly answer the core question. It may still be valuable as a **name allow-list / fuzzy-
  match dictionary** (roster of expected names) to clean up OCR output.
* Cost: uses the AX permission Alembic already requests (optional, for disclosure auto-post). No new
  TCC prompt beyond what disclosure already uses. Per-release fragility identical to `TeamsChatPoster`.

#### 2. Vision OCR (`RecognizeTextRequest`) on the captured meeting-window frame

* macOS 26 Vision provides the Swift-native, fully-async `RecognizeTextRequest` (successor to
  `VNRecognizeTextRequest`) that performs **on-device** OCR directly from a `CGImage`,
  `CVPixelBuffer`, `CMSampleBuffer`, or `Data` — i.e. it consumes exactly the `CMSampleBuffer` a
  ScreenCaptureKit `.screen` output delivers. `recognitionLanguages`, `minimumTextHeightFraction`,
  and per-observation `boundingBox` allow filtering to the region/label of interest. All recognition
  is local — **preserves the privacy invariant** (no networking). Sources: Apple `RecognizeTextRequest`
  docs; "Detecting text in images with the Vision framework" (2026).
* Two OCR targets, both purely visual:
  * **(a) Active-speaker tile name label.** OCR the name rendered on the focused/outlined tile.
    Requires detecting *which* tile is active (the visual outline) — either by OCR-region heuristics
    per app, or by pairing with any available AX/focus hint. Fragile across view modes (grid vs.
    speaker view; name may be hidden until hover; initials-only tiles).
  * **(b) The meeting app's own live captions.** Teams/Zoom/Meet live captions render **"Name: text"**
    at the bottom of the window. OCR'ing the caption strip yields an explicit, app-provided
    speaker→text mapping — often *more* reliable than inferring the active tile, and it sidesteps the
    active-tile-detection problem entirely. Downside: requires the user to have the app's captions
    turned on, and it duplicates text Alembic already transcribes (use the caption **name prefix**
    only, as an attribution hint, not as the transcript source of truth).
* Cost: requires enabling a real video plane in `ScreenCaptureKitSource` (resolution + a `.screen`
  output sink + a periodic OCR pass, e.g. 1–2 Hz to bound CPU), all under the **already-granted**
  Screen Recording permission — **no new TCC prompt**. Adds `import Vision` under `Platform/macOS/`.

#### 3. Roster / directory network APIs (Microsoft Graph, Zoom, Google) — REJECTED

* These give authoritative names and even active-speaker events, but **every one requires network
  calls and auth tokens**, violating the core privacy invariant ("no audio and no transcript data
  ever leaves the machine"; `URLSession`/`URLRequest` are prohibited in `AlembicKit`/`Alembic`).
  Rejected on principle regardless of accuracy. The reserved `"graph"` attribution source in the
  schema is therefore **permanently deferred** under the current privacy posture.

#### 4. Speaker diarization on the audio (no names, just "speaker A/B/…") — ADJACENT

* On-device diarization (Apple `SpeechAnalyzer` has no public diarization module today; third-party
  models would add a heavy dependency) could split "them" into anonymous speaker clusters *without*
  names. This does **not** satisfy the request ("attribute **names**") and adds significant
  complexity/dependency. Out of scope, noted as a possible complement (cluster → then name a cluster
  once via OCR/AX).

### Implementation Patterns (reuse)

* Frame delivery: add a `.screen` output that mirrors `StreamAudioOutput` — an `@unchecked Sendable`
  `SCStreamOutput` that converts each `CMSampleBuffer` to a `Sendable` snapshot and `yield`s it to an
  `AsyncStream`, never `await`ing the actor from the callback (`ScreenCaptureKitSource.swift:34-59`).
* OCR/attribution logic split: pure, testable parts (name normalization, "First Last" ↔ "Last, First"
  expansion — a helper already exists in `VocabularyStore`; time-window→segment assignment; roster
  fuzzy-match; per-app label-region catalog) live in Foundation-only `AlembicKit` + `checkX` functions
  in `AlembicCheck.swift`. Apple-specific parts (Vision, AX, SCStream frames) live under
  `Platform/macOS/`.
* Provider injection: define an `AttributionProvider` protocol (Foundation-only, `Sendable`) that
  `MeetingSession` queries in `ingest`, mirroring how `engineFactory` injects the transcription engine
  today. Tests use a `FakeAttributionProvider`; the live wiring stays in `AppModel.makeSession`.
* Marker/geometry data-not-code: per-app OCR regions and roster markers are **data**
  (like `MeetingChatMarkers.teamsDefaults`), re-derived via `ax-dump` / a new frame-dump diagnostic
  after app updates.

### Ranked attribution signals (most reliable + lowest added permission first)

1. **Vision OCR of the meeting app's own live-caption speaker prefix** ("Name: …" strip). Explicit
   app-provided name→speech mapping; on-device; uses already-granted Screen Recording. **Best signal
   when captions are on.** Gated on the user enabling the app's captions.
2. **Vision OCR of the active-speaker tile name label.** Works without captions; needs per-app
   active-tile detection + label geometry; on-device; no new permission. Primary when captions off.
3. **AX roster read** as a **name dictionary** to correct/validate OCR output (fuzzy-match OCR text
   to a known participant). Uses the AX permission already used for disclosure; optional.
4. **AX dynamic active-speaker attribute** — only if live validation shows it updates reliably on the
   target app/version (external research says it currently does **not** on new Teams). Opportunistic.
5. (Rejected) Graph/Zoom/Google roster & speaker-event APIs — networking, violates privacy invariant.
6. (Out of scope) On-device audio diarization — anonymous clusters, no names, heavy dependency.

## Technical Scenarios

### Attribute a named far-end speaker to each "them" segment

The far-end transcript currently reads as an undifferentiated `them`, so a multi-person meeting is a
wall of text with no indication of who said what. We want each finalized `.them` segment tagged with
the speaking participant's name, derived **only** from on-screen/on-device signals, degrading
gracefully to `them` when no name is available.

**Requirements:**

* Resolve a participant **name** for a `.them` segment's `[start, end]` window with useful precision.
* Persist the name in the transcript via the existing `attribution` slot (additive, `schemaVersion`
  unchanged), plus a small additive field to carry the name string.
* Keep platform code under `Platform/macOS/`; keep `MeetingSession`/`AlembicKit` top level
  Foundation-only; add no networking.
* Never block, delay, or corrupt the audio/ASR pipeline; missing name ⇒ plain `them`.
* Opt-in (attribution requires the video plane + OCR cost); off by default.

**Preferred Approach:**

Introduce an on-device, OCR-first **`AttributionProvider`**. `ScreenCaptureKitSource` gains a real
`.screen` output that periodically (≈1–2 Hz) hands frames to a macOS `VisionSpeakerAttributor`
(`Platform/macOS/`), which runs `RecognizeTextRequest` over a per-app-catalogued region. **For MVP the
target is signal #2 — the active-speaker tile name label** (because most meetings run with the app's
captions off, so #2 is the only path that works in the common case); the same provider is structured to
*also* accept signal #1 (the live-caption "Name:" prefix) later as an opportunistic, higher-confidence
feeder into the identical timeline. It maintains a time-stamped `ActiveSpeakerTimeline` of
`(timeRange, name, confidence)`. `MeetingSession` queries this timeline in `ingest` for each finalized
`.them` event and, if a name covers the segment window with sufficient confidence, attaches
`TranscriptAttribution(source: "vision", confidence: …)` plus the resolved name. An optional AX roster
read supplies a name allow-list to clean up OCR output. Rationale: OCR on the already-captured window is
the only signal that (a) reliably reflects *live* speaking state (new-Teams AX does not), (b) stays
fully on-device (privacy invariant), and (c) needs **no new TCC permission** (reuses Screen Recording).
The design isolates all fragility (per-app regions, name parsing) into replaceable *data* and keeps the
ASR/writer pipeline untouched.

```text
app/Alembic/Sources/
  AlembicKit/
    TranscriptEvent.swift              (EDIT: add optional `displayName: String?` to TranscriptAttribution — additive, schemaVersion unchanged)
    AttributionProvider.swift          (NEW, Foundation-only: `Sendable` protocol; name-for-window query)
    ActiveSpeakerTimeline.swift        (NEW, Foundation-only, testable: (timeRange,name,confidence) store + window→name resolution)
    SpeakerNameNormalizer.swift        (NEW, Foundation-only, testable: OCR cleanup, "Last, First"↔"First Last", roster fuzzy-match)
    SpeakerLabelCatalog.swift          (NEW, Foundation-only: per-app OCR region + caption/tile markers — DATA)
    Platform/macOS/
      ScreenCaptureKitSource.swift     (EDIT: real video plane + `.screen` StreamFrameOutput → AsyncStream<Frame>)
      VisionSpeakerAttributor.swift    (NEW: RecognizeTextRequest over frames → ActiveSpeakerTimeline)
      RosterReader.swift               (NEW, optional: AX roster names as a normalization dictionary)
  Alembic/
    AppModel.swift                     (EDIT: makeSession wires VisionSpeakerAttributor as the AttributionProvider when enabled)
    SettingsView.swift                 (EDIT: "Attribute speaker names (on-screen, on-device)" opt-in toggle via @AppStorage)
  AlembicCheck/AlembicCheck.swift      (EDIT: checkActiveSpeakerTimeline + checkSpeakerNameNormalizer)
```

**Attribution flow:**

```text
SCStream .screen frames (≈1-2 Hz) ─▶ VisionSpeakerAttributor
                                        RecognizeTextRequest over catalogued region
                                        (MVP: active tile label [#2]; later: caption "Name:" prefix [#1])
                                        → normalize (SpeakerNameNormalizer, optional AX roster dict)
                                        → append (timeRange, name, confidence) to ActiveSpeakerTimeline
                                                     │
finalized .them TranscriptEvent  ─▶ MeetingSession.ingest
                                        query ActiveSpeakerTimeline for event[start,end]
                                        name covers window w/ confidence ≥ τ ?
                                          yes → event.attribution = (source:"vision", confidence, displayName)
                                          no  → leave nil  → segment stays plain `them`
                                        insertFinalized + writer.append   (unchanged path)
```

**Implementation Details:**

* **Additive schema.** Add `displayName: String?` (or similar) to `TranscriptAttribution`; keep
  `schemaVersion == 1` because the field is optional and omitted when nil. Existing `AlembicCheck`/
  `CoreModelTests` round-trips continue to pass (they assert only `source`/`confidence`); add cases
  for the new field. The `.md` human-readable writer can render `**Alex Kim (them):**` when a name is
  present, falling back to `**them:**`.
* **Enable the video plane.** In `ScreenCaptureKitSource.start`, set a real `config.width/height`
  (or capture a periodic higher-res snapshot of the meeting window), register a `.screen`
  `StreamFrameOutput` (mirroring `StreamAudioOutput`'s `@unchecked Sendable` callback→`AsyncStream`
  bridge), and throttle OCR to ≈1–2 Hz to bound CPU/GPU. Keep audio delivery on its existing path;
  frames are a *separate* stream so an OCR stall can never back-pressure audio. Bound the capture to
  the meeting window (via `WindowTitleProbe`/PID) so unrelated screen content is never OCR'd.
* **OCR targeting.** MVP targets signal #2 (active-speaker tile label): detect the active tile via the
  per-app label geometry and match `RecognizeTextRequest` observations by `boundingBox` to that region,
  taking the name text. When (later) signal #1 is available — the app's live captions are on — prefer
  it as a higher-confidence override: match observations to the catalogued caption region, split on the
  "Name:" delimiter, take the name only. Use `minimumTextHeightFraction` and `recognitionLanguages` to
  cut noise; use recognition confidence as the base `TranscriptAttribution.confidence`.
* **Timeline→segment assignment.** `ActiveSpeakerTimeline` resolves a name for an ASR segment window
  by dominant overlap; when a segment straddles a speaker change, either assign the majority speaker
  or mark low-confidence (tunable τ). This is **pure logic** → unit-tested in `AlembicCheck` with
  synthetic timelines, independent of Vision.
* **Name normalization.** Reuse the "Last, First" → natural-order expansion already present in
  `VocabularyStore`; dedup OCR jitter; optionally snap to the nearest AX-roster name within an edit-
  distance threshold. Also feeds the existing **vocabulary/contextual-strings** mechanism: known
  participant names could bias ASR (a nice secondary win, out of scope for MVP).
* **Consent/UX.** Off by default; opt-in `@AppStorage` toggle in `SettingsView` ("Attribute speaker
  names — on-screen, on-device, no data leaves your Mac"). Attribution never gates recording; if the
  provider errors or the model is unavailable, the session records exactly as today. Surface a subtle
  "names may be approximate" note.
* **Privacy invariant intact.** Vision + AX + SCStream are all local OS APIs; no `URLSession`/network
  is added; the audit grep stays clean. Names are derived from pixels/AX already on the user's screen.

**MVP recommendation:** ship **signal #2 (active-speaker tile OCR)** for **Teams first** (the app the
codebase already deeply supports), behind the opt-in toggle, with graceful `them` fallback and the
additive `displayName` field. **Rationale — why #2, not #1, is the MVP:** most meetings run with the
app's live captions *off*, so signal #1 (caption-prefix OCR) only attributes a minority of meetings
and cannot be the primary path — the feature has to work when captions are absent, which is the
common case. Signal #1 is not reordered in the ranked list above (when captions *are* on, its explicit
app-authored `Name: …` mapping is the single most reliable signal), but on availability it addresses
far fewer real sessions, so it is **deferred to an opportunistic enhancement** rather than co-developed
for MVP.

The two signals are **not redundant — they have complementary failure modes**, which is the reason #1
stays on the roadmap rather than being dropped: signal #2 physically *cannot* read a name in exactly
the cases #1 still can — **screen-share** (participant tiles collapse to a filmstrip/overlay or hide,
and the name is often hover-only), an **off-screen speaker in a large call** (the talker isn't in the
visible grid, so there is no tile/label to OCR at all), and **camera-off / initials-only tiles** (the
tile may suppress the name label that captions still show). So #1 is not a nicer version of #2; it is
the fallback for view modes where #2 has nothing to read. It is also the cheaper *parse* per instance
(fixed caption region + explicit delimiter) versus #2's genuinely hard part (detecting which tile is
"active"). The countervailing cost — and the reason not to co-develop it now — is that each signal is
its own per-app region catalog + parser to build and maintain (more fragile surface), and #1's low
availability makes that cost poor value up front.

Architecture keeps the door open: because both signals feed the *same* `ActiveSpeakerTimeline`, signal
#1 can be added later as an **opportunistic, high-confidence override** (used only when captions happen
to be on) that also fills #2's screen-share / off-screen blind spots — with no change to the
`MeetingSession.ingest` query path or the schema. Add the AX roster dictionary (signal #3) and extend
the per-app catalog to Zoom/Meet incrementally — exactly the data-driven, per-app expansion model the
detection catalog already uses.

#### Considered Alternatives

* **AX-primary active-speaker read.** Cleanest *if* the AX tree exposed a reliable live "speaking"
  attribute — but external research indicates the new Teams AX tree does not update this reliably on
  macOS, and reverse traversal is broken in some versions. Rejected as the *primary* signal; kept as
  an optional roster-name dictionary and an opportunistic fast-path where a given app/version does
  expose it (validate via `ax-dump`).
* **Graph/Zoom/Google roster + active-speaker APIs.** Authoritative names and real speaker events, but
  require networking + auth → **violates the privacy invariant**. Rejected on principle; the reserved
  `"graph"` attribution source stays permanently deferred under this posture.
* **On-device audio diarization (anonymous clusters).** Splits "them" into speaker A/B/… without
  names — does not meet the "attribute **names**" request, and adds a heavy model dependency
  (`SpeechAnalyzer` has no public diarization today). Out of scope; possible future complement (name a
  cluster once, propagate).
* **Always-on full-resolution capture + continuous OCR.** Higher accuracy but material CPU/GPU/thermal
  cost for a menu-bar app running a whole meeting. Rejected in favor of a throttled (≈1–2 Hz),
  region-bounded OCR pass.
* **Deriving names from the app's captions as the transcript source.** Tempting (captions already
  carry names) but would replace Alembic's own on-device ASR with the app's captions (quality/latency
  regression, app-dependent availability). Use the caption **name prefix only** as an attribution hint;
  keep Alembic's `SpeechAnalyzer` transcript as the source of truth.
