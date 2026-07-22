//
//  ContentView.swift
//  HappiE
//
//  Created for HappiE.
//

import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var isShowingParentGate = false
    @State private var isShowingParentControls = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            HTheme.background
                .ignoresSafeArea()

            switch model.phase {
            case .welcome:
                WelcomeSplashView()
            case .loading:
                LoadingView(message: model.loadingMessage)
            case .selectingChild:
                ProfilePickerView(model: model)
            case .ready:
                MainTabsView(model: model) {
                    isShowingParentGate = true
                }
            case .failed:
                ErrorView(model: model) {
                    isShowingParentGate = true
                }
            }
        }
        .preferredColorScheme(.light)
        .task {
            // UI-test hook: present the parental gate immediately.
            if CommandLine.arguments.contains("-uitest-parent-gate") {
                isShowingParentGate = true
            }
            await model.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                model.recoverForChildUse()
            }
        }
        .fullScreenCover(item: $model.playbackItem) { item in
            VideoPlayerScreen(
                item: item,
                videos: model.videos,
                onSelectVideo: { video in
                    await model.preparePlaybackItem(for: video)
                },
                onRefreshVideos: {
                    await model.refreshLibrarySilently()
                    return model.videos
                },
                onProgress: { videoId, position, completed, force in
                    model.reportPlaybackProgress(videoId: videoId, position: position, completed: completed, force: force)
                }
            ) {
                model.closePlayer()
            }
        }
        .sheet(isPresented: $isShowingParentGate) {
            ParentGateView {
                isShowingParentControls = true
            }
        }
        .sheet(isPresented: $isShowingParentControls) {
            ParentControlsView(model: model) {
                isShowingParentControls = false
            }
        }
    }
}

private struct MainTabsView: View {
    @Bindable var model: AppModel
    let onOpenParentControls: () -> Void

    var body: some View {
        TabView {
            HomeView(model: model, onOpenParentControls: onOpenParentControls)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            HistoryView(model: model)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
        }
        .tint(HTheme.accent)
        .overlay(alignment: .bottom) {
            if !model.playbackErrorMessage.isEmpty {
                PlaybackErrorToast(message: model.playbackErrorMessage) {
                    model.playbackErrorMessage = ""
                }
                .padding(.bottom, 70)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.playbackErrorMessage.isEmpty)
    }
}

private struct PlaybackErrorToast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(HTheme.ink.opacity(0.92))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 30)
        .accessibilityHint("Dismisses the message")
    }
}

private struct WelcomeSplashView: View {
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 18) {
            BrandMark(size: 110)
                .scaleEffect(isPlaying ? 1 : 0.6)
                .animation(.interpolatingSpring(stiffness: 120, damping: 13).delay(0.08), value: isPlaying)

            Text("HappiE")
                .font(.system(size: 54, weight: .heavy, design: .rounded))
                .foregroundStyle(HTheme.ink)
                .opacity(isPlaying ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.2), value: isPlaying)

            Text("Your family videos")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(HTheme.muted)
                .opacity(isPlaying ? 1 : 0)
                .offset(y: isPlaying ? 0 : 10)
                .animation(.easeOut(duration: 0.4).delay(0.34), value: isPlaying)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isPlaying = true
        }
    }
}

private struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            BrandMark(size: 76)

            ProgressView()
                .controlSize(.large)
                .tint(HTheme.accent)

            Text(message)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(HTheme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProfilePickerView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 34) {
            VStack(spacing: 8) {
                BrandWordmark(markSize: 42)

                Text("Who is watching?")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(HTheme.ink)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 22)], spacing: 22) {
                ForEach(model.children) { child in
                    Button {
                        Task {
                            await model.select(child)
                        }
                    } label: {
                        VStack(spacing: 14) {
                            AvatarCircle(name: child.name, size: 104)

                            Text(child.name)
                                .font(.system(size: 24, weight: .heavy, design: .rounded))
                                .foregroundStyle(HTheme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .background(HTheme.surface)
                        .clipShape(.rect(cornerRadius: 24))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Watch as \(child.name)")
                }
            }
            .frame(maxWidth: 760)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorView: View {
    @Bindable var model: AppModel
    let onOpenParentControls: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(HTheme.muted)

            Text("Can't load videos")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(HTheme.ink)

            Text(model.errorMessage)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(HTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            HStack(spacing: 14) {
                Button {
                    Task {
                        await model.loadChildren()
                    }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(width: 190, height: 60)
                }
                .buttonStyle(PrimaryButtonStyle())

                Button(action: onOpenParentControls) {
                    Label("Parent controls", systemImage: "lock.shield")
                        .frame(width: 220, height: 60)
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview(traits: .landscapeLeft) {
    ContentView()
}
