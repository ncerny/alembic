// Milestone 0 spike: real-time, on-device Teams transcription.
//
// Proves the high-risk plumbing for the standalone-app pivot:
//   1. Continuous single/dual-engine transcription via SpeechAnalyzer + SpeechTranscriber (macOS 26+),
//      with NO 1-minute reset (the limitation that forced the old SFSpeechRecognizer hack).
//   2. Offline asset installation (AssetInventory.assetInstallationRequest).
//   3. Audio-format conversion from 48 kHz capture buffers -> analyzer's bestAvailableAudioFormat
//      via a persistent AVAudioConverter, done OFF the capture callback thread.
//   4. Volatile vs finalized result behaviour.
//   5. Dual-engine ("them" = Teams output, "me" = mic) with FULL isolation + backpressure metrics.
//   6. Finalization drain on stop (finalizeAndFinishThroughEndOfInput) loses no trailing utterances.
//
// This is throwaway spike code, not the final app. It is intentionally a single file.
//
// Usage:
//   realtime-transcribe --app "Microsoft Teams" --output /tmp/meeting.jsonl [--duration 120]
//                       [--app-only | --mic-only]

import Foundation
import ScreenCaptureKit
import AVFoundation
import Speech

// MARK: - Shared types

@available(macOS 26, *)
enum SourceLabel: String {
    case them   // remote participants (Teams app audio)
    case me     // local user (microphone)
}

// Capture buffers are normalised to this format before per-pipeline conversion to the analyzer format.
let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

// MARK: - Transcript writer (single session clock, one JSONL file)

final class TranscriptWriter {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "transcript.writer")
    private let sessionStart: Date

    init(outputURL: URL, sessionStart: Date) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: outputURL)
        self.sessionStart = sessionStart
    }

    /// Append one finalized segment as a JSON line. `source` lets downstream tools tell who spoke.
    func appendFinal(source: String, text: String) {
        let elapsed = Date().timeIntervalSince(sessionStart)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let obj: [String: Any] = [
            "t": (round(elapsed * 1000) / 1000),   // session-relative seconds (wall clock; spike approximation)
            "source": source,
            "text": trimmed,
        ]
        queue.async {
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                self.handle.write(data)
                self.handle.write(Data("\n".utf8))
            }
        }
    }

    func close() {
        queue.sync {
            try? self.handle.synchronize()
            try? self.handle.close()
        }
    }
}

// MARK: - One isolated transcription pipeline per audio source

@available(macOS 26, *)
final class SourcePipeline {
    let label: SourceLabel
    private let writer: TranscriptWriter

    private var transcriber: SpeechTranscriber!
    private var analyzer: SpeechAnalyzer!
    private var analyzerFormat: AVAudioFormat!
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation!
    private var consumptionTask: Task<Void, Never>?

    // Persistent converter: 48 kHz mono float32 -> analyzerFormat. Created once.
    private var converter: AVAudioConverter?
    // Conversion runs off the capture callback thread.
    private let convertQueue: DispatchQueue

    // Backpressure / health metrics.
    private(set) var enqueued = 0
    private(set) var dropped = 0
    private(set) var finalizedSegments = 0
    private(set) var finalizedChars = 0

    init(label: SourceLabel, writer: TranscriptWriter) {
        self.label = label
        self.writer = writer
        self.convertQueue = DispatchQueue(label: "pipeline.convert.\(label.rawValue)")
    }

