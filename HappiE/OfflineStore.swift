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
        states[videoId] = .notDownloaded
    }

    func removeAllDownloads() {
        for videoId in states.keys {
            removeDownload(videoId: videoId)
        }
    }

    private func fileURL(for videoId: UUID) -> URL {
        directory.appending(path: "\(videoId.uuidString).mp4")
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
