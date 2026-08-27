//
//  PlayerView.swift
//  HappiE
//
//  Created for HappiE.
//

import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI
import UIKit

struct VideoPlayerScreen: View {
    let item: PlaybackItem
    let videos: [ManifestVideo]
    let onSelectVideo: (ManifestVideo) async -> PlaybackItem?
    let onRefreshVideos: () async -> [ManifestVideo]
    /// (videoId, positionSeconds, completed, force)
    let onProgress: (UUID, Double, Bool, Bool) -> Void
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("HappiEAutoplayNext") private var autoplayNext = true
    @AppStorage("HappiELoopVideo") private var loopEnabled = false
    @AppStorage(PlaybackEngine.defaultsKey) private var compatibilityPlayer = false
    @StateObject private var controller: MediaPlayerManager
    @State private var currentItem: PlaybackItem
    @State private var playerVideos: [ManifestVideo]
    @State private var controlsVisible = true
    @State private var upNextVideo: ManifestVideo?
    @State private var upNextTask: Task<Void, Never>?
    @State private var showsReplay = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var refreshVideosTask: Task<Void, Never>?
    @State private var playerRefreshTask: Task<Void, Never>?
    @State private var playbackRecoveryTask: Task<Void, Never>?
    @State private var videoSwitchTask: Task<Void, Never>?
    @State private var playbackRequestID = UUID()
    @State private var isSwitchingVideo = false
    @State private var playbackRecoveryAttempts = 0
    @State private var playbackFailureMessage: String?

    init(
        item: PlaybackItem,
        videos: [ManifestVideo],
        onSelectVideo: @escaping (ManifestVideo) async -> PlaybackItem?,
        onRefreshVideos: @escaping () async -> [ManifestVideo],
        onProgress: @escaping (UUID, Double, Bool, Bool) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.videos = videos
        self.onSelectVideo = onSelectVideo
        self.onRefreshVideos = onRefreshVideos
        self.onProgress = onProgress
        self.onClose = onClose
        _controller = StateObject(wrappedValue: MediaPlayerManager(url: item.url))
        _currentItem = State(initialValue: item)
        _playerVideos = State(initialValue: videos)
    }

    private var suggestedVideos: [ManifestVideo] {
        playerVideos.filter { $0.id != currentItem.video.id }
    }

    private var nextVideo: ManifestVideo? {
        VideoQueue.next(after: currentItem.video, in: playerVideos)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            playerSurface

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
                    loopEnabled: $loopEnabled,
                    autoplayNext: $autoplayNext,
                    onClose: close,
                    onNext: playNextVideo,
                    onSelect: selectVideo(_:)
                )
                .transition(.opacity)

