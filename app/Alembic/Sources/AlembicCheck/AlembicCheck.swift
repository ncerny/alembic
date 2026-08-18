import Foundation
import AlembicKit
import ScreenCaptureKit
import CoreVideo
import CoreGraphics

// MARK: - Subcommand dispatch (Phase 7 §1 — pure, no `exit`, no async, no I/O)

/// The result of matching `CommandLine.arguments` against `AlembicCheck`'s
/// known subcommands. A plain, `Equatable` value so `AlembicCheck` can assert
/// dispatch decisions directly (`SubcommandDispatch.resolve(...)`) without
/// ever invoking `main()` itself (which calls `exit(64)` for `.unknown` and
/// therefore must never run inside the check suite it is testing).
enum Subcommand: Equatable {
    case audioWatch(seconds: Double)
    case axDump(args: [String])
    case frameDump(args: [String])
    /// No subcommand argument at all — run the check suite.
    case checkSuite
    /// An unrecognized subcommand name — `main()` maps this to
    /// `exit(64)` after printing guidance; `resolve` itself never exits.
    case unknown(name: String)
}

/// Pure subcommand-name matcher, extracted out of `main()`'s former
/// if/else-chain (Phase 7 §1, resolves plan-review-2 MEDIUM-2's "structural
/// checks stay pure" requirement). No `exit`, no `async`, no I/O — every
/// input maps deterministically to exactly one `Subcommand` case.
enum SubcommandDispatch {
    static func resolve(arguments: [String]) -> Subcommand {
        guard arguments.count >= 2 else { return .checkSuite }
        switch arguments[1] {
        case "audio-watch":
            let seconds = arguments.count >= 3 ? (Double(arguments[2]) ?? 60) : 60
            return .audioWatch(seconds: seconds)
        case "ax-dump":
            return .axDump(args: Array(arguments.dropFirst(2)))
        case "frame-dump":
            return .frameDump(args: Array(arguments.dropFirst(2)))
        default:
            return .unknown(name: arguments[1])
        }
    }
}

/// Authoritative test runner for Alembic under Command Line Tools.
///
/// Run with: `swift run AlembicCheck`
///
/// Uses `async @main` so checks can exercise actors and `@MainActor` types
/// (the Phase 5 writer actor and Phase 6 orchestrator) without blocking the
/// main thread. Each phase appends its checks to `runAllChecks`.
@main
struct AlembicCheck {
    static func main() async {
        // Live diagnostic modes (everything else runs the check suite):
        // - `swift run AlembicCheck audio-watch [seconds]`   (AudioWatchProbe)
        // - `swift run AlembicCheck ax-dump [bundle-prefix] [--out path]
        //    [--max-visits n]`                                (AXDumpProbe)
        // - `swift run AlembicCheck frame-dump [bundle-prefix] [--meeting-title
        //    <title> | --window-id <id> | --list-windows] [--out path]
        //    [--frames n] [--interval seconds] [--include-images]`
        //                                                      (FrameDumpProbe, SR-22)
        //
        // Subcommand matching itself is a pure function (`SubcommandDispatch.
        // resolve`, below) so `AlembicCheck` can assert its dispatch behavior
        // — including the bogus-subcommand case — directly, without this
        // `main()` ever needing to be invoked as a check (it calls `exit`,
        // which a check must never do).
        switch SubcommandDispatch.resolve(arguments: CommandLine.arguments) {
        case .audioWatch(let seconds):
            await AudioWatchProbe.run(seconds: seconds)
        case .axDump(let subArgs):
            await AXDumpProbe.run(arguments: subArgs)
        case .frameDump(let subArgs):
            await FrameDumpProbe.run(arguments: subArgs)
        case .unknown(let name):
            // An unrecognized subcommand must fail loudly, not silently run
            // the suite (running a diagnostic from a branch that predates it
            // would otherwise look like the diagnostic "passing" 700 checks).
            print("AlembicCheck: unknown subcommand \"\(name)\" — expected audio-watch, ax-dump, or frame-dump, or no arguments for the check suite")
            exit(64)  // EX_USAGE
        case .checkSuite:
            let suite = CheckSuite()
            await runAllChecks(suite)
            suite.finishAndExit()
        }
    }


    /// Registry of all checks. Phases add their `check…` functions here.
    static func runAllChecks(_ s: CheckSuite) async {
        checkAppInfo(s)
        checkCoreModels(s)
        checkAudioSource(s)
        await checkAudioSourceAsync(s)
        checkTranscriptionEngine(s)
        await checkTranscriptionEngineAsync(s)
        await checkTranscriptWriter(s)
        await checkMeetingSession(s)
        checkTimestampFormatting(s)
        checkPermissionsLogic(s)
        checkVocabularyStore(s)
        checkMeetingAppCatalog(s)
        checkActiveSpeakerTimeline(s)
        checkSpeakerNameNormalizer(s)
        checkSpeakerLabelCatalog(s)
        await checkFakeAttributionProvider(s)
        checkVisionSpeakerAttributorThrottle(s)
        checkVisionSpeakerAttributorGeometry(s)
        checkVisionSpeakerAttributorCropAndColor(s)
        checkVisionSpeakerAttributorCandidateSelection(s)
        checkVisionSpeakerAttributorSelectName(s)
        checkVisionSpeakerAttributorAdvance(s)
        await checkVisionSpeakerAttributorCatalogGate(s)
        checkVisionSpeakerAttributorLayeringAudit(s)
        checkMeetingDetectionPolicy(s)
        checkDetectionTierPolicy(s)
        checkDetectInCall(s)
        checkMeetingDetector(s)
        checkMeetingContext(s)
        checkBestTitle(s)
        checkDisclosurePolicy(s)
        checkFoundationOnlyTopLevelAudit(s)
        checkCandidatePIDs(s)
        checkResolveMeetingWindowID(s)
        checkHasPositiveMeetingEvidence(s)
        checkVideoStreamPixelSize(s)
        checkFrameMetadataExtractor(s)
        checkValidatedPixelGeometry(s)
        checkValidatedPixelCopy(s)
        checkScreenCaptureConfigurationPlan(s)
        checkScreenCaptureAudioIdentitySourceAudit(s)
        checkVideoErrorIsolationSourceAudit(s)

        // --- Phase 7: diagnostic dispatch, calibration canary, coupled fixes, off-toggle proof ---
        checkFrameDumpSubcommandRegistered(s)
        checkFrameDumpValidatePureContract(s)
        checkTeamsOneOnOneCalibrationEvidence(s)
        await checkOffToggleByteIdenticalOutput(s)
        checkActiveSpeakerTimelineRetentionTrimOutOfOrderUpperBounds(s)
        checkVocabularyStoreNaturalOrderExpandNameParity(s)
        checkVisionSpeakerAttributorCropOverflowSafety(s)
        checkVisionSpeakerAttributorAdvanceNoOverlapOnSpeakerChange(s)

        // --- Phase 7 impl-review-1 corrective pass ---
        checkDiagnosticVideoCaptureVisibilityAudit(s)
        checkDiagnosticVideoCaptureBoundedCaptureSourceAudit(s)

        // --- 2026-08-18 live 1-on-1 marker calibration + AppModel gate audit ---
        checkTeamsOneOnOneMarkerCalibration(s)
        checkAppModelAttributionGateAudit(s)
    }

    // MARK: - Phase 8: pure permissions / first-run UX logic (no prompts)

    /// Locks the deterministic permission logic the app's `PermissionsModel`
    /// coordinator builds on: raw-status → state mapping, the Screen Recording
    /// requires-restart rule, the "ready to record" aggregation, the missing /
    /// primary-blocker selection, and the failure → actionable message+link
    /// mapping. Live system prompts, the restart recovery, and the System
    /// Settings deep-links are a MANUAL gate.
    static func checkPermissionsLogic(_ s: CheckSuite) {
        s.check("PermissionLogic maps mic/speech raw status to state") { s in
            s.expectEqual(PermissionLogic.state(for: .authorized), .granted, "authorized→granted")
            s.expectEqual(PermissionLogic.state(for: .denied), .denied, "denied→denied")
            s.expectEqual(PermissionLogic.state(for: .notDetermined), .unknown, "notDetermined→unknown")
        }

        s.check("Screen Recording requires-restart rule") { s in
            // Effective now ⇒ granted regardless of whether we prompted.
            s.expectEqual(
                PermissionLogic.screenRecordingState(effective: true, didRequest: false),
                .granted, "effective ⇒ granted")
            s.expectEqual(
                PermissionLogic.screenRecordingState(effective: true, didRequest: true),
                .granted, "effective after request ⇒ granted")
            // Prompted but not yet effective ⇒ the grant needs an app restart.
            s.expectEqual(
                PermissionLogic.screenRecordingState(effective: false, didRequest: true),
                .requiresRestart, "requested but not effective ⇒ requiresRestart")
            // Never prompted and not effective ⇒ unknown (preflight can't tell
            // denied from not-determined).
            s.expectEqual(
                PermissionLogic.screenRecordingState(effective: false, didRequest: false),
                .unknown, "not requested, not effective ⇒ unknown")
        }

        s.check("PermissionSnapshot ready-to-record only when all three granted") { s in
            let allGranted = PermissionSnapshot(microphone: .granted, speechRecognition: .granted, screenRecording: .granted)
            s.expect(allGranted.isReadyToRecord, "all granted ⇒ ready")
            s.expect(allGranted.missing.isEmpty, "all granted ⇒ nothing missing")
            s.expect(allGranted.primaryBlocker == nil, "all granted ⇒ no blocker")

            for kind in PermissionKind.allCases {
                var snap = PermissionSnapshot(microphone: .granted, speechRecognition: .granted, screenRecording: .granted)
                switch kind {
                case .microphone: snap.microphone = .denied
                case .speechRecognition: snap.speechRecognition = .denied
                case .screenRecording: snap.screenRecording = .denied
                }
                s.expect(!snap.isReadyToRecord, "\(kind.rawValue) denied ⇒ not ready")
                s.expect(snap.missing == [kind], "\(kind.rawValue) denied ⇒ only it missing")
            }
        }

        s.check("primaryBlocker picks a stable priority and detects restart") { s in
            // Mic wins priority over speech + screen when all are missing.
            let allMissing = PermissionSnapshot(microphone: .denied, speechRecognition: .denied, screenRecording: .denied)
            s.expectEqual(allMissing.primaryBlocker, .microphoneDenied, "mic has priority")

            let speechOnly = PermissionSnapshot(microphone: .granted, speechRecognition: .denied, screenRecording: .granted)
            s.expectEqual(speechOnly.primaryBlocker, .speechRecognitionDenied, "speech blocker")

            let screenDenied = PermissionSnapshot(microphone: .granted, speechRecognition: .granted, screenRecording: .denied)
            s.expectEqual(screenDenied.primaryBlocker, .screenRecordingDenied, "screen denied blocker")

            let screenRestart = PermissionSnapshot(microphone: .granted, speechRecognition: .granted, screenRecording: .requiresRestart)
            s.expectEqual(screenRestart.primaryBlocker, .screenRecordingRequiresRestart, "screen restart blocker")
        }

        s.check("PermissionKind exposes the correct System Settings deep-links") { s in
            s.expectEqual(
                PermissionKind.microphone.settingsURLString,
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone", "mic link")
            s.expectEqual(
                PermissionKind.speechRecognition.settingsURLString,
                "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition", "speech link")
            s.expectEqual(
                PermissionKind.screenRecording.settingsURLString,
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", "screen link")
        }

        s.check("StartupBlocker maps every failure to actionable guidance") { s in
            // Denials carry the matching Settings deep-link and are never silent.
            let mic = StartupBlocker.microphoneDenied.guidance
            s.expect(mic.message.contains("Microphone"), "mic message mentions Microphone")
            s.expectEqual(mic.settingsURLString, PermissionKind.microphone.settingsURLString, "mic link")
            s.expect(!mic.suggestsRestart, "mic does not suggest restart")

            let speech = StartupBlocker.speechRecognitionDenied.guidance
            s.expect(speech.message.contains("Speech Recognition"), "speech message")
            s.expectEqual(speech.settingsURLString, PermissionKind.speechRecognition.settingsURLString, "speech link")

            let screen = StartupBlocker.screenRecordingDenied.guidance
            s.expect(screen.message.contains("Screen Recording"), "screen message")
            s.expectEqual(screen.settingsURLString, PermissionKind.screenRecording.settingsURLString, "screen link")

            // Restart blocker recommends Quit & Reopen.
            let restart = StartupBlocker.screenRecordingRequiresRestart.guidance
            s.expect(restart.suggestsRestart, "restart blocker suggests restart")
            s.expect(restart.message.lowercased().contains("restart"), "restart message mentions restart")

            // Asset/locale/capture failures produce specific, non-empty messages.
            let locale = StartupBlocker.localeUnsupported("xx-YY").guidance
            s.expect(locale.message.contains("xx-YY"), "locale message names the locale")
            s.expect(locale.settingsURLString == nil, "locale has no Settings link")

            let asset = StartupBlocker.assetInstallFailed("offline").guidance
            s.expect(asset.message.contains("offline"), "asset message includes detail")

            let stopped = StartupBlocker.captureStopped("stream ended").guidance
            s.expect(stopped.message.contains("stream ended"), "capture-stopped message includes detail")
            s.expect(!stopped.message.isEmpty, "never an empty (silent) message")
        }
    }

    // MARK: - Phase 7: public hh:mm:ss formatter used by the SwiftUI layer

    /// Locks the now-`public` `TranscriptWriter.timestamp(from:)` formatter the
    /// menu + live transcript window rely on for elapsed/segment time display.
    static func checkTimestampFormatting(_ s: CheckSuite) {
        s.check("TranscriptWriter.timestamp formats session seconds as hh:mm:ss") { s in
            s.expectEqual(TranscriptWriter.timestamp(from: 0), "00:00:00", "zero")
            s.expectEqual(TranscriptWriter.timestamp(from: 5), "00:00:05", "seconds")
            s.expectEqual(TranscriptWriter.timestamp(from: 65), "00:01:05", "minutes + seconds")
            s.expectEqual(TranscriptWriter.timestamp(from: 3661), "01:01:01", "hours + minutes + seconds")
            s.expectEqual(TranscriptWriter.timestamp(from: 59.9), "00:00:59", "truncates fractional seconds")
            s.expectEqual(TranscriptWriter.timestamp(from: -3), "00:00:00", "negative clamps to zero")
        }
    }

    // MARK: - Phase 4: macOS TranscriptionEngine pure logic (model-free)

    static func checkTranscriptionEngine(_ s: CheckSuite) {
        s.check("TranscriptEventMapper maps volatile/finalized with source + attribution") { s in
            // Finalized result with a real audio range.
            let finalEvt = TranscriptEventMapper.event(
                from: RecognizerResult(text: "hello world", isFinal: true, audioStart: 1.0, audioEnd: 2.5, confidence: 0.8),
                source: .them,
                fallbackStart: 99,
                fallbackEnd: 99
            )
            s.expect(finalEvt != nil, "non-empty result produces an event")
            s.expectEqual(finalEvt?.kind, .finalized, "isFinal -> finalized")
            s.expectEqual(finalEvt?.source, .them, "engine source stamped")
            s.expectEqual(finalEvt?.start, 1.0, "uses recognizer audio start")
            s.expectEqual(finalEvt?.end, 2.5, "uses recognizer audio end")
            s.expectEqual(finalEvt?.text, "hello world", "text carried through")
            s.expectEqual(finalEvt?.attribution?.source, "asr", "asr attribution")
            s.expectEqual(finalEvt?.attribution?.confidence, 0.8, "confidence carried through")

            // Volatile result without a range falls back to the engine window.
            let volEvt = TranscriptEventMapper.event(
                from: RecognizerResult(text: "  partial ", isFinal: false),
                source: .you,
                fallbackStart: 3.0,
                fallbackEnd: 4.0
            )
            s.expectEqual(volEvt?.kind, .volatile, "not final -> volatile")
            s.expectEqual(volEvt?.source, .you, "you source stamped")
            s.expectEqual(volEvt?.start, 3.0, "falls back to engine start")
            s.expectEqual(volEvt?.end, 4.0, "falls back to engine end")
            s.expectEqual(volEvt?.text, "partial", "text trimmed")

            // Empty / whitespace text is never emitted.
            let empty = TranscriptEventMapper.event(
                from: RecognizerResult(text: "   ", isFinal: true),
                source: .you, fallbackStart: 0, fallbackEnd: 1
            )
            s.expect(empty == nil, "empty text yields no event")

            // Degenerate range: end clamped to be >= start.
            let clamped = TranscriptEventMapper.event(
                from: RecognizerResult(text: "x", isFinal: true, audioStart: 5.0, audioEnd: 4.0),
                source: .you, fallbackStart: 0, fallbackEnd: 0
            )
            s.expectEqual(clamped?.end, 5.0, "end clamped to start")
        }

        s.check("AudioInputCursor honors gaps, clamps overlaps, advances monotonically") { s in
            var cursor = AudioInputCursor()
            // First chunk at t=5 for 0.25s.
            let c1 = AudioChunk(samples: [Float](repeating: 0, count: 250), sampleRate: 1000, channelCount: 1, source: .them, startTime: 5.0)
            s.expectEqual(cursor.bufferStart(for: c1), 5.0, "first chunk honored")
            s.expectEqual(cursor.lastEnd, 5.25, "cursor advanced by duration")

            // Silence gap: next chunk jumps to t=10; gap preserved.
            let c2 = AudioChunk(samples: [Float](repeating: 0, count: 100), sampleRate: 1000, channelCount: 1, source: .them, startTime: 10.0)
            s.expectEqual(cursor.bufferStart(for: c2), 10.0, "silence gap preserved (start honored)")
            s.expectEqual(cursor.lastEnd, 10.1, "cursor advanced past gap")

            // Overlapping/out-of-order chunk (startTime behind cursor) is clamped forward.
            let c3 = AudioChunk(samples: [Float](repeating: 0, count: 100), sampleRate: 1000, channelCount: 1, source: .them, startTime: 9.0)
            s.expectEqual(cursor.bufferStart(for: c3), 10.1, "overlap clamped to cursor (no backwards time)")
        }

        s.check("AudioInputBackpressure escalates ok -> warning -> error and recovers") { s in
            var bp = AudioInputBackpressure(sustainedDropThreshold: 3)
            s.expectEqual(bp.health, .ok, "no drops -> ok")
            bp.recordEnqueued()
            s.expectEqual(bp.health, .ok, "enqueue stays ok")

            bp.recordDropped()
            s.expectEqual(bp.health, .warning, "a single drop -> warning")
            s.expectEqual(bp.dropped, 1, "drop counted")

            // Recover: an enqueue ends the consecutive-drop run (still warning,
            // since total dropped > 0, but not error).
            bp.recordEnqueued()
            s.expectEqual(bp.consecutiveDropped, 0, "enqueue resets the run")
            s.expectEqual(bp.health, .warning, "history of a drop keeps warning")

            // Sustained run of 3 consecutive drops escalates to error.
            bp.recordDropped(); bp.recordDropped(); bp.recordDropped()
            s.expectEqual(bp.health, .error, "sustained drops -> error")
            s.expectEqual(bp.dropped, 4, "total drops accumulate")
        }

        s.check("VolatileResultBuffer sheds volatile but never finalized") { s in
            var buf = VolatileResultBuffer(capacity: 2)
            func vol(_ t: Double) -> TranscriptEvent { TranscriptEvent(kind: .volatile, source: .you, start: t, end: t, text: "v\(t)") }
            func fin(_ t: Double) -> TranscriptEvent { TranscriptEvent(kind: .finalized, source: .you, start: t, end: t, text: "f\(t)") }

            buf.enqueue(vol(1))
            buf.enqueue(vol(2))
            buf.enqueue(vol(3)) // over capacity -> drop oldest volatile (vol1)
            s.expectEqual(buf.droppedVolatile, 1, "oldest volatile dropped")
            s.expectEqual(buf.pending.count, 2, "held at capacity")
            s.expectEqual(buf.pending.first?.text, "v2.0", "vol1 dropped, vol2 kept")

            // Finalized events are retained even beyond capacity.
            buf.enqueue(fin(4))
            buf.enqueue(fin(5)) // would exceed capacity but only finalized remain after shedding volatile
            let finalizedCount = buf.pending.filter { $0.kind == .finalized }.count
            s.expectEqual(finalizedCount, 2, "both finalized retained")
            s.expect(buf.pending.count >= 2, "finalized never dropped even over capacity")

            let drained = buf.drain()
            s.expect(!drained.isEmpty, "drain returns pending")
            s.expectEqual(buf.pending.count, 0, "buffer empty after drain")
        }
    }

    // MARK: - Phase 4: FakeTranscriptionEngine behaviour (async, model-free)

    static func checkTranscriptionEngineAsync(_ s: CheckSuite) async {
        await s.checkAsync("FakeTranscriptionEngine emits scripted events in order then finishes") { s in
            let script = [
                TranscriptEvent(kind: .volatile, source: .them, start: 0, end: 1, text: "hel"),
                TranscriptEvent(kind: .volatile, source: .them, start: 0, end: 2, text: "hello"),
                TranscriptEvent(kind: .finalized, source: .them, start: 0, end: 2, text: "hello",
                                attribution: TranscriptAttribution(source: "asr", confidence: 0.9)),
            ]
            let engine: any TranscriptionEngine = FakeTranscriptionEngine(script: script, emitOnStart: true)
            try await engine.start()

            var received: [TranscriptEvent] = []
            // finish() closes the stream so this for-await terminates.
            await engine.finish()
            for await event in engine.results { received.append(event) }

            s.expectEqual(received.count, 3, "all scripted events delivered")
            s.expectEqual(received, script, "events delivered in order, unchanged")
            s.expectEqual(received.last?.kind, .finalized, "ends on finalized")
        }

        await s.checkAsync("FakeTranscriptionEngine holds script until finish() drains") { s in
            let script = [
                TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "trailing utterance"),
            ]
            let engine = FakeTranscriptionEngine(script: script, emitOnStart: false)
            try await engine.start()
            // Feeding audio is accepted but does not change scripted output.
            await engine.append(AudioChunk(samples: [0.1], sampleRate: 48_000, channelCount: 1, source: .you, startTime: 0))
            let appended = await engine.appendedChunks
            s.expectEqual(appended.count, 1, "append recorded for orchestrator assertions")

            await engine.finish() // drains the held finalized event, then closes
            var received: [TranscriptEvent] = []
            for await event in engine.results { received.append(event) }
            s.expectEqual(received.count, 1, "trailing finalized event drained on finish")
            s.expectEqual(received.first?.text, "trailing utterance", "no trailing utterance lost")
        }

        await s.checkAsync("FakeTranscriptionEngine.finish is idempotent") { s in
            let engine = FakeTranscriptionEngine(script: [], emitOnStart: true)
            try await engine.start()
            await engine.finish()
            await engine.finish() // second call must be a no-op, not a double-finish crash
            var count = 0
            for await _ in engine.results { count += 1 }
            s.expectEqual(count, 0, "empty script; stream finished once")
        }
    }

    // MARK: - Phase 5: TranscriptWriter (incremental disk persistence)

    /// Strips the YAML frontmatter block (everything up to and including the
    /// closing `---` line) from `.md` content and returns the remaining lines.
    /// Used by render-format tests that need to inspect segment lines only.
    private static func transcriptLines(in md: String) -> [String] {
        let lines = md.components(separatedBy: "\n")
        // Find the closing --- (second occurrence of ---)
        var dashCount = 0
        var start = 0
        for (i, line) in lines.enumerated() {
            if line == "---" {
                dashCount += 1
                if dashCount == 2 {
                    start = i + 1
                    break
                }
            }
        }
        return lines[start...].filter { !$0.isEmpty }
    }

    static func checkTranscriptWriter(_ s: CheckSuite) async {
        // Each check writes into a unique temp subdir and cleans it up.
        func makeTempDir() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("alembic-writer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        func decodeLines(_ url: URL) throws -> [FinalizedSegmentDTO] {
            let text = try String(contentsOf: url, encoding: .utf8)
            let dec = JSONDecoder()
            return try text.split(separator: "\n", omittingEmptySubsequences: true).map {
                try dec.decode(FinalizedSegmentDTO.self, from: Data($0.utf8))
            }
        }

        await s.checkAsync("TranscriptWriter normal flow: finalized events persist in order") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let writer = try TranscriptWriter(meetingName: "Standup", directory: dir)
            let url = writer.outputURL

            await writer.append(TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1.5, text: "hello"))
            await writer.append(TranscriptEvent(
                kind: .finalized, source: .them, start: 1.5, end: 3.0, text: "world",
                attribution: TranscriptAttribution(source: "asr", confidence: 0.9)))
            let count = await writer.segmentCount
            await writer.close()

            s.expectEqual(count, 2, "two finalized segments persisted")

            let lines = try decodeLines(url)
            s.expectEqual(lines.count, 2, "two JSONL lines on disk")
            s.expectEqual(lines[0].text, "hello", "first line text/order")
            s.expectEqual(lines[0].source, .you, "first line source")
            s.expectEqual(lines[0].start, 0, "first line start")
            s.expectEqual(lines[0].end, 1.5, "first line end")
            s.expect(lines[0].attribution == nil, "first line has no attribution")
            s.expectEqual(lines[1].text, "world", "second line text/order")
            s.expectEqual(lines[1].source, .them, "second line source")
            s.expectEqual(lines[1].attribution?.source, "asr", "second line attribution source")
            s.expectEqual(lines[1].attribution?.confidence, 0.9, "second line attribution confidence")
            s.expectEqual(lines[1].schemaVersion, FinalizedSegmentDTO.currentSchemaVersion,
                          "schemaVersion on disk matches current")
            s.expect(url.lastPathComponent.hasSuffix("-Standup.jsonl"), "sanitized meeting name in file path")
        }

        await s.checkAsync("TranscriptWriter skips volatile events") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let writer = try TranscriptWriter(meetingName: "Vol", directory: dir)
            let url = writer.outputURL
            await writer.append(TranscriptEvent(kind: .volatile, source: .you, start: 0, end: 1, text: "partial"))
            await writer.append(TranscriptEvent(kind: .volatile, source: .them, start: 1, end: 2, text: "more"))
            let count = await writer.segmentCount
            await writer.close()

