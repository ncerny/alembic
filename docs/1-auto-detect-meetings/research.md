<!-- markdownlint-disable-file -->
# Task Research: Auto-Detect Meetings & Auto-Start Transcription

Investigate whether Alembic can automatically (1) detect which process is binding the
microphone/speaker, and/or (2) intelligently monitor known meeting apps (Microsoft
Teams, Zoom, Discord, Slack, Google Meet), then automatically select the correct
"them" capture target and start transcription when a meeting begins — so the user no
longer has to remember to pick the meeting app and press Start (which has caused
missed/half-captured calls).

## Task Implementation Requests

* Detect when a meeting starts (mic and/or speaker activity, and/or a known meeting app becoming active).
* Auto-select the correct capture target (the meeting app producing audio).
* Auto-start transcription on detection (and ideally auto-stop when the meeting ends).
* Keep the privacy invariant intact: on-device only, no networking, Foundation-only top level.

## Scope and Success Criteria

* Scope: macOS 26 menu-bar app under `app/Alembic/`. Detection + auto-start orchestration only; does not change the transcription/writer pipeline.
* Assumptions:
  * Public APIs strongly preferred; the app is self-signed (not sandboxed) but must avoid private SPI where possible.
  * Apple-framework code stays under `Sources/AlembicKit/Platform/macOS/`; top-level `AlembicKit` stays Foundation-only.
  * No networking anywhere (privacy invariant).
* Success Criteria:
  * A clear, ranked recommendation of detection signals (reliability vs. permission cost).
  * Concrete integration points in the existing architecture (AppModel/MeetingSession/ScreenCaptureKitSource).
  * Identified permission/TCC implications and user-experience tradeoffs (auto-start opt-in, false positives).

## Outline

1. Current selection/start flow (codebase) — what auto-start must hook into.
2. Detection signals (external API research):
   - CoreAudio device-running listeners (mic/output active).
   - Per-process audio attribution (Core Audio process taps).
   - Running/active meeting-app enumeration (NSWorkspace, SCShareableContent).
   - Audio-energy gating to avoid false positives.
3. Alternatives analysis + recommended approach.
4. Integration plan + permission/UX considerations.

## Potential Next Research

* Verify `kAudioProcessPropertyIsRunningInput/Output`, `kAudioProcessPropertyBundleID`, and the `com.apple.controlcenter` log-message wording on an actual macOS 26 build (Apple may have changed the log predicate; the CoreAudio HAL selectors are stable).
  * Reasoning: subagents confirmed availability on macOS 14.2+ via real codebases but could not test on macOS 26 directly.
  * Reference: sbooth/CAAudioHardware AudioProcess.swift (`@available(macOS 14.2, *)`).
* Confirm new Teams (`com.microsoft.teams2`) helper-PID routing — RESOLVED empirically: in-call audio splits across `com.microsoft.teams2.modulehost` (output) and a `…helper` WebView (input+output); idle = all false. Detector must aggregate across the `com.microsoft.teams2*` family and map child PIDs to the parent app. Browser/Meet has the same pattern (renderer helper bundles). Remaining open: validate Zoom Settings→Audio false positive and Discord voice-channel behavior on this machine with the saved probe (`files/audioprobe.swift watch`).
* Decide auto-stop policy: when a meeting ends (mic/output both idle for N seconds), should Alembic auto-stop+save, or just prompt? Affects UX design.

## Research Executed

### File Analysis

* app/Alembic/Sources/Alembic/AppModel.swift
  * `selectedTarget: CaptureTarget?` lives on AppModel; menu picker binds to it (lines 42, 154-159).
  * `refreshTargets()` → `session.loadTargets()` then `autoSelectTargetIfNeeded()` which already auto-picks a likely-Teams target via `ScreenCaptureKitSource.isLikelyTeams`, else first target (lines 147-159).
  * `start()` is the single start entry: permissions gate → asset preflight → vocabulary load → `session.start(target:)` (lines 166-222). This is what auto-start would invoke.
  * Composition root `makeSession` is the only wiring point for platform collaborators (lines 106-142).
  * `LocaleBox`/`VocabularyBox` show the established NSLock-guarded `@unchecked Sendable` box pattern for cross-actor state (lines 339-371).
