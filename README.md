# HappiE iPad App

<p align="center">
  <img src="HappiE/Assets.xcassets/AppIcon.appiconset/HappiE-AppIcon-1024.png" alt="HappiE app icon" width="128" height="128">
</p>

HappiE is the SwiftUI iPad client for the HappiE family video library. It connects to the HappiE API on your home network (no login required), lets a child pick a profile, and plays parent-approved videos in a clean, YouTube-style interface built for little hands.

## Public Release Status

This Xcode project has been cleaned for public release:

- No personal Apple development team is required in project settings.
- Xcode `xcuserdata` is ignored and should not be committed.
- The API base URL is configurable inside Parent controls, with `HAPPIE_API_BASE_URL` as the default Info.plist value.
- The default API URL is `http://localhost:18080` for simulator development.
- App Transport Security allows local development without enabling arbitrary network loads globally.

## Local Setup

1. Start the HappiE backend from the web/API repository:

   ```bash
   cp .env.example .env
   docker compose up --build
   ```

2. Open `HappiE.xcodeproj` in Xcode.
3. Build and run on an iPad simulator.

For a physical iPad, set `HAPPIE_API_BASE_URL` to an API URL the device can reach, for example:

```text
http://YOUR_LAN_IP:18080
```

The backend must also use LAN-reachable `PUBLIC_API_BASE_URL` and `R2_ENDPOINT` values so signed playback and download URLs work from the iPad.

## Current Features

- No sign-in: the app talks directly to the HappiE API on a trusted home network.
- YouTube-style home screen: search bar, video grid with titles, durations, and thumbnails.
- Child profile selection, remembered across launches.
- Continue-watching shelf with resume positions and red progress bars.
- Watch history persisted locally on the device (title, duration, server link, cached thumbnail), searchable, playable even after the library changes.
- Full-screen kid-friendly player with loop control, autoplay-next with an "Up next" countdown, and a replay screen.
- Parental gate (type the spelled-out numbers) protecting Parent controls: profile switching, playback defaults, downloads, library sync, history clearing, and the API server setting.
- Watch progress mirrored to the server via `POST /watch-progress`.
- Library sync from `POST /devices/:id/sync`, with the device registration reused across launches.
- Native AirPlay route picker and volume control.

## Offline Downloads

Each video card has a download control: save, cancel mid-download, or remove with one tap. Videos the server marks `required` are downloaded automatically (toggleable in Parent controls), and Parent controls show saved count, storage used, and a remove-all action.

Playback always prefers the downloaded file. The app also caches the last synced library, so when the backend is unreachable it opens straight into the saved library, dims videos that aren't downloaded, and keeps saved ones playable.

The sync manifest exposes optimized MP4 asset metadata used for downloads:

- `fileSizeBytes`
- `width`
- `height`
- `durationSeconds`
- `quality`

## Checks

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project HappiE.xcodeproj -scheme HappiE -destination 'generic/platform=iOS Simulator' build
```

## Open Source Hygiene

Before publishing:

```bash
rg -n "/Users/|192\.168\.|DEVELOPMENT_TEAM|SECRET|PASSWORD|TOKEN|PRIVATE" .
find . -name "*.xcuserstate" -o -path "*/xcuserdata/*" -o -name ".DS_Store"
```

Expected results should be limited to documentation and intentional project configuration; the app contains no account credentials or authentication tokens.