            s.expectEqual(count, 0, "no volatile events persisted")
            let data = try Data(contentsOf: url)
            s.expectEqual(data.count, 0, "canonical file is empty after only-volatile input")
        }

        await s.checkAsync("TranscriptWriter skips empty/whitespace-only text") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let writer = try TranscriptWriter(meetingName: "Empty", directory: dir)
            let url = writer.outputURL
            await writer.append(TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "   "))
            await writer.append(TranscriptEvent(kind: .finalized, source: .you, start: 1, end: 2, text: "\n\t "))
            await writer.append(TranscriptEvent(kind: .finalized, source: .you, start: 2, end: 3, text: "  kept  "))
            let count = await writer.segmentCount
            await writer.close()

            s.expectEqual(count, 1, "only non-empty segment persisted")
            let lines = try decodeLines(url)
            s.expectEqual(lines.count, 1, "one line on disk")
            s.expectEqual(lines[0].text, "kept", "text trimmed before persisting")
        }

        await s.checkAsync("TranscriptWriter crash-safety: flushed lines survive without clean close") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let writer = try TranscriptWriter(meetingName: "Crash", directory: dir)
            let url = writer.outputURL
            let n = 5
            for i in 0..<n {
                await writer.append(TranscriptEvent(
                    kind: .finalized, source: i.isMultiple(of: 2) ? .you : .them,
                    start: Double(i), end: Double(i) + 1, text: "segment \(i)"))
            }
            // Intentionally DO NOT call close() — simulate the process dying
            // after the last flush. Read the file directly via a fresh handle.
            let handle = try FileHandle(forReadingFrom: url)
            let raw = try handle.readToEnd() ?? Data()
            try? handle.close()
            let text = String(decoding: raw, as: UTF8.self)
            let lineSubs = text.split(separator: "\n", omittingEmptySubsequences: true)
            s.expectEqual(lineSubs.count, n, "all flushed lines present despite no clean close")

            let dec = JSONDecoder()
            var decoded: [FinalizedSegmentDTO] = []
            for sub in lineSubs {
                decoded.append(try dec.decode(FinalizedSegmentDTO.self, from: Data(sub.utf8)))
            }
            s.expectEqual(decoded.count, n, "every line parses as a FinalizedSegmentDTO")
            s.expectEqual(decoded.last?.text, "segment \(n - 1)", "final segment present and intact")
            // No half-written trailing line: file ends in a newline.
            s.expect(raw.last == 0x0A, "file ends on a complete (newline-terminated) line")
        }

        await s.checkAsync("TranscriptWriter optional .md render: [hh:mm:ss] source: text") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let writer = try TranscriptWriter(meetingName: "Render", directory: dir, writeReadableRender: true)
            let mdURL = writer.readableURL
            s.expect(mdURL != nil, "readable URL exposed when rendering enabled")
            // start=3661s -> 01:01:01
            await writer.append(TranscriptEvent(kind: .finalized, source: .them, start: 3661, end: 3662, text: "on the hour"))
            await writer.close()

            if let mdURL {
                let md = try String(contentsOf: mdURL, encoding: .utf8)
                // Skip the YAML frontmatter block before asserting segment lines.
                let firstSegmentLine = transcriptLines(in: md).first ?? ""
                s.expectEqual(firstSegmentLine, "[01:01:01] them: on the hour", "readable line format")
                s.expect(mdURL.lastPathComponent.hasSuffix(".md"), "render file uses .md extension")
            }
        }

        await s.checkAsync("TranscriptWriter optional .md render: attributed displayName vs. fallback") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let writer = try TranscriptWriter(meetingName: "Attributed", directory: dir, writeReadableRender: true)
            let mdURL = writer.readableURL
            s.expect(mdURL != nil, "readable URL exposed when rendering enabled")

            // Named: attribution.displayName present -> "<name> (<source>): text".
            await writer.append(TranscriptEvent(
                kind: .finalized, source: .them, start: 3661, end: 3662, text: "on the hour",
                attribution: TranscriptAttribution(source: "vision", confidence: 0.9, displayName: "Alex Kim")))
            // Unnamed: no attribution at all -> today's plain "source: text" (no regression).
            await writer.append(TranscriptEvent(kind: .finalized, source: .you, start: 3663, end: 3664, text: "plain"))
            // Unnamed: attribution present but no displayName -> same plain fallback.
            await writer.append(TranscriptEvent(
                kind: .finalized, source: .them, start: 3665, end: 3666, text: "no name",
                attribution: TranscriptAttribution(source: "asr", confidence: 0.5)))
            await writer.close()

            if let mdURL {
                let md = try String(contentsOf: mdURL, encoding: .utf8)
                let lines = transcriptLines(in: md)
                s.expectEqual(lines.count, 3, "three segment lines rendered")
                s.expectEqual(lines[0], "[01:01:01] Alex Kim (them): on the hour",
                              "named readable line: <name> (<source>): text")
                s.expectEqual(lines[1], "[01:01:03] you: plain",
                              "unattributed readable line unchanged: source: text")
                s.expectEqual(lines[2], "[01:01:05] them: no name",
                              "attribution without displayName falls back to source: text")
            }
        }

        await s.checkAsync("TranscriptWriter context init: frontmatter in .md, hyphen-collapsed filename") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let date = Date(timeIntervalSince1970: 1_748_951_400) // 2025-06-03T12:30:00Z
            let ctx = MeetingContext(
                windowTitle: "CI Agent - DSU",
                appDisplayName: "Microsoft Teams",
                bundleID: "com.microsoft.teams2",
                localeIdentifier: "en-US",
                startDate: date
            )
            let writer = try TranscriptWriter(context: ctx, directory: dir, writeReadableRender: true)

            // File name must use the sanitized, hyphen-collapsed title.
            s.expect(writer.outputURL.lastPathComponent.hasSuffix("-CI-Agent-DSU.jsonl"),
                     "hyphen-collapsed title in .jsonl filename: \(writer.outputURL.lastPathComponent)")
            s.expect(writer.readableURL?.lastPathComponent.hasSuffix("-CI-Agent-DSU.md") == true,
                     "hyphen-collapsed title in .md filename")

            // .md must open with frontmatter block.
            if let mdURL = writer.readableURL {
                let md = try String(contentsOf: mdURL, encoding: .utf8)
                s.expect(md.hasPrefix("---\n"), ".md starts with ---")
                s.expect(md.contains("title:"), ".md frontmatter contains title key")
                s.expect(md.contains("startTime:"), ".md frontmatter contains startTime key")
            }
            await writer.close()
        }

        await s.checkAsync("TranscriptWriter context init: empty nameForFile → stamp-only filename") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let date = Date(timeIntervalSince1970: 1_748_951_400) // 2025-06-03T12:30:00Z
            let ctx = MeetingContext(startDate: date)   // both windowTitle and appDisplayName nil
            let writer = try TranscriptWriter(context: ctx, directory: dir)
            // Filename must be stamp-only (no trailing hyphen).
            let name = writer.outputURL.lastPathComponent
            s.expect(!name.contains("-.jsonl"), "no trailing hyphen before extension: \(name)")
            s.expect(name.hasSuffix(".jsonl"), ".jsonl extension present")
            await writer.close()
        }

        await s.checkAsync("TranscriptWriter default directory is ~/Documents/Alembic") { s in
            let expected = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Alembic", isDirectory: true)
                .standardizedFileURL
            s.expectEqual(TranscriptWriter.defaultDirectory.standardizedFileURL, expected,
                          "default output directory resolves under ~/Documents/Alembic")
        }
    }

    // MARK: - Phase 6: MeetingSession orchestrator & state machine

    static func checkMeetingSession(_ s: CheckSuite) async {
        // --- shared helpers ---------------------------------------------------
        func makeTempDir() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("alembic-session-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        func decodeLines(_ url: URL) throws -> [FinalizedSegmentDTO] {
            let text = try String(contentsOf: url, encoding: .utf8)
            let dec = JSONDecoder()
            return try text.split(separator: "\n", omittingEmptySubsequences: true).map {
                try dec.decode(FinalizedSegmentDTO.self, from: Data($0.utf8))
            }
        }
        func label(_ st: SessionState) -> String {
            switch st {
            case .idle: return "idle"
            case .selecting: return "selecting"
            case .recording: return "recording"
            case .finalizing: return "finalizing"
            case .saved: return "saved"
            case .error: return "error"
            case .discarded: return "discarded"
            }
        }
        func chunk(_ source: SourceTag, _ start: Double) -> AudioChunk {
            AudioChunk(samples: [0.1, 0.2], sampleRate: 48_000, channelCount: 1, source: source, startTime: start)
        }
        func makeWriterFactory(_ dir: URL) -> @Sendable () throws -> TranscriptWriter {
            { try TranscriptWriter(meetingName: "Session", directory: dir) }
        }
        // Deterministic replacement for a wall-clock sleep/"head start" guess:
        // several Phase 3 checks below construct a `.you` engine with
        // `emitOnStart: true` and a `.them` engine with `emitOnStart: false`
        // (held back until `stop()`'s drain), specifically so the `.you`
        // segment's ingestion-chain link is captured — and therefore its
        // position in the persisted `.jsonl`'s single, session-wide FIFO
        // write order is pinned — strictly before the `.them` engine's
        // events even exist. Giving `.you` a mere *temporal* head start
        // (constructing it first, then immediately calling `stop()`) is not
        // by itself a hard guarantee: nothing forces the `.you` result task
        // to actually be scheduled and reach `ingest`'s synchronous capture
        // line before the test proceeds to `stop()` (confirmed empirically —
        // this raced under scheduler pressure roughly 1 run in 20 without
        // this wait). Spinning on `finalizedTranscript.isEmpty` — a
        // cooperative `Task.yield()` loop, not a timed sleep — blocks the
        // calling task only until the `.you` chain link has actually reached
        // `insertFinalized`, which can only happen *after* its capture line
        // already ran; calling `stop()` only once this returns therefore
        // guarantees the `.you` capture strictly precedes any possible
        // `.them` capture, deterministically, on every run.
        // Phase 7 §3c fix (Phase 3 impl-review-1 MEDIUM finding): bounded via
        // the shared `waitUntil(timeout:poll:)` helper instead of looping
        // unconditionally — a genuine regression in session start/`ingest`
        // now makes this return `false` within `timeout` instead of hanging
        // `AlembicCheck` forever. Every call site below asserts the returned
        // `Bool` with `s.expect(...)`.
        func waitForFirstFinalizedEvent(_ session: MeetingSession, timeout: Duration = .seconds(5)) async -> Bool {
            await waitUntil(timeout: timeout) {
                await MainActor.run { !session.finalizedTranscript.isEmpty }
            }
        }

        // --- 1. State transitions --------------------------------------------
        await s.checkAsync("MeetingSession state machine: idle → selecting → recording → finalizing → saved") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let you = FakeTranscriptionEngine(
                script: [TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "hi")],
                emitOnStart: false)
            let them = FakeTranscriptionEngine(
                script: [TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "yo")],
                emitOnStart: false)
            let source = FakeAudioSource(script: [chunk(.you, 0), chunk(.them, 1)], finishAfterScript: true)
            let make = makeWriterFactory(dir)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make)
            }

            let initial = await session.state
            s.expectEqual(label(initial), "idle", "starts idle")

            await session.loadTargets()
            s.expectEqual(label(await session.state), "selecting", "after loadTargets → selecting")

            let target = await session.availableTargets.first!
            await session.start(target: target)
            s.expectEqual(label(await session.state), "recording", "after start → recording")

            await session.stop()
            s.expectEqual(label(await session.state), "saved", "after stop → saved")

            let history = (await session.stateHistory).map(label)
            s.expectEqual(history, ["idle", "selecting", "recording", "finalizing", "saved"],
                          "exact transition order observed")
        }

        // --- 2. Drain ordering / no lost finalized text ----------------------
        await s.checkAsync("MeetingSession drain: held finalized text survives stop and is fully written") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // emitOnStart:false → engines release finalized text ONLY on finish().
            let you = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "alpha"),
                TranscriptEvent(kind: .finalized, source: .you, start: 2, end: 3, text: "gamma"),
            ], emitOnStart: false)
            let them = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "beta"),
            ], emitOnStart: false)
            let source = FakeAudioSource(script: [chunk(.you, 0)], finishAfterScript: true)
            let make = makeWriterFactory(dir)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make)
            }
            await session.loadTargets()
            let target = await session.availableTargets.first!
            await session.start(target: target)
            await session.stop()

            let finalized = await session.finalizedTranscript
            s.expectEqual(finalized.count, 3, "all 3 held finalized events present in memory")

            guard case let .saved(url) = await session.state else {
                s.expect(false, "session reached .saved with a URL"); return
            }
            let lines = try decodeLines(url)
            s.expectEqual(lines.count, 3, "writer persisted exactly the finalized events (closed AFTER drain)")
            s.expectEqual(Set(lines.map(\.text)), ["alpha", "beta", "gamma"], "no finalized text lost on stop")
        }

        // --- 3. Source-merge ordering ----------------------------------------
        await s.checkAsync("MeetingSession merges both sources onto one timeline ordered by session-clock start") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let you = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "u0"),
                TranscriptEvent(kind: .finalized, source: .you, start: 2, end: 3, text: "u2"),
            ], emitOnStart: false)
            let them = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "t1"),
                TranscriptEvent(kind: .finalized, source: .them, start: 3, end: 4, text: "t3"),
            ], emitOnStart: false)
            let source = FakeAudioSource(script: [chunk(.you, 0)], finishAfterScript: true)
            let make = makeWriterFactory(dir)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make)
            }
            await session.loadTargets()
            await session.start(target: await session.availableTargets.first!)
            await session.stop()

            let merged = await session.finalizedTranscript
            s.expectEqual(merged.map(\.text), ["u0", "t1", "u2", "t3"],
                          "interleaved sources sorted by session-clock start")
            s.expectEqual(merged.map(\.start), [0, 1, 2, 3], "starts strictly increasing on the merged timeline")
        }

        // --- 3b. Source-merge tie-break --------------------------------------
        await s.checkAsync("MeetingSession merge tie-break: equal start orders you before them") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let you = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .you, start: 5, end: 6, text: "you-line"),
            ], emitOnStart: false)
            let them = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .them, start: 5, end: 6, text: "them-line"),
            ], emitOnStart: false)
            let source = FakeAudioSource(script: [chunk(.you, 0)], finishAfterScript: true)
            let make = makeWriterFactory(dir)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make)
            }
            await session.loadTargets()
            await session.start(target: await session.availableTargets.first!)
            await session.stop()

            let merged = await session.finalizedTranscript
            s.expectEqual(merged.map(\.source), [.you, .them], "equal start → you precedes them")
        }

        // --- 4. Routing -------------------------------------------------------
        await s.checkAsync("MeetingSession routes buffers to the engine matching chunk.source") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let you = FakeTranscriptionEngine(script: [], emitOnStart: true)
            let them = FakeTranscriptionEngine(script: [], emitOnStart: true)
            // 2 chunks for you, 3 for them, interleaved.
            let source = FakeAudioSource(script: [
                chunk(.you, 0), chunk(.them, 0), chunk(.them, 1), chunk(.you, 2), chunk(.them, 3),
            ], finishAfterScript: true)
            let make = makeWriterFactory(dir)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make)
            }
            await session.loadTargets()
            await session.start(target: await session.availableTargets.first!)
            await session.stop()

            let youChunks = await you.appendedChunks
            let themChunks = await them.appendedChunks
            s.expectEqual(youChunks.count, 2, "two chunks routed to the you engine")
            s.expectEqual(themChunks.count, 3, "three chunks routed to the them engine")
            s.expect(youChunks.allSatisfy { $0.source == .you }, "you engine only got .you chunks")
            s.expect(themChunks.allSatisfy { $0.source == .them }, "them engine only got .them chunks")
        }

        // --- 5. Error path ----------------------------------------------------
        await s.checkAsync("MeetingSession surfaces a source error and still closes the writer (partial survives)") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // Pre-load an out-of-band capture error.
            let (errors, errorCont) = AsyncStream<String>.makeStream()
            errorCont.yield("stream stopped: simulated capture failure")
            errorCont.finish()

            let you = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "partial you"),
            ], emitOnStart: true)
            let them = FakeTranscriptionEngine(script: [], emitOnStart: true)
            // Stay "recording" (do not finish buffers automatically).
            let source = FakeAudioSource(script: [chunk(.you, 0)], finishAfterScript: false)
            let make = makeWriterFactory(dir)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make,
                    sourceErrors: errors)
            }
            await session.loadTargets()
            await session.start(target: await session.availableTargets.first!)

            // Deterministically wait for the error to drive a terminal state.
            await session.waitUntilFinished()

            guard case let .error(msg) = await session.state else {
                s.expect(false, "session reached .error after a source failure"); return
            }
            s.expect(msg.contains("simulated capture failure"), "error message surfaces the underlying cause")

            // The writer must have been flushed/closed so the file is parseable.
            let url = await session.outputURL
            s.expect(url != nil, "writer was created before the failure")
            if let url {
                // No throw == every persisted line is a valid FinalizedSegmentDTO.
                let lines = try decodeLines(url)
                s.expect(lines.count >= 0, "partial transcript on disk is fully parseable (\(lines.count) line(s))")
            }
        }

        // --- Silent-session discard (auto-start false-positive safety net) ---
        await s.checkAsync("MeetingSession discard: silent session self-destructs and deletes its files") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // "you" speech only — a false positive can still catch the user
            // talking to themselves; far-end silence is what matters.
            let you = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "hello?"),
            ], emitOnStart: true)
            let them = FakeTranscriptionEngine(script: [], emitOnStart: true)
            let source = FakeAudioSource(script: [chunk(.you, 0)], finishAfterScript: false)
            let make = makeWriterFactory(dir)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make)
            }
            await session.loadTargets()
            await session.start(target: await session.availableTargets.first!, discardIfSilentAfter: 0.2)

            await session.waitUntilFinished()

            guard case .discarded = await session.state else {
                s.expect(false, "silent session reached .discarded"); return
            }
            s.expect(await session.outputURL == nil, "outputURL cleared after discard")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            s.expect(leftovers.isEmpty, "transcript files deleted (found: \(leftovers))")
        }

        await s.checkAsync("MeetingSession discard: far-end speech vetoes the watchdog") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let you = FakeTranscriptionEngine(script: [], emitOnStart: true)
            let them = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .them, start: 0, end: 1, text: "welcome"),
            ], emitOnStart: true)
            let source = FakeAudioSource(script: [chunk(.them, 0)], finishAfterScript: false)
            let make = makeWriterFactory(dir)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make)
            }
            await session.loadTargets()
            await session.start(target: await session.availableTargets.first!, discardIfSilentAfter: 0.2)

            // Give the watchdog time to fire (and correctly do nothing).
            try await Task.sleep(for: .milliseconds(600))
            s.expectEqual(label(await session.state), "recording", "session with far-end speech keeps recording")

            await session.stop()
            guard case let .saved(url) = await session.state else {
                s.expect(false, "session saved normally"); return
            }
            s.expect(FileManager.default.fileExists(atPath: url.path), "transcript file kept")
        }

        await s.checkAsync("MeetingSession discard: them-speech landing during the drain rescues the file") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // emitOnStart:false → the "them" event is released only by
            // finish(), i.e. mid-drain, after the watchdog decided to discard.
            let you = FakeTranscriptionEngine(script: [], emitOnStart: false)
            let them = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .them, start: 0, end: 1, text: "late arrival"),
            ], emitOnStart: false)
            let source = FakeAudioSource(script: [chunk(.them, 0)], finishAfterScript: false)
            let make = makeWriterFactory(dir)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make)
            }
            await session.loadTargets()
            await session.start(target: await session.availableTargets.first!, discardIfSilentAfter: 0.2)

            await session.waitUntilFinished()

            guard case let .saved(url) = await session.state else {
                s.expect(false, "in-flight far-end speech → .saved, not .discarded"); return
            }
            s.expect(FileManager.default.fileExists(atPath: url.path), "rescued transcript kept on disk")
            let lines = try decodeLines(url)
            s.expectEqual(lines.count, 1, "the rescued far-end line was written")
        }

        // --- Phase 3: FakeAttributionProvider end-to-end wiring (§2.1–§2.6) ---

        await s.checkAsync("MeetingSession + FakeAttributionProvider: attributes finalized .them end-to-end; .you/volatile untouched") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // .you and .them each emit one finalized event plus one volatile
            // hypothesis that is superseded before finish() — the volatile
            // line must never reach the provider (SR-15) regardless of source.
            let you = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .volatile, source: .you, start: 0, end: 0.5, text: "h"),
                TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "hello"),
            ], emitOnStart: false)
            let them = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .volatile, source: .them, start: 1, end: 1.5, text: "h"),
                TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "hi there"),
                TranscriptEvent(kind: .finalized, source: .them, start: 2, end: 3, text: "unscripted window"),
            ], emitOnStart: false)
            let source = FakeAudioSource(script: [chunk(.you, 0), chunk(.them, 1)], finishAfterScript: true)
            let make = makeWriterFactory(dir)

            let scriptedWindow: ClosedRange<Double> = 1...2
            let provider = FakeAttributionProvider(
                script: [scriptedWindow: SpeakerAttributionResult(displayName: "Alex Kim", confidence: 0.87)],
                defaultResult: nil // the 2...3 window is intentionally unscripted → nil (NR-6 default path)
            )

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: make,
                    attributionProvider: provider)
            }
            await session.loadTargets()
            let target = await session.availableTargets.first!
            await session.start(target: target)
            await session.stop()

            // 1. In-memory merged timeline: the scripted .them segment carries
            //    the attribution; the unscripted .them segment and the .you
            //    segment do not.
            let finalized = await session.finalizedTranscript
            let attributedThem = finalized.first { $0.source == .them && $0.start == 1 }
            s.expectEqual(attributedThem?.attribution?.source, "vision", "scripted .them segment attributed with source vision")
            s.expectEqual(attributedThem?.attribution?.displayName, "Alex Kim", "scripted .them segment carries the resolved name")
            s.expectEqual(attributedThem?.attribution?.confidence, 0.87, "scripted .them segment carries the resolved confidence")

            let unscriptedThem = finalized.first { $0.source == .them && $0.start == 2 }
            s.expect(unscriptedThem?.attribution == nil, "unscripted .them window (provider nil default) stays unattributed")

            let youEvent = finalized.first { $0.source == .you }
            s.expect(youEvent?.attribution == nil, ".you finalized event is never attributed")

            // 2. Provider query log: exactly the two finalized .them windows,
            //    in finalization order, and nothing else — proves SR-15's
            //    ".you/volatile never queried" and gives an exact, ordered
            //    count assertion rather than a loose "was called" check.
            let queried = await provider.queriedWindows
            s.expectEqual(queried, [1...2, 2...3], "provider queried exactly the two finalized .them windows, in order, and nothing else")

            // 3. End-to-end through the writer: decode the actual .jsonl and
            //    assert on the persisted DTOs, not just in-memory state —
            //    proves attribution landed before writer.append (SR-14's
            //    literal ordering) and survived encode/decode (DR-1/DR-3).
            guard case .saved(let url) = await session.state else {
                s.expect(false, "session did not reach .saved"); return
            }
            let persisted = try decodeLines(url)
            s.expectEqual(persisted.count, 3, "all three finalized segments persisted — attribution never drops a segment")
            let persistedThem1 = persisted.first { $0.source == .them && $0.start == 1 }
            s.expectEqual(persistedThem1?.attribution?.displayName, "Alex Kim", "attribution round-trips through the canonical .jsonl")
            let persistedThem2 = persisted.first { $0.source == .them && $0.start == 2 }
            s.expect(persistedThem2?.attribution == nil, "unscripted-window segment persists exactly as it does today (plain them)")
            let persistedYou = persisted.first { $0.source == .you }
            s.expect(persistedYou?.attribution == nil, ".you segment persists unattributed")
        }

        await s.checkAsync("MeetingSession + FakeAttributionProvider: failure/non-finite degrades to the no-provider baseline, never drops a segment") { s in
            // .you uses emitOnStart:true (immediate emission) while .them uses
            // emitOnStart:false (held until drain's finish()). This is
            // deliberate, not incidental: with *both* engines emitOnStart:false,
            // their events are released at the same drain phase and two
            // independent per-engine result-consumption tasks would genuinely
            // race for MainActor scheduling, making the relative persisted
            // order of the .you segment vs the .them segments nondeterministic
            // across runs (confirmed empirically) — which would make the raw
            // byte-parity assertions below flaky through no fault of the
            // attribution logic under test. Giving .you a temporal head start
            // (ingested and written during `start()`, long before `stop()`'s
            // drain even reaches `them.finish()`) pins the .you segment
            // deterministically first, in every session constructed by this
            // helper — baseline and every failure-case session alike — so the
            // byte comparison exercises only the attribution behavior, not an
            // unrelated cross-engine scheduling race.
            func script() -> (you: FakeTranscriptionEngine, them: FakeTranscriptionEngine, source: FakeAudioSource) {
                (
                    FakeTranscriptionEngine(script: [
                        TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "hello"),
                    ], emitOnStart: true),
                    FakeTranscriptionEngine(script: [
                        TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "hi there"),
                        TranscriptEvent(kind: .finalized, source: .them, start: 2, end: 3, text: "still here"),
                    ], emitOnStart: false),
                    FakeAudioSource(script: [chunk(.you, 0), chunk(.them, 1)], finishAfterScript: true)
                )
            }

            // --- baseline: no provider at all ---
            let baseDir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: baseDir) }
            let (baseYou, baseThem, baseSource) = script()
            let baseSession = await MainActor.run {
                MeetingSession(audioSource: baseSource, engineFactory: { tag, _ in tag == .you ? baseYou : baseThem },
                               makeWriter: makeWriterFactory(baseDir))
            }
            await baseSession.loadTargets()
            await baseSession.start(target: baseSession.availableTargets.first!)
            // Deterministic barrier (see `waitForFirstFinalizedEvent`'s doc
            // comment above) — pins the .you-before-.them persisted order.
            s.expect(
                await waitForFirstFinalizedEvent(baseSession),
                "baseSession: first finalized event observed within the bounded barrier timeout"
            )
            await baseSession.stop()
            guard case .saved(let baseURL) = await baseSession.state else {
                s.expect(false, "baseline session did not save"); return
            }
            let baselineBytes = try Data(contentsOf: baseURL)
            let baseline = try decodeLines(baseURL)

            // --- one session per failure mode, each compared against the same baseline ---
            struct FailureCase { let name: String; let provider: FakeAttributionProvider }
            let cases: [FailureCase] = [
                FailureCase(name: "always nil", provider: FakeAttributionProvider(defaultResult: nil)),
                FailureCase(name: "non-finite confidence (NaN)",
                            provider: FakeAttributionProvider(defaultResult: SpeakerAttributionResult(displayName: "X", confidence: .nan))),
                FailureCase(name: "non-finite confidence (+infinity)",
                            provider: FakeAttributionProvider(defaultResult: SpeakerAttributionResult(displayName: "X", confidence: .infinity))),
            ]
            // Note on the non-finite cases: `SpeakerAttributionResult.init`
            // clamps `.nan`/`.infinity` confidence to `0` at construction, so
            // these providers hand `MeetingSession.attributed(_:)` a result
            // with `confidence == 0`. Per the zero-confidence contract,
            // `attributed(_:)` requires `confidence > 0` in addition to
            // `isFinite`/in-range before persisting an attribution, so a
            // `0`-confidence result still degrades to "unattributed" — these
            // cases exercise that guard directly.

            for testCase in cases {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let (you, them, source) = script()
                let session = await MainActor.run {
                    MeetingSession(audioSource: source, engineFactory: { tag, _ in tag == .you ? you : them },
                                   makeWriter: makeWriterFactory(dir), attributionProvider: testCase.provider)
                }
                await session.loadTargets()
                await session.start(target: session.availableTargets.first!)
                // Deterministic barrier (see `waitForFirstFinalizedEvent`'s
                // doc comment above) — pins the .you-before-.them persisted
                // order so this loop's byte comparison against `baseline`
                // isn't a cross-engine scheduling race.
                s.expect(
                    await waitForFirstFinalizedEvent(session),
                    "session: first finalized event observed within the bounded barrier timeout"
                )
                await session.stop()
                guard case .saved(let url) = await session.state else {
                    s.expect(false, "\(testCase.name): session did not save"); return
                }
                let persistedBytes = try Data(contentsOf: url)
                let persisted = try decodeLines(url)

                s.expectEqual(persisted.count, baseline.count, "\(testCase.name): same segment count as no-provider baseline")
                s.expectEqual(persisted.map(\.start), baseline.map(\.start), "\(testCase.name): same ordering as baseline")
                s.expect(persisted.allSatisfy { $0.attribution == nil }, "\(testCase.name): no segment carries attribution")
                s.expectEqual(persistedBytes, baselineBytes, "\(testCase.name): raw .jsonl bytes are byte-identical to the no-provider baseline")
            }
        }

        // Readable (`.md`) render parity: every check above uses
        // `makeWriterFactory`'s default `writeReadableRender: false`, so it
        // only ever exercises canonical `.jsonl` parity. AC-6 says a
        // failure/timeout must produce a transcript identical to the
        // no-attribution baseline, and Phase 1 made the `.md` readable
        // render part of that transcript output — so this case covers it
        // too. A **fixed `Date`** is injected into both writer factories
        // (resolves phase-3-plan-review-4 MEDIUM finding): `TranscriptWriter`
        // stamps `MeetingContext.startDate` (via its `.md` YAML frontmatter's
        // `startTime` field) from the ambient `Date()` default otherwise, so
        // two independently-constructed writer instances could observe
        // different ISO8601 seconds if construction happened to straddle a
        // second boundary — an intermittent, non-attribution-related raw
        // `.md` byte-parity failure. Fixing the date removes that source of
        // flakiness entirely.
        await s.checkAsync("MeetingSession + FakeAttributionProvider: failure degrades to the no-provider baseline in the readable .md render too") { s in
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            func makeReadableWriterFactory(_ dir: URL) -> @Sendable () throws -> TranscriptWriter {
                { try TranscriptWriter(meetingName: "Session", directory: dir, date: fixedDate, writeReadableRender: true) }
            }
            // .you uses emitOnStart:true (immediate emission) while .them uses
            // emitOnStart:false (held until drain's finish()). This is
            // deliberate, not incidental: with *both* engines emitOnStart:false,
            // their events are released at the same drain phase and two
            // independent per-engine result-consumption tasks would genuinely
            // race for MainActor scheduling, making the relative persisted
            // order of the .you segment vs the .them segments nondeterministic
            // across runs (confirmed empirically) — which would make the raw
            // byte-parity assertions below flaky through no fault of the
            // attribution logic under test. Giving .you a temporal head start
            // (ingested and written during `start()`, long before `stop()`'s
            // drain even reaches `them.finish()`) pins the .you segment
            // deterministically first, in every session constructed by this
            // helper — baseline and every failure-case session alike — so the
            // byte comparison exercises only the attribution behavior, not an
            // unrelated cross-engine scheduling race.
            func script() -> (you: FakeTranscriptionEngine, them: FakeTranscriptionEngine, source: FakeAudioSource) {
                (
                    FakeTranscriptionEngine(script: [
                        TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "hello"),
                    ], emitOnStart: true),
                    FakeTranscriptionEngine(script: [
                        TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "hi there"),
                        TranscriptEvent(kind: .finalized, source: .them, start: 2, end: 3, text: "still here"),
                    ], emitOnStart: false),
                    FakeAudioSource(script: [chunk(.you, 0), chunk(.them, 1)], finishAfterScript: true)
                )
            }

            let baseDir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: baseDir) }
            let (baseYou, baseThem, baseSource) = script()
            let baseSession = await MainActor.run {
                MeetingSession(audioSource: baseSource, engineFactory: { tag, _ in tag == .you ? baseYou : baseThem },
                               makeWriter: makeReadableWriterFactory(baseDir))
            }
            await baseSession.loadTargets()
            await baseSession.start(target: baseSession.availableTargets.first!)
            // Deterministic barrier (see `waitForFirstFinalizedEvent`'s doc
            // comment above) — pins the .you-before-.them persisted order.
            s.expect(
                await waitForFirstFinalizedEvent(baseSession),
                "baseSession: first finalized event observed within the bounded barrier timeout"
            )
            await baseSession.stop()
            guard case .saved = await baseSession.state, let baseMDURL = await baseSession.readableURL else {
                s.expect(false, "baseline session did not save a readable render"); return
            }
            let baselineMDBytes = try Data(contentsOf: baseMDURL)

            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let (you, them, source) = script()
            let provider = FakeAttributionProvider(defaultResult: nil)
            let session = await MainActor.run {
                MeetingSession(audioSource: source, engineFactory: { tag, _ in tag == .you ? you : them },
                               makeWriter: makeReadableWriterFactory(dir), attributionProvider: provider)
            }
            await session.loadTargets()
            await session.start(target: session.availableTargets.first!)
            // Deterministic barrier (see `waitForFirstFinalizedEvent`'s doc
            // comment above) — pins the .you-before-.them persisted order.
            s.expect(
                await waitForFirstFinalizedEvent(session),
                "session: first finalized event observed within the bounded barrier timeout"
            )
            await session.stop()
            guard case .saved = await session.state, let mdURL = await session.readableURL else {
                s.expect(false, "failure-mode session did not save a readable render"); return
            }
            let mdBytes = try Data(contentsOf: mdURL)
            s.expectEqual(mdBytes, baselineMDBytes, "readable .md render is byte-identical to the no-provider baseline when attribution fails (AC-6 extended to the readable render, not only canonical .jsonl)")
        }

        // FIFO ingestion ordering under MainActor reentrancy. Proves the
        // `ingest(_:)` FIFO chain: a delayed attribution query for one
        // finalized `.them` event must not let a later finalized event's
        // insert/write run ahead of it, either in the in-memory timeline or
        // the persisted `.jsonl`.
        //
        // **Independently-consumed `.you`/`.them` streams (resolves
        // phase-3-plan-review-4 MEDIUM finding):** `MeetingSession` runs one
        // result-consumption task per engine, and that loop only calls
        // `ingest` for its *next* event once the previous `ingest` call (and
        // its FIFO chain link) has fully returned. Two events emitted by the
        // *same* engine are therefore already serialized by that single
        // result task regardless of the FIFO chain's correctness — racing two
        // `.them` events against each other would pass even a version of
        // `MeetingSession` with no FIFO chain at all, making the check
        // vacuous. Using one event from `.them` (queried, deliberately slow)
        // and one from `.you` (never queried, arrives on its own independent
        // result task) genuinely exercises MainActor reentrancy: while the
        // `.them` result task is suspended inside `ingest` awaiting the slow
        // query, the `.you` result task can — and, absent the FIFO chain,
        // would — race its own `ingest` call ahead on the MainActor.
        await s.checkAsync("MeetingSession + FakeAttributionProvider: a delayed .them attribution query does not let an independently-consumed .you event's write run ahead of it (FIFO ingestion chain)") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // emitOnStart:true → the .them engine's finalized event is
            // ingested essentially immediately once consumption tasks start,
            // well before drain — so its slow (300ms) attribution query is
            // guaranteed to still be in flight when the .you event is
            // released during drain, below.
            let them = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "first, slow to attribute"),
            ], emitOnStart: true)
            // emitOnStart:false → the .you engine holds its event back until
            // finish() (i.e. during stop()'s drain), by which point the
            // .them event's ingest call is already deep inside its 300ms
            // attribution query.
            let you = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .you, start: 2, end: 3, text: "second, never attributed"),
            ], emitOnStart: false)
            let source = FakeAudioSource(script: [chunk(.you, 0), chunk(.them, 1)], finishAfterScript: true)

            // Delays the (only) query it ever receives — the single .them
            // event's — by 300ms, comfortably inside the 2s production
            // `attributionQueryTimeout` so this is a genuine "slow but
            // eventually-succeeding" query, not a timeout.
            let provider = SlowAttributionProvider(firstQueryDelay: .milliseconds(300))

            let session = await MainActor.run {
                MeetingSession(audioSource: source, engineFactory: { tag, _ in tag == .you ? you : them },
                               makeWriter: makeWriterFactory(dir), attributionProvider: provider)
            }
            await session.loadTargets()
            await session.start(target: session.availableTargets.first!)
            // Deterministic replacement for relying on a mere temporal head
            // start: suspend until the .them event's ingestion-chain link
            // has genuinely reached `boundedAttribution` and invoked the
            // provider (registering its capture in the session-wide FIFO
            // chain) *before* triggering the drain that releases the .you
            // engine's held-back event. Without this explicit barrier nothing
            // guarantees the .them capture actually runs before .you's data
            // even exists — confirmed empirically to occasionally race
            // otherwise, exactly like the analogous fix documented on
            // `waitForFirstFinalizedEvent`, above.
            s.expect(
                await provider.waitUntilFirstQueryStarted(),
                "provider: first (slow) query observed within the bounded barrier timeout"
            )
            await session.stop()

            // 1. Persisted order: the raw `.jsonl` must reflect ingest-call
            //    order (the .them event started ingestion first) despite its
            //    slower attribution query — this is the concrete SR-16
            //    guarantee ("failed/timed-out attribution must not reorder
            //    segments") extended to "attribution that merely resolves
            //    slowly must not reorder segments" either.
            guard case .saved(let url) = await session.state else {
                s.expect(false, "session did not save"); return
            }
            let persisted = try decodeLines(url)
            s.expectEqual(persisted.map(\.start), [1, 2], "persisted .jsonl preserves ingest-call order despite the .them event's slower attribution query")
            s.expectEqual(persisted.first?.attribution?.displayName, "slow", "the delayed-but-successful .them query's attribution still lands on the correct (first) segment")
            s.expect(persisted.last?.attribution == nil, "the .you segment (never queried, SR-15) still lands second, not ahead of the slower .them segment")

            // 2. In-memory merged timeline is sorted by session-clock start
            //    regardless of ingest order (an independent, pre-existing
            //    invariant) — still asserted here as a sanity check that
            //    nothing was dropped.
            let finalized = await session.finalizedTranscript
            s.expectEqual(finalized.map(\.start), [1, 2], "in-memory finalizedTranscript contains both segments in session-clock order")
        }

        // Bounded timeout and circuit breaker, against both a cooperative and
        // a genuinely non-cooperative provider.
        await s.checkAsync("MeetingSession + FakeAttributionProvider: cooperative and non-cooperative hangs both stay within the SR-17 timeout bound, and the circuit breaker limits each session to at most one query after the first timeout") { s in
            // .you uses emitOnStart:true (immediate emission) while .them uses
            // emitOnStart:false (held until drain's finish()). This is
            // deliberate, not incidental: with *both* engines emitOnStart:false,
            // their events are released at the same drain phase and two
            // independent per-engine result-consumption tasks would genuinely
            // race for MainActor scheduling, making the relative persisted
            // order of the .you segment vs the .them segments nondeterministic
            // across runs (confirmed empirically) — which would make the raw
            // byte-parity assertions below flaky through no fault of the
            // attribution logic under test. Giving .you a temporal head start
            // (ingested and written during `start()`, long before `stop()`'s
            // drain even reaches `them.finish()`) pins the .you segment
            // deterministically first, in every session constructed by this
            // helper — baseline and every failure-case session alike — so the
            // byte comparison exercises only the attribution behavior, not an
            // unrelated cross-engine scheduling race.
            func script() -> (you: FakeTranscriptionEngine, them: FakeTranscriptionEngine, source: FakeAudioSource) {
                (
                    FakeTranscriptionEngine(script: [
                        TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "hello"),
                    ], emitOnStart: true),
                    FakeTranscriptionEngine(script: [
                        TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "hi there"),
                        TranscriptEvent(kind: .finalized, source: .them, start: 2, end: 3, text: "still here"),
                    ], emitOnStart: false),
                    FakeAudioSource(script: [chunk(.you, 0), chunk(.them, 1)], finishAfterScript: true)
                )
            }

            // --- baseline bytes to compare both timeout cases against (no provider) ---
            let baseDir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: baseDir) }
            let (baseYou, baseThem, baseSource) = script()
            let baseSession = await MainActor.run {
                MeetingSession(audioSource: baseSource, engineFactory: { tag, _ in tag == .you ? baseYou : baseThem },
                               makeWriter: makeWriterFactory(baseDir))
            }
            await baseSession.loadTargets()
            await baseSession.start(target: baseSession.availableTargets.first!)
            // Deterministic barrier (see `waitForFirstFinalizedEvent`'s doc
            // comment above) — pins the .you-before-.them persisted order.
            s.expect(
                await waitForFirstFinalizedEvent(baseSession),
                "baseSession: first finalized event observed within the bounded barrier timeout"
            )
            await baseSession.stop()
            guard case .saved(let baseURL) = await baseSession.state else {
                s.expect(false, "baseline session did not save"); return
            }
            let baselineBytes = try Data(contentsOf: baseURL)

            // A short, injected budget so both cases below are deterministic
            // and fast rather than depending on the 2s production default.
            let testTimeout: Duration = .milliseconds(50)
            struct TimeoutCase { let name: String; let provider: any AttributionProvider; let queryCount: @Sendable () -> Int }
            let hanging = HangingAttributionProvider(blockDuration: .milliseconds(400))
            let nonCooperative = NonCooperativeAttributionProvider(blockDuration: .milliseconds(400))
            let cases: [TimeoutCase] = [
                TimeoutCase(name: "cooperative hang (Task.sleep)", provider: hanging, queryCount: { hanging.queryCount }),
                TimeoutCase(name: "non-cooperative hang (blocking DispatchQueue closure, ignores cancellation)",
                            provider: nonCooperative, queryCount: { nonCooperative.queryCount }),
            ]

            // Two finalized .them segments per session, but the circuit
            // breaker means only the *first* ever actually reaches the
            // provider — allow generous headroom above one `testTimeout`
            // (rather than a tight bound) so this assertion is robust to CI
            // scheduling jitter while still failing hard if the mechanism
            // regressed to "unbounded".
            let maxAcceptableWallClock: Duration = testTimeout * 10

            for testCase in cases {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let (you, them, source) = script()
                let session = await MainActor.run {
                    MeetingSession(audioSource: source, engineFactory: { tag, _ in tag == .you ? you : them },
                                   makeWriter: makeWriterFactory(dir), attributionProvider: testCase.provider,
                                   attributionQueryTimeout: testTimeout)
                }
                await session.loadTargets()
                await session.start(target: session.availableTargets.first!)
                // Deterministic barrier (see `waitForFirstFinalizedEvent`'s
                // doc comment above) — pins the .you-before-.them persisted
                // order; measured *before* starting the SR-17 wall-clock
                // assertion below, so it never counts toward `elapsed`.
                s.expect(
                    await waitForFirstFinalizedEvent(session),
                    "session: first finalized event observed within the bounded barrier timeout"
                )

                let clockStart = ContinuousClock.now
                await session.stop() // must still complete within maxAcceptableWallClock — the concrete SR-17 assertion
                let elapsed = ContinuousClock.now - clockStart
                s.expect(elapsed < maxAcceptableWallClock, "\(testCase.name): stop() completed within \(maxAcceptableWallClock), took \(elapsed)")

                guard case .saved(let url) = await session.state else {
                    s.expect(false, "\(testCase.name): session did not save"); return
                }
                let persistedBytes = try Data(contentsOf: url)
                let persisted = try decodeLines(url)
                s.expectEqual(persisted.count, 3, "\(testCase.name): all segments persisted (nothing dropped)")
                s.expect(persisted.allSatisfy { $0.attribution == nil }, "\(testCase.name): no segment carries attribution")
                s.expectEqual(persistedBytes, baselineBytes, "\(testCase.name): raw .jsonl bytes are byte-identical to the no-provider baseline")

                // Circuit-breaker assertion: two finalized .them segments
                // were ingested, but the provider must only ever have been
                // queried once — the first query's timeout trips the fuse
                // and the second segment skips the provider entirely,
                // bounding abandoned work to one provider task per session
                // regardless of how many more finalized .them segments
                // arrive afterward.
                s.expectEqual(testCase.queryCount(), 1, "\(testCase.name): circuit breaker limited the provider to exactly one query across two finalized .them segments")
            }
        }

        // Error teardown while an attribution query is genuinely in flight.
        // Proves the exact race: a source error arrives while a finalized
        // `.them` event's ingestion-chain link is still suspended inside
        // `boundedAttribution`, and the resulting `flushAndClose()` teardown
        // must cancel that link, produce a parseable, byte-identical-to-
        // what-was-actually-persisted-before-the-error partial transcript,
        // and — once the abandoned query is deliberately, explicitly released
        // and allowed to actually "resolve" — must **not** have let it mutate
        // `finalizedTranscript` or write to the (already-closed) writer.
        //
        // No `Task.sleep`-based guessing anywhere in this check:
        // `GatedAttributionProvider`'s `waitUntilQueryStarted()`/`release()`
        // signals replace both "sleep and hope the query started" and "sleep
        // and hope nothing mutated" with deterministic waits.
        await s.checkAsync("MeetingSession: a source error while an attribution query is in flight cancels the ingestion-chain link and never mutates/writes after the abandoned query is deterministically released") { s in
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let provider = GatedAttributionProvider()

            let (errors, errorCont) = AsyncStream<String>.makeStream()
            let you = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "partial you"),
            ], emitOnStart: true)
            let them = FakeTranscriptionEngine(script: [
                TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "in-flight attribution"),
            ], emitOnStart: true)
            // Stay "recording" (do not finish buffers automatically) so the
            // source error, not a normal drain, is what tears the session down.
            let source = FakeAudioSource(script: [chunk(.you, 0), chunk(.them, 1)], finishAfterScript: false)

            let session = await MainActor.run {
                MeetingSession(
                    audioSource: source,
                    engineFactory: { tag, _ in tag == .you ? you : them },
                    makeWriter: makeWriterFactory(dir),
                    sourceErrors: errors,
                    attributionProvider: provider)
            }
            await session.loadTargets()
            await session.start(target: await session.availableTargets.first!)

            // Deterministic replacement for a fixed `Task.sleep`: suspend
            // until the .them event's ingestion-chain link has genuinely
            // reached `boundedAttribution` and invoked the provider, so the
            // error below is *guaranteed* — not merely likely — to race a
            // query that is actually in flight.
            s.expect(
                await provider.waitUntilQueryStarted(),
                "provider: gated query observed within the bounded barrier timeout"
            )
            errorCont.yield("stream stopped: simulated capture failure mid-attribution")
            errorCont.finish()

            // Deterministically wait for the error to drive a terminal
            // state — this must complete promptly; it must NOT block on the
            // still-gated provider query, proving `flushAndClose()` cancels
            // (via `ingestionDisabled`) rather than awaits the in-flight
            // ingestion-chain link.
            let clockStart = ContinuousClock.now
            await session.waitUntilFinished()
            let elapsed = ContinuousClock.now - clockStart
            s.expect(elapsed < .seconds(5), "error teardown completed promptly (\(elapsed)), not blocked on the in-flight attribution query")

            guard case let .error(msg) = await session.state else {
                s.expect(false, "session reached .error after a source failure"); return
            }
            s.expect(msg.contains("simulated capture failure"), "error message surfaces the underlying cause")

            let url = await session.outputURL
            s.expect(url != nil, "writer was created before the failure")
            var persistedCountAtTeardown = 0
            if let url {
                let lines = try decodeLines(url)
                persistedCountAtTeardown = lines.count
                s.expect(lines.allSatisfy { $0.start != 1 || $0.attribution == nil }, "the in-flight .them segment, if persisted at all, carries no attribution (its query was abandoned before resolving)")
            }

            // Only now — after teardown and the post-teardown state/file
            // assertions above have already run — explicitly release the
            // abandoned query and let it actually resolve. The abandoned
            // link's cancellation/terminal-state/`ingestionDisabled` triple
            // guard must still stop it from mutating `finalizedTranscript` or
            // writing to the transcript.
            provider.release()
            // Cooperatively yield the MainActor executor a small, fixed
            // number of times so the released link — if it were ever going
            // to mutate/write — has the opportunity to actually run its
            // remaining `await`s before the assertions below run. This is a
            // bounded scheduling drain, not a wall-clock timing guess: it
            // depends only on the number of already-resumed continuation
            // hops the released link needs to reach its guard, never on how
            // long that takes on any given machine.
            for _ in 0..<20 { await Task.yield() }

            guard case .error = await session.state else {
                s.expect(false, "session state regressed away from .error after releasing the abandoned attribution query — a late mutation path exists"); return
            }
            if let url {
                let linesAfterRelease = try decodeLines(url)
                s.expectEqual(linesAfterRelease.count, persistedCountAtTeardown, "no additional segment was written after releasing the abandoned attribution query — the ingestion-disabled/terminal-state/cancellation guard stopped it")
            }
        }
    }

    // MARK: - Phase 1: app metadata

    static func checkAppInfo(_ s: CheckSuite) {
        s.check("AlembicInfo metadata matches Info.plist") { s in
            s.expectEqual(AlembicInfo.displayName, "Alembic", "displayName")
            s.expectEqual(AlembicInfo.bundleIdentifier, "com.alembic.app", "bundleIdentifier")
        }
    }

    // MARK: - Phase 2: platform-agnostic core models

    static func checkCoreModels(_ s: CheckSuite) {
        s.check("SourceTag raw values and JSON round-trip") { s in
            s.expectEqual(SourceTag.you.rawValue, "you", "you raw value")
            s.expectEqual(SourceTag.them.rawValue, "them", "them raw value")
            let data = try JSONEncoder().encode(SourceTag.them)
            let decoded = try JSONDecoder().decode(SourceTag.self, from: data)
            s.expectEqual(decoded, .them, "SourceTag round-trip")
        }

        s.check("AudioChunk duration and endTime") { s in
            let chunk = AudioChunk(
                samples: [Float](repeating: 0, count: 48_000),
                sampleRate: 48_000,
                channelCount: 1,
                source: .them,
                startTime: 2.0
            )
            s.expectEqual(chunk.duration, 1.0, "1s of 48kHz audio")
            s.expectEqual(chunk.endTime, 3.0, "endTime = start + duration")

            let zero = AudioChunk(samples: [0, 0], sampleRate: 0, channelCount: 1, source: .you, startTime: 0)
            s.expectEqual(zero.duration, 0, "zero sample-rate guards duration")
        }

        s.check("SessionClock maps platform time to session-relative") { s in
            let clock = SessionClock(originSeconds: 100.0)
            s.expectEqual(clock.sessionTime(forPlatformTime: 100.0), 0.0, "origin maps to zero")
            s.expectEqual(clock.sessionTime(forPlatformTime: 105.5), 5.5, "elapsed since origin")
        }

        s.check("TranscriptEvent attribution presence/absence and Codable") { s in
            let none = TranscriptEvent(kind: .volatile, source: .you, start: 0, end: 1, text: "hi")
            s.expect(none.attribution == nil, "no attribution by default")

            let attr = TranscriptAttribution(source: "asr", confidence: 0.9)
            let evt = TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "hello", attribution: attr)
            let data = try JSONEncoder().encode(evt)
            let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: data)
            s.expectEqual(decoded.text, "hello", "text round-trip")
            s.expectEqual(decoded.attribution?.source, "asr", "attribution source round-trip")
            s.expectEqual(decoded.attribution?.confidence, 0.9, "attribution confidence round-trip")
        }

        s.check("TranscriptAttribution displayName: presence, omission-when-nil, and legacy decode") { s in
            // Presence round-trip: displayName survives Encoder/Decoder round-trip.
            let named = TranscriptAttribution(source: "vision", confidence: 0.87, displayName: "Alex Kim")
            let namedData = try JSONEncoder().encode(named)
            let namedDecoded = try JSONDecoder().decode(TranscriptAttribution.self, from: namedData)
            s.expectEqual(namedDecoded.source, "vision", "displayName round-trip: source")
            s.expectEqual(namedDecoded.confidence, 0.87, "displayName round-trip: confidence")
            s.expectEqual(namedDecoded.displayName, "Alex Kim", "displayName round-trip: displayName")

            // Omission-when-nil: the "displayName" key must be absent from the
            // encoded JSON, not merely decode back to nil (which would also
            // pass if the encoder emitted "displayName":null).
            let unnamed = TranscriptAttribution(source: "asr", confidence: 0.9)
            let unnamedData = try JSONEncoder().encode(unnamed)
            let unnamedJSON = String(decoding: unnamedData, as: UTF8.self)
            s.expect(!unnamedJSON.contains("displayName"), "displayName key omitted from JSON when nil")

            // Back-compat decode: a legacy line with no displayName key at all
            // (pre-Phase-1 shape) must still decode, with displayName == nil.
            let legacyJSON = Data(#"{"confidence":0.9,"source":"asr"}"#.utf8)
            let legacyDecoded = try JSONDecoder().decode(TranscriptAttribution.self, from: legacyJSON)
            s.expectEqual(legacyDecoded.source, "asr", "legacy decode: source")
            s.expectEqual(legacyDecoded.confidence, 0.9, "legacy decode: confidence")
            s.expect(legacyDecoded.displayName == nil, "legacy decode: displayName defaults to nil")
        }

        s.check("FinalizedSegmentDTO round-trip and init(event:)") { s in
            let evt = TranscriptEvent(kind: .finalized, source: .them, start: 3, end: 4.5, text: "world")
            let dto = FinalizedSegmentDTO(event: evt)
            s.expectEqual(dto.schemaVersion, FinalizedSegmentDTO.currentSchemaVersion, "schema version")
            s.expectEqual(dto.start, 3, "start carried over")
            s.expectEqual(dto.end, 4.5, "end carried over")
            s.expectEqual(dto.source, .them, "source carried over")

            let data = try JSONEncoder().encode(dto)
            let decoded = try JSONDecoder().decode(FinalizedSegmentDTO.self, from: data)
            s.expectEqual(decoded.text, "world", "DTO text round-trip")
        }

        s.check("CaptureTarget equality and hashing") { s in
            let a = CaptureTarget(id: "com.microsoft.teams2", displayName: "Microsoft Teams")
            let b = CaptureTarget(id: "com.microsoft.teams2", displayName: "Microsoft Teams")
            s.expectEqual(a, b, "value equality")
            s.expectEqual(Set([a, b]).count, 1, "hashes collapse equal targets")
        }
    }

    // MARK: - Phase 3: macOS AudioSource pure helpers (hardware-free)

    static func checkAudioSource(_ s: CheckSuite) {
        s.check("AudioMath.rms / peak on known samples") { s in
            // Full-scale square wave: rms == peak == 1.
            s.expectEqual(AudioMath.rms([1, -1, 1, -1]), 1, "rms of ±1 square wave")
            s.expectEqual(AudioMath.peak([1, -1, 1, -1]), 1, "peak of ±1 square wave")
            // Half-scale.
            s.expectEqual(AudioMath.rms([0.5, -0.5, 0.5, -0.5]), 0.5, "rms of ±0.5")
            s.expectEqual(AudioMath.peak([0.25, -0.5, 0.1]), 0.5, "peak is max abs")
            // Empty input is silent, not a crash.
            s.expectEqual(AudioMath.rms([]), 0, "rms of empty")
            s.expectEqual(AudioMath.peak([]), 0, "peak of empty")
        }

        s.check("AudioMath downmix (interleaved & non-interleaved)") { s in
            // Interleaved stereo [c0f0,c1f0, c0f1,c1f1] = [1,3, 2,4] -> [(1+3)/2,(2+4)/2] = [2,3].
            s.expectEqual(
                AudioMath.downmixInterleavedToMono([1, 3, 2, 4], channelCount: 2),
                [2, 3],
                "interleaved stereo average"
            )
            // Mono passes through unchanged.
            s.expectEqual(
                AudioMath.downmixInterleavedToMono([1, 2, 3], channelCount: 1),
                [1, 2, 3],
                "mono interleaved passthrough"
            )
            // Non-interleaved (channel-major) [[1,2],[3,4]] -> [2,3].
            s.expectEqual(
                AudioMath.downmixChannelsToMono([[1, 2], [3, 4]]),
                [2, 3],
                "non-interleaved stereo average"
            )
            // Ragged channels bound to the shortest length defensively.
            s.expectEqual(
                AudioMath.downmixChannelsToMono([[1, 2, 9], [3, 4]]),
                [2, 3],
                "ragged channels clamp to shortest"
            )
        }

        s.check("MeterLevel.measuring matches AudioMath") { s in
            let samples: [Float] = [0.5, -0.5, 0.25, -0.25]
            let level = MeterLevel.measuring(samples)
            s.expectEqual(level.rms, AudioMath.rms(samples), "meter rms")
            s.expectEqual(level.peak, AudioMath.peak(samples), "meter peak")
            s.expectEqual(MeterLevel.silent.rms, 0, "silent rms")
            s.expectEqual(MeterLevel.silent.peak, 0, "silent peak")
        }

        s.check("HostClock host-time conversion is linear from zero") { s in
            s.expectEqual(HostClock.seconds(fromMachHostTime: 0), 0, "zero ticks -> zero seconds")
            // Two readings of the monotonic clock never go backwards.
            let a = HostClock.now()
            let b = HostClock.now()
            s.expect(b >= a, "HostClock.now is monotonic non-decreasing")
        }

        s.check("AudioChunkFactory timestamp mapping == platformSeconds - origin") { s in
            // Clock origin 100s; capture's first sample at platform time 105s.
            let clock = SessionClock(originSeconds: 100)
            let samples = [Float](repeating: 0, count: 1000)
            let chunks = AudioChunkFactory.chunks(
                fromMonoSamples: samples,
                sampleRate: 1000,            // 1 frame == 1 ms
                source: .them,
                clock: clock,
                firstSamplePlatformTime: 105,
                framesPerChunk: 250          // 250 ms each -> 4 chunks
            )
            s.expectEqual(chunks.count, 4, "1000 frames / 250 == 4 chunks")
            // First chunk: platform 105 - origin 100 == 5.0s session-relative.
            s.expectEqual(chunks[0].startTime, 5.0, "first chunk start")
            s.expectEqual(chunks[0].source, .them, "tagged source preserved")
            // Second chunk starts 250 frames / 1000 Hz == 0.25s later.
            s.expectEqual(chunks[1].startTime, 5.25, "second chunk start")
            s.expectEqual(chunks[3].startTime, 5.75, "fourth chunk start")
            // Times are session-relative, i.e. exactly platformSeconds - origin.
            let platformOfChunk2 = 105.0 + Double(2 * 250) / 1000.0
            s.expectEqual(chunks[2].startTime, platformOfChunk2 - 100.0, "explicit platform - origin")
        }

        s.check("ScreenCaptureKitSource defensive Teams matching") { s in
            s.expect(
                ScreenCaptureKitSource.isLikelyTeams(CaptureTarget(id: "com.microsoft.teams2", displayName: "Microsoft Teams")),
                "new Teams bundle id recognized"
            )
            s.expect(
                ScreenCaptureKitSource.isLikelyTeams(CaptureTarget(id: "com.microsoft.teams", displayName: "Teams classic")),
                "classic Teams bundle id recognized"
            )
            s.expect(
                ScreenCaptureKitSource.isLikelyTeams(CaptureTarget(id: "com.google.Chrome", displayName: "Teams meeting — Chrome")),
                "browser tab title recognized"
            )
            s.expect(
                !ScreenCaptureKitSource.isLikelyTeams(CaptureTarget(id: "com.apple.Safari", displayName: "Safari")),
                "unrelated app not matched"
            )
        }
    }

    // MARK: - Phase 3: AudioSource protocol behaviour (async, fakes only)

    static func checkAudioSourceAsync(_ s: CheckSuite) async {
        await s.checkAsync("FakeAudioSource emits scripted chunks in order then finishes") { s in
            let script = [
                AudioChunk(samples: [0.1, 0.2], sampleRate: 48_000, channelCount: 1, source: .you, startTime: 0.0),
                AudioChunk(samples: [0.3], sampleRate: 48_000, channelCount: 1, source: .them, startTime: 0.5),
                AudioChunk(samples: [0.4], sampleRate: 48_000, channelCount: 1, source: .you, startTime: 1.0),
            ]
            let source: any AudioSource = FakeAudioSource(script: script, finishAfterScript: true)
            let targets = try await source.availableTargets()
            s.expect(!targets.isEmpty, "fake exposes at least one target")
            try await source.start(target: targets[0])

            var received: [AudioChunk] = []
            for await chunk in source.buffers { received.append(chunk) }

            s.expectEqual(received.count, 3, "all scripted chunks delivered")
            s.expectEqual(received, script, "chunks delivered in order, unchanged")
            s.expectEqual(received.map(\.source), [.you, .them, .you], "source tags multiplexed on one stream")
        }

        await s.checkAsync("FakeAudioSource.stop is idempotent and finishes the stream") { s in
            let source = FakeAudioSource(script: [], finishAfterScript: false)
            try await source.start(target: CaptureTarget(id: "fake.target", displayName: "Fake Target"))
            await source.stop()
            await source.stop() // second call must be a no-op, not a crash/double-finish
            var count = 0
            for await _ in source.buffers { count += 1 }
            s.expectEqual(count, 0, "no chunks; stream finished after stop")
        }
    }

    // MARK: - VocabularyStore

    static func checkVocabularyStore(_ s: CheckSuite) {
        s.check("expandName: single word") { s in
            let hints = VocabularyStore.expandName("Kubernetes")
            s.expectEqual(hints, ["Kubernetes"], "single word → itself only")
        }

        s.check("expandName: space-separated name") { s in
            let hints = VocabularyStore.expandName("Jane Doe")
            s.expect(hints.contains("Jane"), "contains first")
            s.expect(hints.contains("Doe"), "contains last")
            s.expect(hints.contains("Jane Doe"), "contains full phrase")
        }

        s.check("expandName: Last, First format") { s in
            let hints = VocabularyStore.expandName("Doe, Jane")
            s.expect(hints.contains("Doe"), "contains last")
            s.expect(hints.contains("Jane"), "contains first")
            s.expect(hints.contains("Jane Doe"), "contains First Last phrase")
            s.expect(!hints.contains("Doe, Jane"), "does not include raw comma form")
        }

        s.check("load: inline terms are highest priority and never truncated") { s in
            let inline = ["Alpha", "Beta", "Gamma"]
            let result = VocabularyStore.load(
                filePath: nil, folderPath: nil,
                inlineTerms: inline, maxTerms: 2
            )
            s.expect(result.terms.contains("Alpha"), "inline Alpha survives truncation")
            s.expect(result.terms.contains("Beta"), "inline Beta survives truncation")
            s.expectEqual(result.terms.count, 2, "truncated to maxTerms=2")
            s.expect(result.truncated, "truncated flag set")
            s.expectEqual(result.inlineCount, 3, "inline count before truncation")
        }

        s.check("load: inline terms deduplicated case-insensitively") { s in
            let result = VocabularyStore.load(
                filePath: nil, folderPath: nil,
                inlineTerms: ["Kubernetes", "kubernetes", "KUBERNETES"]
            )
            s.expectEqual(result.terms.count, 1, "3 case variants → 1 unique term")
            s.expectEqual(result.inlineCount, 1, "inline count = 1")
        }

        s.check("load: min-length filter (< 2 chars dropped)") { s in
            let result = VocabularyStore.load(
                filePath: nil, folderPath: nil,
                inlineTerms: ["A", "B", "OK", "Go"]
            )
            s.expect(!result.terms.contains("A"), "single char dropped")
            s.expect(!result.terms.contains("B"), "single char dropped")
            s.expect(result.terms.contains("OK"), "2-char term kept")
            s.expect(result.terms.contains("Go"), "2-char term kept")
        }

        s.check("load: missing file returns 0 file terms") { s in
            let result = VocabularyStore.load(
                filePath: "/tmp/alembic-nonexistent-\(Int.random(in: 0..<1_000_000)).txt",
                folderPath: nil,
                inlineTerms: []
            )
            s.expectEqual(result.fileCount, 0, "missing file → 0 file terms")
            s.expectEqual(result.terms.count, 0, "no terms total")
        }

        s.check("load: empty filePath treated as no file source") { s in
            let result = VocabularyStore.load(
                filePath: "", folderPath: nil, inlineTerms: ["OnlyInline"]
            )
            s.expectEqual(result.fileCount, 0, "empty path → 0 file terms")
            s.expectEqual(result.inlineCount, 1, "inline still present")
        }

        s.check("load: plain-text file, one term per line, hash comments stripped") { s in
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("alembic-vocab-check-\(Int.random(in: 0..<1_000_000)).txt")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let content = """
            # This is a comment
            Dynatrace
            Kubernetes
              Zabbix  
            # another comment

            Splunk
            """
            try content.write(to: tmp, atomically: true, encoding: .utf8)
            let result = VocabularyStore.load(
                filePath: tmp.path, folderPath: nil, inlineTerms: []
            )
            s.expectEqual(result.fileCount, 4, "4 non-comment, non-blank lines")
            s.expect(result.terms.contains("Dynatrace"), "Dynatrace present")
            s.expect(result.terms.contains("Zabbix"), "Zabbix (trimmed) present")
            s.expect(result.terms.contains("Splunk"), "Splunk present")
        }

        s.check("load: not-truncated flag when within limit") { s in
            let result = VocabularyStore.load(
                filePath: nil, folderPath: nil,
                inlineTerms: ["Alpha", "Beta"],
                maxTerms: 500
            )
            s.expect(!result.truncated, "not truncated when within limit")
        }

        // MARK: Source-based loading

        s.check("normalizeFilename: underscores and dashes become spaces") { s in
            s.expectEqual(VocabularyStore.normalizeFilename("jane_doe"), "jane doe", "underscore → space")
            s.expectEqual(VocabularyStore.normalizeFilename("kube-proxy"), "kube proxy", "dash → space")
            s.expectEqual(VocabularyStore.normalizeFilename("a__b--c"), "a b c", "runs collapse")
        }

        s.check("load(sources:): word source added verbatim") { s in
            let result = VocabularyStore.load(sources: [
                .init(kind: .word, value: "Kubernetes")
            ])
            s.expectEqual(result.terms, ["Kubernetes"], "word becomes a single term")
            s.expectEqual(result.perSourceTermCounts, [1], "one term from one source")
        }

        s.check("load(sources:): order = priority under truncation") { s in
            let result = VocabularyStore.load(sources: [
                .init(kind: .word, value: "First"),
                .init(kind: .word, value: "Second"),
                .init(kind: .word, value: "Third")
            ], maxTerms: 2)
            s.expectEqual(result.terms, ["First", "Second"], "earliest sources win")
            s.expect(result.truncated, "truncated flag set")
        }

        s.check("load(sources:): file source with tilde + space in path") { s in
            // Build a path containing a space under the temp directory, then
            // express it relative to HOME with a leading "~" to exercise both
            // the space and tilde-expansion fixes.
            let home = NSHomeDirectory()
            let dirName = "alembic vocab check \(Int.random(in: 0..<1_000_000))"
            let dirURL = URL(fileURLWithPath: home).appendingPathComponent(dirName)
            let fm = FileManager.default
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dirURL) }
            let fileURL = dirURL.appendingPathComponent("terms.txt")
            try "Dynatrace\nZabbix\n".write(to: fileURL, atomically: true, encoding: .utf8)

            let tildePath = "~/\(dirName)/terms.txt"
            let result = VocabularyStore.load(sources: [
                .init(kind: .file, value: tildePath)
            ])
            s.expect(result.terms.contains("Dynatrace"), "tilde+space file path resolved")
            s.expect(result.terms.contains("Zabbix"), "second term loaded")
        }

        s.check("load(sources:): directory listing → normalized filenames") { s in
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("alembic-vocab-dir-\(Int.random(in: 0..<1_000_000))")
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            try "".write(to: dir.appendingPathComponent("jane_doe.md"), atomically: true, encoding: .utf8)
            try "".write(to: dir.appendingPathComponent("kube-proxy.txt"), atomically: true, encoding: .utf8)
            try? fm.createDirectory(at: dir.appendingPathComponent("subdir"), withIntermediateDirectories: true)

            let result = VocabularyStore.load(sources: [
                .init(kind: .directory, value: dir.path)
            ])
            s.expect(result.terms.contains("jane doe"), "underscore filename normalized")
            s.expect(result.terms.contains("kube proxy"), "dash filename normalized, extension dropped")
            s.expect(!result.terms.contains("subdir"), "subdirectories excluded")
        }

        s.check("encode/decode sources round-trips") { s in
            let original: [VocabularyStore.VocabularySource] = [
                .init(kind: .word, value: "Splunk"),
                .init(kind: .file, value: "~/a b/v.txt"),
                .init(kind: .directory, value: "/tmp/notes")
            ]
            let decoded = VocabularyStore.decodeSources(VocabularyStore.encodeSources(original))
            s.expectEqual(decoded, original, "round-trip preserves sources")
            s.expectEqual(VocabularyStore.decodeSources(""), [], "empty string → no sources")
            s.expectEqual(VocabularyStore.decodeSources("not json"), [], "malformed → no sources")
        }

        s.check("migratedSources: inline → words, file, folder order") { s in
            let migrated = VocabularyStore.migratedSources(
                inline: "Alpha, Beta",
                filePath: "/tmp/v.txt",
                folderPath: "/tmp/vault"
            )
            s.expectEqual(migrated.count, 4, "2 words + file + folder")
            s.expectEqual(migrated[0].kind, .word, "first is a word")
            s.expectEqual(migrated[0].value, "Alpha", "first inline word")
            s.expectEqual(migrated[2].kind, .file, "file after words")
            s.expectEqual(migrated[3].kind, .directory, "folder last")
        }

        s.check("configuredSources: migrates legacy keys when sources key absent") { s in
            let suite = "alembic-test-\(Int.random(in: 0..<1_000_000))"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("Gamma", forKey: "alembic.vocabulary.inline")
            let migrated = VocabularyStore.configuredSources(defaults: defaults)
            s.expectEqual(migrated.count, 1, "one migrated word")
            s.expectEqual(migrated.first?.value, "Gamma", "legacy inline migrated")

            // Explicit sources key (even empty) takes precedence over legacy keys.
            defaults.set("[]", forKey: VocabularyStore.sourcesDefaultsKey)
            s.expectEqual(VocabularyStore.configuredSources(defaults: defaults).count, 0,
                          "explicit empty sources key overrides legacy migration")
        }
    }

    // MARK: - MeetingAppCatalog

    static func checkMeetingAppCatalog(_ s: CheckSuite) {
        s.check("MeetingAppCatalog.match: exact bundle IDs match") { s in
            let m = MeetingAppCatalog.match(bundleID: "com.microsoft.teams2")
            s.expect(m != nil, "exact teams2 match")
            s.expectEqual(m?.app.displayName, "Microsoft Teams", "teams2 displayName")
            s.expectEqual(m?.canonicalBundlePrefix, "com.microsoft.teams2", "teams2 canonical prefix")

            let mClassic = MeetingAppCatalog.match(bundleID: "com.microsoft.teams")
            s.expectEqual(mClassic?.canonicalBundlePrefix, "com.microsoft.teams", "classic Teams canonical prefix")

            let mZoom = MeetingAppCatalog.match(bundleID: "us.zoom.xos")
            s.expectEqual(mZoom?.app.displayName, "Zoom", "Zoom exact match")

            let mSlack = MeetingAppCatalog.match(bundleID: "com.tinyspeck.slackmacgap")
            s.expectEqual(mSlack?.app.displayName, "Slack", "Slack exact match")
        }

        s.check("MeetingAppCatalog.match: helper bundles resolve to parent prefix") { s in
            let m = MeetingAppCatalog.match(bundleID: "com.microsoft.teams2.modulehost")
            s.expect(m != nil, "teams2 modulehost matches")
            s.expectEqual(m?.canonicalBundlePrefix, "com.microsoft.teams2",
                          "modulehost resolves to teams2 canonical prefix")
            s.expectEqual(m?.app.displayName, "Microsoft Teams", "modulehost resolves to Teams")
        }

        s.check("MeetingAppCatalog.match: longest prefix wins (dot-delimited)") { s in
            // com.microsoft.teams2.modulehost: teams2 (20 chars) beats teams (18 chars)
            let m2 = MeetingAppCatalog.match(bundleID: "com.microsoft.teams2.modulehost")
            s.expectEqual(m2?.canonicalBundlePrefix, "com.microsoft.teams2",
                          "longer prefix teams2 wins over teams for teams2.* helpers")

            // com.microsoft.teams.somehelper should match classic Teams only
            let mClassic = MeetingAppCatalog.match(bundleID: "com.microsoft.teams.somehelper")
            s.expectEqual(mClassic?.canonicalBundlePrefix, "com.microsoft.teams",
                          "classic Teams helper resolves to teams prefix")
        }

        s.check("MeetingAppCatalog.match: dot-delimited boundary prevents false matches") { s in
            // "teams2beta" must NOT match "com.microsoft.teams2" (no dot after teams2)
            s.expect(MeetingAppCatalog.match(bundleID: "com.microsoft.teams2beta") == nil,
                     "teams2beta must not match teams2 (no dot boundary)")

            // "us.zoom.xosextension" must NOT match "us.zoom.xos"
            s.expect(MeetingAppCatalog.match(bundleID: "us.zoom.xosextension") == nil,
                     "xosextension must not match xos (no dot boundary)")

            // "com.tinyspeck.slackmacgapx" must NOT match Slack
            s.expect(MeetingAppCatalog.match(bundleID: "com.tinyspeck.slackmacgapx") == nil,
                     "slackmacgapx must not match slackmacgap (no dot boundary)")
        }

        s.check("MeetingAppCatalog.match: Discord is NOT in the catalog") { s in
            s.expect(MeetingAppCatalog.match(bundleID: "com.hnc.Discord") == nil,
                     "Discord not matched")
            s.expect(MeetingAppCatalog.match(bundleID: "com.discord") == nil,
                     "discord.com not matched")
            s.expect(MeetingAppCatalog.match(bundleID: "com.hammerandchisel.discord") == nil,
                     "Discord legacy ID not matched")
        }

        s.check("MeetingAppCatalog.match: browser/WebKit helpers match with requiresTitleConfirmation") { s in
            let chrome = MeetingAppCatalog.match(bundleID: "com.google.Chrome.helper.EH")
            s.expect(chrome != nil, "Chrome helper is in the catalog")
            s.expect(chrome?.app.requiresTitleConfirmation == true,
                     "Chrome helper requires title confirmation")

            let webkit = MeetingAppCatalog.match(bundleID: "com.apple.WebKit.WebContent")
            s.expect(webkit?.app.requiresTitleConfirmation == true,
                     "WebKit WebContent requires title confirmation")

            let gpu = MeetingAppCatalog.match(bundleID: "com.apple.WebKit.GPU")
            s.expect(gpu?.app.requiresTitleConfirmation == true,
                     "WebKit GPU requires title confirmation")
        }

        s.check("MeetingAppCatalog.isInCall: Teams in-call via helper bundle (with output)") { s in
            let helper = [
                AudioProcessState(pid: 400, bundleID: "com.microsoft.teams2.modulehost",
                                  isRunningInput: true, isRunningOutput: true),
            ]
            let app = MeetingAppCatalog.isInCall(processStates: helper)
            s.expect(app != nil, "Teams2 modulehost with output triggers detection")
            s.expectEqual(app?.displayName, "Microsoft Teams", "detected as Microsoft Teams")
        }

        s.check("MeetingAppCatalog.isInCall: Teams requiresOutput guard") { s in
            // Input-only = Teams is not in-call (requiresOutput enforced, mirrors Zoom guard).
            let micOnly = [AudioProcessState(pid: 400, bundleID: "com.microsoft.teams2",
                                            isRunningInput: true, isRunningOutput: false)]
            s.expect(MeetingAppCatalog.isInCall(processStates: micOnly) == nil,
                     "Teams input-only → no detection (requiresOutput guard)")

            // Output present = in-call (muted or active in meeting).
            let withOutput = [AudioProcessState(pid: 400, bundleID: "com.microsoft.teams2",
                                               isRunningInput: true, isRunningOutput: true)]
            let detected = MeetingAppCatalog.isInCall(processStates: withOutput)
            s.expect(detected != nil, "Teams with output → detection")
            s.expectEqual(detected?.displayName, "Microsoft Teams", "Teams with output → Microsoft Teams")
        }

        s.check("MeetingAppCatalog.isInCall: Slack requires input AND output (huddle gate)") { s in
            // Slack plays notification sounds all day; output alone must never
            // detect. A huddle always runs the mic, so input+output is the gate.
            let viaInput = [AudioProcessState(pid: 100, bundleID: "com.tinyspeck.slackmacgap",
                                              isRunningInput: true, isRunningOutput: false)]
            s.expect(MeetingAppCatalog.isInCall(processStates: viaInput) == nil,
                     "Slack input-only → no detection")

            let viaOutput = [AudioProcessState(pid: 100, bundleID: "com.tinyspeck.slackmacgap",
                                               isRunningInput: false, isRunningOutput: true)]
            s.expect(MeetingAppCatalog.isInCall(processStates: viaOutput) == nil,
                     "Slack output-only (notification sound) → no detection")

            let huddle = [AudioProcessState(pid: 100, bundleID: "com.tinyspeck.slackmacgap",
                                            isRunningInput: true, isRunningOutput: true)]
            s.expect(MeetingAppCatalog.isInCall(processStates: huddle) != nil,
                     "Slack huddle (input+output) → detection")

            let idle = [AudioProcessState(pid: 100, bundleID: "com.tinyspeck.slackmacgap",
                                          isRunningInput: false, isRunningOutput: false)]
            s.expect(MeetingAppCatalog.isInCall(processStates: idle) == nil,
                     "Slack idle → no detection")
        }

        s.check("MeetingAppCatalog.isInCall: Zoom requiresOutput guard") { s in
            // Input-only = mic-preview false-start; must NOT detect.
            let micPreview = [AudioProcessState(pid: 200, bundleID: "us.zoom.xos",
                                               isRunningInput: true, isRunningOutput: false)]
            s.expect(MeetingAppCatalog.isInCall(processStates: micPreview) == nil,
                     "Zoom input-only → no detection (mic-preview guard)")

            // Muted in real meeting: output-only (far-end audio).
            let mutedInCall = [AudioProcessState(pid: 200, bundleID: "us.zoom.xos",
                                                isRunningInput: false, isRunningOutput: true)]
            s.expect(MeetingAppCatalog.isInCall(processStates: mutedInCall) != nil,
                     "Zoom output-only → in-call (muted in meeting)")

            // Active mic + output = normal call.
            let activeCall = [AudioProcessState(pid: 200, bundleID: "us.zoom.xos",
                                               isRunningInput: true, isRunningOutput: true)]
            s.expect(MeetingAppCatalog.isInCall(processStates: activeCall) != nil,
                     "Zoom in+out → in-call")
        }

        s.check("MeetingAppCatalog.isInCall: browser/WebKit helpers NEVER match alone") { s in
            let chrome = [AudioProcessState(pid: 300, bundleID: "com.google.Chrome.helper.EH",
                                           isRunningInput: true, isRunningOutput: true)]
            s.expect(MeetingAppCatalog.isInCall(processStates: chrome) == nil,
                     "Chrome helper alone → no detection")

            let webkit = [AudioProcessState(pid: 301, bundleID: "com.apple.WebKit.WebContent",
                                           isRunningInput: true, isRunningOutput: false)]
            s.expect(MeetingAppCatalog.isInCall(processStates: webkit) == nil,
                     "WebKit WebContent alone → no detection")

            // Confirm Discord web (running in Chrome helper) also doesn't fire.
            let discordWeb = [AudioProcessState(pid: 302, bundleID: "com.google.Chrome.helper",
                                               isRunningInput: false, isRunningOutput: true)]
            s.expect(MeetingAppCatalog.isInCall(processStates: discordWeb) == nil,
                     "Discord web in Chrome helper → no detection")
        }

        s.check("MeetingAppCatalog.isInCall: empty + idle process list → nil") { s in
            s.expect(MeetingAppCatalog.isInCall(processStates: []) == nil,
                     "empty list → nil")
            let unrelated = [AudioProcessState(pid: 1, bundleID: "com.apple.Safari",
                                              isRunningInput: false, isRunningOutput: false)]
            s.expect(MeetingAppCatalog.isInCall(processStates: unrelated) == nil,
                     "unrelated + idle → nil")
        }

        s.check("MeetingAppCatalog.teamsBundleIDHints is single source of truth") { s in
            let hints = MeetingAppCatalog.teamsBundleIDHints
            s.expect(hints.contains("com.microsoft.teams"), "classic Teams prefix present")
            s.expect(hints.contains("com.microsoft.teams2"), "new Teams prefix present")
            // ScreenCaptureKitSource must delegate to the same list.
            s.expectEqual(ScreenCaptureKitSource.teamsBundleIDHints, hints,
                          "ScreenCaptureKitSource.teamsBundleIDHints delegates to catalog")
        }
    }

    // MARK: - Speaker attribution (Phase 2): ActiveSpeakerTimeline

    static func checkActiveSpeakerTimeline(_ s: CheckSuite) {
        s.check("ActiveSpeakerTimeline.resolve: dominant overlap accepted") { s in
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.9, in: 0...10)
            timeline.record(name: "Sam", confidence: 0.9, in: 10.001...12)
            let resolution = timeline.resolve(window: 0...12)
            s.expectEqual(resolution?.displayName, "Alex", "Alex dominates 10/12 of the window")
            s.expect((resolution?.overlapFraction ?? 0) > 0.8, "overlapFraction near 10/12")
            s.expectEqual(resolution?.confidence, 0.9, "confidence carries through")
        }

        s.check("ActiveSpeakerTimeline.resolve: below minOverlapFraction → nil (straddle, SR-12)") { s in
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.9, in: 0...6)
            timeline.record(name: "Sam", confidence: 0.9, in: 6.001...12)
            s.expect(timeline.resolve(window: 0...12) == nil, "no dominant speaker ⇒ nil, never guess")
        }

        s.check("ActiveSpeakerTimeline.resolve: below minConfidence → nil") { s in
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.2, in: 0...12)
            s.expect(timeline.resolve(window: 0...12) == nil, "100% overlap but confidence below τ ⇒ nil")
        }

        s.check("ActiveSpeakerTimeline.resolve: no overlap → nil") { s in
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.9, in: 20...25)
            s.expect(timeline.resolve(window: 0...12) == nil, "interval entirely outside window ⇒ nil")
        }

        s.check("ActiveSpeakerTimeline.resolve: endpoint-touching overlap is ignored, not a zero-overlap winner") { s in
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.9, in: 0...10)
            s.expect(timeline.resolve(window: 10...12) == nil,
                     "shared-endpoint touch has zero duration ⇒ no signal, no division by zero")

            var timeline2 = ActiveSpeakerTimeline()
            timeline2.record(name: "Alex", confidence: 0.9, in: 0...10)
            timeline2.record(name: "Sam", confidence: 0.9, in: 10.001...12)
            s.expectEqual(timeline2.resolve(window: 10...12)?.displayName, "Sam",
                          "endpoint-touching Alex interval contributes nothing to the accumulation")
        }

        s.check("ActiveSpeakerTimeline.resolve: deterministic, with a genuine tie broken lexicographically (SR-13)") { s in
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.9, in: 0...10)
            timeline.record(name: "Sam", confidence: 0.9, in: 10.001...12)
            let first = timeline.resolve(window: 0...12)
            let second = timeline.resolve(window: 0...12)
            s.expectEqual(first, second, "resolve is a pure function of (intervals, configuration, window)")

            // Two distinct names, deliberately tied on both overlap and
            // confidence: both fully span the window, so both clear
            // minOverlapFraction/minConfidence on their own and are tied on
            // totalOverlap and weighted-average confidence. firstSeenIndex is
            // deliberately not exercised here — the tie is genuine.
            var tied = ActiveSpeakerTimeline()
            tied.record(name: "Bob", confidence: 0.7, in: 0...12)
            tied.record(name: "Ann", confidence: 0.7, in: 0...12)
            for _ in 0..<3 {
                s.expectEqual(tied.resolve(window: 0...12)?.displayName, "Ann",
                              "tied overlap+confidence ⇒ lexicographically smaller name wins, every call")
            }
        }

        s.check("ActiveSpeakerTimeline.record: coalesces same-name intervals within coalesceGap") { s in
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.8, in: 0...5)
            timeline.record(name: "Alex", confidence: 0.85, in: 6...9)
            s.expectEqual(timeline.intervals.count, 1, "gap of 1s (<= default 2.5s coalesceGap) merges")
            let merged = timeline.intervals[0]
            s.expectEqual(merged.range, 0...9, "merged range spans both source intervals")
            s.expect(merged.confidence >= 0.8 && merged.confidence <= 0.85,
                     "merged confidence is a weighted average of the two sources")
        }

        s.check("ActiveSpeakerTimeline.record: no coalescing across a large gap") { s in
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.8, in: 0...5)
            timeline.record(name: "Alex", confidence: 0.85, in: 20...23)
            s.expectEqual(timeline.intervals.count, 2, "gap of 15s exceeds default 2.5s coalesceGap")
        }

        s.check("ActiveSpeakerTimeline.record: retention trim drops intervals older than retentionWindow") { s in
            var timeline = ActiveSpeakerTimeline(configuration: .init(retentionWindow: 600))
            timeline.record(name: "Alex", confidence: 0.9, in: 0...5)
            timeline.record(name: "Sam", confidence: 0.9, in: 700...705)
            s.expect(timeline.intervals.count == 1, "the stale Alex interval is trimmed")
            s.expectEqual(timeline.intervals.first?.name, "Sam", "only the recent interval remains")
        }

        s.check("ActiveSpeakerTimeline.record: preserves the sorted invariant for out-of-order input") { s in
            var timeline = ActiveSpeakerTimeline()
            // Report observations out of capture order.
            timeline.record(name: "Sam", confidence: 0.9, in: 10...15)
            timeline.record(name: "Alex", confidence: 0.9, in: 0...5)
            timeline.record(name: "Jamie", confidence: 0.9, in: 5.5...9)

            let lowerBounds = timeline.intervals.map(\.range.lowerBound)
            s.expectEqual(lowerBounds, lowerBounds.sorted(),
                          "intervals stay sorted by range.lowerBound ascending, even with out-of-order record calls")
            s.expectEqual(timeline.intervals.map(\.name), ["Alex", "Jamie", "Sam"],
                          "out-of-order interval is inserted at its sorted position, not appended out of place")

            // Retention trimming must use the true latest upper bound across
            // the whole timeline, not merely the last-inserted element: here
            // "Stale" is inserted (out of order) *after* "Recent", so a naive
            // "trim relative to intervals.last" would use Stale's own
            // upperBound as the reference and never trim anything.
            var timeline2 = ActiveSpeakerTimeline(configuration: .init(retentionWindow: 10))
            timeline2.record(name: "Recent", confidence: 0.9, in: 100...110)
            timeline2.record(name: "Stale", confidence: 0.9, in: 0...5)
            s.expectEqual(timeline2.intervals.map(\.name), ["Recent"],
                          "trim uses the true latest upper bound (110), so Stale (ends at 5) is dropped")
        }

        s.check("ActiveSpeakerTimeline.resolve: zero-length (point) window") { s in
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.9, in: 0...10)
            let resolved = timeline.resolve(window: 5...5)
            s.expectEqual(resolved?.displayName, "Alex", "single interval containing the point resolves")
            s.expectEqual(resolved?.overlapFraction, 1.0, "point containment is fraction 1.0 by convention")

            // Two distinct names both touching the same point is
            // definitionally maximally ambiguous.
            var twoAtPoint = ActiveSpeakerTimeline()
            twoAtPoint.record(name: "Alex", confidence: 0.9, in: 0...10)
            twoAtPoint.record(name: "Sam", confidence: 0.9, in: 3...10)
            s.expect(twoAtPoint.resolve(window: 5...5) == nil,
                     "two distinct names touching the same point ⇒ maximally ambiguous ⇒ nil")
        }

        s.check("ActiveSpeakerTimeline: confidence clamping (DR-3)") { s in
            let clampedHigh = ActiveSpeakerTimeline.Interval(range: 0...10, name: "Alex", confidence: 1.5)
            s.expectEqual(clampedHigh.confidence, 1.0, "confidence > 1 clamps to 1.0")
            let clampedLow = ActiveSpeakerTimeline.Interval(range: 0...10, name: "Alex", confidence: -0.3)
            s.expectEqual(clampedLow.confidence, 0.0, "confidence < 0 clamps to 0.0")

            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 1.7, in: 0...10)
            let resolved = timeline.resolve(window: 0...10)
            s.expect((resolved?.confidence ?? 2) <= 1.0, "resolved confidence from a clamped interval stays <= 1.0")
        }

        s.check("ActiveSpeakerTimeline.Configuration: invalid values clamp, not trap") { s in
            let config = ActiveSpeakerTimeline.Configuration(
                minConfidence: 1.4, minOverlapFraction: -0.2, coalesceGap: -5, retentionWindow: -10
            )
            s.expectEqual(config.minConfidence, 1.0, "minConfidence clamps to 1.0")
            s.expectEqual(config.minOverlapFraction, 0.0, "minOverlapFraction clamps to 0.0")
            s.expectEqual(config.coalesceGap, 0.0, "coalesceGap clamps to 0.0")
            s.expectEqual(config.retentionWindow, 0.0, "retentionWindow clamps to 0.0")
        }

        // --- Phase 3 §0.3/§0.4: overlapping duplicate same-name intervals must not double-count ---
        s.check("ActiveSpeakerTimeline.resolve: overlapping duplicate same-name intervals do not double-count") { s in
            // Reproduces the Phase 2 impl-review-1 MEDIUM finding's exact
            // failure shape: a duplicate/out-of-order-inserted Alex interval
            // identical to the first must not let Alex's totalOverlap sum to
            // 12 (double-counting the same 0...6 span twice) and thereby win
            // with an inflated overlapFraction of 1.0. Pre-fix, this
            // resolved confidently to "Alex"; post-fix, Alex's true
            // (unioned) overlap is only 6/12 = 0.5, below the default
            // minOverlapFraction (0.6), so the window is correctly rejected
            // as ambiguous — same as the non-duplicated straddle case.
            var timeline = ActiveSpeakerTimeline()
            timeline.record(name: "Alex", confidence: 0.9, in: 0...6)
            timeline.record(name: "Sam", confidence: 0.9, in: 6.001...12)
            timeline.record(name: "Alex", confidence: 0.9, in: 0...6) // duplicate/out-of-order re-report
            s.expectEqual(timeline.intervals.count, 3, "the duplicate interval is stored, not silently dropped or coalesced")
            s.expect(timeline.resolve(window: 0...12) == nil,
                     "duplicate same-name overlap must not inflate overlapFraction past the true 6/12 union — straddle stays nil")
        }

        s.check("ActiveSpeakerTimeline.resolve: overlapping same-name intervals still resolve when genuinely dominant") { s in
            // Positive control #1: a discriminating "close call" — Alex's
            // two overlapping intervals *naively sum* to the same overlap as
            // Sam's single interval (6 == 6), which would tie under the old
            // (pre-fix) direct-summation logic and — because "Alex" sorts
            // lexicographically before "Sam" in this codebase's tie-break —
            // incorrectly hand Alex the win. Alex's *true* (unioned) overlap
            // is only 4 (the 5...9 span, since 6...8 is shared between his
            // two intervals), so Sam's genuinely larger, non-overlapping
            // overlap (6) must win outright, with no tie to break.
            //
            // Recorded deliberately out of order (each new call's lowerBound
            // is behind the current last interval's) so `record(...)`'s own
            // same-name coalescing (which would otherwise merge Alex's two
            // intervals into one before `resolve` ever sees them, hiding the
            // bug entirely) never fires — this keeps all three intervals
            // distinct in storage, exactly the shape that reaches
            // `resolve`'s accumulation step uncoalesced.
            var notDominant = ActiveSpeakerTimeline()
            notDominant.record(name: "Alex", confidence: 0.9, in: 6...9)
            notDominant.record(name: "Sam", confidence: 0.9, in: 0...6) // out of order vs Alex(6...9) → inserted, not appended/coalesced
            notDominant.record(name: "Alex", confidence: 0.9, in: 5...8) // out of order vs the current last (Alex 6...9) → inserted, not coalesced with either Alex interval
            s.expectEqual(notDominant.intervals.count, 3, "all three intervals stay distinct — no accidental record()-level coalescing")
            let resolvedNotDominant = notDominant.resolve(window: 0...10)
            s.expectEqual(resolvedNotDominant?.displayName, "Sam",
                          "Sam's genuinely larger, non-overlapping overlap (6) beats Alex's true unioned overlap (4) outright — no double-count-induced tie")

            // Positive control #2: two overlapping same-name intervals that
            // legitimately dominate (covering 100% of the window once
            // unioned, not 190% once naively summed) must still resolve —
            // proves the fix does not regress into excessive conservatism.
            // Same out-of-order recording trick to keep both Alex intervals
            // distinct in storage rather than record()-coalesced.
            var dominant = ActiveSpeakerTimeline()
            dominant.record(name: "Alex", confidence: 0.9, in: 5...10)
            dominant.record(name: "Sam", confidence: 0.9, in: 20...21) // unrelated, keeps `last` != Alex so the next call isn't coalesced
            dominant.record(name: "Alex", confidence: 0.9, in: 0...9) // out of order vs Sam(20...21) → inserted, not coalesced
            s.expectEqual(dominant.intervals.count, 3, "both Alex intervals stay distinct — no accidental record()-level coalescing")
            let resolvedDominant = dominant.resolve(window: 0...10)
            s.expectEqual(resolvedDominant?.displayName, "Alex", "genuinely dominant overlapping union still resolves")
            s.expectEqual(resolvedDominant?.overlapFraction, 1.0, "unioned (not summed) overlap correctly reports 100%, not 190%")
        }

        s.check("ActiveSpeakerTimeline.Interval/Configuration: NaN/±infinity inputs clamp to 0, not NaN") { s in
            s.expectEqual(ActiveSpeakerTimeline.Interval(range: 0...10, name: "Alex", confidence: .nan).confidence, 0,
                          "Interval confidence NaN clamps to 0")
            s.expectEqual(ActiveSpeakerTimeline.Interval(range: 0...10, name: "Alex", confidence: .infinity).confidence, 0,
                          "Interval confidence +infinity clamps to 0")
            s.expectEqual(ActiveSpeakerTimeline.Interval(range: 0...10, name: "Alex", confidence: -.infinity).confidence, 0,
                          "Interval confidence -infinity clamps to 0")

            s.expectEqual(ActiveSpeakerTimeline.Configuration(minConfidence: .nan).minConfidence, 0,
                          "Configuration.minConfidence NaN clamps to 0")
            s.expectEqual(ActiveSpeakerTimeline.Configuration(minOverlapFraction: .nan).minOverlapFraction, 0,
                          "Configuration.minOverlapFraction NaN clamps to 0")
            s.expectEqual(ActiveSpeakerTimeline.Configuration(minConfidence: .infinity).minConfidence, 0,
                          "Configuration.minConfidence +infinity clamps to 0 (safe/conservative bound, not 1)")
        }
    }

    // MARK: - Speaker attribution (Phase 2): SpeakerNameNormalizer

    static func checkSpeakerNameNormalizer(_ s: CheckSuite) {
        s.check("SpeakerNameNormalizer.normalize: trims whitespace") { s in
            s.expectEqual(SpeakerNameNormalizer.normalize("  Alex Kim  "), "Alex Kim", "outer whitespace trimmed")
        }

        s.check("SpeakerNameNormalizer.normalize: strips end-only jitter, preserves interior punctuation") { s in
            s.expectEqual(SpeakerNameNormalizer.normalize("• Alex Kim"), "Alex Kim", "leading bullet stripped")
            s.expectEqual(SpeakerNameNormalizer.normalize("Alex Kim -"), "Alex Kim", "trailing dash stripped")
            s.expectEqual(SpeakerNameNormalizer.normalize("Jean-Luc Picard"), "Jean-Luc Picard",
                          "interior hyphen preserved")
        }

        s.check("SpeakerNameNormalizer.normalize: collapses internal whitespace") { s in
            s.expectEqual(SpeakerNameNormalizer.normalize("Alex   Kim"), "Alex Kim", "internal runs collapse")
        }

        s.check("SpeakerNameNormalizer.normalize: Last, First expansion via shared VocabularyStore helper") { s in
            s.expectEqual(SpeakerNameNormalizer.normalize("Kim, Alex"), "Alex Kim", "comma form expands to natural order")
            s.expectEqual(VocabularyStore.naturalOrder(from: "Kim, Alex"), "Alex Kim",
                          "directly proves the reused VocabularyStore helper")
        }

        s.check("SpeakerNameNormalizer.normalize: strips trailing Teams role labels before Last, First expansion") { s in
            s.expectEqual(SpeakerNameNormalizer.normalize("Kim, Alex (Contractor)", stripTeamsRoleSuffix: true), "Alex Kim",
                          "parenthesized contractor label is not persisted as part of the name")
            s.expectEqual(SpeakerNameNormalizer.normalize("Kim, Alex Contractor", stripTeamsRoleSuffix: true), "Alex Kim",
                          "OCR-dropped parentheses still leave a clean name")
            s.expectEqual(SpeakerNameNormalizer.normalize("Kim, Alex (Contractor", stripTeamsRoleSuffix: true), "Alex Kim",
                          "an unmatched opening parenthesis is stripped with the role suffix")
            s.expectEqual(SpeakerNameNormalizer.normalize("Kim, Alex (Contractori", stripTeamsRoleSuffix: true), "Alex Kim",
                          "trailing OCR noise after a recognized role marker is discarded")
            s.expectEqual(SpeakerNameNormalizer.normalize("Kim, Alex (External)", stripTeamsRoleSuffix: true), "Alex Kim",
                          "external label is stripped conservatively from the end only")
            s.expectEqual(SpeakerNameNormalizer.normalize("Alex Contractor"), "Alex Contractor",
                          "generic names are never truncated outside the Teams role-label context")
            s.expectEqual(SpeakerNameNormalizer.normalize("Contractor, Alex", stripTeamsRoleSuffix: true), "Alex Contractor",
                          "a legitimate surname matching a role word is preserved")
            s.expectEqual(VocabularyStore.expandName("Kim, Alex").last, "Alex Kim",
                          "expandName's own natural-order output is unchanged by the refactor")
        }

        s.check("SpeakerNameNormalizer.normalize: rejects too-short/empty result") { s in
            s.expect(SpeakerNameNormalizer.normalize("•") == nil, "all-jitter input ⇒ nil")
            s.expect(SpeakerNameNormalizer.normalize("") == nil, "empty input ⇒ nil")
            s.expect(SpeakerNameNormalizer.normalize("A") == nil, "single char after cleanup ⇒ nil")
        }

        s.check("SpeakerNameNormalizer.normalize: roster snap, unambiguous") { s in
            s.expectEqual(
                SpeakerNameNormalizer.normalize("Alx Kim", roster: ["Alex Kim", "Sam Lee"]),
                "Alex Kim", "distance-1 unique match snaps to canonical roster spelling")
            s.expectEqual(
                SpeakerNameNormalizer.normalize("Zzz Qqq", roster: ["Alex Kim"]),
                "Zzz Qqq", "no roster entry close enough ⇒ unchanged, not discarded")
            s.expectEqual(
                SpeakerNameNormalizer.normalize("Alx Kim", roster: []),
                "Alx Kim", "empty roster ⇒ no snapping attempted")
        }

        s.check("SpeakerNameNormalizer.normalize: roster snap rejects ambiguity (no closest-wins-by-order)") { s in
            let result = SpeakerNameNormalizer.normalize("An Lee", roster: ["Ann Lee", "Ana Lee"])
            s.expectEqual(result, "An Lee",
                          "two roster entries tie for closest ⇒ unsnapped, never guessed by list order")
        }

        s.check("SpeakerNameNormalizer.normalize: roster snap skipped below minLengthForSnap") { s in
            s.expectEqual(
                SpeakerNameNormalizer.normalize("Ab", roster: ["Al", "Bo"]),
                "Ab", "2-char input below default minLengthForSnap(4) is never snapped")
        }

        s.check("SpeakerNameNormalizer.normalize: length-aware distance cap") { s in
            // "Sarra" and "Sarah" are both 5 characters at edit distance 2.
            // effectiveDistanceCap = min(maxEditDistance: 2, name.count / 3)
            // = min(2, 5/3) == 1, so distance 2 must NOT snap even though
            // maxEditDistance alone would allow it.
            let result = SpeakerNameNormalizer.normalize("Sarra", roster: ["Sarah"])
            s.expectEqual(result, "Sarra",
                          "distance-2 case exceeds the length-scaled cap(1) for a 5-char name ⇒ unsnapped")
        }
    }

    // MARK: - Speaker attribution (Phase 2): SpeakerLabelCatalog

    static func checkSpeakerLabelCatalog(_ s: CheckSuite) {
        s.check("SpeakerLabelCatalog.match: exact and dot-delimited prefix matches") { s in
            s.expect(SpeakerLabelCatalog.match(bundleID: "com.microsoft.teams2") != nil, "exact teams2 match")
            s.expect(SpeakerLabelCatalog.match(bundleID: "com.microsoft.teams2.modulehost") != nil,
                     "dot-delimited prefix match (helper process)")
            s.expect(SpeakerLabelCatalog.match(bundleID: "com.microsoft.teams") != nil,
                     "classic Teams prefix also present")
        }

        s.check("SpeakerLabelCatalog.match: unknown/uncatalogued app ⇒ nil (SR-23)") { s in
            s.expect(SpeakerLabelCatalog.match(bundleID: "us.zoom.xos") == nil, "Zoom not catalogued yet")
            s.expect(SpeakerLabelCatalog.match(bundleID: "com.microsoft.teams2fake") == nil,
                     "prefix must be dot-delimited, not a raw string prefix")
        }

        s.check("SpeakerLabelCatalog: structural validity of every region") { s in
            for entry in SpeakerLabelCatalog.entries {
                for candidate in entry.candidates {
                    s.expect(candidate.tileRegion.isNormalized, "\(entry.displayName) tileRegion normalized")
                    s.expect(candidate.labelRegion.isNormalized, "\(entry.displayName) labelRegion normalized")
                    if let range = candidate.frameAspectRatioRange {
                        s.expect(range.lowerBound > 0 && range.lowerBound <= range.upperBound,
                                 "\(entry.displayName) frame aspect-ratio range is positive and ordered")
                    }
                    if let size = candidate.requiredFrameSize {
                        s.expect(size.width > 0 && size.height > 0,
                                 "\(entry.displayName) required frame size is positive")
                    }
                    for marker in candidate.activeTileMarkers {
                        s.expect(marker.region.isNormalized, "\(entry.displayName) marker region normalized")
                    }
                }
            }
        }

        s.check("SpeakerLabelCatalog: label regions are not full-frame (SR-5/SR-20 regression guard)") { s in
            let fullFrame = UnitRect(x: 0, y: 0, width: 1, height: 1)
            s.expect(!SpeakerLabelCatalog.teamsDefaults.candidateRegions.isEmpty,
                     "teamsDefaults ships at least one candidate label region")
            for region in SpeakerLabelCatalog.teamsDefaults.candidateRegions {
                s.expect(region != fullFrame, "no candidate label region silently reintroduces whole-frame OCR")
            }
        }

        s.check("SpeakerLabelCatalog: active-tile marker data present and well-formed (SR-20/21)") { s in
            s.expect(!SpeakerLabelCatalog.teamsDefaults.activeTileMarkers.isEmpty,
                     "teamsDefaults ships at least one active-tile marker")
            let hexPattern = try NSRegularExpression(pattern: "^#[0-9A-Fa-f]{6}$")
            for candidate in SpeakerLabelCatalog.teamsDefaults.candidates {
                s.expect(!candidate.activeTileMarkers.isEmpty,
                         "every shipped candidate carries at least one active-tile marker")
                for marker in candidate.activeTileMarkers {
                    s.expect(marker.region.width > 0 && marker.region.height > 0, "marker region is non-degenerate")
                    let range = NSRange(marker.hexColor.startIndex..., in: marker.hexColor)
                    s.expect(hexPattern.firstMatch(in: marker.hexColor, range: range) != nil,
                             "hexColor matches #RRGGBB shape")
                    s.expect(marker.colorTolerance >= 0 && marker.colorTolerance <= 1,
                             "colorTolerance is in [0, 1]")
                }
            }
        }

        s.check("SpeakerLabelCatalog: each candidate's labelRegion is bound within its tileRegion") { s in
            // Phase 5 needs no hard-coded Teams geometry to translate a
            // tile-relative marker for a given label: this proves the
            // catalog itself supplies that binding as data.
            for candidate in SpeakerLabelCatalog.teamsDefaults.candidates {
                s.expect(candidate.tileRegion.contains(candidate.labelRegion),
                         "labelRegion \(candidate.labelRegion) must sit inside tileRegion \(candidate.tileRegion)")
            }
        }

        // MARK: Phase 7 — calibrated 1-on-1 and Gallery candidate regression guard

        s.check("SpeakerLabelCatalog.teamsDefaults: ships measured 1-on-1, three-person, and seven-person candidates") { s in
            let entry = SpeakerLabelCatalog.teamsDefaults
            s.expectEqual(entry.candidates.count, 10,
                          "the catalog contains one full-frame, seven Gallery, and two three-person remote candidates")
            s.expectEqual(entry.layoutRequirement.supportedRemoteParticipantCounts, [1, 2, 6],
                          "the declared remote-participant scopes match all measured layouts")
            guard let oneOnOne = entry.candidates.first else { return }
            s.expectEqual(oneOnOne.tileRegion, UnitRect(x: 0, y: 0, width: 1, height: 1),
                          "the 1-on-1 candidate remains full-frame")
            s.expect(oneOnOne.appliesToFrame(
                width: 1600,
                height: 1000,
                meetingTitle: "Subject :: 1 on 1"
            ),
                     "the 1-on-1 candidate accepts its measured aspect ratio")
            s.expect(!oneOnOne.appliesToFrame(
                width: 1600,
                height: 1000,
                meetingTitle: "Weekly Team Sync"
            ),
                     "the 1-on-1 candidate requires the measured Teams title signature")
            s.expect(!oneOnOne.appliesToFrame(
                width: 2400,
                height: 926,
                meetingTitle: "Subject :: 1 on 1"
            ),
                     "the 1-on-1 candidate rejects Gallery frames")

            let gallery = Array(entry.candidates.dropFirst().prefix(7))
            s.expectEqual(gallery.count, 7, "Gallery contains four top-row and three bottom-row candidates")
            for candidate in gallery {
                s.expect(candidate.appliesToFrame(width: 2400, height: 926),
                         "every Gallery candidate accepts the measured 2400x926 frame")
                s.expect(!candidate.appliesToFrame(width: 1600, height: 656),
                         "every Gallery candidate rejects the measured shared-content aspect ratio")
                s.expect(!candidate.appliesToFrame(width: 1600, height: 617),
                         "every Gallery candidate rejects a proportionally similar resized frame")
            }
            let expectedTilePixels = [
                (0, 158, 600, 336), (600, 158, 600, 336),
                (1200, 158, 600, 336), (1800, 158, 600, 336),
                (300, 495, 600, 337), (900, 495, 600, 337),
                (1500, 495, 600, 337)
            ]
            for (candidate, expected) in zip(gallery, expectedTilePixels) {
                guard let rect = VisionSpeakerAttributor.pixelRect(
                    for: candidate.tileRegion,
                    frameWidth: 2400,
                    frameHeight: 926
                ) else {
                    s.expect(false, "Gallery tile converts to a non-degenerate pixel rect")
                    continue
                }
                s.expectEqual(rect.x, expected.0, "Gallery tile x matches measured geometry")
                s.expectEqual(rect.y, expected.1, "Gallery tile y matches measured geometry")
                s.expectEqual(rect.width, expected.2, "Gallery tile width matches measured geometry")
                s.expectEqual(rect.height, expected.3, "Gallery tile height matches measured geometry")
            }
            guard let firstGallery = gallery.first,
                  let marker = firstGallery.activeTileMarkers.first,
                  let markerRect = VisionSpeakerAttributor.pixelRect(
                    forTileRelative: marker.region,
                    tileRegion: firstGallery.tileRegion,
                    frameWidth: 2400,
                    frameHeight: 926
                  )
            else {
                s.expect(false, "first Gallery marker converts to a pixel rect")
                return
            }
            s.expectEqual(markerRect.x, 5, "Gallery marker starts five pixels inside the tile")
            s.expectEqual(markerRect.y, 159, "Gallery marker samples the measured top-outline row")
            s.expectEqual(markerRect.width, 590, "Gallery marker spans the stable top-outline width")
            s.expectEqual(markerRect.height, 1, "Gallery marker samples exactly one outline row")

            let threePerson = Array(entry.candidates.suffix(2))
            s.expectEqual(threePerson.count, 2, "three-person layout contains only the two remote tiles")
            for candidate in threePerson {
                s.expect(candidate.appliesToFrame(width: 2400, height: 926),
                         "three-person candidate accepts the exact measured capture size")
                s.expect(!candidate.appliesToFrame(width: 1600, height: 617),
                         "three-person candidate rejects resized geometry")
            }
        }

        // MARK: Phase 7 — meeting-window evidence gate (SR-20/21)

        s.check("SpeakerLabelCatalog.AppEntry.matchesLayout: any non-empty resolved Teams meeting title passes; frame signatures select calibrated layouts") { s in
            let entry = SpeakerLabelCatalog.teamsDefaults
            s.expect(entry.matchesLayout(meetingTitle: "TAP Michaela | Nathan :: 1 on 1"),
                     "a calibrated 1-on-1 meeting title matches")
            s.expect(entry.matchesLayout(meetingTitle: "Weekly Team Sync"),
                     "a group meeting title matches so frame-aspect and marker evidence can select Gallery")
            s.expect(!entry.matchesLayout(meetingTitle: ""),
                     "an empty title never matches")
            s.expect(!entry.matchesLayout(meetingTitle: nil),
                     "a nil (unresolved) title never matches — fail closed, never assume the layout applies")
        }
    }

    // MARK: - Speaker attribution (Phase 2): FakeAttributionProvider

    static func checkFakeAttributionProvider(_ s: CheckSuite) async {
        await s.checkAsync("FakeAttributionProvider: scripted exact-window hit returns the scripted result") { s in
            let scriptedResult = SpeakerAttributionResult(displayName: "Alex Kim", confidence: 0.8)
            let provider = FakeAttributionProvider(script: [0...5: scriptedResult])
            let result = await provider.attribution(forThemSegment: 0...5)
            s.expectEqual(result, scriptedResult, "exact-window script match returned verbatim")
        }

        await s.checkAsync("FakeAttributionProvider: unscripted window with no defaultResult returns nil") { s in
            let provider = FakeAttributionProvider()
            let result = await provider.attribution(forThemSegment: 0...5)
            s.expect(result == nil, "no script entry, no default ⇒ nil (NR-6 safe default)")
        }

        await s.checkAsync("FakeAttributionProvider: queriedWindows records every call, in order") { s in
            let provider = FakeAttributionProvider()
            _ = await provider.attribution(forThemSegment: 0...5)
            _ = await provider.attribution(forThemSegment: 5...10)
            let queried = await provider.queriedWindows
            s.expectEqual(queried, [0...5, 5...10], "both queries recorded in call order")
        }

        await s.checkAsync("SpeakerAttributionResult: confidence clamping (DR-3)") { s in
            s.expectEqual(SpeakerAttributionResult(displayName: "Alex Kim", confidence: 1.7).confidence, 1.0,
                          "confidence > 1 clamps to 1.0")
            s.expectEqual(SpeakerAttributionResult(displayName: "Alex Kim", confidence: -0.4).confidence, 0.0,
                          "confidence < 0 clamps to 0.0")
        }

        await s.checkAsync("SpeakerAttributionResult.init: NaN/±infinity confidence clamps to 0, not NaN (Phase 2 impl-review-1 MEDIUM remediation)") { s in
            s.expectEqual(SpeakerAttributionResult(displayName: "X", confidence: .nan).confidence, 0,
                          "NaN confidence clamps to 0 (min/max clamping alone never touches NaN — every NaN comparison is false)")
            s.expectEqual(SpeakerAttributionResult(displayName: "X", confidence: .infinity).confidence, 0,
                          "+infinity confidence clamps to 0 (the safe/conservative bound, not 1)")
            s.expectEqual(SpeakerAttributionResult(displayName: "X", confidence: -.infinity).confidence, 0,
                          "-infinity confidence clamps to 0")
        }
    }

    // MARK: - VisionSpeakerAttributor (Phase 5)

    static func checkVisionSpeakerAttributorThrottle(_ s: CheckSuite) {
        s.check("VisionSpeakerAttributor.shouldSample: first sample (lastSampledTime == nil) always samples") { s in
            s.expect(VisionSpeakerAttributor.shouldSample(frameTime: 0, lastSampledTime: nil, minInterval: 0.75),
                     "no prior sample ⇒ always due")
            s.expect(VisionSpeakerAttributor.shouldSample(frameTime: 100, lastSampledTime: nil, minInterval: 0.75),
                     "no prior sample ⇒ always due, regardless of frameTime's magnitude")
        }

        s.check("VisionSpeakerAttributor.shouldSample: throttle boundary (SR-6)") { s in
            s.expect(!VisionSpeakerAttributor.shouldSample(frameTime: 1.0, lastSampledTime: 0.5, minInterval: 0.75),
                     "gap of 0.5s < 0.75s minInterval ⇒ not due")
            s.expect(VisionSpeakerAttributor.shouldSample(frameTime: 1.25, lastSampledTime: 0.5, minInterval: 0.75),
                     "gap of exactly 0.75s ⇒ due (inclusive boundary)")
            s.expect(VisionSpeakerAttributor.shouldSample(frameTime: 2.0, lastSampledTime: 0.5, minInterval: 0.75),
                     "gap larger than minInterval ⇒ due")
        }

        s.check("VisionSpeakerAttributor.shouldSample: non-finite/negative inputs never sample (plan-review-2 MEDIUM-2)") { s in
            s.expect(!VisionSpeakerAttributor.shouldSample(frameTime: .nan, lastSampledTime: nil, minInterval: 0.75),
                     "NaN frameTime ⇒ never due")
            s.expect(!VisionSpeakerAttributor.shouldSample(frameTime: .infinity, lastSampledTime: nil, minInterval: 0.75),
                     "+infinity frameTime ⇒ never due")
            s.expect(!VisionSpeakerAttributor.shouldSample(frameTime: -1.0, lastSampledTime: nil, minInterval: 0.75),
                     "negative frameTime ⇒ never due, even with no prior sample")
            s.expect(!VisionSpeakerAttributor.shouldSample(frameTime: 5.0, lastSampledTime: nil, minInterval: -1),
                     "negative minInterval ⇒ never due")
            s.expect(VisionSpeakerAttributor.shouldSample(frameTime: 5.0, lastSampledTime: .nan, minInterval: 0.75),
                     "a malformed lastSampledTime (NaN) degrades to 'treat as no prior sample' ⇒ due")
        }
    }

    static func checkVisionSpeakerAttributorGeometry(_ s: CheckSuite) {
        s.check("VisionSpeakerAttributor.pixelRect(for:): in-bounds unit rect converts exactly") { s in
            let rect = VisionSpeakerAttributor.pixelRect(
                for: UnitRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
                frameWidth: 400, frameHeight: 200
            )
            s.expectEqual(rect?.x, 100, "x = 0.25 * 400")
            s.expectEqual(rect?.y, 100, "y = 0.5 * 200")
            s.expectEqual(rect?.width, 200, "width = 0.5 * 400")
            s.expectEqual(rect?.height, 50, "height = 0.25 * 200")
        }

        s.check("VisionSpeakerAttributor.pixelRect(for:): exactly-at-edge (full frame) rect converts exactly") { s in
            let rect = VisionSpeakerAttributor.pixelRect(
                for: UnitRect(x: 0, y: 0, width: 1, height: 1),
                frameWidth: 640, frameHeight: 480
            )
            s.expectEqual(rect?.x, 0, "x at frame origin")
            s.expectEqual(rect?.y, 0, "y at frame origin")
            s.expectEqual(rect?.width, 640, "full width")
            s.expectEqual(rect?.height, 480, "full height")
        }

        s.check("VisionSpeakerAttributor.pixelRect(for:): past-frame-edge rect is clamped, not rejected") { s in
            let rect = VisionSpeakerAttributor.pixelRect(
                for: UnitRect(x: 0.9, y: 0.9, width: 0.3, height: 0.3),
                frameWidth: 100, frameHeight: 100
            )
            s.expectEqual(rect?.x, 90, "min edge unaffected by the past-edge max")
            s.expectEqual(rect?.y, 90, "min edge unaffected by the past-edge max")
            s.expectEqual(rect?.width, 10, "max edge clamped to frameWidth, not 30")
            s.expectEqual(rect?.height, 10, "max edge clamped to frameHeight, not 30")
        }

        s.check("VisionSpeakerAttributor.pixelRect(for:): outward-rounding rule (mid-pixel bounds never truncate inward)") { s in
            // 3 / 7 of a 7px-wide frame falls at pixel 3.0 exactly on the low
            // edge, but width 0.2*7 = 1.4 on the high edge — must ceil to 2,
            // not truncate to 1 (which would silently drop part of the
            // requested region).
            let rect = VisionSpeakerAttributor.pixelRect(
                for: UnitRect(x: 3.0 / 7.0, y: 0, width: 0.2, height: 1.0),
                frameWidth: 7, frameHeight: 10
            )
            s.expectEqual(rect?.x, 3, "min edge floors")
            s.expectEqual(rect?.width, 2, "max edge ceils (0.2 * 7 = 1.4 -> 2), never truncates inward")
        }

        s.check("VisionSpeakerAttributor.pixelRect(for:): degenerate/invalid inputs return nil") { s in
            s.expect(VisionSpeakerAttributor.pixelRect(for: UnitRect(x: 0, y: 0, width: 0, height: 1), frameWidth: 10, frameHeight: 10) == nil,
                     "zero width ⇒ nil")
            s.expect(VisionSpeakerAttributor.pixelRect(for: UnitRect(x: 0, y: 0, width: 1, height: 0), frameWidth: 10, frameHeight: 10) == nil,
                     "zero height ⇒ nil")
            s.expect(VisionSpeakerAttributor.pixelRect(for: UnitRect(x: 1.5, y: 0, width: 0.1, height: 0.1), frameWidth: 10, frameHeight: 10) == nil,
                     "entirely past-frame rect (both edges beyond frameWidth) clamps to zero width ⇒ nil")
            s.expect(VisionSpeakerAttributor.pixelRect(for: UnitRect(x: 0, y: 0, width: 1, height: 1), frameWidth: 0, frameHeight: 10) == nil,
                     "non-positive frameWidth ⇒ nil")
            s.expect(VisionSpeakerAttributor.pixelRect(for: UnitRect(x: .nan, y: 0, width: 1, height: 1), frameWidth: 10, frameHeight: 10) == nil,
                     "non-finite unit field ⇒ nil, never traps")
        }

        s.check("VisionSpeakerAttributor.pixelRect(forTileRelative:tileRegion:): chained conversion against teamsDefaults' first candidate's tile") { s in
            let candidate = SpeakerLabelCatalog.teamsDefaults.candidates[0]
            let rect = VisionSpeakerAttributor.pixelRect(
                forTileRelative: candidate.activeTileMarkers[0].region,
                tileRegion: candidate.tileRegion,
                frameWidth: 1000, frameHeight: 1000
            )
            s.expect(rect != nil, "chained conversion against a real catalog tile + a synthetic marker region succeeds")
            if let rect {
                s.expect(rect.x >= 0 && rect.x + rect.width <= 1000, "marker rect stays within the frame")
                s.expect(rect.y >= 0 && rect.y + rect.height <= 1000, "marker rect stays within the frame")
            }
        }

        s.check("VisionSpeakerAttributor.pixelRect(forTileRelative:tileRegion:): a marker region outside the unit tile is still chained correctly (not silently frame-relative)") { s in
            // A quarter-tile at (0.5, 0.5) with a marker region spanning the
            // tile's full extent (0,0,1,1) must resolve to exactly the
            // tile's own frame-relative bounds — proving the chaining
            // multiplies through the tile's own origin/size rather than
            // treating the marker region as already frame-relative.
            let tileRegion = UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            let markerRegion = UnitRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
            let rect = VisionSpeakerAttributor.pixelRect(
                forTileRelative: markerRegion, tileRegion: tileRegion, frameWidth: 200, frameHeight: 200
            )
            s.expectEqual(rect?.x, 100, "chained x anchors at the tile's own origin, not the frame's")
            s.expectEqual(rect?.y, 100, "chained y anchors at the tile's own origin, not the frame's")
            s.expectEqual(rect?.width, 100, "chained width scales by the tile's own size, not the frame's")
            s.expectEqual(rect?.height, 100, "chained height scales by the tile's own size, not the frame's")
        }
    }

    static func checkVisionSpeakerAttributorCropAndColor(_ s: CheckSuite) {
        /// Builds a synthetic, padded-stride BGRA buffer (`bytesPerRow > width * 4`)
        /// so crop/average tests prove they index by stride, not `width * 4`.
        func makePaddedBuffer(width: Int, height: Int, pad: Int, pixel: (b: UInt8, g: UInt8, r: UInt8)) -> (data: Data, bytesPerRow: Int) {
            let bytesPerRow = width * 4 + pad
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            for row in 0..<height {
                for col in 0..<width {
                    let offset = row * bytesPerRow + col * 4
                    bytes[offset] = pixel.b
                    bytes[offset + 1] = pixel.g
                    bytes[offset + 2] = pixel.r
                    bytes[offset + 3] = 0
                }
            }
            return (Data(bytes), bytesPerRow)
        }

        s.check("VisionSpeakerAttributor.croppedBGRA: byte-exact slice respecting a padded bytesPerRow") { s in
            let (data, bytesPerRow) = makePaddedBuffer(width: 10, height: 10, pad: 8, pixel: (b: 10, g: 20, r: 30))
            // Overwrite a distinct 2x2 sub-region (rows 3-4, cols 5-6) with a
            // different color to prove the crop reads exactly that region,
            // by stride, not `width * 4`.
            var mutableData = data
            mutableData.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                for row in 3...4 {
                    for col in 5...6 {
                        let offset = row * bytesPerRow + col * 4
                        base.storeBytes(of: 200, toByteOffset: offset, as: UInt8.self)
                        base.storeBytes(of: 210, toByteOffset: offset + 1, as: UInt8.self)
                        base.storeBytes(of: 220, toByteOffset: offset + 2, as: UInt8.self)
                    }
                }
            }
            let cropped = VisionSpeakerAttributor.croppedBGRA(
                from: mutableData, frameWidth: 10, frameHeight: 10, bytesPerRow: bytesPerRow,
                rect: (x: 5, y: 3, width: 2, height: 2)
            )
            s.expect(cropped != nil, "valid in-bounds crop succeeds")
            if let cropped {
                s.expectEqual(cropped.width, 2, "cropped width matches requested rect")
                s.expectEqual(cropped.height, 2, "cropped height matches requested rect")
                s.expectEqual(cropped.bytesPerRow, 8, "cropped bytesPerRow is exactly width * 4, no padding carried over")
                s.expectEqual(cropped.data.count, 16, "cropped data is exactly bytesPerRow * height")
                let firstPixel = [UInt8](cropped.data.prefix(3))
                s.expectEqual(firstPixel, [200, 210, 220], "first cropped pixel matches the overwritten sub-region, not the base color")
            }
        }

        s.check("VisionSpeakerAttributor.croppedBGRA: rejects a short/malformed buffer (data.count != bytesPerRow * height)") { s in
            let shortData = Data(repeating: 0, count: 10)
            let cropped = VisionSpeakerAttributor.croppedBGRA(
                from: shortData, frameWidth: 10, frameHeight: 10, bytesPerRow: 40,
                rect: (x: 0, y: 0, width: 1, height: 1)
            )
            s.expect(cropped == nil, "a torn/short buffer is rejected before any read, never read out of bounds")
        }

        s.check("VisionSpeakerAttributor.croppedBGRA: rejects an out-of-bounds rect") { s in
            let (data, bytesPerRow) = makePaddedBuffer(width: 10, height: 10, pad: 0, pixel: (b: 1, g: 2, r: 3))
            s.expect(VisionSpeakerAttributor.croppedBGRA(from: data, frameWidth: 10, frameHeight: 10, bytesPerRow: bytesPerRow, rect: (x: 8, y: 0, width: 5, height: 1)) == nil,
                     "rect extending past frameWidth is rejected")
            s.expect(VisionSpeakerAttributor.croppedBGRA(from: data, frameWidth: 10, frameHeight: 10, bytesPerRow: bytesPerRow, rect: (x: 0, y: 8, width: 1, height: 5)) == nil,
                     "rect extending past frameHeight is rejected")
            s.expect(VisionSpeakerAttributor.croppedBGRA(from: data, frameWidth: 10, frameHeight: 10, bytesPerRow: bytesPerRow, rect: (x: -1, y: 0, width: 1, height: 1)) == nil,
                     "negative rect origin is rejected")
            s.expect(VisionSpeakerAttributor.croppedBGRA(from: data, frameWidth: 10, frameHeight: 10, bytesPerRow: bytesPerRow, rect: (x: 0, y: 0, width: 0, height: 1)) == nil,
                     "zero-width rect is rejected")
        }

        s.check("VisionSpeakerAttributor.parseHexColor: valid and malformed inputs") { s in
            let parsed = VisionSpeakerAttributor.parseHexColor("#6264A7")
            s.expect(parsed != nil, "valid #RRGGBB parses")
            if let parsed {
                s.expect(abs(parsed.r - Double(0x62) / 255.0) < 1e-9, "r channel exact")
                s.expect(abs(parsed.g - Double(0x64) / 255.0) < 1e-9, "g channel exact")
                s.expect(abs(parsed.b - Double(0xA7) / 255.0) < 1e-9, "b channel exact")
            }
            s.expect(VisionSpeakerAttributor.parseHexColor("6264A7") == nil, "missing # is rejected")
            s.expect(VisionSpeakerAttributor.parseHexColor("#6264A") == nil, "wrong length (5 digits) is rejected")
            s.expect(VisionSpeakerAttributor.parseHexColor("#6264AG") == nil, "non-hex character is rejected")
        }

        s.check("VisionSpeakerAttributor.averageBGRAColor: uniform-color buffer returns that exact color") { s in
            let (data, bytesPerRow) = makePaddedBuffer(width: 4, height: 4, pad: 12, pixel: (b: 100, g: 150, r: 200))
            let color = VisionSpeakerAttributor.averageBGRAColor(data: data, width: 4, height: 4, bytesPerRow: bytesPerRow)
            s.expect(color != nil, "uniform buffer averages successfully")
            if let color {
                s.expect(abs(color.b - 100.0 / 255.0) < 1e-9, "uniform b channel exact")
                s.expect(abs(color.g - 150.0 / 255.0) < 1e-9, "uniform g channel exact")
                s.expect(abs(color.r - 200.0 / 255.0) < 1e-9, "uniform r channel exact")
            }
        }

        s.check("VisionSpeakerAttributor.averageBGRAColor: zero-area / malformed inputs return nil") { s in
            s.expect(VisionSpeakerAttributor.averageBGRAColor(data: Data(), width: 0, height: 0, bytesPerRow: 0) == nil,
                     "zero-area region returns nil, never divides by zero")
            let (data, bytesPerRow) = makePaddedBuffer(width: 4, height: 4, pad: 0, pixel: (b: 1, g: 2, r: 3))
            s.expect(VisionSpeakerAttributor.averageBGRAColor(data: data, width: 4, height: 5, bytesPerRow: bytesPerRow) == nil,
                     "geometry mismatch (data.count != bytesPerRow * height) is rejected")
        }

        s.check("VisionSpeakerAttributor.markerMatches: exact/within/outside tolerance, and unparseable hexColor") { s in
            let marker = SpeakerLabelCatalog.ActiveTileMarker(
                region: UnitRect(x: 0, y: 0, width: 1, height: 1),
                hexColor: "#808080",
                colorTolerance: 0.1
            )
            let expected = VisionSpeakerAttributor.parseHexColor("#808080")!
            s.expect(VisionSpeakerAttributor.markerMatches(marker, sampledColor: expected), "exact color match")

            let justWithin = (r: expected.r + 0.09, g: expected.g, b: expected.b)
            s.expect(VisionSpeakerAttributor.markerMatches(marker, sampledColor: justWithin), "just-within-tolerance sample matches")

            let justOutside = (r: expected.r + 0.11, g: expected.g, b: expected.b)
            s.expect(!VisionSpeakerAttributor.markerMatches(marker, sampledColor: justOutside), "just-outside-tolerance sample does not match")

            let malformedMarker = SpeakerLabelCatalog.ActiveTileMarker(
                region: UnitRect(x: 0, y: 0, width: 1, height: 1),
                hexColor: "not-a-color", colorTolerance: 1.0
            )
            s.expect(!VisionSpeakerAttributor.markerMatches(malformedMarker, sampledColor: (r: 0, g: 0, b: 0)),
                     "an unparseable hexColor never matches, even with maximal tolerance")
        }
    }

    static func checkVisionSpeakerAttributorCandidateSelection(_ s: CheckSuite) {
        s.check("VisionSpeakerAttributor.singleActiveCandidate: zero/one/many decision (§0.8, plan-review-2 LOW-1)") { s in
            s.expect(VisionSpeakerAttributor.singleActiveCandidate(matchedCandidateIndices: []) == nil,
                     "zero matches ⇒ nil (no active tile detected)")
            s.expectEqual(VisionSpeakerAttributor.singleActiveCandidate(matchedCandidateIndices: [2]), 2,
                          "exactly one match ⇒ that candidate's index")
            s.expect(VisionSpeakerAttributor.singleActiveCandidate(matchedCandidateIndices: [0, 3]) == nil,
                     "two matches ⇒ nil (ambiguous, never a guess — SR-12)")
            s.expect(VisionSpeakerAttributor.singleActiveCandidate(matchedCandidateIndices: [0, 1, 2, 3, 4]) == nil,
                     "every candidate matching simultaneously ⇒ nil (ambiguous)")
        }
    }

    static func checkVisionSpeakerAttributorSelectName(_ s: CheckSuite) {
        s.check("VisionSpeakerAttributor.selectName: empty input ⇒ nil") { s in
            s.expect(VisionSpeakerAttributor.selectName(from: [], minimumConfidence: 0.4) == nil, "no observations ⇒ nil")
        }

        s.check("VisionSpeakerAttributor.selectName: all-below-threshold ⇒ nil") { s in
            let observations = [
                VisionSpeakerAttributor.OCRObservation(text: "Alex Kim", confidence: 0.2),
                VisionSpeakerAttributor.OCRObservation(text: "Sam Lee", confidence: 0.39),
            ]
            s.expect(VisionSpeakerAttributor.selectName(from: observations, minimumConfidence: 0.4) == nil,
                     "every observation below minimumConfidence ⇒ nil")
        }

        s.check("VisionSpeakerAttributor.selectName: normalization-drops-all ⇒ nil") { s in
            // A single stray character normalizes to nil (DR-4's length floor).
            let observations = [VisionSpeakerAttributor.OCRObservation(text: "•", confidence: 0.9)]
            s.expect(VisionSpeakerAttributor.selectName(from: observations, minimumConfidence: 0.4) == nil,
                     "an observation that normalizes to nil contributes nothing")
        }

        s.check("VisionSpeakerAttributor.selectName: tie-break by highest confidence") { s in
            let observations = [
                VisionSpeakerAttributor.OCRObservation(text: "Alex Kim", confidence: 0.6),
                VisionSpeakerAttributor.OCRObservation(text: "Sam Lee", confidence: 0.9),
            ]
            let result = VisionSpeakerAttributor.selectName(from: observations, minimumConfidence: 0.4)
            s.expectEqual(result?.displayName, "Sam Lee", "higher-confidence observation wins")
            s.expectEqual(result?.confidence, 0.9, "winning confidence carried through")
        }

        s.check("VisionSpeakerAttributor.selectName: exact confidence tie breaks by lexicographically smallest name") { s in
            let observations = [
                VisionSpeakerAttributor.OCRObservation(text: "Zara Nolan", confidence: 0.8),
                VisionSpeakerAttributor.OCRObservation(text: "Alex Kim", confidence: 0.8),
            ]
            let result = VisionSpeakerAttributor.selectName(from: observations, minimumConfidence: 0.4)
            s.expectEqual(result?.displayName, "Alex Kim", "lexicographically smallest name wins an exact confidence tie")
        }

        s.check("VisionSpeakerAttributor.selectName: roster-snap interaction (passthrough to SpeakerNameNormalizer)") { s in
            let observations = [VisionSpeakerAttributor.OCRObservation(text: "Alx Kim", confidence: 0.9)]
            let result = VisionSpeakerAttributor.selectName(from: observations, minimumConfidence: 0.4, roster: ["Alex Kim"])
            s.expectEqual(result?.displayName, "Alex Kim", "roster snap applies via the normalize passthrough")
        }
    }

    static func checkVisionSpeakerAttributorAdvance(_ s: CheckSuite) {
        s.check("VisionSpeakerAttributor.advance: first-ever detection anchors via fallbackLookback") { s in
            let step = VisionSpeakerAttributor.advance(
                open: nil, frameTime: 5.0, outcome: .detected(name: "Alex", confidence: 0.8),
                maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expectEqual(step.nextOpen?.name, "Alex", "state anchors on the detected name")
            s.expectEqual(step.nextOpen?.start, 4.25, "start anchored fallbackLookback seconds back")
            s.expectEqual(step.nextOpen?.end, 5.0, "end at the sample's own frameTime")
            s.expectEqual(step.recording?.range, 4.25...5.0, "recorded range matches the anchored interval")
            s.expectEqual(step.recording?.name, "Alex", "recorded name matches")
        }

        s.check("VisionSpeakerAttributor.advance: zero-lookback/zero-duration first detection anchors state but records nothing") { s in
            let step = VisionSpeakerAttributor.advance(
                open: nil, frameTime: 0.0, outcome: .detected(name: "Alex", confidence: 0.8),
                maxGap: 2.5, fallbackLookback: 0.0
            )
            s.expect(step.recording == nil, "a zero-length range at frameTime 0 is never recorded")
            s.expectEqual(step.nextOpen?.start, 0.0, "state still anchors so a later same-speaker sample extends from here")
            s.expectEqual(step.nextOpen?.end, 0.0, "state end matches frameTime")
        }

        s.check("VisionSpeakerAttributor.advance: same-speaker continuation within maxGap extends the open interval") { s in
            let open = VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.8, start: 4.25, end: 5.0)
            let step = VisionSpeakerAttributor.advance(
                open: open, frameTime: 6.0, outcome: .detected(name: "Alex", confidence: 0.85),
                maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expectEqual(step.nextOpen?.start, 4.25, "start unchanged — this is an extension, not a fresh interval")
            s.expectEqual(step.nextOpen?.end, 6.0, "end advances to the new frameTime")
            s.expectEqual(step.recording?.range, 5.0...6.0, "recorded range covers only the newly-extended span")
        }

        s.check("VisionSpeakerAttributor.advance: same-speaker gap exceeding maxGap starts fresh, never bridges (HIGH-3)") { s in
            let open = VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.8, start: 4.25, end: 5.0)
            let step = VisionSpeakerAttributor.advance(
                open: open, frameTime: 9.0, outcome: .detected(name: "Alex", confidence: 0.8), // gap of 4.0 > maxGap 2.5
                maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expectEqual(step.nextOpen?.start, 8.25, "fresh interval anchored fallbackLookback back from frameTime, not from the stale open.end")
            s.expectEqual(step.recording?.range, 8.25...9.0, "recorded range never bridges the excessive gap")
        }

        s.check("VisionSpeakerAttributor.advance: speaker change starts fresh, clamped to the prior open interval's end — never overlaps it (Phase 7 §3d fix, Phase 5 impl-review-1 MEDIUM-2)") { s in
            let open = VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.8, start: 4.25, end: 5.0)
            let step = VisionSpeakerAttributor.advance(
                open: open, frameTime: 5.5, outcome: .detected(name: "Sam", confidence: 0.9),
                maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expectEqual(step.nextOpen?.name, "Sam", "new speaker replaces the open interval")
            // Unclamped fallbackLookback anchor would be `5.5 - 0.75 == 4.75`
            // — *before* Alex's `open.end == 5.0`, which would overlap
            // Alex's already-recorded interval with Sam's new one (a
            // wrong-name risk, not merely "no attribution" — SR-12). The fix
            // clamps `start` to `max(4.75, open.end) == 5.0` instead.
            s.expectEqual(step.nextOpen?.start, 5.0, "fresh interval for a different speaker is clamped to the prior open interval's end, never anchored earlier than it")
            s.expectEqual(step.recording?.range, 5.0...5.5, "recorded range starts exactly at Alex's prior open.end — no overlap with Alex's already-recorded interval")
        }

        s.check("VisionSpeakerAttributor.advance: .noSignal closes the open interval, never bridged by a later detection") { s in
            let open = VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.8, start: 4.25, end: 5.0)
            let closed = VisionSpeakerAttributor.advance(
                open: open, frameTime: 5.5, outcome: .noSignal, maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expect(closed.nextOpen == nil, ".noSignal always closes the open interval")
            s.expect(closed.recording == nil, ".noSignal never records")

            // A later detection, even of the same speaker within what would
            // have been maxGap of Alex's original open.end, must not bridge
            // back through the closed gap — it takes the fresh-start branch.
            let next = VisionSpeakerAttributor.advance(
                open: closed.nextOpen, frameTime: 6.0, outcome: .detected(name: "Alex", confidence: 0.8),
                maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expectEqual(next.nextOpen?.start, 5.25, "fresh interval anchored from the new sample, never from the pre-noSignal open.end (4.25)")
        }

        s.check("VisionSpeakerAttributor.advance: out-of-order/duplicate timestamp is dropped, state unchanged") { s in
            let open = VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.8, start: 4.25, end: 5.0)
            let sameTime = VisionSpeakerAttributor.advance(
                open: open, frameTime: 5.0, outcome: .detected(name: "Alex", confidence: 0.9), maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expectEqual(sameTime.nextOpen, open, "duplicate timestamp (frameTime == open.end) leaves state unchanged")
            s.expect(sameTime.recording == nil, "duplicate timestamp never records")

            let outOfOrder = VisionSpeakerAttributor.advance(
                open: open, frameTime: 4.5, outcome: .detected(name: "Alex", confidence: 0.9), maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expectEqual(outOfOrder.nextOpen, open, "an earlier-than-open.end timestamp leaves state unchanged")
            s.expect(outOfOrder.recording == nil, "out-of-order timestamp never records")
        }

        s.check("VisionSpeakerAttributor.advance: every recording produced has a strictly positive-length range") { s in
            let cases: [(open: VisionSpeakerAttributor.OpenInterval?, frameTime: Double)] = [
                (nil, 5.0),
                (VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.8, start: 0, end: 1), 2.0),
                (VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.8, start: 0, end: 1), 10.0),
            ]
            for testCase in cases {
                let step = VisionSpeakerAttributor.advance(
                    open: testCase.open, frameTime: testCase.frameTime, outcome: .detected(name: "Alex", confidence: 0.8),
                    maxGap: 2.5, fallbackLookback: 0.75
                )
                if let recording = step.recording {
                    s.expect(recording.range.lowerBound < recording.range.upperBound,
                             "recorded range at frameTime \(testCase.frameTime) is strictly positive-length")
                }
            }
        }

        s.check("VisionSpeakerAttributor.advance: non-finite/negative frameTime is a no-op, never corrupts state (plan-review-2 MEDIUM-2)") { s in
            let open = VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.8, start: 4.25, end: 5.0)

            let negativeTime = VisionSpeakerAttributor.advance(
                open: open, frameTime: -1.0, outcome: .detected(name: "Sam", confidence: 0.9), maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expectEqual(negativeTime.nextOpen, open, "negative frameTime leaves openInterval state exactly unchanged")
            s.expect(negativeTime.recording == nil, "negative frameTime never records, even for a nominally-valid detection")

            let nanTime = VisionSpeakerAttributor.advance(
                open: open, frameTime: .nan, outcome: .detected(name: "Sam", confidence: 0.9), maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expectEqual(nanTime.nextOpen, open, "NaN frameTime leaves state unchanged")
            s.expect(nanTime.recording == nil, "NaN frameTime never records")

            // Also proves a negative frameTime can never seed a fresh
            // interval from a nil starting state (no pre-session interval
            // can ever be created).
            let negativeFromNil = VisionSpeakerAttributor.advance(
                open: nil, frameTime: -5.0, outcome: .detected(name: "Alex", confidence: 0.8), maxGap: 2.5, fallbackLookback: 0.75
            )
            s.expect(negativeFromNil.nextOpen == nil, "negative frameTime from a nil open state creates no interval")
            s.expect(negativeFromNil.recording == nil, "negative frameTime from a nil open state records nothing")

            let negativeMaxGap = VisionSpeakerAttributor.advance(
                open: open, frameTime: 6.0, outcome: .detected(name: "Alex", confidence: 0.8), maxGap: -1, fallbackLookback: 0.75
            )
            s.expectEqual(negativeMaxGap.nextOpen, open, "negative maxGap is malformed input ⇒ no-op")
            s.expect(negativeMaxGap.recording == nil, "negative maxGap never records")
        }
    }

    static func checkVisionSpeakerAttributorCatalogGate(_ s: CheckSuite) async {
        await s.checkAsync("VisionSpeakerAttributor: unknown bundle ID never starts consumption, attribution always nil (SR-23)") { s in
            let (frames, continuation) = AsyncStream<CapturedFrame>.makeStream()
            let attributor = VisionSpeakerAttributor(bundleID: "com.unknown.app", meetingTitle: "TAP Michaela | Nathan :: 1 on 1", frames: frames)
            continuation.finish() // nothing ever consumes this stream in this path — safe to finish immediately
            let result = await attributor.attribution(forThemSegment: 0...5)
            s.expect(result == nil, "unmatched bundle ID ⇒ empty timeline ⇒ nil, with no frame ever read, even with a matching title")
        }

        await s.checkAsync("VisionSpeakerAttributor: known+validated app with an empty meeting title never starts consumption, attribution always nil") { s in
            s.expect(SpeakerLabelCatalog.teamsDefaults.markersValidated,
                     "precondition: teamsDefaults is validated")
            let (frames, continuation) = AsyncStream<CapturedFrame>.makeStream()
            let attributor = VisionSpeakerAttributor(bundleID: "com.microsoft.teams", meetingTitle: "", frames: frames)
            continuation.finish()
            let result = await attributor.attribution(forThemSegment: 0...5)
            s.expect(result == nil, "empty title ⇒ empty timeline ⇒ nil, structurally, not by convention")
        }

        await s.checkAsync("VisionSpeakerAttributor: known+validated app with a nil meeting title never starts consumption (fail closed, never assume the layout)") { s in
            let (frames, continuation) = AsyncStream<CapturedFrame>.makeStream()
            let attributor = VisionSpeakerAttributor(bundleID: "com.microsoft.teams", meetingTitle: nil, frames: frames)
            continuation.finish()
            let result = await attributor.attribution(forThemSegment: 0...5)
            s.expect(result == nil, "an unresolved (nil) meeting title never matches any layoutRequirement ⇒ nil")
        }

        await s.checkAsync("VisionSpeakerAttributor: stop() is idempotent and safe with no consumption task ever started") { s in
            let (frames, continuation) = AsyncStream<CapturedFrame>.makeStream()
            let attributor = VisionSpeakerAttributor(bundleID: "com.unknown.app", meetingTitle: nil, frames: frames)
            continuation.finish()
            await attributor.stop()
            await attributor.stop()
            let result = await attributor.attribution(forThemSegment: 0...5)
            s.expect(result == nil, "calling stop() repeatedly on a never-started attributor is harmless")
        }
    }

    /// Precise layering audit (plan-review-2 LOW-2): `Vision` must be new
    /// only in `VisionSpeakerAttributor.swift`; `CoreGraphics` legitimately
    /// already appears in `ScreenCaptureKitSource.swift` (Phase 4) — a
    /// blanket "CoreGraphics only in one file" wording would false-fail
    /// against that pre-existing, correct import.
    static func checkVisionSpeakerAttributorLayeringAudit(_ s: CheckSuite) {
        s.check("Vision is imported only by VisionSpeakerAttributor.swift; CoreGraphics's pre-existing use elsewhere is unaffected (SR-2/NR-2)") { s in
            let platformDir = URL(fileURLWithPath: "Sources/AlembicKit/Platform/macOS")
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: platformDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                s.expect(false, "Vision layering audit: cannot enumerate Sources/AlembicKit/Platform/macOS/")
                return
            }

            var filesImportingVision: [String] = []
            var auditedCount = 0
            for case let url as URL in enumerator {
                guard url.pathExtension == "swift" else { continue }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                auditedCount += 1
                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("import Vision") {
                        filesImportingVision.append(url.lastPathComponent)
                    }
                }
            }
            s.expect(auditedCount > 0, "Vision layering audit checked at least one file")
            s.expectEqual(filesImportingVision, ["VisionSpeakerAttributor.swift"],
                          "Vision is imported by exactly one file, VisionSpeakerAttributor.swift")

            // Top-level AlembicKit (non-Platform) must never import Vision
            // either — reuses the same non-recursive top-level scope as
            // checkFoundationOnlyTopLevelAudit.
            let topLevelDir = URL(fileURLWithPath: "Sources/AlembicKit")
            guard let topEnumerator = fm.enumerator(
                at: topLevelDir, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else {
                s.expect(false, "Vision layering audit: cannot enumerate top-level Sources/AlembicKit/")
                return
            }
            for case let url as URL in topEnumerator {
                guard url.pathExtension == "swift" else { continue }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                s.expect(!content.contains("import Vision"), "top-level \(url.lastPathComponent) must never import Vision")
            }
        }
    }

    // MARK: - MeetingDetectionPolicy

    static func checkMeetingDetectionPolicy(_ s: CheckSuite) {
        s.check("MeetingDetectionPolicy: idle stays idle on false signal") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4.0, endDebounce: 8.0)
            s.expectEqual(policy.processSample(isInCall: false, now: 0), .idle,
                          "false on idle → stays idle")
            s.expectEqual(policy.processSample(isInCall: false, now: 100), .idle,
                          "repeated false on idle → still idle")
        }

        s.check("MeetingDetectionPolicy: no transition before startDebounce") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4.0, endDebounce: 8.0)
            _ = policy.processSample(isInCall: true, now: 0)
            let phase = policy.processSample(isInCall: true, now: 3.99)
            s.expectEqual(phase, .confirming, "just under debounce → still confirming")
        }

        s.check("MeetingDetectionPolicy: idle → confirming → active on sustained signal") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4.0, endDebounce: 8.0)
            s.expectEqual(policy.processSample(isInCall: true, now: 0), .confirming,
                          "first signal → confirming")
            s.expectEqual(policy.processSample(isInCall: true, now: 2), .confirming,
                          "sustained, under debounce → still confirming")
            s.expectEqual(policy.processSample(isInCall: true, now: 4), .active,
                          "exactly at startDebounce → active")
        }

        s.check("MeetingDetectionPolicy: false signal during confirming resets to idle") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4.0, endDebounce: 8.0)
            _ = policy.processSample(isInCall: true, now: 0)
            s.expectEqual(policy.phase, .confirming, "entered confirming")
            s.expectEqual(policy.processSample(isInCall: false, now: 2), .idle,
                          "false during confirming → back to idle")
        }

        s.check("MeetingDetectionPolicy: active → ending → idle on sustained absence") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4.0, endDebounce: 8.0)
            _ = policy.processSample(isInCall: true, now: 0)
            _ = policy.processSample(isInCall: true, now: 4)  // → active
            s.expectEqual(policy.phase, .active, "confirmed active")

            _ = policy.processSample(isInCall: false, now: 5)  // → ending
            s.expectEqual(policy.phase, .ending, "signal dropped → ending")

            _ = policy.processSample(isInCall: false, now: 12.99)  // 7.99s < endDebounce(8)
            s.expectEqual(policy.phase, .ending, "still ending just before endDebounce")

            s.expectEqual(policy.processSample(isInCall: false, now: 13), .idle,
                          "exactly at endDebounce → idle")
        }

        s.check("MeetingDetectionPolicy: re-enter call during ending → back to active") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4.0, endDebounce: 8.0)
            _ = policy.processSample(isInCall: true, now: 0)
            _ = policy.processSample(isInCall: true, now: 4)   // active
            _ = policy.processSample(isInCall: false, now: 5)  // ending
            s.expectEqual(policy.phase, .ending, "in ending phase")

            s.expectEqual(policy.processSample(isInCall: true, now: 7), .active,
                          "signal returns during ending → active (no new start-debounce)")
        }

        s.check("MeetingDetectionPolicy: reset() returns to idle from any phase") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4.0, endDebounce: 8.0)
            _ = policy.processSample(isInCall: true, now: 0)
            _ = policy.processSample(isInCall: true, now: 5)   // active
            s.expectEqual(policy.phase, .active, "confirmed active before reset")

            policy.reset()
            s.expectEqual(policy.phase, .idle, "reset() → idle")

            // Verify a fresh debounce is required after reset.
            s.expectEqual(policy.processSample(isInCall: true, now: 10), .confirming,
                          "confirming after reset (fresh start-debounce required)")
        }

        s.check("MeetingDetectionPolicy: multiple full cycles work correctly") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4.0, endDebounce: 8.0)

            // Cycle 1
            _ = policy.processSample(isInCall: true, now: 0)
            _ = policy.processSample(isInCall: true, now: 4)   // active at t=4
            _ = policy.processSample(isInCall: false, now: 5)  // ending
            _ = policy.processSample(isInCall: false, now: 13) // idle

            // Cycle 2
            _ = policy.processSample(isInCall: true, now: 20)  // confirming
            s.expectEqual(policy.processSample(isInCall: true, now: 24), .active,
                          "second cycle active at t=24")
        }
    }

    // MARK: - Phase 4 (detectInCall): conflict resolution + title confirmation

    /// Tests for `MeetingAppCatalog.detectInCall` — the cases that go beyond what
    /// the existing `isInCall` / `match` checks already cover.
    static func checkDetectInCall(_ s: CheckSuite) {

        func state(_ bundleID: String, input: Bool = false, output: Bool = false) -> AudioProcessState {
            AudioProcessState(pid: 1, bundleID: bundleID, isRunningInput: input, isRunningOutput: output)
        }

        // --- Multi-app conflict: output-active app wins ---
        s.check("detectInCall conflict: output-active app wins over input-only app") { s in
            let states = [
                state("com.microsoft.teams2", input: true, output: false),  // Teams: input only → NOT a candidate (requiresOutput)
                state("com.tinyspeck.slackmacgap", input: true, output: true),  // Slack: both → candidate
            ]
            let match = MeetingAppCatalog.detectInCall(processStates: states)
            s.expect(match?.app.displayName == "Slack", "Slack (sole candidate, has output) wins; Teams excluded by requiresOutput")
        }

        // --- Multi-app conflict: tie (both have output) → nil ---
        s.check("detectInCall conflict: tied output → nil (do not guess)") { s in
            let states = [
                state("com.microsoft.teams2", input: true, output: true),
                state("com.tinyspeck.slackmacgap", input: true, output: true),
            ]
            let match = MeetingAppCatalog.detectInCall(processStates: states)
            s.expect(match == nil, "tied output → no detection to avoid wrong auto-start")
        }

        // --- requiresTitleConfirmation unlocked by matching hint ---
        s.check("detectInCall: requiresTitleConfirmation unlocked when title hint present") { s in
            let states = [state("com.google.Chrome.helper", input: true, output: true)]
            let confirmed: Set<String> = ["Meet – Google Meet"]
            let match = MeetingAppCatalog.detectInCall(processStates: states, confirmedTitles: confirmed)
            s.expect(match != nil, "Chrome helper + 'Meet –' title hint → detection unlocked")
            s.expect(match?.app.displayName == "Google Meet (browser)", "matched Google Meet browser entry")
        }

        // --- requiresTitleConfirmation locked without hint ---
        s.check("detectInCall: requiresTitleConfirmation blocks detection without matching title") { s in
            let states = [state("com.google.Chrome.helper", input: true, output: true)]
            let match = MeetingAppCatalog.detectInCall(processStates: states)
            s.expect(match == nil, "Chrome helper alone (no title) → no detection")
        }

        // --- requiresOutput guard: Zoom with input only → no detection ---
        s.check("detectInCall: requiresOutput blocks Zoom input-only (Settings audio preview)") { s in
            let states = [state("us.zoom.xos", input: true, output: false)]
            let match = MeetingAppCatalog.detectInCall(processStates: states)
            s.expect(match == nil, "Zoom input-only → no detection (mic preview guard)")
        }

        // --- requiresOutput guard: Zoom with output → detection ---
        s.check("detectInCall: requiresOutput allows Zoom when output is active") { s in
            let states = [state("us.zoom.xos", input: true, output: true)]
            let match = MeetingAppCatalog.detectInCall(processStates: states)
            s.expect(match?.app.displayName == "Zoom", "Zoom with output → detected")
        }

        // --- Real live capture: Zoom main app (output) alongside us.zoom.caphost
        // helper. caphost is a sibling bundle (not a child of us.zoom.xos) and
        // must be ignored; the main app still yields a Zoom detection. ---
        s.check("detectInCall: Zoom detected with us.zoom.caphost helper present") { s in
            let states = [
                state("us.zoom.caphost", input: false, output: false),
                state("us.zoom.xos", input: true, output: true),
            ]
            let match = MeetingAppCatalog.detectInCall(processStates: states)
            s.expectEqual(match?.canonicalBundlePrefix, "us.zoom.xos",
                          "Zoom main app detected; caphost sibling ignored")
        }

        // --- requiresOutput guard: Teams with input only → no detection ---
        s.check("detectInCall: requiresOutput blocks Teams input-only") { s in
            let states = [state("com.microsoft.teams2", input: true, output: false)]
            let match = MeetingAppCatalog.detectInCall(processStates: states)
            s.expect(match == nil, "Teams input-only → no detection (requiresOutput guard)")
        }

        // --- requiresOutput guard: Teams with output → detection ---
        s.check("detectInCall: requiresOutput allows Teams when output is active") { s in
            let states = [state("com.microsoft.teams2", input: true, output: true)]
            let match = MeetingAppCatalog.detectInCall(processStates: states)
            s.expect(match?.app.displayName == "Microsoft Teams", "Teams with output → detected")
        }

        // --- Helper / renderer bundle IDs resolve to canonical parent prefix ---
        s.check("detectInCall: Teams helper bundle resolves to canonical parent prefix") { s in
            let states = [state("com.microsoft.teams2.modulehost", input: true, output: true)]
            let match = MeetingAppCatalog.detectInCall(processStates: states)
            s.expect(match?.canonicalBundlePrefix == "com.microsoft.teams2",
                     "teams2.modulehost maps to com.microsoft.teams2")
        }

        // --- Tiers: Teams output-only is broadcast evidence, not interactive ---
        s.check("detectCandidates: Teams output-only (notification chime) → broadcastCandidate") { s in
            let chime = [state("com.microsoft.teams2", input: false, output: true)]
            let candidates = MeetingAppCatalog.detectCandidates(processStates: chime)
            s.expectEqual(candidates.count, 1, "one candidate")
            s.expectEqual(candidates.first?.tier, .broadcastCandidate,
                          "output-only Teams is broadcast evidence, never interactive")

            let call = [state("com.microsoft.teams2", input: true, output: true)]
            s.expectEqual(MeetingAppCatalog.detectCandidates(processStates: call).first?.tier,
                          .interactive, "input+output Teams is interactive")
        }

        // --- Tiers: input/output split across helper processes still interactive ---
        s.check("detectCandidates: Teams gate satisfied across separate family processes") { s in
            let split = [
                state("com.microsoft.teams2", input: true, output: false),
                AudioProcessState(pid: 2, bundleID: "com.microsoft.teams2.modulehost",
                                  isRunningInput: false, isRunningOutput: true),
            ]
            s.expectEqual(MeetingAppCatalog.detectCandidates(processStates: split).first?.tier,
                          .interactive, "input on parent + output on helper → interactive")
        }

        // --- Tiers: Slack is never a broadcast candidate ---
        s.check("detectCandidates: Slack output-only yields no candidate (not broadcastEligible)") { s in
            let chime = [state("com.tinyspeck.slackmacgap", input: false, output: true)]
            s.expect(MeetingAppCatalog.detectCandidates(processStates: chime).isEmpty,
                     "Slack notification sound → no candidate at all")
        }

        // --- resolve: interactive outranks broadcast ---
        s.check("resolve: interactive candidate outranks broadcast candidate") { s in
            let states = [
                state("com.microsoft.teams2", input: false, output: true),      // broadcast evidence
                AudioProcessState(pid: 2, bundleID: "us.zoom.xos",
                                  isRunningInput: true, isRunningOutput: true), // interactive
            ]
            let winner = MeetingAppCatalog.resolve(MeetingAppCatalog.detectCandidates(processStates: states))
            s.expectEqual(winner?.match.app.displayName, "Zoom",
                          "Zoom interactive beats Teams broadcast evidence")

            // Two broadcast-only candidates → ambiguous, no guess.
            let twoBroadcasts = [
                state("com.microsoft.teams2", input: false, output: true),
                AudioProcessState(pid: 2, bundleID: "us.zoom.xos",
                                  isRunningInput: false, isRunningOutput: true),
            ]
            s.expect(MeetingAppCatalog.resolve(MeetingAppCatalog.detectCandidates(processStates: twoBroadcasts)) == nil,
                     "two broadcast candidates → nil (do not guess)")
        }
    }

    // MARK: - Detection tiers: policy-level checks

    static func checkDetectionTierPolicy(_ s: CheckSuite) {
        s.check("MeetingDetectionPolicy: broadcast signal needs broadcastStartDebounce") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4, broadcastStartDebounce: 30, endDebounce: 3)
            s.expectEqual(policy.processSample(signal: .broadcast, now: 0), .confirming, "broadcast → confirming")
            // A chime's output linger (10–15s) dies well inside the window.
            s.expectEqual(policy.processSample(signal: .broadcast, now: 15), .confirming, "15s: still confirming")
            s.expectEqual(policy.processSample(signal: .none, now: 16), .idle, "linger ended → idle, never active")

            // Sustained broadcast (a real town hall) confirms at 30s.
            s.expectEqual(policy.processSample(signal: .broadcast, now: 20), .confirming, "re-enter confirming")
            s.expectEqual(policy.processSample(signal: .broadcast, now: 49), .confirming, "29s elapsed: not yet")
            s.expectEqual(policy.processSample(signal: .broadcast, now: 50), .active, "30s elapsed → active")
        }

        s.check("MeetingDetectionPolicy: broadcast→interactive upgrade keeps elapsed time") { s in
            var policy = MeetingDetectionPolicy(startDebounce: 4, broadcastStartDebounce: 30, endDebounce: 3)
            s.expectEqual(policy.processSample(signal: .broadcast, now: 0), .confirming, "broadcast confirming")
            s.expectEqual(policy.processSample(signal: .broadcast, now: 3), .confirming, "3s: below both thresholds")
            // Mic joins in (user was let in from the lobby): interactive
            // threshold (4s) is already elapsed at 5s → active immediately.
            s.expectEqual(policy.processSample(signal: .interactive, now: 5), .active, "upgrade confirms against 4s threshold")
        }

        s.check("MeetingDetectionPolicy: Bool shim maps true to interactive") { s in
            var viaShim = MeetingDetectionPolicy(startDebounce: 4, endDebounce: 3)
            var viaSignal = MeetingDetectionPolicy(startDebounce: 4, endDebounce: 3)
            for (t, inCall) in [(0.0, true), (4.0, true), (5.0, false), (9.0, false)] {
                let a = viaShim.processSample(isInCall: inCall, now: t)
                let b = viaSignal.processSample(signal: inCall ? .interactive : .none, now: t)
                s.expectEqual(a, b, "shim and signal agree at t=\(t)")
            }
        }
    }

    // MARK: - Phase 4 (MeetingDetector): synchronous tick-based integration

    /// Tests `MeetingDetector.tick()` directly (synchronous, no async needed).
    ///
    /// Uses zero-length debounces so state transitions are immediate:
    /// - idle → confirming on the first in-call tick
    /// - confirming → active on the second in-call tick (elapsed ≥ 0)
    /// - active → ending on first no-call tick
    /// - ending → idle on second no-call tick (elapsed ≥ 0)
    static func checkMeetingDetector(_ s: CheckSuite) {

        func teams(output: Bool = true) -> [AudioProcessState] {
            [AudioProcessState(pid: 200, bundleID: "com.microsoft.teams2",
                               isRunningInput: true, isRunningOutput: output)]
        }

        // --- 1. Full idle → active → idle cycle ---
        s.check("MeetingDetector tick: full idle→active→idle cycle with zero debounce") { s in
            let det = MeetingDetector(
                snapshotProvider: { [] },
                policy: MeetingDetectionPolicy(startDebounce: 0, endDebounce: 0)
            )

            // tick 1: idle → confirming (no emission)
            let r1 = det.tick(snapshot: teams(), now: 0)
            s.expect(r1 == nil, "idle→confirming: no change emitted")

            // tick 2: confirming → active (Detection emitted)
            let r2 = det.tick(snapshot: teams(), now: 0)
            guard let change2 = r2 else { s.expect(false, "active: expected change emitted"); return }
            guard let detection = change2 else { s.expect(false, "active: expected non-nil Detection"); return }
            s.expectEqual(detection.app.displayName, "Microsoft Teams", "detected Teams")
            s.expectEqual(detection.canonicalBundlePrefix, "com.microsoft.teams2", "canonical prefix")
            s.expect(detection.hasOutput, "output present → hasOutput true")

            // tick 3: still active → no change
            let r3 = det.tick(snapshot: teams(), now: 1)
            s.expect(r3 == nil, "still active: no duplicate emission")

            // tick 4: active → ending (no emission yet)
            let r4 = det.tick(snapshot: [], now: 2)
            s.expect(r4 == nil, "ending: no change until end-debounce elapses")

            // tick 5: ending → idle (nil emitted = call ended)
            let r5 = det.tick(snapshot: [], now: 2)
            guard let change5 = r5 else { s.expect(false, "idle: expected change emitted"); return }
            s.expect(change5 == nil, "nil emitted = call ended")
        }

        // --- 2. hasOutput reflects process state ---
        s.check("MeetingDetector tick: hasOutput true when output process present") { s in
            let det = MeetingDetector(
                snapshotProvider: { [] },
                policy: MeetingDetectionPolicy(startDebounce: 0, endDebounce: 0)
            )
            _ = det.tick(snapshot: teams(output: true), now: 0)  // confirming
            let r = det.tick(snapshot: teams(output: true), now: 0)  // active
            guard let d = r?.flatMap({ $0 }) else { s.expect(false, "expected Detection"); return }
            s.expect(d.hasOutput, "output process present → hasOutput true")
        }

        // --- 3. Multi-app tie → no detection ---
        s.check("MeetingDetector tick: multi-app tied output → no detection") { s in
            let det = MeetingDetector(
                snapshotProvider: { [] },
                policy: MeetingDetectionPolicy(startDebounce: 0, endDebounce: 0)
            )
            let tied: [AudioProcessState] = [
                AudioProcessState(pid: 1, bundleID: "com.microsoft.teams2",
                                  isRunningInput: true, isRunningOutput: true),
                AudioProcessState(pid: 2, bundleID: "com.tinyspeck.slackmacgap",
                                  isRunningInput: true, isRunningOutput: true),
            ]
            _ = det.tick(snapshot: tied, now: 0)
            let r = det.tick(snapshot: tied, now: 0)
            s.expect(r == nil, "tied output → no Detection (policy stays confirming/idle)")
        }

        // --- 4. Zoom without output → no detection ---
        s.check("MeetingDetector tick: Zoom without output stays idle (requiresOutput guard)") { s in
            let det = MeetingDetector(
                snapshotProvider: { [] },
                policy: MeetingDetectionPolicy(startDebounce: 0, endDebounce: 0)
            )
            let zoomInputOnly = [AudioProcessState(pid: 3, bundleID: "us.zoom.xos",
                                                   isRunningInput: true, isRunningOutput: false)]
            _ = det.tick(snapshot: zoomInputOnly, now: 0)
            let r = det.tick(snapshot: zoomInputOnly, now: 0)
            s.expect(r == nil, "Zoom input-only → no detection")
        }

        // --- 5. Reset clears state ---
        s.check("MeetingDetector reset clears last-emitted state so cycle repeats") { s in
            let det = MeetingDetector(
                snapshotProvider: { [] },
                policy: MeetingDetectionPolicy(startDebounce: 0, endDebounce: 0)
            )
            _ = det.tick(snapshot: teams(), now: 0)   // confirming
            _ = det.tick(snapshot: teams(), now: 0)   // active (Detection emitted)

            det.reset()

            _ = det.tick(snapshot: teams(), now: 10)  // confirming again (after reset)
            let r = det.tick(snapshot: teams(), now: 10) // active again
            guard let change = r else { s.expect(false, "after reset: expected re-emission"); return }
            s.expect(change != nil, "Detection re-emitted after reset")
        }

        // --- 6. Stickiness: another app's audio can't end an active session ---
        s.check("MeetingDetector tick: Slack chime during active Teams call does not end/split it") { s in
            let det = MeetingDetector(
                snapshotProvider: { [] },
                policy: MeetingDetectionPolicy(startDebounce: 0, endDebounce: 0)
            )
            _ = det.tick(snapshot: teams(), now: 0)
            let started = det.tick(snapshot: teams(), now: 0)
            s.expect(started?.flatMap { $0 } != nil, "Teams call became active")

            // Slack starts making noise (huddle-grade evidence, even): before
            // stickiness this tied the global resolver to nil and ended the
            // session after end-debounce.
            let teamsPlusSlack: [AudioProcessState] = teams() + [
                AudioProcessState(pid: 9, bundleID: "com.tinyspeck.slackmacgap",
                                  isRunningInput: true, isRunningOutput: true),
            ]
            for t in stride(from: 1.0, through: 20.0, by: 1.0) {
                let r = det.tick(snapshot: teamsPlusSlack, now: t)
                s.expect(r == nil, "active Teams session unaffected by Slack audio at t=\(t)")
            }

            // Teams family goes fully silent → session ends even though Slack
            // is still noisy (per-app signal, not global).
            let slackOnly = [AudioProcessState(pid: 9, bundleID: "com.tinyspeck.slackmacgap",
                                               isRunningInput: true, isRunningOutput: true)]
            _ = det.tick(snapshot: slackOnly, now: 21)      // active → ending
            let ended = det.tick(snapshot: slackOnly, now: 22) // ending → idle (0s debounce)
            s.expect(ended == .some(.none) || (ended != nil && ended! == nil), "Teams-silent → session ended")
        }

        // --- 7. Interactive end-of-call keys on input drop (fast end) ---
        //
        // Replays the 2026-08-10 audio-watch trace from a real Teams call:
        // mute/unmute never touches the family's input state; hang-up drops
        // modulehost input+output instantly while a helper then runs
        // output-only for ~11.5 s (the end-call sound linger). The session
        // must end endDebounce after the input drop — not after the linger —
        // and the linger must not start a new (broadcast) detection.
        s.check("MeetingDetector tick: hang-up input-drop ends the session; output linger extends nothing") { s in
            func inCall() -> [AudioProcessState] {
                [AudioProcessState(pid: 2645, bundleID: "com.microsoft.teams2.modulehost",
                                   isRunningInput: true, isRunningOutput: true)]
            }
            func linger() -> [AudioProcessState] {
                [AudioProcessState(pid: 2751, bundleID: "com.microsoft.teams2.helper",
                                   isRunningInput: false, isRunningOutput: true)]
            }
            let det = MeetingDetector(
                snapshotProvider: { [] },
                policy: MeetingDetectionPolicy(startDebounce: 4, broadcastStartDebounce: 30, endDebounce: 3)
            )

            // Join: confirm after the 4 s start debounce.
            _ = det.tick(snapshot: inCall(), now: 0)
            let started = det.tick(snapshot: inCall(), now: 4.5)
            s.expect(started?.flatMap { $0 } != nil, "call active after start debounce")

            // In-call ticks (mute/unmute cycles are invisible to CoreAudio).
            s.expect(det.tick(snapshot: inCall(), now: 20) == nil, "stays active mid-call")

            // Hang-up at t=33.4: input drops, helper linger begins.
            s.expect(det.tick(snapshot: linger(), now: 33.4) == nil, "input drop → ending (no emission yet)")
            let ended = det.tick(snapshot: linger(), now: 36.5)
            guard let change = ended, change == nil else {
                s.expect(false, "session ended ~3 s after hang-up despite output linger"); return
            }

            // Linger continues to ~44.8 s: broadcast evidence, but it dies
            // long before the 30 s broadcast debounce → no new detection.
            for t in stride(from: 37.5, through: 44.8, by: 1.0) {
                s.expect(det.tick(snapshot: linger(), now: t) == nil, "linger never re-detects (t=\(t))")
            }
            s.expect(det.tick(snapshot: [], now: 45.4) == nil, "quiet after linger: still nothing")
            s.expect(det.tick(snapshot: [], now: 60) == nil, "idle stays idle")
        }

        // --- 8. Broadcast tier: chime-style output needs title + long debounce ---
        s.check("MeetingDetector tick: broadcast requires strict meeting title; chime never confirms") { s in
            func outputOnlyTeams() -> [AudioProcessState] {
                [AudioProcessState(pid: 200, bundleID: "com.microsoft.teams2",
                                   isRunningInput: false, isRunningOutput: true)]
            }

            // Hub-only windows: meetingTitleProvider returns nil → signal none.
            let noWindow = MeetingDetector(
                snapshotProvider: { [] },
                meetingTitleProvider: { _ in nil },
                policy: MeetingDetectionPolicy(startDebounce: 0, broadcastStartDebounce: 30, endDebounce: 0)
            )
            for t in stride(from: 0.0, through: 60.0, by: 3.0) {
                let r = noWindow.tick(snapshot: outputOnlyTeams(), now: t)
                s.expect(r == nil, "output-only without meeting window never detects (t=\(t))")
            }

            // Meeting window exists: confirms only after the broadcast debounce.
            let townHall = MeetingDetector(
                snapshotProvider: { [] },
                meetingTitleProvider: { _ in "Digital Town Hall" },
                policy: MeetingDetectionPolicy(startDebounce: 0, broadcastStartDebounce: 30, endDebounce: 0)
            )
            s.expect(townHall.tick(snapshot: outputOnlyTeams(), now: 0) == nil, "t=0: confirming")
            s.expect(townHall.tick(snapshot: outputOnlyTeams(), now: 15) == nil, "t=15: chime-linger territory, still confirming")
            let confirmed = townHall.tick(snapshot: outputOnlyTeams(), now: 31)
            guard let d = confirmed?.flatMap({ $0 }) else {
                s.expect(false, "t=31: broadcast confirmed after 30s debounce"); return
            }
            s.expectEqual(d.tier, .broadcastCandidate, "detection carries broadcast tier")
        }

        // --- 9. Title-change split for back-to-back meetings ---
        s.check("MeetingDetector tick: stable title change splits back-to-back meetings") { s in
            final class TitleBox: @unchecked Sendable {
                private let lock = NSLock()
                private var value: String? = "Meeting One"
                var title: String? {
                    get { lock.withLock { value } }
                    set { lock.withLock { value = newValue } }
                }
            }
            let box = TitleBox()
            let det = MeetingDetector(
                snapshotProvider: { [] },
                meetingTitleProvider: { _ in box.title },
                titleChangeStability: 6,
                policy: MeetingDetectionPolicy(startDebounce: 0, endDebounce: 0)
            )
            _ = det.tick(snapshot: teams(), now: 0)
            let first = det.tick(snapshot: teams(), now: 0)
            s.expect(first?.flatMap { $0 } != nil, "first meeting active")

            // Title flips to the next meeting; audio never drops.
            box.title = "Meeting Two"
            s.expect(det.tick(snapshot: teams(), now: 10) == nil, "changed title pending (t=10)")
            s.expect(det.tick(snapshot: teams(), now: 13) == nil, "still inside stability window (t=13)")
            let split = det.tick(snapshot: teams(), now: 17)
            guard let d = split?.flatMap({ $0 }) else {
                s.expect(false, "stable new title → split emitted"); return
            }
            s.expectEqual(d.app.displayName, "Microsoft Teams", "new detection for same app")

            // A momentary flip back (PiP/z-order noise) must NOT split again.
            box.title = "Meeting One"
            s.expect(det.tick(snapshot: teams(), now: 18) == nil, "blip pending")
            box.title = "Meeting Two"
            s.expect(det.tick(snapshot: teams(), now: 19) == nil, "pending cleared, no split")

            // Title disappearing (window minimized) never splits or ends.
            box.title = nil
            s.expect(det.tick(snapshot: teams(), now: 25) == nil, "nil title → no effect")
        }
    }

    // MARK: - Phase 9: MeetingContext — file naming + YAML frontmatter + bestTitle

    static func checkMeetingContext(_ s: CheckSuite) {
        s.check("MeetingContext nameForFile fallback chain") { s in
            s.expectEqual(
                MeetingContext(windowTitle: "CI Agent - DSU").nameForFile,
                "CI Agent - DSU",
                "windowTitle wins when set"
            )
            s.expectEqual(
                MeetingContext(appDisplayName: "Microsoft Teams").nameForFile,
                "Microsoft Teams",
                "appDisplayName wins when windowTitle nil"
            )
            s.expectEqual(
                MeetingContext().nameForFile,
                "",
                "empty string when both nil"
            )
        }

        s.check("MeetingContext yamlFrontmatter: standard fields present and block delimiters") { s in
            let date = Date(timeIntervalSince1970: 1_748_951_400) // 2025-06-03T12:30:00Z
            let ctx = MeetingContext(
                windowTitle: "Standup",
                appDisplayName: "Microsoft Teams",
                bundleID: "com.microsoft.teams2",
                localeIdentifier: "en-US",
                startDate: date
            )
            let fm = ctx.yamlFrontmatter()
            s.expect(fm.hasPrefix("---\n"), "starts with ---")
            s.expect(fm.hasSuffix("---\n"), "ends with ---")
            s.expect(fm.contains("title:"), "contains title key")
            s.expect(fm.contains("app:"), "contains app key")
            s.expect(fm.contains("bundleID:"), "contains bundleID key")
            s.expect(fm.contains("startTime:"), "contains startTime key")
            s.expect(fm.contains("locale:"), "contains locale key")
        }

        s.check("MeetingContext yamlFrontmatter: nil fields are omitted") { s in
            let ctx = MeetingContext(startDate: Date())
            let fm = ctx.yamlFrontmatter()
            s.expect(!fm.contains("title:"), "nil windowTitle omitted")
            s.expect(!fm.contains("app:"), "nil appDisplayName omitted")
            s.expect(!fm.contains("bundleID:"), "nil bundleID omitted")
            s.expect(!fm.contains("locale:"), "nil localeIdentifier omitted")
        }

        s.check("MeetingContext yamlFrontmatter: hostile title with colon, hash, quotes, backslash") { s in
            let ctx = MeetingContext(
                windowTitle: "title: \"value\" # comment \\ end",
                startDate: Date()
            )
            let fm = ctx.yamlFrontmatter()
            // Value must be wrapped in double-quotes and all special chars escaped
            s.expect(fm.contains("title: \"title: \\\"value\\\" # comment \\\\ end\""),
                     "colon/hash/quotes/backslash escaped")
        }

        s.check("MeetingContext yamlFrontmatter: hostile title with newline and tab") { s in
            let ctx = MeetingContext(windowTitle: "line1\nline2\there", startDate: Date())
            let fm = ctx.yamlFrontmatter()
            s.expect(fm.contains("\\n"), "newline escaped in scalar")
            s.expect(fm.contains("\\t"), "tab escaped in scalar")
            // Must still be a single YAML line (no literal newlines inside the scalar)
            let titleLine = fm.components(separatedBy: "\n").first(where: { $0.hasPrefix("title:") })
            s.expect(titleLine != nil, "title key exists")
        }

        s.check("MeetingContext yamlFrontmatter: YAML-breaking title '---'") { s in
            let ctx = MeetingContext(windowTitle: "---", startDate: Date())
            let fm = ctx.yamlFrontmatter()
            // The '---' inside a double-quoted scalar is harmless
            s.expect(fm.contains("title: \"---\""), "--- wrapped in quotes")
        }

        s.check("MeetingContext yamlFrontmatter: emoji in title passes through safely") { s in
            let ctx = MeetingContext(windowTitle: "Sprint 🚀 Review", startDate: Date())
            let fm = ctx.yamlFrontmatter()
            s.expect(fm.contains("Sprint 🚀 Review"), "emoji preserved in quoted scalar")
        }

        s.check("MeetingContext yamlFrontmatter: extra key-value pairs are quoted") { s in
            let ctx = MeetingContext(
                startDate: Date(),
                extra: [("custom:key", "value\"with\"quotes")]
            )
            let fm = ctx.yamlFrontmatter()
            s.expect(fm.contains("\"custom:key\""), "extra key is quoted")
            s.expect(fm.contains("\"value\\\"with\\\"quotes\""), "extra value is quoted")
        }

        s.check("MeetingContext yamlQuote: control characters use \\uXXXX form") { s in
            let result = MeetingContext.yamlQuote("\u{01}\u{1F}\u{7F}")
            s.expect(result.contains("\\u0001"), "SOH → \\u0001")
            s.expect(result.contains("\\u001F"), "US → \\u001F")
            s.expect(result.contains("\\u007F"), "DEL → \\u007F")
        }

        s.check("MeetingContext applyTrailingStrips: strips matching suffix") { s in
            s.expectEqual(
                MeetingContext.applyTrailingStrips(to: "Standup | Microsoft Teams", strips: [" | Microsoft Teams"]),
                "Standup",
                "trailing app-name suffix stripped"
            )
        }

        s.check("MeetingContext applyTrailingStrips: no match leaves title unchanged") { s in
            s.expectEqual(
                MeetingContext.applyTrailingStrips(to: "Standup | Zoom", strips: [" | Microsoft Teams"]),
                "Standup | Zoom",
                "no matching suffix → unchanged"
            )
        }

        s.check("MeetingContext applyTrailingStrips: empty strips → unchanged") { s in
            s.expectEqual(
                MeetingContext.applyTrailingStrips(to: "Any Title | Microsoft Teams", strips: []),
                "Any Title | Microsoft Teams",
                "empty strips → unchanged"
            )
        }

        s.check("MeetingContext applyTrailingStrips: stripping to empty keeps original") { s in
            s.expectEqual(
                MeetingContext.applyTrailingStrips(to: " | Microsoft Teams", strips: [" | Microsoft Teams"]),
                " | Microsoft Teams",
                "would-be-empty result keeps original"
            )
        }

        s.check("MeetingContext applyTrailingStrips: trims whitespace after strip") { s in
            s.expectEqual(
                MeetingContext.applyTrailingStrips(to: "Weekly Review  | Microsoft Teams", strips: ["| Microsoft Teams"]),
                "Weekly Review",
                "trailing whitespace trimmed after strip"
            )
        }
    }

    static func checkBestTitle(_ s: CheckSuite) {
        s.check("bestTitle: empty candidates → nil") { s in
            s.expect(MeetingContext.bestTitle(from: []) == nil, "empty → nil")
        }

        s.check("bestTitle: all-empty candidates → nil") { s in
            s.expect(MeetingContext.bestTitle(from: ["", ""]) == nil, "all empty → nil")
        }

        s.check("bestTitle: single non-empty candidate returned") { s in
            s.expectEqual(
                MeetingContext.bestTitle(from: ["Only Title"]),
                "Only Title",
                "single candidate returned"
            )
        }

        s.check("bestTitle: hint-match wins over longer title") { s in
            let result = MeetingContext.bestTitle(
                from: ["Zoom Meeting", "A very very very long unrelated title"],
                appHints: ["Zoom Meeting"]
            )
            s.expectEqual(result, "Zoom Meeting", "hint-match preferred over longer")
        }

        s.check("bestTitle: longest title wins when no hint matches") { s in
            let result = MeetingContext.bestTitle(
                from: ["Short", "Medium title", "The longest title here"],
                appHints: ["Zoom Meeting"]
            )
            s.expectEqual(result, "The longest title here", "longest picked when no hint match")
        }

        s.check("bestTitle: longest title wins with no hints provided") { s in
            let result = MeetingContext.bestTitle(
                from: ["A", "BB", "CCC"],
                appHints: []
            )
            s.expectEqual(result, "CCC", "longest picked with empty hints")
        }

        // MARK: Exclusion checks

        s.check("bestTitle: excluded leading segment is dropped") { s in
            let result = MeetingContext.bestTitle(
                from: ["Chat | Kelekis, Dimitrios | Microsoft Teams", "Weekly Standup | Microsoft Teams"],
                exclusions: ["Chat"]
            )
            s.expectEqual(result, "Weekly Standup | Microsoft Teams", "hub window excluded")
        }

        s.check("bestTitle: meeting title wins over longer excluded hub title") { s in
            // Regression: "Chat | Kelekis, Dimitrios | Microsoft Teams" (43 chars) was
            // incorrectly beating "Weekly GSE LT Connect | Microsoft Teams" (39 chars).
            let result = MeetingContext.bestTitle(
                from: [
                    "Weekly GSE LT Connect | Microsoft Teams",
                    "Chat | Kelekis, Dimitrios | Microsoft Teams",
                ],
                exclusions: ["Chat", "Activity", "Calendar", "Calls", "Teams and Channels", "Files", "Microsoft Teams"]
            )
            s.expectEqual(result, "Weekly GSE LT Connect | Microsoft Teams", "meeting title wins over longer excluded hub title")
        }

        s.check("bestTitle: all-excluded falls back to original candidates (no nil regression)") { s in
            let result = MeetingContext.bestTitle(
                from: ["Chat | Alice | Microsoft Teams", "Calendar | Microsoft Teams"],
                exclusions: ["Chat", "Calendar"]
            )
            // Both candidates excluded → fall back to longest of original set.
            s.expect(result != nil, "non-nil when all excluded")
            s.expectEqual(result, "Chat | Alice | Microsoft Teams", "longest original candidate returned as fallback")
        }

        s.check("bestTitle: empty exclusions preserves existing behavior") { s in
            let result = MeetingContext.bestTitle(
                from: ["Short", "A longer title wins"],
                exclusions: []
            )
            s.expectEqual(result, "A longer title wins", "longest wins with empty exclusions")
        }

        s.check("bestTitle strict mode: all-excluded returns nil (detection gate)") { s in
            // Only hub windows on screen (a chime false-positive scenario):
            // strict mode must report "no meeting window", not fall back.
            let hubOnly = MeetingContext.bestTitle(
                from: ["Chat | Alice | Microsoft Teams", "Calendar | Microsoft Teams"],
                exclusions: ["Chat", "Calendar"],
                exclusionFallback: false
            )
            s.expect(hubOnly == nil, "strict: all-excluded → nil")

            // A real meeting window survives strict exclusion.
            let withMeeting = MeetingContext.bestTitle(
                from: ["Chat | Alice | Microsoft Teams", "Weekly Sync | Microsoft Teams"],
                exclusions: ["Chat", "Calendar"],
                exclusionFallback: false
            )
            s.expectEqual(withMeeting, "Weekly Sync | Microsoft Teams", "strict: meeting window found")
        }

        // Verify Teams catalog entry exposes the expected nonMeetingTitlePrefixes.
        s.check("Teams catalog entry has nonMeetingTitlePrefixes seeded") { s in
            let prefixes = MeetingAppCatalog.match(bundleID: "com.microsoft.teams2")?.app.nonMeetingTitlePrefixes ?? []
            s.expect(prefixes.contains("Chat"), "Chat in Teams exclusions")
            s.expect(prefixes.contains("Calendar"), "Calendar in Teams exclusions")
            s.expect(prefixes.contains("Calls"), "Calls in Teams exclusions")
            s.expect(prefixes.contains("Activity"), "Activity in Teams exclusions")
            s.expect(prefixes.contains("Files"), "Files in Teams exclusions")
            s.expect(prefixes.contains("Teams and Channels"), "Teams and Channels in Teams exclusions")
            s.expect(prefixes.contains("Microsoft Teams"), "Microsoft Teams in Teams exclusions")
        }

        s.check("Teams catalog entry has titleTrailingStrips seeded") { s in
            let strips = MeetingAppCatalog.match(bundleID: "com.microsoft.teams2")?.app.titleTrailingStrips ?? []
            s.expect(strips.contains(" | Microsoft Teams"), "| Microsoft Teams in Teams trailing strips")
        }

        s.check("bestTitle: preferFrontmost selects first candidate over longest") { s in
            let result = MeetingContext.bestTitle(
                from: ["test call", "A much longer hub detail title"],
                preferFrontmost: true
            )
            s.expectEqual(result, "test call", "frontmost wins over longer title")
        }

        s.check("bestTitle: preferFrontmost still applies exclusions before picking frontmost") { s in
            // Frontmost is an excluded hub section; next frontmost is the meeting.
            let result = MeetingContext.bestTitle(
                from: [
                    "Calendar | Microsoft Teams",
                    "test call | Microsoft Teams",
                    "PGS Agentic AI Foundations Program Workshop | Microsoft Teams",
                ],
                exclusions: ["Calendar", "Chat"],
                preferFrontmost: true
            )
            s.expectEqual(result, "test call | Microsoft Teams",
                          "excluded frontmost dropped, real meeting window selected")
        }

        s.check("bestTitle + applyTrailingStrips: live meeting window wins over verbose hub page") { s in
            // Real-world capture: the live meeting window ("test call") is frontmost;
            // a calendar event detail page left open in a hub window
            // ("PGS Agentic AI Foundations Program Workshop") is longer but behind it.
            // preferFrontmost must pick the meeting window, not the longest title.
            let raw = MeetingContext.bestTitle(
                from: [
                    "test call | Microsoft Teams",
                    "Calendar | Microsoft Teams",
                    "PGS Agentic AI Foundations Program Workshop | Microsoft Teams",
                ],
                appHints: [],
                exclusions: MeetingAppCatalog.match(bundleID: "com.microsoft.teams2")?.app.nonMeetingTitlePrefixes ?? [],
                preferFrontmost: true
            )
            let strips = MeetingAppCatalog.match(bundleID: "com.microsoft.teams2")?.app.titleTrailingStrips ?? []
            let result = raw.map { MeetingContext.applyTrailingStrips(to: $0, strips: strips) }
            s.expectEqual(result, "test call",
                          "frontmost meeting window selected, then Teams suffix stripped")
        }

        s.check("bestTitle + applyTrailingStrips: 1:1 call picks call window over compact-view overlay and stray hub page") { s in
            // Real-world capture during a 1:1 call: a "Meeting compact view" PiP
            // overlay is frontmost, the real call window is behind it, and a stray
            // "PGS …" hub detail page is further back. The compact-view chrome must
            // be excluded so the actual call window wins, not the hub page.
            let raw = MeetingContext.bestTitle(
                from: [
                    "Meeting compact view | +1 913-712-6167 | Microsoft Teams",
                    "+1 913-712-6167 | Microsoft Teams",
                    "Calls | Microsoft Teams",
                    "PGS Agentic AI Foundations Program Workshop | Microsoft Teams",
                ],
                appHints: [],
                exclusions: MeetingAppCatalog.match(bundleID: "com.microsoft.teams2")?.app.nonMeetingTitlePrefixes ?? [],
                preferFrontmost: true
            )
            let strips = MeetingAppCatalog.match(bundleID: "com.microsoft.teams2")?.app.titleTrailingStrips ?? []
            let result = raw.map { MeetingContext.applyTrailingStrips(to: $0, strips: strips) }
            s.expectEqual(result, "+1 913-712-6167",
                          "compact-view overlay excluded, real call window selected")
        }

        s.check("Teams catalog excludes Meeting compact view overlay") { s in
            let prefixes = MeetingAppCatalog.match(bundleID: "com.microsoft.teams2")?.app.nonMeetingTitlePrefixes ?? []
            s.expect(prefixes.contains("Meeting compact view"), "Meeting compact view in Teams exclusions")
        }
    }

    // MARK: - Foundation-only top-level AlembicKit audit

    /// Asserts that all `.swift` files directly under `Sources/AlembicKit/`
    /// (i.e. not in subdirectories) contain no imports of Apple platform
    /// frameworks. Those imports are only permitted under `Platform/macOS/`.
    /// Locks the deterministic disclosure logic: the post/stage/skip decision
    /// (enabled gate, once-per-session guard, Teams-only gate, autoSend routing),
    /// message templating (placeholder substitution, whitespace collapse,
    /// blank-template fallback, length cap), and the user-facing status strings.
    /// The live Accessibility UI automation in `TeamsChatPoster` is a MANUAL gate.
    static func checkDisclosurePolicy(_ s: CheckSuite) {
        s.check("DisclosurePolicy.decide: disabled config always skips") { s in
            let cfg = DisclosurePolicy.Config(enabled: false, autoSend: true)
            s.expectEqual(
                DisclosurePolicy.decide(config: cfg, isTeams: true, alreadyPosted: false),
                .skip(reason: "disabled in settings"), "disabled ⇒ skip")
        }

        s.check("DisclosurePolicy.decide: once-per-session guard skips a second attempt") { s in
            let cfg = DisclosurePolicy.Config(enabled: true, autoSend: true)
            s.expectEqual(
                DisclosurePolicy.decide(config: cfg, isTeams: true, alreadyPosted: true),
                .skip(reason: "already disclosed this meeting"), "alreadyPosted ⇒ skip")
        }

        s.check("DisclosurePolicy.decide: teamsOnly gate skips non-Teams") { s in
            let cfg = DisclosurePolicy.Config(enabled: true, autoSend: true, teamsOnly: true)
            s.expectEqual(
                DisclosurePolicy.decide(config: cfg, isTeams: false, alreadyPosted: false),
                .skip(reason: "only supported for Microsoft Teams"), "non-Teams + teamsOnly ⇒ skip")
            // With teamsOnly off, a non-Teams app proceeds.
            let any = DisclosurePolicy.Config(enabled: true, autoSend: true, teamsOnly: false)
            s.expectEqual(
                DisclosurePolicy.decide(config: any, isTeams: false, alreadyPosted: false),
                .post, "non-Teams + teamsOnly off ⇒ post")
        }

        s.check("DisclosurePolicy.decide: autoSend routes post vs clipboard") { s in
            let auto = DisclosurePolicy.Config(enabled: true, autoSend: true)
            s.expectEqual(
                DisclosurePolicy.decide(config: auto, isTeams: true, alreadyPosted: false),
                .post, "autoSend on ⇒ post")
            let manual = DisclosurePolicy.Config(enabled: true, autoSend: false)
            s.expectEqual(
                DisclosurePolicy.decide(config: manual, isTeams: true, alreadyPosted: false),
                .stageToClipboard, "autoSend off ⇒ stageToClipboard")
        }

        s.check("DisclosurePolicy.renderMessage: blank template falls back to default") { s in
            s.expectEqual(
                DisclosurePolicy.renderMessage(template: "   \n  "),
                DisclosurePolicy.defaultMessage, "blank ⇒ default")
            s.expectEqual(
                DisclosurePolicy.renderMessage(template: ""),
                DisclosurePolicy.defaultMessage, "empty ⇒ default")
        }

        s.check("DisclosurePolicy.renderMessage: collapses whitespace and newlines") { s in
            let out = DisclosurePolicy.renderMessage(template: "Hi   there\n\nfolks\t!")
            s.expectEqual(out, "Hi there folks !", "internal whitespace collapsed to single spaces")
        }

        s.check("DisclosurePolicy.renderMessage: substitutes the meeting placeholder") { s in
            let withTitle = DisclosurePolicy.renderMessage(
                template: "Transcribing {meeting} locally.", meetingTitle: "Weekly Sync")
            s.expectEqual(withTitle, "Transcribing Weekly Sync locally.", "placeholder filled")
            // No title ⇒ placeholder removed, surrounding whitespace collapsed.
            let noTitle = DisclosurePolicy.renderMessage(
                template: "Transcribing {meeting} locally.", meetingTitle: nil)
            s.expectEqual(noTitle, "Transcribing locally.", "placeholder removed when no title")
        }

        s.check("DisclosurePolicy.renderMessage: caps length with ellipsis on a word boundary") { s in
            let long = String(repeating: "word ", count: 200)
            let out = DisclosurePolicy.renderMessage(template: long)
            s.expect(out.count <= DisclosurePolicy.maxMessageLength, "respects maxMessageLength")
            s.expect(out.hasSuffix("…"), "truncated output ends with ellipsis")
            s.expect(!out.contains("  "), "no double spaces after truncation")
        }

        s.check("DisclosurePolicy.defaultMessage is workplace-appropriate") { s in
            let m = DisclosurePolicy.defaultMessage
            s.expect(m.contains("locally"), "states it is local")
            s.expect(m.lowercased().contains("nothing is uploaded"), "states nothing is uploaded")
            s.expect(!m.lowercased().contains("personal use only"),
                     "avoids 'personal use only' phrasing")
        }

        s.check("DisclosurePolicy.Result: every outcome has a non-empty status") { s in
            let results: [DisclosurePolicy.Result] = [
                .posted, .stagedToClipboard, .skipped(reason: "disabled"), .failed(detail: "no chat"),
            ]
            for r in results {
                s.expect(!r.statusMessage.isEmpty, "non-empty status for \(r)")
            }
            s.expect(DisclosurePolicy.Result.failed(detail: "no chat").statusMessage.contains("no chat"),
                     "failure status includes detail")
        }
    }

    // MARK: - Phase 4: ScreenCaptureKitSource gated video-frame stream (pure seams)

    static func checkCandidatePIDs(_ s: CheckSuite) {
        s.check("candidatePIDs: returns parent PID plus dot-delimited child bundle-ID PIDs") { s in
            let processes: [(pid: Int32, bundleID: String)] = [
                (pid: 100, bundleID: "com.microsoft.teams2"),
                (pid: 101, bundleID: "com.microsoft.teams2.modulehost"),
                (pid: 102, bundleID: "com.other.app"),
            ]
            let result = ScreenCaptureKitSource.candidatePIDs(
                target: "com.microsoft.teams2", canonicalBundlePrefix: "com.microsoft.teams2", runningProcesses: processes)
            s.expectEqual(result, Set([100, 101]), "parent + child PIDs, unrelated app excluded")
        }

        s.check("candidatePIDs: excludes a bundle ID that only shares a textual prefix without the dot-delimiter") { s in
            let processes: [(pid: Int32, bundleID: String)] = [
                (pid: 100, bundleID: "com.microsoft.teams2"),
                (pid: 200, bundleID: "com.microsoft.teams2x"),
            ]
            let result = ScreenCaptureKitSource.candidatePIDs(
                target: "com.microsoft.teams2", canonicalBundlePrefix: "com.microsoft.teams2", runningProcesses: processes)
            s.expectEqual(result, Set([100]), "teams2x excluded — not a dot-delimited child")
        }

        s.check("candidatePIDs: returns an empty set when no running process matches the prefix") { s in
            let processes: [(pid: Int32, bundleID: String)] = [(pid: 100, bundleID: "com.other.app")]
            let result = ScreenCaptureKitSource.candidatePIDs(
                target: "com.microsoft.teams2", canonicalBundlePrefix: "com.microsoft.teams2", runningProcesses: processes)
            s.expect(result.isEmpty, "no bundle-ID match ⇒ empty set")
        }

        s.check("candidatePIDs: an explicit pid:<n> target resolves directly to that PID, independent of bundle identifiers") { s in
            // canonicalBundlePrefix would itself be "pid:4242" here (no catalog
            // match for a raw pid: target) — the pid: fast path must not
            // consult it, and must not depend on any running process's
            // bundle ID (a pid: target's owning process may have none).
            let processes: [(pid: Int32, bundleID: String)] = [
                (pid: 4242, bundleID: ""),
                (pid: 999, bundleID: "com.microsoft.teams2"),
            ]
            let result = ScreenCaptureKitSource.candidatePIDs(
                target: "pid:4242", canonicalBundlePrefix: "pid:4242", runningProcesses: processes)
            s.expectEqual(result, Set([4242]), "pid: target resolves to exactly that PID, not to any bundle-matched PID")
        }

        s.check("candidatePIDs: a pid:<n> target resolves even when no running process is supplied at all") { s in
            let result = ScreenCaptureKitSource.candidatePIDs(target: "pid:777", canonicalBundlePrefix: "pid:777", runningProcesses: [])
            s.expectEqual(result, Set([777]), "pid: fast path does not depend on runningProcesses")
        }
    }

    static func checkResolveMeetingWindowID(_ s: CheckSuite) {
        typealias Window = (windowID: Int, ownerPID: Int32, title: String, windowLayer: Int, width: Double, height: Double)
        let titleHints = ["Standup"]
        let nonMeetingTitlePrefixes = ["Chat", "Calendar", "Meeting compact view"]
        let familyPIDs: Set<Int32> = [100, 101]

        s.check("resolveMeetingWindowID: frontmost call window wins over a longer hub window behind it") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "Standup | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
                (windowID: 2, ownerPID: 100, title: "Chat with a much longer title than the call window | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: [])
            s.expectEqual(result, 1, "frontmost call window wins over the longer stray hub title")
        }

        s.check("resolveMeetingWindowID: a chat-hub-only screen (excluded leading segment) resolves to nil, no fallback") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "Chat | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: nonMeetingTitlePrefixes)
            s.expect(result == nil, "every candidate excluded ⇒ nil, exclusionFallback: false must not fall back to the hub title")
        }

        s.check("resolveMeetingWindowID: a frontmost compact-view overlay is excluded by title, not merely deprioritized") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "Meeting compact view", windowLayer: 0, width: 300, height: 200),
                (windowID: 2, ownerPID: 100, title: "Standup | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: nonMeetingTitlePrefixes)
            s.expectEqual(result, 2, "compact-view overlay excluded by title despite being frontmost")
        }

        s.check("resolveMeetingWindowID: a helper/child-PID-owned window is discovered via PID-family resolution") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 101, title: "Standup | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: [])
            s.expectEqual(result, 1, "child-PID-owned window resolved as the meeting window")
        }

        s.check("resolveMeetingWindowID: a tiny overlay window is filtered by the bounds floor") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "Window", windowLayer: 0, width: 66, height: 20),
                (windowID: 2, ownerPID: 100, title: "Standup | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: [])
            s.expectEqual(result, 2, "tiny overlay excluded by minContentWidth/minContentHeight")
        }

        s.check("resolveMeetingWindowID: a non-family PID is never returned even if its title would otherwise rank highest") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 999, title: "Standup | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: [])
            s.expect(result == nil, "non-family PID window never qualifies")
        }

        s.check("resolveMeetingWindowID: nil when every candidate has a non-zero windowLayer") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "Standup | Microsoft Teams", windowLayer: 3, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: [])
            s.expect(result == nil, "only overlay/HUD-layer windows on screen ⇒ nil")
        }

        s.check("resolveMeetingWindowID: nil when every candidate has an empty title") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: [])
            s.expect(result == nil, "empty titles never qualify")
        }

        s.check("resolveMeetingWindowID: deterministic given the same front-to-back order presented twice") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "Standup | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
                (windowID: 2, ownerPID: 100, title: "Chat | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let first = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: nonMeetingTitlePrefixes)
            let second = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: titleHints, nonMeetingTitlePrefixes: nonMeetingTitlePrefixes)
            s.expectEqual(first, second, "deterministic for identical input")
            s.expectEqual(first, 1, "resolves to the call window given this z-order")
        }

        // MARK: HIGH-2 — fail closed without positive meeting-window evidence

        // Mirrors the real Teams catalog entry: no static `titleHints` at all
        // (meeting subjects are arbitrary), only a finite
        // `nonMeetingTitlePrefixes` blocklist — the exact shape that let an
        // unexcluded-but-unconfirmed window through before this fix.
        let teamsNonMeetingTitlePrefixes = MeetingAppCatalog.apps.first { $0.displayName == "Microsoft Teams" }?.nonMeetingTitlePrefixes ?? []

        s.check("resolveMeetingWindowID: with no titleHints (Teams) and no expectedMeetingTitle, a not-yet-catalogued hub window fails closed to nil") { s in
            for candidateTitle in ["Settings | Microsoft Teams", "Apps | Microsoft Teams", "Help | Microsoft Teams", "Notifications | Microsoft Teams", "More | Microsoft Teams"] {
                let windows: [Window] = [
                    (windowID: 1, ownerPID: 100, title: candidateTitle, windowLayer: 0, width: 900, height: 600),
                ]
                let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                    fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: [], nonMeetingTitlePrefixes: teamsNonMeetingTitlePrefixes)
                s.expect(result == nil, "\"\(candidateTitle)\" is not in nonMeetingTitlePrefixes yet must still fail closed — no positive evidence exists")
            }
        }

        s.check("resolveMeetingWindowID: with no titleHints and no expectedMeetingTitle, even a plausible real meeting title fails closed (never accepted on exclusion-survival alone)") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "Standup | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: [], nonMeetingTitlePrefixes: teamsNonMeetingTitlePrefixes)
            s.expect(result == nil, "no titleHints and no expectedMeetingTitle ⇒ nil even for a title that looks like a real meeting")
        }

        s.check("resolveMeetingWindowID: a caller-supplied expectedMeetingTitle (the session's confirmed title) is positive evidence even with no static titleHints") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "Standup | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
                (windowID: 2, ownerPID: 100, title: "Chat | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: [], nonMeetingTitlePrefixes: teamsNonMeetingTitlePrefixes,
                expectedMeetingTitle: "Standup")
            s.expectEqual(result, 1, "expectedMeetingTitle confirms the real meeting window and it is selected")
        }

        s.check("resolveMeetingWindowID: an expectedMeetingTitle that matches no on-screen window still fails closed") { s in
            let windows: [Window] = [
                (windowID: 1, ownerPID: 100, title: "Settings | Microsoft Teams", windowLayer: 0, width: 900, height: 600),
            ]
            let result = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: windows, candidatePIDs: familyPIDs, titleHints: [], nonMeetingTitlePrefixes: teamsNonMeetingTitlePrefixes,
                expectedMeetingTitle: "Standup")
            s.expect(result == nil, "the only on-screen window does not match expectedMeetingTitle ⇒ fail closed")
        }
    }

    static func checkHasPositiveMeetingEvidence(_ s: CheckSuite) {
        s.check("hasPositiveMeetingEvidence: true when the title contains a static titleHint") { s in
            s.expect(
                ScreenCaptureKitSource.hasPositiveMeetingEvidence(title: "Zoom Meeting", titleHints: ["Zoom Meeting"], expectedMeetingTitle: nil),
                "titleHints match ⇒ positive evidence")
        }

        s.check("hasPositiveMeetingEvidence: false with empty titleHints and no expectedMeetingTitle (Teams' shape)") { s in
            s.expect(
                !ScreenCaptureKitSource.hasPositiveMeetingEvidence(title: "Standup | Microsoft Teams", titleHints: [], expectedMeetingTitle: nil),
                "no titleHints, no expectedMeetingTitle ⇒ fail closed")
        }

        s.check("hasPositiveMeetingEvidence: true when the title starts with a non-empty expectedMeetingTitle") { s in
            s.expect(
                ScreenCaptureKitSource.hasPositiveMeetingEvidence(title: "Standup | Microsoft Teams", titleHints: [], expectedMeetingTitle: "Standup"),
                "expectedMeetingTitle prefix match ⇒ positive evidence")
        }

        s.check("hasPositiveMeetingEvidence: false when the title does not start with expectedMeetingTitle") { s in
            s.expect(
                !ScreenCaptureKitSource.hasPositiveMeetingEvidence(title: "Settings | Microsoft Teams", titleHints: [], expectedMeetingTitle: "Standup"),
                "mismatched expectedMeetingTitle ⇒ no evidence")
        }

        s.check("hasPositiveMeetingEvidence: an empty expectedMeetingTitle string never counts as evidence") { s in
            s.expect(
                !ScreenCaptureKitSource.hasPositiveMeetingEvidence(title: "Standup | Microsoft Teams", titleHints: [], expectedMeetingTitle: ""),
                "empty expectedMeetingTitle is treated as absent, not a universal prefix match")
        }
    }

    static func checkVideoStreamPixelSize(_ s: CheckSuite) {
        s.check("videoStreamPixelSize: returns the exact scaled size unchanged when already below maxDimension") { s in
            let size = ScreenCaptureKitSource.videoStreamPixelSize(windowSize: CGSize(width: 400, height: 300), backingScale: 2)
            s.expectEqual(size.width, 800, "width scaled by backingScale")
            s.expectEqual(size.height, 600, "height scaled by backingScale")
        }

        s.check("videoStreamPixelSize: clamps the longer side to exactly maxDimension, preserving aspect ratio") { s in
            // raw: 2000*2 x 1000*2 = 4000x2000 -> clampScale = 1600/4000 = 0.4 -> 1600x800
            let size = ScreenCaptureKitSource.videoStreamPixelSize(windowSize: CGSize(width: 2000, height: 1000), backingScale: 2, maxDimension: 1600)
            s.expectEqual(size.width, 1600, "longer side clamps to exactly maxDimension")
            s.expectEqual(size.height, 800, "aspect ratio preserved under the clamp")
        }

        s.check("videoStreamPixelSize: defaults to a 2400px ceiling so small Gallery labels retain OCR detail") { s in
            let size = ScreenCaptureKitSource.videoStreamPixelSize(windowSize: CGSize(width: 2000, height: 1000), backingScale: 2)
            s.expectEqual(size.width, 2400, "default longer-side ceiling preserves more label detail")
            s.expectEqual(size.height, 1200, "default ceiling preserves aspect ratio")
        }

        s.check("videoStreamPixelSize: never returns less than 2x2, even for a degenerate (0,0) window size") { s in
            let size = ScreenCaptureKitSource.videoStreamPixelSize(windowSize: .zero, backingScale: 2)
            s.expect(size.width >= 2, "width floor")
            s.expect(size.height >= 2, "height floor")
        }
    }

    static func checkFrameMetadataExtractor(_ s: CheckSuite) {
        let clock = SessionClock(originSeconds: 100)

        s.check("FrameMetadataExtractor.extract: accepts .complete status with a nonzero displayTime, exact conversion") { s in
            let hostTime: UInt64 = 5_000_000_000
            let attachments: [SCStreamFrameInfo: Any] = [
                .status: SCFrameStatus.complete.rawValue,
                .displayTime: hostTime,
            ]
            let result = FrameMetadataExtractor.extract(from: attachments, clock: clock)
            let expected = clock.sessionTime(forPlatformTime: HostClock.seconds(fromMachHostTime: hostTime))
            s.expect(result != nil, "accepted a valid .complete frame")
            if let result {
                s.expect(abs(result - expected) < 0.000_001, "exact HostClock/SessionClock conversion, not merely non-nil")
            }
        }

        s.check("FrameMetadataExtractor.extract: rejects every non-.complete SCFrameStatus") { s in
            let hostTime: UInt64 = 5_000_000_000
            for status: SCFrameStatus in [.idle, .blank, .suspended, .started, .stopped] {
                let attachments: [SCStreamFrameInfo: Any] = [
                    .status: status.rawValue,
                    .displayTime: hostTime,
                ]
                s.expect(FrameMetadataExtractor.extract(from: attachments, clock: clock) == nil, "rejects status \(status)")
            }
        }

        s.check("FrameMetadataExtractor.extract: rejects an unparseable/out-of-range raw status value") { s in
            let attachments: [SCStreamFrameInfo: Any] = [
                .status: 999,
                .displayTime: UInt64(5_000_000_000),
            ]
            s.expect(FrameMetadataExtractor.extract(from: attachments, clock: clock) == nil, "out-of-range status rejected")
        }

        s.check("FrameMetadataExtractor.extract: rejects a zero displayTime even when status is .complete") { s in
            let attachments: [SCStreamFrameInfo: Any] = [
                .status: SCFrameStatus.complete.rawValue,
                .displayTime: UInt64(0),
            ]
            s.expect(FrameMetadataExtractor.extract(from: attachments, clock: clock) == nil, "zero displayTime rejected")
        }

        s.check("FrameMetadataExtractor.extract: rejects a dictionary missing either key") { s in
            s.expect(
                FrameMetadataExtractor.extract(from: [.status: SCFrameStatus.complete.rawValue], clock: clock) == nil,
                "missing .displayTime rejected")
            s.expect(
                FrameMetadataExtractor.extract(from: [.displayTime: UInt64(5_000_000_000)], clock: clock) == nil,
                "missing .status rejected")
            s.expect(FrameMetadataExtractor.extract(from: [:], clock: clock) == nil, "empty dictionary rejected")
        }
    }

    static func checkValidatedPixelGeometry(_ s: CheckSuite) {
        s.check("validatedPixelGeometry: accepts valid 32BGRA non-planar geometry and returns the exact byte count") { s in
            let byteCount = ScreenCaptureKitSource.validatedPixelGeometry(
                pixelFormatType: kCVPixelFormatType_32BGRA, isPlanar: false,
                width: 10, height: 5, bytesPerRow: 40, dataSize: 200)
            s.expectEqual(byteCount, 200, "byteCount == bytesPerRow * height")
        }

        s.check("validatedPixelGeometry: rejects a wrong pixel format even with otherwise-valid geometry") { s in
            let byteCount = ScreenCaptureKitSource.validatedPixelGeometry(
                pixelFormatType: kCVPixelFormatType_32ARGB, isPlanar: false,
                width: 10, height: 5, bytesPerRow: 40, dataSize: 200)
            s.expect(byteCount == nil, "non-BGRA packed format rejected")
        }

        s.check("validatedPixelGeometry: rejects a planar buffer even with the right raw format code path") { s in
            let byteCount = ScreenCaptureKitSource.validatedPixelGeometry(
                pixelFormatType: kCVPixelFormatType_32BGRA, isPlanar: true,
                width: 10, height: 5, bytesPerRow: 40, dataSize: 200)
            s.expect(byteCount == nil, "isPlanar: true rejected regardless of format code")
        }

        s.check("validatedPixelGeometry: rejects non-positive/degenerate dimensions") { s in
            for (w, h) in [(0, 5), (10, 0), (0, 0)] {
                let byteCount = ScreenCaptureKitSource.validatedPixelGeometry(
                    pixelFormatType: kCVPixelFormatType_32BGRA, isPlanar: false,
                    width: w, height: h, bytesPerRow: 40, dataSize: 200)
                s.expect(byteCount == nil, "degenerate width=\(w) height=\(h) rejected")
            }
        }

        s.check("validatedPixelGeometry: rejects an under-strided bytesPerRow (fabricated, unreachable from a real CVPixelBuffer)") { s in
            // width=100 needs >= 400 bytes/row for BGRA; 40 is far too small.
            let byteCount = ScreenCaptureKitSource.validatedPixelGeometry(
                pixelFormatType: kCVPixelFormatType_32BGRA, isPlanar: false,
                width: 100, height: 5, bytesPerRow: 40, dataSize: 200)
            s.expect(byteCount == nil, "bytesPerRow < width * 4 rejected")
        }

        s.check("validatedPixelGeometry: rejects an Int-overflowing bytesPerRow * height (fabricated Int-max-adjacent pair)") { s in
            let byteCount = ScreenCaptureKitSource.validatedPixelGeometry(
                pixelFormatType: kCVPixelFormatType_32BGRA, isPlanar: false,
                width: 1, height: 4, bytesPerRow: Int.max / 2, dataSize: 0)
            s.expect(byteCount == nil, "overflowing bytesPerRow * height rejected")
        }

        s.check("validatedPixelGeometry: rejects (without trapping) a fabricated width whose width * 4 itself would overflow Int (LOW-1)") { s in
            // A width near Int.max/4 makes the *unchecked* `width * 4` used by
            // the minimum-row-bytes comparison overflow/trap before this
            // function ever gets a chance to reject it — the exact trust-
            // boundary bug this check locks in the fix for. Reaching this
            // line at all (rather than crashing the process) is the assertion.
            let byteCount = ScreenCaptureKitSource.validatedPixelGeometry(
                pixelFormatType: kCVPixelFormatType_32BGRA, isPlanar: false,
                width: Int.max / 3, height: 1, bytesPerRow: 4, dataSize: 0)
            s.expect(byteCount == nil, "width * 4 overflow rejected safely, not trapped")
        }

        s.check("validatedPixelGeometry: rejects a reported dataSize smaller than bytesPerRow * height") { s in
            let byteCount = ScreenCaptureKitSource.validatedPixelGeometry(
                pixelFormatType: kCVPixelFormatType_32BGRA, isPlanar: false,
                width: 10, height: 5, bytesPerRow: 40, dataSize: 199)
            s.expect(byteCount == nil, "undersized reported dataSize rejected")
        }

        s.check("validatedPixelGeometry: a zero reported dataSize is treated as unknown, not rejected") { s in
            let byteCount = ScreenCaptureKitSource.validatedPixelGeometry(
                pixelFormatType: kCVPixelFormatType_32BGRA, isPlanar: false,
                width: 10, height: 5, bytesPerRow: 40, dataSize: 0)
            s.expectEqual(byteCount, 200, "dataSize == 0 is not enforced as a lower bound")
        }
    }

    static func checkValidatedPixelCopy(_ s: CheckSuite) {
        func makeBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, nil, &buffer)
            guard status == kCVReturnSuccess else { return nil }
            return buffer
        }

        s.check("validatedPixelCopy: accepts a valid non-planar 32BGRA buffer and copies its contents byte-for-byte") { s in
            guard let buffer = makeBuffer(width: 4, height: 3, pixelFormat: kCVPixelFormatType_32BGRA) else {
                s.expect(false, "failed to construct a valid 32BGRA test CVPixelBuffer")
                return
            }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess, let base = CVPixelBufferGetBaseAddress(buffer) else {
                s.expect(false, "failed to lock the test buffer to seed its contents")
                return
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let totalBytes = bytesPerRow * height
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for i in 0..<totalBytes { ptr[i] = UInt8(truncatingIfNeeded: i) }
            let sourceSnapshot = Data(bytes: base, count: totalBytes)
            CVPixelBufferUnlockBaseAddress(buffer, [])

            guard let copy = ScreenCaptureKitSource.validatedPixelCopy(from: buffer) else {
                s.expect(false, "expected a successful copy for a valid buffer")
                return
            }
            s.expectEqual(copy.width, 4, "width preserved")
            s.expectEqual(copy.height, 3, "height preserved")
            s.expectEqual(copy.bytesPerRow, bytesPerRow, "bytesPerRow preserved")
            s.expectEqual(copy.data.count, bytesPerRow * copy.height, "copies exactly bytesPerRow * height bytes")
            s.expect(copy.data == sourceSnapshot, "copy matches source contents byte-for-byte")
        }

        s.check("validatedPixelCopy: rejects a planar buffer even with otherwise-valid dimensions") { s in
            guard let buffer = makeBuffer(width: 4, height: 4, pixelFormat: kCVPixelFormatType_420YpCbCr8Planar) else {
                s.expect(false, "failed to construct a planar test CVPixelBuffer")
                return
            }
            s.expect(ScreenCaptureKitSource.validatedPixelCopy(from: buffer) == nil, "planar buffer rejected")
        }

        s.check("validatedPixelCopy: rejects a non-BGRA packed format") { s in
            guard let buffer = makeBuffer(width: 4, height: 4, pixelFormat: kCVPixelFormatType_32ARGB) else {
                s.expect(false, "failed to construct a 32ARGB test CVPixelBuffer")
                return
            }
            s.expect(ScreenCaptureKitSource.validatedPixelCopy(from: buffer) == nil, "wrong packed format (32ARGB) rejected, not merely '4 bytes/pixel'")
        }
    }

    static func checkScreenCaptureConfigurationPlan(_ s: CheckSuite) {
        s.check("ScreenCaptureConfigurationPlan: .audioOnly always produces video == nil with an unchanged audio plan") { s in
            let noWindow = ScreenCaptureConfigurationPlan.plan(for: .audioOnly, meetingWindowResolved: false)
            let withWindow = ScreenCaptureConfigurationPlan.plan(for: .audioOnly, meetingWindowResolved: true)
            s.expect(noWindow.video == nil, "audioOnly + no window ⇒ no video plan")
            s.expect(withWindow.video == nil, "audioOnly + resolved window ⇒ still no video plan — the off state cannot be influenced by window resolution")
            s.expectEqual(noWindow.audio, withWindow.audio, "audio plan identical regardless of window resolution")
            s.expectEqual(noWindow.audio.width, 2, "2x2 audio plane")
            s.expectEqual(noWindow.audio.height, 2, "2x2 audio plane")
            s.expect(noWindow.audio.capturesAudio, "audio plan captures audio")
            s.expectEqual(noWindow.audio.sampleHandlerQoS, .userInitiated, "audio QoS unchanged")
            // HIGH-1 regression lock: the audio display/filter must always be
            // scoped to the single matched app, never the wider PID family
            // video/meeting-window resolution uses.
            s.expectEqual(noWindow.audio.displayPIDScope, .singleMatchedApp, "audio display selection scoped to the single matched app, not the PID family")
            s.expect(noWindow.audio.filterIncludesSingleMatchedAppOnly, "audio filter's `including:` list is exactly the single matched app")
            s.expect(noWindow.audio.excludesCurrentProcessAudio, "audio filter excludes Alembic's own process audio")
            s.expectEqual(noWindow.audio.channelCount, 2, "stereo audio")
            s.expectEqual(noWindow.audio.sampleRate, 48_000, "48kHz audio")
            s.expectEqual(noWindow.audio.minimumFrameIntervalFPS, 1, "1fps video-plane throttle on the audio stream")
            s.expect(!noWindow.audio.showsCursor, "audio stream never shows the cursor")
        }

        s.check("ScreenCaptureConfigurationPlan: .audioPlusAttribution with no resolved window still produces video == nil") { s in
            let plan = ScreenCaptureConfigurationPlan.plan(for: .audioPlusAttribution, meetingWindowResolved: false)
            s.expect(plan.video == nil, "no window ⇒ no video plan even in attribution mode")
            let audioOnlyPlan = ScreenCaptureConfigurationPlan.plan(for: .audioOnly, meetingWindowResolved: false)
            s.expectEqual(plan.audio, audioOnlyPlan.audio, "audio plan unchanged")
        }

        s.check("ScreenCaptureConfigurationPlan: .audioPlusAttribution with a resolved window adds an independent video plan") { s in
            let plan = ScreenCaptureConfigurationPlan.plan(for: .audioPlusAttribution, meetingWindowResolved: true)
            guard let video = plan.video else {
                s.expect(false, "expected a non-nil video plan")
                return
            }
            s.expect(!video.capturesAudio, "video stream never captures audio")
            s.expectEqual(video.sampleHandlerQoS, .utility, "video QoS is .utility")
            s.expect(video.usesWindowScopedFilter, "video filter is window-scoped, never app-level")
            s.expectEqual(video.pixelFormat, .bgra8, "video pixel format is always .bgra8")
            s.expect(video.requiresPositiveMeetingEvidence, "video stream only ever created behind the positive-meeting-evidence gate (HIGH-2)")
            let audioOnlyPlan = ScreenCaptureConfigurationPlan.plan(for: .audioOnly, meetingWindowResolved: false)
            s.expectEqual(plan.audio, audioOnlyPlan.audio, "audio plan unaffected by adding the video plan")
        }
    }

    /// Belt-and-suspenders static source audit (following
    /// `checkFoundationOnlyTopLevelAudit`'s precedent of asserting properties
    /// of the *source tree* rather than of runtime behavior) — supplemental
    /// to `checkScreenCaptureConfigurationPlan` above, not a substitute for
    /// it: proves the audio-stream construction block in
    /// `ScreenCaptureKitSource.swift` cannot branch on `mode`, that the
    /// audio-plane constants and QoS are unconditionally reachable, that the
    /// video-only output/`startCapture()` calls are reachable only from the
    /// `.audioPlusAttribution` branch, and that the pixel-buffer lock's
    /// return code is checked before use.
    static func checkScreenCaptureAudioIdentitySourceAudit(_ s: CheckSuite) {
        s.check("ScreenCaptureKitSource.swift: audio construction never branches on `mode`; video gated on .audioPlusAttribution") { s in
            let path = "Sources/AlembicKit/Platform/macOS/ScreenCaptureKitSource.swift"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                s.expect(false, "could not read \(path)")
                return
            }

            guard
                let configRange = content.range(of: "let config = SCStreamConfiguration()"),
                let selfStreamRange = content.range(of: "self.stream = stream")
            else {
                s.expect(false, "could not locate the audio stream construction block markers")
                return
            }
            let audioBlock = content[configRange.lowerBound..<selfStreamRange.upperBound]
            s.expect(!audioBlock.contains("mode"), "audio stream construction block does not reference `mode` anywhere")

            s.expect(audioBlock.contains("config.width = 2"), "audio plane width constant present and reachable, unconditionally")
            s.expect(audioBlock.contains("config.height = 2"), "audio plane height constant present and reachable, unconditionally")
            s.expect(audioBlock.contains("qos: .userInitiated"), "audio output QoS present in the unconditional block")

            let useInitiatedCount = content.components(separatedBy: "qos: .userInitiated").count - 1
            s.expectEqual(useInitiatedCount, 1, "audio's .userInitiated QoS appears exactly once in the file")

            guard
                let modeSwitchRange = content.range(of: "switch mode {"),
                let videoAddRange = content.range(of: "videoStream.addStreamOutput(frameOutput, type: .screen"),
                let videoStartRange = content.range(of: "try await box.stream.startCapture()")
            else {
                s.expect(false, "could not locate the mode switch / video output-registration markers")
                return
            }
            s.expect(videoAddRange.lowerBound > modeSwitchRange.lowerBound, "video .screen output registration occurs only after the mode switch")
            s.expect(videoStartRange.lowerBound > modeSwitchRange.lowerBound, "videoStream.startCapture() occurs only after the mode switch")

            s.expect(
                content.contains("CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess"),
                "validatedPixelCopy checks the CVPixelBufferLockBaseAddress return code before reading buffer state")

            // HIGH-1 regression lock: the audio display selection must use the
            // single matched app's PID (`appPID`/`app.processID`), never the
            // wider `pids` family the meeting-window resolver above it uses.
            guard let appWindowsRange = content.range(of: "let appWindows = content.windows.filter { $0.owningApplication?.processID == appPID }") else {
                s.expect(false, "audio display's appWindows filter must scope to appPID (single matched app), not the pids family — literal line not found")
                return
            }
            s.expect(!content.contains("let appWindows = content.windows.filter { pids.contains"), "audio display selection must never be scoped to the pids family")

            // MEDIUM-1 regression lock: microphone capture must start before
            // any video-stream work, so a slow/blocked video startup can
            // never delay it.
            guard
                let startMicRange = content.range(of: "try startMic(clock: clock)"),
                let modeSwitchRange2 = content.range(of: "switch mode {")
            else {
                s.expect(false, "could not locate startMic call / mode switch markers")
                return
            }
            s.expect(startMicRange.lowerBound < modeSwitchRange2.lowerBound, "startMic(clock:) is called before the video-stream mode switch, never after")
            s.expect(appWindowsRange.lowerBound < modeSwitchRange2.lowerBound, "audio display selection (appPID-scoped) resolves before the video mode switch")
            s.expect(content.contains("videoStartupTask = Task"),
                     "video startup runs in an independent task so audio consumption can begin immediately")
            s.expect(content.contains("startVideoStream(VideoStreamBox(videoStream), timeout: .seconds(3))"),
                     "video startup has a bounded three-second wait and an owned non-Sendable stream box")

            // MEDIUM-2: the audio-stream literal constants this source audit
            // already pins (channelCount/sampleRate/excludesCurrentProcessAudio/
            // minimumFrameInterval/showsCursor) must match
            // `ScreenCaptureConfigurationPlan`'s fixed `AudioPlan` values, so
            // the seam and production cannot silently drift apart.
            s.expect(audioBlock.contains("config.channelCount = 2"), "production audio channelCount matches AudioPlan.channelCount")
            s.expect(audioBlock.contains("config.sampleRate = 48_000"), "production audio sampleRate matches AudioPlan.sampleRate")
            s.expect(audioBlock.contains("config.excludesCurrentProcessAudio = true"), "production audio excludesCurrentProcessAudio matches AudioPlan")
            s.expect(audioBlock.contains("config.minimumFrameInterval = CMTime(value: 1, timescale: 1)"), "production audio minimumFrameInterval matches AudioPlan (1fps)")
            s.expect(audioBlock.contains("config.showsCursor = false"), "production audio showsCursor matches AudioPlan")
            s.expect(audioBlock.contains("SCContentFilter(display: display, including: [app]"), "audio filter's including: list is exactly [app] — the single matched app, matching AudioPlan.filterIncludesSingleMatchedAppOnly")

            // HIGH-2 regression lock: video window resolution must be gated on
            // positive meeting-window evidence, not exclusion-list survival
            // alone.
            s.expect(content.contains("hasPositiveMeetingEvidence"), "resolveMeetingWindowID consults hasPositiveMeetingEvidence before returning a windowID")
        }
    }

    /// impl-review-2 HIGH-1 regression lock: video-only attribution failures
    /// (no meeting window resolved, video `SCStream` setup failure, video
    /// `SCStream` mid-session stop) must never be able to reach
    /// `ScreenCaptureKitSource.errors` — the fatal channel
    /// `MeetingSession.handleSourceError` treats as terminal (flush + close
    /// the session). They may only finish `frames` and, at most, surface on
    /// the separate non-fatal `attributionDiagnostics` stream. This is a
    /// static source audit (same precedent as
    /// `checkScreenCaptureAudioIdentitySourceAudit`/
    /// `checkFoundationOnlyTopLevelAudit`) because exercising a real
    /// `SCStream` failure requires live ScreenCaptureKit capture, which this
    /// harness cannot do.
    static func checkVideoErrorIsolationSourceAudit(_ s: CheckSuite) {
        s.check("ScreenCaptureKitSource.swift: video-only failures never reach the fatal `errors` stream") { s in
            let path = "Sources/AlembicKit/Platform/macOS/ScreenCaptureKitSource.swift"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                s.expect(false, "could not read \(path)")
                return
            }

            // `ScreenCaptureKitSource` must expose two DISTINCT public
            // `CaptureSourceError` streams: the fatal `errors` (audio/mic
            // only) and the non-fatal `attributionDiagnostics` (video only).
            s.expect(
                content.contains("public nonisolated let errors: AsyncStream<CaptureSourceError>"),
                "public fatal `errors` stream is declared")
            s.expect(
                content.contains("public nonisolated let attributionDiagnostics: AsyncStream<CaptureSourceError>"),
                "public non-fatal `attributionDiagnostics` stream is declared, distinct from `errors`")

            // `StreamFrameOutput` (the video-only delegate/output object) must
            // hold no reference at all to the fatal continuation: no stored
            // property/parameter named `errors`, and its own `didStopWithError`
            // must yield only onto `diagnostics`.
            guard
                let frameOutputStart = content.range(of: "final class StreamFrameOutput"),
                let audioSourceMarker = content.range(of: "// MARK: - macOS AudioSource")
            else {
                s.expect(false, "could not locate StreamFrameOutput class / macOS AudioSource section markers")
                return
            }
            let frameOutputBlock = content[frameOutputStart.lowerBound..<audioSourceMarker.lowerBound]
            // Targeted at the declaration/parameter shape, not the substring
            // "errors" in general — the corrective doc comment on
            // `didStopWithError` legitimately mentions `errors` in prose (to
            // say it is NOT used), so a blanket substring ban would false-fail.
            s.expect(!frameOutputBlock.contains("let errors:"), "StreamFrameOutput declares no `errors`-named stored property")
            s.expect(!frameOutputBlock.contains("errors: AsyncStream<CaptureSourceError>.Continuation"), "StreamFrameOutput's init takes no `errors:` parameter")
            s.expect(frameOutputBlock.contains("private let diagnostics: AsyncStream<CaptureSourceError>.Continuation"), "StreamFrameOutput's only CaptureSourceError sink is `diagnostics`")
            s.expect(frameOutputBlock.contains("diagnostics.yield(.streamStopped(\"video:"), "StreamFrameOutput.didStopWithError yields only onto `diagnostics`")
            s.expect(!frameOutputBlock.contains("errorContinuation"), "StreamFrameOutput never references the outer `errorContinuation`")

            // Every video-only `.streamStopped(\"video: ...\")` yield site in
            // the whole file (didStopWithError, no-window, disappeared-window,
            // startup-timeout, setup-catch) must
            // route through `diagnostics`/`attributionDiagnosticsContinuation`
            // — never `errors`/`errorContinuation`. Count both sides so a
            // future added/removed video failure site cannot silently regress
            // past this audit (five known sites today).
            let videoStreamStoppedSites = content.components(separatedBy: "\"video:").count - 1
            s.expectEqual(videoStreamStoppedSites, 5, "exactly five video-only failure message sites exist")
            let fatalYieldOfVideoMessage = content.contains("errorContinuation.yield(.streamStopped(\"video:") || content.contains("errors.yield(.streamStopped(\"video:")
            s.expect(!fatalYieldOfVideoMessage, "no video-only failure message is ever yielded onto the fatal errors/errorContinuation sink")
            let nonFatalYieldCount = content.components(separatedBy: "attributionDiagnosticsContinuation.yield(.streamStopped(\"video:").count - 1
                + content.components(separatedBy: "diagnostics.yield(.streamStopped(\"video:").count - 1
            s.expectEqual(nonFatalYieldCount, 5, "all five video-only failure sites yield onto the non-fatal diagnostics sink")

            // `errorContinuation.yield` must never appear at all in the file —
            // the only fatal producer is `StreamAudioOutput.errors.yield`
            // (fed by `errorContinuation` only through its `init`, at the
            // audio-only construction call site below).
            s.expect(!content.contains("errorContinuation.yield"), "errorContinuation is never yielded onto directly — only StreamAudioOutput.errors.yield (audio-fatal) exists")

            // The audio `StreamAudioOutput` init call is the only place
            // `errorContinuation` is threaded into a delegate object — proves
            // the video `StreamFrameOutput` init call (below) cannot also
            // receive it.
            let errorContinuationInitSites = content.components(separatedBy: "errors: errorContinuation").count - 1
            s.expectEqual(errorContinuationInitSites, 1, "errorContinuation is threaded into exactly one delegate init call — StreamAudioOutput's (audio, fatal)")
            s.expect(content.contains("diagnostics: attributionDiagnosticsContinuation"), "StreamFrameOutput's init call is threaded attributionDiagnosticsContinuation, not errorContinuation")

            // `stop()` must terminate both sinks so a consumer of either
            // stream always observes clean completion.
            s.expect(content.contains("errorContinuation.finish()"), "stop() finishes the fatal errors stream")
            s.expect(content.contains("attributionDiagnosticsContinuation.finish()"), "stop() finishes the non-fatal attributionDiagnostics stream")
        }
    }

    static func checkFoundationOnlyTopLevelAudit(_ s: CheckSuite) {
        let forbiddenFrameworks: [String] = [
            "AVFoundation", "CoreMedia", "ScreenCaptureKit", "Speech",
            "CoreGraphics", "AppKit", "UIKit", "SwiftUI", "Combine",
            "CoreAudio", "AudioToolbox", "CoreBluetooth",
            // Phase 7 §6 addition: explicitly named in the plan's layering
            // audit ("no Apple-framework import ... Vision, AppKit,
            // ApplicationServices"). Both are only ever imported under
            // `Sources/AlembicKit/Platform/macOS/` (`VisionSpeakerAttributor.
            // swift`, `DiagnosticVideoCapture.swift`), which this scan
            // already excludes via `.skipsSubdirectoryDescendants` — adding
            // them here makes that exemption an explicit, checked fact
            // rather than an accidental one (absence-by-omission).
            "Vision", "ApplicationServices",
        ]

        let topLevelDir = URL(fileURLWithPath: "Sources/AlembicKit")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: topLevelDir,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else {
            s.expect(false, "Foundation-only audit: cannot enumerate Sources/AlembicKit/")
            return
        }

        var auditedCount = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let filename = url.lastPathComponent
            auditedCount += 1

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                for fw in forbiddenFrameworks {
                    s.expect(
                        !trimmed.contains(fw),
                        "Foundation-only violation: \(filename) imports \(fw)"
                    )
                }
            }
        }
        s.expect(auditedCount > 0,
                 "Foundation-only audit checked at least one file (Sources/AlembicKit/ found)")
    }

    // MARK: - Phase 7: frame-dump dispatch/validation, calibration canary, off-toggle proof, §3a–§3e regressions

    /// Confirms `SubcommandDispatch.resolve` wires `frame-dump` alongside
    /// `ax-dump`/`audio-watch`, and that a bogus subcommand resolves to
    /// `.unknown` — never `exit`, never invoking `main()` itself (which does
    /// call `exit(64)` for `.unknown` and must never run mid-suite).
    static func checkFrameDumpSubcommandRegistered(_ s: CheckSuite) {
        s.check("SubcommandDispatch.resolve wires frame-dump/ax-dump/audio-watch and rejects unknown, without ever calling exit") { s in
            s.expectEqual(
                SubcommandDispatch.resolve(arguments: ["AlembicCheck", "frame-dump", "--list-windows"]),
                .frameDump(args: ["--list-windows"]),
                "frame-dump dispatches with its sub-arguments"
            )
            s.expectEqual(
                SubcommandDispatch.resolve(arguments: ["AlembicCheck", "ax-dump", "--out", "x"]),
                .axDump(args: ["--out", "x"]),
                "ax-dump still dispatches correctly alongside frame-dump"
            )
            s.expectEqual(
                SubcommandDispatch.resolve(arguments: ["AlembicCheck", "audio-watch", "5"]),
                .audioWatch(seconds: 5),
                "audio-watch still dispatches correctly alongside frame-dump"
            )
            s.expectEqual(
                SubcommandDispatch.resolve(arguments: ["AlembicCheck"]),
                .checkSuite,
                "no subcommand argument resolves to running the check suite"
            )
            switch SubcommandDispatch.resolve(arguments: ["AlembicCheck", "bogus-subcommand"]) {
            case .unknown(let name):
                s.expectEqual(name, "bogus-subcommand", "an unrecognized subcommand's name is captured for the printed guidance")
            default:
                s.expect(false, "expected .unknown for a bogus subcommand name")
            }
        }
    }

    /// Exercises `FrameDumpProbe.validate(...)` — a pure function, no TCC/
    /// window-server/capture touched — against the three required-passing
    /// structural contracts (resolves plan-review-2 HIGH-1/MEDIUM-2): (a)
    /// `--include-images` without an explicit, allowed `--out` is rejected;
    /// (b) a bare bundle-prefix is rejected while `--meeting-title`/
    /// `--window-id` succeed; (c) `--list-windows` combined with any
    /// capture-only flag is rejected. No check here calls `FrameDumpProbe.run`.
    static func checkFrameDumpValidatePureContract(_ s: CheckSuite) {
        let packageRoot = "/repo/app/Alembic"
        let repoRoot = "/repo"
        let gitignorePatterns = ["app/Alembic/.frame-dump-scratch/"]
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        func validate(_ arguments: [String], cwd: String = "/repo/app/Alembic") -> Result<FrameDumpProbe.Plan, FrameDumpProbe.ValidationError> {
            FrameDumpProbe.validate(
                arguments: arguments, packageRoot: packageRoot, repoRoot: repoRoot,
                gitignorePatterns: gitignorePatterns, cwd: cwd, now: fixedNow
            )
        }

        s.check("FrameDumpProbe.validate: bare bundle-prefix fails closed; --meeting-title/--window-id succeed (positive-evidence contract)") { s in
            switch validate(["com.microsoft.teams"]) {
            case .failure(.missingPositiveEvidence): s.expect(true, "bare bundle-prefix rejected")
            default: s.expect(false, "bare bundle-prefix should fail with .missingPositiveEvidence")
            }
            switch validate(["com.microsoft.teams", "--meeting-title", "Weekly Standup"]) {
            case .success(let plan): s.expectEqual(plan.resolution, .meetingTitle("Weekly Standup"), "--meeting-title resolves successfully")
            default: s.expect(false, "--meeting-title should succeed")
            }
            switch validate(["com.microsoft.teams", "--window-id", "42"]) {
            case .success(let plan): s.expectEqual(plan.resolution, .windowID(42), "--window-id resolves successfully")
            default: s.expect(false, "--window-id should succeed")
            }
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--window-id", "1"]) {
            case .failure(.ambiguousPositiveEvidence): s.expect(true, "both --meeting-title and --window-id together is rejected as ambiguous")
            default: s.expect(false, "supplying both --meeting-title and --window-id should fail with .ambiguousPositiveEvidence")
            }
        }

        s.check("FrameDumpProbe.validate: --include-images requires an explicit, allowed --out") { s in
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--include-images"]) {
            case .failure(.includeImagesRequiresExplicitOut): s.expect(true, "--include-images without --out rejected")
            default: s.expect(false, "--include-images without --out should fail with .includeImagesRequiresExplicitOut")
            }
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--include-images", "--out", "/tmp/frame-dump-out"]) {
            case .success: s.expect(true, "--include-images with an explicit out-of-repo --out succeeds")
            default: s.expect(false, "--include-images with an out-of-repo --out should succeed")
            }
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--out", "/repo/scratch"]) {
            case .failure(.outInsideRepoNotGitignored): s.expect(true, "an in-repo, non-gitignored --out is rejected")
            default: s.expect(false, "an in-repo, non-gitignored --out should fail with .outInsideRepoNotGitignored")
            }
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--out", "/repo/app/Alembic/.frame-dump-scratch/manual"]) {
            case .success: s.expect(true, "an in-repo --out under the gitignored diagnostics directory succeeds")
            default: s.expect(false, "an in-repo, gitignored --out should succeed")
            }
        }

        s.check("FrameDumpProbe.validate: --list-windows is mutually exclusive with capture-only flags, and succeeds alone") { s in
            switch validate(["com.microsoft.teams", "--list-windows"]) {
            case .success(let plan): s.expectEqual(plan.resolution, .listWindows, "--list-windows alone succeeds")
            default: s.expect(false, "--list-windows alone should succeed")
            }
            for combo in [
                ["com.microsoft.teams", "--list-windows", "--frames", "3"],
                ["com.microsoft.teams", "--list-windows", "--interval", "2"],
                ["com.microsoft.teams", "--list-windows", "--out", "/tmp/x"],
                ["com.microsoft.teams", "--list-windows", "--include-images"],
                ["com.microsoft.teams", "--list-windows", "--meeting-title", "X"],
                ["com.microsoft.teams", "--list-windows", "--window-id", "1"],
            ] {
                switch validate(combo) {
                case .failure(.listWindowsMutuallyExclusive): s.expect(true, "\(combo): rejected as mutually exclusive")
                default: s.expect(false, "\(combo) should fail with .listWindowsMutuallyExclusive")
                }
            }
        }

        s.check("FrameDumpProbe.validate: default output path is package-root-relative scratch directory, not a literal app/Alembic/... string") { s in
            switch validate(["com.microsoft.teams", "--meeting-title", "X"]) {
            case .success(let plan):
                s.expect(plan.outPath.hasPrefix(packageRoot + "/.frame-dump-scratch/"), "default --out is <packageRoot>/.frame-dump-scratch/<timestamp>")
                s.expect(!plan.outPath.contains("app/Alembic/app/Alembic"), "default --out never doubles up the app/Alembic path segment")
            default: s.expect(false, "omitting --out (without --include-images) should succeed with a default scratch path")
            }
        }

        // impl-review-1 HIGH-1: an explicit `--out` must be canonicalized
        // relative to `cwd` (resolving `.`/`..` and, on real disk, symlinks)
        // *before* the privacy allowlist check — a relative or `..`-escaping
        // path that actually resolves inside the repository (and outside the
        // gitignored scratch directory) must be rejected exactly like an
        // equivalent absolute in-repo path, not silently treated as "outside
        // the repo entirely" merely because the raw string doesn't start
        // with the repo root.
        s.check("FrameDumpProbe.validate: a relative --out is canonicalized against cwd before the privacy allowlist check (impl-review-1 HIGH-1)") { s in
            // A bare relative path, run from inside the package root (the
            // repo's documented `cd app/Alembic` precondition), resolves to
            // an in-repo, non-gitignored location and must be rejected —
            // previously this was erroneously treated as "outside the repo"
            // because the raw string never starts with the absolute
            // repoRoot.
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--out", "frame-dump-out"], cwd: "/repo/app/Alembic") {
            case .failure(.outInsideRepoNotGitignored(let raw)):
                s.expectEqual(raw, "frame-dump-out", "the error echoes the caller's original relative string")
            default:
                s.expect(false, "a relative --out resolving in-repo (non-gitignored) should fail with .outInsideRepoNotGitignored")
            }

            // A `..`-escaping relative path that still resolves inside the
            // repository (one level up from the package root, still under
            // `/repo`) must likewise be rejected — `..` must not be usable
            // to dodge the string-prefix check while staying in-repo.
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--out", "../alembic-dump"], cwd: "/repo/app/Alembic") {
            case .failure(.outInsideRepoNotGitignored): s.expect(true, "a `..`-escaping --out that still resolves in-repo is rejected")
            default: s.expect(false, "../alembic-dump from /repo/app/Alembic (still inside /repo) should fail with .outInsideRepoNotGitignored")
            }

            // A relative path that legitimately points at the gitignored
            // scratch directory must still succeed once canonicalized.
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--out", ".frame-dump-scratch/manual"], cwd: "/repo/app/Alembic") {
            case .success(let plan):
                s.expectEqual(plan.outPath, "/repo/app/Alembic/.frame-dump-scratch/manual", "the relative gitignored-scratch --out canonicalizes to the expected absolute path")
            default:
                s.expect(false, "a relative --out under the gitignored scratch directory should succeed")
            }

            // A relative path that genuinely resolves outside the
            // repository entirely (three levels up from the package root
            // exits /repo) must still succeed, exactly like an equivalent
            // absolute out-of-repo --out.
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--out", "../../../tmp/frame-dump-out"], cwd: "/repo/app/Alembic") {
            case .success(let plan):
                s.expectEqual(plan.outPath, "/tmp/frame-dump-out", "a relative --out that resolves outside the repo entirely canonicalizes correctly and succeeds")
            default:
                s.expect(false, "a relative --out resolving outside the repo entirely should succeed")
            }
        }

        // impl-review-1 LOW-1: the parser must fail deterministically on
        // malformed input, before any TCC/window-server access, rather than
        // silently accepting a typo'd flag as the bundle-prefix positional
        // argument or leaving `--catalog` without a value.
        s.check("FrameDumpProbe.validate: unknown flags, a missing --catalog value, and multiple bundle prefixes all fail closed (impl-review-1 LOW-1)") { s in
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--bogus-flag"]) {
            case .failure(.unknownFlag(let flag)): s.expectEqual(flag, "--bogus-flag", "the unrecognized flag's exact text is captured")
            default: s.expect(false, "an unrecognized --flag should fail with .unknownFlag, not be silently accepted")
            }

            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--catalog"]) {
            case .failure(.missingValueForFlag("--catalog")): s.expect(true, "a trailing, value-less --catalog is rejected")
            default: s.expect(false, "--catalog with no following value should fail with .missingValueForFlag(\"--catalog\")")
            }

            // A recognized --catalog value is still accepted and discarded
            // as before (no regression from the missing-value check above).
            switch validate(["com.microsoft.teams", "--meeting-title", "X", "--catalog", "teamsDefaults"]) {
            case .success: s.expect(true, "--catalog with a value still succeeds and is discarded")
            default: s.expect(false, "--catalog <value> should still succeed")
            }

            switch validate(["com.microsoft.teams", "com.microsoft.teams2", "--meeting-title", "X"]) {
            case .failure(.multipleBundlePrefixes(let first, let second)):
                s.expectEqual(first, "com.microsoft.teams", "the first positional argument is preserved")
                s.expectEqual(second, "com.microsoft.teams2", "the second positional argument is captured, not silently overwriting the first")
            default:
                s.expect(false, "two positional (non-flag) arguments should fail with .multipleBundlePrefixes")
            }
        }
    }

    /// Proves the **actual measured** marker evidence from the 2026-08-18
    /// live 1-on-1 calibration pass distinguishes active-speaking frames
    /// from inactive ones through `teamsDefaults`'s real, shipped marker —
    /// not a synthetic/rounded stand-in like
    /// `checkVisionSpeakerAttributorCropAndColor`'s `#808080` fixture. Both
    /// sampled colors below are the exact averages measured from the
    /// gitignored `app/Alembic/.frame-dump-scratch/
    /// live-calibration-remote-20260818/` capture (frames 2–6/8–9 active,
    /// 1/7/10 inactive) — sanitized as numeric-only color triples here,
    /// exactly as `docs/2-speaker-attribution/calibration-record.md`
    /// records them; no image/OCR/participant data is read or referenced.
    static func checkTeamsOneOnOneMarkerCalibration(_ s: CheckSuite) {
        s.check("SpeakerLabelCatalog.teamsDefaults marker: measured active-frame color matches, measured inactive-frame color does not (2026-08-18 live calibration)") { s in
            guard let marker = SpeakerLabelCatalog.teamsDefaults.candidates.first?.activeTileMarkers.first else {
                s.expect(false, "the first teamsDefaults candidate must retain the measured 1-on-1 marker")
                return
            }

            s.check("SpeakerLabelCatalog Gallery marker: both measured active speakers match; inactive and silent samples do not") { s in
                guard let marker = SpeakerLabelCatalog.teamsDefaults.candidates.dropFirst().first?.activeTileMarkers.first else {
                    s.expect(false, "Gallery candidates must ship a measured marker")
                    return
                }
                s.expectEqual(marker.hexColor, "#8288FC",
                              "Gallery uses the measured 2400px-capture outline color")
                let firstActive = (r: 129.0 / 255.0, g: 135.0 / 255.0, b: 251.0 / 255.0)
                let secondActive = (r: 130.0 / 255.0, g: 136.0 / 255.0, b: 252.0 / 255.0)
                let inactive = (r: 86.0 / 255.0, g: 88.0 / 255.0, b: 71.0 / 255.0)
                let silent = (r: 121.0 / 255.0, g: 132.0 / 255.0, b: 128.0 / 255.0)
                s.expect(VisionSpeakerAttributor.markerMatches(marker, sampledColor: firstActive),
                         "the first measured active participant outline matches")
                s.expect(VisionSpeakerAttributor.markerMatches(marker, sampledColor: secondActive),
                         "the second measured active participant outline matches")
                s.expect(!VisionSpeakerAttributor.markerMatches(marker, sampledColor: inactive),
                         "an inactive tile does not match")
                s.expect(!VisionSpeakerAttributor.markerMatches(marker, sampledColor: silent),
                         "the no-outline silent frame does not match")
            }

            s.check("SpeakerLabelCatalog three-person markers: each remote speaker matches independently and crosstalk remains detectable") { s in
                let candidates = Array(SpeakerLabelCatalog.teamsDefaults.candidates.suffix(2))
                guard candidates.count == 2,
                      let top = candidates[0].activeTileMarkers.first,
                      let bottom = candidates[1].activeTileMarkers.first
                else {
                    s.expect(false, "three-person remote candidates must retain measured markers")
                    return
                }
                let topActive = (r: 137.0 / 255.0, g: 143.0 / 255.0, b: 254.0 / 255.0)
                let topInactive = (r: 139.0 / 255.0, g: 155.0 / 255.0, b: 144.0 / 255.0)
                let bottomActive = (r: 128.0 / 255.0, g: 134.0 / 255.0, b: 234.0 / 255.0)
                let bottomInactive = (r: 194.0 / 255.0, g: 213.0 / 255.0, b: 211.0 / 255.0)
                s.expect(VisionSpeakerAttributor.markerMatches(top, sampledColor: topActive),
                         "top remote active outline matches")
                s.expect(!VisionSpeakerAttributor.markerMatches(top, sampledColor: topInactive),
                         "top remote inactive edge does not match")
                s.expect(VisionSpeakerAttributor.markerMatches(bottom, sampledColor: bottomActive),
                         "bottom remote active outline matches")
                s.expect(!VisionSpeakerAttributor.markerMatches(bottom, sampledColor: bottomInactive),
                         "bottom remote inactive edge does not match")
                s.expect(VisionSpeakerAttributor.singleActiveCandidate(matchedCandidateIndices: [8, 9]) == nil,
                         "two simultaneous remote outlines remain ambiguous")
            }
            s.expectEqual(marker.hexColor, "#797EE5", "the shipped marker's expected color is the measured 2026-08-18 evidence, not the Phase 2 MVP's #6264A7 guess")
            s.expect(marker.colorTolerance >= 0.08 && marker.colorTolerance <= 0.10,
                     "the shipped tolerance is the conservative, calibration-record-documented 0.08-0.10 range")
            // Marker region: a 1px-wide column at frame-x=3 of a 1600px-wide
            // frame, y-inset within the measured y=120..960 span.
            s.expect(abs(marker.region.x - 3.0 / 1600.0) < 1e-9, "marker region x is the measured x=3/1600 column")
            s.expect(abs(marker.region.width - 1.0 / 1600.0) < 1e-9, "marker region width is a single measured pixel (1/1600)")
            s.expect(marker.region.y >= 120.0 / 1000.0 - 1e-9, "marker region y starts at or after the measured y=120 lower bound")
            s.expect(marker.region.y + marker.region.height <= 960.0 / 1000.0 + 1e-9,
                     "marker region ends at or before the measured y=960 upper bound (safe vertical inset)")

            // Measured average sampled color, active-speaking frames
            // (2, 3, 4, 5, 6, 8, 9): ~(122, 127, 228)/255.
            let activeSampled = (r: 122.0 / 255.0, g: 127.0 / 255.0, b: 228.0 / 255.0)
            s.expect(VisionSpeakerAttributor.markerMatches(marker, sampledColor: activeSampled),
                     "the measured active-speaking-frame color matches the shipped marker within its calibrated tolerance")

            // Measured average sampled color, inactive frames (1, 7, 10):
            // a distinctly different neutral gray/tan, ~(183, 181, 177)/255.
            let inactiveSampled = (r: 183.0 / 255.0, g: 181.0 / 255.0, b: 177.0 / 255.0)
            s.expect(!VisionSpeakerAttributor.markerMatches(marker, sampledColor: inactiveSampled),
                     "the measured inactive-frame color never matches the shipped marker — the calibrated tolerance does not overreach")
        }
    }

    /// **Source-content audit, not a live gating test** (`AlembicCheck`
    /// depends only on `AlembicKit` — see `Package.swift`'s target graph —
    /// and cannot import the `Alembic` app target to drive
    /// `AppModel.start()` directly). Locks the structural contract that
    /// `AppModel.start()`'s attribution gate is the conjunction of both the
    /// calibration gate (toggle enabled AND `speakerEntry?.markersValidated`)
    /// AND the layout/title gate (`speakerEntry?.matchesLayout(meetingTitle:)`)
    /// — never either alone — so an unsupported group/share Teams layout can
    /// never start attribution video even when the toggle is on and the
    /// catalog entry is validated. Mirrors the style of
    /// `checkDiagnosticVideoCaptureVisibilityAudit`/
    /// `checkDiagnosticVideoCaptureBoundedCaptureSourceAudit` (structural
    /// source-text assertions for a fact that cannot be exercised through a
    /// pure function call from this target).
    static func checkAppModelAttributionGateAudit(_ s: CheckSuite) {
        s.check("AppModel.start(): attributionGated requires BOTH calibrationGated (markersValidated) AND matchesLayout(meetingTitle:) — never either alone") { s in
            guard let content = try? String(contentsOfFile: "Sources/Alembic/AppModel.swift", encoding: .utf8) else {
                s.expect(false, "cannot read Sources/Alembic/AppModel.swift for the attribution-gate audit")
                return
            }
            s.expect(content.contains("calibrationGated = attributionEnabled && (speakerEntry?.markersValidated ?? false)"),
                     "calibrationGated must require both the toggle and speakerEntry.markersValidated")
            s.expect(content.contains("attributionGated = calibrationGated && (speakerEntry?.matchesLayout(meetingTitle: meetingTitle) ?? false)"),
                     "attributionGated must require calibrationGated AND speakerEntry.matchesLayout(meetingTitle:) — a validated entry with an unsupported (e.g. group/share) layout must never gate video/provider construction")
            s.expect(content.contains("if attributionGated {"),
                     "the attribution-mode capture source/runtime must be constructed only inside an `if attributionGated` branch")
        }
    }

    /// Canary, updated at Phase 7's live-calibration pass (2026-08-18): the
    /// pre-calibration form of this check asserted `markersValidated ==
    /// false` and was *expected* to fail, loudly, the moment a human
    /// completed live calibration — that moment has now happened for the
    /// strict Teams 1-on-1 layout (see `SpeakerLabelCatalog.teamsDefaults`'s
    /// doc comment and `docs/2-speaker-attribution/calibration-record.md`,
    /// Calibration Pass #1). This check now asserts the **narrower**,
    /// evidence-backed claim that flip is justified for: `markersValidated
    /// == true` **and** the committed calibration record exists on disk and
    /// documents this exact evidence (date, frame dimensions, title
    /// fragment) — not the broader multi-participant/grid scope. It reads
    /// only the calibration-record file's presence/content (never any
    /// frame-dump scratch evidence, which is gitignored and never read by
    /// this check) via `FrameDumpProbe.packageRoot(startingAt:)`'s existing
    /// runtime package-root resolution, so this check works regardless of
    /// the shell's current directory at invocation time.
    static func checkTeamsOneOnOneCalibrationEvidence(_ s: CheckSuite) {
        s.check("Canary (updated): SpeakerLabelCatalog.teamsDefaults.markersValidated == true is backed by a committed 1-on-1 calibration record") { s in
            s.expect(
                SpeakerLabelCatalog.teamsDefaults.markersValidated,
                "markersValidated is expected true for the calibrated Teams 1-on-1 layout as of the 2026-08-18 live " +
                "calibration pass — see docs/2-speaker-attribution/calibration-record.md, Calibration Pass #1"
            )
            s.expectEqual(SpeakerLabelCatalog.teamsDefaults.candidates.count, 10,
                          "the validated claim covers all measured 1-on-1, three-person, and Gallery candidates")

            let fileManager = FileManager.default
            guard let packageRoot = FrameDumpProbe.packageRoot(startingAt: fileManager.currentDirectoryPath) else {
                s.expect(false, "cannot resolve the Swift package root to locate the calibration record")
                return
            }
            let calibrationRecordPath = URL(fileURLWithPath: packageRoot)
                .appendingPathComponent("../../docs/2-speaker-attribution/calibration-record.md")
                .standardizedFileURL.path
            guard let content = try? String(contentsOfFile: calibrationRecordPath, encoding: .utf8) else {
                s.expect(false, "docs/2-speaker-attribution/calibration-record.md must exist and be readable once markersValidated == true; not found at \(calibrationRecordPath)")
                return
            }
            s.expect(!content.contains("NOT YET CALIBRATED"),
                     "the calibration record must no longer be the blank/templated placeholder once markersValidated == true")
            s.expect(content.contains("2026-08-18"), "the calibration record documents the capture date")
            s.expect(content.contains("1600") && content.contains("1000"), "the calibration record documents the measured 1600×1000 frame dimensions")
            s.expect(content.contains("2400") && content.contains("926"), "the calibration record documents the measured 2400×926 Gallery frame dimensions")
            s.expect(content.contains(":: 1 on 1"), "the calibration record documents the exact title fragment used for the layout gate")
            s.expect(!content.lowercased().contains(".png"),
                     "the calibration record contains no raw image file references (sanitized, numeric evidence only)")
        }
    }

    /// Authoritative, deterministic proof of AC-3/UR-4's byte-identical
    /// off-toggle requirement (resolves plan-review-3 MEDIUM-1) — a fixed,
    /// fake-event fixture run twice: once with `attributionProvider: nil`
    /// (production's exact toggle-off wiring — `AppModel`'s gating on
    /// `alembic.attribution.enabled` never constructs or passes a provider
    /// into `MeetingSession` at all when the toggle is off, confirmed by
    /// reading `Sources/Alembic/AppModel.swift`'s `start()`, since
    /// `AlembicCheck` cannot import the `Alembic` app target — see
    /// `Package.swift`'s target graph — to drive that gating decision
    /// directly), and once with a `FakeAttributionProvider` physically wired
    /// in but scripted to never yield a result. Asserts the two runs' raw
    /// `.jsonl` bytes AND rendered `.md` bytes are **exactly equal** — not a
    /// field-by-field "shape" comparison — proving no stray `attribution`
    /// object, no `"vision"` source, no reordering, and no incidental
    /// formatting drift regardless of whether attribution wiring exists in
    /// memory. A live, in-meeting toggle-off smoke check (§4 "10b") MAY
    /// additionally be performed by a human but is explicitly
    /// non-authoritative — only this deterministic, fixed-fixture check
    /// proves AC-3 going forward (it cannot control for timestamp/ASR
    /// nondeterminism the way a live capture can).
    static func checkOffToggleByteIdenticalOutput(_ s: CheckSuite) async {
        await s.checkAsync("MeetingSession: off-toggle output is byte-identical (.jsonl AND .md) whether an attribution provider is wired in and yields nothing, or absent entirely — authoritative deterministic AC-3/UR-4 proof") { s in
            func makeTempDir() throws -> URL {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("alembic-off-toggle-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            }
            func decodeLines(_ url: URL) throws -> [FinalizedSegmentDTO] {
                let text = try String(contentsOf: url, encoding: .utf8)
                let dec = JSONDecoder()
                return try text.split(separator: "\n", omittingEmptySubsequences: true).map {
                    try dec.decode(FinalizedSegmentDTO.self, from: Data($0.utf8))
                }
            }
            // Fixed date (not `Date()`): both runs' `.md` frontmatter must be
            // byte-identical too, and `MeetingContext.yamlFrontmatter()`
            // embeds `startDate` — a real wall-clock `Date()` would make the
            // two runs' `.md` bytes differ by construction, unrelated to
            // attribution.
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            func makeWriterFactory(_ dir: URL) -> @Sendable () throws -> TranscriptWriter {
                { try TranscriptWriter(meetingName: "OffToggleFixture", directory: dir, date: fixedDate, writeReadableRender: true) }
            }
            func chunk(_ source: SourceTag, _ start: Double) -> AudioChunk {
                AudioChunk(samples: [0.1, 0.2], sampleRate: 48_000, channelCount: 1, source: source, startTime: start)
            }
            func script() -> (you: FakeTranscriptionEngine, them: FakeTranscriptionEngine, source: FakeAudioSource) {
                (
                    FakeTranscriptionEngine(script: [
                        TranscriptEvent(kind: .finalized, source: .you, start: 0, end: 1, text: "hello"),
                    ], emitOnStart: true),
                    FakeTranscriptionEngine(script: [
                        TranscriptEvent(kind: .finalized, source: .them, start: 1, end: 2, text: "hi there"),
                    ], emitOnStart: false),
                    FakeAudioSource(script: [chunk(.you, 0), chunk(.them, 1)], finishAfterScript: true)
                )
            }

            // --- Run A: attributionProvider: nil (today's only shipped state / the toggle-off wiring). ---
            let dirA = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dirA) }
            let (youA, themA, sourceA) = script()
            let sessionA = await MainActor.run {
                MeetingSession(audioSource: sourceA, engineFactory: { tag, _ in tag == .you ? youA : themA },
                               makeWriter: makeWriterFactory(dirA))
            }
            await sessionA.loadTargets()
            await sessionA.start(target: sessionA.availableTargets.first!)
            s.expect(
                await waitUntil { await MainActor.run { !sessionA.finalizedTranscript.isEmpty } },
                "run A: first finalized event observed within the bounded barrier timeout"
            )
            await sessionA.stop()
            guard case .saved(let urlA) = await sessionA.state, let mdURLA = await sessionA.readableURL else {
                s.expect(false, "run A (no provider) did not save"); return
            }
            let jsonlA = try Data(contentsOf: urlA)
            let mdA = try Data(contentsOf: mdURLA)

            // --- Run B: a FakeAttributionProvider IS wired in (mirroring an
            // AttributionRuntime existing in memory) but scripted to never
            // yield a result — the closest deterministic proxy to "the
            // toggle is off" available from MeetingSession's own public API.
            // `AppModel`'s actual toggle-off gating (never constructing or
            // passing a provider at all when `alembic.attribution.enabled ==
            // false`) lives in the `Alembic` app target, which `AlembicCheck`
            // cannot import (see `Package.swift`: `AlembicCheck` depends only
            // on `AlembicKit`) — so this run instead proves the next-best,
            // still-meaningful fact: a provider's mere presence in memory,
            // absent an actual attributed result, is never itself observable
            // in the persisted schema.
            let dirB = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dirB) }
            let (youB, themB, sourceB) = script()
            let provider = FakeAttributionProvider(defaultResult: nil)
            let sessionB = await MainActor.run {
                MeetingSession(audioSource: sourceB, engineFactory: { tag, _ in tag == .you ? youB : themB },
                               makeWriter: makeWriterFactory(dirB), attributionProvider: provider)
            }
            await sessionB.loadTargets()
            await sessionB.start(target: sessionB.availableTargets.first!)
            s.expect(
                await waitUntil { await MainActor.run { !sessionB.finalizedTranscript.isEmpty } },
                "run B: first finalized event observed within the bounded barrier timeout"
            )
            await sessionB.stop()
            guard case .saved(let urlB) = await sessionB.state, let mdURLB = await sessionB.readableURL else {
                s.expect(false, "run B (provider present, never yields) did not save"); return
            }
            let jsonlB = try Data(contentsOf: urlB)
            let mdB = try Data(contentsOf: mdURLB)

            s.expectEqual(jsonlB, jsonlA, "off-toggle proof: raw .jsonl bytes are byte-identical whether an attribution provider is wired in (and yields nothing) or absent entirely")
            s.expectEqual(mdB, mdA, "off-toggle proof: rendered .md bytes are byte-identical whether an attribution provider is wired in (and yields nothing) or absent entirely")
            s.expect(try decodeLines(urlA).allSatisfy { $0.attribution == nil }, "run A: no segment carries attribution")
            s.expect(try decodeLines(urlB).allSatisfy { $0.attribution == nil }, "run B: no segment carries attribution")
        }
    }

    /// §3a regression (Phase 2 impl-review-1 LOW finding, folded into Phase
    /// 7): `ActiveSpeakerTimeline`'s retention `trim()` must remove **every**
    /// stale interval regardless of its position in the sorted-by-
    /// `lowerBound` array, not merely stop at the first non-stale element
    /// scanned from the front. A long early interval (large `upperBound`,
    /// small `lowerBound`) followed by a short, *nested* later interval
    /// (small `upperBound`, but a larger `lowerBound` so it still sorts
    /// after the long one) proves the position-independent behavior: the
    /// old prefix-stop trim would see the long interval at the front is not
    /// stale and stop immediately, silently leaving the genuinely-stale
    /// short interval behind it untouched — the exact under-trim this fix
    /// closes.
    static func checkActiveSpeakerTimelineRetentionTrimOutOfOrderUpperBounds(_ s: CheckSuite) {
        s.check("ActiveSpeakerTimeline.record: retention trim removes a stale nested interval even when the front (longer) interval is still fresh") { s in
            var timeline = ActiveSpeakerTimeline(configuration: .init(minConfidence: 0, minOverlapFraction: 0, coalesceGap: 0, retentionWindow: 100))
            // Long early interval: lowerBound 0, upperBound 1000 — sorts
            // first (smallest lowerBound) and, once both records exist, has
            // the *largest* upperBound (1000), so it is never stale here.
            timeline.record(name: "Zoe", confidence: 1.0, in: 0...1000)
            // Short interval nested inside Zoe's timespan: lowerBound 5 (>
            // Zoe's lowerBound, so it sorts *after* Zoe) but upperBound 8 —
            // far smaller than Zoe's. Once both are recorded, mostRecentUpperBound
            // == 1000, cutoff == 1000 - 100 == 900: Zoe (1000) is fresh, Sam
            // (8) is genuinely stale, and Sam sits *behind* Zoe in the
            // sorted array — exactly the position the old prefix-stop trim
            // could never reach.
            timeline.record(name: "Sam", confidence: 1.0, in: 5...8)

            let remaining = timeline.intervals.map(\.name)
            s.expect(!remaining.contains("Sam"), "the short, nested, genuinely-stale interval is trimmed even though it sits behind the still-fresh long interval in sorted order")
            s.expect(remaining.contains("Zoe"), "the still-fresh long interval survives retention trimming")
        }
    }

    /// §3a regression (Phase 2 impl-review-1 LOW finding, folded into Phase
    /// 7): `VocabularyStore.naturalOrder(from:)` must apply the same
    /// `count >= 2` part-filter `expandName(_:)`'s own comma branch already
    /// uses on the same string, not a looser `!isEmpty` filter — otherwise a
    /// three-part comma name with a short (single-character) trailing part
    /// regresses silently from natural-order expansion to the untouched
    /// original once `expandName` delegates to `naturalOrder`.
    static func checkVocabularyStoreNaturalOrderExpandNameParity(_ s: CheckSuite) {
        s.check("VocabularyStore.naturalOrder/expandName parity: a comma name with a one-character trailing part still expands to natural order") { s in
            s.expectEqual(VocabularyStore.naturalOrder(from: "Kim, Alex, M"), "Alex Kim",
                          "naturalOrder filters the short trailing part the same way expandName's own comma-branch filter does")
            s.expectEqual(VocabularyStore.expandName("Kim, Alex, M"), ["Kim", "Alex", "Alex Kim"],
                          "expandName's own two-part decision and naturalOrder's recomputed parts stay in sync end-to-end")
        }
    }

    /// §3d regression (Phase 5 impl-review-1 MEDIUM-1, folded into Phase 7):
    /// `VisionSpeakerAttributor.croppedBGRA`/`averageBGRAColor` must reject
    /// (not trap on) an under-stride `bytesPerRow` (smaller than
    /// `frameWidth * 4` / `width * 4`) and must never overflow-trap on
    /// adversarially large dimensions — the exact pixel math `FrameDumpProbe`
    /// also reuses, so a fix here protects the diagnostic tool too.
    static func checkVisionSpeakerAttributorCropOverflowSafety(_ s: CheckSuite) {
        s.check("VisionSpeakerAttributor.croppedBGRA/averageBGRAColor: under-stride bytesPerRow is rejected, not read out of bounds") { s in
            // frameWidth 10 needs bytesPerRow >= 40; declare a too-small 20
            // with a data buffer sized to match that (wrong) declared stride
            // so the `data.count == bytesPerRow * frameHeight` check alone
            // would not catch the under-stride condition.
            let frameWidth = 10, frameHeight = 4, bytesPerRow = 20
            let data = Data(repeating: 0xAB, count: bytesPerRow * frameHeight)
            let cropped = VisionSpeakerAttributor.croppedBGRA(
                from: data, frameWidth: frameWidth, frameHeight: frameHeight, bytesPerRow: bytesPerRow,
                rect: (x: 0, y: 0, width: frameWidth, height: frameHeight)
            )
            s.expect(cropped == nil, "croppedBGRA rejects bytesPerRow < frameWidth * 4 rather than reading skewed/undersized rows")

            let averaged = VisionSpeakerAttributor.averageBGRAColor(
                data: data, width: frameWidth, height: frameHeight, bytesPerRow: bytesPerRow
            )
            s.expect(averaged == nil, "averageBGRAColor rejects bytesPerRow < width * 4 the same way")
        }

        s.check("VisionSpeakerAttributor.croppedBGRA/averageBGRAColor: adversarially large dimensions fail closed (nil) instead of trapping on overflow") { s in
            // Near Int.max/4 so `width * 4` (unchecked) would overflow/trap;
            // `multipliedReportingOverflow` must catch this before any crash.
            let hugeWidth = Int.max / 4 + 10
            let cropped = VisionSpeakerAttributor.croppedBGRA(
                from: Data([0, 0, 0, 0]), frameWidth: hugeWidth, frameHeight: 1, bytesPerRow: 4,
                rect: (x: 0, y: 0, width: 1, height: 1)
            )
            s.expect(cropped == nil, "croppedBGRA fails closed rather than trapping on an overflow-adjacent frameWidth")

            let averaged = VisionSpeakerAttributor.averageBGRAColor(
                data: Data([0, 0, 0, 0]), width: hugeWidth, height: 1, bytesPerRow: 4
            )
            s.expect(averaged == nil, "averageBGRAColor fails closed rather than trapping on an overflow-adjacent width")
        }

        s.check("VisionSpeakerAttributor.croppedBGRA: adversarially huge rect coordinates fail closed (nil) instead of trapping on overflow (impl-review-1 MEDIUM-3)") { s in
            // A normal, small, valid frame — the adversarial part is only
            // `rect`, whose `x`/`width` (and separately `y`/`height`) are
            // huge enough that the *bounds-check addition itself*
            // (`rect.x + rect.width <= frameWidth`) would overflow/trap if
            // computed with plain `+` instead of `addingReportingOverflow`.
            let frameWidth = 100, frameHeight = 100, bytesPerRow = 400
            let data = Data(repeating: 0xAB, count: bytesPerRow * frameHeight)

            let hugeXRect = VisionSpeakerAttributor.croppedBGRA(
                from: data, frameWidth: frameWidth, frameHeight: frameHeight, bytesPerRow: bytesPerRow,
                rect: (x: Int.max - 5, y: 0, width: 10, height: 1)
            )
            s.expect(hugeXRect == nil, "croppedBGRA fails closed rather than trapping when rect.x + rect.width overflows Int")

            let hugeWidthRect = VisionSpeakerAttributor.croppedBGRA(
                from: data, frameWidth: frameWidth, frameHeight: frameHeight, bytesPerRow: bytesPerRow,
                rect: (x: 0, y: 0, width: Int.max - 5, height: 1)
            )
            s.expect(hugeWidthRect == nil, "croppedBGRA fails closed rather than trapping when rect.width alone is overflow-adjacent")

            let hugeYRect = VisionSpeakerAttributor.croppedBGRA(
                from: data, frameWidth: frameWidth, frameHeight: frameHeight, bytesPerRow: bytesPerRow,
                rect: (x: 0, y: Int.max - 5, width: 1, height: 10)
            )
            s.expect(hugeYRect == nil, "croppedBGRA fails closed rather than trapping when rect.y + rect.height overflows Int")

            let hugeHeightRect = VisionSpeakerAttributor.croppedBGRA(
                from: data, frameWidth: frameWidth, frameHeight: frameHeight, bytesPerRow: bytesPerRow,
                rect: (x: 0, y: 0, width: 1, height: Int.max - 5)
            )
            s.expect(hugeHeightRect == nil, "croppedBGRA fails closed rather than trapping when rect.height alone is overflow-adjacent")
        }
    }

    /// §3d regression (Phase 5 impl-review-1 MEDIUM-2, folded into Phase 7):
    /// `VisionSpeakerAttributor.advance`'s fresh-start branch must clamp
    /// `start` to the previous open interval's `end` when the fresh start is
    /// for a **different** speaker, so a speaker change never records two
    /// overlapping intervals for two different names (a wrong-name risk, not
    /// merely "no attribution" — conflicts with SR-12's no-guess posture).
    static func checkVisionSpeakerAttributorAdvanceNoOverlapOnSpeakerChange(_ s: CheckSuite) {
        s.check("VisionSpeakerAttributor.advance: a speaker change never produces two overlapping recorded intervals") { s in
            let open = VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.9, start: 0, end: 10)
            // frameTime just past `open.end`, but far enough that
            // `frameTime - fallbackLookback` would fall *before* open.end
            // without the clamp (fallbackLookback = 5, frameTime = 10.5 ⇒
            // unclamped start = 5.5, well inside 0...10).
            let step = VisionSpeakerAttributor.advance(
                open: open, frameTime: 10.5, outcome: .detected(name: "Sam", confidence: 0.9),
                maxGap: 2.5, fallbackLookback: 5
            )
            guard let recording = step.recording else {
                s.expect(false, "expected a recording for the new speaker's fresh-start interval"); return
            }
            s.expectEqual(recording.name, "Sam", "the new speaker's name is recorded")
            s.expect(recording.range.lowerBound >= open.end, "the new interval's start is clamped to the prior open interval's end (\(open.end)), never overlapping it — got \(recording.range.lowerBound)")
        }

        s.check("VisionSpeakerAttributor.advance: a same-speaker fresh start after a long gap is unaffected by the overlap clamp") { s in
            let open = VisionSpeakerAttributor.OpenInterval(name: "Alex", confidence: 0.9, start: 0, end: 10)
            // Long gap since `open.end` (frameTime 100), same speaker: this is
            // a fresh start (gap exceeds maxGap), not a speaker change — the
            // clamp must not apply, so the ordinary fallbackLookback anchor
            // is used exactly as before this fix.
            let step = VisionSpeakerAttributor.advance(
                open: open, frameTime: 100, outcome: .detected(name: "Alex", confidence: 0.9),
                maxGap: 2.5, fallbackLookback: 5
            )
            guard let recording = step.recording else {
                s.expect(false, "expected a recording for the same speaker's fresh-start-after-gap interval"); return
            }
            s.expectEqual(recording.range.lowerBound, 95, "a same-speaker fresh start after a long gap still anchors at frameTime - fallbackLookback, unaffected by the speaker-change overlap clamp")
        }
    }

    /// Source audit (impl-review-1 MEDIUM-2): `DiagnosticVideoCapture` is a
    /// raw meeting-window frame-capture primitive whose purpose is
    /// explicitly sensitive (screenshots/OCR of live meeting content) — it
    /// must be `package`-visible only, never `public`, so no consumer of
    /// `AlembicKit` as a library dependency outside this Swift package can
    /// see or call it. `AlembicCheck` (the only in-package caller) still
    /// works because `package` is visible across targets within the same
    /// `Package.swift`.
    static func checkDiagnosticVideoCaptureVisibilityAudit(_ s: CheckSuite) {
        s.check("DiagnosticVideoCapture.swift: the type and its API surface are package-visible, never public") { s in
            let path = "Sources/AlembicKit/Platform/macOS/DiagnosticVideoCapture.swift"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                s.expect(false, "could not read \(path)")
                return
            }

            s.expect(content.contains("package actor DiagnosticVideoCapture"), "DiagnosticVideoCapture is declared `package`, not `public`")
            s.expect(!content.contains("public actor DiagnosticVideoCapture"), "DiagnosticVideoCapture is never declared `public`")

            // No line in the file declares a `public` member of any kind —
            // the entire diagnostic capture surface (type, nested types,
            // methods, initializers) must be `package` or narrower.
            var publicMemberLines: [String] = []
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("public ") || trimmed.contains(" public ") {
                    publicMemberLines.append(trimmed)
                }
            }
            s.expect(publicMemberLines.isEmpty, "no `public` declaration remains in DiagnosticVideoCapture.swift — found: \(publicMemberLines)")

            s.expect(content.contains("package static func listWindows"), "listWindows is package-visible")
            s.expect(content.contains("package func captureFrames"), "the bounded captureFrames(...) entry point is package-visible")
            s.expect(content.contains("package func stop"), "stop() is package-visible")
            s.expect(content.contains("package init()"), "init() is package-visible")
        }
    }

    /// Source audit (impl-review-1 MEDIUM-1): `captureFrames(...)` must be
    /// bounded by both a first-frame and inter-frame timeout, and must
    /// guarantee `stop()` runs on every exit path — success, thrown error,
    /// and task cancellation. The underlying async timeout-race behavior
    /// itself is not independently pure-testable here (it needs a live
    /// `SCStream`), so this audit locks the structural contract in source:
    /// the timeout parameters exist, the cancellation handler is wired, and
    /// both the success and failure paths call `stop()` before returning/
    /// rethrowing. Also confirms `FrameDumpProbe.runCapture` calls the
    /// bounded `captureFrames(...)` entry point rather than the raw
    /// `start()`/manual-loop/manual-`stop()` pattern the finding flagged.
    static func checkDiagnosticVideoCaptureBoundedCaptureSourceAudit(_ s: CheckSuite) {
        s.check("DiagnosticVideoCapture.captureFrames: first/inter-frame timeouts and guaranteed stop() on every exit path") { s in
            let path = "Sources/AlembicKit/Platform/macOS/DiagnosticVideoCapture.swift"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                s.expect(false, "could not read \(path)")
                return
            }

            guard
                let captureFramesRange = content.range(of: "package func captureFrames("),
                let collectFramesStart = content.range(of: "private func collectFrames(")
            else {
                s.expect(false, "could not locate captureFrames(...)'s declaration")
                return
            }
            let captureFramesBody = content[captureFramesRange.lowerBound..<collectFramesStart.lowerBound]

            s.expect(captureFramesBody.contains("firstFrameTimeout: Duration"), "captureFrames declares a firstFrameTimeout parameter")
            s.expect(captureFramesBody.contains("interFrameTimeout: Duration"), "captureFrames declares an interFrameTimeout parameter")
            s.expect(captureFramesBody.contains("withTaskCancellationHandler"), "captureFrames wraps consumption in withTaskCancellationHandler")
            s.expect(captureFramesBody.contains("onCancel"), "captureFrames supplies an onCancel handler")

            // Both the success path (after the cancellation-handler call
            // returns) and the catch path must call `stop()` — a guaranteed
            // teardown on every exit, not just the happy path.
            let stopCallCount = captureFramesBody.components(separatedBy: "await stop()").count - 1
            s.expect(stopCallCount >= 2, "captureFrames calls await stop() on both the success path and the catch/error path (found \(stopCallCount) call(s))")
            s.expect(captureFramesBody.contains("} catch {"), "captureFrames has an explicit catch block guaranteeing stop() before rethrowing")

            guard let collectFramesBody = content.range(of: "private func collectFrames(").map({ content[$0.lowerBound...] }) else {
                s.expect(false, "could not locate collectFrames(...)'s body")
                return
            }
            s.expect(collectFramesBody.contains("Task.checkCancellation()"), "collectFrames checks for cancellation on every loop iteration")
            s.expect(collectFramesBody.contains("firstFrameTimeout : interFrameTimeout") || collectFramesBody.contains("firstFrameTimeout: firstFrameTimeout, interFrameTimeout: interFrameTimeout"), "collectFrames threads both timeouts through to nextFrame")
        }

        s.check("FrameDumpProbe.runCapture: calls the bounded captureFrames(...) entry point, not a manual start()/loop/stop()") { s in
            let path = "Sources/AlembicCheck/FrameDumpProbe.swift"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                s.expect(false, "could not read \(path)")
                return
            }
            s.expect(content.contains("capture.captureFrames("), "runCapture calls DiagnosticVideoCapture.captureFrames(...)")
            s.expect(!content.contains("capture.start("), "runCapture no longer calls the raw start(...) directly")
            s.expect(!content.contains("capture.stop()"), "runCapture no longer manually calls capture.stop() — captureFrames guarantees teardown itself")
        }
    }
}
