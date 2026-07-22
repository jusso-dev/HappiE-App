//
//  OfflineStore.swift
//  HappiE
//
//  Created for HappiE.
//

import Foundation
import Observation

enum OfflineState: Equatable {
    case notDownloaded
    case downloading(Double)
    case downloaded(bytes: Int64)

    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Sidecar saved next to each downloaded video so the title, duration, and
/// thumbnail survive offline, independent of the synced manifest.
struct OfflineVideoMetadata: Codable {
    let title: String
    let durationSeconds: Int?
}

/// Downloads videos to the device and serves them for offline playback.
/// Files live in Application Support/OfflineVideos (excluded from backup);
/// the store rescans on launch so downloads survive restarts.
@MainActor
@Observable
final class OfflineStore {
    private(set) var states: [UUID: OfflineState] = [:]

    private let directory: URL
    private let session: URLSession
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appending(path: "OfflineVideos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup()
        scanExistingDownloads()
    }

    func state(for videoId: UUID) -> OfflineState {
        states[videoId] ?? .notDownloaded
    }

    /// Local file to play from, when the video has been fully downloaded.
    func localURL(for videoId: UUID) -> URL? {
        guard state(for: videoId).isDownloaded else { return nil }
        return fileURL(for: videoId)
    }

    var downloadedCount: Int {
        states.values.filter(\.isDownloaded).count
    }

    var totalDownloadedBytes: Int64 {
        states.values.reduce(0) { total, state in
            if case .downloaded(let bytes) = state {
                return total + bytes
            }
            return total
        }
    }

    var totalDownloadedText: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedBytes, countStyle: .file)
    }

    func download(_ video: ManifestVideo) {
        guard state(for: video.id) == .notDownloaded else { return }
        guard let asset = video.assets.first(where: { $0.kind == .mp4 }) else { return }

        saveSidecar(for: video)
        states[video.id] = .downloading(0)
        let videoId = video.id
        let destination = fileURL(for: videoId)

        let task = session.downloadTask(with: asset.url) { tempURL, response, _ in
            let succeeded: Int64? = {
                guard
                    let tempURL,
                    let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode)
                else {
                    return nil
                }
                try? FileManager.default.removeItem(at: destination)
                guard (try? FileManager.default.moveItem(at: tempURL, to: destination)) != nil else {
                    return nil
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path())[.size] as? Int64) ?? nil
                return size ?? 0
            }()

            Task { @MainActor [weak self] in
                guard let self else { return }
                progressObservations[videoId] = nil
                tasks[videoId] = nil
                if let bytes = succeeded {
                    states[videoId] = .downloaded(bytes: bytes)
                } else {
                    states[videoId] = .notDownloaded
                }
            }
        }

        progressObservations[videoId] = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor [weak self] in
                guard let self, state(for: videoId).isDownloading else { return }
                states[videoId] = .downloading(fraction)
            }
        }

        tasks[videoId] = task
        task.resume()
    }

    func cancelDownload(videoId: UUID) {
        tasks[videoId]?.cancel()
        tasks[videoId] = nil
        progressObservations[videoId] = nil
        if state(for: videoId).isDownloading {
            states[videoId] = .notDownloaded
        }
    }

    func removeDownload(videoId: UUID) {
        cancelDownload(videoId: videoId)
        try? FileManager.default.removeItem(at: fileURL(for: videoId))
        try? FileManager.default.removeItem(at: metadataURL(for: videoId))
        try? FileManager.default.removeItem(at: thumbnailURL(for: videoId))
        states[videoId] = .notDownloaded
    }

    func removeAllDownloads() {
        for videoId in states.keys {
            removeDownload(videoId: videoId)
        }
    }

    // MARK: - Offline metadata and thumbnails

    /// Locally cached thumbnail for a downloaded video, if present.
    func thumbnailFileURL(for videoId: UUID) -> URL? {
        let url = thumbnailURL(for: videoId)
        return FileManager.default.fileExists(atPath: url.path()) ? url : nil
    }

    func metadata(for videoId: UUID) -> OfflineVideoMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: videoId)) else { return nil }
        return try? JSONDecoder().decode(OfflineVideoMetadata.self, from: data)
    }

    /// Writes the title/duration sidecar and caches the thumbnail image so a
    /// saved video stays fully presentable with no network at all.
    func saveSidecar(for video: ManifestVideo) {
        let metadata = OfflineVideoMetadata(
            title: video.displayTitle,
            durationSeconds: video.durationSeconds
        )
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: metadataURL(for: video.id), options: .atomic)
        }

        guard thumbnailFileURL(for: video.id) == nil, let remoteURL = video.thumbnailURL else { return }
        let destination = thumbnailURL(for: video.id)
        let session = session
        Task.detached(priority: .utility) {
            guard let (data, response) = try? await session.data(from: remoteURL),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                return
            }
            try? data.write(to: destination, options: .atomic)
        }
    }

    /// Repairs sidecars for videos downloaded before metadata/thumbnail
    /// caching existed (or whose thumbnail fetch previously failed).
    func backfillSidecars(from videos: [ManifestVideo]) {
        for video in videos where state(for: video.id).isDownloaded {
            if metadata(for: video.id) == nil || thumbnailFileURL(for: video.id) == nil {
                saveSidecar(for: video)
            }
        }
    }

    /// Downloaded videos reconstructed from sidecars, for offline mode when
    /// a video is no longer in (or there is no) cached manifest.
    var downloadedVideosFromSidecars: [ManifestVideo] {
        states.keys
            .filter { state(for: $0).isDownloaded }
            .compactMap { videoId in
                let metadata = metadata(for: videoId)
                return ManifestVideo(
                    id: videoId,
                    title: metadata?.title ?? "Saved video",
                    description: "",
                    durationSeconds: metadata?.durationSeconds,
                    downloadPriority: .normal,
                    expiresAt: nil,
                    assets: []
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func fileURL(for videoId: UUID) -> URL {
        directory.appending(path: "\(videoId.uuidString).mp4")
    }

    private func metadataURL(for videoId: UUID) -> URL {
        directory.appending(path: "\(videoId.uuidString).json")
    }

    private func thumbnailURL(for videoId: UUID) -> URL {
        directory.appending(path: "\(videoId.uuidString).jpg")
    }

    private func scanExistingDownloads() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        for file in files where file.pathExtension == "mp4" {
            guard let videoId = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            states[videoId] = .downloaded(bytes: size)
        }
    }

    private func excludeFromBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }
}
