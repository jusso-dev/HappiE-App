import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

enum PlaybackEngine: String {
    case apple
    case compatibility

    static let defaultsKey = "HappiECompatibilityPlayer"
    static var preferred: PlaybackEngine {
#if canImport(MobileVLCKit)
        UserDefaults.standard.bool(forKey: defaultsKey) ? .compatibility : .apple
#else
        .apple
#endif
    }
}

@MainActor
protocol MediaPlayerSession: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var volume: Double { get }
    var isPlaying: Bool { get }
    func play()
    func pause()
    func replaceCurrentItem(with url: URL, startAt seconds: Double)
    func seek(to seconds: Double)
    func jump(by seconds: Double)
}

/// One observable playback session. Engine-specific callbacks are normalized
/// here so kid-facing playback policy remains independent of AVPlayer/VLC.
@MainActor
final class MediaPlayerManager: NSObject, ObservableObject, MediaPlayerSession, AVPictureInPictureControllerDelegate {
    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 1
    @Published private(set) var volume: Double = 1
    @Published private(set) var endedEvent = UUID()
    @Published private(set) var stalledEvent = UUID()
    @Published private(set) var engine: PlaybackEngine
    @Published private(set) var isPictureInPictureActive = false

    private var currentURL: URL
    private var timeObserver: Any?
    private var volumeObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var pictureInPictureController: AVPictureInPictureController?

#if canImport(MobileVLCKit)
    fileprivate let vlcPlayer = VLCMediaPlayer()
    let vlcView = UIView(frame: .zero)
#endif

    init(url: URL, engine: PlaybackEngine = .preferred) {
        currentURL = url
#if canImport(MobileVLCKit)
        self.engine = engine
#else
        self.engine = .apple
#endif
        super.init()
        player.volume = 1
        observeSystemVolume()
        addAVTimeObserver()
        observeAVEvents()
#if canImport(MobileVLCKit)
        vlcView.backgroundColor = .black
        vlcPlayer.drawable = vlcView
        vlcPlayer.delegate = self
#endif
        load(url: url, startAt: 0, autoplay: false)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        volumeObservation?.invalidate()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var currentTimeText: String { Self.timeText(currentTime) }
    var durationText: String { Self.timeText(duration) }
    var usesCompatibilityPlayer: Bool { engine == .compatibility }
    var isPictureInPictureSupported: Bool {
        !usesCompatibilityPlayer && AVPictureInPictureController.isPictureInPictureSupported()
    }

    func configurePictureInPicture(with playerLayer: AVPlayerLayer) {
        guard pictureInPictureController == nil, isPictureInPictureSupported else { return }
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPictureController = controller
    }

    func togglePictureInPicture() {
        guard let pictureInPictureController else { return }
        if pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
        } else if pictureInPictureController.isPictureInPicturePossible {
            pictureInPictureController.startPictureInPicture()
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.isPictureInPictureActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.isPictureInPictureActive = false
        }
    }

    func setEngine(_ requested: PlaybackEngine) {
#if canImport(MobileVLCKit)
        let availableEngine = requested
#else
        let availableEngine = PlaybackEngine.apple
#endif
        guard engine != availableEngine else { return }
        let resumeAt = currentTime
        let shouldResume = isPlaying
        pause()
        engine = availableEngine
        load(url: currentURL, startAt: resumeAt, autoplay: shouldResume)
    }

    func play() {
        isPlaying = true
        if usesCompatibilityPlayer {
#if canImport(MobileVLCKit)
            vlcPlayer.play()
#endif
        } else {
            player.isMuted = false
            player.volume = 1
            // play() resets AVPlayer to 1x. Apply the grown-up's stored
            // preference explicitly so resumes, seeks, and item changes keep it.
            player.playImmediately(atRate: Self.storedPlaybackRate)
        }
    }

