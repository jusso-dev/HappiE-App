//
//  Theme.swift
//  HappiE
//
//  Created for HappiE.
//

import SwiftUI

/// Clean, minimal palette modeled on a video-sharing platform:
/// white surfaces, near-black text, a single red accent.
enum HTheme {
    static let background = Color.white
    static let surface = Color(red: 0.96, green: 0.96, blue: 0.96)
    static let ink = Color(red: 0.05, green: 0.05, blue: 0.05)
    static let muted = Color(red: 0.38, green: 0.38, blue: 0.38)
    static let line = Color(red: 0.90, green: 0.90, blue: 0.90)
    static let accent = Color(red: 1.0, green: 0.0, blue: 0.2)
    static let badge = Color.black.opacity(0.75)

    static let thumbnailCorner: CGFloat = 12

    static let avatarPalette: [Color] = [
        Color(red: 0.05, green: 0.58, blue: 0.46),
        Color(red: 0.91, green: 0.34, blue: 0.31),
        Color(red: 0.22, green: 0.55, blue: 0.80),
        Color(red: 0.91, green: 0.63, blue: 0.18)
    ]
}

struct BrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(HTheme.accent)

            Image(systemName: "play.fill")
                .font(.system(size: size * 0.44, weight: .black))
                .foregroundStyle(.white)
                .offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
    }
}

struct BrandWordmark: View {
    var markSize: CGFloat = 34

    var body: some View {
        HStack(spacing: 8) {
            BrandMark(size: markSize)

            Text("HappiE")
                .font(.system(size: markSize * 0.68, weight: .heavy, design: .rounded))
                .foregroundStyle(HTheme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HappiE")
    }
}

struct AvatarCircle: View {
    let name: String
    let size: CGFloat

    private var color: Color {
        // Stable across launches, unlike String.hashValue which is
        // randomized per process and made avatars change color.
        let value = name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
        let index = abs(value) % HTheme.avatarPalette.count
        return HTheme.avatarPalette[index]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color)

            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .background(HTheme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(HTheme.ink)
            .background(configuration.isPressed ? HTheme.line : HTheme.surface)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Kid-friendly relative "watched" text, e.g. "Watched today".
enum WatchedDateText {
    static func text(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Watched today"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Watched yesterday"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Watched \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}
