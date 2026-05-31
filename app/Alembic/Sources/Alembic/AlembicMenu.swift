import SwiftUI
import AlembicKit

/// The menu-bar pull-down menu: a first-run permissions gate, target picker,
/// Start/Stop, live-window opener, Reveal-in-Finder, current status, and Quit.
///
/// Presentation only — every action forwards to ``AppModel`` (which owns the
/// orchestrator and the ``PermissionsModel``). Long-running operations are
/// launched in detached `Task`s so the main thread is never blocked.
struct AlembicMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)

        if let warning = model.session.lastWarning {
            Text(warning)
        }

        Divider()

        permissionsSection

        Divider()

        if model.session.availableTargets.isEmpty {
            Button("No capturable apps found") {}
                .disabled(true)
        } else {
            Picker("Meeting App", selection: $model.selectedTarget) {
                ForEach(model.session.availableTargets) { target in
                    Text(target.displayName).tag(Optional(target))
                }
            }
        }

        Button("Refresh Targets") {
            Task { await model.refreshTargets() }
        }

        Divider()

        Button("Start") {
            Task { await model.start() }
        }
        .disabled(!model.canStart)

        Button("Stop") {
            Task { await model.stop() }
        }
        .disabled(!model.canStop)

        Button("Open Live Transcript") {
            openWindow(id: AppModel.liveWindowID)
            // A menu-bar-only app (LSUIElement) is not the active app, so a newly
            // opened window stays buried behind other apps. Activate ourselves so
            // the transcript window actually comes to the front.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Button("Reveal Transcript in Finder") {
            model.revealTranscript()
        }
        .disabled(!model.canReveal)

        Divider()

        Button("Quit Alembic") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - First-run permissions gate

    /// Shows per-permission status and a grant action for each one that's still
    /// missing, plus actionable guidance (Open Settings / Quit & Reopen) for the
    /// current blocker. Collapses to a single line once all three are granted.
    @ViewBuilder
    private var permissionsSection: some View {
        let permissions = model.permissions

        if permissions.isReadyToRecord {
            Text("Permissions: all granted ✓")
                .font(.caption)
        } else {
            Text("Permissions needed before recording:")
                .font(.caption)

            ForEach(PermissionKind.allCases, id: \.self) { kind in
                permissionRow(kind, state: permissions.state(of: kind))
            }

            Button("Grant All Permissions…") {
                Task { await model.permissions.requestAllMissing() }
            }

            if let guidance = model.startupGuidance {
                Text(guidance.message)
                    .font(.caption)

                if guidance.suggestsRestart {
                    Button("Quit & Reopen Alembic") {
                        model.quitAndReopen()
                    }
                } else if guidance.settingsURLString != nil {
                    Button("Open System Settings…") {
                        model.permissions.openSettings(for: guidance)
                    }
                }
            }
        }
    }

    /// One permission's status line, with a context-appropriate action button.
    @ViewBuilder
    private func permissionRow(_ kind: PermissionKind, state: PermissionState) -> some View {
        switch state {
        case .granted:
            Button("\(kind.displayName): granted ✓") {}
                .disabled(true)

        case .requiresRestart:
            Button("\(kind.displayName): needs restart — Quit & Reopen") {
                model.quitAndReopen()
            }

        case .requesting:
            Button("\(kind.displayName): requesting…") {}
                .disabled(true)

        case .denied:
            Button("\(kind.displayName): denied — Open Settings…") {
                model.permissions.openSettings(for: kind)
            }

        case .unknown:
            Button("\(kind.displayName): grant…") {
                grant(kind)
            }
        }
    }

    /// Triggers the system prompt for a single permission.
    private func grant(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            Task { await model.permissions.requestMicrophone() }
        case .speechRecognition:
            Task { await model.permissions.requestSpeechRecognition() }
        case .screenRecording:
            model.permissions.requestScreenRecording()
        }
    }
}
