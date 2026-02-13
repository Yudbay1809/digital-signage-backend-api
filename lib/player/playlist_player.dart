import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/playback_item.dart';

class PlaylistPlayer extends StatefulWidget {
  final List<PlaybackItem> items;
  final String syncKey;
  final int transitionDurationSec;

  const PlaylistPlayer({
    super.key,
    required this.items,
    required this.syncKey,
    this.transitionDurationSec = 1,
  });

  @override
  State<PlaylistPlayer> createState() => _PlaylistPlayerState();
}

class _PlaylistPlayerState extends State<PlaylistPlayer> {
  static const Duration _cacheReadyHold = Duration(seconds: 3);

  int _index = 0;
  Timer? _timer;
  VideoPlayerController? _videoController;
  String? _videoBoundItemId;
  VideoPlayerController? _nextVideoController;
  String? _nextVideoBoundItemId;
  bool _prewarming = false;
  bool _syncing = false;
  String _lastItemsSignature = '';
  String? _pendingUnreadyItemId;
  DateTime? _pendingUnreadySince;

  PlaybackItem get _current => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _lastItemsSignature = _itemsSignature(widget.items);
    _startSyncLoop();
  }

  @override
  void didUpdateWidget(covariant PlaylistPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextItemsSignature = _itemsSignature(widget.items);
    final itemsChanged = nextItemsSignature != _lastItemsSignature;
    if (itemsChanged || oldWidget.syncKey != widget.syncKey) {
      _lastItemsSignature = nextItemsSignature;
      _pendingUnreadyItemId = null;
      _pendingUnreadySince = null;
      _index = 0;
      unawaited(_disposeNextController());
      _startSyncLoop();
    }
  }

  String _itemsSignature(List<PlaybackItem> items) {
    return items
        .map(
          (item) =>
              '${item.id}|${item.type}|${item.url}|${item.durationSec}|${item.localPath ?? ''}',
        )
        .join(';');
  }

  void _startSyncLoop() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _syncToTimeline());
    _syncToTimeline(force: true);
  }

  int _timelineSeed() {
    var seed = 0;
    for (final unit in widget.syncKey.codeUnits) {
      seed = ((seed * 31) + unit) & 0x7fffffff;
    }
    return seed;
  }

  ({int index, int offsetSec, int remainingSec})? _timelineSnapshot() {
    if (widget.items.isEmpty) return null;
    final durations = widget.items
        .map((item) => item.durationSec < 1 ? 1 : item.durationSec)
        .toList();
    final total = durations.fold<int>(0, (sum, value) => sum + value);
    if (total <= 0) return null;

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final seed = _timelineSeed() % total;
    final phase = (nowSec + seed) % total;

    var cursor = 0;
    for (var i = 0; i < durations.length; i++) {
      final span = durations[i];
      if (phase < cursor + span) {
        final offset = phase - cursor;
        return (
          index: i,
          offsetSec: offset,
          remainingSec: span - offset,
        );
      }
      cursor += span;
    }

    return (
      index: 0,
      offsetSec: 0,
      remainingSec: durations.first,
    );
  }

  bool _hasLocalFile(PlaybackItem item) {
    final local = (item.localPath ?? '').trim();
    if (local.isEmpty) return false;
    return File(local).existsSync();
  }

  bool _canSwitchToItem(PlaybackItem target) {
    if (target.type != 'video') {
      _pendingUnreadyItemId = null;
      _pendingUnreadySince = null;
      return true;
    }
    if (_hasLocalFile(target)) {
      _pendingUnreadyItemId = null;
      _pendingUnreadySince = null;
      return true;
    }

    final now = DateTime.now();
    if (_pendingUnreadyItemId != target.id) {
      _pendingUnreadyItemId = target.id;
      _pendingUnreadySince = now;
      return false;
    }
    if (_pendingUnreadySince == null) {
      _pendingUnreadySince = now;
      return false;
    }
    return now.difference(_pendingUnreadySince!) >= _cacheReadyHold;
  }

  int _nextIndexOf(int index) {
    if (widget.items.isEmpty) return 0;
    return (index + 1) % widget.items.length;
  }

  Future<void> _disposeNextController() async {
    final next = _nextVideoController;
    _nextVideoController = null;
    _nextVideoBoundItemId = null;
    if (next != null) {
      await next.dispose();
    }
  }

  Future<VideoPlayerController?> _createVideoController(
    PlaybackItem item, {
    required int offsetSec,
    required bool autoplay,
  }) async {
    final candidates = <VideoPlayerController>[];
    final local = (item.localPath ?? '').trim();
    if (local.isNotEmpty && File(local).existsSync()) {
      candidates.add(VideoPlayerController.file(File(local)));
    }
    candidates.add(VideoPlayerController.networkUrl(Uri.parse(item.url)));

    for (var i = 0; i < candidates.length; i++) {
      final controller = candidates[i];
      try {
        await controller.initialize().timeout(const Duration(seconds: 10));
        final maxSeek = controller.value.duration.inSeconds > 0
            ? controller.value.duration.inSeconds - 1
            : 0;
        final safeOffset = offsetSec.clamp(0, maxSeek);
        if (safeOffset > 0) {
          await controller.seekTo(Duration(seconds: safeOffset));
        }
        if (autoplay) {
          await controller.play();
        } else {
          await controller.pause();
        }
        for (var j = i + 1; j < candidates.length; j++) {
          await candidates[j].dispose();
        }
        return controller;
      } catch (_) {
        await controller.dispose();
      }
    }
    return null;
  }

  Future<void> _prewarmNextVideoController({int? fromIndex}) async {
    if (widget.items.isEmpty || _prewarming) return;
    final baseIndex = fromIndex ?? _index;
    final nextIndex = _nextIndexOf(baseIndex);
    final nextItem = widget.items[nextIndex];

    if (nextItem.type != 'video') {
      await _disposeNextController();
      return;
    }
    if (_nextVideoBoundItemId == nextItem.id &&
        _nextVideoController != null &&
        _nextVideoController!.value.isInitialized) {
      return;
    }

    _prewarming = true;
    try {
      await _disposeNextController();
      final controller = await _createVideoController(
        nextItem,
        offsetSec: 0,
        autoplay: false,
      );
      if (controller != null) {
        _nextVideoController = controller;
        _nextVideoBoundItemId = nextItem.id;
      }
    } finally {
      _prewarming = false;
    }
  }

  Future<bool> _prepareIndexAtOffset(int targetIndex, int offsetSec) async {
    if (widget.items.isEmpty) return false;
    final item = widget.items[targetIndex];

    if (item.type == 'video') {
      final previous = _videoController;
      VideoPlayerController? activated;

      if (_nextVideoBoundItemId == item.id &&
          _nextVideoController != null &&
          _nextVideoController!.value.isInitialized) {
        activated = _nextVideoController;
        _nextVideoController = null;
        _nextVideoBoundItemId = null;
        final maxSeek = activated!.value.duration.inSeconds > 0
            ? activated.value.duration.inSeconds - 1
            : 0;
        final safeOffset = offsetSec.clamp(0, maxSeek);
        if (safeOffset > 0) {
          await activated.seekTo(Duration(seconds: safeOffset));
        }
        await activated.play();
      } else {
        activated = await _createVideoController(
          item,
          offsetSec: offsetSec,
          autoplay: true,
        );
      }

      if (activated == null) {
        return false;
      }

      _videoController = activated;
      _videoBoundItemId = item.id;
      _index = targetIndex;
      if (previous != null && !identical(previous, activated)) {
        await previous.dispose();
      }
      unawaited(_prewarmNextVideoController(fromIndex: targetIndex));
      return true;
    }

    final previous = _videoController;
    _videoController = null;
    _videoBoundItemId = null;
    _index = targetIndex;
    if (previous != null) {
      await previous.dispose();
    }
    unawaited(_prewarmNextVideoController(fromIndex: targetIndex));
    return true;
  }

  Future<void> _syncToTimeline({bool force = false}) async {
    if (_syncing) return;
    _syncing = true;
    try {
      final snap = _timelineSnapshot();
      if (snap == null) {
        await _videoController?.dispose();
        _videoController = null;
        _videoBoundItemId = null;
        await _disposeNextController();
        if (mounted) setState(() {});
        return;
      }

      final targetIndex = snap.index;
      final switchingIndex = targetIndex != _index;
      if (switchingIndex &&
          _videoController != null &&
          !_canSwitchToItem(widget.items[targetIndex])) {
        unawaited(_prewarmNextVideoController(fromIndex: targetIndex));
        return;
      }

      final mustPrepare = force ||
          switchingIndex ||
          (_videoController == null && _current.type == 'video');
      if (mustPrepare) {
        final prepared = await _prepareIndexAtOffset(targetIndex, snap.offsetSec);
        if (prepared && mounted) {
          setState(() {});
        }
        return;
      }

      if (_current.type == 'video' &&
          _videoController != null &&
          _videoController!.value.isInitialized) {
        final currentPos = _videoController!.value.position.inSeconds;
        if ((currentPos - snap.offsetSec).abs() > 2) {
          await _videoController!.seekTo(Duration(seconds: snap.offsetSec));
        }
      }
      unawaited(_prewarmNextVideoController());
    } finally {
      _syncing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _videoController?.dispose();
    _videoBoundItemId = null;
    unawaited(_disposeNextController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const Center(
        child: Text('No playlist items', style: TextStyle(color: Colors.white)),
      );
    }

    final item = _current;
    Widget content;
    if (item.type == 'video' &&
        _videoController != null &&
        _videoBoundItemId == item.id &&
        _videoController!.value.isInitialized &&
        _videoController!.value.size.width > 0 &&
        _videoController!.value.size.height > 0) {
      content = FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: _videoController!.value.size.width,
          height: _videoController!.value.size.height,
          child: VideoPlayer(_videoController!),
        ),
      );
    } else if (item.type == 'video') {
      content = const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    } else if (item.type == 'image') {
      final ImageProvider provider;
      if (item.localPath != null && item.localPath!.trim().isNotEmpty) {
        provider = ResizeImage(
          FileImage(File(item.localPath!)),
          width: 1920,
        );
      } else {
        provider = ResizeImage(
          NetworkImage(item.url),
          width: 1920,
        );
      }
      content = SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.contain,
          child: Image(
            image: provider,
            filterQuality: FilterQuality.low,
            errorBuilder: (context, error, stackTrace) {
              return const SizedBox(
                width: 420,
                height: 240,
                child: Center(
                  child: Text(
                    'Gagal memuat gambar',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              );
            },
          ),
        ),
      );
    } else {
      content = Center(
        child: Text(
          item.id,
          style: const TextStyle(color: Colors.white, fontSize: 22),
        ),
      );
    }

    final transitionMillis = widget.transitionDurationSec.clamp(0, 30) * 1000;
    // Keep video transition as direct cut to avoid decode+fade spikes.
    if (transitionMillis <= 0 || item.type == 'video') {
      return SizedBox.expand(
        child: KeyedSubtree(
          key: ValueKey('$_index-${item.id}'),
          child: content,
        ),
      );
    }

    return SizedBox.expand(
      child: AnimatedSwitcher(
        duration: Duration(milliseconds: transitionMillis),
        switchInCurve: Curves.easeInOut,
        switchOutCurve: Curves.easeInOut,
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: KeyedSubtree(
          key: ValueKey('$_index-${item.id}'),
          child: content,
        ),
      ),
    );
  }
}
