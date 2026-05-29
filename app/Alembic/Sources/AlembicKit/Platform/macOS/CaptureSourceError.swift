import Foundation

/// Errors surfaced by the macOS `ScreenCaptureKitSource`.
///
/// Kept inside `Platform/macOS` (the contract layer stays Apple-free). Fatal
/// capture failures are pushed on the source's `errors` channel and/or thrown
/// from `start`; mid-session stream failures (`didStopWithError`) arrive as
/// `.streamStopped`.
public enum CaptureSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Screen Recording authorization is missing — `SCStream` cannot capture.
    case screenRecordingDenied
    /// Microphone authorization is missing — the mic tap cannot run.
    case microphoneDenied
    /// Speech Recognition authorization is missing — the transcriber cannot run.
    case speechRecognitionDenied
    /// No running application matched the requested `CaptureTarget`.
    case targetNotFound(String)
    /// No display was available to anchor the `SCContentFilter`.
    case noDisplay
    /// The `SCStream` stopped mid-session (`didStopWithError`).
    case streamStopped(String)
    /// The mic `AVAudioEngine` failed to start.
    case engineStartFailed(String)

    public var description: String {
        switch self {
        case .screenRecordingDenied:
            return "Screen Recording permission denied. Grant it in System Settings › Privacy & Security › Screen Recording."
        case .microphoneDenied:
            return "Microphone permission denied. Grant it in System Settings › Privacy & Security › Microphone."
        case .speechRecognitionDenied:
            return "Speech Recognition permission denied. Grant it in System Settings › Privacy & Security › Speech Recognition."
        case .targetNotFound(let id):
            return "No running application matched target '\(id)'."
        case .noDisplay:
            return "No display available to anchor audio capture."
        case .streamStopped(let message):
            return "Capture stream stopped: \(message)"
        case .engineStartFailed(let message):
            return "Microphone engine failed to start: \(message)"
        }
    }
}