                CenterVideoTapTarget(onHideControls: hideControls)
                    .zIndex(4)
            }

            if showsReplay {
                ReplayOverlay {
                    replayCurrentVideo()
                }
                .zIndex(5)
            }

            if let upNextVideo {
                UpNextOverlay(
                    video: upNextVideo,
                    onPlayNow: {
                        cancelUpNext()
                        selectVideo(upNextVideo)
                    },
                    onCancel: {
                        cancelUpNext()
                        showsReplay = true
                        controlsVisible = true
                    }
                )
                .zIndex(6)
            }

            if let playbackFailureMessage {
                PlaybackFailureOverlay(message: playbackFailureMessage, onClose: close)
                    .zIndex(7)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if currentItem.resumeAt > 0 {
                controller.replaceCurrentItem(with: currentItem.url, startAt: currentItem.resumeAt)
            } else {
                controller.play()
            }
            scheduleControlsHide()
            refreshPlayerVideos()
            scheduleVideoRefresh()
        }
        .onDisappear {
            cancelPlayerTasks()
            UIApplication.shared.isIdleTimerDisabled = false
            onProgress(currentItem.video.id, controller.currentTime, false, true)
            controller.pause()
        }
        .onChange(of: controller.currentTime) {
            guard controller.isPlaying else { return }
            onProgress(currentItem.video.id, controller.currentTime, false, false)
        }
        .onChange(of: controller.endedEvent) {
            handleVideoEnded()
        }
        .onChange(of: controller.stalledEvent) {
            recoverPlayback()
        }
        .onChange(of: compatibilityPlayer) {
            controller.setEngine(compatibilityPlayer ? .compatibility : .apple)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .accessibilityLabel("Playing \(currentItem.video.displayTitle)")
    }

    @ViewBuilder
    private var playerSurface: some View {
#if canImport(MobileVLCKit)
        if controller.usesCompatibilityPlayer {
            VLCVideoSurface(manager: controller).ignoresSafeArea()
        } else {
            NativeVideoPlayer(controller: controller).ignoresSafeArea()
        }
#else
        NativeVideoPlayer(controller: controller).ignoresSafeArea()
#endif
    }

    private func handleVideoEnded() {
        onProgress(currentItem.video.id, controller.duration, true, false)

        if loopEnabled {
            controller.seek(to: 0)
            controller.play()
            return
        }

        if autoplayNext, let nextVideo {
            controller.pause()
            startUpNextCountdown(for: nextVideo)
            return
        }

        controller.pause()
        showsReplay = true
        controlsVisible = true
    }

    private func startUpNextCountdown(for video: ManifestVideo) {
        upNextTask?.cancel()
        upNextVideo = video
        upNextTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard upNextVideo != nil else { return }
                cancelUpNext()
                selectVideo(video)
            }
        }
    }

    private func cancelUpNext() {
        upNextTask?.cancel()
        upNextTask = nil
        upNextVideo = nil
    }

    private func replayCurrentVideo() {
        showsReplay = false
        controller.seek(to: 0)
        controller.play()
        scheduleControlsHide()
    }

    private func close() {
        cancelPlayerTasks()
        onProgress(currentItem.video.id, controller.currentTime, false, true)
        controller.pause()
        onClose()
        dismiss()
    }

    private func selectVideo(_ video: ManifestVideo) {
        guard !isSwitchingVideo else { return }
        isSwitchingVideo = true
        showsReplay = false
        cancelUpNext()
        showControls()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        playbackRecoveryAttempts = 0
        playbackFailureMessage = nil

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
        guard let nextVideo else { return }
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

    private func recoverPlayback() {
        guard !isSwitchingVideo, playbackRecoveryTask == nil, videoSwitchTask == nil else { return }
        guard playbackRecoveryAttempts < 1 else {
            controller.pause()
            playbackFailureMessage = "This video can’t play with AVPlayer. Ask a parent to enable a compatibility player."
            return
        }
        playbackRecoveryAttempts += 1
        let resumeAt = controller.currentTime
        let video = currentItem.video
        let requestID = UUID()
        playbackRequestID = requestID
        playbackRecoveryTask = Task {
            guard let refreshedItem = await onSelectVideo(video) else {
                await MainActor.run {
                    if playbackRequestID == requestID {
                        playbackRecoveryTask = nil
                        controller.pause()
                        playbackFailureMessage = "This video can’t play with AVPlayer. Ask a parent to enable a compatibility player."
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
        upNextTask?.cancel()
        hideControlsTask = nil
        refreshVideosTask = nil
        playerRefreshTask = nil
        playbackRecoveryTask = nil
        videoSwitchTask = nil
        upNextTask = nil
        upNextVideo = nil
    }
}

private struct PlaybackFailureOverlay: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 58, weight: .bold))

            Text("Can’t play this video")
                .font(.system(size: 24, weight: .heavy, design: .rounded))

            Text(message)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Close player", action: onClose)
                .buttonStyle(PrimaryButtonStyle())
        }
        .foregroundStyle(.white)
        .padding(30)
        .background(.black.opacity(0.86))
        .clipShape(.rect(cornerRadius: 26))
        .padding(30)
        .accessibilityElement(children: .contain)
    }
}

private struct ReplayOverlay: View {
    let onReplay: () -> Void

    var body: some View {
        Button(action: onReplay) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 84, weight: .bold))

                Text("Watch again")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(28)
            .background(.black.opacity(0.55))
            .clipShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch again")
    }
}

private struct UpNextOverlay: View {
    let video: ManifestVideo
    let onPlayNow: () -> Void
    let onCancel: () -> Void