* app/Alembic/Sources/AlembicKit/MeetingSession.swift
  * State machine: idle → selecting → recording → finalizing → saved/error (lines 13-29). `start(target:)` guarded to only run from `.idle`/`.selecting` (line 182). Single-shot session; AppModel rebuilds on terminal state.
  * Platform-neutral / Foundation-only by contract (lines 49-54). Auto-detect platform code must NOT live here.
* app/Alembic/Sources/AlembicKit/Platform/macOS/ScreenCaptureKitSource.swift
  * `availableTargets()` enumerates windowed apps via `SCShareableContent` (lines 115-127).
  * `isLikelyTeams`, `teamsBundleIDHints`, `availableTeamsTargets()` already provide meeting-app heuristics (lines 287-305) — extensible to other meeting apps.
  * Already exposes live `meterUpdates` AsyncStream (per-source RMS). NOT used to gate auto-start (would miss listen-only stretches); at most a post-start confirmation that audio is flowing (lines 51, 87-88).
  * Capture is per-app via `SCContentFilter(display:including:[app])` (line 163). Knowing which app to capture is exactly the open problem.

### Code Search Results

* `teamsBundleIDHints`, `isLikelyTeams` — already exist in ScreenCaptureKitSource.swift:287-305; the meeting-app heuristic is a natural extension point (add Zoom/Discord/Slack/Meet bundle IDs).
* `availableTargets()` / `matches(_:_:)` — ScreenCaptureKitSource.swift:115-127, 278-281 — already maps bundle IDs ↔ CaptureTarget, so a detected bundle ID can be resolved to a target with no new mapping layer.

### External Research

Two parallel research subagents surveyed Apple docs + 20+ production Swift repos.

* CoreAudio per-process audio attribution (PUBLIC, zero-TCC, macOS 14.2+ — below the macOS 26 floor):
  * `kAudioHardwarePropertyProcessObjectList` enumerates every process registered with the audio HAL.
  * Per-process properties: `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput`.
  * Result: you can ask "which bundle ID is using the mic / speakers right now?" with NO capture, NO extra permission. This directly answers the user's "detect which processes are binding microphone/speaker" question.
  * Source: developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyprocessobjectlist ; reference impl sbooth/CAAudioHardware AudioProcess.swift (`@available(macOS 14.2, *)`).