    /// Resolve locale, build the transcriber, install assets, pick the analyzer audio format.
    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber not available on this device"])
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw NSError(domain: "spike", code: 2, userInfo: [NSLocalizedDescriptionKey: "Locale \(Locale.current.identifier) not supported"])
        }

        // progressiveTranscription => volatile + fast results, the right preset for live captions.
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = t

        let installed = await SpeechTranscriber.installedLocales
        let alreadyInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        if !alreadyInstalled {
            log("[\(label.rawValue)] installing speech model assets for \(locale.identifier(.bcp47))…")
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                try await req.downloadAndInstall()
                log("[\(label.rawValue)] assets installed")
            } else {
                log("[\(label.rawValue)] assets already present (no installation request needed)")
            }
        } else {
            log("[\(label.rawValue)] assets already installed")
        }

        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw NSError(domain: "spike", code: 3, userInfo: [NSLocalizedDescriptionKey: "No compatible analyzer audio format"])
        }
        self.analyzerFormat = fmt
        log("[\(label.rawValue)] analyzer format: \(Int(fmt.sampleRate))Hz \(fmt.channelCount)ch")
    }

    /// Start the analyzer + result-consumption loop.
    func start() async throws {
        // Bounded buffer so a slow analyzer can't grow memory without bound; we count drops.
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.inputBuilder = builder

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        self.analyzer = analyzer

        let results = transcriber.results
        let label = self.label
        consumptionTask = Task { [weak self] in
            do {
                for try await result in results {
                    let chunk = String(result.text.characters)
                    if result.isFinal {
                        self?.finalizedSegments += 1
                        self?.finalizedChars += chunk.count
                        self?.writer.appendFinal(source: label.rawValue, text: chunk)
                        log("[\(label.rawValue) FINAL] \(chunk)")
                    } else {
                        // Volatile = live caption; show but never persist.
                        log("[\(label.rawValue) …] \(chunk)")
                    }
                }
            } catch {
                log("[\(label.rawValue)] result stream error: \(error.localizedDescription)")
            }
        }

        try await analyzer.start(inputSequence: stream)
        log("[\(label.rawValue)] analyzer started")
    }

    /// Called from capture callbacks. Hops off the callback thread, converts, then yields.
    func enqueueCapture(_ buffer: AVAudioPCMBuffer) {
        // Copy now; the source buffer may be reused by the capture system after we return.
        guard let copy = Self.copy(buffer) else { return }
        convertQueue.async { [weak self] in
            self?.process(copy)
        }
    }

    /// Convert one 48 kHz mono buffer to the analyzer format and yield it (records backpressure).
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let builder = inputBuilder else { return }
        guard let converted = convertToAnalyzerFormat(buffer) else { return }
        let result = builder.yield(AnalyzerInput(buffer: converted))
        switch result {
        case .enqueued: enqueued += 1
        case .dropped: dropped += 1
        case .terminated: break
        @unknown default: break
        }
    }

    /// Graceful stop: finish input, drain all trailing finalized results, then return.
    func finish() async {
        inputBuilder?.finish()
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                log("[\(label.rawValue)] finalize failed: \(error.localizedDescription)")
            }
        }
        // Wait for the consumption loop to flush every remaining finalized result.
        await consumptionTask?.value
        log("[\(label.rawValue)] drained")
    }

    // MARK: - Conversion

    private func convertToAnalyzerFormat(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil {
            converter = AVAudioConverter(from: captureFormat, to: analyzerFormat)
        }
        guard let converter else { return nil }

        let ratio = analyzerFormat.sampleRate / captureFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, inStatus in
            if fed {
                inStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inStatus.pointee = .haveData
            return input
        }
        if let error {
            log("[\(label.rawValue)] convert error: \(error.localizedDescription)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = out.floatChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        }
        return out
    }

    func metricsLine() -> String {
        "[\(label.rawValue)] enqueued=\(enqueued) dropped=\(dropped) finalSegments=\(finalizedSegments) finalChars=\(finalizedChars)"
    }

    /// Test helper: feed a known audio file through the live pipeline (proves real transcription).
    /// Feeds synchronously so finish() isn't called before buffers are yielded.
    func feedFile(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        log("[\(label.rawValue)] test file format: \(Int(inFormat.sampleRate))Hz \(inFormat.channelCount)ch, frames=\(file.length)")
        let frames: AVAudioFrameCount = 8192
        var reads = 0
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { break }
            do {
                try file.read(into: buf)
            } catch {
                log("[\(label.rawValue)] read error after \(reads) reads: \(error.localizedDescription)")
                break
            }
            if buf.frameLength == 0 { break }
            reads += 1
            process(CaptureCoordinator.downmixTo48kMono(buf))
        }
        log("[\(label.rawValue)] fed \(reads) chunks")
    }
}

// MARK: - Audio capture (ScreenCaptureKit for app/"them", AVAudioEngine for mic/"me")

@available(macOS 26, *)
final class CaptureCoordinator: NSObject, SCStreamDelegate, SCStreamOutput {
    private let themPipeline: SourcePipeline?
    private let mePipeline: SourcePipeline?
    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?
    private var loggedAppFormat = false

    init(them: SourcePipeline?, me: SourcePipeline?) {
        self.themPipeline = them
        self.mePipeline = me
    }

