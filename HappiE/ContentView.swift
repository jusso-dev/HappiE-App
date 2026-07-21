//
//  ContentView.swift
//  HappiE
//
//  Created for HappiE.
//

import SwiftUI
import Combine
import AVKit
import AVFoundation
import MediaPlayer
import UIKit

struct ContentView: View {
    @StateObject private var model = LibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingAPISettings = false

    var body: some View {
        ZStack {
            HappiEColor.background
                .ignoresSafeArea()

            Group {
                switch model.phase {
                case .welcome:
                    WelcomeAnimationView(message: model.welcomeMessage)
                case .loading:
                    LoadingLibraryView(message: model.loadingMessage)
                case .selectingChild:
                    ChildPickerView(model: model) {
                        isShowingAPISettings = true
                    }
                case .ready:
                    LibraryHomeView(model: model) {
                        isShowingAPISettings = true
                    }
                case .failed:
                    ParentErrorView(model: model, onShowSettings: {
                        isShowingAPISettings = true
                    })
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .environment(\.offlineVideoIDs, model.offlineVideoIDs)
        .environment(\.localThumbnailURLForVideo, { videoID in
            model.offlineAssets.localThumbnailURL(for: videoID)
        })
        .task {
            await model.resume()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                model.recoverForChildUse()
            }
        }
        .fullScreenCover(item: $model.playbackItem) { item in
            VideoPlayerScreen(
                item: item,
                videos: model.videos,
                onSelectVideo: { video in
                    await model.preparePlaybackItem(for: video)
                },
                onRefreshVideos: {
                    await model.refreshLibrarySilently()
                    return model.videos
                }
            ) {
                model.closePlayer()
            }
        }
        .sheet(isPresented: $isShowingAPISettings) {
            APISettingsScreen(model: model) {
                isShowingAPISettings = false
            }
            .presentationDetents([.medium])
        }
    }

}

@MainActor
final class LibraryViewModel: ObservableObject {
    enum Phase {
        case welcome
        case loading
        case selectingChild
        case ready
        case failed
    }

    @Published var phase: Phase = .welcome
    @Published var children: [ChildProfile] = []
    @Published var selectedChild: ChildProfile?
    @Published var videos: [ManifestVideo] = []
    @Published var errorMessage = ""
    @Published var loadingMessage = "Checking your family library"
    @Published var welcomeMessage = "HappiE"
    @Published var lastSyncedText = "Not synced yet"
    @Published var playbackItem: PlaybackItem?
    @Published var playbackErrorMessage = ""
    @Published var isPreparingPlayback = false
    @Published var manifestExpiresAt: Date?
    @Published private(set) var apiBaseURL: URL
    @Published private(set) var offlineVideoIDs: Set<UUID> = []
    @Published private(set) var downloadingVideoIDs: Set<UUID> = []

    private let apiConfigurationStore: APIConfigurationStore
    private let session: URLSession
    private let libraryCache = LibraryCacheStore()
    let offlineAssets: OfflineAssetStore
    private var deviceId: UUID?
    private var hasCachedSnapshot = false
    private var hasResumed = false

    init(
        apiConfigurationStore: APIConfigurationStore? = nil,
        session: URLSession = .shared
    ) {
        let apiConfigurationStore = apiConfigurationStore ?? APIConfigurationStore()
        self.apiConfigurationStore = apiConfigurationStore
        self.session = session
        self.offlineAssets = OfflineAssetStore(session: session)
        _apiBaseURL = Published(initialValue: apiConfigurationStore.loadBaseURL())

        offlineAssets.$offlineVideoIDs.assign(to: &$offlineVideoIDs)
        offlineAssets.$downloadingVideoIDs.assign(to: &$downloadingVideoIDs)

        if let snapshot = libraryCache.load() {
            hasCachedSnapshot = true
            children = snapshot.children
            selectedChild = snapshot.children.first { $0.id == snapshot.selectedChildId }
            deviceId = snapshot.deviceId
            videos = snapshot.videos
            manifestExpiresAt = snapshot.manifestExpiresAt
            if snapshot.lastSyncedAt != nil {
                lastSyncedText = "Last synced from cache"
            }
        }
    }

    func localPlaybackURL(for video: ManifestVideo) -> URL? {
        offlineAssets.localVideoURL(for: video.id)
    }

    func localThumbnailURL(for video: ManifestVideo) -> URL? {
        offlineAssets.localThumbnailURL(for: video.id)
    }

    func isOffline(_ video: ManifestVideo) -> Bool {
        offlineVideoIDs.contains(video.id)
    }

    func isDownloading(_ video: ManifestVideo) -> Bool {
        downloadingVideoIDs.contains(video.id)
    }

    var apiBaseText: String {
        apiBaseURL.absoluteString
    }

    var defaultAPIBaseText: String {
        APIEnvironment.defaultBaseURL.absoluteString
    }

    private var api: APIClient {
        APIClient(environment: APIEnvironment(baseURL: apiBaseURL), session: session)
    }

    var featuredVideo: ManifestVideo? {
        videos.first
    }

    func resume() async {
        guard !hasResumed else { return }
        hasResumed = true
        await showWelcome(message: "HappiE")

        if hasCachedSnapshot, selectedChild != nil, deviceId != nil {
            phase = .ready
            Task { await self.refreshLibrarySilently() }
            return
        }

        if !children.isEmpty {
            phase = .selectingChild
            Task { await self.loadChildren() }
            return
        }

        await loadChildren()
    }

    @discardableResult
    func updateAPIBaseURL(_ text: String) throws -> Bool {
        let newURL = try APIConfigurationStore.normalizedBaseURL(from: text)
        guard newURL != apiBaseURL else { return false }

        apiConfigurationStore.saveBaseURL(newURL)
        return applyAPIBaseURL(newURL)
    }

    @discardableResult
    func resetAPIBaseURLToDefault() -> Bool {
        let newURL = apiConfigurationStore.resetBaseURL()
        return applyAPIBaseURL(newURL)
    }

    func loadChildren() async {
        let showsLoading = (phase != .ready && phase != .selectingChild)
        if showsLoading {
            loadingMessage = "Finding kid profiles"
            phase = .loading
        }

        do {
            let fetched = try await api.children()
            children = fetched
            saveSnapshot()
            if let onlyChild = fetched.first, fetched.count == 1 {
                await select(onlyChild)
            } else if fetched.isEmpty {
                phase = .failed
                errorMessage = "No child profiles are ready yet. Create one in the parent admin app first."
            } else if phase != .ready {
                phase = .selectingChild
            }
        } catch {
            handleLoadChildrenFailure(error)
        }
    }

    private func handleLoadChildrenFailure(_ error: Error) {
        if hasCachedSnapshot, selectedChild != nil, deviceId != nil {
            phase = .ready
            playbackErrorMessage = ""
            lastSyncedText = "Offline · showing saved library"
            return
        }

        if !children.isEmpty {
            phase = .selectingChild
            return
        }

        fail(error)
    }

    func select(_ child: ChildProfile) async {
        let previousSelectedChild = selectedChild
        let previousDeviceId = deviceId
        let canUseCachedLibrary = hasCachedSnapshot && selectedChild?.id == child.id && deviceId != nil
        selectedChild = child

        if canUseCachedLibrary {
            phase = .ready
        } else {
            loadingMessage = "Syncing \(child.name)'s videos"
            phase = .loading
        }

        do {
            let device = try await api.registerDevice(childId: child.id)
            deviceId = device.id
            let manifest = try await api.syncDevice(deviceId: device.id)
            apply(manifest)
            lastSyncedText = "Synced just now"
            phase = .ready
        } catch {
            handleSelectFailure(
                error,
                canUseCachedLibrary: canUseCachedLibrary,
                previousSelectedChild: previousSelectedChild,
                previousDeviceId: previousDeviceId
            )
        }
    }

    private func handleSelectFailure(
        _ error: Error,
        canUseCachedLibrary: Bool,
        previousSelectedChild: ChildProfile?,
        previousDeviceId: UUID?
    ) {
        if canUseCachedLibrary {
            phase = .ready
            lastSyncedText = "Offline · showing saved library"
            return
        }

        selectedChild = previousSelectedChild
        deviceId = previousDeviceId
        fail(error)
    }

    func sync() async {
        await sync(showLoading: true)
    }

    func refreshLibrarySilently() async {
        await sync(showLoading: false)
    }

    private func sync(showLoading: Bool) async {
        guard let deviceId else {
            if let child = selectedChild {
                await select(child)
            }
            return
        }

        if showLoading {
            loadingMessage = "Refreshing videos"
            phase = .loading
        }

        do {
            let manifest = try await api.syncDevice(deviceId: deviceId)
            apply(manifest)
            lastSyncedText = "Synced just now"
            if showLoading {
                phase = .ready
            }
        } catch {
            if hasCachedSnapshot, selectedChild != nil {
                lastSyncedText = "Offline · showing saved library"
                phase = .ready
            } else if showLoading {
                fail(error)
            } else {
                playbackErrorMessage = error.localizedDescription
            }
        }
    }

    func play(_ video: ManifestVideo) async {
        playbackErrorMessage = ""
        isPreparingPlayback = true

        if let localURL = localPlaybackURL(for: video) {
            try? configurePlaybackAudio()
            playbackItem = PlaybackItem(video: video, url: localURL)
            isPreparingPlayback = false
            return
        }

        do {
            try configurePlaybackAudio()
            let response = try await api.playbackURL(videoId: video.id)
            playbackItem = PlaybackItem(video: video, url: response.url)
        } catch {
            playbackErrorMessage = error.localizedDescription
        }

        isPreparingPlayback = false
    }

    func preparePlaybackItem(for video: ManifestVideo) async -> PlaybackItem? {
        playbackErrorMessage = ""

        if let localURL = localPlaybackURL(for: video) {
            try? configurePlaybackAudio()
            return PlaybackItem(video: video, url: localURL)
        }

        do {
            try configurePlaybackAudio()
            let response = try await api.playbackURL(videoId: video.id)
            return PlaybackItem(video: video, url: response.url)
        } catch {
            playbackErrorMessage = error.localizedDescription
            return nil
        }
    }

    private func configurePlaybackAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
    }

    private func apply(_ manifest: SyncManifest) {
        videos = manifest.videos
        manifestExpiresAt = manifest.expiresAt
        offlineAssets.reconcile(videos: manifest.videos, removedIDs: manifest.remove)
        saveSnapshot()
    }

    private func saveSnapshot() {
        hasCachedSnapshot = true
        let snapshot = LibrarySnapshot(
            children: children,
            selectedChildId: selectedChild?.id,
            deviceId: deviceId,
            videos: videos,
            manifestExpiresAt: manifestExpiresAt,
            lastSyncedAt: Date()
        )
        libraryCache.save(snapshot)
    }

    func closePlayer() {
        playbackItem = nil
    }

    func showProfileSwitcher() {
        playbackItem = nil
        phase = .selectingChild
    }

    func recoverForChildUse() {
        playbackItem = nil

        if selectedChild != nil, phase == .selectingChild {
            phase = .ready
        }
    }

    private func applyAPIBaseURL(_ newURL: URL) -> Bool {
        guard newURL != apiBaseURL else { return false }

        apiBaseURL = newURL
        resetLibraryForServerChange()
        return true
    }

    private func resetLibraryForServerChange() {
        libraryCache.clear()
        offlineAssets.clearAll()
        hasCachedSnapshot = false
        deviceId = nil
        selectedChild = nil
        children = []
        videos = []
        playbackItem = nil
        playbackErrorMessage = ""
        isPreparingPlayback = false
        manifestExpiresAt = nil
        lastSyncedText = "Not synced yet"
        errorMessage = ""
        loadingMessage = "Connecting to your family library"
        phase = .loading
        Task { await loadChildren() }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        phase = .failed
    }

    private func showWelcome(message: String) async {
        welcomeMessage = message
        phase = .welcome
        try? await Task.sleep(nanoseconds: 1_650_000_000)
    }
}

private struct APISettingsScreen: View {
    @ObservedObject var model: LibraryViewModel
    let onClose: () -> Void

