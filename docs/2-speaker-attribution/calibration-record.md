<!-- markdownlint-disable-file -->
# Speaker Attribution — Calibration Record

Canonical, repo-root path: `docs/2-speaker-attribution/calibration-record.md`. Referenced from
`app/Alembic/README.md`, `app/Alembic/MANUAL-VALIDATION.md` §10, and the doc comment above
`SpeakerLabelCatalog.teamsDefaults`. This is the **only** copy of this file — do not create a second
one under `app/Alembic/docs/` or anywhere else.

**Status: CALIBRATED for strict Teams 1-on-1, three-person, and one seven-person 4-over-3 Gallery
layout.** Calibration Passes #1–#3 and End-to-End Validation Pass #1 were completed on 2026-08-18.
Other participant counts,
shared-content views, participant rails, transcript/chat side panels, materially resized windows,
and unknown layouts remain unsupported and fail closed.

The original AC-4 requirement is satisfied: a live three-person Teams recording produced correct
Vision attribution for one remote speaker with zero wrong-name segments. The second remote speaker
fell back safely to plain `them`; two-speaker completeness remains a quality-improvement target, not
part of the original single-segment acceptance criterion.

---

## Purpose

This file is the durable, sanitized evidence trail behind every `TileCandidate`/`ActiveTileMarker`
literal in `SpeakerLabelCatalog.teamsDefaults`, and behind every `markersValidated: true` flip. It
records **numbers and pass/fail notes only** — never raw screenshots, never raw `.jsonl`/`.md`
transcript files, never participant-identifying frame captures, never real participant names. See §2
and §4 of the `.copilot-tracking/plans/2026-08-17/speaker-attribution-phase-7-plan.md` for the full
fail-closed calibration workflow and evidence-handling contract this file exists to support.

**Hard rule for every entry below: no raw screenshots, no embedded images of real meeting content, no
raw `.jsonl`/`.md` transcript attachments or excerpts containing real participant names/transcript
text, and no raw participant names of any kind.** A hand-redacted, cropped geometry snippet (no
participant-identifying content) is the only acceptable image-adjacent evidence, and only if truly
useful. The evidence for Calibration Pass #1 below was inspected **locally only**, from a gitignored
`app/Alembic/.frame-dump-scratch/` capture directory; nothing from that directory — no raw OCR text, no
PNGs, no participant names — has been copied into this file or any other committed file.

---

## How to fill this in (calibration pass)

Follow `app/Alembic/MANUAL-VALIDATION.md` §10a ("One-time calibration") end to end, then §10b
("End-to-end attribution validation") to produce entries below. In short:

1. Run `swift run AlembicCheck frame-dump com.microsoft.teams --list-windows` during a live Teams
   meeting to discover the exact window title/`CGWindowID`.
2. Run `swift run AlembicCheck frame-dump com.microsoft.teams --meeting-title "<confirmed
   title-prefix>"` (or `--window-id <id>`) `--frames 10 --out <path outside the repo, or under the
   gitignored app/Alembic/.frame-dump-scratch/ diagnostics directory>`.
3. Compare the emitted `frame-N.txt` OCR bounding boxes and sampled marker colors against
   `SpeakerLabelCatalog.teamsDefaults`'s current literals; note the real numbers.
4. Hand-edit `Sources/AlembicKit/SpeakerLabelCatalog.swift`'s `teamsDefaults` literals to match.
5. Fill in a "Calibration Pass #N" section below with the measured numbers (never the raw frame-dump
   files themselves, never raw participant names).
6. Only after that, flip `markersValidated: false` → `true` on `teamsDefaults`, re-run
   `swift run AlembicCheck` (must still be green), then complete `MANUAL-VALIDATION.md` §10b in a live
   meeting and fill in an "End-to-End Validation Pass #N" section below.
7. Delete the local frame-dump scratch directory and the local `.jsonl`/`.md` evidence per §10a/§10b's
   cleanup steps. Confirm with `git status --ignored --short` that nothing sensitive was staged.

