import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/device_config.dart';
import 'cache.dart';

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

  Future<Map<String, String>> syncMedia(List<MediaItem> media) async {
    final result = <String, String>{};
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
        continue;
      }
      if (isVideo && size > maxVideoBytes) {
        final stale = await cache.getFileForPath(m.path);
        if (stale.existsSync()) {
          try {
            stale.deleteSync();
          } catch (_) {}
        }
        continue;
      }
      final file = await cache.getFileForPath(m.path);
      final hasChecksum = m.checksum.trim().isNotEmpty;
      final ok = hasChecksum
          ? await cache.verifyChecksum(file, m.checksum)
          : file.existsSync();
      if (!ok) {
        final url = _absoluteUrl(m.path);
        final res = await _downloadWithRetry(Uri.parse(url));
        if (res.statusCode == 200) {
          await file.writeAsBytes(res.bodyBytes, flush: true);
        }
      }
      final validAfter = hasChecksum
          ? await cache.verifyChecksum(file, m.checksum)
          : file.existsSync();
      if (validAfter && file.existsSync()) {
        result[m.id] = file.path;
      } else if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    }
    await cache.cleanupCache(maxCacheBytes);
    return result;
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