    @State private var countdownProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: 18) {
            Text("Up next")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

            VideoThumbnail(video: video, progress: nil)
                .frame(width: 320, height: 180)

            Text(video.displayTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 14) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .padding(.horizontal, 26)
                        .frame(height: 54)
                }
                .buttonStyle(QuietButtonStyle())

                Button(action: onPlayNow) {
                    ZStack(alignment: .leading) {
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(.white.opacity(0.25))
                                .frame(width: proxy.size.width * countdownProgress)
                        }

                        Label("Play now", systemImage: "play.fill")
                            .padding(.horizontal, 26)
                            .frame(height: 54)
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(30)
        .background(.black.opacity(0.78))
        .clipShape(.rect(cornerRadius: 28))
        .onAppear {
            withAnimation(.linear(duration: 5)) {
                countdownProgress = 1
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up next: \(video.displayTitle). Playing in five seconds.")
    }
}

private struct PlayerChrome: View {
    let item: PlaybackItem
    let videos: [ManifestVideo]
    @ObservedObject var controller: MediaPlayerManager
    @Binding var loopEnabled: Bool
    @Binding var autoplayNext: Bool
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
                    controller: controller,
                    autoplayNext: $autoplayNext,
                    onClose: onClose
                )

                Spacer()

                VStack(spacing: 20) {
                    KidPlaybackControls(
                        video: item.video,
                        controller: controller,
                        hasNextVideo: !videos.isEmpty,
                        loopEnabled: $loopEnabled,
                        onNext: onNext
                    )

                    if !videos.isEmpty {
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
    @ObservedObject var controller: MediaPlayerManager
    @Binding var autoplayNext: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 24, weight: .heavy))

                    Text("Close")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 64)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .accessibilityLabel("Close the video")

            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer()

            AutoplayToggle(isOn: $autoplayNext)

            AirPlayRouteButton()
                .frame(width: 56, height: 56)

            if controller.isPictureInPictureSupported {
                Button {
                    controller.togglePictureInPicture()
                } label: {
                    Image(systemName: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .accessibilityLabel(
                    controller.isPictureInPictureActive
                        ? "Stop Picture in Picture"
                        : "Start Picture in Picture"
                )
            }

            PlayerVolumeControl(controller: controller)
                .frame(width: 240)
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }
}

/// YouTube-style autoplay switch: a small play glyph that slides
/// between "on" and "off" positions.
private struct AutoplayToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Text("Autoplay")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? .white : .white.opacity(0.35))
                        .frame(width: 44, height: 22)

                    Image(systemName: isOn ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(isOn ? Color.black : Color.white)
                        .frame(width: 18, height: 18)
                        .background(isOn ? Color.white : Color.black.opacity(0.6))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 1))
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.18), value: isOn)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.black.opacity(0.45))
            .clipShape(Capsule())
        }
        .accessibilityLabel("Autoplay next video")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
                .frame(width: 560, height: 300)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide video controls")
    }
}

private struct SuggestedVideoStrip: View {
    let videos: [ManifestVideo]
    let onSelect: (ManifestVideo) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(videos.prefix(8)) { video in
                    Button {
                        onSelect(video)
                    } label: {
                        VideoThumbnail(video: video, progress: nil)
                            .frame(width: 300, height: 168)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(video.displayTitle)")
                }
            }
        }
    }
}

/// AVKit's player-layer PiP API keeps HappiE's custom kid controls while
/// enabling both the top-bar PiP action and automatic PiP on app background.
private struct NativeVideoPlayer: UIViewRepresentable {
    @ObservedObject var controller: MediaPlayerManager

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = controller.player
        view.playerLayer.videoGravity = .resizeAspect
        controller.player.allowsExternalPlayback = true
        controller.player.usesExternalPlaybackWhileExternalScreenIsActive = true
        controller.configurePictureInPicture(with: view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== controller.player {
            view.playerLayer.player = controller.player
        }
        controller.player.allowsExternalPlayback = true
        controller.player.usesExternalPlaybackWhileExternalScreenIsActive = true
    }
}

