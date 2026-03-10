# RELEASE NOTES v1.1.3

Tanggal: 2026-03-11

## Ringkasan
Patch ini fokus pada stabilitas playback di device RAM 2GB dengan guard otomatis, cache readiness gate, dan kontrol auto-promote.

## Perubahan Utama
- Auto Downgrade Guard + lock sementara jika FPS drop/crash/sync error berulang.
- Cache Readiness Gate untuk switch playlist (jika pending terlalu lama, otomatis downgrade).
- Stability Score + cooldown untuk menahan auto-promote saat stabilitas rendah.
- Max Performance Profile di Settings agar device tidak auto-upgrade ke `high`.

## Dampak
- Mengurangi force close dan black screen saat pergantian playlist.
- Stabilitas lebih konsisten pada device RAM kecil.
- Auto-upgrade tidak agresif lagi sehingga device tetap responsif.
