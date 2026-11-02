//
//  HomeView.swift
//  HappiE
//
//  Created for HappiE.
//

import SwiftUI
import UIKit

/// YouTube-style home: brand bar, search, continue-watching shelf, video grid.
struct HomeView: View {
    @Bindable var model: AppModel
    let onOpenParentControls: () -> Void

    @FocusState private var searchFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 16pt margins on iPhone, roomier 24pt on iPad.
    private var margin: CGFloat { horizontalSizeClass == .compact ? 16 : 24 }

    var body: some View {
        VStack(spacing: 0) {
            HomeHeaderBar(
                model: model,
                searchFocused: $searchFocused,
                onOpenParentControls: onOpenParentControls
            )

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    if model.isOfflineMode {
                        OfflineBanner(model: model)
                    }

                    if model.isSearching {
                        searchResults
                    } else {
                        continueWatchingShelf
                        videoGrid(title: "All videos", videos: model.videos)
                    }
                }
                .padding(.horizontal, margin)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .refreshable {
                await model.refreshLibrarySilently()
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(HTheme.background)
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = model.filteredVideos
        if results.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No videos found",
                message: "Try a different word, or clear the search to see everything."
            )
        } else {
            videoGrid(title: "Results", videos: results)
        }
    }

    @ViewBuilder
    private var continueWatchingShelf: some View {
        let resumable = model.continueWatching
        if !resumable.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Continue watching")
                    .scaledFont(size: 22, weight: .heavy, relativeTo: .title2)
                    .foregroundStyle(HTheme.ink)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(resumable) { entry in
                            ContinueWatchingCard(model: model, entry: entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func videoGrid(title: String, videos: [ManifestVideo]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .scaledFont(size: 22, weight: .heavy, relativeTo: .title2)
                .foregroundStyle(HTheme.ink)

            if videos.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: "No videos yet",
                    message: "Ask a grown-up to add videos from the family admin app."
                )
            } else {
                // One column on iPhone portrait, two in landscape, more on iPad.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 20)],
                    alignment: .leading,
                    spacing: 26
                ) {
                    ForEach(videos) { video in
                        VideoCard(model: model, video: video)
                    }
                }
            }
        }
    }
}

private struct HomeHeaderBar: View {
    @Bindable var model: AppModel
    var searchFocused: FocusState<Bool>.Binding
    let onOpenParentControls: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: isCompact ? 10 : 14) {
                BrandWordmark(markSize: isCompact ? 32 : 36)

                Spacer()

                if let child = model.selectedChild {
                    HStack(spacing: 8) {
                        AvatarCircle(name: child.name, size: 34)

                        Text(child.name)
                            .scaledFont(size: 17, weight: .bold, relativeTo: .body)
                            .foregroundStyle(HTheme.ink)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Watching as \(child.name)")
                }

                Button(action: onOpenParentControls) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HTheme.muted)
                        .frame(width: 44, height: 44)
                        .background(HTheme.surface)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Parent controls")
            }

            SearchBar(text: $model.searchText, focused: searchFocused)
        }
        .padding(.horizontal, isCompact ? 16 : 24)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(HTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HTheme.line)
                .frame(height: 1)
        }
    }
}

struct SearchBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(HTheme.muted)

            TextField("Search videos", text: $text)
                .scaledFont(size: 19, weight: .medium, relativeTo: .body)
                .foregroundStyle(HTheme.ink)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused(focused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(HTheme.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.trailing, -12)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(HTheme.surface)
        .clipShape(Capsule())
    }
}

/// Banner shown when the app is serving the locally saved library.
private struct OfflineBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(HTheme.muted)

            Text("You're offline — showing saved videos")
                .scaledFont(size: 16, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(HTheme.ink)

            Spacer()

            Button {
                Task {
                    await model.sync()
                }
            } label: {
                Text("Retry")
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(HTheme.surface)
        .clipShape(.rect(cornerRadius: 14))
    }
}

