import Foundation
import ScreenCaptureKit
import AVFoundation
import Speech

// MARK: - Audio Capture Delegate

class AudioCaptureDelegate: NSObject, SCStreamDelegate, SCStreamOutput {
    let outputURL: URL
    var appFile: AVAudioFile?
    var micFile: AVAudioFile?
    let appLock = NSLock()
    let micLock = NSLock()
    var audioEngine: AVAudioEngine?
    let targetSampleRate: Double = 48000

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    private var micURL: URL {
        let base = outputURL.deletingPathExtension().path
        return URL(fileURLWithPath: base + "-mic.wav")
    }

    func setupAudioFile() {
        // Write int16 PCM to disk (most compatible with SFSpeechRecognizer)
        // but accept float32 input buffers — AVAudioFile converts automatically
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            appFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            micFile = try AVAudioFile(
                forWriting: micURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            fputs("Error creating audio files: \(error)\n", stderr)
        }
    }

    func startMicCapture() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        fputs("Mic format: \(Int(inputFormat.sampleRate))Hz, \(inputFormat.channelCount)ch\n", stderr)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.writeMicBuffer(buffer, sourceRate: inputFormat.sampleRate, sourceChannels: Int(inputFormat.channelCount))
        }

        do {
            try engine.start()
            fputs("Microphone capture started\n", stderr)
        } catch {
            fputs("Failed to start mic capture: \(error)\n", stderr)
        }
    }

    func stopMicCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // SCStreamOutput — app audio
    private var hasLoggedFormat = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if !hasLoggedFormat {
            hasLoggedFormat = true
            fputs("App audio format: \(Int(asbd.pointee.mSampleRate))Hz, \(asbd.pointee.mChannelsPerFrame)ch, \(isNonInterleaved ? "non-interleaved" : "interleaved"), flags=0x\(String(asbd.pointee.mFormatFlags, radix: 16))\n", stderr)
        }

        let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false
        )!

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let _ = data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        srcBuffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { rawPtr in
            let floatPtr = rawPtr.bindMemory(to: Float.self)
            let channelCount = Int(asbd.pointee.mChannelsPerFrame)
            for ch in 0..<channelCount {
                if let channelData = srcBuffer.floatChannelData?[ch] {
                    for frame in 0..<frameCount {
                        if isNonInterleaved {
                            // Non-interleaved: each channel's frames are contiguous
                            channelData[frame] = floatPtr[ch * frameCount + frame]
                        } else {
                            // Interleaved: samples alternate between channels
                            channelData[frame] = floatPtr[frame * channelCount + ch]
                        }
                    }
                }
            }
        }

        let mono = downmixToMono(srcBuffer, channels: Int(asbd.pointee.mChannelsPerFrame), sampleRate: asbd.pointee.mSampleRate)
        appLock.lock()
        defer { appLock.unlock() }
        do { try appFile?.write(from: mono) }
        catch { fputs("Error writing app audio: \(error)\n", stderr) }
    }

    private func writeMicBuffer(_ buffer: AVAudioPCMBuffer, sourceRate: Double, sourceChannels: Int) {
        let mono = downmixToMono(buffer, channels: sourceChannels, sampleRate: sourceRate)
        micLock.lock()
        defer { micLock.unlock() }
        do { try micFile?.write(from: mono) }
        catch { fputs("Error writing mic audio: \(error)\n", stderr) }
    }

    /// Convert any buffer to 48kHz mono float32
    private func downmixToMono(_ buffer: AVAudioPCMBuffer, channels: Int, sampleRate: Double) -> AVAudioPCMBuffer {
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        // Downmix to mono first if multi-channel
        var monoBuffer: AVAudioPCMBuffer = buffer
        if channels > 1 {
            let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
            guard let mb = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: buffer.frameLength) else { return buffer }
            mb.frameLength = buffer.frameLength
            for frame in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for ch in 0..<channels { sum += buffer.floatChannelData![ch][frame] }
                mb.floatChannelData![0][frame] = sum / Float(channels)
            }
            monoBuffer = mb
        }

        // Resample if needed
        if sampleRate != targetSampleRate {
            let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
            guard let converter = AVAudioConverter(from: srcFmt, to: targetFormat) else { return monoBuffer }
            let ratio = targetSampleRate / sampleRate
            let dstFrameCount = AVAudioFrameCount(Double(monoBuffer.frameLength) * ratio) + 1
            guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: dstFrameCount) else { return monoBuffer }
            var error: NSError?
            converter.convert(to: dstBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return monoBuffer
            }
            return dstBuffer
        }

        return monoBuffer
    }

    /// Mix app and mic files into the output file
    func mixFiles() {
        // Close both files first
        appFile = nil
        micFile = nil

        do {
            let appRead = try AVAudioFile(forReading: outputURL)
            let micRead = try AVAudioFile(forReading: micURL)

            // Read in float32 for mixing
            let processingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )!
            let appFrames = AVAudioFrameCount(appRead.length)
            let micFrames = AVAudioFrameCount(micRead.length)
            let maxFrames = max(appFrames, micFrames)

            fputs("Mixing audio: app=\(appFrames) mic=\(micFrames) frames\n", stderr)

            guard let appBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: appFrames) else { return }
            try appRead.read(into: appBuffer)

            guard let micBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: micFrames) else { return }
            try micRead.read(into: micBuffer)

            // Write mixed output as int16 PCM (most compatible)
            let mixedPath = outputURL.deletingPathExtension().path + "-mixed.wav"
            let mixedFileURL = URL(fileURLWithPath: mixedPath)
            let mixedSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let mixedFile = try AVAudioFile(
                forWriting: mixedFileURL,
                settings: mixedSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: maxFrames) else { return }
            mixedBuffer.frameLength = maxFrames

            let appData = appBuffer.floatChannelData![0]
            let micData = micBuffer.floatChannelData![0]
            let mixedData = mixedBuffer.floatChannelData![0]

            for frame in 0..<Int(maxFrames) {
                let appSample: Float = frame < Int(appFrames) ? appData[frame] : 0
                let micSample: Float = frame < Int(micFrames) ? micData[frame] : 0
                mixedData[frame] = appSample + micSample
            }

            try mixedFile.write(from: mixedBuffer)

            // Replace original with mixed
            let fm = FileManager.default
            try fm.removeItem(at: outputURL)
            try fm.moveItem(at: mixedFileURL, to: outputURL)
            try? fm.removeItem(at: micURL)

            fputs("Audio mixed successfully (\(maxFrames) frames)\n", stderr)
        } catch {
            fputs("Error mixing audio: \(error)\n", stderr)
            // Fall back to app-only audio (already at outputURL)
            try? FileManager.default.removeItem(at: micURL)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Stream stopped with error: \(error)\n", stderr)
    }

    func closeFile() {
        // Don't nil the files here — mixFiles() handles cleanup
    }
}