    private static var storedPlaybackRate: Float {
        let value = UserDefaults.standard.object(forKey: "HappiEPlaybackRate") as? Double ?? 1
        return Float([0.75, 1, 1.25, 1.5].contains(value) ? value : 1)
    }

    func pause() {
        if usesCompatibilityPlayer {
#if canImport(MobileVLCKit)
            vlcPlayer.pause()
#endif
        } else {
            player.pause()
        }
        isPlaying = false
    }

    func replaceCurrentItem(with url: URL, startAt seconds: Double = 0) {
        load(url: url, startAt: seconds, autoplay: true)
    }

    func togglePlayback() { isPlaying ? pause() : play() }
    func jump(by seconds: Double) { seek(to: currentTime + seconds) }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        if usesCompatibilityPlayer {
#if canImport(MobileVLCKit)
            vlcPlayer.time = VLCTime(int: Int32(clamped * 1_000))
#endif
        } else {
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func load(url: URL, startAt seconds: Double, autoplay: Bool) {
        currentURL = url
        currentTime = max(0, seconds)
        duration = 1
        isPlaying = false
        if usesCompatibilityPlayer {
#if canImport(MobileVLCKit)
            player.pause()
            player.replaceCurrentItem(with: nil)
            vlcPlayer.media = VLCMedia(url: url)
            vlcPlayer.play()
            if seconds > 0 { vlcPlayer.time = VLCTime(int: Int32(seconds * 1_000)) }
            if !autoplay { vlcPlayer.pause() }
            isPlaying = autoplay
#endif
        } else {
#if canImport(MobileVLCKit)
            vlcPlayer.stop()
#endif
            player.pause()
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            guard autoplay else { return }
            if seconds > 0 {
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.play() }
                }
            } else { play() }
        }
    }

    private func addAVTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !usesCompatibilityPlayer else { return }
                currentTime = time.seconds.isFinite ? time.seconds : 0
                if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    duration = seconds
                }
            }
        }
    }

    private func observeAVEvents() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                 object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, !usesCompatibilityPlayer,
                      note.object as AnyObject? === player.currentItem else { return }
                isPlaying = false
                endedEvent = UUID()
            }
        })
        for name in [Notification.Name.AVPlayerItemPlaybackStalled,
                     .AVPlayerItemFailedToPlayToEndTime, .AVPlayerItemNewErrorLogEntry] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self, !usesCompatibilityPlayer,
                          note.object as AnyObject? === player.currentItem else { return }
                    stalledEvent = UUID()
                }
            })
        }
    }

    private func observeSystemVolume() {
        let session = AVAudioSession.sharedInstance()
        volume = Double(session.outputVolume)
        volumeObservation = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
            Task { @MainActor [weak self] in self?.volume = Double(session.outputVolume) }
        }
    }

    private static func timeText(_ seconds: Double) -> String {
        let text = ManifestVideo.timestampText(seconds: max(0, Int(seconds.rounded())))
        return text.isEmpty ? "0:00" : text
    }
}

#if canImport(MobileVLCKit)
extension MediaPlayerManager: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, usesCompatibilityPlayer else { return }
            currentTime = Double(vlcPlayer.time.intValue) / 1_000
            let milliseconds = vlcPlayer.media?.length.intValue ?? 0
            if milliseconds > 0 { duration = Double(milliseconds) / 1_000 }
        }
    }

    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, usesCompatibilityPlayer else { return }
            switch vlcPlayer.state {
            case .ended:
                isPlaying = false
                endedEvent = UUID()
            case .error:
                isPlaying = false
                stalledEvent = UUID()
            case .playing: isPlaying = true
            case .paused, .stopped: isPlaying = false
            default: break
            }
        }
    }
}

struct VLCVideoSurface: UIViewRepresentable {
    @ObservedObject var manager: MediaPlayerManager
    func makeUIView(context: Context) -> UIView { manager.vlcView }
    func updateUIView(_ uiView: UIView, context: Context) { manager.vlcPlayer.drawable = uiView }
}
#endif
