import SwiftUI
import AppKit
import AlembicKit

/// Settings panel for configuring vocabulary hint sources.
///
/// Vocabulary hints are passed to `AnalysisContext.contextualStrings[.general]`
/// before each recording session starts, biasing on-device speech recognition
/// toward the terms most likely to appear in your meetings.
///
/// Sources are evaluated top-to-bottom; the first row has the highest priority
/// when the combined term count exceeds the ~500-term Apple limit.
struct SettingsView: View {
    private let model: AppModel
    @State private var sources: [VocabularyStore.VocabularySource]
    @State private var previewResult: VocabularyStore.SourceLoadResult?
    @State private var isPreviewing = false
    @AppStorage("alembic.autostart.enabled") private var autoStartEnabled = false
    @AppStorage(DisclosurePolicy.DefaultsKey.enabled) private var discloseEnabled = false
    @AppStorage(DisclosurePolicy.DefaultsKey.autoSend) private var discloseAutoSend = false
    @AppStorage(DisclosurePolicy.DefaultsKey.teamsOnly) private var discloseTeamsOnly = true
    @AppStorage(DisclosurePolicy.DefaultsKey.message) private var discloseMessage = DisclosurePolicy.defaultMessage
    @State private var accessibilityTrusted = false

    init(model: AppModel) {
        self.model = model
        _sources = State(initialValue: VocabularyStore.configuredSources())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if sources.isEmpty {
                        Text("No vocabulary sources. Use + to add a word, file, or directory.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 6) {
                            ForEach($sources) { $source in
                                sourceRow($source)
                            }
                        }
                    }

                    HStack {
                        Menu {
                            Button("Word") { addWord() }
                            Button("File…") { addFile() }
                            Button("Directory…") { addDirectory() }
                        } label: {
                            Label("Add Source", systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        Spacer()
                    }
                    .padding(.top, 2)
                } header: {
                    Text("Vocabulary Sources")
                        .font(.headline)
                        .padding(.bottom, 4)
                }

                Section {
                    HStack {
                        Button("Preview") { runPreview() }
                            .disabled(isPreviewing)

                        if isPreviewing {
                            ProgressView().scaleEffect(0.6)
                        }

                        if let r = previewResult {
                            Text(previewSummary(r))
                                .font(.caption)
                                .foregroundStyle(r.truncated ? .orange : .secondary)
                        }

                        Spacer()
                    }
                } header: {
                    Text("Test Sources")
                        .font(.headline)
                        .padding(.bottom, 4)
                }

                Section {
                    Toggle("Auto-start recording when a meeting is detected", isOn: $autoStartEnabled)
                        .onChange(of: autoStartEnabled) { _, newValue in
                            model.setAutoStartEnabled(newValue)
                        }
                } header: {
                    Text("Automation")
                        .font(.headline)
                        .padding(.bottom, 4)
                }

                Section {
                    Toggle("Post a transcription notice to the meeting chat", isOn: $discloseEnabled)

                    if discloseEnabled {
                        TextField(
                            "Notice",
                            text: $discloseMessage,
                            prompt: Text(DisclosurePolicy.defaultMessage),
                            axis: .vertical
                        )
                        .labelsHidden()
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)

                        Text("Use {meeting} to insert the detected meeting title.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Only for Microsoft Teams", isOn: $discloseTeamsOnly)

                        Toggle("Send automatically (otherwise copy to clipboard to paste)",
                               isOn: $discloseAutoSend)

                        if discloseAutoSend {
                            HStack(spacing: 8) {
                                Image(systemName: accessibilityTrusted
                                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(accessibilityTrusted ? .green : .orange)
                                Text(accessibilityTrusted
                                     ? "Accessibility enabled — Alembic can post into the chat."
                                     : "Automatic posting needs Accessibility permission.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !accessibilityTrusted {
                                    Button("Grant…") {
                                        model.requestAccessibilityTrust()
                                        accessibilityTrusted = model.isAccessibilityTrusted
                                    }
                                    Button("Settings") { model.openAccessibilitySettings() }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Meeting Disclosure")
                        .font(.headline)
                        .padding(.bottom, 4)
                }
            }
            .formStyle(.grouped)

            Divider()

            Text("Hints take effect on the next recording. Sources are prioritized top to bottom.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 360)
        .onChange(of: sources) { _, newValue in
            persist(newValue)
        }
        .onAppear {
            accessibilityTrusted = model.isAccessibilityTrusted
            // Persist once after a legacy migration so source IDs stay stable
            // across launches instead of being re-derived from the old keys.
            let existing = UserDefaults.standard.string(forKey: VocabularyStore.sourcesDefaultsKey)
            if existing == nil || existing!.isEmpty {
                persist(sources)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func sourceRow(_ source: Binding<VocabularyStore.VocabularySource>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: source.kind) {
                Text("Word").tag(VocabularyStore.VocabularySource.Kind.word)
                Text("File").tag(VocabularyStore.VocabularySource.Kind.file)
                Text("Directory").tag(VocabularyStore.VocabularySource.Kind.directory)
            }
            .labelsHidden()
            .fixedSize()

            switch source.wrappedValue.kind {
            case .word:
                TextField("Term", text: source.value, prompt: Text("Term"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            case .file:
                TextField("Vocabulary file path", text: source.value, prompt: Text("Vocabulary file path"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { browse(source, directories: false) }
            case .directory:
                TextField("Folder path", text: source.value, prompt: Text("Folder path"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { browse(source, directories: true) }
            }

            Button { remove(source.wrappedValue.id) } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this source")
        }
    }

    // MARK: - Mutations

    private func addWord() {
        sources.append(.init(kind: .word, value: ""))
    }

    private func addFile() {
        if let path = runOpenPanel(directories: false, title: "Choose Vocabulary File") {
            sources.append(.init(kind: .file, value: path))
        }
    }

    private func addDirectory() {
        if let path = runOpenPanel(directories: true, title: "Choose Vocabulary Directory") {
            sources.append(.init(kind: .directory, value: path))
        }
    }

    private func remove(_ id: UUID) {
        sources.removeAll { $0.id == id }
    }

    private func browse(_ source: Binding<VocabularyStore.VocabularySource>, directories: Bool) {
        let title = directories ? "Choose Vocabulary Directory" : "Choose Vocabulary File"
        if let path = runOpenPanel(directories: directories, title: title) {
            source.wrappedValue.value = path
        }
    }

    private func runOpenPanel(directories: Bool, title: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.title = title
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func persist(_ value: [VocabularyStore.VocabularySource]) {
        UserDefaults.standard.set(
            VocabularyStore.encodeSources(value),
            forKey: VocabularyStore.sourcesDefaultsKey
        )
    }

    // MARK: - Preview

    private func runPreview() {
        isPreviewing = true
        previewResult = nil
        let snapshot = sources
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                VocabularyStore.load(sources: snapshot)
            }.value
            previewResult = result
            isPreviewing = false
        }
    }

    private func previewSummary(_ r: VocabularyStore.SourceLoadResult) -> String {
        let total = r.terms.count
        let suffix = r.truncated ? " (truncated to \(VocabularyStore.recommendedMaxTerms))" : ""
        return "→ \(total) term\(total == 1 ? "" : "s")" + suffix
    }
}
