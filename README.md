# HappiE iPad App

<p align="center">
  <img src="HappiE/Assets.xcassets/AppIcon.appiconset/HappiE-AppIcon-1024.png" alt="HappiE app icon" width="128" height="128">
</p>

HappiE is the SwiftUI iPad client for the Heylo family video library. It signs in to the Heylo API, lets a child pick videos assigned by a parent, and plays videos in a kid-friendly full-screen player.

## Public Release Status

This Xcode project has been cleaned for public release:

- No personal Apple development team is required in project settings.
- Xcode `xcuserdata` is ignored and should not be committed.
- The API base URL is configurable through the `HAPPIE_API_BASE_URL` Info.plist value.
- The default API URL is `http://localhost:18080` for simulator development.
- App Transport Security allows local development without enabling arbitrary network loads globally.

## Local Setup

1. Start the Heylo backend from the web/API repository:

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

- Parent sign-in against the Heylo API.
- Child profile selection.
- Library sync from `POST /devices/:id/sync`.
- YouTube Kids-style full-screen player chrome.
- Native AirPlay route picker.
- Volume control.
- Offline-ready labels based on the server `download_priority`.

## Offline Downloads

The app currently displays which videos the server marks as required for offline use. Actual local file download, verification, playback from disk, and eviction are the next implementation steps.

The sync manifest already exposes optimized MP4 asset metadata:

- `fileSizeBytes`
- `width`
- `height`
- `durationSeconds`
- `quality`

Use those fields to enforce device storage quotas and show labels such as `Offline ready · 42 MB` once the local file exists.

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

Expected results should be limited to documentation and code reading auth headers or tokens from Keychain.
