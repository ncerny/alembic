import Foundation

/// Pure, Foundation-only permission model + decision logic shared by the app's
/// observable `PermissionsModel` coordinator and exercised by `AlembicCheck`.
///
/// ## Why this lives in the contract layer (Foundation-only)
/// The three permissions Alembic needs — Microphone, Speech Recognition, and
/// Screen Recording — **fail independently**, gate recording, and each maps to a
/// specific, actionable user message. The *decisions* about those states (how a
/// raw TCC status becomes a UI state, when Screen Recording needs an app
/// restart, whether all three are granted, and which message/Settings deep-link
/// a failure surfaces) are deterministic and must be unit-tested. Live system
/// prompts, the restart behavior, and System Settings deep-links cannot run
/// headlessly (manual gate), so all the *logic* is isolated here, Apple-free,
/// and the thin platform primitives (status/request) live in
/// `Platform/macOS/CaptureAuthorization.swift`.
public enum PermissionKind: String, Sendable, Equatable, CaseIterable {
    case microphone
    case speechRecognition
    case screenRecording

    /// Short, user-facing label for the permission row.
    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .screenRecording: return "Screen Recording"
        }
    }

    /// System Settings deep-link target for this permission. Opened by the app
    /// via `NSWorkspace.shared.open(URL(string:)!)`; kept here as a `String` so
    /// the contract layer stays Foundation-only and the value is test-locked.
    public var settingsURLString: String {
        switch self {
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognition:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }
}

/// Per-permission UI state. The three permissions each carry one of these,
/// updated independently as the user grants them.
public enum PermissionState: String, Sendable, Equatable {
    /// Not yet determined / never requested this launch.
    case unknown
    /// A system prompt is in flight.
    case requesting
    /// Granted and effective — usable for capture right now.
    case granted
    /// Explicitly denied (or restricted) — user must enable in System Settings.
    case denied
    /// Granted in System Settings but not yet effective for this process; macOS
    /// requires the app to relaunch before Screen Recording capture works.
    case requiresRestart

    public var isGranted: Bool { self == .granted }
}

/// Foundation-only mirror of the platform's tri-state TCC status. The Apple
/// primitives in `CaptureAuthorization.swift` map their framework statuses to
/// this so the pure decision logic below never imports a media framework.
public enum PermissionRawStatus: String, Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
}

/// Pure decision functions that turn raw platform statuses into ``PermissionState``.
public enum PermissionLogic {
    /// Maps a Microphone / Speech Recognition raw status to a UI state.
    ///
    /// These two permissions report a real tri-state (the system distinguishes
    /// "not determined" from "denied"), so the mapping is direct.
    public static func state(for raw: PermissionRawStatus) -> PermissionState {
        switch raw {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .unknown
        }
    }

    /// Maps Screen Recording to a state.
    ///
    /// Screen Recording is special on two counts:
    /// 1. `CGPreflightScreenCaptureAccess()` returns only a boolean — it cannot
    ///    distinguish "denied" from "not determined".
    /// 2. A *fresh* grant (the user just toggled it on, in the system prompt or
    ///    System Settings) typically does **not** take effect until the app is
    ///    relaunched.
    ///
    /// - Parameters:
    ///   - effective: `CGPreflightScreenCaptureAccess()` — whether capture works now.
    ///   - didRequest: whether we've already shown the system prompt this launch.
    ///     When we've prompted but the preflight is still `false`, the most likely
    ///     cause is the grant-needs-restart condition, so we surface
    ///     ``PermissionState/requiresRestart`` rather than a misleading "denied".
    public static func screenRecordingState(effective: Bool, didRequest: Bool) -> PermissionState {
        if effective { return .granted }
        if didRequest { return .requiresRestart }
        return .unknown
    }
}

/// An immutable snapshot of all three permission states, with the "ready to
/// record" aggregation and the list of what's still missing.
public struct PermissionSnapshot: Sendable, Equatable {
    public var microphone: PermissionState
    public var speechRecognition: PermissionState
    public var screenRecording: PermissionState

    public init(
        microphone: PermissionState = .unknown,
        speechRecognition: PermissionState = .unknown,
        screenRecording: PermissionState = .unknown
    ) {
        self.microphone = microphone
        self.speechRecognition = speechRecognition
        self.screenRecording = screenRecording
    }