private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

private struct KidPlaybackControls: View {
    let video: ManifestVideo
    @ObservedObject var controller: MediaPlayerManager
    let hasNextVideo: Bool
    @Binding var loopEnabled: Bool
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 52, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
            }
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            Button {
                loopEnabled.toggle()
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(loopEnabled ? .black : .white)
                    .frame(width: 58, height: 58)
                    .background(loopEnabled ? .white : .white.opacity(0.14))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Repeat this video")
            .accessibilityValue(loopEnabled ? "On" : "Off")
            .accessibilityAddTraits(loopEnabled ? .isSelected : [])

            VStack(spacing: 8) {
                BigTimeline(
                    video: video,
                    currentTime: controller.currentTime,
                    duration: controller.duration,
                    onSeek: { seconds in
                        controller.seek(to: seconds)
                    }
                )

                HStack(spacing: 20) {
                    Text(controller.currentTimeText)
                    Spacer()
                    Text(controller.durationText)
                }
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()

                if let chapters = video.chapters, !chapters.isEmpty {
                    ChapterStrip(chapters: chapters) { chapter in
                        controller.seek(to: Double(chapter.startSeconds))
                        controller.play()
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                onNext()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 74, height: 74)
            }
            .disabled(!hasNextVideo)
            .opacity(hasNextVideo ? 1 : 0.38)
            .accessibilityLabel("Play next video")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BigTimeline: View {
    let video: ManifestVideo
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var dragTime: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let displayedTime = dragTime ?? currentTime
            let progress = duration > 0 ? min(max(displayedTime / duration, 0), 1) : 0
            let knobX = progress * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(height: 8)

                Capsule()
                    .fill(HTheme.accent)
                    .frame(width: max(8, knobX), height: 8)

                Circle()
                    .fill(HTheme.accent)
                    .frame(width: 38, height: 38)
                    .overlay(Circle().stroke(.white, lineWidth: 6))
                    .shadow(color: .black.opacity(0.26), radius: 6, x: 0, y: 2)
                    .offset(x: min(max(knobX - 19, 0), max(width - 38, 0)))

                if let dragTime {
                    ScrubPreview(video: video, seconds: dragTime)
                        .frame(width: 176)
                        .offset(
                            x: min(max(knobX - 88, 0), max(width - 176, 0)),
                            y: -112
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let percent = min(max(value.location.x / width, 0), 1)
                        dragTime = percent * duration
                    }
                    .onEnded { value in
                        let percent = min(max(value.location.x / width, 0), 1)
                        let seconds = percent * duration
                        dragTime = nil
                        onSeek(seconds)
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

private struct ScrubPreview: View {
    let video: ManifestVideo
    let seconds: Double

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let url = video.previewImageURL(at: seconds) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            VideoThumbnail(video: video, progress: nil)
                        }
                    }
                } else {
                    VideoThumbnail(video: video, progress: nil)
                }
            }
            .frame(width: 160, height: 90)
            .clipped()
            .clipShape(.rect(cornerRadius: 10))

            Text(ManifestVideo.timestampText(seconds: max(0, Int(seconds.rounded()))))
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(8)
        .background(.black.opacity(0.88))
        .clipShape(.rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .accessibilityHidden(true)
    }
}

private struct ChapterStrip: View {
    let chapters: [VideoChapter]
    let onSelect: (VideoChapter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chapters.sorted(by: { $0.startSeconds < $1.startSeconds })) { chapter in
                    Button {
                        onSelect(chapter)
                    } label: {
                        Text(chapter.title)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(.white.opacity(0.16))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Play chapter \(chapter.title)")
                    .accessibilityValue(ManifestVideo.timestampText(seconds: chapter.startSeconds))
                }
            }
        }
#if os(tvOS)
        .focusSection()
#endif
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
    @ObservedObject var controller: MediaPlayerManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)

            SystemVolumeSlider()
                .frame(height: 34)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(.black.opacity(0.45))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Video volume")
    }
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.backgroundColor = .clear
        style(volumeView)
        return volumeView
    }

    func updateUIView(_ volumeView: MPVolumeView, context: Context) {
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
