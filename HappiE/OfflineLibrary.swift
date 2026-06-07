//
//  OfflineLibrary.swift
//  HappiE
//
//  Created for HappiE.
//

import Foundation
import Combine

struct LibrarySnapshot: Codable {
    var children: [ChildProfile]
    var selectedChildId: UUID?
    var deviceId: UUID?
    var videos: [ManifestVideo]
    var manifestExpiresAt: Date?
    var lastSyncedAt: Date?
}

enum OfflineStorage {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("HappiE", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

final class LibraryCacheStore {
    private let fileURL: URL

    init() {
        fileURL = OfflineStorage.root.appendingPathComponent("library.json")
    }

    func load() -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibrarySnapshot.self, from: data)
    }

    func save(_ snapshot: LibrarySnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

struct OfflineAssetIndex: Codable {
    struct Entry: Codable {
        var videoAssetId: UUID?
        var videoAssetVersion: Int?
        var videoFileName: String?
        var thumbAssetId: UUID?
        var thumbAssetVersion: Int?
        var thumbFileName: String?
    }
    var entries: [UUID: Entry] = [:]
}

@MainActor
final class OfflineAssetStore: ObservableObject {
    @Published private(set) var offlineVideoIDs: Set<UUID> = []
    @Published private(set) var downloadingVideoIDs: Set<UUID> = []

    private let directory: URL
    private let indexURL: URL
    private var index: OfflineAssetIndex
    private let session: URLSession
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    init(session: URLSession = .shared) {
        let dir = OfflineStorage.root.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        indexURL = dir.appendingPathComponent("index.json")
        self.session = session

        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode(OfflineAssetIndex.self, from: data) {
            index = decoded
        } else {
            index = OfflineAssetIndex()
        }
        rebuildOfflineSet()
    }

    func localVideoURL(for videoID: UUID) -> URL? {
        guard let entry = index.entries[videoID], let name = entry.videoFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func localThumbnailURL(for videoID: UUID) -> URL? {
        guard let entry = index.entries[videoID], let name = entry.thumbFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func reconcile(videos: [ManifestVideo], removedIDs: [UUID]) {
        let eligible = videos.filter { $0.downloadPriority == .required || $0.downloadPriority == .normal }
        let eligibleIDs = Set(eligible.map(\.id))

        for (videoID, entry) in index.entries where !eligibleIDs.contains(videoID) {
            activeTasks[videoID]?.cancel()
            activeTasks[videoID] = nil
            removeFile(entry.videoFileName)
            removeFile(entry.thumbFileName)
            index.entries.removeValue(forKey: videoID)
        }

        for id in removedIDs {
            activeTasks[id]?.cancel()
            activeTasks[id] = nil
            if let entry = index.entries[id] {
                removeFile(entry.videoFileName)
                removeFile(entry.thumbFileName)
                index.entries.removeValue(forKey: id)
            }
        }

        let sorted = eligible.sorted { lhs, rhs in
            if lhs.downloadPriority != rhs.downloadPriority {
                return lhs.downloadPriority == .required
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        for video in sorted {
            scheduleDownload(video)
        }

        persistIndex()
        rebuildOfflineSet()
    }

    func clearAll() {
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = OfflineAssetIndex()
        persistIndex()
        rebuildOfflineSet()
    }

    private func scheduleDownload(_ video: ManifestVideo) {
        guard activeTasks[video.id] == nil else { return }

        let videoAsset = pickVideoAsset(from: video.assets)
        let thumbAsset = video.assets.first(where: { $0.kind == .thumbnail })

        let existing = index.entries[video.id]
        let needVideo = needsDownload(
            asset: videoAsset,
            existingId: existing?.videoAssetId,
            existingVersion: existing?.videoAssetVersion,
            fileName: existing?.videoFileName
        )
        let needThumb = needsDownload(
            asset: thumbAsset,
            existingId: existing?.thumbAssetId,
            existingVersion: existing?.thumbAssetVersion,
            fileName: existing?.thumbFileName
        )

        if !needVideo && !needThumb { return }

        downloadingVideoIDs.insert(video.id)
        let videoID = video.id
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(
                videoID: videoID,
                videoAsset: needVideo ? videoAsset : nil,
                thumbAsset: needThumb ? thumbAsset : nil
            )
        }
        activeTasks[videoID] = task
    }

    private func runDownload(videoID: UUID, videoAsset: ManifestAsset?, thumbAsset: ManifestAsset?) async {
        var entry = index.entries[videoID] ?? OfflineAssetIndex.Entry()

        if let asset = videoAsset {
            let fileName = "\(asset.id.uuidString).\(fileExtension(for: asset, fallback: "mp4"))"
            let dest = directory.appendingPathComponent(fileName)
            do {
                try await downloadFile(from: asset.url, to: dest)
                if let oldName = entry.videoFileName, oldName != fileName {
                    removeFile(oldName)
                }
                entry.videoAssetId = asset.id
                entry.videoAssetVersion = asset.version
                entry.videoFileName = fileName
            } catch {
                downloadingVideoIDs.remove(videoID)
                activeTasks[videoID] = nil
                return
            }
        }

        if let asset = thumbAsset {
            let fileName = "\(asset.id.uuidString).\(fileExtension(for: asset, fallback: "jpg"))"
            let dest = directory.appendingPathComponent(fileName)
            do {
                try await downloadFile(from: asset.url, to: dest)
                if let oldName = entry.thumbFileName, oldName != fileName {
                    removeFile(oldName)
                }
                entry.thumbAssetId = asset.id
                entry.thumbAssetVersion = asset.version
                entry.thumbFileName = fileName
            } catch {
                // Thumb failure is not fatal.
            }
        }

        index.entries[videoID] = entry
        downloadingVideoIDs.remove(videoID)
        activeTasks[videoID] = nil
        rebuildOfflineSet()
        persistIndex()
    }

    private func downloadFile(from url: URL, to dest: URL) async throws {
        let (tempURL, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
    }

    private func pickVideoAsset(from assets: [ManifestAsset]) -> ManifestAsset? {
        if let mp4 = assets.first(where: { $0.kind == .mp4 }) { return mp4 }
        if let original = assets.first(where: { $0.kind == .original }) { return original }
        return nil
    }

    private func fileExtension(for asset: ManifestAsset, fallback: String) -> String {
        let ext = asset.url.pathExtension
        return ext.isEmpty ? fallback : ext
    }

    private func needsDownload(asset: ManifestAsset?, existingId: UUID?, existingVersion: Int?, fileName: String?) -> Bool {
        guard let asset else { return false }
        guard
            let existingId, existingId == asset.id,
            let existingVersion, existingVersion == asset.version,
            let fileName,
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        else {
            return true
        }
        return false
    }

    private func removeFile(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func rebuildOfflineSet() {
        var ids: Set<UUID> = []
        for (id, entry) in index.entries {
            guard let name = entry.videoFileName else { continue }
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                ids.insert(id)
            }
        }
        offlineVideoIDs = ids
    }
}