    @State private var apiBaseURLText = ""
    @State private var apiBaseURLError = ""

    var body: some View {
        ZStack {
            HappiEColor.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Settings")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(HappiEColor.ink)

                        Text("Changing servers clears saved library data from the previous server.")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(HappiEColor.muted)
                    }

                    Spacer()

                    Button("Done", systemImage: "checkmark", action: onClose)
                        .font(.system(size: 19, weight: .black, design: .rounded))
                        .padding(.horizontal, 20)
                        .frame(height: 56)
                        .buttonStyle(SecondaryPillButtonStyle())
                }

                APIBaseURLEditor(
                    title: "API server",
                    text: $apiBaseURLText,
                    currentText: model.apiBaseText,
                    defaultText: model.defaultAPIBaseText,
                    errorMessage: apiBaseURLError,
                    saveTitle: "Save Server",
                    resetTitle: "Reset",
                    onSave: {
                        saveAPIBaseURL()
                    },
                    onReset: resetAPIBaseURL
                )
            }
            .padding(28)
            .frame(maxWidth: 620)
            .background(HappiEColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(CardStroke(cornerRadius: 28))
        }
        .onAppear(perform: syncAPIBaseURLText)
        .onChange(of: model.apiBaseURL) { _, _ in
            syncAPIBaseURLText()
        }
    }

    private func saveAPIBaseURL() {
        do {
            try model.updateAPIBaseURL(apiBaseURLText)
            apiBaseURLText = model.apiBaseText
            apiBaseURLError = ""
        } catch {
            apiBaseURLError = error.localizedDescription
        }
    }

    private func resetAPIBaseURL() {
        model.resetAPIBaseURLToDefault()
        syncAPIBaseURLText()
        apiBaseURLError = ""
    }

    private func syncAPIBaseURLText() {
        apiBaseURLText = model.apiBaseText
    }
}