* CoreAudio device-level activity (PUBLIC, zero-TCC, macOS 10.4+):
  * `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input/output device = cheap, interrupt-driven boolean "is any process doing mic/output IO". No PID. Observe via `AudioObjectAddPropertyListenerBlock`; rebind when `kAudioHardwarePropertyDefaultInputDevice`/`DefaultOutputDevice` changes (AirPods/USB).
  * Caveat: fires for Alembic's OWN mic tap once recording → use the per-process API to exclude `ProcessInfo.processInfo.processIdentifier`. For reliability, watch ALL input-capable devices (apps like Zoom/Teams may pick a non-default device) — ben-mig/kyrr MicrophoneMonitor.swift.
  * Swift 6 concurrency: the listener block runs on a CoreAudio thread; store it in `nonisolated(unsafe)` (or `nonisolated static let`) and bridge to an `AsyncStream<Bool>` — same pattern as the existing `StreamAudioOutput`. Debounce the false→idle edge 200-500ms.
* Running/active meeting apps (PUBLIC, zero-TCC):
  * `NSWorkspace.shared.runningApplications` + `didLaunch/didTerminateApplicationNotification` to know which known meeting apps exist. Bundle IDs: Zoom `us.zoom.xos`, Teams `com.microsoft.teams`/`com.microsoft.teams2`, Discord `com.hnc.Discord`, Slack `com.tinyspeck.slackmacgap`, Webex, FaceTime, plus browsers for Meet.
* Google Meet / call-state heuristics (needs Screen Recording — ALREADY granted):
  * `CGWindowListCopyWindowInfo` + `kCGWindowName` title heuristics ("Zoom Meeting", Slack "Huddle", Discord "Voice Connected", browser tab "Meet – …"). Expensive — poll every 10-15s, not per audio event. Misses background/hidden tabs (CoreAudio signal covers those).
* Cross-app idle/in-call mic behavior (documented + corroborated by reference impls screenpipe, koe, oschief.ai, stenoai):
  * **All five apps release the mic when idle** (`IsRunningInput=false` when open but not in a call) — so per-process input-active is a real in-call signal, not just "app running".
  * **Mic is held for the ENTIRE call even when muted/silent** (Teams, Zoom, Slack, Meet, Discord) — for AEC/noise-suppression/VAD. Confirms the listen-only/muted case is covered without any speech gate.
  * Exceptions where input-active ALONE over-fires:
    * **Zoom**: Settings → Audio screen opens the mic for the level-meter preview (orange dot with no call). Disambiguate via output-active or window title "Zoom Meeting".
    * **Discord**: holds the mic continuously whenever *connected to a voice channel* (even alone, muted, or PTT) — broader than "in a call with people". `IsRunningOutput=1` (far-end audio) or the AX "Disconnect" item is the better discriminator.
  * **Browser apps (Google Meet)**: input-active attributes to the renderer/helper bundle (`com.google.Chrome.helper.renderer`, `com.apple.WebKit.WebContent`), NOT the main browser — same parent-mapping problem as Teams helpers. Tab title contains "Meet – …".
  * Reference per-app disambiguators: Teams `(Meeting)`/`Call with`; Zoom `Zoom Meeting`; Slack `Huddle`/"Leave Huddle"; Discord "Disconnect"/`IsRunningOutput`; Meet renderer + "Meet –". Best open-source model: screenpipe `meeting_detector.rs` 4-state machine (Idle→Confirming→Active→Ending) with an audio-output backstop in Ending.
  * Composite high-precision gate (koe/screenpipe): `IsRunningInput AND IsRunningOutput` on the app-family eliminates BOTH the Zoom-settings and Discord-empty-channel false positives, while still catching muted/listen-only real calls (the app holds both streams the whole call). koe itself uses OR to catch the earliest moment of joining.
  * `AVCaptureDevice.isInUseByAnotherApplication` — KVO-observable but documented as UNRELIABLE for cross-process state on macOS 13+. Do not use as primary.
  * `com.apple.controlcenter` `log stream` subprocess — most attribution-precise (drives the orange dot) but needs a spawned subprocess and version-fragile message parsing; redundant given the per-process HAL API.
  * The orange-dot indicator itself uses private TCC/XPC SPI — no public query API.
  * Core Audio process taps (`AudioHardwareCreateProcessTap`, macOS 14.2+) capture PCM but are for capture, not enumeration; not needed for detection.
  * ScreenCaptureKit/`SCShareableContentInfo` exposes NO audio-presence info — cannot tell which app is producing audio without starting a (~200-600ms, ~15-25MB) capture.

### Project Conventions

* Standards referenced: Foundation-only top-level AlembicKit; Apple-framework code under Platform/macOS; no networking; checks added to AlembicCheck.swift; NSLock-guarded `@unchecked Sendable` boxes for cross-actor state.
* Instructions followed: .github/copilot-instructions.md (architecture, conventions, privacy invariant).

### Empirical Probe (this machine, macOS 26.4.1, 2026-06-02)

Ran a self-contained probe of `kAudioHardwarePropertyProcessObjectList` + `IsRunningInput/Output` (saved at session `files/audioprobe.swift`). Findings with **new Teams running but NOT in a call**:

* New Teams registers SEVERAL processes with the audio HAL: `com.microsoft.teams2.modulehost`, multiple `com.microsoft.teams2.helper` (WebView), `com.microsoft.teams2.notificationcenter`. **All showed `IsRunningInput = false` and `IsRunningOutput = false` while idle.** → Teams does NOT hold the mic open when merely open/not in a call. This makes per-process `IsRunningInput` a usable "in a call" signal for Teams.
* Implication for matching: in-call audio will surface under a `com.microsoft.teams2.helper` (WebView/Electron renderer) bundle ID, NOT the parent `com.microsoft.teams2`. Bundle-ID matching must be **prefix-based** (`com.microsoft.teams2*` → Teams) and the detector must map any helper PID back to the parent app so the SCStream `CaptureTarget` (which targets the main app) is correct.
* Alembic itself (`com.alembic.app`) appears in the list with both flags false when idle — confirms we can cleanly exclude our own PID, and that we only read `true` for ourselves once we start capturing.
* Could not test the in-call transition on this machine (no call active during research). The probe supports a `watch` mode for the user to confirm the idle→in-call→ended flag transitions live.

### Empirical Probe — confirmed in-call transition (user-run, 2026-06-02)

User ran the `watch` probe through a full Teams call lifecycle:

* **Idle (not in a call):** all `com.microsoft.teams2*` processes show `. .`.
* **Joined call, MUTED/SILENT:** `com.microsoft.teams2.modulehost` → `. Y` (output/far-end only); a second process (WebView helper) → `Y Y` (input + output).
* **Left call:** both return to `. .`.

Decisive conclusions:
* Teams releases the mic/speakers when not in a call → no idle false positives for Teams.
* **Input is held for the entire call even while the local user is muted/silent** (`Y` on input despite mute). This directly validates the corrected design: keying off the meeting app's audio session — NOT the user's speech — catches listen-only/muted calls. The user's original objection to a mic-energy gate is fully resolved.
* Audio IO is split across multiple processes of the app family (modulehost does output, a helper does input+output). The detection rule must **aggregate across the whole bundle-ID family**: in-call ⇔ ANY process whose bundle ID matches a known meeting app (prefix match) has `IsRunningInput OR IsRunningOutput == true`.
* Output-only on `modulehost` (`. Y`) is itself a strong "live call with a far-end" signal independent of the mic.

## Key Discoveries

### Project Structure

* The auto-start "brain" must live in `Sources/AlembicKit/Platform/macOS/` (CoreAudio/AppKit/CoreGraphics imports are forbidden at the top level). `MeetingSession` stays Foundation-only; `AppModel` (composition root) is the only place allowed to wire a new `MeetingDetector` to the session.
* `AppModel.start()` is the single auto-start entry point (it already runs the permissions gate + asset preflight + vocabulary load). Auto-start = call the existing `start()` after setting `selectedTarget`. `AppModel.stop()` is the auto-stop hook.
* `autoSelectTargetIfNeeded()` already auto-picks a likely-Teams target; the detector should set `selectedTarget` from the *detected bundle ID* (more precise than the name heuristic) before calling `start()`.

### Implementation Patterns

* Bridge CoreAudio callbacks to `AsyncStream` exactly like `StreamAudioOutput` already does for SCStream audio — the codebase precedent is established (ScreenCaptureKitSource.swift:34-52).
* Cross-actor shared state uses the NSLock-guarded `@unchecked Sendable` box pattern (`LocaleBox`/`VocabularyBox`, AppModel.swift:339-371) — reuse for any detector state read by a `@Sendable` callback.
* Pure logic (bundle-ID→meeting-app matching, the debounce/confidence state machine) belongs in `AlembicKit` top-level + a `checkX` in `AlembicCheck.swift` (the only test mechanism that executes under CLT).

### Ranked detection signals (most reliable + lowest permission first)

1. CoreAudio per-process: `kAudioHardwarePropertyProcessObjectList` + `IsRunningInput/Output` + `BundleID` → exact app using mic/speakers. Zero TCC, macOS 14.2+. PRIMARY.
2. `NSWorkspace.runningApplications` ∩ known meeting bundle IDs → app present (not necessarily in a call). Zero TCC. Context.
3. `kAudioDevicePropertyDeviceIsRunningSomewhere` (input) → cheap interrupt wake-up. Zero TCC, 10.4+.
4. Same on output → confirms a live call (far-end audio plays even when you're silent). Used as confirmation, NOT as a required gate alongside your mic.
5. `CGWindowListCopyWindowInfo` title heuristics → confirms active call + only reliable way for Google-Meet-in-browser. Uses already-granted Screen Recording; poll 10-15s.
6-8 (rejected): controlcenter log stream, `AVCaptureDevice.isInUseByAnotherApplication`, process taps — see External Research.

## Technical Scenarios

### Auto-detect a meeting and auto-start transcription against the right app

The user forgets to (a) select the meeting app and (b) press Start, losing the first minutes and/or capturing only their own mic. We want Alembic to detect a call in a known app, auto-select that app as the "them" target, and start transcription — opt-in, with auto-stop on meeting end.

**Requirements:**

* Detect "a meeting is happening in app X" with high precision (few false starts) and low permission cost.
* Resolve detected app → existing `CaptureTarget` and start via the existing pipeline.
* Keep platform code under `Platform/macOS/`; keep `MeetingSession` Foundation-only.
* Opt-in setting; auto-stop when the call ends; never silently start without user consent.

**Preferred Approach:**

Add a macOS `MeetingDetector` (under `Platform/macOS/`) that fuses three zero/low-permission signals and emits a `Sendable` detection stream. `AppModel` owns it and, when auto-start is enabled, maps the detected bundle ID to a target, sets `selectedTarget`, and calls the existing `start()`. Rationale: the CoreAudio per-process API gives exact bundle-ID attribution with no extra permission and no capture, directly answering "which process is binding the mic/speaker"; it's far more precise than name heuristics and reuses the existing bundle-ID↔target mapping.

```text
app/Alembic/Sources/
  AlembicKit/
    MeetingAppCatalog.swift            (NEW, Foundation-only: known meeting bundle IDs + matching logic)
    MeetingDetectionPolicy.swift       (NEW, Foundation-only: debounce/confidence state machine — testable)
    Platform/macOS/
      AudioProcessMonitor.swift        (NEW: kAudioHardwarePropertyProcessObjectList per-process input/output)
      DeviceActivityMonitor.swift      (NEW: kAudioDevicePropertyDeviceIsRunningSomewhere → AsyncStream<Bool>)
      MeetingAppWatcher.swift          (NEW: NSWorkspace running-apps + launch/terminate notifications)
      WindowTitleProbe.swift           (NEW, optional: CGWindowList call-state + Google Meet)
      MeetingDetector.swift            (NEW: fuses signals → AsyncStream<Detection?>)
  Alembic/
    AppModel.swift                     (EDIT: own MeetingDetector; wire detections → start()/stop())
    SettingsView.swift                 (EDIT: "Auto-start on detected meeting" toggle via @AppStorage)
  AlembicCheck/AlembicCheck.swift      (EDIT: checkMeetingAppMatching + checkDetectionPolicy)
