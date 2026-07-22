//
//  HistoryView.swift
//  HappiE
//
//  Created for HappiE.
//

import SwiftUI

/// Watch history, newest first, persisted on the device. Entries stay
/// playable through their server link even after the library changes.
struct HistoryView: View {
    @Bindable var model: AppModel

    @State private var searchText = ""

    private var filteredEntries: [WatchHistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.history.entries }
        return model.history.entries.filter { entry in
            query
                .split(separator: " ")
                .allSatisfy { entry.title.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text("History")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(HTheme.ink)

                    Spacer()
                }

                if !model.history.entries.isEmpty {
                    HistorySearchBar(text: $searchText)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(HTheme.background)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(HTheme.line)
                    .frame(height: 1)
            }

            if model.history.entries.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "Nothing watched yet",
                    message: "Videos you watch will show up here so you can find them again."
                )
                .frame(maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No matches",
                    message: "No watched videos match that search."
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 18) {
                        ForEach(filteredEntries) { entry in
                            HistoryRow(model: model, entry: entry)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .background(HTheme.background)
    }
}

private struct HistorySearchBar: View {
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        SearchBar(text: $text, focused: $focused)
    }
}

private struct HistoryRow: View {
    @Bindable var model: AppModel
    let entry: WatchHistoryEntry

    var body: some View {
        Button {
            Task {
                await model.play(historyEntry: entry)
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                HistoryThumbnail(model: model, entry: entry)
                    .frame(width: 210, height: 118)

                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(HTheme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if !entry.durationText.isEmpty {
                            Text(entry.durationText)
                            Text("•")
                        }
                        Text(WatchedDateText.text(for: entry.lastWatchedAt))
                    }
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(HTheme.muted)

                    if entry.completed {
                        Label("Watched to the end", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(HTheme.muted)
                    } else if entry.resumePosition != nil {
                        Label("Keep watching", systemImage: "play.circle.fill")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(HTheme.accent)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isPreparingPlayback)
        .accessibilityLabel("\(entry.title), \(WatchedDateText.text(for: entry.lastWatchedAt))")
        .accessibilityHint("Plays the video")
    }
}
