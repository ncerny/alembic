import Foundation

/// Errors surfaced by the macOS `ScreenCaptureKitSource`.
///
/// Kept inside `Platform/macOS` (the contract layer stays Apple-free). Fatal
/// capture failures are pushed on the source's `errors` channel and/or thrown
/// from `start`; mid-session failures (the meeting-audio tap's device dying)
/// arrive as `.streamStopped`.
public enum CaptureSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Screen Recording authorization is missing — capture targets and window
    /// titles cannot be read.
    case screenRecordingDenied
    /// System Audio Recording authorization is missing — the meeting-audio
    /// process tap cannot run.
    case systemAudioRecordingDenied
    /// Microphone authorization is missing — the mic tap cannot run.
    case microphoneDenied
    /// Speech Recognition authorization is missing — the transcriber cannot run.
    case speechRecognitionDenied
    /// No running application matched the requested `CaptureTarget`.
    case targetNotFound(String)
    /// The meeting-audio process tap could not be created or started.
    case audioTapFailed(String)
    /// A capture stream stopped mid-session.
    case streamStopped(String)
    /// The mic `AVAudioEngine` failed to start.
    case engineStartFailed(String)

    public var description: String {
        switch self {
        case .screenRecordingDenied:
            return "Screen Recording permission denied. Grant it in System Settings › Privacy & Security › Screen Recording."
        case .systemAudioRecordingDenied:
            return "System Audio Recording permission denied. Grant it in System Settings › Privacy & Security › Screen & System Audio Recording."
        case .microphoneDenied:
            return "Microphone permission denied. Grant it in System Settings › Privacy & Security › Microphone."
        case .speechRecognitionDenied:
            return "Speech Recognition permission denied. Grant it in System Settings › Privacy & Security › Speech Recognition."
        case .targetNotFound(let id):
            return "No running application matched target '\(id)'."
        case .audioTapFailed(let message):
            return "Meeting audio capture failed to start: \(message)"
        case .streamStopped(let message):
            return "Capture stream stopped: \(message)"
        case .engineStartFailed(let message):
            return "Microphone engine failed to start: \(message)"
        }
    }
}