---

## Calibration Pass #1 — Geometry & marker color (Teams 1-on-1 layout)

* **Date:** 2026-08-18
* **Teams app version/build:** 26149.1804.4788.5681.
* **macOS version:** 26.5.1, build 25F80.
* **Display scale (1x / 2x / Retina):** not measured directly; the captured frame's pixel dimensions
  (below) are recorded as the authoritative geometry basis instead of an inferred display scale.
* **View modes tested:** **1-on-1 only** (macOS Teams "1 on 1" layout — a two-person call: one local
  participant, exactly one remote participant, rendered as a single full-frame primary tile). No
  grid/gallery/group layout was tested or is supported by this pass.
* **Meeting-window title fragment observed:** the literal substring `":: 1 on 1"` was present,
  verbatim, in the resolved meeting window's title in 9 of the 10 sampled frames (the 10th frame's OCR
  pass of the window-title chrome dropped one space between the colons — an OCR-recognition artifact of
  that single frame's whole-frame OCR pass, not a real UI difference; the underlying window title itself
  did not change mid-capture). This is UI chrome text (the window title bar), not participant content,
  and is recorded here as the literal fragment `SpeakerLabelCatalog.teamsDefaults.layoutRequirement`
  now requires.
* **Local evidence integrity reference:** SHA-256 of the local `manifest.json` produced by this
  capture (`app/Alembic/.frame-dump-scratch/live-calibration-remote-20260818/manifest.json` — gitignored,
  never committed): `2295b251a810d0b65347cac0f2838231b0d53f70ec62ab30c7de45a3e115f29f`. The hash itself
  is a non-reversible integrity reference and is safe to commit; the manifest and every frame it lists
  remain local-only and must not be committed, attached, or shared.

### Measured frame dimensions

| View mode | Frame width (px) | Frame height (px) | Frames sampled |
|---|---|---|---|
| 1-on-1 (single primary tile) | 1600 | 1000 | 10 (all 10 consistent) |

### Measured `TileCandidate` geometry (unit rects, top-left origin)

| Candidate | `tileRegion` (x, y, w, h) | Measured name-label OCR bounding box (x, y, w, h), range across 10 frames | Shipped `labelRegion` (x, y, w, h) |
|---|---|---|---|
| 1-on-1 primary tile (full frame) | (0, 0, 1, 1) | x: 0.0073–0.0087, y: 0.9698–0.9719, w: 0.0596–0.0712, h: 0.0118–0.0140 (bottom-left of frame; label is left-aligned participant-name text, observed truncated with a trailing ellipsis on the widest sample) | (0.0, 0.965, 0.12, 0.035) — generous margin around every measured edge |

