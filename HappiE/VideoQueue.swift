import Foundation

/// Resolves player navigation without letting an unrelated title interrupt a series.
enum VideoQueue {
    static func next(after current: ManifestVideo, in videos: [ManifestVideo]) -> ManifestVideo? {
        guard let currentSeries = seriesKey(for: current),
              let currentEpisode = current.episodeNumber
        else {
            // Preserve the original flat-library behavior when episode metadata is absent.
            return videos.first { $0.id != current.id }
        }

        let currentPosition = Position(season: current.seasonNumber ?? 0, episode: currentEpisode)

        return videos
            .compactMap { video -> (video: ManifestVideo, position: Position)? in
                guard video.id != current.id,
                      seriesKey(for: video) == currentSeries,
                      let episode = video.episodeNumber
                else { return nil }

                let position = Position(season: video.seasonNumber ?? 0, episode: episode)
                guard position > currentPosition else { return nil }
                return (video, position)
            }
            .min { lhs, rhs in lhs.position < rhs.position }?
            .video
    }

    private static func seriesKey(for video: ManifestVideo) -> String? {
        if let seriesId = video.seriesId {
            return "id:\(seriesId.uuidString.lowercased())"
        }

        let title = video.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : "title:\(title.lowercased())"
    }

    private struct Position: Comparable {
        let season: Int
        let episode: Int

        static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.season, lhs.episode) < (rhs.season, rhs.episode)
        }
    }
}
