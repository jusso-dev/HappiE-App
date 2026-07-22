//
//  AppModel.swift
//  HappiE
//
//  Created for HappiE.
//

import AVFoundation
import Foundation
import Network
import Observation
import SwiftUI

struct PlaybackItem: Identifiable {
    let id = UUID()
    let video: ManifestVideo
    let url: URL
    var resumeAt: Double = 0
}

@MainActor
@Observable
final class AppModel {
    enum Phase {
        case welcome
        case loading
        case selectingChild
        case ready
        case failed
    }

    var phase: Phase = .welcome
    var children: [ChildProfile] = []
    var selectedChild: ChildProfile?
    var videos: [ManifestVideo] = []
    var errorMessage = ""
    var loadingMessage = "Loading your videos"
    var lastSyncedText = "Not synced yet"
    var playbackItem: PlaybackItem?
    var playbackErrorMessage = ""
    var isPreparingPlayback = false
    var searchText = ""
    /// True when showing the locally cached library because the server is unreachable.
    var isOfflineMode = false
    /// Live network path status from NWPathMonitor.
    private(set) var isNetworkAvailable = true
    private(set) var apiBaseURL: URL

    let history: WatchHistoryStore
    let offline = OfflineStore()

    private let apiConfigurationStore: APIConfigurationStore
    private let session: URLSession
    private let defaults: UserDefaults
    private var deviceId: UUID?
    private var hasStarted = false
    private var lastReportedProgress: [UUID: Double] = [:]
    private let pathMonitor = NWPathMonitor()
    private var offlineRetryTask: Task<Void, Never>?

    private static let selectedChildKey = "HappiESelectedChildId"
    private static let autoDownloadKey = "HappiEAutoDownloadRequired"

    init(
        apiConfigurationStore: APIConfigurationStore? = nil,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        let apiConfigurationStore = apiConfigurationStore ?? APIConfigurationStore()
        self.apiConfigurationStore = apiConfigurationStore
        self.session = session
        self.defaults = defaults
        self.history = WatchHistoryStore(session: session)
        self.apiBaseURL = apiConfigurationStore.loadBaseURL()
        startNetworkMonitoring()
    }

