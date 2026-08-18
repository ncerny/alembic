# Alembic — Manual Validation Checklist

This is the **manual hardware gate** for Alembic. The automated suite
(`swift run AlembicCheck`) and the privacy audit cover everything that can be
verified headlessly; the items below **cannot** be automated because they need a
permissioned macOS 26 machine, a display, real TCC prompts, a real on-device
model-asset download, and a live Microsoft Teams meeting with other
participants.

Run this checklist on such a machine after `bash build.sh` succeeds. Check each
box only when the **Expected result** is observed.

## Pre-flight

- [ ] On macOS 26.0 or later (`sw_vers`).
- [ ] `cd app/Alembic && bash build.sh` completes and prints
      `Built and verified: …/build/Alembic.app`.
- [ ] `swift run AlembicCheck` prints `N checks passed, 0 failed` and exits 0.
- [ ] Launch `open build/Alembic.app`. **Expected:** no Dock icon, no window;
      an Alembic icon appears in the menu bar.

## 1. First-run permissions

- [ ] On first record attempt, macOS prompts for **Microphone**. Grant it.
      **Expected:** mic state becomes granted.
- [ ] macOS prompts for **Speech Recognition**. Grant it. **Expected:** speech
      state becomes granted.
- [ ] macOS prompts for **Screen Recording** (System Settings → Privacy &
      Security → Screen Recording). Enable Alembic. **Expected:** the app
      detects the grant but reports it needs a restart.
- [ ] The app shows a **"Quit & Reopen"** action (not a misleading "denied")
      for Screen Recording. **Expected:** `requiresRestart` guidance is shown.
- [ ] Use **Quit & Reopen**. **Expected:** after relaunch, Screen Recording is
      effective (`CGPreflightScreenCaptureAccess()` true) and all three
      permissions read as granted; recording is no longer blocked.
- [ ] (Optional) Deny one permission and confirm the corresponding actionable
      guidance + System Settings deep-link appears for that permission only.

## 2. Model-asset download

- [ ] On a machine where the speech model assets for the locale are **not**
      installed, starting shows a **model-download progress** indicator
      (`modelDownloadProgress` in `[0,1]`). **Expected:** progress bar advances
      to 100%, then recording proceeds. (This is the only expected network
      activity — model files *from* Apple; see §8.)
- [ ] On a machine where assets are already installed, **no** download bar shows
      and recording starts immediately.

## 3. Pick target & start

- [ ] Join/start a Teams meeting with at least one other participant talking.
- [ ] In Alembic, pick the **Teams** capture target from the picker.
- [ ] Click **Start**. **Expected:** status shows `Recording — hh:mm:ss` with a
      live-advancing elapsed timer.
- [ ] Speak into your mic. **Expected:** a **volatile** caption appears for
      "you" and is replaced by a **finalized** line shortly after.
- [ ] Have the other participant speak. **Expected:** volatile→finalized
      captions appear for "them".
- [ ] **Expected:** input **meters** move for both sources while audio flows.

## 4. Continuous-run stability (SpeechAnalyzer fix)

- [ ] Keep recording **continuously for more than 2 minutes** with intermittent
      speech on both sides.
- [ ] **Expected:** transcription does **not** reset/stall at ~1 minute (the
      single long-lived `SpeechAnalyzer` per source — no mid-stream restart).
- [ ] **Expected:** the **dropped-audio metric stays 0** under normal load
      (no sustained-drop warning/error escalation).

## 5. Stop, drain & save

- [ ] Click **Stop**. **Expected:** the session **drains** in-flight finalized
      results before closing (no truncated tail); status moves to
      `Saved — hh:mm:ss`.
- [ ] Open `~/Documents/Alembic/`. **Expected:** a new
      `<yyyy-MM-dd_HHmm>-<meeting>.jsonl` and a sibling `.md` exist.
