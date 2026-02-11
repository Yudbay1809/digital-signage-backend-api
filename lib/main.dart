import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
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
      title: 'Signage Android Player',
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
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 6,
          shadowColor: const Color(0x240F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
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
  static const double _flashSaleOverlayReservedTop = 220;
  static const double _flashSaleOverlayReservedBottom = 94;
  static const String _defaultServerBaseUrl = '';
  final Duration _heartbeatInterval = const Duration(seconds: 30);
  final Duration _configPollInterval = const Duration(seconds: 8);
  final Duration _realtimeSafetyPollInterval = const Duration(seconds: 30);
  final int _maxCacheBytes = 4 * 1024 * 1024 * 1024; // 4 GB

  String _baseUrl = '';
  List<PlaybackItem> _itemsA = const [];
  String _syncKeyA = 'screen-0';
  String _gridPresetA = '1x1';
  int _transitionDurationSecA = 1;
  String _activePlaylistNameA = '';
  bool _flashSaleActiveA = false;
  DateTime? _flashSaleStartsAtA;
  DateTime? _flashSaleEndsAtA;
  DateTime? _flashSaleCountdownEndsAtA;
  String _flashSaleNoteA = '';
  String _flashSaleProductsJsonA = '';
  String? _preFlashSalePlaylistIdA;
  String? _flashSaleAutoReturnedFromPlaylistA;
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
  final TextEditingController _registerLocationController =
      TextEditingController();
  final TextEditingController _registerBaseUrlController =
      TextEditingController();

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
      _baseUrl = _normalizeBaseUrl(
        prefs.getString('base_url') ?? _defaultServerBaseUrl,
      );
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _looksLikeDeviceNotFoundError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('fetch config failed: 404') ||
        msg.contains('device not found');
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
      _transitionDurationSecA = 1;
      _activePlaylistNameA = '';
      _flashSaleActiveA = false;
      _flashSaleStartsAtA = null;
      _flashSaleEndsAtA = null;
      _flashSaleCountdownEndsAtA = null;
      _flashSaleNoteA = '';
      _flashSaleProductsJsonA = '';
      _preFlashSalePlaylistIdA = null;
      _flashSaleAutoReturnedFromPlaylistA = null;
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
                        Text(
                          'Registrasi Device',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
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
                          style: const TextStyle(
                            color: Color(0xFF854D0E),
                            fontWeight: FontWeight.w600,
                          ),
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          label: Text(
                            _registering ? 'Menyimpan...' : 'Simpan & Register',
                          ),
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
    _sync = SyncService(
      baseUrl: _baseUrl,
      cache: _cache,
      maxCacheBytes: _maxCacheBytes,
    );
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
    final probes = <String>['http://$host:$port'];

    for (final probeUrl in probes) {
      final probeParsed = Uri.parse(probeUrl);
      final scheme = probeParsed.scheme;
      try {
        final res = await http
            .get(Uri.parse('$probeUrl/server-info'))
            .timeout(const Duration(milliseconds: 500));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final base = _normalizeBaseUrl((data['base_url'] ?? '').toString());
          if (base.isNotEmpty) return base;
          final discoveredPort = (data['server_port'] ?? '$port')
              .toString()
              .trim();
          if (discoveredPort.isNotEmpty)
            return '$scheme://$host:$discoveredPort';
          return '$scheme://$host';
        }

        final fallback = await http
            .get(Uri.parse('$probeUrl/healthz'))
            .timeout(const Duration(milliseconds: 450));
        if (fallback.statusCode == 200) {
          final data = jsonDecode(fallback.body) as Map<String, dynamic>;
          final discoveredPort = (data['server_port'] ?? '$port')
              .toString()
              .trim();
          if (discoveredPort.isNotEmpty)
            return '$scheme://$host:$discoveredPort';
          return '$scheme://$host';
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _discoverBaseUrl() async {
    final common = [
      _defaultServerBaseUrl,
      'http://127.0.0.1:8000',
      'http://localhost:8000',
    ];
    for (final url in common) {
      if (url.isEmpty) continue;
      final found = await _probeBaseUrl(url);
      if (found != null) return found;
    }

    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final address in iface.addresses) {
        final ip = address.address;
        if (!(ip.startsWith('192.168.') ||
            ip.startsWith('10.') ||
            ip.startsWith('172.'))) {
          continue;
        }

        final parts = ip.split('.');
        if (parts.length != 4) continue;
        final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
        final futures = <Future<String?>>[];

        for (var host = 1; host <= 254; host++) {
          final candidate = 'http://$prefix$host:8000';
          futures.add(_probeBaseUrl(candidate));
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
                      decoration: const InputDecoration(
                        labelText: 'Nama Device',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: locationController,
                      decoration: const InputDecoration(labelText: 'Lokasi'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: baseUrlController,
                      decoration: const InputDecoration(
                        labelText: 'Base URL Server',
                      ),
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
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Credits: Yudbay1809',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF475569),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Close'),
                ),
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
                          _showSnack(
                            'Registrasi gagal: device_id tidak diterima dari server',
                          );
                          return;
                        }
                        _showSnack('Registrasi berhasil');
                      }

                      if (mounted) {
                        setState(() {
                          _error = null;
                          _needsRegistration =
                              _deviceId == null || _deviceId!.isEmpty;
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
        await _switchToRegistrationRequired(
          'Device terhapus dari server. Silakan registrasi terlebih dahulu.',
        );
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
    _flashOverlayTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || !_flashSaleActiveA) return;
      setState(() {});
    });
  }

  void _startTimelineEvaluator() {
    _timelineEvalTimer?.cancel();
    _timelineEvalTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final cfg = _cachedConfig;
      if (cfg == null || !mounted) return;
      _applyConfigToPlayback(
        cfg,
        _cachedLocalMap,
        force: false,
        setLoadingFalse: false,
      );
    });
  }

  Duration _currentSyncInterval() {
    return _realtimeConnected
        ? _realtimeSafetyPollInterval
        : _configPollInterval;
  }

  void _restartSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_currentSyncInterval(), (_) async {
      try {
        await _syncFromServer(force: false);
      } catch (e) {
        if (_looksLikeDeviceNotFoundError(e)) {
          await _switchToRegistrationRequired(
            'Device terhapus dari server. Silakan registrasi terlebih dahulu.',
          );
        }
      } finally {
        _syncInProgress = false;
      }
    });
  }

  Future<void> _syncFromServer({
    required bool force,
    bool setLoadingFalse = false,
  }) async {
    if (_deviceId == null || _syncInProgress) return;
    _syncInProgress = true;
    try {
      await _syncDetectedOrientation();
      final config = await _api.fetchConfig(_deviceId!);
      final localMap = await _sync.syncMedia(config.media);
      _cachedConfig = config;
      _cachedLocalMap = localMap;
      _applyConfigToPlayback(
        config,
        localMap,
        force: force,
        setLoadingFalse: setLoadingFalse,
      );
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
    var selectionA = (screenA != null && config.playlists.isNotEmpty)
        ? _resolvePlaylistSelection(screenA, config.playlists)
        : const _PlaylistSelection(
            playlistId: 'screen-0',
            startTime: null,
            endTime: null,
            countdownEndTime: null,
            note: null,
            scheduled: false,
          );
    var nextSyncKeyA = selectionA.playlistId;
    final configuredGridPresetA = _gridPresetForScreen(config, index: 0);
    final nextTransitionDurationSecA = _transitionDurationForScreen(
      config,
      index: 0,
    );
    final playlistById = <String, PlaylistConfig>{
      for (final p in config.playlists) p.id: p,
    };
    final flashCampaign = config.flashSale;
    final campaignActive = flashCampaign?.active == true;
    final campaignStart = _tryParseIsoDateTime(flashCampaign?.runtimeStartAt);
    final campaignEnd = _tryParseIsoDateTime(flashCampaign?.runtimeEndAt);
    final campaignCountdownEnd = _tryParseIsoDateTime(
      flashCampaign?.countdownEndAt,
    );
    final campaignNote = (flashCampaign?.note ?? '').trim();
    final campaignProductsJson = (flashCampaign?.productsJson ?? '').trim();

    if (!campaignActive) {
      if (_flashSaleAutoReturnedFromPlaylistA != null &&
          nextSyncKeyA != _flashSaleAutoReturnedFromPlaylistA) {
        _flashSaleAutoReturnedFromPlaylistA = null;
      }

      final selectedBeforeOverride = playlistById[nextSyncKeyA];
      final selectedBeforeOverrideIsFlash =
          (selectedBeforeOverride?.isFlashSale ?? false) ||
          _isFlashSalePlaylistName(selectedBeforeOverride?.name ?? '');
      final countdownEnded =
          selectionA.countdownEndTime != null &&
          !selectionA.countdownEndTime!.isAfter(DateTime.now());
      final hasReturnTarget =
          (_preFlashSalePlaylistIdA ?? '').isNotEmpty &&
          _preFlashSalePlaylistIdA != nextSyncKeyA &&
          playlistById.containsKey(_preFlashSalePlaylistIdA);

      if (selectedBeforeOverrideIsFlash &&
          countdownEnded &&
          hasReturnTarget &&
          _flashSaleAutoReturnedFromPlaylistA != nextSyncKeyA) {
        nextSyncKeyA = _preFlashSalePlaylistIdA!;
        _flashSaleAutoReturnedFromPlaylistA = selectionA.playlistId;
        selectionA = _PlaylistSelection(
          playlistId: nextSyncKeyA,
          startTime: null,
          endTime: null,
          countdownEndTime: null,
          note: null,
          scheduled: false,
        );
      }
    }

    final nextPlaylist = playlistById[nextSyncKeyA];
    final nextPlaylistNameA = nextPlaylist?.name ?? '';
    final nextPlaylistFlashFlag = nextPlaylist?.isFlashSale ?? false;
    final fallbackFlashByPlaylist =
        nextPlaylistFlashFlag ||
        selectionA.scheduled ||
        _isFlashSalePlaylistName(nextPlaylistNameA);
    final isFlashSale = campaignActive || fallbackFlashByPlaylist;
    final flashStart = campaignActive ? campaignStart : selectionA.startTime;
    final flashEnd = campaignActive ? campaignEnd : selectionA.endTime;
    final flashCountdownEnd = campaignActive
        ? campaignCountdownEnd
        : selectionA.countdownEndTime;
    final flashNote = campaignActive ? campaignNote : (selectionA.note ?? '');
    final flashProductsJson = campaignActive
        ? campaignProductsJson
        : ((nextPlaylist?.flashItemsJson ?? '').trim());
    final nextGridPresetA = isFlashSale ? '1x1' : configuredGridPresetA;
    final playlistSwitchNeeded = nextSyncKeyA != _syncKeyA;
    final gridChanged = nextGridPresetA != _gridPresetA;
    final transitionChanged =
        nextTransitionDurationSecA != _transitionDurationSecA;
    final flashChanged =
        isFlashSale != _flashSaleActiveA ||
        nextPlaylistNameA != _activePlaylistNameA ||
        flashStart != _flashSaleStartsAtA ||
        flashEnd != _flashSaleEndsAtA ||
        flashCountdownEnd != _flashSaleCountdownEndsAtA ||
        flashNote != _flashSaleNoteA ||
        flashProductsJson != _flashSaleProductsJsonA;
    if (!force &&
        _lastConfigSignature == nextSignature &&
        !playlistSwitchNeeded &&
        !gridChanged &&
        !transitionChanged &&
        !flashChanged) {
      return;
    }

    var nextPreFlashSalePlaylistIdA = _preFlashSalePlaylistIdA;
    if (isFlashSale && !_flashSaleActiveA) {
      if (_syncKeyA.isNotEmpty &&
          _syncKeyA != nextSyncKeyA &&
          playlistById.containsKey(_syncKeyA)) {
        nextPreFlashSalePlaylistIdA = _syncKeyA;
      }
    } else if (!isFlashSale) {
      nextPreFlashSalePlaylistIdA = null;
    }

    final itemsA = _buildPlaybackItemsForScreen(
      config,
      localMap,
      index: 0,
      overridePlaylistId: nextSyncKeyA,
    );
    _lastConfigSignature = nextSignature;
    if (!mounted) return;
    setState(() {
      _itemsA = itemsA;
      _syncKeyA = nextSyncKeyA;
      _gridPresetA = nextGridPresetA;
      _transitionDurationSecA = nextTransitionDurationSecA;
      _activePlaylistNameA = nextPlaylistNameA;
      _flashSaleActiveA = isFlashSale;
      _flashSaleStartsAtA = flashStart;
      _flashSaleEndsAtA = flashEnd;
      _flashSaleCountdownEndsAtA = flashCountdownEnd;
      _flashSaleNoteA = flashNote;
      _flashSaleProductsJsonA = flashProductsJson;
      _preFlashSalePlaylistIdA = nextPreFlashSalePlaylistIdA;
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
    _realtimeReconnectTimer = Timer(
      const Duration(seconds: 5),
      _connectRealtime,
    );
  }

  Future<void> _connectRealtime() async {
    if (!_realtimeEnabled ||
        _realtimeConnecting ||
        _realtimeSocket != null ||
        _deviceId == null ||
        _baseUrl.isEmpty ||
        _needsRegistration)
      return;
    _realtimeConnecting = true;
    try {
      final wsUrl = '${_toWsUrl(_baseUrl)}/ws/updates';
      final socket = await WebSocket.connect(
        wsUrl,
      ).timeout(const Duration(seconds: 5));
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
            await _switchToRegistrationRequired(
              'Device terhapus dari server. Silakan registrasi terlebih dahulu.',
            );
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
    final media =
        config.media
            .map(
              (m) =>
                  '${m.id}|${m.type}|${m.path}|${m.checksum}|${m.durationSec ?? 0}',
            )
            .toList()
          ..sort();

    final playlists = config.playlists.map((p) {
      final items =
          p.items
              .map((i) => '${i.order}:${i.mediaId}:${i.durationSec ?? 0}')
              .toList()
            ..sort();
      return '${p.id}|${p.name}|${p.screenId}|${p.isFlashSale}|${p.flashCountdownSec ?? ''}|${p.flashNote ?? ''}|${p.flashItemsJson ?? ''}|${items.join(',')}';
    }).toList()..sort();

    final screens = config.screens.map((s) {
      final schedules =
          s.schedules
              .map(
                (sc) =>
                    '${sc.dayOfWeek}:${sc.startTime}:${sc.endTime}:${sc.playlistId}:${sc.countdownSec ?? ''}:${sc.note ?? ''}',
              )
              .toList()
            ..sort();
      return '${s.screenId}|${s.name}|${s.activePlaylistId ?? ''}|${s.gridPreset ?? '1x1'}|${s.transitionDurationSec ?? 1}|${schedules.join(',')}';
    }).toList()..sort();

    final flash = config.flashSale;
    final flashSignature = flash == null
        ? ''
        : '${flash.enabled}|${flash.active}|${flash.note ?? ''}|${flash.countdownSec ?? ''}|${flash.productsJson ?? ''}|${flash.scheduleDays ?? ''}|${flash.scheduleStartTime ?? ''}|${flash.scheduleEndTime ?? ''}|${flash.runtimeStartAt ?? ''}|${flash.runtimeEndAt ?? ''}|${flash.countdownEndAt ?? ''}|${flash.activatedAt ?? ''}|${flash.updatedAt ?? ''}';

    return [
      config.deviceId,
      config.orientation ?? '',
      media.join(';'),
      playlists.join(';'),
      screens.join(';'),
      flashSignature,
    ].join('||');
  }

  List<PlaybackItem> _buildPlaybackItemsForScreen(
    DeviceConfig cfg,
    Map<String, String> localMap, {
    required int index,
    String? overridePlaylistId,
  }) {
    if (cfg.screens.length <= index || cfg.playlists.isEmpty) return const [];

    final screen = cfg.screens[index];
    final selection = _resolvePlaylistSelection(screen, cfg.playlists);
    final selectedPlaylistId = (overridePlaylistId ?? '').trim().isNotEmpty
        ? overridePlaylistId!.trim()
        : selection.playlistId;
    final playlist = cfg.playlists.firstWhere(
      (p) => p.id == selectedPlaylistId,
      orElse: () => cfg.playlists.first,
    );

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
      items.add(
        PlaybackItem(
          id: media.id,
          type: media.type,
          url: _absoluteUrl(media.path),
          durationSec: duration,
          localPath: localMap[media.id],
        ),
      );
    }
    return items;
  }

  String _gridPresetForScreen(DeviceConfig cfg, {required int index}) {
    if (cfg.screens.length <= index) return '1x1';
    final preset = cfg.screens[index].gridPreset ?? '1x1';
    return RegExp(r'^\d+x\d+$').hasMatch(preset) ? preset : '1x1';
  }

  int _transitionDurationForScreen(DeviceConfig cfg, {required int index}) {
    if (cfg.screens.length <= index) return 1;
    final value = cfg.screens[index].transitionDurationSec ?? 1;
    if (value < 0) return 0;
    if (value > 30) return 30;
    return value;
  }

  String _absoluteUrl(String path) {
    if (path.startsWith('http')) return path;
    return '$_baseUrl$path';
  }

  _PlaylistSelection _resolvePlaylistSelection(
    ScreenConfig screen,
    List<PlaylistConfig> playlists,
  ) {
    final now = DateTime.now();
    final day = now.weekday % 7;
    final playlistById = <String, PlaylistConfig>{
      for (final p in playlists) p.id: p,
    };

    _ResolvedScheduleCandidate? bestActiveForPlaylist(String playlistId) {
      final matches = <_ResolvedScheduleCandidate>[];
      for (final schedule in screen.schedules) {
        if (schedule.playlistId != playlistId) continue;
        if (schedule.dayOfWeek != day) continue;
        final start = _parseTime(schedule.startTime, now);
        final end = _parseTime(schedule.endTime, now);
        if ((now.isAtSameMomentAs(start) || now.isAfter(start)) &&
            now.isBefore(end)) {
          matches.add(_ResolvedScheduleCandidate(schedule, start, end));
        }
      }
      if (matches.isEmpty) return null;
      matches.sort((a, b) {
        final aHasNote = (a.schedule.note ?? '').trim().isNotEmpty ? 1 : 0;
        final bHasNote = (b.schedule.note ?? '').trim().isNotEmpty ? 1 : 0;
        if (aHasNote != bHasNote) return bHasNote.compareTo(aHasNote);
        return b.start.compareTo(a.start);
      });
      return matches.first;
    }

    final forced = (screen.activePlaylistId ?? '').trim();
    if (forced.isNotEmpty && playlists.any((p) => p.id == forced)) {
      final forcedPlaylist = playlistById[forced]!;
      final active = bestActiveForPlaylist(forced);
      if (active != null) {
        DateTime? countdownEnd;
        final playlistCountdown = forcedPlaylist.flashCountdownSec ?? 0;
        if (playlistCountdown > 0) {
          countdownEnd = active.start.add(Duration(seconds: playlistCountdown));
        }
        return _PlaylistSelection(
          playlistId: forced,
          startTime: active.start,
          endTime: active.end,
          countdownEndTime: countdownEnd,
          note: forcedPlaylist.flashNote?.trim(),
          scheduled: true,
        );
      }
      return _PlaylistSelection(
        playlistId: forced,
        startTime: null,
        endTime: null,
        countdownEndTime: (forcedPlaylist.flashCountdownSec ?? 0) > 0
            ? now.add(Duration(seconds: forcedPlaylist.flashCountdownSec!))
            : null,
        note: forcedPlaylist.flashNote?.trim(),
        scheduled:
            forcedPlaylist.isFlashSale ||
            _isFlashSalePlaylistName(forcedPlaylist.name),
      );
    }

    _ResolvedScheduleCandidate? bestActive;
    for (final playlist in playlists) {
      final candidate = bestActiveForPlaylist(playlist.id);
      if (candidate == null) continue;
      if (bestActive == null || candidate.start.isAfter(bestActive.start)) {
        bestActive = candidate;
      }
    }
    if (bestActive != null) {
      DateTime? countdownEnd;
      final activePlaylist = playlistById[bestActive.schedule.playlistId];
      final playlistCountdown = activePlaylist?.flashCountdownSec ?? 0;
      if (playlistCountdown > 0) {
        countdownEnd = bestActive.start.add(Duration(seconds: playlistCountdown));
      }
      return _PlaylistSelection(
        playlistId: bestActive.schedule.playlistId,
        startTime: bestActive.start,
        endTime: bestActive.end,
        countdownEndTime: countdownEnd,
        note: (playlistById[bestActive.schedule.playlistId]?.flashNote ?? '')
            .trim(),
        scheduled: true,
      );
    }

    final fallbackPlaylist = playlists.first;
    return _PlaylistSelection(
      playlistId: fallbackPlaylist.id,
      startTime: null,
      endTime: null,
      countdownEndTime: (fallbackPlaylist.flashCountdownSec ?? 0) > 0
          ? now.add(Duration(seconds: fallbackPlaylist.flashCountdownSec!))
          : null,
      note: fallbackPlaylist.flashNote?.trim(),
      scheduled: fallbackPlaylist.isFlashSale,
    );
  }

  DateTime _parseTime(String value, DateTime now) {
    final parts = value.split(':').map(int.parse).toList();
    return DateTime(
      now.year,
      now.month,
      now.day,
      parts[0],
      parts[1],
      parts.length > 2 ? parts[2] : 0,
    );
  }

  DateTime? _tryParseIsoDateTime(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
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

  List<PlaybackItem> _itemsForGridCell(
    List<PlaybackItem> source,
    int cellIndex,
    int cellCount,
  ) {
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
      return PlaylistPlayer(
        items: _itemsA,
        syncKey: _syncKeyA,
        transitionDurationSec: _transitionDurationSecA,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        const spacing = 1.0;
        final contentWidth = width - ((cols - 1) * spacing);
        final contentHeight = height - ((rows - 1) * spacing);
        final cellWidth = contentWidth / cols;
        final cellHeight = contentHeight / rows;
        final aspectRatio = (cellHeight <= 0) ? 1.0 : (cellWidth / cellHeight);

        return GridView.builder(
          padding: EdgeInsets.zero,
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: cellCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
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
                transitionDurationSec: _transitionDurationSecA,
              ),
            );
          },
        );
      },
    );
  }

  bool _isFlashSalePlaylistName(String name) {
    final value = name.toLowerCase().trim();
    return value.contains('flash sale') ||
        value.contains('flashsale') ||
        value.contains('promo');
  }

  String _flashSaleCountdownLabel() {
    final end = _flashSaleCountdownEndsAtA;
    if (end == null) return '--:--';
    final remaining = end.difference(DateTime.now());
    if (remaining.isNegative || remaining.inSeconds <= 0) return '00:00';
    final minutes = remaining.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final seconds = remaining.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final hours = remaining.inHours;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  List<_BeautyProduct> _flashSaleProductsFromActiveSource() {
    final cfg = _cachedConfig;
    if (cfg == null) return const [];
    final mediaById = <String, MediaItem>{for (final m in cfg.media) m.id: m};
    var raw = _flashSaleProductsJsonA.trim();
    if (raw.isEmpty) {
      PlaylistConfig? active;
      for (final item in cfg.playlists) {
        if (item.id == _syncKeyA) {
          active = item;
          break;
        }
      }
      raw = (active?.flashItemsJson ?? '').trim();
    }
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final rows = <_BeautyProduct>[];
      for (final row in decoded) {
        if (row is! Map) continue;
        final name = (row['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final mediaId = (row['media_id'] ?? '').toString().trim();
        final linkedMedia = mediaById[mediaId];
        final linkedPath = (linkedMedia?.path ?? '').trim();
        rows.add(
          _BeautyProduct(
            name: name,
            brand: (row['brand'] ?? '').toString().trim(),
            normalPrice: 'Rp ${(row['normal_price'] ?? '').toString().trim()}',
            promoPrice: 'Rp ${(row['promo_price'] ?? '').toString().trim()}',
            discountLabel: _discountLabel(
              (row['normal_price'] ?? '').toString().trim(),
              (row['promo_price'] ?? '').toString().trim(),
            ),
            stockLeft:
                int.tryParse((row['stock'] ?? '').toString().trim()) ?? 0,
            mediaType: linkedMedia?.type ?? '',
            mediaUrl: linkedPath.isEmpty ? '' : _absoluteUrl(linkedPath),
            mediaLocalPath: _cachedLocalMap[mediaId] ?? '',
          ),
        );
      }
      return rows;
    } catch (_) {
      return const [];
    }
  }

  String _discountLabel(String normalRaw, String promoRaw) {
    final normal = int.tryParse(normalRaw.replaceAll(RegExp(r'[^0-9]'), ''));
    final promo = int.tryParse(promoRaw.replaceAll(RegExp(r'[^0-9]'), ''));
    if (normal == null || promo == null || normal <= 0 || promo >= normal) {
      return '-0%';
    }
    final pct = (((normal - promo) * 100) / normal).round();
    return '-$pct%';
  }

  Widget _buildFlashSaleOverlay() {
    if (!_flashSaleActiveA) return const SizedBox.shrink();
    final countdown = _flashSaleCountdownLabel();
    final note = _flashSaleNoteA.trim().isNotEmpty
        ? _flashSaleNoteA.trim()
        : 'Atur Note Flash Sale di CMS Desktop';
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    final timeLabel = '$hour:$minute:$second';
    final dynamicProducts = _flashSaleProductsFromActiveSource();
    final products = dynamicProducts.isNotEmpty
        ? dynamicProducts
        : const <_BeautyProduct>[
            _BeautyProduct(
              name: 'Cushion Foundation',
              brand: 'Glow Kiss',
              normalPrice: 'Rp 129.000',
              promoPrice: 'Rp 79.000',
              discountLabel: '-39%',
              stockLeft: 12,
              mediaType: '',
              mediaUrl: '',
              mediaLocalPath: '',
            ),
            _BeautyProduct(
              name: 'Lip Cream Matte',
              brand: 'Velvet Charm',
              normalPrice: 'Rp 99.000',
              promoPrice: 'Rp 59.000',
              discountLabel: '-40%',
              stockLeft: 9,
              mediaType: '',
              mediaUrl: '',
              mediaLocalPath: '',
            ),
            _BeautyProduct(
              name: 'Serum Vitamin C',
              brand: 'Pure Aura',
              normalPrice: 'Rp 189.000',
              promoPrice: 'Rp 109.000',
              discountLabel: '-42%',
              stockLeft: 6,
              mediaType: '',
              mediaUrl: '',
              mediaLocalPath: '',
            ),
            _BeautyProduct(
              name: 'Sunscreen SPF 50',
              brand: 'Sun Veil',
              normalPrice: 'Rp 149.000',
              promoPrice: 'Rp 89.000',
              discountLabel: '-40%',
              stockLeft: 15,
              mediaType: '',
              mediaUrl: '',
              mediaLocalPath: '',
            ),
            _BeautyProduct(
              name: 'Eyeshadow Palette',
              brand: 'Rosy Muse',
              normalPrice: 'Rp 209.000',
              promoPrice: 'Rp 119.000',
              discountLabel: '-43%',
              stockLeft: 7,
              mediaType: '',
              mediaUrl: '',
              mediaLocalPath: '',
            ),
          ];
    const maxVisibleProducts = 5;
    final rotateEnabled = products.length > maxVisibleProducts;
    final rotationStep = rotateEnabled
        ? (now.millisecondsSinceEpoch ~/ 9000) % products.length
        : 0;
    final displayProducts = rotateEnabled
        ? List<_BeautyProduct>.generate(
            maxVisibleProducts,
            (i) => products[(i + rotationStep) % products.length],
          )
        : products;
    final pulse = 0.94 + (math.sin(now.millisecondsSinceEpoch / 380) * 0.06);
    final shimmer = (now.millisecondsSinceEpoch % 2800) / 2800.0;

    String marqueeText(String src) {
      return '💄 🎀 ✨ 🛍️  $src  🔥 Diskon hingga 50%! Gratis gift untuk pembelian di atas Rp 150.000! Stok terbatas! ✨';
    }

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x40126663),
                      Color(0x3523B4A7),
                      Color(0x201E7C74),
                    ],
                  ),
                ),
                child: CustomPaint(
                  painter: _ShimmerParticlePainter(shimmer: shimmer),
                ),
              ),
            ),
          ),
          Positioned(
            top: 10,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xDD0D6F67), Color(0xCC2AC8BA)],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0x66FFFFFF), width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33145C56),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'FLASH SALE BEAUTY',
                              style: GoogleFonts.montserrat(
                                color: Colors.white,
                                fontSize: 25,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Promo Cantik Hari Ini ✨',
                              style: GoogleFonts.poppins(
                                color: const Color(0xFFFDF2F8),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.wifi_rounded,
                                color: Color(0xFFF5F3FF),
                                size: 17,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                timeLabel,
                                style: GoogleFonts.poppins(
                                  color: const Color(0xFFF8FAFC),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Transform.scale(
                            scale: pulse,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xD9FFFFFF),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFFE879F9),
                                  width: 1.2,
                                ),
                              ),
                              child: Text(
                                '⏳ $countdown',
                                style: GoogleFonts.montserrat(
                                  color: const Color(0xFFBE185D),
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.9,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    child: SizedBox(
                      key: ValueKey('${displayProducts.length}:$rotationStep'),
                      height: 122,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: 1 + displayProducts.length,
                        separatorBuilder: (_, index) =>
                            const SizedBox(width: 10),
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return _FlashSaleInfoCard(
                              countdown: countdown,
                              timeLabel: timeLabel,
                              note: note,
                            );
                          }
                          final item = displayProducts[index - 1];
                          final glow =
                              0.4 + ((index % 2 == 0) ? pulse * 0.6 : 0.4);
                          return _BeautyFlashCard(
                            product: item,
                            pulse: pulse,
                            glow: glow,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Container(
                width: double.infinity,
                height: 90,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0xFFF472B6),
                      Color(0xFFFDA4AF),
                      Color(0xFFF59E0B),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0x99FFFFFF), width: 1),
                ),
                child: _RunningTextBanner(text: marqueeText(note), height: 66),
              ),
            ),
          ),
        ],
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
                Text(
                  'Menyiapkan player...',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
                      const Icon(
                        Icons.error_outline,
                        size: 36,
                        color: Color(0xFFB91C1C),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Koneksi Bermasalah',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
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
              AnimatedPadding(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(
                  top: _flashSaleActiveA ? _flashSaleOverlayReservedTop : 0,
                  bottom: _flashSaleActiveA
                      ? _flashSaleOverlayReservedBottom
                      : 0,
                ),
                child: _buildGridPlayback(),
              ),
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
  final DateTime? startTime;
  final DateTime? endTime;
  final DateTime? countdownEndTime;
  final String? note;
  final bool scheduled;

  const _PlaylistSelection({
    required this.playlistId,
    required this.startTime,
    required this.endTime,
    required this.countdownEndTime,
    required this.note,
    required this.scheduled,
  });
}

class _ResolvedScheduleCandidate {
  final ScheduleConfig schedule;
  final DateTime start;
  final DateTime end;

  const _ResolvedScheduleCandidate(this.schedule, this.start, this.end);
}

class _BeautyProduct {
  final String name;
  final String brand;
  final String normalPrice;
  final String promoPrice;
  final String discountLabel;
  final int stockLeft;
  final String mediaType;
  final String mediaUrl;
  final String mediaLocalPath;

  const _BeautyProduct({
    required this.name,
    required this.brand,
    required this.normalPrice,
    required this.promoPrice,
    required this.discountLabel,
    required this.stockLeft,
    required this.mediaType,
    required this.mediaUrl,
    required this.mediaLocalPath,
  });
}

class _BeautyFlashCard extends StatelessWidget {
  final _BeautyProduct product;
  final double pulse;
  final double glow;

  const _BeautyFlashCard({
    required this.product,
    required this.pulse,
    required this.glow,
  });

  @override
  Widget build(BuildContext context) {
    final progress = (product.stockLeft / 20).clamp(0.05, 1.0);
    return Container(
      width: 212,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF9A8D4), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0x1F0F172A),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEC4899),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'FLASH SALE',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 9,
                    ),
                  ),
                ),
                const Spacer(),
                Transform.scale(
                  scale: pulse,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFB7185),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      product.discountLabel,
                      style: GoogleFonts.montserrat(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              product.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.montserrat(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            Text(
              product.brand,
              style: GoogleFonts.poppins(
                fontSize: 11,
                color: const Color(0xFF64748B),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            _FlashSaleProductMediaPreview(product: product),
            const SizedBox(height: 3),
            Text(
              product.normalPrice,
              style: GoogleFonts.poppins(
                fontSize: 10,
                color: const Color(0xFF94A3B8),
                decoration: TextDecoration.lineThrough,
              ),
            ),
            Text(
              product.promoPrice,
              style: GoogleFonts.montserrat(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: const Color(0xFFDB2777),
                shadows: [
                  Shadow(
                    color: const Color(0x99F9A8D4),
                    blurRadius: 9 * glow,
                    offset: const Offset(0, 0),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Sisa ${product.stockLeft} pcs',
              style: GoogleFonts.poppins(
                fontSize: 10,
                color: const Color(0xFF9F1239),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: progress,
                backgroundColor: const Color(0xFFFBCFE8),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFFFB7185),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FlashSaleProductMediaPreview extends StatelessWidget {
  final _BeautyProduct product;

  const _FlashSaleProductMediaPreview({required this.product});

  Widget _placeholder(String message) {
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: GoogleFonts.poppins(
          fontSize: 10,
          color: const Color(0xFF9F1239),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasLocal = product.mediaLocalPath.trim().isNotEmpty;
    final hasRemote = product.mediaUrl.trim().isNotEmpty;
    final isImage = product.mediaType == 'image';
    final hasPreview = isImage && (hasLocal || hasRemote);

    Widget content;
    if (hasPreview) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: hasLocal
            ? Image.file(
                File(product.mediaLocalPath),
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (context, error, stackTrace) {
                  if (hasRemote) {
                    return Image.network(
                      product.mediaUrl,
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (context, error, stackTrace) =>
                          _placeholder('Gagal memuat gambar'),
                    );
                  }
                  return _placeholder('Gagal memuat gambar');
                },
              )
            : Image.network(
                product.mediaUrl,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (context, error, stackTrace) =>
                    _placeholder('Gagal memuat gambar'),
              ),
      );
    } else if (product.mediaType == 'video') {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.ondemand_video, size: 20, color: Color(0xFFDB2777)),
          const SizedBox(height: 2),
          Text(
            'Video Product',
            style: GoogleFonts.poppins(
              fontSize: 10,
              color: const Color(0xFF9F1239),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    } else {
      content = _placeholder('Media belum dipilih');
    }

    return Container(
      height: 40,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF2F8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFBCFE8)),
      ),
      child: content,
    );
  }
}

class _FlashSaleInfoCard extends StatelessWidget {
  final String countdown;
  final String timeLabel;
  final String note;

  const _FlashSaleInfoCard({
    required this.countdown,
    required this.timeLabel,
    required this.note,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 248,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFA7F3D0), width: 1.3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x240F172A),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.auto_awesome,
                  size: 15,
                  color: Color(0xFF0F766E),
                ),
                const SizedBox(width: 6),
                Text(
                  'INFO FLASH SALE',
                  style: GoogleFonts.montserrat(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F766E),
                  ),
                ),
                const Spacer(),
                Text(
                  timeLabel,
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF334155),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFCE7F3),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF9A8D4)),
              ),
              child: Text(
                'Countdown: $countdown',
                style: GoogleFonts.montserrat(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFBE185D),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Text(
                note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShimmerParticlePainter extends CustomPainter {
  final double shimmer;

  const _ShimmerParticlePainter({required this.shimmer});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < 28; i++) {
      final seed = i + 1;
      final t = (shimmer + (seed * 0.067)) % 1.0;
      final x =
          (size.width * ((seed * 0.113) % 1.0)) +
          math.sin(t * math.pi * 2.0) * 16;
      final y =
          (size.height * ((seed * 0.187) % 1.0)) +
          math.cos(t * math.pi * 2.0) * 9;
      final radius = 0.9 + ((seed % 4) * 0.55);
      paint.color = Colors.white.withValues(
        alpha: (0.03 + (math.sin((t + seed) * 6.28) + 1) * 0.03).clamp(
          0.02,
          0.11,
        ),
      );
      canvas.drawCircle(
        Offset(x.clamp(0, size.width), y.clamp(0, size.height)),
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ShimmerParticlePainter oldDelegate) {
    return oldDelegate.shimmer != shimmer;
  }
}

class _RunningTextBanner extends StatefulWidget {
  final String text;
  final double height;

  const _RunningTextBanner({required this.text, this.height = 28});

  @override
  State<_RunningTextBanner> createState() => _RunningTextBannerState();
}

class _RunningTextBannerState extends State<_RunningTextBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      width: double.infinity,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textStyle = const TextStyle(
            color: Color(0xFFFFF7ED),
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          );
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: textStyle),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          final textWidth = painter.width;
          final track = constraints.maxWidth + textWidth + 40;
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final x = constraints.maxWidth - (_controller.value * track);
              return Transform.translate(offset: Offset(x, 0), child: child);
            },
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(widget.text, maxLines: 1, style: textStyle),
              ),
            ),
          );
        },
      ),
    );
  }
}
