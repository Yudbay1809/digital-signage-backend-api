import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'models/device_config.dart';
import 'models/playback_item.dart';
import 'player/playlist_player.dart';
import 'services/api.dart';
import 'services/cache.dart';
import 'services/sync.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SignageApp());
}

class SignageApp extends StatelessWidget {
  const SignageApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0EA5E9),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'Android Signage Player',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF3F8FF),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.95),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD7E5FF)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD7E5FF)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
        cardTheme: CardThemeData(
          elevation: 6,
          shadowColor: const Color(0x240F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          ),
        ),
      ),
      home: const PlayerPage(),
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const String _defaultServerBaseUrl = '';
  final Duration _heartbeatInterval = const Duration(seconds: 30);
  final Duration _configPollInterval = const Duration(seconds: 8);
  final Duration _realtimeSafetyPollInterval = const Duration(seconds: 30);
  final int _maxCacheBytes = 4 * 1024 * 1024 * 1024; // 4 GB

  String _baseUrl = '';
  List<PlaybackItem> _itemsA = const [];
  String _syncKeyA = 'screen-0';
  String _gridPresetA = '1x1';
  String _activePlaylistNameA = '';
  bool _flashSaleActiveA = false;
  DateTime? _flashSaleEndsAtA;
  bool _loading = true;
  String? _error;
  String? _deviceId;
  String _deviceName = '';
  String _deviceLocation = '';
  String? _lastSyncedOrientation;
  String? _lastConfigSignature;
  bool _syncInProgress = false;
  bool _needsRegistration = false;
  bool _registering = false;
  String? _registrationNotice;
  final TextEditingController _registerNameController = TextEditingController();
  final TextEditingController _registerLocationController = TextEditingController();
  final TextEditingController _registerBaseUrlController = TextEditingController();

  late ApiService _api;
  late final CacheService _cache;
  late SyncService _sync;
  Timer? _heartbeatTimer;
  Timer? _syncTimer;
  Timer? _timelineEvalTimer;
  Timer? _flashOverlayTimer;
  Timer? _realtimeReconnectTimer;
  Timer? _realtimePingTimer;
  Timer? _settingsHoldTimer;
  WebSocket? _realtimeSocket;
  bool _realtimeConnecting = false;
  bool _realtimeEnabled = false;
  bool _realtimeConnected = false;
  DeviceConfig? _cachedConfig;
  Map<String, String> _cachedLocalMap = const {};

  @override
  void initState() {
    super.initState();
    _cache = CacheService();
    _init();
  }

  Future<void> _init() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await WakelockPlus.enable();

      final prefs = await SharedPreferences.getInstance();
      _deviceId = prefs.getString('device_id');
      _deviceName = prefs.getString('device_name') ?? '';
      _deviceLocation = prefs.getString('device_location') ?? '';
      _registerNameController.text = _deviceName;
      _registerLocationController.text = _deviceLocation;
      _baseUrl = _normalizeBaseUrl(prefs.getString('base_url') ?? _defaultServerBaseUrl);
      _registerBaseUrlController.text = _baseUrl;
      await _syncBaseUrlToServerIp();

      if (_baseUrl.isEmpty) {
        setState(() {
          _error = 'Server tidak ditemukan otomatis';
          _loading = false;
        });
        return;
      }

      _rebuildServices();

      if ((_deviceId == null || _deviceId!.isEmpty) && _deviceName.isNotEmpty) {
        await _registerCurrentDevice();
      }

      if (_deviceId == null || _deviceId!.isEmpty) {
        setState(() {
          _needsRegistration = true;
          _loading = false;
          _error = null;
        });
        return;
      }

      await _load();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _syncTimer?.cancel();
    _timelineEvalTimer?.cancel();
    _flashOverlayTimer?.cancel();
    _settingsHoldTimer?.cancel();
    _realtimePingTimer?.cancel();
    _stopRealtimeChannel();
    _registerNameController.dispose();
    _registerLocationController.dispose();
    _registerBaseUrlController.dispose();
    super.dispose();
  }

  void _startSettingsHoldTimer() {
    _settingsHoldTimer?.cancel();
    _settingsHoldTimer = Timer(const Duration(seconds: 3), () {
      _settingsHoldTimer = null;
      _openSettings();
    });
  }

  void _cancelSettingsHoldTimer() {
    _settingsHoldTimer?.cancel();
    _settingsHoldTimer = null;
  }

  Future<void> _registerFromGate() async {
    if (_registering) return;
    final name = _registerNameController.text.trim();
    final location = _registerLocationController.text.trim();
    if (name.isEmpty) {
      _showSnack('Nama device wajib diisi');
      return;
    }

    setState(() => _registering = true);
    try {
      _baseUrl = _normalizeBaseUrl(_registerBaseUrlController.text);
      await _syncBaseUrlToServerIp();
      final reachable = await _probeBaseUrl(_baseUrl);
      if (reachable != null) {
        _baseUrl = reachable;
      }
      _registerBaseUrlController.text = _baseUrl;
      if (_baseUrl.isEmpty) {
        _showSnack('Base URL server wajib diisi');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      _deviceName = name;
      _deviceLocation = location;
      await prefs.setString('device_name', _deviceName);
      await prefs.setString('device_location', _deviceLocation);
      await prefs.setString('base_url', _baseUrl);
      _rebuildServices();
      await _registerCurrentDevice();

      if (_deviceId == null || _deviceId!.isEmpty) {
        _showSnack('Registrasi gagal: device_id tidak diterima dari server');
        return;
      }
      _showSnack('Registrasi berhasil');

      if (!mounted) return;
      setState(() {
        _needsRegistration = false;
        _loading = true;
        _registrationNotice = null;
      });
      await _load();
    } catch (e) {
      _showSnack(e.toString());
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _looksLikeDeviceNotFoundError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('fetch config failed: 404') || msg.contains('device not found');
  }

  Future<void> _switchToRegistrationRequired(String notice) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('device_id');
    if (!mounted) return;
    _heartbeatTimer?.cancel();
    _syncTimer?.cancel();
    _stopRealtimeChannel();
    setState(() {
      _deviceId = null;
      _itemsA = const [];
      _syncKeyA = 'screen-0';
      _gridPresetA = '1x1';
      _activePlaylistNameA = '';
      _flashSaleActiveA = false;
      _flashSaleEndsAtA = null;
      _cachedConfig = null;
      _cachedLocalMap = const {};
      _needsRegistration = true;
      _loading = false;
      _error = null;
      _registrationNotice = notice;
    });
  }

  Widget _buildRegistrationGate() {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0B1022), Color(0xFF0C4A6E), Color(0xFF1E3A8A)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.devices_rounded, color: Color(0xFF0369A1)),
                        SizedBox(width: 8),
                        Text('Registrasi Device', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Masukkan data device untuk mulai sinkronisasi konten.',
                      style: TextStyle(color: Colors.blueGrey.shade700),
                    ),
                    if (_registrationNotice != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3CD),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFACC15)),
                        ),
                        child: Text(
                          _registrationNotice!,
                          style: const TextStyle(color: Color(0xFF854D0E), fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextField(
                      controller: _registerNameController,
                      decoration: const InputDecoration(
                        labelText: 'Nama Device',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                    ),
                    const SizedBox(height: 9),
                    TextField(
                      controller: _registerLocationController,
                      decoration: const InputDecoration(
                        labelText: 'Lokasi',
                        prefixIcon: Icon(Icons.place_outlined),
                      ),
                    ),
                    const SizedBox(height: 9),
                    TextField(
                      controller: _registerBaseUrlController,
                      decoration: const InputDecoration(
                        labelText: 'Base URL Server',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            final found = await _discoverBaseUrl();
                            if (found != null && mounted) {
                              setState(() {
                                _baseUrl = found;
                                _registerBaseUrlController.text = found;
                              });
                            }
                          },
                          icon: const Icon(Icons.travel_explore_rounded),
                          label: const Text('Auto Detect'),
                        ),
                        const Spacer(),
                        ElevatedButton.icon(
                          onPressed: _registering ? null : _registerFromGate,
                          icon: _registering
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.save_outlined),
                          label: Text(_registering ? 'Menyimpan...' : 'Simpan & Register'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _rebuildServices() {
    _api = ApiService(_baseUrl);
    _sync = SyncService(baseUrl: _baseUrl, cache: _cache, maxCacheBytes: _maxCacheBytes);
  }

  Future<void> _registerCurrentDevice() async {
    if (_deviceName.trim().isEmpty || _baseUrl.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final detectedOrientation = _detectDisplayOrientation();
    final reg = await _api.registerDevice(
      name: _deviceName.trim(),
      location: _deviceLocation.trim(),
      orientation: detectedOrientation,
    );
    final deviceId = reg['id']?.toString();
    if (deviceId == null || deviceId.isEmpty) return;
    _deviceId = deviceId;
    _lastSyncedOrientation = detectedOrientation;
    await prefs.setString('device_id', deviceId);
  }

  Future<void> _syncBaseUrlToServerIp() async {
    final prefs = await SharedPreferences.getInstance();
    String? canonical;
    if (_baseUrl.isNotEmpty) {
      canonical = await _probeBaseUrl(_baseUrl);
    }
    canonical ??= await _discoverBaseUrl();
    if (canonical == null || canonical.isEmpty) return;
    if (canonical != _baseUrl) {
      _baseUrl = canonical;
      _registerBaseUrlController.text = canonical;
      await prefs.setString('base_url', canonical);
    }
  }

  Future<String?> _probeBaseUrl(String url) async {
    final normalized = _normalizeBaseUrl(url);
    if (normalized.isEmpty) return null;
    final parsed = Uri.tryParse(normalized);
    if (parsed == null || parsed.host.isEmpty) return null;

    final host = parsed.host;
    final port = parsed.hasPort ? parsed.port : 8000;
    final probes = <String>[
      'http://$host:$port',
    ];

    for (final probeUrl in probes) {
      final probeParsed = Uri.parse(probeUrl);
      final scheme = probeParsed.scheme;
      try {
        final res = await http.get(Uri.parse('$probeUrl/server-info')).timeout(const Duration(milliseconds: 500));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final base = _normalizeBaseUrl((data['base_url'] ?? '').toString());
          if (base.isNotEmpty) return base;
          final discoveredPort = (data['server_port'] ?? '$port').toString().trim();
          if (discoveredPort.isNotEmpty) return '$scheme://$host:$discoveredPort';
          return '$scheme://$host';
        }

        final fallback = await http.get(Uri.parse('$probeUrl/healthz')).timeout(const Duration(milliseconds: 450));
        if (fallback.statusCode == 200) {
          final data = jsonDecode(fallback.body) as Map<String, dynamic>;
          final discoveredPort = (data['server_port'] ?? '$port').toString().trim();
          if (discoveredPort.isNotEmpty) return '$scheme://$host:$discoveredPort';
          return '$scheme://$host';
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _discoverBaseUrl() async {
    final common = [_defaultServerBaseUrl, 'http://127.0.0.1:8000', 'http://localhost:8000'];
    for (final url in common) {
      if (url.isEmpty) continue;
      final found = await _probeBaseUrl(url);
      if (found != null) return found;
    }

    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
    for (final iface in interfaces) {
      for (final address in iface.addresses) {
        final ip = address.address;
        if (!(ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.'))) {
          continue;
        }

        final parts = ip.split('.');
        if (parts.length != 4) continue;
        final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
        final futures = <Future<String?>>[];

        for (var host = 1; host <= 254; host++) {
          final candidate = 'http://$prefix$host:8000';
          futures.add(
            _probeBaseUrl(candidate),
          );
        }

        final results = await Future.wait(futures);
        for (final found in results) {
          if (found != null) return found;
        }
      }
    }
    return null;
  }

  Future<void> _openSettings() async {
    final nameController = TextEditingController(text: _deviceName);
    final locationController = TextEditingController(text: _deviceLocation);
    final baseUrlController = TextEditingController(text: _baseUrl);

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final screenWidth = MediaQuery.of(ctx).size.width;
        final dialogWidth = screenWidth < 520 ? screenWidth * 0.92 : 450.0;
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: const Text('Device Settings'),
              content: SizedBox(
                width: dialogWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Nama Device'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: locationController,
                      decoration: const InputDecoration(labelText: 'Lokasi'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: baseUrlController,
                      decoration: const InputDecoration(labelText: 'Base URL Server'),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () async {
                          final found = await _discoverBaseUrl();
                          if (found != null) {
                            setLocalState(() => baseUrlController.text = found);
                          }
                        },
                        child: const Text('Auto Detect Server'),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      final prefs = await SharedPreferences.getInstance();
                      _deviceName = nameController.text.trim();
                      _deviceLocation = locationController.text.trim();
                      _registerNameController.text = _deviceName;
                      _registerLocationController.text = _deviceLocation;
                      _baseUrl = _normalizeBaseUrl(baseUrlController.text);
                      final reachable = await _probeBaseUrl(_baseUrl);
                      if (reachable != null) {
                        _baseUrl = reachable;
                      }
                      _registerBaseUrlController.text = _baseUrl;

                      if (_deviceName.isEmpty) {
                        _showSnack('Nama device wajib diisi');
                        return;
                      }
                      if (_baseUrl.isEmpty) {
                        _showSnack('Base URL server wajib diisi');
                        return;
                      }

                      await prefs.setString('device_name', _deviceName);
                      await prefs.setString('device_location', _deviceLocation);
                      await prefs.setString('base_url', _baseUrl);
                      _rebuildServices();

                      if (_deviceId == null || _deviceId!.isEmpty) {
                        await _registerCurrentDevice();
                        if (_deviceId == null || _deviceId!.isEmpty) {
                          _showSnack('Registrasi gagal: device_id tidak diterima dari server');
                          return;
                        }
                        _showSnack('Registrasi berhasil');
                      }

                      if (mounted) {
                        setState(() {
                          _error = null;
                          _needsRegistration = _deviceId == null || _deviceId!.isEmpty;
                        });
                        if (_deviceId != null && _deviceId!.isNotEmpty) {
                          _load();
                        }
                      }
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    } catch (e) {
                      _showSnack(e.toString());
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    baseUrlController.dispose();
  }

  String _normalizeBaseUrl(String value) {
    var out = value.trim();
    if (out.isEmpty) return '';
    if (out.startsWith('https://')) {
      out = 'http://${out.substring('https://'.length)}';
    }
    if (!out.startsWith(RegExp(r'https?://'))) {
      out = 'http://$out';
    }
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    final parsed = Uri.tryParse(out);
    if (parsed != null && parsed.host.isNotEmpty) {
      final port = parsed.hasPort ? parsed.port : 8000;
      out = 'http://${parsed.host}:$port';
    }
    return out;
  }

  Future<void> _applyOrientation(String? orientation) async {
    if (orientation == null) return;
    if (orientation == 'portrait') {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else if (orientation == 'landscape') {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  String _detectDisplayOrientation() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) {
      final size = views.first.physicalSize;
      return size.height >= size.width ? 'portrait' : 'landscape';
    }
    return 'landscape';
  }

  Future<void> _syncDetectedOrientation() async {
    if (_deviceId == null) return;
    final detected = _detectDisplayOrientation();
    await _applyOrientation(detected);

    if (_lastSyncedOrientation == detected) return;
    try {
      await _api.updateDeviceOrientation(
        deviceId: _deviceId!,
        orientation: detected,
      );
      _lastSyncedOrientation = detected;
    } catch (_) {}
  }

  Future<void> _load() async {
    if (_deviceId == null) return;
    try {
      if (_baseUrl.isEmpty) {
        await _syncBaseUrlToServerIp();
      }
      await _syncFromServer(force: true, setLoadingFalse: true);
      _startTimers();
      _startRealtimeChannel();
    } catch (e) {
      if (_looksLikeDeviceNotFoundError(e)) {
        await _switchToRegistrationRequired('Device terhapus dari server. Silakan registrasi terlebih dahulu.');
        return;
      }
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _startTimers() {
    _heartbeatTimer?.cancel();
    _restartSyncTimer();
    _startTimelineEvaluator();
    _startFlashOverlayTicker();

    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      try {
        if (_deviceId != null) {
          await _api.heartbeat(_deviceId!);
        }
      } catch (_) {}
    });

  }

  void _startFlashOverlayTicker() {
    _flashOverlayTimer?.cancel();
    _flashOverlayTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_flashSaleActiveA) return;
      setState(() {});
    });
  }

  void _startTimelineEvaluator() {
    _timelineEvalTimer?.cancel();
    _timelineEvalTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final cfg = _cachedConfig;
      if (cfg == null || !mounted) return;
      _applyConfigToPlayback(cfg, _cachedLocalMap, force: false, setLoadingFalse: false);
    });
  }

  Duration _currentSyncInterval() {
    return _realtimeConnected ? _realtimeSafetyPollInterval : _configPollInterval;
  }

  void _restartSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_currentSyncInterval(), (_) async {
      try {
        await _syncFromServer(force: false);
      } catch (e) {
        if (_looksLikeDeviceNotFoundError(e)) {
          await _switchToRegistrationRequired('Device terhapus dari server. Silakan registrasi terlebih dahulu.');
        }
      }
      finally {
        _syncInProgress = false;
      }
    });
  }

  Future<void> _syncFromServer({required bool force, bool setLoadingFalse = false}) async {
    if (_deviceId == null || _syncInProgress) return;
    _syncInProgress = true;
    try {
      await _syncDetectedOrientation();
      final config = await _api.fetchConfig(_deviceId!);
      final localMap = await _sync.syncMedia(config.media);
      _cachedConfig = config;
      _cachedLocalMap = localMap;
      _applyConfigToPlayback(config, localMap, force: force, setLoadingFalse: setLoadingFalse);
    } finally {
      _syncInProgress = false;
    }
  }

  void _applyConfigToPlayback(
    DeviceConfig config,
    Map<String, String> localMap, {
    required bool force,
    required bool setLoadingFalse,
  }) {
    final nextSignature = _buildConfigSignature(config);
    final screenA = config.screens.isNotEmpty ? config.screens.first : null;
    final selectionA = (screenA != null && config.playlists.isNotEmpty)
        ? _resolvePlaylistSelection(screenA, config.playlists)
        : const _PlaylistSelection(playlistId: 'screen-0', endTime: null);
    final nextSyncKeyA = selectionA.playlistId;
    final nextGridPresetA = _gridPresetForScreen(config, index: 0);
    final nextPlaylistA = config.playlists.where((p) => p.id == nextSyncKeyA).toList();
    final nextPlaylistNameA = nextPlaylistA.isNotEmpty ? nextPlaylistA.first.name : '';
    final isLandscape = (config.orientation ?? '').toLowerCase() == 'landscape';
    final isFlashSale = _isFlashSalePlaylistName(nextPlaylistNameA);
    final playlistSwitchNeeded = nextSyncKeyA != _syncKeyA;
    final gridChanged = nextGridPresetA != _gridPresetA;
    final flashChanged =
        isFlashSale != _flashSaleActiveA ||
        nextPlaylistNameA != _activePlaylistNameA ||
        selectionA.endTime != _flashSaleEndsAtA;
    if (!force && _lastConfigSignature == nextSignature && !playlistSwitchNeeded && !gridChanged && !flashChanged) return;

    final itemsA = _buildPlaybackItemsForScreen(config, localMap, index: 0);
    _lastConfigSignature = nextSignature;
    if (!mounted) return;
    setState(() {
      _itemsA = itemsA;
      _syncKeyA = nextSyncKeyA;
      _gridPresetA = nextGridPresetA;
      _activePlaylistNameA = nextPlaylistNameA;
      _flashSaleActiveA = isLandscape && isFlashSale;
      _flashSaleEndsAtA = selectionA.endTime;
      if (setLoadingFalse) _loading = false;
    });
  }

  String _toWsUrl(String baseUrl) {
    if (baseUrl.startsWith('http://')) {
      return 'ws://${baseUrl.substring('http://'.length)}';
    }
    return 'ws://$baseUrl';
  }

  void _startRealtimeChannel() {
    _realtimeEnabled = true;
    _stopRealtimeChannel();
    _realtimeEnabled = true;
    _connectRealtime();
  }

  void _scheduleRealtimeReconnect() {
    _realtimeReconnectTimer?.cancel();
    if (!_realtimeEnabled || _deviceId == null || _needsRegistration) return;
    _realtimeReconnectTimer = Timer(const Duration(seconds: 5), _connectRealtime);
  }

  Future<void> _connectRealtime() async {
    if (!_realtimeEnabled || _realtimeConnecting || _realtimeSocket != null || _deviceId == null || _baseUrl.isEmpty || _needsRegistration) return;
    _realtimeConnecting = true;
    try {
      final wsUrl = '${_toWsUrl(_baseUrl)}/ws/updates';
      final socket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 5));
      _realtimeSocket = socket;
      _realtimeConnected = true;
      _restartSyncTimer();
      _realtimePingTimer?.cancel();
      _realtimePingTimer = Timer.periodic(const Duration(seconds: 12), (_) {
        try {
          _realtimeSocket?.add('ping');
        } catch (_) {}
      });
      socket.add('subscribe:$_deviceId');
      try {
        await _syncFromServer(force: true);
      } catch (_) {}
      await for (final _ in socket) {
        if (_deviceId == null || _needsRegistration) break;
        try {
          await _syncFromServer(force: true);
        } catch (e) {
          if (_looksLikeDeviceNotFoundError(e)) {
            await _switchToRegistrationRequired('Device terhapus dari server. Silakan registrasi terlebih dahulu.');
            break;
          }
        }
      }
    } catch (_) {
      // fallback stays on periodic polling
    } finally {
      _realtimePingTimer?.cancel();
      _realtimePingTimer = null;
      try {
        await _realtimeSocket?.close();
      } catch (_) {}
      _realtimeSocket = null;
      _realtimeConnected = false;
      if (_deviceId != null && !_needsRegistration) {
        _restartSyncTimer();
      }
      _realtimeConnecting = false;
      _scheduleRealtimeReconnect();
    }
  }

  void _stopRealtimeChannel() {
    _realtimeEnabled = false;
    _realtimeReconnectTimer?.cancel();
    _realtimeReconnectTimer = null;
    _realtimePingTimer?.cancel();
    _realtimePingTimer = null;
    try {
      _realtimeSocket?.close();
    } catch (_) {}
    _realtimeSocket = null;
    _realtimeConnected = false;
    _realtimeConnecting = false;
  }

  String _buildConfigSignature(DeviceConfig config) {
    final media = config.media
        .map((m) => '${m.id}|${m.type}|${m.path}|${m.checksum}|${m.durationSec ?? 0}')
        .toList()
      ..sort();

    final playlists = config.playlists.map((p) {
      final items = p.items.map((i) => '${i.order}:${i.mediaId}:${i.durationSec ?? 0}').toList()..sort();
      return '${p.id}|${p.name}|${p.screenId}|${items.join(',')}';
    }).toList()
      ..sort();

    final screens = config.screens.map((s) {
      final schedules = s.schedules
          .map((sc) => '${sc.dayOfWeek}:${sc.startTime}:${sc.endTime}:${sc.playlistId}')
          .toList()
        ..sort();
      return '${s.screenId}|${s.name}|${s.activePlaylistId ?? ''}|${s.gridPreset ?? '1x1'}|${schedules.join(',')}';
    }).toList()
      ..sort();

    return [
      config.deviceId,
      config.orientation ?? '',
      media.join(';'),
      playlists.join(';'),
      screens.join(';'),
    ].join('||');
  }

  List<PlaybackItem> _buildPlaybackItemsForScreen(DeviceConfig cfg, Map<String, String> localMap, {required int index}) {
    if (cfg.screens.length <= index || cfg.playlists.isEmpty) return const [];

    final screen = cfg.screens[index];
    final selection = _resolvePlaylistSelection(screen, cfg.playlists);
    final playlist = cfg.playlists.firstWhere((p) => p.id == selection.playlistId, orElse: () => cfg.playlists.first);

    if (playlist.items.isEmpty || cfg.media.isEmpty) return const [];

    final mediaById = <String, MediaItem>{};
    for (final media in cfg.media) {
      mediaById[media.id] = media;
    }

    final items = <PlaybackItem>[];
    for (final item in playlist.items) {
      final media = mediaById[item.mediaId];
      if (media == null) {
        continue;
      }
      final duration = item.durationSec ?? media.durationSec ?? 10;
      items.add(PlaybackItem(
        id: media.id,
        type: media.type,
        url: _absoluteUrl(media.path),
        durationSec: duration,
        localPath: localMap[media.id],
      ));
    }
    return items;
  }

  String _gridPresetForScreen(DeviceConfig cfg, {required int index}) {
    if (cfg.screens.length <= index) return '1x1';
    final preset = cfg.screens[index].gridPreset ?? '1x1';
    return RegExp(r'^\d+x\d+$').hasMatch(preset) ? preset : '1x1';
  }

  String _absoluteUrl(String path) {
    if (path.startsWith('http')) return path;
    return '$_baseUrl$path';
  }

  _PlaylistSelection _resolvePlaylistSelection(ScreenConfig screen, List<PlaylistConfig> playlists) {
    final forced = (screen.activePlaylistId ?? '').trim();
    if (forced.isNotEmpty && playlists.any((p) => p.id == forced)) {
      return _PlaylistSelection(playlistId: forced, endTime: null);
    }

    final now = DateTime.now();
    final day = now.weekday % 7;

    for (final schedule in screen.schedules) {
      if (schedule.dayOfWeek != day) continue;
      final start = _parseTime(schedule.startTime, now);
      final end = _parseTime(schedule.endTime, now);
      if ((now.isAtSameMomentAs(start) || now.isAfter(start)) && now.isBefore(end)) {
        return _PlaylistSelection(playlistId: schedule.playlistId, endTime: end);
      }
    }

    return _PlaylistSelection(playlistId: playlists.first.id, endTime: null);
  }

  DateTime _parseTime(String value, DateTime now) {
    final parts = value.split(':').map(int.parse).toList();
    return DateTime(now.year, now.month, now.day, parts[0], parts[1], parts.length > 2 ? parts[2] : 0);
  }

  int _gridRows(String preset) {
    final parts = preset.split('x');
    if (parts.length != 2) return 1;
    return int.tryParse(parts[0]) ?? 1;
  }

  int _gridCols(String preset) {
    final parts = preset.split('x');
    if (parts.length != 2) return 1;
    return int.tryParse(parts[1]) ?? 1;
  }

  List<PlaybackItem> _itemsForGridCell(List<PlaybackItem> source, int cellIndex, int cellCount) {
    if (source.isEmpty || cellCount <= 1) return source;
    final total = source.length;
    final base = total ~/ cellCount;
    final extra = total % cellCount;
    final take = base + (cellIndex < extra ? 1 : 0);
    if (take <= 0) return const [];
    final start = (cellIndex * base) + (cellIndex < extra ? cellIndex : extra);
    final end = start + take;
    if (start < 0 || start >= total || end > total) return const [];
    return source.sublist(start, end);
  }

  Widget _buildGridPlayback() {
    final rows = _gridRows(_gridPresetA).clamp(1, 4);
    final cols = _gridCols(_gridPresetA).clamp(1, 4);
    final cellCount = rows * cols;
    if (cellCount <= 1) {
      return PlaylistPlayer(items: _itemsA, syncKey: _syncKeyA);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : MediaQuery.sizeOf(context).width;
        final height = constraints.maxHeight.isFinite ? constraints.maxHeight : MediaQuery.sizeOf(context).height;
        final cellWidth = width / cols;
        final cellHeight = height / rows;
        final aspectRatio = (cellHeight <= 0) ? 1.0 : (cellWidth / cellHeight);

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: cellCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 1,
            mainAxisSpacing: 1,
            childAspectRatio: aspectRatio,
          ),
          itemBuilder: (context, index) {
            final cellItems = _itemsForGridCell(_itemsA, index, cellCount);
            if (cellItems.isEmpty) {
              return const DecoratedBox(
                decoration: BoxDecoration(color: Colors.black),
                child: SizedBox.expand(),
              );
            }
            return DecoratedBox(
              decoration: const BoxDecoration(color: Colors.black),
              child: PlaylistPlayer(
                items: cellItems,
                syncKey: '$_syncKeyA-grid-$index',
              ),
            );
          },
        );
      },
    );
  }

  bool _isFlashSalePlaylistName(String name) {
    final value = name.toLowerCase().trim();
    return value.contains('flash sale') || value.contains('flashsale') || value.contains('promo');
  }

  String _flashSaleCountdownLabel() {
    final end = _flashSaleEndsAtA;
    if (end == null) return '--:--';
    final remaining = end.difference(DateTime.now());
    if (remaining.isNegative || remaining.inSeconds <= 0) return '00:00';
    final minutes = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = remaining.inHours;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Widget _buildFlashSaleOverlay() {
    if (!_flashSaleActiveA) return const SizedBox.shrink();
    final title = _activePlaylistNameA.trim().isEmpty ? 'Flash Sale' : _activePlaylistNameA.trim();
    final countdown = _flashSaleCountdownLabel();
    return Align(
      alignment: Alignment.topCenter,
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFE11D48), Color(0xFFBE123C), Color(0xFF7F1D1D)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFCA5A5), width: 1.2),
            boxShadow: const [
              BoxShadow(color: Color(0x661F2937), blurRadius: 10, offset: Offset(0, 4)),
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.local_fire_department_rounded, color: Colors.white, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'FLASH SALE',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.0),
                    ),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFDE68A),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFF59E0B)),
                ),
                child: Text(
                  countdown,
                  style: const TextStyle(
                    color: Color(0xFF7C2D12),
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_needsRegistration) {
      return _buildRegistrationGate();
    }

    if (_loading) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0B1022), Color(0xFF0C4A6E)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 14),
                Text('Menyiapkan player...', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF450A0A), Color(0xFF7F1D1D), Color(0xFF991B1B)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 36, color: Color(0xFFB91C1C)),
                      const SizedBox(height: 10),
                      const Text('Koneksi Bermasalah', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: const TextStyle(color: Color(0xFF334155)),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 14),
                      ElevatedButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('Buka Pengaturan'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        onPointerDown: (_) => _startSettingsHoldTimer(),
        onPointerUp: (_) => _cancelSettingsHoldTimer(),
        onPointerCancel: (_) => _cancelSettingsHoldTimer(),
        child: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildGridPlayback(),
              _buildFlashSaleOverlay(),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistSelection {
  final String playlistId;
  final DateTime? endTime;

  const _PlaylistSelection({
    required this.playlistId,
    required this.endTime,
  });
}

