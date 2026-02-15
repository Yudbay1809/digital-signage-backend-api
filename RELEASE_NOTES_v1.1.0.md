# Release Notes v1.1.0 (2026-02-14)

## Summary
This release focuses on runtime stability for low-RAM signage devices, safer media handling, and smoother image transitions.

## Added
- Media Guard on player side to skip oversized media before playback.
- Crash Recovery Mode for repeated startup-crash sessions.
- Per-device Performance Profile in settings:
  - `low` (2GB RAM target)
  - `normal`
  - `high`

## Changed
- Image transition is re-enabled as lightweight fade only (`150-250ms`).
- Video transition remains direct-cut for playback stability.
- Device config media parsing now includes media `size` metadata.
- Android build stability improved by tuning Kotlin Gradle settings:
  - `kotlin.incremental=false`
  - `kotlin.incremental.useClasspathSnapshot=false`
  - `kotlin.compiler.execution.strategy=in-process`

## Fixed
- Resolved recurring Kotlin incremental cache warnings during Android release builds on Windows mixed-drive environments.
- Reduced frame-drop risk by balancing transition behavior and decode/cache budgets.

## Verification
- `flutter analyze` passed with no issues.
- `flutter build apk --release` succeeded.
- `flutter build windows --release` succeeded.

## Build Artifacts
- APK: `build/app/outputs/flutter-apk/app-release.apk`
- Windows: `build/windows/x64/runner/Release/`

