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

## 8. Privacy spot-check (network egress)

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

## Sign-off

- [ ] **Acceptance:** a real Teams meeting produced an accurate, timestamped
      canonical `.jsonl` + readable `.md` under `~/Documents/Alembic/`, with no
      unexpected network egress, no 1-minute reset, and `dropped == 0`.

Tester: ___________________  Date: ___________  macOS build: ___________