The shipped `labelRegion` fully contains the measured OCR bounding-box range on every edge (measured
`x + w` maxed at 0.0785, well inside the shipped region's right edge at 0.12; measured `y + h` maxed at
0.9837, inside the shipped region's bottom edge at 1.0).

### Measured active-tile marker

**Calibration history:** an initial pass of this capture tested only a left-edge, 20%-wide
`.highlightColor` sample (the Phase 2 MVP's speculative `#6264A7` guess) and found no match on any of
the 10 sampled frames (sampled colors stayed a neutral `#9F9DA3`–`#ACAAA7`). A strict 1-on-1 call
renders exactly one tile, so a first interpretation concluded no active-tile indicator exists at all.
A corrected, **narrow** re-measurement — sampling a single 1px-wide pixel column instead of a wide
guessed strip — found the real indicator: a thin vertical outline at frame-pixel `x=3` (of the
`1600`-wide frame), not the wide strip originally guessed.

| Candidate | Marker region (frame-relative unit rect) | Active-speaking frames (2, 3, 4, 5, 6, 8, 9) sampled color | Inactive frames (1, 7, 10) sampled color at the same pixels | Result |
|---|---|---|---|---|
| 1-on-1 primary tile | `x=3/1600≈0.001875`, `y=120/1000=0.12`, `width=1/1600≈0.000625`, `height=840/1000=0.84` (a safe vertical inset of the fully-confirmed border, whose full measured extent runs further, from roughly `y≈88` to `y≈992`) | consistently `~(121–122, 126–127, 228–229)` ≈ `#797EE5`, uniform across the entire sampled column on every active frame | consistently a distinctly different neutral gray/tan, `~(174–185, 179–182, 174–194)` — no purple hue | **Match on every active-speaking frame; no match on any inactive frame.** The smallest observed per-channel separation between the two populations is ≈0.17 (normalized), comfortably outside the shipped `colorTolerance: 0.09` (chosen from the requested conservative `0.08–0.10` range). |

The shipped marker uses `hexColor: "#797EE5"` (the measured active-frame average, not a rounder/nicer
placeholder) and `colorTolerance: 0.09`. This is a real, measured `.highlightColor` marker — no
"trivially active"/unconditional marker kind is shipped or was ever committed to this repository.

### Notes


* This pass deliberately measured **only** the 1-on-1 layout. The Phase 2 MVP's speculative 2×2
  grid-view candidates (four additional `TileCandidate`s) were **removed**, not merely left unvalidated
  — they were never measured against live evidence. Calibration Pass #2 later added a different,
  evidence-backed seven-person 4-over-3 Gallery candidate set.
* No raw screenshots, OCR text, or participant names from the underlying frame-dump capture are
  reproduced above — every number above was read from the local, gitignored capture directory and
  transcribed here as sanitized geometry/color data only.

---

## Calibration Pass #2 — Teams seven-person Gallery

* **Date:** 2026-08-18
* **Teams app version/build:** 26149.1804.4788.5681.
* **macOS version:** 26.5.1, build 25F80.
* **View mode:** seven total participants in a 4-over-3 Gallery layout (four equal top-row tiles,
  three equal bottom-row tiles centered beneath them).
* **Local evidence integrity reference:** SHA-256 of the local sensitive manifest:
  `6607a6192f56876acb402f6a77445aa4fb31a5ac4e8528ce4ba6d73f1d92de3e`.

### Measured frame and layout

| Item | Measurement |
|---|---|
| Frame | 2400×926, 10 frames |
| Aspect ratio | 2.5918; shipped candidate gate 2.57–2.61 |
| Top-row tiles | x = 0, 600, 1200, 1800; y = 158; w = 600; h = 336 |
| Bottom-row tiles | x = 300, 900, 1500; y = 495; w = 600; h = 337 |
| Top label regions | y = 445; w = 360; h = 49, left-aligned to each tile |
| Bottom label regions | y = 780; w = 360; h = 49, left-aligned to each tile |

All shipped values are stored as frame-relative unit rectangles. Cropped-label Vision OCR recognized
both observed active participants at confidence 1.0. No participant names or OCR text are retained
here.

### Active-speaker marker and transitions

The shipped Gallery marker samples the top outline from x = tile-left + 5 through tile-right - 5 at
the first stable outline row. Active samples were `(129, 135, 251)` and `(130, 136, 252)`, represented
by `#8288FC` with tolerance `0.09`.

| Frames | Observation | Result |
|---|---|---|
| 1–8 | One top-row participant outlined | Exactly one candidate marker matched |
| 9 | No purple outline | Zero candidates matched; no attribution signal |
| 10 | A different top-row participant outlined | Exactly one different candidate matched |

Inactive tile samples were well outside tolerance. A separate five-frame capture with a transcript
side panel open produced zero candidate marker matches, despite a similar outer-window aspect ratio.
The measured shared-content view ratio (1600×656, 2.439) is outside the Gallery aspect gate.

### Scope

This pass supports only the measured seven-person 4-over-3 Gallery geometry. Other participant counts,
shared-content views, participant rails, side panels, and materially resized windows remain
unsupported and fail closed.

All local frame-dump scratch directories from both calibration passes were deleted after the
sanitized measurements and manifest hashes above were recorded.

---

## Calibration Pass #3 — Teams three-person layout

* **Date:** 2026-08-18
* **Teams app version/build:** 26149.1804.4788.5681.
* **macOS version:** 26.5.1, build 25F80.
* **View mode:** three total participants: two top-row tiles and one centered bottom tile.
* **Frame evidence:** 2400×926, 15 frames.
* **Local evidence integrity reference:** SHA-256 of the local sensitive manifest:
  `308ae242c0fc4a04706361c31c9f14a5b2a927b8e34b239375f7799d1bf55750`.

Only the two remote tiles are catalogued. Their measured tile rectangles were `(1200,99,764,396)`
and `(818,495,764,431)` in pixels. Name-label crops were `(1200,445,450,49)` and
`(818,875,450,51)`.

The top remote tile used a measured left-edge marker near `#898FFE`; the bottom remote tile used
`#8086EA`, both with tolerance `0.09`. The sequence contained independent bottom-remote activity,
independent top-remote activity, two simultaneous-outline crosstalk frames, and multiple no-outline
frames. Simultaneous valid labels remain ambiguous and produce no attribution.

Teams role suffixes such as contractor/external/guest are stripped before `Last, First` expansion.
For the small lower tile, OCR must preserve the visible comma separator; malformed no-separator
alternatives are rejected rather than persisted as approximate names.

---

## End-to-End Validation Pass #1 — supported layouts

* **Date:** 2026-08-18
* **Layout:** calibrated three-person Teams layout.
* **Result:** PASS for original AC-4.
* **Local JSONL integrity hash:** `af493a281c52314c6ff70322d3849136928b940b34c62eaf5b99559a8b312524`.

* **Date:**
* **Teams app version/build:**

### Results

| Checklist item | Pass/Fail | Notes |
|---|---|---|
| At least one far-end segment attributed with the correct participant name, `attribution.source == "vision"` | Pass | 9 correct Vision-attributed segments |
| Ambiguous/off-screen cases fall back to `them`, with no dropped/corrupted segments | Pass | Zero malformed lines and zero Vision attribution on `you` |
| No wrong-name attribution | Pass | Zero unexpected attributed names |
| Toggle-off output remains byte-identical | Pass | Covered by authoritative deterministic check |

### Segment counts (sanitized — numbers only, no transcript text)

* Total finalized segments: 29.
* Total finalized `.them` segments: 18.
* Segments with `attribution.source == "vision"`: 9.
* `.them` segments falling back without Vision attribution: 9.
* Distinct correctly attributed remote speakers: 1.
* Wrong-name segments: 0.

### Optional: redacted schema snippet

*(A minimal, hand-redacted JSON snippet showing the `attribution` shape with the participant's actual
name replaced by a placeholder, e.g. `"displayName": "<redacted real name>"` — omit if not useful.)*

### Optional: local evidence integrity hash

*(A SHA-256 hash of the local `.jsonl` file, e.g. via `shasum -a 256 <file>` — the hash itself is safe
to commit as a non-reversible integrity reference; the file itself must not be committed or attached
anywhere.)*

### Cleanup confirmation

* [x] Local test `.jsonl`/`.md` evidence files deleted after this entry was written.
* [x] `git status --ignored --short` confirmed clean of diagnostic/evidence artifacts.

---

## Unsupported layouts

Other Gallery participant counts, shared-content views, participant rails, transcript/chat side
panels, materially resized windows, and unknown Teams layouts remain unsupported. The provider fails
closed unless a frame matches a calibrated candidate's frame signature and exactly one measured marker.

---

## Sign-off

* **Calibration:** complete for strict 1-on-1, three-person, and seven-person 4-over-3 Gallery.
* **End-to-end attribution validation:** PASS for original AC-4; 9 correct segments, zero wrong names.
* **Other layouts:** unsupported and fail closed.
