# HappiE iPad App

<p align="center">
  <img src="HappiE/Assets.xcassets/AppIcon.appiconset/HappiE-AppIcon-1024.png" alt="HappiE app icon" width="128" height="128">
</p>

HappiE is the SwiftUI iPad client for the HappiE family video library. It connects directly to the LAN-local HappiE API without an account login, lets a child pick videos assigned by a parent, and plays videos in a kid-friendly full-screen player.

## Public Release Status

This Xcode project has been cleaned for public release:

- No personal Apple development team is required in project settings.
- Xcode `xcuserdata` is ignored and should not be committed.
- The API base URL is configurable from Settings, with `HAPPIE_API_BASE_URL` as the default Info.plist value.
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

- Unauthenticated access to the LAN-local HappiE API.
- Child profile selection.
- Library sync from `POST /devices/:id/sync`.
- YouTube Kids-style full-screen player chrome.
- Native AirPlay route picker.
- Volume control.
- Cached library metadata and automatic offline downloads based on the server `download_priority`.

## Offline Downloads

The app caches the last child list, selected profile, device id, and sync manifest. A cached library opens immediately and refreshes in the background; if the backend is unavailable, the app remains in the saved library instead of blocking on network access.

Videos marked `required` or `normal` are downloaded automatically. Playback always prefers the downloaded file, so those videos continue working without the backend. Online-only videos still need the backend to return a playback URL. Changing the configured server clears metadata and downloaded assets from the previous server to prevent libraries from being mixed.

The sync manifest already exposes optimized MP4 asset metadata:

- `fileSizeBytes`
- `width`
- `height`
- `durationSeconds`
- `quality`

The app uses the local asset index to show `Offline ready` once a downloaded video exists.

## Checks

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project HappiE.xcodeproj -scheme HappiE -destination 'generic/platform=iOS Simulator' build
```

## Open Source Hygiene

Before publishing:

```bash
rg -n "/Users/|192\\.168\\.|DEVELOPMENT_TEAM|SECRET|PASSWORD|TOKEN|PRIVATE" .
find . -name "*.xcuserstate" -o -path "*/xcuserdata/*" -o -name ".DS_Store"
```

Expected results should be limited to documentation and intentional project configuration; the app contains no account credentials or authentication tokens.
