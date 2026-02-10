import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/playback_item.dart';

class PlaylistPlayer extends StatefulWidget {
  final List<PlaybackItem> items;
  final String syncKey;

  const PlaylistPlayer({super.key, required this.items, required this.syncKey});

  @override
  State<PlaylistPlayer> createState() => _PlaylistPlayerState();
}

class _PlaylistPlayerState extends State<PlaylistPlayer> {
  int _index = 0;
  Timer? _timer;
  VideoPlayerController? _videoController;
  bool _syncing = false;

  PlaybackItem get _current => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _startSyncLoop();
  }

  @override
  void didUpdateWidget(covariant PlaylistPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items || oldWidget.syncKey != widget.syncKey) {
      _index = 0;
      _startSyncLoop();
    }
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
    final durations = widget.items.map((item) => item.durationSec < 1 ? 1 : item.durationSec).toList();
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

  Future<void> _syncToTimeline({bool force = false}) async {
    if (_syncing) return;
    _syncing = true;
    try {
      final snap = _timelineSnapshot();
      if (snap == null) {
        await _videoController?.dispose();
        _videoController = null;
        if (mounted) setState(() {});
        return;
      }

      final mustPrepare = force || snap.index != _index || _videoController == null && _current.type == 'video';
      if (mustPrepare) {
        _index = snap.index;
        await _prepareCurrentAtOffset(snap.offsetSec);
        if (mounted) setState(() {});
        return;
      }

      if (_current.type == 'video' && _videoController != null && _videoController!.value.isInitialized) {
        final currentPos = _videoController!.value.position.inSeconds;
        if ((currentPos - snap.offsetSec).abs() > 2) {
          await _videoController!.seekTo(Duration(seconds: snap.offsetSec));
        }
      }
      if (mounted) setState(() {});
    } finally {
      _syncing = false;
    }
  }

  Future<void> _prepareCurrentAtOffset(int offsetSec) async {
    await _videoController?.dispose();
    _videoController = null;

    if (widget.items.isEmpty) return;

    final item = _current;
    if (item.type == 'video') {
      final candidates = <VideoPlayerController>[];
      if (item.localPath != null && item.localPath!.trim().isNotEmpty) {
        candidates.add(VideoPlayerController.file(File(item.localPath!)));
      }
      candidates.add(VideoPlayerController.networkUrl(Uri.parse(item.url)));

      for (var i = 0; i < candidates.length; i++) {
        final controller = candidates[i];
        try {
          await controller.initialize().timeout(const Duration(seconds: 10));
          final maxSeek = controller.value.duration.inSeconds > 0 ? controller.value.duration.inSeconds - 1 : 0;
          final safeOffset = offsetSec.clamp(0, maxSeek);
          if (safeOffset > 0) {
            await controller.seekTo(Duration(seconds: safeOffset));
          }
          await controller.play();
          _videoController = controller;
          for (var j = i + 1; j < candidates.length; j++) {
            await candidates[j].dispose();
          }
          return;
        } catch (_) {
          await controller.dispose();
        }
      }
      return;
    }

    if (item.durationSec < 1 || offsetSec < 0) {
      return;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const Center(child: Text('No playlist items', style: TextStyle(color: Colors.white)));
    }

    final item = _current;
    Widget content;
    if (item.type == 'video' &&
        _videoController != null &&
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
      content = Center(
        child: item.localPath != null
            ? Image.file(File(item.localPath!), fit: BoxFit.contain)
            : Image.network(item.url, fit: BoxFit.contain),
      );
    } else {
      content = Center(
        child: Text(item.id, style: const TextStyle(color: Colors.white, fontSize: 22)),
      );
    }

    return SizedBox.expand(child: content);
  }
}
