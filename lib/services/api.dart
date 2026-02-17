import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/device_config.dart';

class ApiService {
  final String baseUrl;
  static const Duration _timeout = Duration(seconds: 8);
  static const List<Duration> _retryDelays = [
    Duration(milliseconds: 350),
    Duration(milliseconds: 900),
  ];

  ApiService(this.baseUrl);

  Uri _uri(String path, [Map<String, String>? queryParameters]) {
    final uri = Uri.parse(baseUrl).resolve(path);
    if (queryParameters == null || queryParameters.isEmpty) return uri;
    return uri.replace(
      queryParameters: {...uri.queryParameters, ...queryParameters},
    );
  }

  bool _isTransientError(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        error is HttpException;
  }

  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() call,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt <= _retryDelays.length; attempt++) {
      try {
        final res = await call().timeout(_timeout);
        if (res.statusCode >= 500 && attempt < _retryDelays.length) {
          await Future.delayed(_retryDelays[attempt]);
          continue;
        }
        return res;
      } catch (error) {
        lastError = error;
        if (!_isTransientError(error) || attempt >= _retryDelays.length) {
          rethrow;
        }
        await Future.delayed(_retryDelays[attempt]);
      }
    }
    throw Exception('Network request failed: $lastError');
  }

  Future<Map<String, dynamic>> registerDevice({
    required String name,
    required String location,
    String? orientation,
  }) async {
    final query = <String, String>{'name': name, 'location': location};
    if (orientation != null && orientation.isNotEmpty) {
      query['orientation'] = orientation;
    }
    final res = await _sendWithRetry(
      () => http.post(_uri('/devices/register', query)),
    );
    if (res.statusCode != 200) {
      throw Exception('Register failed: ${res.statusCode} ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<DeviceConfig> fetchConfig(String deviceId) async {
    final res = await _sendWithRetry(
      () => http.get(_uri('/devices/$deviceId/config')),
    );
    if (res.statusCode != 200) {
      throw Exception('Fetch config failed: ${res.statusCode}');
    }
    final data = jsonDecode(res.body);

    final media = (data['media'] as List).map((m) {
      return MediaItem(
        id: m['id'],
        type: m['type'],
        path: m['path'],
        checksum: m['checksum'],
        durationSec: m['duration_sec'],
        sizeBytes: (m['size'] as num?)?.toInt(),
      );
    }).toList();

    final playlists = (data['playlists'] as List).map((p) {
      final items = (p['items'] as List).map((i) {
        return PlaylistItemConfig(
          order: i['order'],
          mediaId: i['media_id'],
          durationSec: i['duration_sec'],
        );
      }).toList();
      items.sort((a, b) => a.order.compareTo(b.order));
      return PlaylistConfig(
        id: p['id'],
        name: (p['name'] ?? '').toString(),
        screenId: p['screen_id'],
        isFlashSale: p['is_flash_sale'] == true,
        flashNote: p['flash_note']?.toString(),
        flashCountdownSec: (p['flash_countdown_sec'] as num?)?.toInt(),
        flashItemsJson: p['flash_items_json']?.toString(),
        items: items,
      );
    }).toList();

    final screens = (data['screens'] as List).map((s) {
      final schedules = (s['schedules'] as List).map((sc) {
        return ScheduleConfig(
          dayOfWeek: sc['day_of_week'],
          startTime: sc['start_time'],
          endTime: sc['end_time'],
          playlistId: sc['playlist_id'],
          note: sc['note']?.toString(),
          countdownSec: (sc['countdown_sec'] as num?)?.toInt(),
        );
      }).toList();

      return ScreenConfig(
        screenId: s['screen_id'],
        name: s['name'],
        activePlaylistId: s['active_playlist_id']?.toString(),
        gridPreset: (s['grid_preset'] ?? '1x1').toString(),
        transitionDurationSec: (s['transition_duration_sec'] as num?)?.toInt(),
        schedules: schedules,
      );
    }).toList();

    final orientation = data['device'] != null
        ? data['device']['orientation'] as String?
        : null;
    final flashSaleRaw = data['flash_sale'];
    final flashSale = (flashSaleRaw is Map)
        ? FlashSaleConfig(
            enabled: flashSaleRaw['enabled'] == true,
            active: flashSaleRaw['active'] == true,
            note: flashSaleRaw['note']?.toString(),
            countdownSec: (flashSaleRaw['countdown_sec'] as num?)?.toInt(),
            productsJson: flashSaleRaw['products_json']?.toString(),
            scheduleDays: flashSaleRaw['schedule_days']?.toString(),
            scheduleStartTime: flashSaleRaw['schedule_start_time']?.toString(),
            scheduleEndTime: flashSaleRaw['schedule_end_time']?.toString(),
            runtimeStartAt: flashSaleRaw['runtime_start_at']?.toString(),
            runtimeEndAt: flashSaleRaw['runtime_end_at']?.toString(),
            countdownEndAt: flashSaleRaw['countdown_end_at']?.toString(),
            activatedAt: flashSaleRaw['activated_at']?.toString(),
            updatedAt: flashSaleRaw['updated_at']?.toString(),
          )
        : null;
    return DeviceConfig(
      deviceId: data['device_id'],
      media: media,
      playlists: playlists,
      screens: screens,
      flashSale: flashSale,
      orientation: orientation,
    );
  }

  Future<void> heartbeat(String deviceId) async {
    final res = await _sendWithRetry(
      () => http.post(_uri('/devices/$deviceId/heartbeat')),
    );
    if (res.statusCode != 200) {
      throw Exception('Heartbeat failed: ${res.statusCode}');
    }
  }

  Future<void> reportMediaCache({
    required String deviceId,
    required Iterable<String> mediaIds,
  }) async {
    final normalized = mediaIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final res = await _sendWithRetry(
      () => http.post(
        _uri('/devices/$deviceId/media-cache-report'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(normalized),
      ),
    );
    if (res.statusCode != 200) {
      throw Exception('Report media cache failed: ${res.statusCode}');
    }
  }

  Future<void> updateDeviceOrientation({
    required String deviceId,
    required String orientation,
  }) async {
    final res = await _sendWithRetry(
      () => http.put(_uri('/devices/$deviceId', {'orientation': orientation})),
    );
    if (res.statusCode != 200) {
      throw Exception('Update orientation failed: ${res.statusCode}');
    }
  }
}
