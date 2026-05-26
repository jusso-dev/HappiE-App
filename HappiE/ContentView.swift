//
//  ContentView.swift
//  HappiE
//
//  Created by Justin Middler on 25/5/2026.
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

    var body: some View {
        ZStack {
            HeyloColor.background
                .ignoresSafeArea()

            Group {
                switch model.phase {
                case .welcome:
                    WelcomeAnimationView(message: model.welcomeMessage)
                case .signedOut:
                    ParentLoginView(model: model)
                case .loading:
                    LoadingLibraryView(message: model.loadingMessage)
                case .selectingChild:
                    ChildPickerView(model: model, performAppAction: performAppAction(_:))
                case .ready:
                    LibraryHomeView(model: model, performAppAction: performAppAction(_:))
                case .failed:
                    ParentErrorView(model: model)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
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
    }

    private func performAppAction(_ action: AppAction) {
        switch action {
        case .switchProfile:
            model.phase = .selectingChild
        case .signOut:
            model.signOut()
        }
    }
}

private enum AppAction {
    case switchProfile
    case signOut
}

@MainActor
final class LibraryViewModel: ObservableObject {
    enum Phase {
        case welcome
        case signedOut
        case loading
        case selectingChild
        case ready
        case failed
    }

    @Published var phase: Phase = .signedOut
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

    let apiBaseText = APIEnvironment.local.baseURL.absoluteString

    private let api = APIClient()
    private let authStore = AuthStore()
    private var tokens: StoredTokens?
    private var deviceId: UUID?
    private var hasResumed = false

    var featuredVideo: ManifestVideo? {
        videos.first
    }

    func resume() async {
        guard !hasResumed else { return }
        hasResumed = true
        await showWelcome(message: "HappiE")

        guard let storedTokens = authStore.loadTokens() else {
            phase = .signedOut
            return
        }

        tokens = storedTokens
        await loadChildren()
    }

    func signIn(email: String, password: String) async {
        loadingMessage = "Opening your family library"
        phase = .loading

        do {
            let tokenResponse = try await api.login(email: email, password: password)
            let storedTokens = StoredTokens(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken
            )
            authStore.save(storedTokens)
            tokens = storedTokens
            await showWelcome(message: "Let's watch")
            await loadChildren()
        } catch {
            fail(error)
        }
    }

    func loadChildren() async {
        guard let tokens else {
            phase = .signedOut
            return
        }

        loadingMessage = "Finding kid profiles"
        phase = .loading

        do {
            children = try await api.children(token: tokens.accessToken)
            if let onlyChild = children.first, children.count == 1 {
                await select(onlyChild)
            } else {
                phase = children.isEmpty ? .failed : .selectingChild
                if children.isEmpty {
                    errorMessage = "No child profiles are ready yet. Create one in the parent admin app first."
                }
            }
        } catch {
            await refreshThenRetry { [weak self] in
                await self?.loadChildren()
            } onFailure: {
                fail(error)
            }
        }
    }

    func select(_ child: ChildProfile) async {
        guard let tokens else {
            phase = .signedOut
            return
        }

        selectedChild = child
        loadingMessage = "Syncing \(child.name)'s videos"
        phase = .loading

        do {
            let device = try await api.registerDevice(childId: child.id, token: tokens.accessToken)
            deviceId = device.id
            let manifest = try await api.syncDevice(deviceId: device.id, token: tokens.accessToken)
            apply(manifest)
            lastSyncedText = "Synced just now"
            phase = .ready
        } catch {
            await refreshThenRetry { [weak self] in
                await self?.select(child)
            } onFailure: {
                fail(error)
            }
        }
    }

    func sync() async {
        await sync(showLoading: true)
    }

    func refreshLibrarySilently() async {
        await sync(showLoading: false)
    }

    private func sync(showLoading: Bool) async {
        guard let tokens, let deviceId else {
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
            let manifest = try await api.syncDevice(deviceId: deviceId, token: tokens.accessToken)
            apply(manifest)
            lastSyncedText = "Synced just now"
            if showLoading {
                phase = .ready
            }
        } catch {
            if showLoading {
                fail(error)
            } else {
                playbackErrorMessage = error.localizedDescription
            }
        }
    }

    func play(_ video: ManifestVideo) async {
        guard let tokens else {
            phase = .signedOut
            return
        }

        playbackErrorMessage = ""
        isPreparingPlayback = true

        do {
            try configurePlaybackAudio()
            let response = try await api.playbackURL(videoId: video.id, token: tokens.accessToken)
            playbackItem = PlaybackItem(video: video, url: response.url)
        } catch {
            await refreshThenRetry { [weak self] in
                await self?.play(video)
            } onFailure: {
                playbackErrorMessage = error.localizedDescription
            }
        }

        isPreparingPlayback = false
    }

    func preparePlaybackItem(for video: ManifestVideo) async -> PlaybackItem? {
        guard let tokens else {
            phase = .signedOut
            return nil
        }

        playbackErrorMessage = ""

        do {
            try configurePlaybackAudio()
            let response = try await api.playbackURL(videoId: video.id, token: tokens.accessToken)
            return PlaybackItem(video: video, url: response.url)
        } catch {
            var preparedItem: PlaybackItem?
            await refreshThenRetry { [weak self] in
                preparedItem = await self?.preparePlaybackItem(for: video)
            } onFailure: {
                playbackErrorMessage = error.localizedDescription
            }
            return preparedItem
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

    func signOut() {
        authStore.clear()
        tokens = nil
        deviceId = nil
        selectedChild = nil
        videos = []
        phase = .signedOut
    }

    private func refreshThenRetry(_ retry: @escaping () async -> Void, onFailure: () -> Void) async {
        guard let refreshToken = tokens?.refreshToken else {
            onFailure()
            return
        }

        do {
            let response = try await api.refresh(refreshToken: refreshToken)
            let refreshed = StoredTokens(accessToken: response.accessToken, refreshToken: response.refreshToken)
            authStore.save(refreshed)
            tokens = refreshed
            await retry()
        } catch {
            authStore.clear()
            onFailure()
        }
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

private struct ParentLoginView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        HStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 28) {
                BrandMark()

                VStack(alignment: .leading, spacing: 10) {
                    Text("HappiE")
                        .font(.system(size: 64, weight: .black, design: .rounded))
                        .foregroundStyle(HeyloColor.ink)

                    Text("Private family videos for little hands.")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(HeyloColor.muted)
                }

                HStack(spacing: 16) {
                    TrustBadge(icon: "lock.fill", title: "Parent approved")
                    TrustBadge(icon: "ipad", title: "iPad ready")
                    TrustBadge(icon: "arrow.down.circle.fill", title: "Offline videos")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 20) {
                Text("Parent sign in")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(HeyloColor.ink)

                TextField("Email", text: $email)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .textFieldStyle(.plain)
                    .inputPanel()

                SecureField("Password", text: $password)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .textFieldStyle(.plain)
                    .inputPanel()

                Button {
                    Task {
                        await model.signIn(email: email, password: password)
                    }
                } label: {
                    Label("Open Library", systemImage: "play.fill")
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 74)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(email.isEmpty || password.isEmpty)

                Text(model.apiBaseText)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(HeyloColor.muted)
            }
            .padding(28)
            .frame(width: 420)
            .background(HeyloColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(CardStroke(cornerRadius: 28))
        }
    }
}

private struct WelcomeAnimationView: View {
    let message: String

    @State private var isPlaying = false

    private let floatingIcons = [
        FloatingIcon(systemName: "play.fill", color: HeyloColor.accent, x: -340, y: -190, delay: 0.0),
        FloatingIcon(systemName: "star.fill", color: HeyloColor.sun, x: 310, y: -160, delay: 0.12),
        FloatingIcon(systemName: "heart.fill", color: HeyloColor.coral, x: -250, y: 175, delay: 0.24),
        FloatingIcon(systemName: "music.note", color: HeyloColor.sky, x: 260, y: 185, delay: 0.34),
        FloatingIcon(systemName: "sparkles", color: HeyloColor.sun, x: 0, y: -245, delay: 0.18)
    ]

    var body: some View {
        ZStack {
            ForEach(floatingIcons) { icon in
                FloatingIconView(icon: icon, isPlaying: isPlaying)
            }

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(HeyloColor.accent.opacity(0.12))
                        .frame(width: 254, height: 254)
                        .scaleEffect(isPlaying ? 1.1 : 0.72)

                    Circle()
                        .fill(HeyloColor.sun.opacity(0.18))
                        .frame(width: 196, height: 196)
                        .scaleEffect(isPlaying ? 0.96 : 0.64)

                    BrandMark(size: 142)
                        .scaleEffect(isPlaying ? 1 : 0.58)
                        .rotationEffect(.degrees(isPlaying ? 0 : -10))
                }
                .animation(.interpolatingSpring(stiffness: 120, damping: 13).delay(0.08), value: isPlaying)

                Text(message)
                    .font(.system(size: 66, weight: .black, design: .rounded))
                    .foregroundStyle(HeyloColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                    .scaleEffect(isPlaying ? 1 : 0.84)
                    .opacity(isPlaying ? 1 : 0)
                    .animation(.easeOut(duration: 0.42).delay(0.22), value: isPlaying)

                Text("Family videos are opening")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(HeyloColor.muted)
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
            .background(HeyloColor.panel)
            .clipShape(Circle())
            .overlay(Circle().stroke(HeyloColor.line, lineWidth: 2))
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
    @State private var playbackRecoveryTask: Task<Void, Never>?
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
            hideControlsTask?.cancel()
            refreshVideosTask?.cancel()
            playbackRecoveryTask?.cancel()
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
        .accessibilityLabel("Playing \(currentItem.video.title)")
    }

    private func close() {
        hideControlsTask?.cancel()
        refreshVideosTask?.cancel()
        playbackRecoveryTask?.cancel()
        controller.pause()
        onClose()
        dismiss()
    }

    private func selectVideo(_ video: ManifestVideo) {
        guard !isSwitchingVideo else { return }
        isSwitchingVideo = true
        showControls()

        Task {
            guard let nextItem = await onSelectVideo(video) else {
                await MainActor.run {
                    isSwitchingVideo = false
                    scheduleControlsHide()
                }
                return
            }

            await MainActor.run {
                currentItem = nextItem
                controller.replaceCurrentItem(with: nextItem.url)
                isSwitchingVideo = false
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
        Task {
            let refreshedVideos = await onRefreshVideos()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                playerVideos = refreshedVideos
            }
        }
    }

    private func recoverPlaybackIfNeeded(notification: Notification) {
        guard notification.object as AnyObject? === controller.player.currentItem else { return }
        recoverPlayback()
    }

    private func recoverPlayback() {
        guard playbackRecoveryTask == nil else { return }
        let resumeAt = controller.currentTime
        playbackRecoveryTask = Task {
            guard let refreshedItem = await onSelectVideo(currentItem.video) else {
                await MainActor.run {
                    playbackRecoveryTask = nil
                }
                return
            }

            await MainActor.run {
                currentItem = refreshedItem
                controller.replaceCurrentItem(with: refreshedItem.url, startAt: resumeAt)
                playbackRecoveryTask = nil
            }
        }
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
                    title: item.video.title,
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
                        PlayerEndShelf(title: item.video.title)
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
                .foregroundStyle(HeyloColor.sun)

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
                    .accessibilityLabel("Play \(video.title)")
                }
            }
        }
    }
}

private struct SuggestedVideoCard: View {
    let video: ManifestVideo

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [video.displayColor.opacity(0.96), video.displayColor.opacity(0.62), HeyloColor.sky.opacity(0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let thumbnailURL = video.thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: video.symbolName)
                            .font(.system(size: 44, weight: .black))
                            .foregroundStyle(HeyloColor.panel.opacity(0.9))
                    }
                }
            } else {
                Image(systemName: video.symbolName)
                    .font(.system(size: 44, weight: .black))
                    .foregroundStyle(HeyloColor.panel.opacity(0.9))
            }

            Text(video.durationText)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.black.opacity(0.68))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(8)

            if video.isOfflineReady {
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
                .stroke(video.isOfflineReady ? HeyloColor.accent : .clear, lineWidth: 4)
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

    init(url: URL) {
        player = AVPlayer(url: url)
        player.volume = 1
        player.isMuted = false
        addTimeObserver()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    var remainingText: String {
        "-\(Self.timeText(max(0, duration - currentTime)))"
    }

    var currentTimeText: String {
        Self.timeText(currentTime)
    }

    func play() {
        player.isMuted = false
        player.volume = Float(volume)
        player.play()
        isPlaying = true
    }

    func replaceCurrentItem(with url: URL, startAt seconds: Double = 0) {
        currentTime = max(0, seconds)
        duration = 1
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

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        player.isMuted = clamped == 0
        player.volume = Float(clamped)
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

            Slider(
                value: Binding(
                    get: { controller.volume },
                    set: { controller.setVolume($0) }
                ),
                in: 0...1
            )
            .tint(.white)

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
        .buttonStyle(PlayerPillButtonStyle(tint: HeyloColor.panel.opacity(0.94), foreground: HeyloColor.ink))
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
    let performAppAction: (AppAction) -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderBar(
                    title: "Who is watching?",
                    subtitle: "Choose a parent-approved profile",
                    trailing: {
                        ParentButton(title: "Sign Out", icon: "rectangle.portrait.and.arrow.right") {
                            performAppAction(.signOut)
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
                                .foregroundStyle(HeyloColor.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Label("\(child.storageQuotaMb / 1024) GB video space", systemImage: "internaldrive.fill")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(HeyloColor.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 250)
                        .background(HeyloColor.panel)
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
    let performAppAction: (AppAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(
                title: "Hi, \(model.selectedChild?.name ?? "there")",
                subtitle: model.lastSyncedText,
                trailing: {
                    HStack(spacing: 12) {
                        if model.children.count > 1 {
                            ParentButton(title: "Switch", icon: "person.2.fill") {
                                model.showProfileSwitcher()
                            }
                        }

                        ParentButton(title: "Sync", icon: "arrow.clockwise") {
                            Task {
                                await model.sync()
                            }
                        }

                        ParentButton(title: "Profiles", icon: "person.2.fill") {
                            performAppAction(.switchProfile)
                        }
                    }
                }
            )
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    if let featuredVideo = model.featuredVideo {
                        ContinueWatchingView(model: model, video: featuredVideo)
                    }

                    BigActionRow(
                        downloadedCount: model.videos.filter { $0.downloadPriority == .required }.count,
                        videoCount: model.videos.count
                    )

                    VStack(alignment: .leading, spacing: 18) {
                        SectionTitle(title: "\(model.selectedChild?.name ?? "Kid")'s videos", subtitle: "Picked by your family")

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
                }
                .padding(.bottom, 36)
            }
        }
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
                    .foregroundStyle(HeyloColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(subtitle)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(HeyloColor.muted)
            }

            Spacer()

            trailing()
        }
    }
}

private struct ContinueWatchingView: View {
    @ObservedObject var model: LibraryViewModel
    let video: ManifestVideo

    var body: some View {
        HStack(spacing: 26) {
            ThumbnailView(video: video, size: .large)
                .frame(width: 360, height: 204)

            VStack(alignment: .leading, spacing: 18) {
                Text("Ready to watch")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(HeyloColor.accent)

                Text(video.title)
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(HeyloColor.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(video.description.isEmpty ? "Family-approved video" : video.description)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(HeyloColor.muted)
                    .lineLimit(2)

                HStack(spacing: 14) {
                    PrimaryButton(title: model.isPreparingPlayback ? "Opening" : "Play", systemImage: "play.fill") {
                        Task {
                            await model.play(video)
                        }
                    }
                    .disabled(model.isPreparingPlayback)
                    SecondaryIconButton(systemImage: "arrow.down.circle.fill", label: "Download")
                }

                if !model.playbackErrorMessage.isEmpty {
                    Text(model.playbackErrorMessage)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(HeyloColor.warning)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
        .background(HeyloColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(CardStroke(cornerRadius: 28))
    }
}

private struct BigActionRow: View {
    let downloadedCount: Int
    let videoCount: Int

    var body: some View {
        HStack(spacing: 18) {
            BigActionButton(title: "Ready", detail: "\(downloadedCount)", icon: "arrow.down.to.line.compact", tint: HeyloColor.accent)
            BigActionButton(title: "Videos", detail: "\(videoCount)", icon: "play.rectangle.fill", tint: HeyloColor.sky)
            BigActionButton(title: "New", detail: "Sync", icon: "sparkles", tint: HeyloColor.sun)
            BigActionButton(title: "Safe", detail: "Parent", icon: "checkmark.shield.fill", tint: HeyloColor.coral)
        }
    }
}

private struct BigActionButton: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .black))
                .frame(width: 70, height: 70)
                .background(tint.opacity(0.16))
                .foregroundStyle(tint)
                .clipShape(Circle())

            Text(detail)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(HeyloColor.ink)
                .lineLimit(1)

            Text(title)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(HeyloColor.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 166)
        .background(HeyloColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(CardStroke(cornerRadius: 26))
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(HeyloColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(subtitle)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(HeyloColor.muted)
                .lineLimit(1)

            Spacer()
        }
    }
}

private struct VideoTile: View {
    @ObservedObject var model: LibraryViewModel
    let video: ManifestVideo

    var body: some View {
        Button {
            Task {
                await model.play(video)
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ThumbnailView(video: video, size: .tile)
                    .frame(height: 188)

                VStack(alignment: .leading, spacing: 10) {
                    Text(video.title)
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(HeyloColor.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Label(video.durationText, systemImage: "play.circle.fill")

                        if video.isOfflineReady {
                            Label("Offline ready", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(video.isOfflineReady ? HeyloColor.accent : HeyloColor.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, minHeight: 308, alignment: .topLeading)
            .background(HeyloColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(video.isOfflineReady ? HeyloColor.accent : HeyloColor.line, lineWidth: video.isOfflineReady ? 4 : 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isPreparingPlayback)
        .accessibilityLabel("\(video.title), \(video.durationText)\(video.isOfflineReady ? ", offline ready" : "")")
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

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [video.displayColor.opacity(0.96), video.displayColor.opacity(0.62), HeyloColor.sky.opacity(0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let thumbnailURL = video.thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        ThumbnailSymbol(video: video, size: size)
                    }
                }
            } else {
                ThumbnailSymbol(video: video, size: size)
            }

            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .black))

                Text(video.durationText)
                    .font(.system(size: 16, weight: .black, design: .rounded))
            }
            .foregroundStyle(HeyloColor.panel)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(HeyloColor.ink.opacity(0.72))
            .clipShape(Capsule())
            .padding(14)

            if video.isOfflineReady {
                OfflineReadyBadge(style: size == .large ? .large : .standard)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(video.isOfflineReady ? HeyloColor.accent : .clear, lineWidth: 5)
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
            .background(HeyloColor.accent)
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
            .foregroundStyle(HeyloColor.panel.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.fill")
                .font(.system(size: 54, weight: .black))
                .foregroundStyle(HeyloColor.accent)

            Text("No videos yet")
                .font(.system(size: 32, weight: .black, design: .rounded))
                .foregroundStyle(HeyloColor.ink)

            Text("Ask a parent to assign videos from the family admin app.")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(HeyloColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .background(HeyloColor.panel)
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
                .tint(HeyloColor.accent)

            Text(message)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(HeyloColor.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ParentErrorView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 76, weight: .black))
                .foregroundStyle(HeyloColor.warning)

            Text("Parent help needed")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(HeyloColor.ink)

            Text(model.errorMessage)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(HeyloColor.muted)
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

                Button {
                    model.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(width: 210, height: 66)
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
        }
        .padding(32)
        .frame(maxWidth: 760)
        .background(HeyloColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(CardStroke(cornerRadius: 30))
    }
}

private struct BrandMark: View {
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle()
                .fill(HeyloColor.accent)

            Image(systemName: "play.fill")
                .font(.system(size: size * 0.36, weight: .black))
                .foregroundStyle(HeyloColor.panel)
                .offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
        .shadow(color: HeyloColor.accent.opacity(0.22), radius: 18, x: 0, y: 10)
    }
}

private struct TrustBadge: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 17, weight: .black, design: .rounded))
            .foregroundStyle(HeyloColor.ink)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(HeyloColor.panel)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(HeyloColor.line, lineWidth: 2))
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
                .foregroundStyle(HeyloColor.panel)
        }
        .frame(width: size, height: size)
    }
}

private struct ParentButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .padding(.horizontal, 22)
                .frame(height: 62)
        }
        .buttonStyle(SecondaryPillButtonStyle())
    }
}

private struct PrimaryButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .padding(.horizontal, 30)
                .frame(height: 72)
        }
        .buttonStyle(PrimaryPillButtonStyle())
    }
}