private struct APIBaseURLEditor: View {
    let title: String
    @Binding var text: String
    let currentText: String
    let defaultText: String
    let errorMessage: String
    let saveTitle: String
    let resetTitle: String
    let onSave: () -> Void
    let onReset: () -> Void

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedText != currentText
    }

    private var canReset: Bool {
        currentText != defaultText || hasChanges
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "network")
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(HappiEColor.ink)

            TextField("http://localhost:18080", text: $text)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .textFieldStyle(.plain)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .inputPanel()

            HStack(spacing: 10) {
                Button {
                    onSave()
                } label: {
                    Label(saveTitle, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .padding(.horizontal, 18)
                        .frame(height: 52)
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .disabled(trimmedText.isEmpty || !hasChanges)

                Button {
                    onReset()
                } label: {
                    Label(resetTitle, systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .padding(.horizontal, 18)
                        .frame(height: 52)
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .disabled(!canReset)
            }

            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(HappiEColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WelcomeAnimationView: View {
    let message: String

    @State private var isPlaying = false

    private let floatingIcons = [
        FloatingIcon(systemName: "play.fill", color: HappiEColor.accent, x: -340, y: -190, delay: 0.0),
        FloatingIcon(systemName: "star.fill", color: HappiEColor.sun, x: 310, y: -160, delay: 0.12),
        FloatingIcon(systemName: "heart.fill", color: HappiEColor.coral, x: -250, y: 175, delay: 0.24),
        FloatingIcon(systemName: "music.note", color: HappiEColor.sky, x: 260, y: 185, delay: 0.34),
        FloatingIcon(systemName: "sparkles", color: HappiEColor.sun, x: 0, y: -245, delay: 0.18)
    ]

    var body: some View {
        ZStack {
            ForEach(floatingIcons) { icon in
                FloatingIconView(icon: icon, isPlaying: isPlaying)
            }

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(HappiEColor.accent.opacity(0.12))
                        .frame(width: 254, height: 254)
                        .scaleEffect(isPlaying ? 1.1 : 0.72)

                    Circle()
                        .fill(HappiEColor.sun.opacity(0.18))
                        .frame(width: 196, height: 196)
                        .scaleEffect(isPlaying ? 0.96 : 0.64)

                    BrandMark(size: 142)
                        .scaleEffect(isPlaying ? 1 : 0.58)
                        .rotationEffect(.degrees(isPlaying ? 0 : -10))
                }
                .animation(.interpolatingSpring(stiffness: 120, damping: 13).delay(0.08), value: isPlaying)

                Text(message)
                    .font(.system(size: 66, weight: .black, design: .rounded))
                    .foregroundStyle(HappiEColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                    .scaleEffect(isPlaying ? 1 : 0.84)
                    .opacity(isPlaying ? 1 : 0)
                    .animation(.easeOut(duration: 0.42).delay(0.22), value: isPlaying)

                Text("Family videos are opening")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(HappiEColor.muted)
                    .opacity(isPlaying ? 1 : 0)
                    .offset(y: isPlaying ? 0 : 12)
                    .animation(.easeOut(duration: 0.38).delay(0.38), value: isPlaying)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onAppear {
            isPlaying = true
        }
    }
}

private struct FloatingIcon: Identifiable {
    let id = UUID()
    let systemName: String
    let color: Color
    let x: CGFloat
    let y: CGFloat
    let delay: Double
}

private struct FloatingIconView: View {
    let icon: FloatingIcon
    let isPlaying: Bool

    var body: some View {
        Image(systemName: icon.systemName)
            .font(.system(size: 34, weight: .black))
            .foregroundStyle(icon.color)
            .frame(width: 78, height: 78)
            .background(HappiEColor.panel)
            .clipShape(Circle())
            .overlay(Circle().stroke(HappiEColor.line, lineWidth: 2))
            .shadow(color: icon.color.opacity(0.18), radius: 14, x: 0, y: 10)
            .scaleEffect(isPlaying ? 1 : 0.22)
            .opacity(isPlaying ? 1 : 0)
            .offset(x: isPlaying ? icon.x : 0, y: isPlaying ? icon.y : 0)
            .rotationEffect(.degrees(isPlaying ? 0 : -18))
            .animation(.interpolatingSpring(stiffness: 110, damping: 11).delay(icon.delay), value: isPlaying)
    }
}

struct PlaybackItem: Identifiable {
    let id = UUID()
    let video: ManifestVideo
    let url: URL
}

private struct VideoPlayerScreen: View {
    let item: PlaybackItem
    let videos: [ManifestVideo]
    let onSelectVideo: (ManifestVideo) async -> PlaybackItem?
    let onRefreshVideos: () async -> [ManifestVideo]
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PlayerController
    @State private var currentItem: PlaybackItem
    @State private var playerVideos: [ManifestVideo]
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var refreshVideosTask: Task<Void, Never>?
    @State private var playerRefreshTask: Task<Void, Never>?
    @State private var playbackRecoveryTask: Task<Void, Never>?
    @State private var videoSwitchTask: Task<Void, Never>?
    @State private var playbackRequestID = UUID()
    @State private var isSwitchingVideo = false

    init(
        item: PlaybackItem,
        videos: [ManifestVideo],
        onSelectVideo: @escaping (ManifestVideo) async -> PlaybackItem?,
        onRefreshVideos: @escaping () async -> [ManifestVideo],
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.videos = videos
        self.onSelectVideo = onSelectVideo
        self.onRefreshVideos = onRefreshVideos
        self.onClose = onClose
        _controller = StateObject(wrappedValue: PlayerController(url: item.url))
        _currentItem = State(initialValue: item)
        _playerVideos = State(initialValue: videos)
    }

    private var suggestedVideos: [ManifestVideo] {
        playerVideos.filter { $0.id != currentItem.video.id }
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VideoPlayer(player: controller.player)
                .ignoresSafeArea()

            Button {
                toggleControls()
            } label: {
                Color.black.opacity(0.001)
            }
            .buttonStyle(.plain)
            .ignoresSafeArea()
            .accessibilityLabel(controlsVisible ? "Hide video controls" : "Show video controls")

            if controlsVisible {
                PlayerChrome(
                    item: currentItem,
                    videos: suggestedVideos,
                    controller: controller,
                    onClose: close,
                    onNext: playNextVideo,
                    onSelect: selectVideo(_:)
                )
                .transition(.opacity)

                CenterVideoTapTarget(onHideControls: hideControls)
                    .zIndex(4)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            controller.play()
            scheduleControlsHide()
            refreshPlayerVideos()
            scheduleVideoRefresh()
        }
        .onDisappear {
            cancelPlayerTasks()
            UIApplication.shared.isIdleTimerDisabled = false
            controller.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)) { notification in
            recoverPlaybackIfNeeded(notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            recoverPlaybackIfNeeded(notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemNewErrorLogEntry)) { notification in
            recoverPlaybackIfNeeded(notification: notification)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .accessibilityLabel("Playing \(currentItem.video.displayTitle)")
    }

    private func close() {
        cancelPlayerTasks()
        controller.pause()
        onClose()
        dismiss()
    }

    private func selectVideo(_ video: ManifestVideo) {
        guard !isSwitchingVideo else { return }
        isSwitchingVideo = true
        showControls()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil

        let requestID = UUID()
        playbackRequestID = requestID
        videoSwitchTask?.cancel()
        videoSwitchTask = Task {
            let nextItem = await onSelectVideo(video)

            await MainActor.run {
                guard playbackRequestID == requestID, !Task.isCancelled else { return }

                guard let nextItem else {
                    isSwitchingVideo = false
                    videoSwitchTask = nil
                    scheduleControlsHide()
                    return
                }

                currentItem = nextItem
                controller.replaceCurrentItem(with: nextItem.url)
                isSwitchingVideo = false
                videoSwitchTask = nil
                refreshPlayerVideos()
                scheduleControlsHide()
            }
        }
    }

    private func playNextVideo() {
        guard let nextVideo = suggestedVideos.first else { return }
        selectVideo(nextVideo)
    }

    private func toggleControls() {
        if controlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    private func showControls() {
        controlsVisible = true
        scheduleControlsHide()
    }

    private func hideControls() {
        hideControlsTask?.cancel()
        controlsVisible = false
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard controller.isPlaying else { return }
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                controlsVisible = false
            }
        }
    }

    private func scheduleVideoRefresh() {
        refreshVideosTask?.cancel()
        refreshVideosTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    refreshPlayerVideos()
                }
            }
        }
    }

    private func refreshPlayerVideos() {
        playerRefreshTask?.cancel()
        playerRefreshTask = Task {
            let refreshedVideos = await onRefreshVideos()
            await MainActor.run {
                guard !Task.isCancelled else { return }
                playerVideos = refreshedVideos
                playerRefreshTask = nil
            }
        }
    }

    private func recoverPlaybackIfNeeded(notification: Notification) {
        guard
            !isSwitchingVideo,
            videoSwitchTask == nil,
            notification.object as AnyObject? === controller.player.currentItem
        else {
            return
        }
        recoverPlayback()
    }

    private func recoverPlayback() {
        guard playbackRecoveryTask == nil, videoSwitchTask == nil else { return }
        let resumeAt = controller.currentTime
        let video = currentItem.video
        let requestID = UUID()
        playbackRequestID = requestID
        playbackRecoveryTask = Task {
            guard let refreshedItem = await onSelectVideo(video) else {
                await MainActor.run {
                    if playbackRequestID == requestID {
                        playbackRecoveryTask = nil
                    }
                }
                return
            }

            await MainActor.run {
                guard playbackRequestID == requestID, !Task.isCancelled else { return }
                currentItem = refreshedItem
                controller.replaceCurrentItem(with: refreshedItem.url, startAt: resumeAt)
                playbackRecoveryTask = nil
            }
        }
    }

    private func cancelPlayerTasks() {
        hideControlsTask?.cancel()
        refreshVideosTask?.cancel()
        playerRefreshTask?.cancel()
        playbackRecoveryTask?.cancel()
        videoSwitchTask?.cancel()
        hideControlsTask = nil
        refreshVideosTask = nil
        playerRefreshTask = nil
        playbackRecoveryTask = nil
        videoSwitchTask = nil
    }
}

private struct PlayerChrome: View {
    let item: PlaybackItem
    let videos: [ManifestVideo]
    @ObservedObject var controller: PlayerController
    let onClose: () -> Void
    let onNext: () -> Void
    let onSelect: (ManifestVideo) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.68), .black.opacity(0.02), .black.opacity(0.74)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                PlayerTopBar(
                    title: item.video.displayTitle,
                    duration: item.video.durationText,
                    controller: controller,
                    onClose: onClose
                )

                Spacer()

                VStack(spacing: 20) {
                    KidPlaybackControls(
                        controller: controller,
                        hasNextVideo: !videos.isEmpty,
                        onNext: onNext
                    )

                    if videos.isEmpty {
                        PlayerEndShelf(title: item.video.displayTitle)
                    } else {
                        SuggestedVideoStrip(videos: videos, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 28)
            }
            .zIndex(2)
        }
    }
}

private struct PlayerTopBar: View {
    let title: String
    let duration: String
    @ObservedObject var controller: PlayerController
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button("Back", systemImage: "arrow.left", action: onClose)
                .labelStyle(.iconOnly)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)

            BrandMark(size: 74)
                .shadow(radius: 0)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                HStack(spacing: 10) {
                    Text("HappiE")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))

                    Label("SUBSCRIBED", systemImage: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(.black.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }

            Spacer()

            AirPlayRouteButton()
                .frame(width: 56, height: 56)

            PlayerVolumeControl(controller: controller)
                .frame(width: 260)

            Image(systemName: "ellipsis")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(90))
                .frame(width: 44, height: 56)
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }
}