- [ ] The `.jsonl` is **non-empty** and **every line parses** as a
      `FinalizedSegmentDTO`. Verify:
      ```bash
      f=$(ls -t ~/Documents/Alembic/*.jsonl | head -1)
      wc -l "$f"                              # > 0 lines
      while IFS= read -r l; do echo "$l" | python3 -m json.tool >/dev/null \
        || echo "BAD LINE: $l"; done < "$f"   # prints nothing if all valid
      ```
      **Expected:** `>0` lines, no `BAD LINE` output; each object has
      `schemaVersion`, `start`, `end`, `source` (`you`/`them`), `text`.
- [ ] The `.md` is human-readable with `[hh:mm:ss] source: text` lines.
- [ ] Click **Reveal in Finder**. **Expected:** Finder opens with the canonical
      `.jsonl` selected.

## 6. Attribution & timing sanity

- [ ] **You/them labeling:** lines you spoke are tagged `you`, others `them`.
      **Expected:** correct labeling **with headphones**. Without headphones,
      some "them" audio may bleed into the mic and be mislabeled — note this is
      *approximate by design* (duplicate-suppression deferred).
- [ ] **Timestamp accuracy:** segment `start`/`end` reflect **audio time**, not
      wall clock — spot-check a known utterance against the elapsed timer.
      **Expected:** timestamps line up with when speech actually occurred.

## 7. Meeting-mode scenarios

- [ ] **Gallery view** meeting (multiple video tiles, several speakers).
      **Expected:** "them" audio is captured and transcribed regardless of view.
- [ ] **Screen-share** scenario (a participant shares their screen).
      **Expected:** meeting audio capture continues uninterrupted during share.

## 8. Vocabulary hints (Settings UI)

- [ ] Open **Settings…** from the menu bar icon. **Expected:** the Settings window
      appears with three inputs: Inline Terms, Vocabulary File, Markdown Folder.
- [ ] Enter a comma-separated list in **Inline Terms** (e.g. `Dynatrace, Kubernetes`).
      Click **Preview**. **Expected:** preview shows the correct inline count and
      total term count with no truncation warning.
- [ ] Use **Browse…** for **Vocabulary File** to select a plain-text file (one
      term per line, `#` comment lines). Click **Preview**. **Expected:** file
      terms are counted separately from inline terms.
- [ ] Use **Browse…** for **Markdown Folder** to select a folder of `.md` notes.
      Click **Preview**. **Expected:** basenames appear as hints; `Last, First`
      names appear in natural order (e.g. `Jane Doe`).
- [ ] Enter enough terms to exceed 500 total. **Expected:** the preview shows an
      orange truncation warning indicating folder terms were dropped first.
- [ ] Start a recording after configuring vocabulary. **Expected:** the console
      log (`[alembic] Vocabulary loaded: …`) shows the correct counts, and
      recognition of the hinted terms is noticeably more accurate.

## 9. Privacy spot-check (network egress)

- [ ] Before/after the (optional, one-time) Apple model-asset download, monitor
      network while recording. Use one of:
      ```bash
      sudo nettop -p "$(pgrep -x Alembic)"     # per-process live connections
      ```
      or Little Snitch / Lulu. **Expected:** **no** network egress attributable
      to Alembic during capture — no connections carrying audio or transcript
      text. The only acceptable traffic is the one-time Apple speech model-asset
      download (`AssetInventory`), which sends **no** audio.
- [ ] (Reproduce the static audit) From `app/Alembic`:
      ```bash
      grep -rniE 'URLSession|URLRequest|NWConnection|Network\.|Socket|https?://|WebSocket' Sources/
      ```
      **Expected:** **no matches** — the sources contain no networking code.

## 10. Speaker attribution — calibration & validation (Teams, opt-in)

This section is the manual, live-meeting-gated workflow for the opt-in speaker-attribution feature
(`docs/2-speaker-attribution/spec.md`). It is separate from §1–§9 above: the feature ships **off by
default** and stays disabled in Settings until calibration has been completed for at least one layout.
See `.copilot-tracking/plans/2026-08-17/speaker-attribution-phase-7-plan.md` §2/§4 for the full
rationale and repo-root `docs/2-speaker-attribution/calibration-record.md` for the committed evidence.

