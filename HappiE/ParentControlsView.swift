//
//  ParentControlsView.swift
//  HappiE
//
//  Created for HappiE.
//

import SwiftUI

/// Everything a grown-up needs, in one gated place: profiles, playback
/// defaults, history, library stats, and the API server.
struct ParentControlsView: View {
    @Bindable var model: AppModel
    let onClose: () -> Void

    @AppStorage("HappiEAutoplayNext") private var autoplayNext = true
    @AppStorage("HappiELoopVideo") private var loopEnabled = false
    @State private var apiBaseURLText = ""
    @State private var apiBaseURLError = ""
    @State private var isConfirmingClearHistory = false
    @State private var isConfirmingRemoveDownloads = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Who is watching") {
                    ForEach(model.children) { child in
                        Button {
                            onClose()
                            Task {
                                await model.select(child)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarCircle(name: child.name, size: 36)

                                Text(child.name)
                                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                                    .foregroundStyle(HTheme.ink)

                                Spacer()

                                if child.id == model.selectedChild?.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(HTheme.accent)
                                }
                            }
                        }
                    }
                }

                Section("Playback") {
                    Toggle("Autoplay next video", isOn: $autoplayNext)
                        .tint(HTheme.accent)

                    Toggle("Repeat the same video", isOn: $loopEnabled)
                        .tint(HTheme.accent)
                }

                Section("Library") {
                    LabeledContent("Videos", value: "\(model.videos.count)")
                    LabeledContent("Last synced", value: model.lastSyncedText)

                    Button("Sync library now", systemImage: "arrow.clockwise") {
                        onClose()
                        Task {
                            await model.sync()
                        }
                    }
                }

                Section {
                    Toggle("Auto-save must-have videos", isOn: Binding(
                        get: { model.autoDownloadRequired },
                        set: { model.autoDownloadRequired = $0 }
                    ))
                    .tint(HTheme.accent)

                    LabeledContent("Saved videos", value: "\(model.offline.downloadedCount)")
                    LabeledContent("Storage used", value: model.offline.totalDownloadedText)

                    Button("Remove all downloads", systemImage: "trash", role: .destructive) {
                        isConfirmingRemoveDownloads = true
                    }
                    .disabled(model.offline.downloadedCount == 0)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Videos marked as must-have by the server are saved automatically when this is on. Any video can also be saved or removed from its download button on the home screen.")
                }

                Section("Watch history") {
                    LabeledContent("Videos in history", value: "\(model.history.entries.count)")

                    Button("Clear watch history", systemImage: "trash", role: .destructive) {
                        isConfirmingClearHistory = true
                    }
                    .disabled(model.history.entries.isEmpty)
                }

                Section {
                    TextField("http://localhost:18080", text: $apiBaseURLText)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if !apiBaseURLError.isEmpty {
                        Label(apiBaseURLError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HTheme.accent)
                    }

                    Button("Use this server", systemImage: "checkmark.circle") {
                        saveAPIBaseURL()
                    }
                    .disabled(apiBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines) == model.apiBaseText)

                    Button("Reset to default", systemImage: "arrow.uturn.backward") {
                        model.resetAPIBaseURLToDefault()
                        syncAPIBaseURLText()
                        apiBaseURLError = ""
                    }
                    .disabled(model.apiBaseText == model.defaultAPIBaseText && apiBaseURLText == model.apiBaseText)
                } header: {
                    Text("API server")
                } footer: {
                    Text("Changing servers reloads profiles and videos. HappiE is designed for a trusted home network.")
                }
            }
            .navigationTitle("Parent controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                }
            }
        }
        .tint(HTheme.accent)
        .onAppear(perform: syncAPIBaseURLText)
        .confirmationDialog(
            "Clear watch history?",
            isPresented: $isConfirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                model.history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the locally saved list of watched videos and their thumbnails from this device.")
        }
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $isConfirmingRemoveDownloads,
            titleVisibility: .visible
        ) {
            Button("Remove all downloads", role: .destructive) {
                model.offline.removeAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All videos saved on this device will be deleted. They can be downloaded again any time.")
        }
    }

    private func saveAPIBaseURL() {
        do {
            try model.updateAPIBaseURL(apiBaseURLText)
            syncAPIBaseURLText()
            apiBaseURLError = ""
            onClose()
        } catch {
            apiBaseURLError = error.localizedDescription
        }
    }

    private func syncAPIBaseURLText() {
        apiBaseURLText = model.apiBaseText
    }
}
