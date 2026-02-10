class MediaItem {
  final String id;
  final String type; // image | video
  final String path;
  final String checksum;
  final int? durationSec;

  const MediaItem({
    required this.id,
    required this.type,
    required this.path,
    required this.checksum,
    this.durationSec,
  });
}

class PlaylistItemConfig {
  final int order;
  final String mediaId;
  final int? durationSec;

  const PlaylistItemConfig({
    required this.order,
    required this.mediaId,
    this.durationSec,
  });
}

class PlaylistConfig {
  final String id;
  final String name;
  final String screenId;
  final List<PlaylistItemConfig> items;

  const PlaylistConfig({
    required this.id,
    required this.name,
    required this.screenId,
    required this.items,
  });
}

class ScheduleConfig {
  final int dayOfWeek; // 0-6
  final String startTime; // HH:MM:SS
  final String endTime;
  final String playlistId;

  const ScheduleConfig({
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    required this.playlistId,
  });
}

class ScreenConfig {
  final String screenId;
  final String name;
  final String? activePlaylistId;
  final String? gridPreset;
  final List<ScheduleConfig> schedules;

  const ScreenConfig({
    required this.screenId,
    required this.name,
    this.activePlaylistId,
    this.gridPreset,
    required this.schedules,
  });
}

class DeviceConfig {
  final String deviceId;
  final String? orientation;
  final List<MediaItem> media;
  final List<PlaylistConfig> playlists;
  final List<ScreenConfig> screens;

  const DeviceConfig({
    required this.deviceId,
    required this.media,
    required this.playlists,
    required this.screens,
    this.orientation,
  });
}
