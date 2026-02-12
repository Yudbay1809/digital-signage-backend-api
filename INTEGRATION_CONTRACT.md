# Integration Contract: CMS <-> Backend <-> Player

Dokumen ini merangkum kontrak integrasi utama antara:
- `cms_signage_desktop` (operator CMS)
- `app` (FastAPI backend)
- `digital-signage-backend-api` (Flutter player Android)

## 1. Peran Sistem
- CMS: membuat/mengubah konten dan konfigurasi.
- Backend: sumber data utama (single source of truth), API, penyimpanan media, realtime event.
- Player: register device, sinkronisasi config/media, pemutaran konten layar.

## 2. Endpoint Backend Wajib

### Discovery dan health
- `GET /healthz`
- `GET /server-info`
- `GET /` (info dasar layanan)

### Device lifecycle
- `POST /devices/register`
- `POST /devices/{device_id}/heartbeat`
- `GET /devices`
- `PUT /devices/{device_id}` (orientation, dll)
- `DELETE /devices/{device_id}`
- `GET /devices/{device_id}/config` (payload utama untuk player)

### Media
- `POST /media/upload`
- `GET /media`
- `GET /media/page`
- `GET /media/{media_id}`
- `DELETE /media/{media_id}`
- `POST /media/upload-to-playlist` (opsional)

### Playlist
- `POST /playlists`
- `GET /playlists?screen_id=...`
- `PUT /playlists/{playlist_id}`
- `DELETE /playlists/{playlist_id}`
- `POST /playlists/{playlist_id}/items`
- `GET /playlists/{playlist_id}/items`
- `PUT /playlists/items/{item_id}`
- `DELETE /playlists/items/{item_id}`

### Schedule
- `POST /schedules`
- `GET /schedules?screen_id=...`
- `PUT /schedules/{schedule_id}`
- `DELETE /schedules/{schedule_id}`

### Screen/layout
- `POST /screens`
- `GET /screens?device_id=...`
- `PUT /screens/{screen_id}` (`active_playlist_id`, `grid_preset`, `transition_duration_sec`)
- `DELETE /screens/{screen_id}`

### Flash Sale (device-level, prioritas)
- `GET /flash-sale/device/{device_id}`
- `PUT /flash-sale/device/{device_id}/now`
- `PUT /flash-sale/device/{device_id}/schedule`
- `DELETE /flash-sale/device/{device_id}`

### Realtime
- `WS /ws/updates`
- Event utama:
  - `config_changed`
  - `device_status_changed`

## 3. Kontrak Payload Kritis

### 3.1 Register Device response (minimum)
Player/CMS mengandalkan field:
- `id` (device_id)
- `name`
- `location`
- `status`
- `orientation`

### 3.2 Device Config (`GET /devices/{device_id}/config`)
Response minimum yang harus stabil:
- `device_id`
- `device`
  - `id`, `name`, `location`, `orientation`
- `screens[]`
  - `screen_id`, `name`, `active_playlist_id`, `grid_preset`, `transition_duration_sec`, `schedules[]`
- `playlists[]`
  - `id`, `name`, `screen_id`, `items[]`
- `media[]`
  - `id`, `type`, `path`, `checksum`, `duration_sec`
- `flash_sale` (nullable)
  - `enabled`, `active`, `note`, `countdown_sec`, `products_json`
  - `runtime_start_at`, `runtime_end_at`, `countdown_end_at`

### 3.3 Media URL
- `media.path` dikembalikan sebagai path relatif (contoh: `/storage/media/file.jpg`).
- Player membentuk URL absolut: `{baseUrl}{path}`.
- Backend wajib expose static files pada prefix `/storage`.

## 4. Urutan Sinkronisasi Runtime

### 4.1 CMS -> Backend
1. Operator ubah konten/konfigurasi via CMS.
2. CMS panggil endpoint REST terkait.
3. Backend commit perubahan DB.
4. Middleware backend publish event websocket `config_changed`.

### 4.2 Player startup
1. Player menemukan base URL (`/server-info` atau `/healthz`).
2. Player `register` device jika belum punya `device_id`.
3. Player fetch `GET /devices/{device_id}/config`.
4. Player sinkronisasi file media lokal berdasarkan `path + checksum`.
5. Player render playlist aktif/scheduled.

### 4.3 Player runtime
1. Heartbeat periodik ke `/devices/{device_id}/heartbeat`.
2. Subscribe `WS /ws/updates` untuk trigger sync cepat.
3. Tetap polling fallback periodik jika websocket putus.
4. Saat config berubah, player fetch config ulang dan apply delta (playlist/grid/flash sale).

## 5. Aturan Perilaku yang Disepakati

### Playlist selection
- Prioritas pemilihan playlist di player:
1. `screen.active_playlist_id` jika valid.
2. schedule aktif saat ini (`day_of_week`, `start_time`, `end_time`).
3. fallback playlist pertama pada screen.

### Schedule constraints
- Backend menolak overlap schedule pada screen+day yang sama.
- `start_time` harus < `end_time`.

### Grid dan orientation
- `grid_preset` format `NxM`, rentang 1..4.
- Device landscape: `cols >= rows`.
- Device portrait: `rows >= cols`.
- `transition_duration_sec` rentang 0..30.

### Flash Sale
- Mode utama: device-level campaign (`/flash-sale/device/*`).
- Saat `flash_sale.active=true`, player tampilkan overlay/campaign runtime.
- `products_json` harus valid JSON array dan semua `media_id` harus terdaftar di tabel media.

## 6. Error Handling Kontrak
- Unauthorized: `401` (jika `SIGNAGE_API_KEY` aktif dan header `X-API-Key` tidak cocok).
- Not found: `404` untuk resource tidak ada.
- Validation: `400/422` untuk payload tidak valid.
- Player/CMS harus menampilkan pesan error backend apa adanya untuk troubleshooting.

## 7. Header dan Auth
- Jika backend API key diaktifkan (`SIGNAGE_API_KEY`), klien wajib kirim:
  - `X-API-Key: <key>`
- Ownership/account boundary (device owner) dapat menggunakan:
  - `X-Account-ID` atau fallback `X-API-Key` (sesuai implementasi backend).

## 8. Kompatibilitas dan Depresiasi
- Field playlist-level flash sale (`is_flash_sale`, `flash_note`, `flash_countdown_sec`, `flash_items_json`) masih ada untuk kompatibilitas.
- Integrasi baru disarankan memakai device-level flash sale (`flash_sale` pada config device).
- Jika kelak playlist-level flash sale dihapus, pastikan player/CMS sudah tidak bergantung pada field legacy.

## 9. Checklist Smoke Test Integrasi
1. CMS berhasil auto-discover backend (`/server-info`).
2. Device register dan muncul di `GET /devices`.
3. Upload media berhasil, file tersedia di `/storage/...`.
4. Buat playlist + item, dan terlihat di config device.
5. Set grid + transition, lalu player menyesuaikan tampilan.
6. Buat schedule tanpa overlap, player switch playlist sesuai waktu.
7. Publish flash sale now/schedule, player menampilkan overlay.
8. Websocket event memicu refresh CMS/player tanpa restart app.
