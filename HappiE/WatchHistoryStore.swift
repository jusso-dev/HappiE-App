//
//  WatchHistoryStore.swift
//  HappiE
//
//  Created for HappiE.
//

import Foundation
import Observation

struct WatchHistoryEntry: Identifiable, Codable, Equatable {
    /// The server video id — doubles as the entry id.
    let id: UUID
    var title: String
    var durationSeconds: Int?
    /// Canonical link to the video on the server, e.g. http://host/videos/<id>.
    var serverLink: String
    var lastWatchedAt: Date
    var positionSeconds: Double
    var completed: Bool

    var durationText: String {
        ManifestVideo.timestampText(seconds: durationSeconds)
    }

    /// 0...1 progress through the video, nil when duration is unknown.
    var progressFraction: Double? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        if completed { return 1 }
        return min(max(positionSeconds / Double(durationSeconds), 0), 1)
    }

    /// A position worth resuming from: meaningfully started, not basically finished.
    var resumePosition: Double? {
        guard !completed, positionSeconds > 15 else { return nil }
        if let durationSeconds, durationSeconds > 0,
           positionSeconds > Double(durationSeconds) * 0.95 {
            return nil
        }
        return positionSeconds
    }
}

/// Persists watch history on the device: a JSON index plus cached thumbnail
/// images, so history survives offline and across launches.
@MainActor
@Observable
final class WatchHistoryStore {
    private(set) var entries: [WatchHistoryEntry] = []

    private static let maxEntries = 100

    private let directory: URL
    private let thumbnailDirectory: URL
    private let indexURL: URL
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = base.appending(path: "WatchHistory", directoryHint: .isDirectory)
        thumbnailDirectory = directory.appending(path: "thumbnails", directoryHint: .isDirectory)
        indexURL = directory.appending(path: "history.json")
        try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        load()
    }

    func entry(for videoId: UUID) -> WatchHistoryEntry? {
        entries.first(where: { $0.id == videoId })
    }

    var continueWatching: [WatchHistoryEntry] {
        entries.filter { $0.resumePosition != nil }
    }

    /// Records that playback started, moving the video to the top of history
    /// and caching its thumbnail locally for offline display.
    func recordPlayback(of video: ManifestVideo, serverBaseURL: URL) {
        var entry = entries.first(where: { $0.id == video.id }) ?? WatchHistoryEntry(
            id: video.id,
            title: video.displayTitle,
            durationSeconds: video.durationSeconds,
            serverLink: "",
            lastWatchedAt: Date(),
            positionSeconds: 0,
            completed: false
        )
        entry.title = video.displayTitle
        entry.durationSeconds = video.durationSeconds ?? entry.durationSeconds
        entry.serverLink = serverBaseURL
            .appending(path: "/videos/\(video.id.uuidString.lowercased())")
            .absoluteString
        entry.lastWatchedAt = Date()
        upsert(entry)

        if let thumbnailURL = video.thumbnailURL {
            cacheThumbnailIfNeeded(videoId: video.id, from: thumbnailURL)
        }
    }

    func updateProgress(videoId: UUID, positionSeconds: Double, completed: Bool) {
        guard var entry = entries.first(where: { $0.id == videoId }) else { return }
        entry.positionSeconds = positionSeconds
        entry.completed = completed || entry.completed
        entry.lastWatchedAt = Date()
        upsert(entry)
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: thumbnailDirectory)
        try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        save()
    }

    /// Local file URL of the cached thumbnail, if one has been saved.
    func thumbnailFileURL(for videoId: UUID) -> URL? {
        let url = thumbnailDirectory.appending(path: "\(videoId.uuidString).jpg")
        return FileManager.default.fileExists(atPath: url.path()) ? url : nil
    }

    private func upsert(_ entry: WatchHistoryEntry) {
        entries.removeAll(where: { $0.id == entry.id })
        entries.insert(entry, at: 0)
        entries.sort(by: { $0.lastWatchedAt > $1.lastWatchedAt })
        if entries.count > Self.maxEntries {
            for removed in entries[Self.maxEntries...] {
                let thumb = thumbnailDirectory.appending(path: "\(removed.id.uuidString).jpg")
                try? FileManager.default.removeItem(at: thumb)
            }
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    private func cacheThumbnailIfNeeded(videoId: UUID, from remoteURL: URL) {
        guard thumbnailFileURL(for: videoId) == nil else { return }
        let destination = thumbnailDirectory.appending(path: "\(videoId.uuidString).jpg")
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

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([WatchHistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
