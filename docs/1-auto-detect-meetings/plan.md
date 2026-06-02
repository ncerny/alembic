# Implementation Plan: Auto-Detect Meetings & Auto-Start Transcription

**Date:** 2026-06-02
**Research:** `.copilot-tracking/research/2026-06-02/auto-detect-meeting-research.md`
**Scope notes:**
- **Discord is manual-only for now** (excluded from the auto-detect allow-list) per the requester. Its known false-positive behavior (mic held whenever connected to a voice channel) makes it the riskiest over-firer; defer until the rest is proven.
- **Browser Google Meet is also deferred to manual-only** in the core iteration. Meet audio attributes to generic renderer/helper bundles (`com.google.Chrome.helper*`, `com.apple.WebKit.WebContent`) that cannot be safely distinguished from any other browser audio without window-title confirmation. Auto-detect for Meet is gated behind the optional `WindowTitleProbe` (Phase 7); until that ships, only **native-app** meetings auto-start.

## Goal

Let Alembic automatically detect that a meeting is live in a known **native** app (Microsoft
Teams, Zoom, Slack), auto-select that app as the "them" capture target, and auto-start
transcription via the existing pipeline — so the user stops losing the first minutes of
calls. Auto-stop when the call ends. Strictly **opt-in**, on-device only, no networking.
Browser Google Meet support is added later via the optional window-title probe (Phase 7).

## Confirmed Decisions (from research)

- **Primary signal = CoreAudio per-process attribution.** `kAudioHardwarePropertyProcessObjectList`
  + `kAudioProcessPropertyBundleID` + `IsRunningInput`/`IsRunningOutput`. Zero TCC, macOS 14.2+
  (below the macOS 26 floor, so always available). Gives exact bundle-ID attribution with no capture.
- **In-call rule = bundle-ID family aggregation.** A meeting is live ⇔ ANY process whose bundle ID
  prefix-matches a known meeting app (e.g. `com.microsoft.teams2*` covers `.modulehost`/`.helper`)
  has `IsRunningInput OR IsRunningOutput == true`, **excluding Alembic's own PID**. Empirically
  confirmed: idle Teams = all flags false; muted in-call = `modulehost` output-only + helper in+out.
- **Cheap wake-up trigger = `kAudioDevicePropertyDeviceIsRunningSomewhere`** on default input+output,
  rebound on default-device changes. Avoids constant polling of the process list.
- **Per-app precision policy is data-driven** (`requiresOutput` flag, bundle-ID prefixes, optional
  title hints) living in a Foundation-only catalog, unit-tested in AlembicCheck.
  - Default OR gate catches muted/listen-only joins immediately.
  - **Zoom** over-fires (Settings→Audio mic preview) → require output-active (or window title).
  - **Google Meet** in a browser attributes to a generic renderer/helper bundle
    (`com.google.Chrome.helper*`, `com.apple.WebKit.WebContent`) that is indistinguishable from any
    other browser audio by bundle ID alone → **deferred to Phase 7**: requires a window-title
    confirmation ("Meet –") before it may emit a detection. Generic browser-helper audio must NEVER
    produce a detection on its own.
  - **Discord** = manual-only this iteration; not in the auto-detect allow-list.
- **Opt-in only.** Gate behind a master toggle (persisted in UserDefaults). Never silently start.
- **Auto-stop only stops sessions this feature auto-started.** Track that the active session was
  detector-initiated (plus its detected bundle ID); never auto-stop a user-initiated recording.
- **Privacy invariant intact** — all signals are local OS APIs; no networking added.

## Architecture

```
DeviceActivityMonitor (input+output) ─┐  cheap interrupt wake-up (mic or output goes active)
NSWorkspace launch/terminate notifs  ─┼─▶ MeetingDetector ──▶ AudioProcessMonitor (per-process)
WindowTitleProbe (poll 10-15s, opt)  ─┘     (debounce 3-5s)    known meeting app has Input OR Output?
                                                                     exclude self PID; apply per-app policy
                                                                              │
                                                       Detection{bundleID, displayName, confidence}
                                                                              │
                                          AppModel: if autoStartEnabled && session idle →
                                          map bundleID → CaptureTarget → selectedTarget → start()
                                          on detection==nil sustained N s while recording → stop()
```

### Placement rules (enforced by existing conventions)

- The detection "brain" lives under `Sources/AlembicKit/Platform/macOS/` — CoreAudio / AppKit /
  CoreGraphics imports are forbidden at the top level of AlembicKit.