    func startAppCapture(appName: String) async throws {
        guard let themPipeline else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.applicationName.localizedCaseInsensitiveContains(appName) }) else {
            throw NSError(domain: "spike", code: 10, userInfo: [NSLocalizedDescriptionKey: "App '\(appName)' not found. Run the existing helper's `list` to see options."])
        }
        guard let display = content.displays.first else {
            throw NSError(domain: "spike", code: 11, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        log("capturing app audio from \(app.applicationName) (pid \(app.processID))")

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 2
        config.sampleRate = 48000
        config.width = 2
        config.height = 2

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
        try await s.startCapture()
        self.stream = s
        _ = themPipeline // keep
    }

    func startMicCapture() {
        guard let mePipeline else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        log("mic format: \(Int(inFormat.sampleRate))Hz \(inFormat.channelCount)ch")
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let mono = Self.downmixTo48kMono(buffer)
            mePipeline.enqueueCapture(mono)
        }
        do {
            try engine.start()
            self.audioEngine = engine
            log("mic capture started")
        } catch {
            log("mic capture failed: \(error.localizedDescription)")
        }
    }

    func stopCapture() async {
        if let stream {
            try? await stream.stopCapture()
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // SCStreamOutput: app audio buffers.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let themPipeline else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let channels = Int(asbd.pointee.mChannelsPerFrame)
        let sampleRate = asbd.pointee.mSampleRate
        let nonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if !loggedAppFormat {
            loggedAppFormat = true
            log("app audio format: \(Int(sampleRate))Hz \(channels)ch \(nonInterleaved ? "non-interleaved" : "interleaved")")
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false),
              let src = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        src.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            for ch in 0..<channels {
                guard let cd = src.floatChannelData?[ch] else { continue }
                for frame in 0..<frameCount {
                    cd[frame] = nonInterleaved ? f[ch * frameCount + frame] : f[frame * channels + ch]
                }
            }
        }
        themPipeline.enqueueCapture(Self.downmixTo48kMono(src))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("SCStream stopped with error: \(error.localizedDescription)")
    }

    /// Downmix to mono and resample to 48 kHz float32 (the common capture format pipelines expect).
    static func downmixTo48kMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let channels = Int(buffer.format.channelCount)
        let sr = buffer.format.sampleRate

        // Mono downmix.
        var mono = buffer
        if channels > 1, let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false),
           let mb = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: buffer.frameLength) {
            mb.frameLength = buffer.frameLength
            for frame in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for ch in 0..<channels { sum += buffer.floatChannelData![ch][frame] }
                mb.floatChannelData![0][frame] = sum / Float(channels)
            }
            mono = mb
        }

        guard sr != captureFormat.sampleRate else { return mono }

        guard let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: srcFmt, to: captureFormat) else { return mono }
        let ratio = captureFormat.sampleRate / sr
        let cap = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: cap) else { return mono }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return mono
        }
        return (err == nil && out.frameLength > 0) ? out : mono
    }
}

// MARK: - Logging (everything diagnostic goes to stderr)

func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

// MARK: - Entry point

@available(macOS 26, *)
func run() async {
    let args = CommandLine.arguments
    var appName = "Microsoft Teams"
    var outputPath = "/tmp/realtime-transcript.jsonl"
    var duration: Double? = nil
    var captureThem = true
    var captureMe = true
    var testFile: String? = nil

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--app": i += 1; if i < args.count { appName = args[i] }
        case "--output": i += 1; if i < args.count { outputPath = args[i] }
        case "--duration": i += 1; if i < args.count { duration = Double(args[i]) }
        case "--test-file": i += 1; if i < args.count { testFile = args[i] }
        case "--app-only": captureMe = false
        case "--mic-only": captureThem = false
        default: break
        }
        i += 1
    }

    // Speech authorization (still requested for safety; on-device API gates on installed assets too).
    let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
        SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
    }
    log("speech authorization status: \(auth.rawValue) (3 = authorized)")

    let sessionStart = Date()
    let writer: TranscriptWriter
    do {
        writer = try TranscriptWriter(outputURL: URL(fileURLWithPath: outputPath), sessionStart: sessionStart)
    } catch {
        log("FATAL: cannot open output file: \(error.localizedDescription)")
        exit(1)
    }

    let them = captureThem ? SourcePipeline(label: .them, writer: writer) : nil
    let me = captureMe ? SourcePipeline(label: .me, writer: writer) : nil

    // Offline self-test: feed a known audio file through the live pipeline to prove transcription.
    if let testFile {
        let pipeline = SourcePipeline(label: .them, writer: writer)
        do {
            try await pipeline.prepare()
            try await pipeline.start()
            log("=== TEST-FILE === feeding \(testFile)")
            try pipeline.feedFile(URL(fileURLWithPath: testFile))
            await pipeline.finish()
            writer.close()
            log("=== DONE ===")
            log(pipeline.metricsLine())
            log("transcript: \(outputPath)")
        } catch {
            log("FATAL during test-file run: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    do {
        if let them { try await them.prepare() }
        if let me { try await me.prepare() }
        if let them { try await them.start() }
        if let me { try await me.start() }
    } catch {
        log("FATAL during prepare/start: \(error.localizedDescription)")
        exit(1)
    }

    let coordinator = CaptureCoordinator(them: them, me: me)
    do {
        if captureThem { try await coordinator.startAppCapture(appName: appName) }
    } catch {
        log("FATAL starting app capture: \(error.localizedDescription)")
        exit(1)
    }
    if captureMe { coordinator.startMicCapture() }

    log("=== RECORDING === output: \(outputPath)  (Ctrl-C to stop)")

    // Stop on SIGINT or after --duration.
    let stop: () async -> Void = {
        log("stopping capture…")
        await coordinator.stopCapture()
        log("draining analyzers (finalizing trailing results)…")
        if let them { await them.finish() }
        if let me { await me.finish() }
        writer.close()
        log("=== DONE ===")
        if let them { log(them.metricsLine()) }
        if let me { log(me.metricsLine()) }
        log("transcript: \(outputPath)")
    }

    if let duration {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        await stop()
        exit(0)
    } else {
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigint.setEventHandler {
            Task { await stop(); exit(0) }
        }
        sigint.resume()
    }
}

if #available(macOS 26, *) {
    Task { await run() }
    RunLoop.main.run()
} else {
    log("Requires macOS 26 or later.")
    exit(1)
}
