import Foundation
import ScreenCaptureKit
import AVFoundation

// MARK: - Audio Capture Delegate

class AudioCaptureDelegate: NSObject, SCStreamDelegate, SCStreamOutput {
    let outputURL: URL
    var audioFile: AVAudioFile?
    let sampleRate: Double = 16000 // Whisper-compatible
    let channels: AVAudioChannelCount = 1

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    func setupAudioFile(format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        // Initialize audio file on first buffer
        if audioFile == nil {
            let srcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.pointee.mSampleRate,
                channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
                interleaved: false
            )!
            do {
                try setupAudioFile(format: srcFormat)
            } catch {
                fputs("Error creating audio file: \(error)\n", stderr)
                return
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let _ = data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }

        // Convert to PCM buffer and write
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false
        )!

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        srcBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy float data into buffer
        data.withUnsafeBytes { rawPtr in
            let floatPtr = rawPtr.bindMemory(to: Float.self)
            let channelCount = Int(asbd.pointee.mChannelsPerFrame)
            for ch in 0..<channelCount {
                if let channelData = srcBuffer.floatChannelData?[ch] {
                    for frame in 0..<frameCount {
                        channelData[frame] = floatPtr[frame * channelCount + ch]
                    }
                }
            }
        }

        // Convert to target format (16kHz mono int16)
        let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        )!

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return }
        let ratio = sampleRate / asbd.pointee.mSampleRate
        let dstFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrameCount) else { return }

        var error: NSError?
        let status = converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if status == .haveData, let file = audioFile {
            do {
                try file.write(from: dstBuffer)
            } catch {
                fputs("Error writing audio: \(error)\n", stderr)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Stream stopped with error: \(error)\n", stderr)
    }

    func closeFile() {
        audioFile = nil // flush and close
    }
}

// MARK: - Main

enum Command: String {
    case list
    case capture
}

func printUsage() {
    fputs("""
    Usage:
      audio-capture list                         List running applications
      audio-capture capture --app <name> --output <path>  Capture audio from app

    Options:
      --app <name>       Application name to capture (e.g., "Microsoft Teams")
      --output <path>    Output WAV file path

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

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 2
        config.sampleRate = 48000

        let filter = SCContentFilter(
            desktopIndependentWindow: content.windows.first(where: { $0.owningApplication?.processID == app.processID })
                ?? content.windows.first!
        )

        let outputURL = URL(fileURLWithPath: outputPath)
        let delegate = AudioCaptureDelegate(outputURL: outputURL)

        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: SCStreamOutputType.audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))

        try await stream.startCapture()
        print("RECORDING") // Signal to parent process
        fflush(stdout)

        // Wait for SIGINT
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sigintSource.setEventHandler {
                fputs("\nStopping capture...\n", stderr)
                Task {
                    try? await stream.stopCapture()
                    delegate.closeFile()
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

// Parse arguments
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
}
