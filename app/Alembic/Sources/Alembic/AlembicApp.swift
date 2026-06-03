import SwiftUI
import AlembicKit

/// Entry point for the Alembic menu-bar app.
///
/// Alembic is a menu-bar-only macOS app (no Dock icon — enforced via
/// `LSUIElement` in `Info.plist`). The `MenuBarExtra` hosts the capture controls
/// (``AlembicMenu``); an openable ``LiveTranscriptView`` `Window` shows live
/// captions. Both scenes share a single `@MainActor` ``AppModel`` that owns the
/// `@Observable` `MeetingSession` orchestrator and wires it to the production
/// macOS capture/transcription stack.
@main
struct AlembicApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            AlembicMenu(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        // `.menu` style renders a standard pull-down menu from the menu-bar item.
        .menuBarExtraStyle(.menu)

        // The live transcript window, opened on demand from the menu via
        // `openWindow(id:)`. A menu-bar app shows no window until requested.
        Window("Live Transcript", id: AppModel.liveWindowID) {
            LiveTranscriptView(model: model)
        }

        Window("Alembic Settings", id: AppModel.settingsWindowID) {
            SettingsView(model: model)
        }
        .defaultSize(width: 540, height: 380)
    }
}
