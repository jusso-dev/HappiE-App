//
//  HappiEAPI.swift
//  HappiE
//
//  Created for HappiE.
//

import Foundation

struct APIEnvironment {
    static let local = APIEnvironment(baseURL: defaultBaseURL)

    let baseURL: URL

    static var defaultBaseURL: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "HAPPIE_API_BASE_URL") as? String
        let value = configured.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
        } ?? "http://localhost:18080"
        return URL(string: value)!
    }
}

struct APIClient {
    var environment: APIEnvironment = .local
    var session: URLSession = .shared

    func children() async throws -> [ChildProfile] {
        try await request("/children")
    }

    func registerDevice(childId: UUID) async throws -> DeviceRegistration {
        try await request(
            "/devices/register",
            method: "POST",
            body: DeviceRegisterRequest(
                childProfileId: childId,
                name: "Family iPad",
                platform: "ios",
                storageQuotaMb: 8192
            )
        )
    }

    func syncDevice(deviceId: UUID) async throws -> SyncManifest {
        try await request("/devices/\(deviceId.uuidString)/sync", method: "POST")
    }

    func playbackURL(videoId: UUID) async throws -> PlaybackURLResponse {
        try await request("/videos/\(videoId.uuidString)/playback-url")
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET"
    ) async throws -> Response {
        let emptyBody: EmptyBody? = nil
        return try await request(path, method: method, body: emptyBody)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Body?
    ) async throws -> Response {
        let url = environment.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(url: url, error: error)
        } catch {
            throw APIError.network(url: url, message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let apiError = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw APIError.server(statusCode: httpResponse.statusCode, message: apiError.error)
            }
            throw APIError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            throw APIError.unexpectedPayload(contentType: contentType)
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct EmptyBody: Encodable {}

struct ChildProfile: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let avatarColor: String?
    let birthYear: Int?
    let storageQuotaMb: Int
}

struct DeviceRegisterRequest: Encodable {
    let childProfileId: UUID
    let name: String
    let platform: String
    let storageQuotaMb: Int
}

struct DeviceRegistration: Decodable {
    let id: UUID
    let childProfileId: UUID?
    let storageQuotaMb: Int
}

struct SyncManifest: Codable {
    let deviceId: UUID
    let childProfileId: UUID
    let storageQuotaMb: Int
    let expiresAt: Date
    let videos: [ManifestVideo]
    let remove: [UUID]
}

struct ManifestVideo: Identifiable, Codable {
    let id: UUID
    let title: String
    let description: String
    let durationSeconds: Int?
    let downloadPriority: DownloadPriority
    let expiresAt: Date?
    let assets: [ManifestAsset]

    var thumbnailURL: URL? {
        assets.first(where: { $0.kind == .thumbnail })?.url
    }
}

struct ManifestAsset: Identifiable, Codable {
    let id: UUID
    let kind: AssetKind
    let quality: String?
    let width: Int?
    let height: Int?
    let durationSeconds: Int?
    let fileSizeBytes: Int64?
    let version: Int
    let url: URL
}

enum DownloadPriority: String, Codable {
    case required
    case normal
    case optional
}

enum AssetKind: String, Codable {
    case original
    case mp4
    case hls
    case thumbnail
}

struct PlaybackURLResponse: Decodable {
    let url: URL
    let expiresInSeconds: Int
}

struct APIErrorResponse: Decodable {
    let error: String
}

enum APIError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case network(url: URL, message: String)
    case server(statusCode: Int, message: String)
    case transport(url: URL, error: URLError)
    case unexpectedPayload(contentType: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The API did not return a valid HTTP response."
        case .httpStatus(let status):
            return "The API returned HTTP \(status)."
        case .network(let url, let message):
            return "Could not reach \(url.host ?? url.absoluteString): \(message)"
        case .server(_, let message):
            return message
        case .transport(let url, let error):
            return "Could not reach \(url.host ?? url.absoluteString): \(error.localizedDescription) (\(error.code.rawValue))"
        case .unexpectedPayload(let contentType):
            return "The API returned \(contentType), not JSON."
        }
    }
}
