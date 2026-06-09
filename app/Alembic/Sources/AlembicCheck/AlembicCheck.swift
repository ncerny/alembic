import Foundation
import AlembicKit

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
        let suite = CheckSuite()
        await runAllChecks(suite)
        suite.finishAndExit()
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
        checkMeetingDetectionPolicy(s)
        checkDetectInCall(s)
        checkMeetingDetector(s)
        checkMeetingContext(s)
        checkBestTitle(s)
        checkFoundationOnlyTopLevelAudit(s)
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
            }
        }
        func chunk(_ source: SourceTag, _ start: Double) -> AudioChunk {
            AudioChunk(samples: [0.1, 0.2], sampleRate: 48_000, channelCount: 1, source: source, startTime: start)
        }
        func makeWriterFactory(_ dir: URL) -> @Sendable () throws -> TranscriptWriter {
            { try TranscriptWriter(meetingName: "Session", directory: dir) }
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

        s.check("MeetingAppCatalog.isInCall: Slack in-call via input OR output") { s in
            let viaInput = [AudioProcessState(pid: 100, bundleID: "com.tinyspeck.slackmacgap",
                                              isRunningInput: true, isRunningOutput: false)]
            s.expect(MeetingAppCatalog.isInCall(processStates: viaInput) != nil,
                     "Slack in-call via input alone")

            let viaOutput = [AudioProcessState(pid: 100, bundleID: "com.tinyspeck.slackmacgap",
                                               isRunningInput: false, isRunningOutput: true)]
            s.expect(MeetingAppCatalog.isInCall(processStates: viaOutput) != nil,
                     "Slack in-call via output alone")

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
    static func checkFoundationOnlyTopLevelAudit(_ s: CheckSuite) {
        let forbiddenFrameworks: [String] = [
            "AVFoundation", "CoreMedia", "ScreenCaptureKit", "Speech",
            "CoreGraphics", "AppKit", "UIKit", "SwiftUI", "Combine",
            "CoreAudio", "AudioToolbox", "CoreBluetooth",
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
}
