# Digital Signage Player App

[![Flutter CI](https://github.com/Yudbay1809/digital-signage-backend-api/actions/workflows/flutter-ci.yml/badge.svg)](https://github.com/Yudbay1809/digital-signage-backend-api/actions/workflows/flutter-ci.yml)
![Platform](https://img.shields.io/badge/platform-Android-success)
![Flutter](https://img.shields.io/badge/Flutter-3.38.x-blue)
![License](https://img.shields.io/badge/license-MIT-informational)

Flutter-based digital signage player application.  
This app is designed for unattended screens with playlist sync, local caching, and full-screen playback.

## Highlights

- Device registration flow with server base URL configuration
- Playlist sync and local media caching
- Realtime updates via websocket channel with fallback polling
- Full-screen immersive playback mode
- Keep-awake behavior for always-on display usage
- Device-level Flash Sale overlay campaign (independent from playlist)
- Flash Sale product cards driven by campaign `products_json` + `media_id`
- Flash Sale countdown/note sourced from campaign runtime in device config

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

- Flutter `3.38.x` (stable channel)
- Dart `3.10.x`
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

## Security

If you discover a security issue, please follow the reporting process in `SECURITY.md`.

## Contributing

Contributions are welcome. Please read `CONTRIBUTING.md` before opening a Pull Request.

## License

This project is licensed under the MIT License. See `LICENSE`.