private struct CenterVideoTapTarget: View {
    let onHideControls: () -> Void

    var body: some View {
        Button {
            onHideControls()
        } label: {
            Rectangle()
                .fill(.black.opacity(0.001))
                .frame(width: 560, height: 340)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide video controls")
    }
}

private struct PlayerEndShelf: View {
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(HappiEColor.sun)

            Text("\(title) is the only video in this library.")
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer()
        }
        .frame(height: 150)
        .padding(.horizontal, 20)
        .background(.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SuggestedVideoStrip: View {
    let videos: [ManifestVideo]
    let onSelect: (ManifestVideo) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(videos.prefix(8)) { video in
                    Button {
                        onSelect(video)
                    } label: {
                        SuggestedVideoCard(video: video)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(video.displayTitle)")
                }
            }
        }
    }
}

private struct SuggestedVideoCard: View {
    let video: ManifestVideo
    @Environment(\.offlineVideoIDs) private var offlineVideoIDs
    @Environment(\.localThumbnailURLForVideo) private var localThumbnailURLForVideo

    private var isOfflineReady: Bool { offlineVideoIDs.contains(video.id) }
    private var thumbnailURL: URL? {
        localThumbnailURLForVideo(video.id) ?? video.thumbnailURL
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [video.displayColor.opacity(0.96), video.displayColor.opacity(0.62), HappiEColor.sky.opacity(0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: video.symbolName)
                            .font(.system(size: 44, weight: .black))
                            .foregroundStyle(HappiEColor.panel.opacity(0.9))
                    }
                }
            } else {
                Image(systemName: video.symbolName)
                    .font(.system(size: 44, weight: .black))
                    .foregroundStyle(HappiEColor.panel.opacity(0.9))
            }

            Text(video.durationText)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.black.opacity(0.68))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(8)

            if isOfflineReady {
                OfflineReadyBadge(style: .compact)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 390, height: 168)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isOfflineReady ? HappiEColor.accent : .clear, lineWidth: 4)
        )
    }
}

