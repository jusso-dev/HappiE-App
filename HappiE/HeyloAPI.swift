//
//  HeyloAPI.swift
//  HappiE
//
//  Created by Justin Middler on 25/5/2026.
//

import Foundation
import Security

struct APIEnvironment {
    static let local = APIEnvironment(baseURL: defaultBaseURL)

    let baseURL: URL

    private static var defaultBaseURL: URL {
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

    func login(email: String, password: String) async throws -> TokenResponse {
        try await request(
            "/auth/login",
            method: "POST",
            body: LoginRequest(email: email, password: password),
            token: nil
        )
    }

    func refresh(refreshToken: String) async throws -> TokenResponse {
        try await request(
            "/auth/refresh",
            method: "POST",
            body: RefreshRequest(refreshToken: refreshToken),
            token: nil
        )
    }

    func children(token: String) async throws -> [ChildProfile] {
        try await request("/children", token: token)
    }

    func registerDevice(childId: UUID, token: String) async throws -> DeviceRegistration {
        try await request(
            "/devices/register",
            method: "POST",
            body: DeviceRegisterRequest(
                childProfileId: childId,
                name: "Family iPad",
                platform: "ios",
                storageQuotaMb: 8192
            ),
            token: token
        )
    }

    func syncDevice(deviceId: UUID, token: String) async throws -> SyncManifest {
        try await request("/devices/\(deviceId.uuidString)/sync", method: "POST", token: token)
    }

    func playbackURL(videoId: UUID, token: String) async throws -> PlaybackURLResponse {
        try await request("/videos/\(videoId.uuidString)/playback-url", token: token)
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        token: String?
    ) async throws -> Response {
        let emptyBody: EmptyBody? = nil
        return try await request(path, method: method, body: emptyBody, token: token)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Body?,
        token: String?
    ) async throws -> Response {
        let url = environment.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
                throw APIError.server(apiError.error)
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

final class AuthStore {
    private let service = "au.com.HappiE.auth"

    func loadTokens() -> StoredTokens? {
        guard
            let accessToken = read("accessToken"),
            let refreshToken = read("refreshToken")
        else {
            return nil
        }

        return StoredTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    func save(_ tokens: StoredTokens) {
        write(tokens.accessToken, key: "accessToken")
        write(tokens.refreshToken, key: "refreshToken")
    }

    func clear() {
        delete("accessToken")
        delete("refreshToken")
    }

    private func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, key: String) {
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8)
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    private func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}

struct StoredTokens {
    let accessToken: String
    let refreshToken: String
}

struct EmptyBody: Encodable {}

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

struct RefreshRequest: Encodable {
    let refreshToken: String
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
}

struct ChildProfile: Identifiable, Decodable, Equatable {
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

struct SyncManifest: Decodable {
    let deviceId: UUID
    let childProfileId: UUID
    let storageQuotaMb: Int
    let expiresAt: Date
    let videos: [ManifestVideo]
    let remove: [UUID]
}

struct ManifestVideo: Identifiable, Decodable {
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

struct ManifestAsset: Identifiable, Decodable {
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

enum DownloadPriority: String, Decodable {
    case required
    case normal
    case optional
}

enum AssetKind: String, Decodable {
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
    case server(String)
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
        case .server(let message):
            return message
        case .transport(let url, let error):
            return "Could not reach \(url.host ?? url.absoluteString): \(error.localizedDescription) (\(error.code.rawValue))"
        case .unexpectedPayload(let contentType):
            return "The API returned \(contentType), not JSON."
        }
    }
}
