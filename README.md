# Digital Signage Player App

[![Flutter CI](https://github.com/Yudbay1809/digital-signage-backend-api/actions/workflows/flutter-ci.yml/badge.svg)](https://github.com/Yudbay1809/digital-signage-backend-api/actions/workflows/flutter-ci.yml)
![Platform](https://img.shields.io/badge/platform-Android-success)
![Flutter](https://img.shields.io/badge/Flutter-3.38.x-blue)
![License](https://img.shields.io/badge/license-MIT-informational)

Flutter-based digital signage player application.  
This app is designed for unattended screens with playlist sync, local caching, and full-screen playback.

## Final Release Notes
- Analyzer warning cleanup completed (no remaining `flutter analyze` issues).
- Verified end-to-end against backend final contract (`/devices/{id}/config`, websocket refresh flow).
- Player works with normalized media URL path from backend (`/storage/media/<file>`).

## Highlights

- Device registration flow with server base URL configuration
- Playlist sync and local media caching
- Realtime updates via websocket channel with fallback polling
- Full-screen immersive playback mode
- Keep-awake behavior for always-on display usage
- Device-level Flash Sale overlay campaign (independent from playlist)
- Flash Sale product cards driven by campaign `products_json` + `media_id`
- Flash Sale countdown/note sourced from campaign runtime in device config
- Smooth auto-scrolling Flash Sale cards when product count is more than 5
- Smooth running text banner optimized for TV playback
- Countdown parser hardened for UTC/naive timestamp variants from backend
- Supports static server base URL setup (recommended for production LAN deployment)

## Tech Stack

- Flutter / Dart
- `video_player`
- `http`
- `shared_preferences`
- `path_provider`
- `wakelock_plus`

## Project Structure

```text
lib/
  main.dart                 # App entry + orchestration
  models/                   # Data models (device config, playback items)
  services/                 # API, sync, cache services
  player/                   # Playlist playback implementation
test/
  widget_test.dart
```

## Getting Started

### Prerequisites

- Flutter stable (`3.38+`)
- Dart (`3.10+`)
- Android SDK (for Android build target)

### Run Locally

```bash
flutter pub get
flutter run
```

### Run Quality Checks

```bash
flutter analyze
flutter test
```

## CI

GitHub Actions workflow runs:

- `flutter pub get`
- `flutter analyze`
- `flutter test`

See: `.github/workflows/flutter-ci.yml`

## Flash Sale Runtime
- Player reads `flash_sale` from `GET /devices/{device_id}/config`.
- Overlay activates when campaign `active=true`.
- Supports:
  - running text from `note`
  - countdown from `countdown_sec`/`countdown_end_at`
  - product cards from `products_json` with media preview fallback

## Build Release APK
```bash
flutter build apk --release
```

Output:
- `build/app/outputs/flutter-apk/app-release.apk`

## Build Release Windows (Smoke)
```bash
flutter build windows --release
```

Output:
- `build/windows/x64/runner/Release/digital_signage_backend_api.exe`

## Maintainer
- Yudbay1809

## Security

If you discover a security issue, please follow the reporting process in `SECURITY.md`.

## Contributing

Contributions are welcome. Please read `CONTRIBUTING.md` before opening a Pull Request.

## License

This project is licensed under the MIT License. See `LICENSE`.
