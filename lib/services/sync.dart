import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/device_config.dart';
import 'cache.dart';

class SyncRunResult {
  final Map<String, String> localMap;
  final List<String> lowReadyIds;
  final List<String> completedIds;
  final List<String> highReadyIds;
  final List<Map<String, dynamic>> failedItems;
  final int downloadedBytes;

  const SyncRunResult({
    required this.localMap,
    required this.lowReadyIds,
    required this.completedIds,
    required this.highReadyIds,
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
    bool allowHighTierUpgrades = false,
  }) async {
    final result = <String, String>{};
    final lowReadyIds = <String>[];
    final completedIds = <String>[];
    final highReadyIds = <String>[];
    final failedItems = <Map<String, dynamic>>[];
    var downloadedBytes = 0;
    var done = 0;
    final total = media.length;

    for (final m in media) {
      final size = m.sizeBytes ?? 0;
      final isImage = m.type == 'image';
      final isVideo = m.type == 'video';
      if (isVideo && size > maxVideoBytes) {
        final targetPath = m.displayPath.trim().isNotEmpty
            ? m.displayPath
            : m.path;
        final stale = await cache.getFileForPath(targetPath);
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

      final lowPath = (m.thumbPath.trim().isNotEmpty ? m.thumbPath : m.path);
      final normalPath = (m.displayPath.trim().isNotEmpty
          ? m.displayPath
          : m.path);
      final highPath = (m.highPath.trim().isNotEmpty ? m.highPath : normalPath);

      String? bestLocalPath;

      // Stage 1: LOW for fast-first render.
      final lowFile = await cache.getFileForPath(lowPath);
      if (!lowFile.existsSync()) {
        final lowUrl = _absoluteUrl(lowPath);
        try {
          final res = await _downloadWithRetry(Uri.parse(lowUrl));
          if (res.statusCode == 200) {
            await lowFile.writeAsBytes(res.bodyBytes, flush: true);
            downloadedBytes += res.bodyBytes.length;
          }
        } catch (_) {
          // LOW is best-effort. Continue to NORMAL stage.
        }
      }
      if (lowFile.existsSync()) {
        bestLocalPath = lowFile.path;
        if (!lowReadyIds.contains(m.id)) {
          lowReadyIds.add(m.id);
        }
      }

      // Stage 2: NORMAL determines server-ready status.
      final hasChecksum = m.checksum.trim().isNotEmpty;
      final normalFile = await cache.getFileForPath(normalPath);
      final normalAllowed = !isImage || size <= 0 || size <= maxImageBytes;
      var normalReady = false;
      if (!normalAllowed) {
        failedItems.add({
          'media_id': m.id,
          'error': 'image_too_large',
          'retry_count': 0,
        });
      } else {
        normalReady = hasChecksum
            ? await cache.verifyChecksum(normalFile, m.checksum)
            : normalFile.existsSync();
        if (!normalReady) {
          final normalUrl = _absoluteUrl(normalPath);
          try {
            final res = await _downloadWithRetry(Uri.parse(normalUrl));
            if (res.statusCode == 200) {
              await normalFile.writeAsBytes(res.bodyBytes, flush: true);
              downloadedBytes += (m.sizeBytes ?? res.bodyBytes.length);
            } else {
              failedItems.add({
                'media_id': m.id,
                'error': 'normal_http_${res.statusCode}',
                'retry_count': 0,
              });
            }
          } catch (error) {
            failedItems.add({
              'media_id': m.id,
              'error': 'normal_${error.toString()}',
              'retry_count': 0,
            });
          }
        }
        normalReady = hasChecksum
            ? await cache.verifyChecksum(normalFile, m.checksum)
            : normalFile.existsSync();
        if (normalReady && normalFile.existsSync()) {
          bestLocalPath = normalFile.path;
          if (!completedIds.contains(m.id)) {
            completedIds.add(m.id);
          }
        } else if (normalFile.existsSync() && hasChecksum) {
          try {
            normalFile.deleteSync();
          } catch (_) {}
          if (!failedItems.any((row) => row['media_id'] == m.id)) {
            failedItems.add({
              'media_id': m.id,
              'error': 'checksum_invalid_after_download',
              'retry_count': 0,
            });
          }
        }
      }

      // Stage 3: HIGH quality opportunistic upgrade.
      if (allowHighTierUpgrades &&
          isImage &&
          normalReady &&
          highPath.trim() != normalPath.trim()) {
        final highFile = await cache.getFileForPath(highPath);
        if (!highFile.existsSync()) {
          final highUrl = _absoluteUrl(highPath);
          try {
            final res = await _downloadWithRetry(Uri.parse(highUrl));
            if (res.statusCode == 200) {
              await highFile.writeAsBytes(res.bodyBytes, flush: true);
              downloadedBytes += res.bodyBytes.length;
            }
          } catch (_) {
            // HIGH is optional; ignore failures.
          }
        }
        if (highFile.existsSync()) {
          bestLocalPath = highFile.path;
          if (!highReadyIds.contains(m.id)) {
            highReadyIds.add(m.id);
          }
        }
      }

      if (bestLocalPath != null && bestLocalPath.trim().isNotEmpty) {
        result[m.id] = bestLocalPath;
      }

      done += 1;
      onItemProcessed?.call(done, total, m);
    }

    await cache.cleanupCache(maxCacheBytes);
    return SyncRunResult(
      localMap: result,
      lowReadyIds: lowReadyIds,
      completedIds: completedIds,
      highReadyIds: highReadyIds,
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
