import Foundation
import AppKit
import AlembicKit

/// `@MainActor @Observable` coordinator for the three independent permissions
/// Alembic needs before it can record: Microphone, Speech Recognition, and
/// Screen Recording.
///
/// ## Division of labour
/// All *decisions* (raw status → ``PermissionState``, the requires-restart rule,
/// the ready-to-record aggregation, and failure → message/Settings-link mapping)
/// live as pure, tested logic in `AlembicKit` (`PermissionLogic`,
/// `PermissionSnapshot`, `StartupBlocker`). The thin platform primitives
/// (status/request) live in `AlembicKit/Platform/macOS/CaptureAuthorization.swift`.
/// This coordinator only holds observable state and bridges system prompts onto
/// that pure logic — so the SwiftUI views can render per-permission status and
/// "grant" buttons.
///
/// ## Screen Recording restart caveat
/// `CGRequestScreenCaptureAccess()` frequently needs an app relaunch before the
/// grant becomes effective. We record whether we've prompted this launch
/// (`didRequestScreenRecording`) and feed it to
/// `PermissionLogic.screenRecordingState(effective:didRequest:)`, which surfaces
/// ``PermissionState/requiresRestart`` so the UI can offer "Quit & Reopen"
/// instead of silently failing.
///
/// > Manual gate: the live system prompts, the restart recovery, and the
/// > System Settings deep-links cannot run headlessly. The pure logic is covered
/// > by `AlembicCheck`; this glue is validated on a real machine first-run.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var microphone: PermissionState = .unknown
    private(set) var speechRecognition: PermissionState = .unknown
    private(set) var screenRecording: PermissionState = .unknown

    /// Whether we've shown the Screen Recording system prompt this launch, used
    /// by the requires-restart detection rule.
    @ObservationIgnored private var didRequestScreenRecording = false

    /// Immutable snapshot for the pure aggregation/guidance helpers.
    var snapshot: PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphone,
            speechRecognition: speechRecognition,
            screenRecording: screenRecording
        )
    }

    /// `true` only when all three permissions are granted and effective.
    var isReadyToRecord: Bool { snapshot.isReadyToRecord }

    /// Permissions still needing a grant, in stable order, for the onboarding UI.
    var missing: [PermissionKind] { snapshot.missing }

    /// The most relevant blocker for a refused start (with actionable guidance),
    /// or `nil` when ready.
    var primaryBlocker: StartupBlocker? { snapshot.primaryBlocker }

    func state(of kind: PermissionKind) -> PermissionState { snapshot.state(of: kind) }

    // MARK: - Refresh (no prompts)

    /// Re-reads the current status of all three permissions **without** showing
    /// any system prompt. Safe to call on launch and whenever the menu opens.
    func refresh() {
        microphone = PermissionLogic.state(for: CapturePreflight.microphoneStatus().rawPermissionStatus)
        speechRecognition = PermissionLogic.state(for: CapturePreflight.speechRecognitionStatus().rawPermissionStatus)
        screenRecording = PermissionLogic.screenRecordingState(
            effective: CapturePreflight.screenRecordingStatus() == .authorized,
            didRequest: didRequestScreenRecording
        )
    }

    // MARK: - Requests (show the system prompt)

    func requestMicrophone() async {
        microphone = .requesting
        let status = await CapturePreflight.requestMicrophone()
        microphone = PermissionLogic.state(for: status.rawPermissionStatus)
    }

    func requestSpeechRecognition() async {
        speechRecognition = .requesting
        let status = await CapturePreflight.requestSpeechRecognition()
        speechRecognition = PermissionLogic.state(for: status.rawPermissionStatus)
    }

    /// Requests Screen Recording. The system prompt may grant immediately or — far
    /// more commonly — require an app relaunch, in which case the state becomes
    /// ``PermissionState/requiresRestart`` rather than `granted`.
    func requestScreenRecording() {
        screenRecording = .requesting
        let effective = CapturePreflight.requestScreenRecording() == .authorized
        didRequestScreenRecording = true
        screenRecording = PermissionLogic.screenRecordingState(
            effective: effective,
            didRequest: didRequestScreenRecording
        )
    }

    /// Requests every permission that is not yet granted, in order. Drives the
    /// "Grant All" affordance in the first-run flow.
    func requestAllMissing() async {
        if !microphone.isGranted { await requestMicrophone() }
        if !speechRecognition.isGranted { await requestSpeechRecognition() }
        if !screenRecording.isGranted { requestScreenRecording() }
    }

    // MARK: - Actions

    /// Opens the System Settings pane for a permission (deep-link).
    func openSettings(for kind: PermissionKind) {
        guard let url = URL(string: kind.settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the System Settings pane named by a guidance entry, when present.
    func openSettings(for guidance: PermissionGuidance) {
        guard let string = guidance.settingsURLString, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
