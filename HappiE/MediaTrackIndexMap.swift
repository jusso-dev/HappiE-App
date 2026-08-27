import Foundation

enum MediaTrackType: String, Codable { case audio, subtitle }

struct MediaTrack: Identifiable, Codable, Equatable {
    let index: Int
    let title: String
    let language: String?
    let requiresRebuild: Bool
    var id: Int { index }

    init(index: Int, title: String, language: String?, requiresRebuild: Bool) {
        self.index = index
        self.title = title
        self.language = language
        self.requiresRebuild = requiresRebuild
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        language = try values.decodeIfPresent(String.self, forKey: .language)
        requiresRebuild = try values.decodeIfPresent(Bool.self, forKey: .requiresRebuild) ?? false
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let language, !language.isEmpty { return language }
        return "Track \(index + 1)"
    }
}

/// Maps stable stream indexes to their position in a native media group.
/// Missing indexes (and -1) map to Off.
struct MediaTrackIndexMap: Equatable {
    let streamIndexes: [Int]
    func optionOffset(forStreamIndex streamIndex: Int) -> Int? {
        guard streamIndex >= 0 else { return nil }
        return streamIndexes.firstIndex(of: streamIndex)
    }
    func streamIndex(forOptionOffset offset: Int?) -> Int {
        guard let offset, streamIndexes.indices.contains(offset) else { return -1 }
        return streamIndexes[offset]
    }
}