/// The standard video card: 16:9 thumbnail, duration badge, title below,
/// and a download control so each video can be saved to the device.
struct VideoCard: View {
    @Bindable var model: AppModel
    let video: ManifestVideo

    private var historyEntry: WatchHistoryEntry? {
        model.history.entry(for: video.id)
    }

    private var offlineState: OfflineState {
        model.offline.state(for: video.id)
    }

    /// In offline mode, only downloaded videos can actually play.
    private var isPlayable: Bool {
        !model.isOfflineMode || offlineState.isDownloaded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task {
                    await model.play(video)
                }
            } label: {
                VideoThumbnail(
                    video: video,
                    progress: historyEntry?.progressFraction,
                    localThumbnailURL: model.offline.thumbnailFileURL(for: video.id),
                    isOffline: model.isOfflineMode,
                    thumbnailRevision: model.offline.thumbnailRevision
                )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(model.isPreparingPlayback || !isPlayable)
            .accessibilityLabel("\(video.displayTitle)\(video.durationText.isEmpty ? "" : ", \(video.durationText)")")
            .accessibilityHint(isPlayable ? "Plays the video" : "Not available offline")

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.displayTitle)
                        .scaledFont(size: 18, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(HTheme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if !video.durationText.isEmpty {
                            Text(video.durationText)
                        }

                        if offlineState.isDownloaded {
                            Text("•")
                            Label("Saved", systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(HTheme.accentText)
                        }

                        if let historyEntry, historyEntry.completed {
                            Text("•")
                            Label("Watched", systemImage: "checkmark")
                        }
                    }
                    .scaledFont(size: 14, weight: .medium, relativeTo: .footnote)
                    .foregroundStyle(HTheme.muted)
                }

                Spacer(minLength: 0)

                DownloadControl(model: model, video: video)
            }
            .padding(.horizontal, 4)
        }
        .opacity(isPlayable ? 1 : 0.45)
    }
}

/// Per-video download button: tap to save, tap again to cancel or remove.
struct DownloadControl: View {
    @Bindable var model: AppModel
    let video: ManifestVideo

    @State private var isConfirmingRemove = false

    private var offlineState: OfflineState {
        model.offline.state(for: video.id)
    }

    private var hasDownloadableAsset: Bool {
        video.assets.contains(where: { $0.kind == .mp4 })
    }

    var body: some View {
        if hasDownloadableAsset || offlineState.isDownloaded {
            Button {
                switch offlineState {
                case .notDownloaded:
                    model.offline.download(video)
                case .downloading:
                    model.offline.cancelDownload(videoId: video.id)
                case .downloaded:
                    isConfirmingRemove = true
                }
            } label: {
                Group {
                    switch offlineState {
                    case .notDownloaded:
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(HTheme.muted)
                    case .downloading(let progress):
                        DownloadProgressRing(progress: progress)
                    case .downloaded:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(HTheme.accent)
                    }
                }
                // Frame and hit shape on the label, so the whole 44pt square
                // is tappable rather than just the glyph.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(accessibilityText)
            .confirmationDialog(
                "Remove this download?",
                isPresented: $isConfirmingRemove,
                titleVisibility: .visible
            ) {
                Button("Remove download", role: .destructive) {
                    model.offline.removeDownload(videoId: video.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(video.displayTitle) will no longer be available offline.")
            }
        }
    }

    private var accessibilityText: String {
        switch offlineState {
        case .notDownloaded: "Save \(video.displayTitle) to this device"
        case .downloading: "Cancel download of \(video.displayTitle)"
        case .downloaded: "Remove downloaded copy of \(video.displayTitle)"
        }
    }
}

struct DownloadProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(HTheme.line, lineWidth: 3)

            Circle()
                .trim(from: 0, to: max(0.03, min(progress, 1)))
                .stroke(HTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(HTheme.accent)
        }
        .frame(width: 26, height: 26)
        .animation(.linear(duration: 0.2), value: progress)
    }
}

/// Shared 16:9 thumbnail with duration badge and optional red progress bar.
/// Prefers a locally cached image so saved videos render offline.
struct VideoThumbnail: View {
    let video: ManifestVideo
    let progress: Double?
    var localThumbnailURL: URL? = nil
    var isOffline = false
    var thumbnailRevision = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HTheme.surface

