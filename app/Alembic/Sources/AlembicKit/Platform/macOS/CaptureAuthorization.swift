import Foundation
import AVFoundation
import CoreGraphics
import Speech

/// Minimal capture-authorization preflight for the macOS source.
///
/// Phase 3 scope is deliberately small: report enough about Screen Recording +
/// Microphone status to *drive* capture and fail with a clear error when denied.
/// (System Audio Recording, Speech Recognition: see `CapturePreflight`.)
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

    /// System Audio Recording (`kTCCServiceAudioCapture`) status — the grant
    /// the meeting-audio process tap needs.
    ///
    /// There is no public API for this permission, so it is read through the
    /// TCC SPI (`AudioCaptureTCC`). When that SPI cannot be resolved the status
    /// is reported as `.authorized`: Alembic cannot gate on it, and Core Audio
    /// raises the system prompt itself when the tap starts.
    public static func systemAudioRecordingStatus() -> CaptureAuthorization.Status {
        AudioCaptureTCC.preflight() ?? .authorized
    }

    /// Requests System Audio Recording, awaiting the user's response. The
    /// explicit request matters: the implicit prompt Core Audio raises at tap
    /// start was observed to go unseen and time out, silently capturing nothing.
    @discardableResult
    public static func requestSystemAudioRecording() async -> CaptureAuthorization.Status {
        if systemAudioRecordingStatus() == .authorized { return .authorized }
        return await AudioCaptureTCC.request() ?? .authorized
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

        // System Audio Recording: required by the meeting-audio process tap;
        // request inline when not yet determined so the prompt is visible.
        var systemAudio = systemAudioRecordingStatus()
        if systemAudio == .notDetermined {
            systemAudio = await requestSystemAudioRecording()
        }
        guard systemAudio == .authorized else { throw CaptureSourceError.systemAudioRecordingDenied }
    }
}

// MARK: - TCC SPI (System Audio Recording)

/// `TCCAccessPreflight` / `TCCAccessRequest` for `kTCCServiceAudioCapture`,
/// resolved at runtime from the private TCC framework. Every entry point
/// returns `nil` when the framework or symbol is unavailable so callers can
/// fall back to Core Audio's own prompt instead of failing.
private enum AudioCaptureTCC {
    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    /// `0` granted, `1` denied, anything else not yet determined.
    static func preflight() -> CaptureAuthorization.Status? {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        switch unsafeBitCast(symbol, to: PreflightFunction.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    static func request() async -> CaptureAuthorization.Status? {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        let request = unsafeBitCast(symbol, to: RequestFunction.self)
        let granted: Bool = await withCheckedContinuation { continuation in
            request(service, nil) { continuation.resume(returning: $0) }
        }
        return granted ? .authorized : .denied
    }
}
