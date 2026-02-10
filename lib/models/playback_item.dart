class PlaybackItem {
  final String id;
  final String type; // image | video
  final String url;
  final int durationSec;
  final String? localPath;

  const PlaybackItem({
    required this.id,
    required this.type,
    required this.url,
    required this.durationSec,
    this.localPath,
  });
}
