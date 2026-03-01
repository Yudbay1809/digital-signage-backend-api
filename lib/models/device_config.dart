class MediaItem {
  final String id;
  final String type; // image | video
  final String path;
  final String displayPath;
  final String thumbPath;
  final String highPath;
  final String checksum;
  final int? durationSec;
  final int? sizeBytes;

  const MediaItem({
    required this.id,
    required this.type,
    required this.path,
    String? displayPath,
    String? thumbPath,
    String? highPath,
    required this.checksum,
    this.durationSec,
    this.sizeBytes,
  }) : displayPath = (displayPath == null || displayPath == '')
           ? path
           : displayPath,
       thumbPath = (thumbPath == null || thumbPath == '') ? path : thumbPath,
       highPath = (highPath == null || highPath == '') ? path : highPath;
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
  final bool isFlashSale;
  final String? flashNote;
  final int? flashCountdownSec;
  final String? flashItemsJson;
  final List<PlaylistItemConfig> items;

  const PlaylistConfig({
    required this.id,
    required this.name,
    required this.screenId,
    this.isFlashSale = false,
    this.flashNote,
    this.flashCountdownSec,
    this.flashItemsJson,
    required this.items,
  });
}

class ScheduleConfig {
  final int dayOfWeek; // 0-6
  final String startTime; // HH:MM:SS
  final String endTime;
  final String playlistId;
  final String? note;
  final int? countdownSec;

  const ScheduleConfig({
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    required this.playlistId,
    this.note,
    this.countdownSec,
  });
}

class ScreenConfig {
  final String screenId;
  final String name;
  final String? activePlaylistId;
  final String? gridPreset;
  final int? transitionDurationSec;
  final List<ScheduleConfig> schedules;

  const ScreenConfig({
    required this.screenId,
    required this.name,
    this.activePlaylistId,
    this.gridPreset,
    this.transitionDurationSec,
    required this.schedules,
  });
}

class DeviceConfig {
  final String deviceId;
  final String? orientation;
  final List<MediaItem> media;
  final List<PlaylistConfig> playlists;
  final List<ScreenConfig> screens;
  final FlashSaleConfig? flashSale;

  const DeviceConfig({
    required this.deviceId,
    required this.media,
    required this.playlists,
    required this.screens,
    this.flashSale,
    this.orientation,
  });
}

class FlashSaleConfig {
  final bool enabled;
  final bool active;
  final String? note;
  final int? countdownSec;
  final String? productsJson;
  final String? scheduleDays;
  final String? scheduleStartTime;
  final String? scheduleEndTime;
  final String? runtimeStartAt;
  final String? runtimeEndAt;
  final String? countdownEndAt;
  final String? activatedAt;
  final String? updatedAt;

  const FlashSaleConfig({
    required this.enabled,
    required this.active,
    this.note,
    this.countdownSec,
    this.productsJson,
    this.scheduleDays,
    this.scheduleStartTime,
    this.scheduleEndTime,
    this.runtimeStartAt,
    this.runtimeEndAt,
    this.countdownEndAt,
    this.activatedAt,
    this.updatedAt,
  });
}