```

**Detection / auto-start flow:**

```text
DeviceActivityMonitor(input/output) ─┐  cheap wake-up (mic or output goes active)
NSWorkspace launch/active notifs   ─┼─▶ MeetingDetector ──▶ AudioProcessMonitor (per-process)
WindowTitleProbe (poll 10-15s)     ─┘     (debounce 3-5s)    known meeting app has IsRunningInput
                                                                             OR IsRunningOutput? exclude self PID
                                                                                      │
                                                          Detection{bundleID, name, confidence}
                                                                                      │
                                                          AppModel: if autoStartEnabled && session idle →
                                                          map bundleID → CaptureTarget → selectedTarget → start()
                                                          on detection==nil for N s while recording → stop()
```

**Implementation Details:**

* Primary attribution (macOS 14.2+, guard with `@available`): enumerate `kAudioHardwarePropertyProcessObjectList`; for each, read `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningInput/Output`. **Aggregate across the bundle-ID family**: a meeting is live ⇔ ANY process whose bundle ID prefix-matches a known meeting app (e.g. `com.microsoft.teams2*` covers `.modulehost`/`.helper`/etc.) has `IsRunningInput OR IsRunningOutput == true`, excluding Alembic's own PID. Confirmed empirically: idle Teams = all flags false; in a muted call, `modulehost`=`. Y` and a helper=`Y Y`. Map the matched helper/child PID back to the parent app (via `NSRunningApplication`/bundle-ID prefix) so the resolved `CaptureTarget` targets the main app, not the renderer.
* Cheap trigger: `kAudioDevicePropertyDeviceIsRunningSomewhere` listeners on default input + output, rebinding on default-device changes, bridged to `AsyncStream<Bool>` (store the block `nonisolated(unsafe)`; debounce false-edge 200-500ms).
* False-positive gate: require a known meeting app whose process is **holding an audio session** — `kAudioProcessPropertyIsRunningInput` OR `kAudioProcessPropertyIsRunningOutput == true` on that app's process — sustained ≥3-5s before auto-start. Critically, this keys off the *meeting app* opening the audio device (which it does for the entire call, even while the local user is muted or silently listening), NOT off the local mic's audio energy/RMS. Music/dictation are excluded by the *bundle-ID filter* (the producing app isn't a known meeting app), so no speech-energy gate is needed or wanted. Optional disambiguation when an app holds audio without being in a call: far-end output activity and/or window-title call-state (never the local mic).
* Per-app precision rules (documented behavior, corroborated by screenpipe/koe/oschief.ai): the OR gate above is the default and catches muted/listen-only joins immediately. **Escalate to require output-active (or a window-title match) for the two known over-firers**: Zoom (Settings→Audio mic-preview opens the mic with no call) and Discord (connected-to-voice-channel ≠ in a call with people; `IsRunningOutput` = far-end audio is the real discriminator). For browser/Google Meet, match the renderer/helper bundle family (`com.google.Chrome.helper*`, `com.apple.WebKit.WebContent`) and map to the parent browser; confirm with tab title "Meet –". Keep this as a small data-driven per-app policy (allow-list + requiresOutput flag + title hints) in a Foundation-only `MeetingAppCatalog`, unit-tested via AlembicCheck.
* Target resolution reuses `ScreenCaptureKitSource.matches`/`availableTargets()` (bundle ID is already the `CaptureTarget.id`). Extend `teamsBundleIDHints` into a shared `MeetingAppCatalog`.
* Consent/UX: gate behind an opt-in `@AppStorage` toggle in `SettingsView` (matches existing settings pattern). On detection, either auto-start immediately or post a user notification "Meeting detected in Teams — Start?" depending on the toggle. Auto-stop when both signals idle for N seconds (policy TBD — see Potential Next Research).
* Privacy invariant intact: all signals are local OS APIs; no networking added.

#### Considered Alternatives

* Device-level `DeviceIsRunningSomewhere` only (no per-process): simplest and macOS 10.4+, but gives no PID/bundle ID — can't pick the right capture target and can't exclude Alembic's own mic. Rejected as the sole mechanism; kept as the cheap wake-up trigger.
* `AVCaptureDevice.isInUseByAnotherApplication` KVO: trivial API but documented unreliable for cross-process state on macOS 13+. Rejected.
* `com.apple.controlcenter` `log stream` subprocess: very precise attribution but requires spawning a subprocess and parsing version-fragile log wording; redundant given the public per-process HAL API. Rejected (keep as fallback only if HAL attribution proves insufficient on macOS 26).
* Core Audio process taps / SCStream probe captures to "listen for audio": heavyweight (PCM capture, ~200-600ms, ~15-25MB) and unnecessary for mere detection. Rejected.
* Window-title-only detection: necessary for Google-Meet-in-browser and good for call-state confirmation, but expensive, misses background tabs, and can't attribute audio. Kept as a secondary confirmation signal, not primary.
