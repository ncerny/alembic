import Foundation
import AVFoundation
import CoreGraphics
import Speech

/// Minimal capture-authorization preflight for the macOS source.
///
/// Phase 3 scope is deliberately small: report enough about Screen Recording +
/// Microphone status to *drive* capture and fail with a clear error when denied.
/// The polished first-run request/onboarding flow is Phase 8.
public struct CaptureAuthorization: Sendable, Equatable {

    /// Tri-state authorization status. Screen Recording cannot reliably be
    /// distinguished between "not determined" and "denied" via the preflight API,
    /// so callers should treat anything other than `.authorized` as "needs the
    /// user to grant access".
    public enum Status: String, Sendable, Equatable {
        case authorized
        case denied
        case notDetermined
    }

    public let screenRecording: Status
    public let microphone: Status

    public init(screenRecording: Status, microphone: Status) {
        self.screenRecording = screenRecording
        self.microphone = microphone
    }

    /// Both permissions are granted, so capture can start.
    public var isReadyForCapture: Bool {
        screenRecording == .authorized && microphone == .authorized
    }
}

extension CaptureAuthorization.Status {
    /// Foundation-only projection used by the app's `PermissionsModel` so the
    /// pure `PermissionLogic` mapping never depends on AVFoundation/CoreGraphics.
    public var rawPermissionStatus: PermissionRawStatus {
        switch self {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        }
    }
}

/// Stateless helpers that query (and minimally request) capture authorization.
public enum CapturePreflight {

    /// Screen Recording status via `CGPreflightScreenCaptureAccess`.
    ///
    /// The CoreGraphics preflight returns only a boolean, so a `false` result is
    /// reported as `.denied` (it may actually be "not determined"). Triggering an
    /// actual prompt is left to `requestScreenRecording()` / Phase 8.
    public static func screenRecordingStatus() -> CaptureAuthorization.Status {
        CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    /// Microphone status mapped from `AVCaptureDevice.authorizationStatus`.
    public static func microphoneStatus() -> CaptureAuthorization.Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Speech Recognition status mapped from `SFSpeechRecognizer.authorizationStatus`.
    ///
    /// The macOS 26 `SpeechAnalyzer`/`SpeechTranscriber` stack still gates
    /// on-device transcription behind the Speech Recognition TCC permission
    /// (`NSSpeechRecognitionUsageDescription`), so this is a third, independent
    /// grant alongside Microphone and Screen Recording.
    public static func speechRecognitionStatus() -> CaptureAuthorization.Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Current combined authorization snapshot (no prompts).
    public static func current() -> CaptureAuthorization {
        CaptureAuthorization(
            screenRecording: screenRecordingStatus(),
            microphone: microphoneStatus()
        )
    }

    /// Requests Screen Recording access (shows the system prompt on first call).
    /// Returns the post-request status.
    @discardableResult
    public static func requestScreenRecording() -> CaptureAuthorization.Status {
        CGRequestScreenCaptureAccess() ? .authorized : .denied
    }

    /// Requests Microphone access, awaiting the user's response. Returns the
    /// post-request status.
    @discardableResult
    public static func requestMicrophone() async -> CaptureAuthorization.Status {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return .authorized }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : .denied
    }

    /// Requests Speech Recognition access, awaiting the user's response.
    ///
    /// `SFSpeechRecognizer.requestAuthorization` is a callback-based API that
    /// predates Swift concurrency; we bridge it with `withCheckedContinuation`
    /// so callers get a clean `async` result. Returns the post-request status.
    @discardableResult
    public static func requestSpeechRecognition() async -> CaptureAuthorization.Status {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return .authorized }
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Ensures the permissions required for capture are granted, requesting any
    /// that are not yet determined. Throws a clear `CaptureSourceError` when a
    /// permission is denied. Acts as a backstop beneath the app's first-run
    /// permissions gate (`PermissionsModel`); `start()` should normally refuse
    /// before reaching here.
    public static func requireForCapture() async throws {
        // Microphone: we can request inline when not yet determined.
        var mic = microphoneStatus()
        if mic == .notDetermined {
            mic = await requestMicrophone()
        }
        guard mic == .authorized else { throw CaptureSourceError.microphoneDenied }

        // Speech Recognition: required by the on-device transcriber; request
        // inline when not yet determined.
        var speech = speechRecognitionStatus()
        if speech == .notDetermined {
            speech = await requestSpeechRecognition()
        }
        guard speech == .authorized else { throw CaptureSourceError.speechRecognitionDenied }

        // Screen Recording: request shows the prompt; granting requires a relaunch
        // in practice, but we surface a clear error so the caller (Phase 8 UX) can
        // guide the user.
        var screen = screenRecordingStatus()
        if screen != .authorized {
            screen = requestScreenRecording()
        }
        guard screen == .authorized else { throw CaptureSourceError.screenRecordingDenied }
    }
}
