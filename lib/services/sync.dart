import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/device_config.dart';
import 'cache.dart';

class SyncRunResult {
  final Map<String, String> localMap;
  final List<String> completedIds;
  final List<Map<String, dynamic>> failedItems;
  final int downloadedBytes;

  const SyncRunResult({
    required this.localMap,
    required this.completedIds,
    required this.failedItems,
    required this.downloadedBytes,
  });
}

class SyncService {
  final String baseUrl;
  final CacheService cache;
  final int maxCacheBytes;
  final int maxImageBytes;
  final int maxVideoBytes;

  SyncService({
    required this.baseUrl,
    required this.cache,
    required this.maxCacheBytes,
    required this.maxImageBytes,
    required this.maxVideoBytes,
  });

  Future<http.Response> _downloadWithRetry(Uri uri) async {
    const timeout = Duration(seconds: 12);
    const delays = [Duration(milliseconds: 500), Duration(milliseconds: 1200)];
    Object? lastError;
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      try {
        final res = await http.get(uri).timeout(timeout);
        if (res.statusCode == 200) return res;
        if (res.statusCode >= 500 && attempt < delays.length) {
          await Future.delayed(delays[attempt]);
          continue;
        }
        return res;
      } catch (error) {
        lastError = error;
        final transient =
            error is TimeoutException ||
            error is SocketException ||
            error is HttpException;
        if (!transient || attempt >= delays.length) rethrow;
        await Future.delayed(delays[attempt]);
      }
    }
    throw Exception('Download failed: $lastError');
  }

  Future<SyncRunResult> syncMediaDetailed(
    List<MediaItem> media, {
    void Function(int done, int total, MediaItem item)? onItemProcessed,
  }) async {
    final result = <String, String>{};
    final completedIds = <String>[];
    final failedItems = <Map<String, dynamic>>[];
    var downloadedBytes = 0;
    var done = 0;
    final total = media.length;

    for (final m in media) {
      final size = m.sizeBytes ?? 0;
      final isImage = m.type == 'image';
      final isVideo = m.type == 'video';
      if (isImage && size > maxImageBytes) {
        final stale = await cache.getFileForPath(m.path);
        if (stale.existsSync()) {
          try {
            stale.deleteSync();
          } catch (_) {}
        }
        failedItems.add({
          'media_id': m.id,
          'error': 'image_too_large',
          'retry_count': 0,
        });
        done += 1;
        onItemProcessed?.call(done, total, m);
        continue;
      }
      if (isVideo && size > maxVideoBytes) {
        final stale = await cache.getFileForPath(m.path);
        if (stale.existsSync()) {
          try {
            stale.deleteSync();
          } catch (_) {}
        }
        failedItems.add({
          'media_id': m.id,
          'error': 'video_too_large',
          'retry_count': 0,
        });
        done += 1;
        onItemProcessed?.call(done, total, m);
        continue;
      }
      final file = await cache.getFileForPath(m.path);
      final hasChecksum = m.checksum.trim().isNotEmpty;
      final ok = hasChecksum
          ? await cache.verifyChecksum(file, m.checksum)
          : file.existsSync();
      if (!ok) {
        final url = _absoluteUrl(m.path);
        try {
          final res = await _downloadWithRetry(Uri.parse(url));
          if (res.statusCode == 200) {
            await file.writeAsBytes(res.bodyBytes, flush: true);
            downloadedBytes += (m.sizeBytes ?? res.bodyBytes.length);
          } else {
            failedItems.add({
              'media_id': m.id,
              'error': 'http_${res.statusCode}',
              'retry_count': 0,
            });
          }
        } catch (error) {
          failedItems.add({
            'media_id': m.id,
            'error': error.toString(),
            'retry_count': 0,
          });
        }
      }
      final validAfter = hasChecksum
          ? await cache.verifyChecksum(file, m.checksum)
          : file.existsSync();
      if (validAfter && file.existsSync()) {
        result[m.id] = file.path;
        completedIds.add(m.id);
      } else if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
        if (!failedItems.any((row) => row['media_id'] == m.id)) {
          failedItems.add({
            'media_id': m.id,
            'error': 'checksum_invalid_after_download',
            'retry_count': 0,
          });
        }
      }
      done += 1;
      onItemProcessed?.call(done, total, m);
    }

    await cache.cleanupCache(maxCacheBytes);
    return SyncRunResult(
      localMap: result,
      completedIds: completedIds,
      failedItems: failedItems,
      downloadedBytes: downloadedBytes,
    );
  }

  Future<Map<String, String>> syncMedia(List<MediaItem> media) async {
    final run = await syncMediaDetailed(media);
    return run.localMap;
  }

  String _absoluteUrl(String path) {
    final raw = path.trim();
    if (raw.isEmpty) return raw;
    final normalized = raw.replaceAll('\\', '/');
    if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
      final parsed = Uri.tryParse(normalized);
      return parsed?.toString() ?? normalized;
    }
    final base = Uri.tryParse(baseUrl);
    if (base == null) return normalized;
    final resolved = base.resolveUri(Uri(path: normalized));
    return resolved.toString();
  }
}