**Scope as of 2026-08-18:** calibrated for strict macOS Teams 1-on-1, three-person, and one
seven-person 4-over-3 Gallery layout. Environment: **macOS 26.5.1 (build 25F80)**, **Teams
26149.1804.4788.5681**. The Gallery pass used 2400×926 frames, observed two different active speakers
and one no-outline interval, and verified cropped-label OCR. Candidate frame-shape and exact marker
geometry keep shared-content, side-panel, other participant counts, resized, and unknown layouts fail
closed. Original AC-4 end-to-end transcript validation passed in the three-person layout.

### 10a. One-time calibration (COMPLETE for 1-on-1, three-person, and seven-person Gallery — 2026-08-18)

- [x] Joined a live Teams 1-on-1 meeting (one other participant) in the full-frame primary-tile layout.
- [x] Ran `swift run AlembicCheck frame-dump com.microsoft.teams --list-windows` to confirm the live
      meeting window's exact title (or `CGWindowID`) — required because `frame-dump` fails closed on
      bundle-prefix-only input for Teams (no static title hints exist for it).
- [x] Ran `swift run AlembicCheck frame-dump com.microsoft.teams --meeting-title "<confirmed
      title-prefix>"` `--frames 10 --out app/Alembic/.frame-dump-scratch/live-calibration-remote-20260818`
      (gitignored scratch directory). A sensitive-data warning printed before capture, a `manifest.json`
      listed every written file as `"sensitive": true"`, and both text/geometry `.txt` reports and
      (`--include-images`) PNGs were written.
- [x] Compared each `frame-N.txt` OCR bounding box for the (known, not recorded here) participant's name
      against `SpeakerLabelCatalog.teamsDefaults`'s label region; noted actual pixel offsets — see
      `docs/2-speaker-attribution/calibration-record.md`, Calibration Pass #1, for the sanitized numeric
      evidence.
- [x] Captured a seven-person 4-over-3 Gallery view at 2400×926. Frames 1–8 outlined one top-row
      participant, frame 9 had no outline, and frame 10 outlined a different top-row participant.
      Cropped-label Vision OCR recognized both active labels at confidence 1.0.
- [x] Captured a three-person layout at 2400×926 with both remote speakers independently active,
      two crosstalk frames, and multiple no-outline frames. Added only the two remote tile candidates.
- [x] Hand-edited `Sources/AlembicKit/SpeakerLabelCatalog.swift`'s `teamsDefaults` literals to the
      measured 1-on-1 geometry; removed the previously-unmeasured, speculative grid-view candidates
      entirely (not merely left unvalidated). A first pass's speculative left-edge, 20%-wide
      `.highlightColor` sample (`#6264A7`) never matched, but a corrected, narrow re-measurement (a
      single 1px-wide pixel column at frame-x=3) found the real active-tile outline: `#797EE5` on
      active-speaking frames vs. a distinctly different neutral color on inactive frames at the same
      pixels. The shipped marker is that corrected, measured `.highlightColor` value — never an
      unconditional/"trivially active" marker kind, which was considered and explicitly rejected.
- [x] Authored the committed calibration record (repo-root `docs/2-speaker-attribution/calibration-record.md`)
      with the numeric measurements, view mode tested, frame dimensions, title fragment, marker
      color/tolerance, macOS/Teams build numbers, and a manifest SHA-256 integrity reference —
      **no raw screenshots, no raw participant names**.
- [x] Kept `markersValidated == true` after adding the measured Gallery candidates, a strict
      2.57–2.61 frame-aspect signature, and the measured `#8288FC` top-outline marker.
- [x] Updated (not deleted) the calibration canary: `checkMarkersValidatedRequiresManualCalibration` is
      now `checkTeamsOneOnOneCalibrationEvidence`, asserting `markersValidated == true` **and** that the
      committed calibration record exists and documents this exact evidence (date, frame dimensions,
      title fragment) — see that check's doc comment in `AlembicCheck.swift`. Added
      `checkTeamsOneOnOneMarkerCalibration` (the measured marker color match/nonmatch proof) and
      `checkAppModelAttributionGateAudit` (a structural audit locking `AppModel.start()`'s
      `attributionGated` to the conjunction of `markersValidated` AND `matchesLayout(meetingTitle:)`).