    /// Recovers as soon as connectivity returns, instead of waiting for the
    /// child to find and press a retry button.
    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                isNetworkAvailable = satisfied
                if satisfied {
                    await recoverFromOfflineIfNeeded()
                } else {
                    markOffline()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "au.com.HappiE.network-monitor"))
    }

    /// Called when the app returns to the foreground — the network may have
    /// changed (airplane mode toggled) while we were suspended.
    func handleBecameActive() {
        if !isNetworkAvailable {
            markOffline()
        } else if isOfflineMode {
            Task {
                await recoverFromOfflineIfNeeded()
            }
        } else if phase == .ready {
            // Refresh quietly on return — also detects a server that died
            // while we were away (the quiet failure marks us offline).
            Task {
                await sync(showLoading: false, quiet: true)
            }
        }
    }

    /// Flips into offline mode without any network calls or phase flashes.
    /// The already-loaded library stays on screen when we have one.
    private func markOffline() {
        guard !isOfflineMode else { return }
        if phase == .ready, !videos.isEmpty {
            isOfflineMode = true
            lastSyncedText = "Offline — showing saved videos"
            startOfflineRetryLoop()
        } else if phase == .ready || phase == .failed {
            _ = enterOfflineModeIfPossible(preferredChildId: selectedChild?.id)
        }
    }

    /// Retries quietly every few seconds while offline — this also catches
    /// the server coming back when the network itself never dropped.
    private func startOfflineRetryLoop() {
        guard offlineRetryTask == nil else { return }
        offlineRetryTask = Task { [weak self] in
            defer { self?.offlineRetryTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, isOfflineMode else { return }
                await recoverFromOfflineIfNeeded()
            }
        }
    }

    private func recoverFromOfflineIfNeeded() async {
        guard isOfflineMode, isNetworkAvailable else { return }
        if selectedChild != nil {
            await sync(showLoading: false, quiet: true)
        } else if let refreshed = try? await api.children(), !refreshed.isEmpty {
            await loadChildren()
        }
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

    var filteredVideos: [ManifestVideo] {
        videos.filter { $0.matches(searchText: searchText) }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// History entries with meaningful progress whose videos can still play.
    var continueWatching: [WatchHistoryEntry] {
        history.continueWatching
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        phase = .welcome
        try? await Task.sleep(for: .seconds(1.4))
        await loadChildren()
    }

    func loadChildren() async {
        // Airplane mode at launch: go straight to the saved library instead
        // of waiting on a doomed request.
        if !isNetworkAvailable, enterOfflineModeIfPossible() {
            return
        }

        loadingMessage = "Finding profiles"
        phase = .loading

        do {
            children = try await api.children()
            guard !children.isEmpty else {
                errorMessage = "No profiles are set up yet. Create one in the family admin app first."
                phase = .failed
                return
            }

            let rememberedId = defaults.string(forKey: Self.selectedChildKey).flatMap(UUID.init(uuidString:))
            if let remembered = children.first(where: { $0.id == rememberedId }) {
                await select(remembered)
            } else if children.count == 1, let onlyChild = children.first {
                await select(onlyChild)
            } else {
                phase = .selectingChild
            }
        } catch {
            if enterOfflineModeIfPossible() {
                return
            }
            fail(error)
        }
    }

    func select(_ child: ChildProfile) async {
        selectedChild = child
        defaults.set(child.id.uuidString, forKey: Self.selectedChildKey)
        loadingMessage = "Getting \(child.name)'s videos"
        phase = .loading

        do {
            let deviceId = try await ensureDevice(for: child)
            let manifest = try await syncManifest(deviceId: deviceId, child: child)
            apply(manifest, for: child)
            lastSyncedText = "Synced just now"
            phase = .ready
        } catch {
            if enterOfflineModeIfPossible(preferredChildId: child.id) {
                return
            }
            fail(error)
        }
    }

    func showProfilePicker() {
        playbackItem = nil
        phase = .selectingChild
    }

    func sync() async {
        await sync(showLoading: true)
    }

    func refreshLibrarySilently() async {
        await sync(showLoading: false)
    }

    private func sync(showLoading: Bool, quiet: Bool = false) async {
        guard let child = selectedChild else { return }
        guard let deviceId else {
            if showLoading {
                await select(child)
            } else {
                // Background path: never route through select(), which flips
                // the whole screen into the loading phase.
                do {
                    let freshId = try await ensureDevice(for: child)
                    let manifest = try await syncManifest(deviceId: freshId, child: child)
                    apply(manifest, for: child)
                    lastSyncedText = "Synced just now"
                } catch {
                    if !quiet {
                        playbackErrorMessage = error.localizedDescription
                    }
                    markOfflineOnConnectivityFailure(error)
                }
            }
            return
        }

        if showLoading {
            loadingMessage = "Refreshing videos"
            phase = .loading
        }

        do {
            let manifest = try await syncManifest(deviceId: deviceId, child: child)
            apply(manifest, for: child)
            lastSyncedText = "Synced just now"
            if showLoading {
                phase = .ready
            }
        } catch {
            if showLoading {
                if enterOfflineModeIfPossible(preferredChildId: child.id) {
                    return
                }
                fail(error)
            } else {
                if !quiet {
                    playbackErrorMessage = error.localizedDescription
                }
                markOfflineOnConnectivityFailure(error)
            }
        }
    }

    private static let offlinePlaybackMessage = "This video isn't saved on this device, so it needs the internet to play."

    func play(_ video: ManifestVideo) async {
        playbackErrorMessage = ""
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }

        do {
            try configurePlaybackAudio()
            let url: URL
            if let localURL = offline.localURL(for: video.id) {
                url = localURL
            } else if !isNetworkAvailable {
                playbackErrorMessage = Self.offlinePlaybackMessage
                return
            } else {
                url = try await api.playbackURL(videoId: video.id).url
            }
            let resumeAt = history.entry(for: video.id)?.resumePosition ?? 0
            history.recordPlayback(of: video, serverBaseURL: apiBaseURL)
            playbackItem = PlaybackItem(video: video, url: url, resumeAt: resumeAt)
        } catch {
            playbackErrorMessage = error.localizedDescription
            markOfflineOnConnectivityFailure(error)
        }
    }

    /// Plays straight from a history entry, even when the video has since
    /// left the synced library — the server link is all that's needed.
    func play(historyEntry: WatchHistoryEntry) async {
        if let video = videos.first(where: { $0.id == historyEntry.id }) {
            await play(video)
            return
        }

        playbackErrorMessage = ""
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }

        do {
            try configurePlaybackAudio()
            let url: URL
            if let localURL = offline.localURL(for: historyEntry.id) {
                url = localURL
            } else if !isNetworkAvailable {
                playbackErrorMessage = Self.offlinePlaybackMessage
                return
            } else {
                url = try await api.playbackURL(videoId: historyEntry.id).url
            }
            let video = ManifestVideo(
                id: historyEntry.id,
                title: historyEntry.title,
                description: "",
                durationSeconds: historyEntry.durationSeconds,
                downloadPriority: .normal,
                expiresAt: nil,
                assets: []
            )
            let resumeAt = historyEntry.resumePosition ?? 0
            history.recordPlayback(of: video, serverBaseURL: apiBaseURL)
            playbackItem = PlaybackItem(video: video, url: url, resumeAt: resumeAt)
        } catch {
            playbackErrorMessage = error.localizedDescription
            markOfflineOnConnectivityFailure(error)
        }
    }

    func preparePlaybackItem(for video: ManifestVideo) async -> PlaybackItem? {
        playbackErrorMessage = ""

        do {
            try configurePlaybackAudio()
            let url: URL
            if let localURL = offline.localURL(for: video.id) {
                url = localURL
            } else if !isNetworkAvailable {
                playbackErrorMessage = Self.offlinePlaybackMessage
                return nil
            } else {
                url = try await api.playbackURL(videoId: video.id).url
            }
            history.recordPlayback(of: video, serverBaseURL: apiBaseURL)
            return PlaybackItem(video: video, url: url)
        } catch {
            playbackErrorMessage = error.localizedDescription
            markOfflineOnConnectivityFailure(error)
            return nil
        }
    }

    /// A failed request that couldn't reach the server means we're
    /// effectively offline — switch modes so the retry loop takes over.
    private func markOfflineOnConnectivityFailure(_ error: Error) {
        if (error as? APIError)?.isConnectivityFailure == true {
            markOffline()
        }
    }

    func closePlayer() {
        playbackItem = nil
    }

    func recoverForChildUse() {
        playbackItem = nil
    }

    /// Saves progress locally and mirrors it to the server, throttled so the
    /// per-tick player callbacks don't hammer either one. `force` bypasses
    /// the throttle so closing the player never loses the resume position.
    func reportPlaybackProgress(videoId: UUID, position: Double, completed: Bool, force: Bool = false) {
        let lastReported = lastReportedProgress[videoId] ?? -100
        guard completed || force || abs(position - lastReported) >= 10 else { return }
        lastReportedProgress[videoId] = position

        history.updateProgress(videoId: videoId, positionSeconds: position, completed: completed)

        guard let child = selectedChild else { return }
        let api = api
        let deviceId = deviceId
        Task {
            try? await api.reportWatchProgress(
                childId: child.id,
                videoId: videoId,
                deviceId: deviceId,
                positionSeconds: Int(position),
                completed: completed
            )
        }
    }

    @discardableResult
    func updateAPIBaseURL(_ text: String) throws -> Bool {
        let newURL = try APIConfigurationStore.normalizedBaseURL(from: text)
        guard newURL != apiBaseURL else { return false }

        apiConfigurationStore.saveBaseURL(newURL)
        applyAPIBaseURL(newURL)
        return true
    }

    @discardableResult
    func resetAPIBaseURLToDefault() -> Bool {
        let newURL = apiConfigurationStore.resetBaseURL()
        guard newURL != apiBaseURL else { return false }
        applyAPIBaseURL(newURL)
        return true
    }

    private func applyAPIBaseURL(_ newURL: URL) {
        apiBaseURL = newURL
        deviceId = nil
        selectedChild = nil
        children = []
        videos = []
        playbackItem = nil
        playbackErrorMessage = ""
        lastSyncedText = "Not synced yet"
        errorMessage = ""
        Task {
            await loadChildren()
        }
    }

    private func ensureDevice(for child: ChildProfile) async throws -> UUID {
        let key = deviceKey(for: child)
        if let stored = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) {
            deviceId = stored
            return stored
        }

        let device = try await api.registerDevice(childId: child.id)
        defaults.set(device.id.uuidString, forKey: key)
        deviceId = device.id
        return device.id
    }

    /// Syncs, transparently re-registering when the stored device was
    /// deleted server-side.
    private func syncManifest(deviceId: UUID, child: ChildProfile) async throws -> SyncManifest {
        do {
            return try await api.syncDevice(deviceId: deviceId)
        } catch let error as APIError {
            guard case .server(_, let message) = error, message.localizedCaseInsensitiveContains("device") else {
                throw error
            }
            defaults.removeObject(forKey: deviceKey(for: child))
            self.deviceId = nil
            let freshId = try await ensureDevice(for: child)
            return try await api.syncDevice(deviceId: freshId)
        }
    }

    private func deviceKey(for child: ChildProfile) -> String {
        "HappiEDeviceId-\(child.id.uuidString)"
    }

    private func configurePlaybackAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
    }

    private func apply(_ manifest: SyncManifest, for child: ChildProfile) {
        videos = manifest.videos
        isOfflineMode = false
        saveLibraryCache(child: child, videos: manifest.videos)
        autoDownloadIfEnabled()
        offline.backfillSidecars(from: manifest.videos)
    }

    var autoDownloadRequired: Bool {
        get {
            defaults.object(forKey: Self.autoDownloadKey) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Self.autoDownloadKey)
            if newValue {
                autoDownloadIfEnabled()
            }
        }
    }

    private func autoDownloadIfEnabled() {
        guard autoDownloadRequired else { return }
        for video in videos where video.downloadPriority == .required {
            offline.download(video)
        }
    }

    // MARK: - Offline library cache

    private struct LibraryCache: Codable {
        let child: ChildProfile
        let videos: [ManifestVideo]
    }

    private var libraryCacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "libraryCache.json")
    }

    private func saveLibraryCache(child: ChildProfile, videos: [ManifestVideo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(LibraryCache(child: child, videos: videos)) else { return }
        try? data.write(to: libraryCacheURL, options: .atomic)
    }

    private func loadLibraryCache() -> LibraryCache? {
        guard let data = try? Data(contentsOf: libraryCacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibraryCache.self, from: data)
    }

    /// Falls back to the last synced library when the server is unreachable,
    /// so downloaded videos stay watchable offline. Saved videos missing from
    /// the cached manifest (or with no cache at all) are rebuilt from their
    /// on-disk sidecars.
    private func enterOfflineModeIfPossible(preferredChildId: UUID? = nil) -> Bool {
        let cache = loadLibraryCache()
        if let cache, let preferredChildId, cache.child.id != preferredChildId { return false }

        var offlineVideos = cache?.videos ?? []
        let knownIds = Set(offlineVideos.map(\.id))
        offlineVideos += offline.downloadedVideosFromSidecars.filter { !knownIds.contains($0.id) }
        guard !offlineVideos.isEmpty else { return false }

        if let cache {
            selectedChild = cache.child
        }
        videos = offlineVideos
        isOfflineMode = true
        lastSyncedText = "Offline — showing saved videos"
        phase = .ready
        startOfflineRetryLoop()
        return true
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        phase = .failed
    }
}
