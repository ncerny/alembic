import SwiftUI
import AppKit
import AlembicKit

/// Settings panel for configuring vocabulary hint sources.
///
/// Vocabulary hints are passed to `AnalysisContext.contextualStrings[.general]`
/// before each recording session starts, biasing on-device speech recognition
/// toward the terms most likely to appear in your meetings.
///
/// Three sources are combined in priority order (inline > file > folder). The
/// ~500-term Apple limit is enforced by truncating lower-priority sources first.
struct SettingsView: View {
    @AppStorage("alembic.vocabulary.inline")
    private var inlineVocabulary = ""

    @AppStorage("alembic.vocabulary.filePath")
    private var vocabularyFilePath = ""

    @AppStorage("alembic.vocabulary.folderPath")
    private var vocabularyFolderPath = ""

    @State private var previewResult: VocabularyStore.LoadResult?
    @State private var isPreviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Inline Terms") {
                        TextEditor(text: $inlineVocabulary)
                            .font(.body.monospaced())
                            .frame(minHeight: 60, maxHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                    }
                    .help("Comma-separated terms (highest priority). E.g.: Dynatrace, Kubernetes, Zabbix")

                    LabeledContent("Vocabulary File") {
                        HStack {
                            TextField("~/.config/alembic/vocabulary.txt", text: $vocabularyFilePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse…") { browseForFile() }
                        }
                    }
                    .help("Plain-text file with one term per line. Lines starting with # are ignored.")

                    LabeledContent("Markdown Folder") {
                        HStack {
                            TextField("~/path/to/vault", text: $vocabularyFolderPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse…") { browseForFolder() }
                        }
                    }
                    .help("Folder of .md files. Basenames become hints (\"Last, First\" → \"First Last\").")
                } header: {
                    Text("Vocabulary Hints")
                        .font(.headline)
                        .padding(.bottom, 4)
                }

                Section {
                    HStack {
                        Button("Preview") {
                            runPreview()
                        }
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
            }
            .formStyle(.grouped)

            Divider()

            Text("Hints take effect on the next recording. Priority: inline → file → folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 340)
    }

    // MARK: - Helpers

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Vocabulary File"
        if panel.runModal() == .OK, let url = panel.url {
            vocabularyFilePath = url.path
        }
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Markdown Folder"
        if panel.runModal() == .OK, let url = panel.url {
            vocabularyFolderPath = url.path
        }
    }

    private func runPreview() {
        isPreviewing = true
        previewResult = nil
        let filePath = vocabularyFilePath.nilIfEmpty
        let folderPath = vocabularyFolderPath.nilIfEmpty
        let inlineTerms = inlineVocabulary
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                VocabularyStore.load(
                    filePath: filePath,
                    folderPath: folderPath,
                    inlineTerms: inlineTerms
                )
            }.value
            previewResult = result
            isPreviewing = false
        }
    }

    private func previewSummary(_ r: VocabularyStore.LoadResult) -> String {
        var parts: [String] = []
        if r.inlineCount > 0 { parts.append("\(r.inlineCount) inline") }
        if r.fileCount > 0   { parts.append("\(r.fileCount) file") }
        if r.folderCount > 0 { parts.append("\(r.folderCount) folder") }
        let total = "→ \(r.terms.count) term\(r.terms.count == 1 ? "" : "s")"
        let suffix = r.truncated ? " (truncated to \(VocabularyStore.recommendedMaxTerms))" : ""
        return parts.isEmpty ? "0 terms" : parts.joined(separator: " + ") + " " + total + suffix
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