- [x] Re-ran `swift run AlembicCheck` — full suite green (1550 checks passed, 0 failed),
      and the release build plus signed app-bundle build completed successfully.
- [x] Deleted every scratch frame-dump directory used for the calibration passes (they contained real participant
      names/OCR text and raw PNGs — do not commit or retain them), then ran
      `git status --ignored --short` from the repo root and confirmed the scratch directory does not
      appear as an untracked/staged file.

### 10b. End-to-end attribution validation — supported layouts

**Complete.** A live three-person Teams recording satisfied original AC-4.

- [x] Enable the attribution toggle in Settings (now enabled since a `markersValidated` entry exists).
      **Expected:** the copy states on-device/no-data-leaves-the-Mac (UR-2) and the approximate-names
      caveat (UR-3).
- [x] Join a calibrated three-person Teams meeting.
- [x] Confirm at least one far-end segment is attributed with the correct participant name and
      `attribution.source == "vision"`.
- [x] Confirm ambiguous/off-screen cases fall
      back to plain `them`, with no dropped or corrupted segments (SR-12's no-guess posture).
- [x] **Evidence handling — sanitized only, nothing raw committed or shared.** The resulting `.jsonl`
      and rendered `.md` for this session **MUST NOT** be committed to the repository, attached to a
      PR, pasted into an issue/chat, or otherwise shared. Retain them **locally only**, and only for as
      long as needed:
      1. Spot-check locally with the `python3 -m json.tool`-style line validation from §5, filtering
         for `"source":"vision"`, and confirm the known participant's correct name appears at least once.
      2. Author the **committed** evidence instead: a sanitized entry in "End-to-End Validation Pass #1"
         of `docs/2-speaker-attribution/calibration-record.md` recording — numbers and pass/fail only, no
         transcript text — the session date, segment counts (total / `source == "vision"` / `them`
         fallback), and (only if useful) a minimal, hand-redacted JSON snippet with the participant's
         actual name replaced by a placeholder. A SHA-256 hash of the local `.jsonl` MAY be recorded
         alongside as a non-reversible integrity reference.
      3. **Cleanup:** delete the local `.jsonl`/`.md` evidence files once the calibration-record entry is
         written; confirm via `git status --short` that no transcript file was staged or committed.
- [ ] Disable the toggle; confirm the very next recording's `.jsonl`/`.md` is identical in shape to the
      pre-feature baseline. **Note:** this manual disable-and-observe step is a **non-authoritative
      smoke check only** — the byte-for-byte requirement is proven authoritatively by the deterministic
      `checkOffToggleByteIdenticalOutput` case in `swift run AlembicCheck`.
- [x] **Cleanup:** confirm any frame-dump scratch directory has been deleted and does not reappear as a
      side effect of this end-to-end session (`git status --ignored --short` clean).

### 10c. NOT SUPPORTED — other Gallery sizes, shared content, and side panels

Only the measured three-person and seven-person 4-over-3 Gallery geometries are supported.
Shared-content views, participant rails, transcript/chat side panels, other participant counts, and materially resized
windows remain unsupported. They produce no attribution unless a future calibration pass adds a
distinct frame signature, candidate geometry, marker evidence, and OCR validation.

## Sign-off

- [ ] **Acceptance:** a real Teams meeting produced an accurate, timestamped
      canonical `.jsonl` + readable `.md` under `~/Documents/Alembic/`, with no
      unexpected network egress, no 1-minute reset, and `dropped == 0`.
- [x] **Speaker attribution — calibration (§10a):** complete for strict 1-on-1, three-person, and
      seven-person 4-over-3 Gallery. Sanitized evidence is in Calibration Passes #1–#3.
- [x] **Speaker attribution — end-to-end validation (§10b):** original AC-4 passed with 9 correct
      Vision-attributed segments and zero wrong-name segments.
- [ ] **Other layouts (§10c):** not supported or claimed; future support requires separate live
      calibration evidence.

Tester: ___________________  Date: ___________  macOS build: ___________