// MARK: - Main

enum Command: String {
    case list
    case capture
    case transcribe
}

func printUsage() {
    fputs("""
    Usage:
      audio-capture list                                   List running applications
      audio-capture capture --app <name> --output <path>   Capture audio from app
      audio-capture transcribe --input <path>              Transcribe a WAV file on-device

    Options:
      --app <name>       Application name to capture (e.g., "Microsoft Teams")
      --output <path>    Output WAV file path
      --input <path>     Input WAV file path to transcribe

    Send SIGINT (Ctrl+C) to stop capture.

    """, stderr)
}

func listApps() async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let apps = content.applications
            .filter { !$0.applicationName.isEmpty }
            .sorted { $0.applicationName < $1.applicationName }

        for app in apps {
            print("\(app.processID)\t\(app.applicationName)")
        }
    } catch {
        fputs("Error listing apps: \(error)\n", stderr)
        exit(1)
    }
}

func captureApp(name: String, outputPath: String) async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let app = content.applications.first(where: {
            $0.applicationName.localizedCaseInsensitiveContains(name)
        }) else {
            fputs("Application '\(name)' not found. Use 'list' to see running apps.\n", stderr)
            exit(1)
        }

        fputs("Capturing audio from: \(app.applicationName) (PID: \(app.processID))\n", stderr)

        guard let display = content.displays.first else {
            fputs("No displays found.\n", stderr)
            exit(1)
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 2
        config.sampleRate = 48000
        // Minimize video overhead — we only need audio
        config.width = 2
        config.height = 2

        let filter = SCContentFilter(
            display: display,
            including: [app],
            exceptingWindows: []
        )

        let outputURL = URL(fileURLWithPath: outputPath)
        let delegate = AudioCaptureDelegate(outputURL: outputURL)
        delegate.setupAudioFile()

        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: SCStreamOutputType.audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))

        try await stream.startCapture()
        delegate.startMicCapture()
        print("RECORDING") // Signal to parent process
        fflush(stdout)

        // Wait for SIGINT
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sigintSource.setEventHandler {
                fputs("\nStopping capture...\n", stderr)
                Task {
                    delegate.stopMicCapture()
                    try? await stream.stopCapture()
                    delegate.mixFiles()
                    print("STOPPED")
                    fflush(stdout)
                    continuation.resume()
                }
            }
            sigintSource.resume()
        }
    } catch {
        fputs("Capture error: \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Transcription

/// Preprocess audio for optimal on-device speech recognition:
/// 1. Resample to 16kHz (what speech models are trained on)
/// 2. Prepend ~1s of silence (gives the recognizer time to initialize)
func preprocessForTranscription(inputURL: URL) throws -> URL {
    let srcFile = try AVAudioFile(forReading: inputURL)
    let srcFormat = srcFile.processingFormat
    let srcFrames = AVAudioFrameCount(srcFile.length)

    let targetRate: Double = 16000
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetRate,
        channels: 1,
        interleaved: false
    )!

    // Read source audio into a float32 mono buffer
    let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: srcFormat.sampleRate,
        channels: 1,
        interleaved: false
    )!

    let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames)!
    try srcFile.read(into: srcBuffer)

    // Downmix to mono if needed
    var monoBuffer: AVAudioPCMBuffer
    if srcFormat.channelCount > 1 {
        monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: srcFrames)!
        monoBuffer.frameLength = srcFrames
        for frame in 0..<Int(srcFrames) {
            var sum: Float = 0
            for ch in 0..<Int(srcFormat.channelCount) {
                sum += srcBuffer.floatChannelData![ch][frame]
            }
            monoBuffer.floatChannelData![0][frame] = sum / Float(srcFormat.channelCount)
        }
    } else {
        monoBuffer = srcBuffer
    }

    // Resample to 16kHz
    var resampledBuffer: AVAudioPCMBuffer
    if srcFormat.sampleRate != targetRate {
        let srcMonoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: srcMonoFormat, to: targetFormat) else {
            throw NSError(domain: "Alembic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }
        let ratio = targetRate / srcFormat.sampleRate
        let dstFrameCount = AVAudioFrameCount(Double(monoBuffer.frameLength) * ratio) + 1
        resampledBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: dstFrameCount)!

        var inputConsumed = false
        var error: NSError?
        converter.convert(to: resampledBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return monoBuffer
        }
        if let error = error {
            throw error
        }
    } else {
        resampledBuffer = monoBuffer
    }

    // Prepend 1 second of silence
    let silenceFrames = AVAudioFrameCount(targetRate)  // 1 second
    let totalFrames = silenceFrames + resampledBuffer.frameLength
    let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: totalFrames)!
    outputBuffer.frameLength = totalFrames

    let outData = outputBuffer.floatChannelData![0]
    // Fill silence
    for i in 0..<Int(silenceFrames) {
        outData[i] = 0
    }
    // Copy resampled audio after silence
    let resData = resampledBuffer.floatChannelData![0]
    for i in 0..<Int(resampledBuffer.frameLength) {
        outData[Int(silenceFrames) + i] = resData[i]
    }

    // Write to temp file
    let outputPath = inputURL.deletingPathExtension().path + "-16k.wav"
    let outputURL = URL(fileURLWithPath: outputPath)
    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: targetRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let outputFile = try AVAudioFile(
        forWriting: outputURL,
        settings: outputSettings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try outputFile.write(from: outputBuffer)

    let duration = Double(resampledBuffer.frameLength) / targetRate
    fputs("Preprocessed audio: \(Int(srcFormat.sampleRate))Hz → 16kHz, +1s silence, \(String(format: "%.1f", duration))s audio\n", stderr)

    return outputURL
}

