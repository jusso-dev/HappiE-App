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
    let onSelectTracks: (ManifestVideo, Int?, Int) async -> PlaybackItem?
    let onRefreshVideos: () async -> [ManifestVideo]
    /// (videoId, positionSeconds, completed, force, audioIndex, subtitleIndex)
    let onProgress: (UUID, Double, Bool, Bool, Int?, Int) -> Void
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("HappiEAutoplayNext") private var autoplayNext = true
    @AppStorage("HappiELoopVideo") private var loopEnabled = false
    @StateObject private var controller: PlayerController
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
    @State private var isShowingTrackGate = false
    @State private var isShowingTrackPicker = false

    init(
        item: PlaybackItem,
        videos: [ManifestVideo],
        onSelectVideo: @escaping (ManifestVideo) async -> PlaybackItem?,
        onSelectTracks: @escaping (ManifestVideo, Int?, Int) async -> PlaybackItem?,
        onRefreshVideos: @escaping () async -> [ManifestVideo],
        onProgress: @escaping (UUID, Double, Bool, Bool, Int?, Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.videos = videos
        self.onSelectVideo = onSelectVideo
        self.onSelectTracks = onSelectTracks
        self.onRefreshVideos = onRefreshVideos
        self.onProgress = onProgress
        self.onClose = onClose
        _controller = StateObject(wrappedValue: PlayerController(url: item.url))
        _currentItem = State(initialValue: item)
        _playerVideos = State(initialValue: videos)
    }

    private var suggestedVideos: [ManifestVideo] {
        playerVideos.filter { $0.id != currentItem.video.id }
    }

    private var nextVideo: ManifestVideo? {
        suggestedVideos.first
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
                    loopEnabled: $loopEnabled,
                    autoplayNext: $autoplayNext,
                    onClose: close,
                    onOpenTracks: { isShowingTrackGate = true },
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
            reportProgress(position: controller.currentTime, force: true)
            controller.pause()
        }
        .onChange(of: controller.currentTime) {
            guard controller.isPlaying else { return }
            reportProgress(position: controller.currentTime)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            guard notification.object as AnyObject? === controller.player.currentItem else { return }
            handleVideoEnded()
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
        .sheet(isPresented: $isShowingTrackGate) {
            ParentGateView {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    isShowingTrackPicker = true
                }
            }
        }
        .sheet(isPresented: $isShowingTrackPicker) {
            TrackPickerView(
                audioTracks: controller.audioTracks.isEmpty ? currentItem.audioTracks : controller.audioTracks,
                subtitleTracks: controller.subtitleTracks.isEmpty ? currentItem.subtitleTracks : controller.subtitleTracks,
                selectedAudioIndex: currentItem.selectedAudioIndex,
                selectedSubtitleIndex: currentItem.selectedSubtitleIndex,
                onSelect: selectTrack(type:index:)
            )
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .accessibilityLabel("Playing \(currentItem.video.displayTitle)")
    }

    private func reportProgress(position: Double, completed: Bool = false, force: Bool = false) {
        onProgress(currentItem.video.id, position, completed, force, currentItem.selectedAudioIndex, currentItem.selectedSubtitleIndex)
    }

    private func selectTrack(type: MediaTrackType, index: Int) {
        let previousTime = controller.currentTime
        let displayedTracks = type == .audio
            ? (controller.audioTracks.isEmpty ? currentItem.audioTracks : controller.audioTracks)
            : (controller.subtitleTracks.isEmpty ? currentItem.subtitleTracks : controller.subtitleTracks)
        let requiresRebuild = displayedTracks.first(where: { $0.index == index })?.requiresRebuild == true
        if !requiresRebuild, controller.selectTrack(type: type, streamIndex: index) {
            if type == .audio { currentItem.selectedAudioIndex = index }
            else { currentItem.selectedSubtitleIndex = index }
            reportProgress(position: previousTime, force: true)
            return
        }

        let audioIndex = type == .audio ? index : currentItem.selectedAudioIndex
        let subtitleIndex = type == .subtitle ? index : currentItem.selectedSubtitleIndex
        guard videoSwitchTask == nil else { return }
        videoSwitchTask = Task {
            let rebuilt = await onSelectTracks(currentItem.video, audioIndex, subtitleIndex)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if var rebuilt {
                    rebuilt.resumeAt = previousTime
                    currentItem = rebuilt
                    controller.replaceCurrentItem(with: rebuilt.url, startAt: previousTime)
                }
                videoSwitchTask = nil
            }
        }
    }

    private func handleVideoEnded() {
        reportProgress(position: controller.duration, completed: true)

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
        reportProgress(position: controller.currentTime, force: true)
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
            guard let refreshedItem = await onSelectTracks(video, currentItem.selectedAudioIndex, currentItem.selectedSubtitleIndex) else {
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

private struct TrackPickerView: View {
    let audioTracks: [MediaTrack]
    let subtitleTracks: [MediaTrack]
    let selectedAudioIndex: Int?
    let selectedSubtitleIndex: Int
    let onSelect: (MediaTrackType, Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if audioTracks.count > 1 {
                    Section("Audio") {
                        trackButton(title: "Off", type: .audio, index: -1, selected: selectedAudioIndex == -1)
                        ForEach(audioTracks) { track in
                            trackButton(title: track.displayTitle, type: .audio, index: track.index, selected: selectedAudioIndex == track.index)
                        }
                    }
                }
                if !subtitleTracks.isEmpty {
                    Section("Subtitles") {
                        trackButton(title: "Off", type: .subtitle, index: -1, selected: selectedSubtitleIndex == -1)
                        ForEach(subtitleTracks) { track in
                            trackButton(title: track.displayTitle, type: .subtitle, index: track.index, selected: selectedSubtitleIndex == track.index)
                        }
                    }
                }
            }
            .navigationTitle("Audio & Subtitles")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func trackButton(title: String, type: MediaTrackType, index: Int, selected: Bool) -> some View {
        Button {
            onSelect(type, index)
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PlayerChrome: View {
    let item: PlaybackItem
    let videos: [ManifestVideo]
    @ObservedObject var controller: PlayerController
    @Binding var loopEnabled: Bool
    @Binding var autoplayNext: Bool
    let onClose: () -> Void
    let onOpenTracks: () -> Void
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
                    hasTrackChoices: controller.audioTracks.count > 1 || !controller.subtitleTracks.isEmpty || item.audioTracks.count > 1 || !item.subtitleTracks.isEmpty,
                    onOpenTracks: onOpenTracks,
                    onClose: onClose
                )

                Spacer()

                VStack(spacing: 20) {
                    KidPlaybackControls(
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
    @ObservedObject var controller: PlayerController
    @Binding var autoplayNext: Bool
    let hasTrackChoices: Bool
    let onOpenTracks: () -> Void
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
                .onLongPressGesture(minimumDuration: 0.8) {
                    if hasTrackChoices { onOpenTracks() }
                }
                .accessibilityHint(hasTrackChoices ? "Long press for audio and subtitles" : "")

            Spacer()

            AutoplayToggle(isOn: $autoplayNext)

            AirPlayRouteButton()
                .frame(width: 56, height: 56)

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

@MainActor
final class PlayerController: ObservableObject {
    let player: AVPlayer

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    @Published var volume: Double = 1
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []

    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var timeObserver: Any?
    private var volumeObservation: NSKeyValueObservation?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.volume = 1
        player.isMuted = false
        observeSystemVolume()
        addTimeObserver()
        refreshMediaOptions()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        volumeObservation?.invalidate()
    }

    var currentTimeText: String {
        Self.timeText(currentTime)
    }

    var durationText: String {
        Self.timeText(duration)
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
        refreshMediaOptions()
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

    @discardableResult
    func selectTrack(type: MediaTrackType, streamIndex: Int) -> Bool {
        guard let item = player.currentItem else { return false }
        let group = type == .audio ? audioGroup : subtitleGroup
        guard let group else { return false }
        if streamIndex == -1 {
            item.select(nil, in: group)
            return true
        }
        let tracks = type == .audio ? audioTracks : subtitleTracks
        let map = MediaTrackIndexMap(streamIndexes: tracks.map(\.index))
        guard let offset = map.optionOffset(forStreamIndex: streamIndex), group.options.indices.contains(offset) else { return false }
        item.select(group.options[offset], in: group)
        return true
    }

    private func refreshMediaOptions() {
        audioTracks = []
        subtitleTracks = []
        audioGroup = nil
        subtitleGroup = nil
        guard let item = player.currentItem else { return }
        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard item === player.currentItem else { return }
            audioGroup = audio
            subtitleGroup = subtitles
            audioTracks = Self.tracks(from: audio)
            subtitleTracks = Self.tracks(from: subtitles)
        }
    }

    private static func tracks(from group: AVMediaSelectionGroup?) -> [MediaTrack] {
        (group?.options ?? []).enumerated().map { offset, option in
            MediaTrack(index: offset, title: option.displayName, language: option.extendedLanguageTag, requiresRebuild: false)
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
        ManifestVideo.timestampText(seconds: max(0, Int(seconds.rounded()))).isEmpty
            ? "0:00"
            : ManifestVideo.timestampText(seconds: max(0, Int(seconds.rounded())))
    }
}

private struct KidPlaybackControls: View {
    @ObservedObject var controller: PlayerController
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
            }
            .frame(maxHeight: .infinity)
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