            OfflineFirstImage(
                localURL: localThumbnailURL,
                remoteURL: !isOffline && localThumbnailURL == nil ? video.thumbnailURL : nil
            )
            .id(thumbnailRevision)

            if !video.durationText.isEmpty {
                DurationBadge(text: video.durationText)
                    .padding(8)
            }

            if let progress, progress > 0 {
                WatchProgressBar(progress: progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .clipped()
        .clipShape(.rect(cornerRadius: HTheme.thumbnailCorner))
    }
}

struct ThumbnailPlaceholder: View {
    var body: some View {
        ZStack {
            HTheme.surface

            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(HTheme.line)
        }
    }
}

/// Renders disk-backed images without sending file URLs through AsyncImage.
/// Remote images remain lazy; local images stay usable with no network.
struct OfflineFirstImage: View {
    let localURL: URL?
    let remoteURL: URL?

    @State private var localData: Data?

    var body: some View {
        Group {
            if let localData, let image = UIImage(data: localData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if localURL != nil {
                ThumbnailPlaceholder()
            } else if let remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        ThumbnailPlaceholder()
                    }
                }
            } else {
                ThumbnailPlaceholder()
            }
        }
        .task(id: localURL) {
            guard let localURL, localURL.isFileURL else {
                localData = nil
                return
            }

            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: localURL)
            }.value
            guard !Task.isCancelled else { return }
            localData = data
        }
    }
}

struct DurationBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .scaledFont(size: 13, weight: .bold, design: .default, relativeTo: .footnote)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(minHeight: 24)
            // Sits on a thumbnail, so it grows only a little.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .background(HTheme.badge)
            .clipShape(.rect(cornerRadius: 5))
    }
}

struct WatchProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.white.opacity(0.4))

                Rectangle()
                    .fill(HTheme.accent)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

private struct ContinueWatchingCard: View {
    @Bindable var model: AppModel
    let entry: WatchHistoryEntry

    var body: some View {
        Button {
            Task {
                await model.play(historyEntry: entry)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HistoryThumbnail(model: model, entry: entry)
                    .frame(width: 264, height: 148)

                Text(entry.title)
                    .scaledFont(size: 16, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(HTheme.ink)
                    .lineLimit(1)
                    .frame(width: 264, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isPreparingPlayback)
        .accessibilityLabel("Continue watching \(entry.title)")
    }
}

/// Thumbnail for history entries: prefers the locally cached copy, then uses
/// the live library image while online.
struct HistoryThumbnail: View {
    @Bindable var model: AppModel
    let entry: WatchHistoryEntry

    private var imageURL: URL? {
        model.offline.thumbnailFileURL(for: entry.id)
            ?? model.history.thumbnailFileURL(for: entry.id)
    }

    private var remoteImageURL: URL? {
        guard !model.isOfflineMode, imageURL == nil else { return nil }
        return model.videos.first(where: { $0.id == entry.id })?.thumbnailURL
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HTheme.surface

            OfflineFirstImage(localURL: imageURL, remoteURL: remoteImageURL)
                .id("\(model.offline.thumbnailRevision)-\(model.history.thumbnailRevision)")

            if !entry.durationText.isEmpty {
                DurationBadge(text: entry.durationText)
                    .padding(8)
            }

            if let progress = entry.progressFraction, progress > 0 {
                WatchProgressBar(progress: progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .clipped()
        .clipShape(.rect(cornerRadius: HTheme.thumbnailCorner))
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(HTheme.muted)

            Text(title)
                .scaledFont(size: 24, weight: .heavy, relativeTo: .title)
                .foregroundStyle(HTheme.ink)

            Text(message)
                .scaledFont(size: 17, weight: .medium, relativeTo: .body)
                .foregroundStyle(HTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}