func transcribeFile(inputPath: String, vocabulary: [String] = []) async {
    let url = URL(fileURLWithPath: inputPath)

    guard FileManager.default.fileExists(atPath: inputPath) else {
        fputs("Input file not found: \(inputPath)\n", stderr)
        exit(1)
    }

    // Request authorization
    let authStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }

    guard authStatus == .authorized else {
        fputs("Speech recognition not authorized (status: \(authStatus.rawValue)). Grant permission in System Settings > Privacy & Security > Speech Recognition.\n", stderr)
        exit(1)
    }

    guard let recognizer = SFSpeechRecognizer() else {
        fputs("Speech recognizer not available for the current locale.\n", stderr)
        exit(1)
    }

    guard recognizer.isAvailable else {
        fputs("Speech recognizer is not currently available.\n", stderr)
        exit(1)
    }

    // Diagnostic: check on-device support
    fputs("On-device recognition supported: \(recognizer.supportsOnDeviceRecognition)\n", stderr)
    fputs("Locale: \(recognizer.locale.identifier)\n", stderr)

    // Feed raw file directly — SFSpeechRecognizer handles format conversion internally
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if !vocabulary.isEmpty {
        request.contextualStrings = vocabulary
        fputs("Vocabulary hints: \(vocabulary.joined(separator: ", "))\n", stderr)
    }

    do {
        // On-device recognition resets mid-file for longer audio, losing earlier text.
        // Track accumulated text across resets by detecting when the recognizer starts over.
        var accumulatedSegments: [String] = []
        var currentPartialText = ""
        var previousPartialText = ""

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let result = result else { return }
                if !result.isFinal {
                    let partialText = result.bestTranscription.formattedString
                    // Detect recognizer reset: new text is much shorter and doesn't
                    // start with the beginning of the previous text
                    if !previousPartialText.isEmpty && partialText.count < previousPartialText.count / 2 {
                        let prevPrefix = String(previousPartialText.prefix(30))
                        if !partialText.hasPrefix(prevPrefix) {
                            // Reset detected — save the accumulated text so far
                            accumulatedSegments.append(previousPartialText)
                            fputs("Recognizer reset detected, saved segment (\(previousPartialText.count) chars)\n", stderr)
                        }
                    }
                    previousPartialText = partialText
                    currentPartialText = partialText
                }
                if result.isFinal {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: result)
                    }
                }
            }
        }

        // Combine: accumulated segments from resets + best of (final text, last partial)
        let finalText = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespaces)
        let lastPartial = currentPartialText.trimmingCharacters(in: .whitespaces)

        // For the last segment, use whichever is longer
        let lastSegment = finalText.count >= lastPartial.count ? finalText : lastPartial
        if !lastSegment.isEmpty {
            accumulatedSegments.append(lastSegment)
        }

        let fullText = accumulatedSegments.joined(separator: " ")

        fputs("Transcription complete: \(accumulatedSegments.count) accumulated segment(s), \(fullText.count) chars total\n", stderr)
        fputs("Full text: \"\(fullText.prefix(300))\"\n", stderr)

        if fullText.trimmingCharacters(in: .whitespaces).isEmpty {
            fputs("No speech detected\n", stderr)
            print("[]")
            fflush(stdout)
            return
        }

        // Output as a single chunk (no segment-level timing with partial results)
        let jsonChunks: [[String: Any]] = [
            [
                "start": 0,
                "end": 0,
                "text": fullText,
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonChunks, options: [.prettyPrinted, .sortedKeys])
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
            fflush(stdout)
        }
    } catch {
        let desc = error.localizedDescription
        // "No speech detected" is a normal outcome, not an error — return empty array
        if desc.localizedCaseInsensitiveContains("no speech") || desc.localizedCaseInsensitiveContains("no utterances") {
            fputs("Speech recognizer reported: \(desc)\n", stderr)
            print("[]")
            fflush(stdout)
        } else {
            fputs("Transcription error: \(desc)\n", stderr)
            exit(1)
        }
    }
}
let args = CommandLine.arguments
guard args.count >= 2 else {
    printUsage()
    exit(1)
}