private struct SecondaryIconButton: View {
    let systemImage: String
    let label: String

    var body: some View {
        Button {
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .black))
                .frame(width: 72, height: 72)
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: .black, design: .rounded))
            .foregroundStyle(HeyloColor.panel)
            .background(configuration.isPressed ? HeyloColor.accent.opacity(0.82) : HeyloColor.accent)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct SecondaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(HeyloColor.ink)
            .background(configuration.isPressed ? HeyloColor.line.opacity(0.65) : HeyloColor.panel)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(HeyloColor.line, lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(HeyloColor.ink)
            .background(configuration.isPressed ? HeyloColor.line.opacity(0.65) : HeyloColor.background)
            .clipShape(Circle())
            .overlay(Circle().stroke(HeyloColor.line, lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct CardStroke: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(HeyloColor.line, lineWidth: 2)
    }
}

private extension View {
    func inputPanel() -> some View {
        self
            .foregroundStyle(HeyloColor.ink)
            .tint(HeyloColor.accent)
            .colorScheme(.light)
            .padding(.horizontal, 18)
            .frame(height: 64)
            .background(HeyloColor.background)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(CardStroke(cornerRadius: 18))
    }
}

private enum HeyloColor {
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
        let palette = [HeyloColor.accent, HeyloColor.coral, HeyloColor.sky, HeyloColor.sun]
        let index = abs(name.hashValue) % palette.count
        return palette[index]
    }
}

private extension ManifestVideo {
    var isOfflineReady: Bool {
        downloadPriority == .required
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
        let palette = [HeyloColor.sky, HeyloColor.accent, HeyloColor.coral, HeyloColor.sun]
        let index = abs(title.hashValue) % palette.count
        return palette[index]
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
