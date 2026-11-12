#if os(macOS)
import AppKit
import SilveranKit
import SwiftUI

struct MacObsidianSettingsView: View {
    @State private var settings = ObsidianSyncSettings()
    @State private var loaded = false
    @State private var status: ObsidianSyncStatus?
    @State private var isSyncing = false
    @State private var observerID: UUID?
    private let labelWidth: CGFloat = 180

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Obsidian")
                    .font(.headline)

                Text(
                    "Silveran keeps a note for each book in your vault. Starting a book adds the date to the note's readings list. Every highlight goes into a \"Destaques\" section at the end of the note. Silveran rewrites only that section, never the rest of the note."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Toggle("Sync highlights to Obsidian", isOn: binding(\.enabled))
                    .disabled(settings.vaultPath == nil)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    GridRow {
                        label("Vault folder")
                        HStack(spacing: 8) {
                            Text(settings.vaultPath ?? "Not chosen")
                                .foregroundStyle(settings.vaultPath == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 420, alignment: .leading)
                            Button("Choose…") { chooseVault() }
                        }
                    }
                    GridRow {
                        label("Book notes folder")
                        TextField("Sources", text: binding(\.notesFolder))
                            .frame(maxWidth: 320)
                    }
                    GridRow {
                        label("Book template")
                        TextField("Templates/Book.md", text: binding(\.templatePath))
                            .frame(maxWidth: 320)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        syncAll()
                    } label: {
                        Label(
                            "Sync All Highlights Now",
                            systemImage: "arrow.triangle.2.circlepath",
                        )
                    }
                    .disabled(!settings.enabled || settings.vaultPath == nil || isSyncing)
                    if isSyncing {
                        ProgressView().controlSize(.small)
                    }
                }

                if let status {
                    Label(
                        status.message,
                        systemImage: status.isError
                            ? "exclamationmark.triangle" : "checkmark.circle",
                    )
                    .font(.callout)
                    .foregroundStyle(status.isError ? .red : .secondary)
                    .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .task {
            settings = await ObsidianSyncActor.shared.settings()
            status = await ObsidianSyncActor.shared.status()
            loaded = true
            observerID = await ObsidianSyncActor.shared.addObserver { newStatus in
                Task { @MainActor in status = newStatus }
            }
        }
        .onDisappear {
            if let observerID {
                Task { await ObsidianSyncActor.shared.removeObserver(id: observerID) }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ObsidianSyncSettings, Value>)
        -> Binding<Value>
    {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                save()
            },
        )
    }

    private func save() {
        guard loaded else { return }
        let snapshot = settings
        Task { await ObsidianSyncActor.shared.updateSettings(snapshot) }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose Vault"
        panel.message = "Choose your Obsidian vault folder"
        if let path = settings.vaultPath {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        guard
            let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil,
            )
        else {
            status = ObsidianSyncStatus(
                date: Date(),
                message: "Could not save access to that folder.",
                isError: true,
            )
            return
        }
        settings.vaultPath = url.path
        settings.vaultBookmark = bookmark
        save()
    }

    private func syncAll() {
        isSyncing = true
        Task {
            await ObsidianSyncActor.shared.syncAllHighlights()
            await MainActor.run { isSyncing = false }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .frame(width: labelWidth, alignment: .trailing)
            .foregroundStyle(.secondary)
    }
}
#endif