@MainActor
private final class PlayerController: ObservableObject {
    let player: AVPlayer

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    @Published var volume: Double = 1

    private var timeObserver: Any?
    private var volumeObservation: NSKeyValueObservation?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.volume = 1
        player.isMuted = false
        observeSystemVolume()
        addTimeObserver()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        volumeObservation?.invalidate()
    }

    var remainingText: String {
        "-\(Self.timeText(max(0, duration - currentTime)))"
    }

    var currentTimeText: String {
        Self.timeText(currentTime)
    }

    func play() {
        player.isMuted = false
        player.volume = 1
        player.play()
        isPlaying = true
    }

    func replaceCurrentItem(with url: URL, startAt seconds: Double = 0) {
        currentTime = max(0, seconds)
        duration = 1
        isPlaying = false
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if seconds > 0 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.play()
                }
            }
        } else {
            play()
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func jump(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                currentTime = seconds

                if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                    duration = itemDuration
                }
            }
        }
    }

    private func observeSystemVolume() {
        let session = AVAudioSession.sharedInstance()
        volume = Double(session.outputVolume)
        volumeObservation = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
            let systemVolume = Double(session.outputVolume)
            Task { @MainActor [weak self] in
                self?.volume = systemVolume
            }
        }
    }

    private static func timeText(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

private struct KidPlaybackControls: View {
    @ObservedObject var controller: PlayerController
    let hasNextVideo: Bool
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 56, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
            }
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            VStack(spacing: 8) {
                BigTimeline(
                    currentTime: controller.currentTime,
                    duration: controller.duration,
                    onSeek: { seconds in
                        controller.seek(to: seconds)
                    }
                )

                HStack(spacing: 20) {
                    Text(controller.currentTimeText)
                    Spacer()
                    Text(Self.timeLabel(controller.duration))
                }
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)

            Button {
                onNext()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 74, height: 74)
            }
            .disabled(!hasNextVideo)
            .opacity(hasNextVideo ? 1 : 0.38)
        }
        .frame(maxWidth: .infinity)
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