    public func state(of kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone: return microphone
        case .speechRecognition: return speechRecognition
        case .screenRecording: return screenRecording
        }
    }

    /// Recording may only start when **all three** permissions are granted and
    /// effective. Anything else (denied, unknown, requesting, requiresRestart)
    /// must block the start with an actionable message — never a silent no-op.
    public var isReadyToRecord: Bool {
        microphone.isGranted && speechRecognition.isGranted && screenRecording.isGranted
    }

    /// Permissions that are not yet granted, in a stable order, so the UI can
    /// guide the user through the remaining grants.
    public var missing: [PermissionKind] {
        PermissionKind.allCases.filter { !state(of: $0).isGranted }
    }

    /// The single most relevant blocker for a refused `start()`, chosen in a
    /// stable priority order (microphone, speech, screen recording). Returns
    /// `nil` when ``isReadyToRecord`` is `true`.
    public var primaryBlocker: StartupBlocker? {
        for kind in PermissionKind.allCases {
            let s = state(of: kind)
            if s.isGranted { continue }
            switch kind {
            case .microphone:
                return .microphoneDenied
            case .speechRecognition:
                return .speechRecognitionDenied
            case .screenRecording:
                return s == .requiresRestart ? .screenRecordingRequiresRestart : .screenRecordingDenied
            }
        }
        return nil
    }
}

/// A user-facing message plus the next action for a blocked start or a failure.
public struct PermissionGuidance: Sendable, Equatable {
    /// Clear, specific, user-facing explanation of what went wrong.
    public let message: String
    /// System Settings deep-link to open, when the fix lives there. `nil` when
    /// the action is something other than opening Settings (e.g. relaunch).
    public let settingsURLString: String?
    /// `true` when the recommended action is to quit & reopen the app.
    public let suggestsRestart: Bool

    public init(message: String, settingsURLString: String? = nil, suggestsRestart: Bool = false) {
        self.message = message
        self.settingsURLString = settingsURLString
        self.suggestsRestart = suggestsRestart
    }
}

/// Every reason a start can be blocked or a session can fail, each mapped to a
/// clear, actionable ``PermissionGuidance``. This is the single source of truth
/// for "never silently no-op" — the app routes all failures through here.
public enum StartupBlocker: Sendable, Equatable {
    case microphoneDenied
    case speechRecognitionDenied
    case screenRecordingDenied
    case screenRecordingRequiresRestart
    case localeUnsupported(String)
    case assetInstallFailed(String)
    case captureStopped(String)

    public var guidance: PermissionGuidance {
        switch self {
        case .microphoneDenied:
            return PermissionGuidance(
                message: "Microphone access is required to transcribe what you say. "
                    + "Open System Settings › Privacy & Security › Microphone and enable Alembic.",
                settingsURLString: PermissionKind.microphone.settingsURLString
            )
        case .speechRecognitionDenied:
            return PermissionGuidance(
                message: "Speech Recognition access is required to transcribe audio. "
                    + "Open System Settings › Privacy & Security › Speech Recognition and enable Alembic.",
                settingsURLString: PermissionKind.speechRecognition.settingsURLString
            )
        case .screenRecordingDenied:
            return PermissionGuidance(
                message: "Screen Recording access is required to capture meeting audio. "
                    + "Open System Settings › Privacy & Security › Screen Recording and enable Alembic.",
                settingsURLString: PermissionKind.screenRecording.settingsURLString
            )
        case .screenRecordingRequiresRestart:
            return PermissionGuidance(
                message: "Screen Recording was granted but won't take effect until Alembic restarts. "
                    + "Quit & Reopen to finish enabling capture.",
                settingsURLString: PermissionKind.screenRecording.settingsURLString,
                suggestsRestart: true
            )
        case .localeUnsupported(let id):
            return PermissionGuidance(
                message: "Speech transcription does not support locale '\(id)'. "
                    + "Choose a supported language in System Settings › General › Language & Region."
            )
        case .assetInstallFailed(let detail):
            return PermissionGuidance(
                message: "Downloading the on-device speech model failed: \(detail). "
                    + "Check your network connection and try Start again."
            )
        case .captureStopped(let detail):
            return PermissionGuidance(
                message: "Capture stopped unexpectedly: \(detail). "
                    + "Make sure the meeting app is running and visible, then try Start again."
            )
        }
    }
}