guard let command = Command(rawValue: args[1]) else {
    fputs("Unknown command: \(args[1])\n", stderr)
    printUsage()
    exit(1)
}

switch command {
case .list:
    Task {
        await listApps()
        exit(0)
    }
    RunLoop.main.run()

case .capture:
    var appName = "Microsoft Teams"
    var outputPath = "/tmp/meeting-audio.wav"

    var i = 2
    while i < args.count {
        switch args[i] {
        case "--app":
            i += 1
            if i < args.count { appName = args[i] }
        case "--output":
            i += 1
            if i < args.count { outputPath = args[i] }
        default:
            break
        }
        i += 1
    }

    Task {
        await captureApp(name: appName, outputPath: outputPath)
        exit(0)
    }
    RunLoop.main.run()

case .transcribe:
    var inputPath = ""
    var vocabulary: [String] = []

    var i = 2
    while i < args.count {
        switch args[i] {
        case "--input":
            i += 1
            if i < args.count { inputPath = args[i] }
        case "--vocabulary":
            i += 1
            if i < args.count {
                vocabulary = args[i].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        default:
            break
        }
        i += 1
    }

    guard !inputPath.isEmpty else {
        fputs("Error: --input <path> is required for transcribe command.\n", stderr)
        printUsage()
        exit(1)
    }

    Task {
        await transcribeFile(inputPath: inputPath, vocabulary: vocabulary)
        exit(0)
    }
    RunLoop.main.run()
}