private struct BigTimeline: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
            let knobX = progress * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.96))
                    .frame(height: 8)

                Capsule()
                    .fill(.white)
                    .frame(width: max(8, knobX), height: 8)

                Circle()
                    .fill(Color(red: 1, green: 0.03, blue: 0.14))
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(.white, lineWidth: 10))
                    .shadow(color: .black.opacity(0.26), radius: 6, x: 0, y: 2)
                    .offset(x: min(max(knobX - 23, 0), max(width - 46, 0)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let percent = min(max(value.location.x / width, 0), 1)
                        onSeek(percent * duration)
                    }
            )
        }
        .frame(height: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video timeline")
        .accessibilityValue("\(Int(currentTime)) seconds")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onSeek(currentTime + 15)
            case .decrement:
                onSeek(currentTime - 15)
            @unknown default:
                break
            }
        }
    }
}

private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView(frame: .zero)
        routePicker.activeTintColor = .white
        routePicker.tintColor = .white
        routePicker.prioritizesVideoDevices = true
        routePicker.backgroundColor = .clear
        return routePicker
    }

    func updateUIView(_ routePicker: AVRoutePickerView, context: Context) {
        routePicker.activeTintColor = .white
        routePicker.tintColor = .white
        routePicker.prioritizesVideoDevices = true
    }
}

private struct PlayerVolumeControl: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.white)

            SystemVolumeSlider()
                .frame(height: 34)

            Text("\(Int(controller.volume * 100))")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(.black.opacity(0.56))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Video volume")
    }
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.backgroundColor = .clear
        style(volumeView)
        return volumeView
    }

    func updateUIView(_ volumeView: MPVolumeView, context: Context) {
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        style(volumeView)
    }

    private func style(_ volumeView: MPVolumeView) {
        for case let slider as UISlider in volumeView.subviews {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.34)
            slider.thumbTintColor = .white
        }
    }
}

private struct PlayerRoundButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 34, weight: .black))
                .frame(width: 78, height: 78)
        }
        .buttonStyle(PlayerPillButtonStyle(tint: HappiEColor.panel.opacity(0.94), foreground: HappiEColor.ink))
        .accessibilityLabel(label)
    }
}

private struct PlayerPillButtonStyle: ButtonStyle {
    let tint: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(tint.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct ChildPickerView: View {
    @ObservedObject var model: LibraryViewModel
    let onShowSettings: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderBar(
                    title: "Who is watching?",
                    subtitle: "Choose a parent-approved profile",
                    trailing: {
                        SecondaryIconButton(systemImage: "gearshape.fill", label: "Settings") {
                            onShowSettings()
                        }
                    }
                )

                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 22)], spacing: 22) {
                ForEach(model.children) { child in
                    Button {
                        Task {
                            await model.select(child)
                        }
                    } label: {
                        VStack(spacing: 18) {
                            AvatarCircle(name: child.name, color: child.avatarDisplayColor, size: 112)

                            Text(child.name)
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .foregroundStyle(HappiEColor.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Label("\(child.storageQuotaMb / 1024) GB video space", systemImage: "internaldrive.fill")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(HappiEColor.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 250)
                        .background(HappiEColor.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay(CardStroke(cornerRadius: 28))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 920)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LibraryHomeView: View {
    @ObservedObject var model: LibraryViewModel
    let onShowSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(
                title: "Hi, \(model.selectedChild?.name ?? "there")",
                subtitle: model.lastSyncedText,
                trailing: {
                    ParentControlsMenu(model: model, onShowSettings: onShowSettings)
                }
            )
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SectionTitle(title: "Videos", subtitle: "Picked by your family")

                    if model.videos.isEmpty {
                        EmptyLibraryView()
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 22)
                            ],
                            alignment: .leading,
                            spacing: 22
                        ) {
                            ForEach(model.videos) { video in
                                VideoTile(model: model, video: video)
                            }
                        }
                    }
                }
                .padding(.bottom, 36)
            }
        }
    }
}

private struct ParentControlsMenu: View {
    @ObservedObject var model: LibraryViewModel
    let onShowSettings: () -> Void

    private var offlineReadyCount: Int {
        model.offlineVideoIDs.count
    }

    var body: some View {
        Menu {
            Section("Stats") {
                Label("^[\(model.videos.count) video](inflect: true)", systemImage: "play.rectangle.fill")
                Label("\(offlineReadyCount) ready offline", systemImage: "arrow.down.circle.fill")
                Label(model.lastSyncedText, systemImage: "clock.arrow.circlepath")
            }

            Section("Controls") {
                Button("Switch Profile", systemImage: "person.2.fill") {
                    model.showProfileSwitcher()
                }

                Button("Sync Library", systemImage: "arrow.clockwise") {
                    Task {
                        await model.sync()
                    }
                }

                Button("Settings", systemImage: "gearshape.fill") {
                    onShowSettings()
                }
            }
        } label: {
            Label("Library", systemImage: "slider.horizontal.3")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .padding(.horizontal, 22)
                .frame(height: 62)
        }
        .buttonStyle(SecondaryPillButtonStyle())
    }
}

