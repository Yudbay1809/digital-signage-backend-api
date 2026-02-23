# RELEASE NOTES v1.1.2

Tanggal: 2026-02-23

## Ringkasan
Patch ini mengintegrasikan Smart Media Sync ke player mobile/windows agar proses download media mengikuti prioritas dari backend dan melaporkan progress queue.

## Perubahan Utama
- Integrasi endpoint Smart Sync di API client:
  - fetch sync plan
  - report sync progress
  - ack sync ready
- Alur sinkronisasi media diperbarui:
  - membaca urutan plan dari backend
  - tetap memakai engine checksum/download yang sudah stabil
  - kirim progress status selama proses download
  - kirim ack saat ready
- `SyncService` ditingkatkan:
  - hasil detail (`completed`, `failed`, `downloaded bytes`)
  - kompatibel dengan flow lama (fallback aman tetap ada)
- Penyesuaian `android/gradle.properties` untuk stabilitas build release (OOM mitigation).

## Dampak
- Device melaporkan status queue lebih akurat ke backend.
- Pengunduhan media menjadi lebih terkontrol dan dapat dipantau CMS.
