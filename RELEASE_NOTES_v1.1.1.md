# Release Notes v1.1.1

## Date
2026-02-17

## Summary
Patch release focused on media cache telemetry integration with backend.

## What's New
- Player now reports local cached media IDs after media sync completes.
- Integrated endpoint call:
  - `POST /devices/{device_id}/media-cache-report`

## Why
- Enables CMS/backend to verify cache readiness per device (`ready/missing`) before critical runtime operations.

## Notes
- No breaking changes to existing playback, sync, or schedule behavior.