private struct HeaderBar<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 18) {
            BrandMark(size: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(HappiEColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(subtitle)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(HappiEColor.muted)
            }

            Spacer()

            trailing()
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(HappiEColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(subtitle)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(HappiEColor.muted)
                .lineLimit(1)

            Spacer()
        }
    }
}

private struct VideoTile: View {
    @ObservedObject var model: LibraryViewModel
    let video: ManifestVideo

    private var isOfflineReady: Bool { model.isOffline(video) }
    private var isDownloading: Bool { model.isDownloading(video) }

    var body: some View {
        Button {
            Task {
                await model.play(video)
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ThumbnailView(video: video, size: .tile)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text(video.displayTitle)
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(HappiEColor.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .truncationMode(.tail)

                    HStack(spacing: 10) {
                        Label(video.durationText, systemImage: "play.circle.fill")

                        if isOfflineReady {
                            Label("Offline ready", systemImage: "checkmark.circle.fill")
                        } else if isDownloading {
                            Label("Downloading", systemImage: "arrow.down.circle")
                        }
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(isOfflineReady ? HappiEColor.accent : HappiEColor.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, minHeight: 308, alignment: .topLeading)
            .background(HappiEColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(isOfflineReady ? HappiEColor.accent : HappiEColor.line, lineWidth: isOfflineReady ? 4 : 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isPreparingPlayback)
        .accessibilityLabel("\(video.displayTitle), \(video.durationText)\(isOfflineReady ? ", offline ready" : "")")
        .accessibilityHint("Opens the video player")
    }
}

private struct ThumbnailView: View {
    enum Size {
        case large
        case tile
    }

    let video: ManifestVideo
    let size: Size
    @Environment(\.offlineVideoIDs) private var offlineVideoIDs
    @Environment(\.localThumbnailURLForVideo) private var localThumbnailURLForVideo

    private var isOfflineReady: Bool { offlineVideoIDs.contains(video.id) }
    private var thumbnailURL: URL? {
        localThumbnailURLForVideo(video.id) ?? video.thumbnailURL
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [video.displayColor.opacity(0.96), video.displayColor.opacity(0.62), HappiEColor.sky.opacity(0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        ThumbnailSymbol(video: video, size: size)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ThumbnailSymbol(video: video, size: size)
            }

            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .black))

                Text(video.durationText)
                    .font(.system(size: 16, weight: .black, design: .rounded))
            }
            .foregroundStyle(HappiEColor.panel)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(HappiEColor.ink.opacity(0.72))
            .clipShape(Capsule())
            .padding(14)

            if isOfflineReady {
                OfflineReadyBadge(style: size == .large ? .large : .standard)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isOfflineReady ? HappiEColor.accent : .clear, lineWidth: 5)
        )
    }
}

private struct OfflineReadyBadge: View {
    enum Style {
        case compact
        case standard
        case large
    }

    let style: Style

    private var title: String {
        style == .compact ? "Offline" : "Offline ready"
    }

    private var fontSize: CGFloat {
        switch style {
        case .compact: 14
        case .standard: 15
        case .large: 18
        }
    }

    private var height: CGFloat {
        switch style {
        case .compact: 30
        case .standard: 36
        case .large: 42
        }
    }

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, style == .compact ? 9 : 12)
            .frame(height: height)
            .background(HappiEColor.accent)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.82), lineWidth: 2))
            .shadow(color: .black.opacity(0.26), radius: 8, x: 0, y: 3)
    }
}

private struct ThumbnailSymbol: View {
    let video: ManifestVideo
    let size: ThumbnailView.Size

    var body: some View {
        Image(systemName: video.symbolName)
            .font(.system(size: size == .large ? 86 : 68, weight: .heavy))
            .foregroundStyle(HappiEColor.panel.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.fill")
                .font(.system(size: 54, weight: .black))
                .foregroundStyle(HappiEColor.accent)

            Text("No videos yet")
                .font(.system(size: 32, weight: .black, design: .rounded))
                .foregroundStyle(HappiEColor.ink)

            Text("Ask a parent to assign videos from the family admin app.")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(HappiEColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .background(HappiEColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(CardStroke(cornerRadius: 28))
    }
}

private struct LoadingLibraryView: View {
    let message: String

    var body: some View {
        VStack(spacing: 22) {
            BrandMark(size: 96)

            ProgressView()
                .controlSize(.large)
                .tint(HappiEColor.accent)

            Text(message)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(HappiEColor.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ParentErrorView: View {
    @ObservedObject var model: LibraryViewModel
    let onShowSettings: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 76, weight: .black))
                .foregroundStyle(HappiEColor.warning)

            Text("Library unavailable")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(HappiEColor.ink)

            Text(model.errorMessage)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(HappiEColor.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 680)

            HStack(spacing: 14) {
                Button {
                    Task {
                        await model.loadChildren()
                    }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(width: 210, height: 66)
                }
                .buttonStyle(PrimaryPillButtonStyle())

                Button(action: onShowSettings) {
                    Label("Settings", systemImage: "gearshape.fill")
                        .frame(width: 190, height: 66)
                }
                .buttonStyle(SecondaryPillButtonStyle())

            }
        }
        .padding(32)
        .frame(maxWidth: 760)
        .background(HappiEColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(CardStroke(cornerRadius: 30))
    }
}

private struct BrandMark: View {
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle()
                .fill(HappiEColor.accent)

            Image(systemName: "play.fill")
                .font(.system(size: size * 0.36, weight: .black))
                .foregroundStyle(HappiEColor.panel)
                .offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
        .shadow(color: HappiEColor.accent.opacity(0.22), radius: 18, x: 0, y: 10)
    }
}

private struct AvatarCircle: View {
    let name: String
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(color)

            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .black, design: .rounded))
                .foregroundStyle(HappiEColor.panel)
        }
        .frame(width: size, height: size)
    }
}

