import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class CacheService {
  Future<Directory> _baseDir() async {
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${dir.path}/media_cache');
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }
    return cacheDir;
  }

  Future<File> getFileForPath(String path) async {
    final cleanPath = path.trim();
    final digest = sha1.convert(cleanPath.codeUnits).toString();
    final segments = cleanPath.split('/');
    final original = segments.isNotEmpty ? segments.last : 'media';
    final dot = original.lastIndexOf('.');
    final ext = dot > 0 ? original.substring(dot) : '';
    final filename = '$digest$ext';
    final dir = await _baseDir();
    return File('${dir.path}/$filename');
  }

  Future<bool> verifyChecksum(File file, String checksum) async {
    if (!file.existsSync()) return false;
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    return digest == checksum;
  }

  Future<void> cleanupCache(int maxBytes) async {
    final dir = await _baseDir();
    if (!dir.existsSync()) return;

    final files = dir.listSync().whereType<File>().toList();
    var total = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
    if (total <= maxBytes) return;

    files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    for (final f in files) {
      if (total <= maxBytes) break;
      final len = f.lengthSync();
      try {
        f.deleteSync();
        total -= len;
      } catch (_) {}
    }
  }
}