- `MeetingSession` stays **Foundation-only**; it is NOT modified.
- `AppModel.makeSession` / `AppModel` (composition root) is the **only** place allowed to own and wire
  the new `MeetingDetector` to start/stop. Auto-start = set `selectedTarget`, then call existing `start()`.
  Auto-stop = call existing `stop()`.
- Pure logic (bundle-ID matching, debounce/confidence state machine) lives in **Foundation-only**
  AlembicKit top-level files and is tested by `checkX` functions in `AlembicCheck.swift`
  (the only test mechanism that executes under CLT).

### New / edited files

```
app/Alembic/Sources/
  AlembicKit/                              (Foundation-only — testable core)
    MeetingAppCatalog.swift          (NEW: known meeting apps; bundle-ID prefix matching; per-app
                                          requiresOutput flag + title hints; app-specific helper→parent
                                          mapping (e.g. Teams). Generic browser/WebKit helpers are
                                          flagged requiresTitleConfirmation and cannot match alone.
                                          Discord intentionally absent this iteration.)
    MeetingDetectionPolicy.swift     (NEW: pure debounce/confidence state machine
                                          Idle→Confirming→Active→Ending; input over signal samples)
    Platform/macOS/
      AudioProcessMonitor.swift      (NEW: kAudioHardwarePropertyProcessObjectList enumeration;
                                          per-process PID/BundleID/IsRunningInput/IsRunningOutput;
                                          @available(macOS 14.2, *) guard; excludes own PID)
      DeviceActivityMonitor.swift    (NEW: kAudioDevicePropertyDeviceIsRunningSomewhere on ALL
                                          input- and output-capable devices → AsyncStream<Bool>;
                                          rebind on device-list / default-device changes; listener
                                          block stored nonisolated(unsafe); debounce false-edge 200-500ms)
      MeetingAppWatcher.swift        (NEW: NSWorkspace.runningApplications + didLaunch/didTerminate
                                          notifications → which known meeting apps are present)
      WindowTitleProbe.swift         (NEW, Phase 7: CGWindowListCopyWindowInfo title heuristics;
                                          REQUIRED to unlock browser Google Meet + disambiguate Zoom;
                                          poll 10-15s using already-granted Screen Recording)
      MeetingDetector.swift          (NEW: fuses the monitors + policy → AsyncStream<Detection?>;
                                          Sendable Detection value type; applies multi-app conflict rules)
  Alembic/
    AppModel.swift                   (EDIT: own a MeetingDetector; consume detections; gate on the
                                          UserDefaults toggle via setAutoStartEnabled(_:); track
                                          detector-initiated session ownership; map bundleID→CaptureTarget;
                                          call start()/stop())
    SettingsView.swift               (EDIT: "Auto-start when a meeting is detected" toggle that both
                                          persists via @AppStorage AND calls AppModel.setAutoStartEnabled;
                                          @AppStorage key)
    AlembicCheck/AlembicCheck.swift  (EDIT: register checkMeetingAppCatalog + checkMeetingDetectionPolicy
                                          + extend the Foundation-only static audit to the new top-level files)
```

### New UserDefaults / @AppStorage keys

| Key | Role |
|---|---|
| `alembic.autostart.enabled` | Master opt-in toggle. Written by `SettingsView` (`@AppStorage`); read directly from `UserDefaults` by `AppModel` (an `@Observable @MainActor` class, not a View — it does not use `@AppStorage`). `SettingsView` also calls `AppModel.setAutoStartEnabled(_:)` so the detector starts/stops immediately; `AppModel` may also observe `UserDefaults.didChangeNotification` as a backstop. |
| `alembic.autostart.autoStopEnabled` (optional) | Whether end-of-call auto-stops vs just prompts. |

## Phases