private struct SecondaryIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    init(systemImage: String, label: String, action: @escaping () -> Void = {}) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 30, weight: .black))
                .frame(width: 72, height: 72)
        }
        .buttonStyle(IconButtonStyle())
    }
}

private struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: .black, design: .rounded))
            .foregroundStyle(HappiEColor.panel)
            .background(configuration.isPressed ? HappiEColor.accent.opacity(0.82) : HappiEColor.accent)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct SecondaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(HappiEColor.ink)
            .background(configuration.isPressed ? HappiEColor.line.opacity(0.65) : HappiEColor.panel)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(HappiEColor.line, lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(HappiEColor.ink)
            .background(configuration.isPressed ? HappiEColor.line.opacity(0.65) : HappiEColor.background)
            .clipShape(Circle())
            .overlay(Circle().stroke(HappiEColor.line, lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct CardStroke: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(HappiEColor.line, lineWidth: 2)
    }
}

private extension View {
    func inputPanel() -> some View {
        self
            .foregroundStyle(HappiEColor.ink)
            .tint(HappiEColor.accent)
            .colorScheme(.light)
            .padding(.horizontal, 18)
            .frame(height: 64)
            .background(HappiEColor.background)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(CardStroke(cornerRadius: 18))
    }
}

private enum HappiEColor {
    static let background = Color(red: 0.94, green: 0.97, blue: 0.98)
    static let panel = Color(red: 0.99, green: 0.995, blue: 0.99)
    static let ink = Color(red: 0.14, green: 0.20, blue: 0.23)
    static let muted = Color(red: 0.38, green: 0.48, blue: 0.52)
    static let line = Color(red: 0.80, green: 0.88, blue: 0.88)
    static let accent = Color(red: 0.05, green: 0.58, blue: 0.46)
    static let sun = Color(red: 0.91, green: 0.63, blue: 0.18)
    static let coral = Color(red: 0.91, green: 0.34, blue: 0.31)
    static let sky = Color(red: 0.22, green: 0.55, blue: 0.80)
    static let warning = Color(red: 0.82, green: 0.46, blue: 0.13)
}

private extension ChildProfile {
    var avatarDisplayColor: Color {
        let palette = [HappiEColor.accent, HappiEColor.coral, HappiEColor.sky, HappiEColor.sun]
        let index = abs(name.hashValue) % palette.count
        return palette[index]
    }
}

private struct OfflineVideoIDsKey: EnvironmentKey {
    static let defaultValue: Set<UUID> = []
}

private struct LocalThumbnailURLForVideoKey: EnvironmentKey {
    static let defaultValue: (UUID) -> URL? = { _ in nil }
}

private extension EnvironmentValues {
    var offlineVideoIDs: Set<UUID> {
        get { self[OfflineVideoIDsKey.self] }
        set { self[OfflineVideoIDsKey.self] = newValue }
    }

    var localThumbnailURLForVideo: (UUID) -> URL? {
        get { self[LocalThumbnailURLForVideoKey.self] }
        set { self[LocalThumbnailURLForVideoKey.self] = newValue }
    }
}

private extension ManifestVideo {
    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return "Family video"
        }

        guard let url = URL(string: trimmedTitle), let host = url.host?.lowercased() else {
            return trimmedTitle
        }

        if !url.schemeMatchesHTTP {
            return trimmedTitle
        }

        if let descriptionTitle = meaningfulDescription {
            return descriptionTitle
        }

        if host.contains("youtubekids") {
            return "YouTube Kids video"
        }

        if host.contains("youtube") || host.contains("youtu.be") {
            return "YouTube video"
        }

        return host.replacingOccurrences(of: "www.", with: "")
    }

    private var meaningfulDescription: String? {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            return nil
        }

        let genericDescriptions = [
            "imported from user-supplied youtube url.",
            "family-approved video"
        ]

        guard !genericDescriptions.contains(trimmedDescription.lowercased()) else {
            return nil
        }

        return trimmedDescription
    }

    var durationText: String {
        guard let durationSeconds else {
            return "Video"
        }

        let minutes = max(1, Int(ceil(Double(durationSeconds) / 60.0)))
        return "\(minutes) min"
    }

    var symbolName: String {
        let lowercased = title.lowercased()
        if lowercased.contains("music") || lowercased.contains("song") {
            return "music.note.house.fill"
        }
        if lowercased.contains("space") || lowercased.contains("star") {
            return "star.circle.fill"
        }
        if lowercased.contains("car") {
            return "car.circle.fill"
        }
        if lowercased.contains("book") || lowercased.contains("story") {
            return "book.circle.fill"
        }
        if lowercased.contains("food") || lowercased.contains("kitchen") {
            return "fork.knife.circle.fill"
        }
        if lowercased.contains("ocean") || lowercased.contains("water") {
            return "water.waves"
        }
        return "play.rectangle.fill"
    }

    var displayColor: Color {
        let palette = [HappiEColor.sky, HappiEColor.accent, HappiEColor.coral, HappiEColor.sun]
        let index = abs(displayTitle.hashValue) % palette.count
        return palette[index]
    }
}

private extension URL {
    var schemeMatchesHTTP: Bool {
        guard let scheme = scheme?.lowercased() else {
            return false
        }

        return scheme == "http" || scheme == "https"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
