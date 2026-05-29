//
//  APIConfiguration.swift
//  HappiE
//
//  Created for HappiE.
//

import Foundation

struct APIConfigurationStore {
    private let defaults: UserDefaults
    private let baseURLKey = "HappiEAPIBaseURL"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadBaseURL() -> URL {
        guard
            let storedValue = defaults.string(forKey: baseURLKey),
            let storedURL = try? Self.normalizedBaseURL(from: storedValue)
        else {
            return APIEnvironment.defaultBaseURL
        }

        return storedURL
    }

    func saveBaseURL(from text: String) throws -> URL {
        let url = try Self.normalizedBaseURL(from: text)
        saveBaseURL(url)
        return url
    }

    func saveBaseURL(_ url: URL) {
        defaults.set(url.absoluteString, forKey: baseURLKey)
    }

    func resetBaseURL() -> URL {
        defaults.removeObject(forKey: baseURLKey)
        return APIEnvironment.defaultBaseURL
    }

    static func normalizedBaseURL(from text: String) throws -> URL {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw APIConfigurationError.empty
        }

        if !value.contains("://") {
            value = "http://\(value)"
        }

        guard var components = URLComponents(string: value) else {
            throw APIConfigurationError.invalid
        }

        components.scheme = components.scheme?.lowercased()

        guard let scheme = components.scheme, ["http", "https"].contains(scheme) else {
            throw APIConfigurationError.unsupportedScheme
        }

        guard components.host?.isEmpty == false else {
            throw APIConfigurationError.missingHost
        }

        guard components.query == nil, components.fragment == nil else {
            throw APIConfigurationError.unsupportedComponents
        }

        trimTrailingSlashes(from: &components)

        guard let url = components.url else {
            throw APIConfigurationError.invalid
        }

        return url
    }

    private static func trimTrailingSlashes(from components: inout URLComponents) {
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        components.percentEncodedPath = path == "/" ? "" : path
    }
}

enum APIConfigurationError: LocalizedError {
    case empty
    case invalid
    case missingHost
    case unsupportedScheme
    case unsupportedComponents

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter an API server URL."
        case .invalid:
            return "Enter a valid API server URL."
        case .missingHost:
            return "The API server URL needs a host name or IP address."
        case .unsupportedScheme:
            return "The API server URL must start with http:// or https://."
        case .unsupportedComponents:
            return "Remove query strings and fragments from the API server URL."
        }
    }
}