### Phase 1 — Foundation-only detection core (no Apple APIs yet)
- `MeetingAppCatalog.swift`: a `Sendable` model of known meeting apps. Each entry: display name,
  one or more bundle-ID **prefixes** (`com.microsoft.teams`, `com.microsoft.teams2`, `us.zoom.xos`,
  `com.tinyspeck.slackmacgap`), a `requiresOutput: Bool` over-firer flag (Zoom = true), a
  `requiresTitleConfirmation: Bool` flag (for generic browser/WebKit helpers used by Meet — true, and
  unmatched until Phase 7), optional title hints, and an app-specific `parentBundleID` mapping for
  helper/renderer bundles back to the capturable parent app. **Discord deliberately omitted** this
  iteration; **generic browser/WebKit helper families are present but `requiresTitleConfirmation` so
  they cannot match on bundle ID alone** (prevents browser audio — including Discord web — from being
  mistaken for a meeting).
  - Pure functions: `match(bundleID:) -> MeetingApp?` (longest-prefix), `resolveParent(bundleID:)`,
    and `isInCall(processStates:) -> MeetingApp?` applying the OR gate + per-app `requiresOutput`, and
    skipping any app whose `requiresTitleConfirmation` is set (those need Phase 7's probe).
- `MeetingDetectionPolicy.swift`: a pure state machine `Idle → Confirming → Active → Ending` that
  takes timestamped boolean samples ("a known meeting app currently holds audio") and a clock, and
  emits transitions only after the debounce window (start ≥3-5s sustained; end after N s idle). No I/O.
- Extend / migrate `teamsBundleIDHints` (ScreenCaptureKitSource) to source from `MeetingAppCatalog`
  so there is a single source of truth (keep the existing `isLikelyTeams` API working).
- **Acceptance:** `swift run AlembicCheck` green with new `checkMeetingAppCatalog`
  (prefix matching, helper→parent mapping, Zoom requiresOutput, generic-browser-helper
  requiresTitleConfirmation does NOT match alone, Discord NOT matched) and
  `checkMeetingDetectionPolicy` (no start before debounce; start on sustained signal; end after idle;
  excludes-self contract documented). Extend the Foundation-only static audit so these two new
  top-level files are asserted free of Apple-framework imports. No Apple-framework imports in these files.

### Phase 2 — CoreAudio per-process monitor (`AudioProcessMonitor`)
- Under `Platform/macOS/`, `@available(macOS 14.2, *)`-guarded. Enumerate
  `kAudioHardwarePropertyProcessObjectList`; for each object read `kAudioProcessPropertyPID`,
  `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningInput`,
  `kAudioProcessPropertyIsRunningOutput`. Emit a snapshot array of
  `(pid, bundleID, input, output)` — a `Sendable` value type reusing the Phase-1 catalog types.
- **Exclude Alembic's own PID** (`ProcessInfo.processInfo.processIdentifier`) so our own mic tap never
  self-triggers.
- Expose a `snapshot()` for on-demand reads (called when the cheap trigger fires / on a slow poll).
  No constant high-frequency polling.
- **Acceptance:** manual diagnostic only — a debug-only utility (NOT an authoritative `AlembicCheck`
  assertion) prints the live snapshot, verified against the saved `files/audioprobe.swift watch`
  behavior (idle Teams = all false; in-call = the family shows input/output true). Automated CLT
  coverage stays on the pure mapping it feeds (`MeetingAppCatalog.isInCall`, fed fake
  `AudioProcessState` inputs in Phase 1) — never live CoreAudio snapshots, which are environment-dependent.

### Phase 3 — Device wake-up + app presence monitors
- `DeviceActivityMonitor.swift`: listeners on `kAudioDevicePropertyDeviceIsRunningSomewhere` for
  **all input-capable AND output-capable devices** (not just the defaults — apps like Zoom/Teams may
  select a non-default device such as AirPods or a USB interface), bridged to `AsyncStream<Bool>`
  exactly like the existing `StreamAudioOutput` AsyncStream bridge. Rebind the listener set on
  `kAudioHardwarePropertyDevices` (device list) and default-device changes. Store the CoreAudio
  listener block `nonisolated(unsafe)`; debounce the false→idle edge 200-500ms. This is the cheap
  interrupt that tells the detector "go read the process list now." Back it with a bounded
  low-frequency safety poll (e.g. every ~10-15s) so a missed wake-up only delays detection by that
  interval rather than dropping it.
- `MeetingAppWatcher.swift`: `NSWorkspace.shared.runningApplications` filtered to catalog bundle IDs,
  plus `didLaunch/didTerminateApplicationNotification`, exposing the set of present known meeting apps
  as context (NOT a call signal by itself).
- **Acceptance:** manual gate — toggling audio in any app flips the device stream; launching/quitting a
  meeting app updates the watcher set. Concurrency: builds clean under Swift 6 strict concurrency.

### Phase 4 — `MeetingDetector` fusion
- `MeetingDetector.swift`: owns the Phase-2/3 monitors + the Phase-1 policy. On a device-activity
  wake-up (or a low-frequency safety poll), take an `AudioProcessMonitor.snapshot()`, run it through
  `MeetingAppCatalog.isInCall`, feed the boolean into `MeetingDetectionPolicy`, and emit
  `AsyncStream<Detection?>` where `Detection = { bundleID (parent), displayName, confidence }` and
  `nil` means "no active meeting". Map any app-specific helper/child bundle ID to the parent app id so
  the emitted `bundleID` is directly resolvable to a `CaptureTarget`.
- **Multi-app conflict rules** (several known apps may hold audio at once — Teams call + Zoom settings
  preview, Slack huddle + browser audio): (a) while a detector-initiated session is recording, keep the
  current target — **never switch targets mid-session**; (b) when idle, pick the highest-confidence app
  (output-active beats input-only); (c) on a tie with no clear winner, **do not auto-start** (emit no
  detection / surface a prompt) rather than guess.
- Cross-actor shared state (last snapshot, current policy state read by the `@Sendable` device
  callback) uses the established **NSLock-guarded `@unchecked Sendable` box** pattern
  (`LocaleBox`/`VocabularyBox`).
- **Acceptance:** an integration-style check (using a fake snapshot provider + injected clock, so it
  runs under CLT) drives Idle→Active→Ending and asserts the emitted `Detection` bundle ID is the
  **parent** app, confidence escalates correctly, the conflict rules hold, and
  Zoom-without-output / generic-browser-helper / Discord do not emit.

### Phase 5 — AppModel wiring (auto-start / auto-stop)
- `AppModel` owns a `MeetingDetector` (created lazily; only started while the toggle is on). It reads
  the toggle **directly from `UserDefaults`** (it is an `@Observable @MainActor` class, not a View, so
  it does not use `@AppStorage`) and exposes `setAutoStartEnabled(_:)` for `SettingsView` to call,
  starting/stopping the detector immediately; it may also observe `UserDefaults.didChangeNotification`
  as a backstop. A consumer task reads the detector's `AsyncStream<Detection?>`:
  - On non-nil `Detection` while enabled and `session` is idle/selecting: resolve
    `bundleID → CaptureTarget` via the existing `availableTargets()`/`matches` mapping (bundle ID is
    already `CaptureTarget.id`), set `selectedTarget`, **record that this session is detector-initiated
    plus its detected bundle ID** (e.g. an `autoStartedTarget: CaptureTarget?` field), and call the
    existing `start()` (which already runs the permissions gate + asset preflight + vocabulary load —
    no new start path).
  - On `nil` sustained for N s while `recording`: **only auto-stop if the active session was
    detector-initiated** (`autoStartedTarget != nil`) and (optional `autoStopEnabled`) — call existing
    `stop()`. **A user-initiated recording is NEVER auto-stopped.** Clear `autoStartedTarget` on any stop.
- Respect existing guards: never auto-start mid-preflight, never override a user-initiated session,
  honor `canStart`/`canStop`. If the detected app is not yet in `availableTargets`, run a
  `refreshTargets()` first; if still unresolved, no-op (do not guess).
- Start/stop the detector via `setAutoStartEnabled(_:)` when the toggle flips.
- **Acceptance:** manual gate — with the toggle ON, joining a Teams/Zoom/Meet call auto-starts against
  the right app within the debounce window and leaving auto-stops (if enabled). With the toggle OFF,
  behavior is identical to today. Deterministic CLT coverage stays at the policy/catalog level.

### Phase 6 — Settings UI + consent
- `SettingsView`: add an "Auto-start when a meeting is detected" `Toggle` bound to
  `@AppStorage("alembic.autostart.enabled")` whose change handler also calls
  `AppModel.setAutoStartEnabled(_:)`. Secondary text lists the **currently auto-detected native apps
  (Teams, Zoom, Slack)** and notes that Discord and browser Google Meet are manual-only until window-
  title detection ships (Phase 7), and that detection is fully on-device. Optional secondary toggle for
  auto-stop. Match the existing `Form`/`Section` styling.
- **Acceptance:** toggle persists across launches; flipping it starts/stops detection (Phase 5);
  `swift run AlembicCheck` green; `bash build.sh` produces a signed app.

### Phase 7 — WindowTitleProbe: unlock browser Google Meet + Zoom disambiguation
- Add `WindowTitleProbe.swift` using `CGWindowListCopyWindowInfo` + `kCGWindowName` (already-granted
  Screen Recording), polled every 10-15s. This is the signal that **unlocks browser Google Meet**
  (clears the `requiresTitleConfirmation` gate only when a "Meet –" tab title is present and a generic
  browser/WebKit helper holds audio) and disambiguates Zoom Settings→Audio (require "Zoom Meeting"
  title or output-active). Fed as a required confirmation for `requiresTitleConfirmation` apps and a
  secondary confirmation elsewhere — never the sole signal, and background/hidden tabs that the
  CoreAudio signal already covers are not regressed.
- On unlock, update the Settings secondary text (Phase 6) to include Google Meet.
- **Acceptance:** browser Meet auto-starts only with a confirming tab title; non-meeting browser tabs
  and Discord web do not; Zoom settings-preview no longer false-starts. Manual gate.

## Reusable Assets

| Asset | Source | Reuse |
|---|---|---|
| Bundle-ID ↔ CaptureTarget mapping | `ScreenCaptureKitSource.matches` / `availableTargets()` / `target(for:)` (lines 270-305) | High — detected bundle ID resolves directly; no new mapping layer |
| Teams bundle-ID hints | `teamsBundleIDHints` / `isLikelyTeams` (ScreenCaptureKitSource:287-305) | High — migrate into `MeetingAppCatalog` as single source of truth |
| AsyncStream-from-callback bridge | `StreamAudioOutput` (ScreenCaptureKitSource:34-52) | High — pattern for `DeviceActivityMonitor` |
| NSLock `@unchecked Sendable` box | `LocaleBox`/`VocabularyBox` (AppModel:339-371) | High — detector cross-actor state |
| Existing start/stop pipeline | `AppModel.start()` / `stop()` (AppModel:166-243) | High — auto-start/stop just invoke these |
| `@AppStorage` + UserDefaults settings pattern | `SettingsView` (181-184) | High — auto-start toggle |
| AlembicCheck `checkX` + CheckSuite | `AlembicCheck.swift` `runAllChecks` (20-32) | High — register two new pure checks |
| Empirical probe | `files/audioprobe.swift` (session) | Medium — manual validation of Phase 2 |

## Out of Scope / Deferred

- **Discord auto-detection** — manual-only for now (requester). When revisited: use `IsRunningOutput`
  (far-end audio) and/or the AX "Disconnect" item, since Discord holds the mic whenever connected to a
  voice channel even when alone/muted/PTT.
- **Browser Google Meet auto-detection until Phase 7** — Meet attributes to generic browser/WebKit
  helper bundles indistinguishable from other browser audio by bundle ID; it stays manual-only until
  the `WindowTitleProbe` (Phase 7) provides "Meet –" title confirmation. Native-app meetings
  (Teams/Zoom/Slack) auto-start without it.
- **`com.apple.controlcenter` `log stream` subprocess** — more attribution-precise but version-fragile
  + needs a spawned subprocess; redundant given the public per-process HAL API. Fallback only if HAL
  attribution proves insufficient on macOS 26.
- **Core Audio process taps / SCStream probe capture** for detection — heavyweight, unnecessary.
- **`AVCaptureDevice.isInUseByAnotherApplication`** — documented unreliable cross-process on macOS 13+.
- **Final auto-stop policy** (auto-stop vs prompt; idle threshold N) — start with a conservative
  prompt-or-toggle; tune after real use (Potential Next Research in the research doc).
- **No change to the transcription/writer pipeline** — detection + orchestration only.

## Risks

- ⚠️ macOS 26 selector/log-wording drift — the CoreAudio HAL selectors are stable (macOS 14.2+); the
  only fragile path (controlcenter log) is explicitly out of scope. Verify `IsRunningInput/Output`
  on a real macOS 26 in-call (Teams already confirmed by the user's `watch` probe).
- ⚠️ Browser Google Meet helper-bundle attribution requires the WindowTitleProbe (Phase 7) — Meet is
  deferred to manual-only until then, so the native-app core ships safely without it.
- ⚠️ Self-trigger from Alembic's own mic tap — mitigated by excluding our own PID (Phase 2).
- ⚠️ False auto-starts → mitigated by opt-in toggle, debounce ≥3-5s, per-app `requiresOutput`,
  `requiresTitleConfirmation` for generic browser helpers, multi-app conflict rules, and excluding
  known over-firers (Discord, browser Meet) this iteration.
- ⚠️ Stopping a user's manual recording → mitigated by tracking detector-initiated session ownership;
  only auto-started sessions can be auto-stopped (Phase 5).
- Concurrency: CoreAudio callbacks run on a CoreAudio thread — keep them `nonisolated`, bridge to
  AsyncStream, never `await` from the callback (matches existing precedent).
