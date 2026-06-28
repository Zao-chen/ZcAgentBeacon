import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:zc_agentbeacon_core/zc_agentbeacon_core.dart';

const productName = 'ZcAgentBeacon';
const serverVersion = '0.1.0';
const discoveryAddress = '239.255.42.99';
const discoveryPort = 42179;
const defaultServerPort = 42178;
const defaultCompanionPort = 42180;

Future<void> main(List<String> args) async {
  final server = ZcServer(
    host: stringArg(args, '--host') ??
        env('ZC_AGENTBEACON_SERVER_HOST') ??
        '0.0.0.0',
    port: intArg(args, '--port') ??
        int.tryParse(env('ZC_AGENTBEACON_SERVER_PORT') ?? '') ??
        defaultServerPort,
    webRoot: stringArg(args, '--web-root') ??
        env('ZC_AGENTBEACON_WEB_ROOT') ??
        'apps/dashboard/build/web',
  );
  await server.start();
  stdout.writeln('$productName Server listening on http://${server.host}:${server.port}');
}

class ZcServer {
  ZcServer({
    required this.host,
    required this.port,
    required this.webRoot,
    ZcStatusEngine? engine,
  }) : engine = engine ?? ZcStatusEngine();

  final String host;
  final int port;
  final String webRoot;
  final ZcStatusEngine engine;

  final state = DashboardState();
  final sockets = <WebSocket>{};
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);

  HttpServer? httpServer;
  RawDatagramSocket? discoverySocket;
  Timer? pollTimer;
  Timer? scanTimer;
  Timer? screenTimer;

  Future<void> start() async {
    state.loadManualDevices();
    await startDiscovery();
    await startHttp();
    restartPolling();
    startScanning();
    startScreenControl();
    await pollAll();
  }

  Future<void> startHttp() async {
    final bind = host == '0.0.0.0' ? InternetAddress.anyIPv4 : InternetAddress(host);
    httpServer = await HttpServer.bind(bind, port);
    httpServer!.listen(handleRequest);
  }

  Future<void> startDiscovery() async {
    discoverySocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    try {
      discoverySocket!.joinMulticast(InternetAddress(discoveryAddress));
    } on SocketException {
      // Discovery still works on some networks without multicast join.
    }
    discoverySocket!.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final datagram = discoverySocket!.receive();
      if (datagram == null) {
        return;
      }
      try {
        final payload = jsonDecode(utf8.decode(datagram.data));
        if (payload is Map) {
          state.handleBeacon(payload.cast<String, Object?>(), datagram.address);
        }
      } on Object {
        return;
      }
    });
  }

  void restartPolling() {
    pollTimer?.cancel();
    pollTimer = Timer.periodic(
      Duration(milliseconds: state.settings.pollIntervalMs),
      (_) => pollAll(),
    );
  }

  void startScanning() {
    if (!state.settings.scanEnabled) {
      return;
    }
    scanTimer?.cancel();
    scanTimer = Timer.periodic(
      Duration(seconds: state.settings.scanIntervalSeconds),
      (_) => scanOnce(),
    );
    scanOnce();
  }

  Future<void> pollAll() async {
    final devices = state.devices.values.toList();
    await Future.wait(devices.map(pollDevice));
    broadcast();
  }

  Future<void> pollDevice(DeviceState device) async {
    try {
      final uri = Uri(
        scheme: 'http',
        host: device.host,
        port: device.port,
        path: '/status',
        queryParameters: state.settings.token == null
            ? null
            : {'token': state.settings.token!},
      );
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 2));
      if (state.settings.token != null) {
        request.headers.set('Authorization', 'Bearer ${state.settings.token}');
      }
      final response = await request.close().timeout(const Duration(seconds: 3));
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}: $body');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('Companion returned non-object JSON');
      }
      final snapshot = AgentSnapshot.fromJson(decoded.cast<String, Object?>());
      state.mergeSnapshot(device.key, snapshot, engine);
    } on Object catch (error) {
      state.markDeviceError(device.key, error.toString());
    }
  }

  Future<void> scanOnce() async {
    final hosts = await scanHosts();
    await Future.wait(hosts.map((host) async {
      final found = await probeCompanion(host);
      if (found != null) {
        state.addScannedDevice(found.host, found.port, found.hostname);
      }
    }));
  }

  Future<ProbeResult?> probeCompanion(String host) async {
    try {
      final health = await client
          .getUrl(Uri(scheme: 'http', host: host, port: defaultCompanionPort, path: '/health'))
          .timeout(Duration(milliseconds: state.settings.scanTimeoutMs));
      final healthResponse = await health.close().timeout(const Duration(seconds: 2));
      await healthResponse.drain();
      if (healthResponse.statusCode >= 400) {
        return null;
      }
      final request = await client
          .getUrl(Uri(scheme: 'http', host: host, port: defaultCompanionPort, path: '/status'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(const Duration(seconds: 3));
      final decoded = jsonDecode(await utf8.decoder.bind(response).join());
      if (decoded is! Map || !decoded.containsKey('rawConversations')) {
        return null;
      }
      return ProbeResult(
        host: host,
        port: defaultCompanionPort,
        hostname: decoded['hostname']?.toString() ?? host,
      );
    } on Object {
      return null;
    }
  }

  Future<List<String>> scanHosts() async {
    final cidrs = state.settings.scanCidrs.isNotEmpty
        ? state.settings.scanCidrs
        : await localScanCidrs();
    final hosts = <String>[];
    for (final cidr in cidrs) {
      hosts.addAll(expandCidr(cidr));
    }
    return hosts;
  }

  Future<void> handleRequest(HttpRequest request) async {
    setCors(request.response);
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (request.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(state.snapshot().encode());
      socket.done.whenComplete(() => sockets.remove(socket));
      return;
    }
    if (request.uri.path == '/health') {
      await jsonResponse(request, {'ok': true, 'product': productName, 'version': serverVersion});
      return;
    }
    if (request.uri.path == '/api/conversations') {
      await jsonResponse(request, state.snapshot().toJson());
      return;
    }
    if (request.uri.path == '/api/devices' && request.method == 'GET') {
      await jsonResponse(request, {
        'devices': state.snapshot().devices.map((item) => item.toJson()).toList(),
      });
      return;
    }
    if (request.uri.path == '/api/devices' && request.method == 'POST') {
      await addDevice(request);
      return;
    }
    if (request.uri.path == '/api/settings') {
      if (request.method == 'GET') {
        await jsonResponse(request, state.settings.toJson());
      } else if (request.method == 'POST') {
        await updateSettings(request);
      } else {
        await jsonResponse(request, {'error': 'method_not_allowed'}, HttpStatus.methodNotAllowed);
      }
      return;
    }
    await serveStatic(request);
  }

  Future<void> addDevice(HttpRequest request) async {
    final decoded = await readJsonObject(request);
    final host = decoded['host']?.toString().trim() ?? '';
    final port = int.tryParse(decoded['port']?.toString() ?? '') ?? defaultCompanionPort;
    if (host.isEmpty) {
      await jsonResponse(request, {'error': 'invalid_device'}, HttpStatus.badRequest);
      return;
    }
    state.addManualDevice(host, port, decoded['hostname']?.toString());
    await pollAll();
    await jsonResponse(request, state.snapshot().toJson(), HttpStatus.created);
  }

  Future<void> updateSettings(HttpRequest request) async {
    final decoded = await readJsonObject(request);
    state.settings = DashboardSettings.fromJson(decoded);
    restartPolling();
    startScanning();
    broadcast();
    await jsonResponse(request, state.settings.toJson());
  }

  Future<void> serveStatic(HttpRequest request) async {
    var path = Uri.decodeComponent(request.uri.path);
    if (path == '/') {
      path = '/index.html';
    }
    path = path.replaceAll('\\', '/');
    if (path.contains('..')) {
      await jsonResponse(request, {'error': 'forbidden'}, HttpStatus.forbidden);
      return;
    }
    final file = File(joinPath(webRoot, path.substring(1)));
    if (await file.exists()) {
      request.response.headers.contentType = contentType(file.path);
      request.response.headers.set('Cache-Control', 'no-store, max-age=0');
      await file.openRead().pipe(request.response);
      return;
    }
    final index = File(joinPath(webRoot, 'index.html'));
    if (await index.exists()) {
      request.response.headers.contentType = ContentType.html;
      await index.openRead().pipe(request.response);
      return;
    }
    request.response.headers.contentType = ContentType.html;
    request.response.write('<!doctype html><meta charset="utf-8"><h1>ZcAgentBeacon server is running</h1>');
    await request.response.close();
  }

  void broadcast() {
    final encoded = state.snapshot().encode();
    for (final socket in sockets.toList()) {
      if (socket.readyState == WebSocket.open) {
        socket.add(encoded);
      }
    }
  }

  void startScreenControl() {
    if (!state.settings.screenControlEnabled || !Platform.isLinux) {
      return;
    }
    screenTimer?.cancel();
    unblankScreen();
    screenTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final idleFor = DateTime.now().toUtc().difference(state.lastActivityAt);
      if (!state.screenBlanked && idleFor.inSeconds >= state.settings.screenIdleSeconds) {
        blankScreen();
      } else if (state.screenBlanked && state.lastActivityAt.isAfter(state.screenBlankedAt!)) {
        unblankScreen();
      }
    });
  }

  Future<void> blankScreen() async {
    await xset(['s', 'blank']);
    await xset(['s', 'activate']);
    await xset(['+dpms']);
    await xset(['dpms', 'force', 'off']);
    state.screenBlanked = true;
    state.screenBlankedAt = DateTime.now().toUtc();
  }

  Future<void> unblankScreen() async {
    await xset(['dpms', 'force', 'on']);
    await xset(['s', 'reset']);
    await xset(['-dpms']);
    await xset(['s', 'off']);
    state.screenBlanked = false;
  }

  Future<void> xset(List<String> args) async {
    try {
      await Process.run('/usr/bin/xset', args, environment: {
        ...Platform.environment,
        'DISPLAY': state.settings.screenDisplay,
        'XAUTHORITY': state.settings.screenXauthority,
      }).timeout(const Duration(seconds: 3));
    } on Object {
      return;
    }
  }
}

class DashboardState {
  final devices = <String, DeviceState>{};
  final history = <String, ConversationView>{};
  DashboardSettings settings = DashboardSettings.fromEnvironment();
  DateTime lastActivityAt = DateTime.now().toUtc();
  String lastActivityReason = 'startup';
  bool screenBlanked = false;
  DateTime? screenBlankedAt;

  void loadManualDevices() {
    for (final entry in settings.manualDevices) {
      final parts = entry.split(':');
      if (parts.isEmpty || parts.first.trim().isEmpty) {
        continue;
      }
      addManualDevice(
        parts.first.trim(),
        parts.length > 1 ? int.tryParse(parts[1]) ?? defaultCompanionPort : defaultCompanionPort,
        null,
      );
    }
  }

  void handleBeacon(Map<String, Object?> payload, InternetAddress address) {
    final kind = payload['kind']?.toString();
    if (kind != 'zc-agentbeacon.companion') {
      return;
    }
    addScannedDevice(
      address.address,
      int.tryParse(payload['port']?.toString() ?? '') ?? defaultCompanionPort,
      payload['hostname']?.toString(),
    );
  }

  void addManualDevice(String host, int port, String? hostname) {
    upsertDevice(host, port, hostname, manual: true, prefix: 'manual');
  }

  void addScannedDevice(String host, int port, String? hostname) {
    upsertDevice(host, port, hostname, manual: false, prefix: 'scan');
    final device = devices.values
        .where((item) => item.host == host && item.port == port)
        .firstOrNull;
    device?.lastBeaconAt = DateTime.now().toUtc();
  }

  void upsertDevice(
    String host,
    int port,
    String? hostname, {
    required bool manual,
    required String prefix,
  }) {
    final existing = devices.values
        .where((item) => item.host == host && item.port == port)
        .firstOrNull;
    if (existing != null) {
      existing.hostname = hostname ?? existing.hostname;
      existing.manual = existing.manual || manual;
      return;
    }
    final key = '$prefix:$host:$port';
    devices[key] = DeviceState(
      key: key,
      nodeId: key,
      hostname: hostname ?? host,
      host: host,
      port: port,
      manual: manual,
    );
  }

  void mergeSnapshot(String key, AgentSnapshot snapshot, ZcStatusEngine engine) {
    final device = devices[key];
    if (device == null) {
      return;
    }
    device
      ..nodeId = snapshot.nodeId.isEmpty ? device.nodeId : snapshot.nodeId
      ..hostname = snapshot.hostname.isEmpty ? device.hostname : snapshot.hostname
      ..os = snapshot.os
      ..snapshot = snapshot
      ..lastSeenAt = DateTime.now().toUtc()
      ..lastError = null;

    final activeKeys = <String>{};
    final items = engine.conversationsFromRaw(snapshot.rawConversations);
    for (final item in items) {
      if (auxiliaryProcessShadow(item)) {
        final peer = historyPeerForShadow(device.nodeId, item);
        if (peer != null) {
          final merged = mergeAuxiliaryShadow(peer.value, item).copyWith(
            seenAt: DateTime.now().toUtc(),
          );
          history[peer.key] = merged;
          if (item.status.isActive) {
            activeKeys.add(peer.key);
          }
          markActivity('conversation_changed');
          continue;
        }
      }
      final historyKey = '${device.nodeId}:${item.conversationId}';
      activeKeys.add(historyKey);
      final copied = item.copyWith(
        deviceId: device.nodeId,
        deviceName: device.hostname,
        deviceHost: '${device.host}:${device.port}',
        seenAt: DateTime.now().toUtc(),
      );
      final previous = history[historyKey];
      if (previous == null || jsonEncode(previous.toJson()) != jsonEncode(copied.toJson())) {
        markActivity('conversation_changed');
      }
      history[historyKey] = copied;
    }
    purgeAuxiliaryHistory(device.nodeId);
    for (final entry in history.entries.toList()) {
      final item = entry.value;
      if (item.deviceId != device.nodeId || activeKeys.contains(entry.key)) {
        continue;
      }
      if (item.status.isActive) {
        history[entry.key] = item.copyWith(
          status: ConversationStatus.idle,
          completedAt: DateTime.now().toUtc(),
        );
        markActivity('conversation_completed');
      }
    }
  }

  MapEntry<String, ConversationView>? historyPeerForShadow(
    String deviceId,
    ConversationView shadow,
  ) {
    final cwd = normalizeCwd(shadow.cwd);
    final candidates = history.entries.where((entry) {
      final item = entry.value;
      return item.deviceId == deviceId &&
          !auxiliaryProcessShadow(item) &&
          normalizeCwd(item.cwd) == cwd;
    }).toList();
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) {
      final aTime = a.value.lastEventAt ?? a.value.seenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.value.lastEventAt ?? b.value.seenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return candidates.first;
  }

  void purgeAuxiliaryHistory(String deviceId) {
    final humanCwds = history.values
        .where((item) => item.deviceId == deviceId && !auxiliaryProcessShadow(item))
        .map((item) => normalizeCwd(item.cwd))
        .toSet();
    for (final entry in history.entries.toList()) {
      final item = entry.value;
      if (item.deviceId == deviceId &&
          auxiliaryProcessShadow(item) &&
          (!item.status.isActive || humanCwds.contains(normalizeCwd(item.cwd)))) {
        history.remove(entry.key);
      }
    }
  }

  void markDeviceError(String key, String error) {
    final device = devices[key];
    if (device != null) {
      device.lastError = error;
    }
  }

  void markActivity(String reason) {
    lastActivityAt = DateTime.now().toUtc();
    lastActivityReason = reason;
  }

  DashboardSnapshot snapshot() {
    final now = DateTime.now().toUtc();
    final deviceViews = devices.values.map((device) {
      final status = deviceStatus(device, now);
      return DeviceView(
        nodeId: device.nodeId,
        hostname: device.hostname,
        host: device.host,
        port: device.port,
        os: device.os,
        status: status,
        codexRunning: device.snapshot?.codexRunning ?? false,
        conversationCount: device.snapshot?.rawConversations.length ?? 0,
        lastSeenAt: device.lastSeenAt,
        lastBeaconAt: device.lastBeaconAt,
        lastError: device.lastError,
        manual: device.manual,
      );
    }).toList()
      ..sort((a, b) => a.hostname.compareTo(b.hostname));
    final deviceStatusById = {
      for (final item in deviceViews) item.nodeId: item.status,
    };
    final conversations = <ConversationView>[];
    final humanCwdsByDevice = <String?, Set<String>>{};
    for (final item in history.values) {
      if (auxiliaryProcessShadow(item)) {
        continue;
      }
      humanCwdsByDevice.putIfAbsent(item.deviceId, () => {}).add(normalizeCwd(item.cwd));
    }
    for (final item in history.values) {
      if (auxiliaryProcessShadow(item) &&
          (!item.status.isActive ||
              (humanCwdsByDevice[item.deviceId] ?? {}).contains(normalizeCwd(item.cwd)))) {
        continue;
      }
      final deviceStatus = deviceStatusById[item.deviceId];
      conversations.add(
        deviceStatus == ConversationStatus.stale ||
                deviceStatus == ConversationStatus.errorOffline
            ? item.copyWith(status: deviceStatus!)
            : item,
      );
    }
    conversations.sort((a, b) {
      final aTime = a.lastEventAt ?? a.seenAt ?? a.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.lastEventAt ?? b.seenAt ?? b.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return DashboardSnapshot(
      generatedAt: now,
      devices: deviceViews,
      conversations: conversations,
      screen: {
        'controlEnabled': settings.screenControlEnabled,
        'idleAfterSeconds': settings.screenIdleSeconds,
        'lastActivityAt': lastActivityAt.toIso8601String(),
        'lastActivityReason': lastActivityReason,
      },
    );
  }

  ConversationStatus deviceStatus(DeviceState device, DateTime now) {
    final lastSeen = device.lastSeenAt;
    if (lastSeen == null) {
      return ConversationStatus.errorOffline;
    }
    final age = now.difference(lastSeen).inSeconds;
    if (age >= settings.offlineAfterSeconds) {
      return ConversationStatus.errorOffline;
    }
    if (age >= settings.staleAfterSeconds) {
      return ConversationStatus.stale;
    }
    return ConversationStatus.idle;
  }
}

class DeviceState {
  DeviceState({
    required this.key,
    required this.nodeId,
    required this.hostname,
    required this.host,
    required this.port,
    this.manual = false,
  });

  final String key;
  String nodeId;
  String hostname;
  String host;
  int port;
  String os = '';
  bool manual;
  DateTime? lastBeaconAt;
  DateTime? lastSeenAt;
  AgentSnapshot? snapshot;
  String? lastError;
}

class DashboardSettings {
  const DashboardSettings({
    this.pollIntervalMs = 2000,
    this.staleAfterSeconds = 15,
    this.offlineAfterSeconds = 45,
    this.scanEnabled = true,
    this.scanIntervalSeconds = 60,
    this.scanTimeoutMs = 1200,
    this.scanCidrs = const [],
    this.manualDevices = const [],
    this.screenControlEnabled = true,
    this.screenIdleSeconds = 600,
    this.screenDisplay = ':0',
    this.screenXauthority = '/home/pi/.Xauthority',
    this.token,
  });

  final int pollIntervalMs;
  final int staleAfterSeconds;
  final int offlineAfterSeconds;
  final bool scanEnabled;
  final int scanIntervalSeconds;
  final int scanTimeoutMs;
  final List<String> scanCidrs;
  final List<String> manualDevices;
  final bool screenControlEnabled;
  final int screenIdleSeconds;
  final String screenDisplay;
  final String screenXauthority;
  final String? token;

  Map<String, Object?> toJson() => {
        'pollIntervalMs': pollIntervalMs,
        'staleAfterSeconds': staleAfterSeconds,
        'offlineAfterSeconds': offlineAfterSeconds,
        'scanEnabled': scanEnabled,
        'scanIntervalSeconds': scanIntervalSeconds,
        'scanTimeoutMs': scanTimeoutMs,
        'scanCidrs': scanCidrs,
        'screenControlEnabled': screenControlEnabled,
        'screenIdleSeconds': screenIdleSeconds,
        'tokenEnabled': token != null && token!.isNotEmpty,
      };

  factory DashboardSettings.fromEnvironment() {
    return DashboardSettings(
      pollIntervalMs: int.tryParse(env('ZC_AGENTBEACON_POLL_INTERVAL_MS') ?? '') ?? 2000,
      staleAfterSeconds: int.tryParse(env('ZC_AGENTBEACON_STALE_SECONDS') ?? '') ?? 15,
      offlineAfterSeconds: int.tryParse(env('ZC_AGENTBEACON_OFFLINE_SECONDS') ?? '') ?? 45,
      scanEnabled: envFlag('ZC_AGENTBEACON_SCAN_ENABLED', true),
      scanIntervalSeconds: max(10, int.tryParse(env('ZC_AGENTBEACON_SCAN_INTERVAL_SECONDS') ?? '') ?? 60),
      scanTimeoutMs: max(200, int.tryParse(env('ZC_AGENTBEACON_SCAN_TIMEOUT_MS') ?? '') ?? 1200),
      scanCidrs: splitEnv('ZC_AGENTBEACON_SCAN_CIDRS'),
      manualDevices: splitEnv('ZC_AGENTBEACON_DEVICES'),
      screenControlEnabled: envFlag('ZC_AGENTBEACON_SCREEN_CONTROL', true),
      screenIdleSeconds: max(10, int.tryParse(env('ZC_AGENTBEACON_SCREEN_IDLE_SECONDS') ?? '') ?? 600),
      screenDisplay: env('ZC_AGENTBEACON_SCREEN_DISPLAY') ?? ':0',
      screenXauthority: env('ZC_AGENTBEACON_SCREEN_XAUTHORITY') ??
          (Platform.environment['HOME'] == null ? '/home/pi/.Xauthority' : '${Platform.environment['HOME']}/.Xauthority'),
      token: env('ZC_AGENTBEACON_TOKEN'),
    );
  }

  factory DashboardSettings.fromJson(Map<String, Object?> json) {
    final base = DashboardSettings.fromEnvironment();
    return DashboardSettings(
      pollIntervalMs: max(500, int.tryParse(json['pollIntervalMs']?.toString() ?? '') ?? base.pollIntervalMs),
      staleAfterSeconds: max(1, int.tryParse(json['staleAfterSeconds']?.toString() ?? '') ?? base.staleAfterSeconds),
      offlineAfterSeconds: max(1, int.tryParse(json['offlineAfterSeconds']?.toString() ?? '') ?? base.offlineAfterSeconds),
      scanEnabled: json['scanEnabled'] is bool ? json['scanEnabled'] as bool : base.scanEnabled,
      scanIntervalSeconds: max(10, int.tryParse(json['scanIntervalSeconds']?.toString() ?? '') ?? base.scanIntervalSeconds),
      scanTimeoutMs: max(200, int.tryParse(json['scanTimeoutMs']?.toString() ?? '') ?? base.scanTimeoutMs),
      scanCidrs: (json['scanCidrs'] is List)
          ? (json['scanCidrs'] as List).map((item) => item.toString()).toList()
          : base.scanCidrs,
      manualDevices: base.manualDevices,
      screenControlEnabled: json['screenControlEnabled'] is bool
          ? json['screenControlEnabled'] as bool
          : base.screenControlEnabled,
      screenIdleSeconds: max(10, int.tryParse(json['screenIdleSeconds']?.toString() ?? '') ?? base.screenIdleSeconds),
      screenDisplay: base.screenDisplay,
      screenXauthority: base.screenXauthority,
      token: base.token,
    );
  }
}

class ProbeResult {
  const ProbeResult({required this.host, required this.port, required this.hostname});
  final String host;
  final int port;
  final String hostname;
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

Future<Map<String, Object?>> readJsonObject(HttpRequest request) async {
  final body = await utf8.decoder.bind(request).join();
  final decoded = jsonDecode(body.isEmpty ? '{}' : body);
  if (decoded is Map) {
    return decoded.cast<String, Object?>();
  }
  return {};
}

Future<void> jsonResponse(
  HttpRequest request,
  Object body, [
  int status = HttpStatus.ok,
]) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.headers.set('Cache-Control', 'no-store, max-age=0');
  request.response.write(jsonEncode(body));
  await request.response.close();
}

void setCors(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  response.headers.set('Access-Control-Allow-Headers', 'Content-Type,Authorization');
}

ContentType contentType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.html')) return ContentType.html;
  if (lower.endsWith('.js')) return ContentType('application', 'javascript', charset: 'utf-8');
  if (lower.endsWith('.css')) return ContentType('text', 'css', charset: 'utf-8');
  if (lower.endsWith('.json')) return ContentType.json;
  if (lower.endsWith('.png')) return ContentType('image', 'png');
  if (lower.endsWith('.svg')) return ContentType('image', 'svg+xml');
  if (lower.endsWith('.wav')) return ContentType('audio', 'wav');
  return ContentType.binary;
}

Future<List<String>> localScanCidrs() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (isPrivateIpv4(address.address)) {
          final parts = address.address.split('.');
          return ['${parts[0]}.${parts[1]}.${parts[2]}.0/24'];
        }
      }
    }
  } on Object {
    return const [];
  }
  return const [];
}

List<String> expandCidr(String cidr) {
  final parts = cidr.split('/');
  if (parts.length != 2 || parts[1] != '24') {
    return const [];
  }
  final octets = parts[0].split('.').map(int.tryParse).toList();
  if (octets.length != 4 || octets.any((item) => item == null)) {
    return const [];
  }
  return [
    for (var i = 1; i < 255; i++) '${octets[0]}.${octets[1]}.${octets[2]}.$i',
  ];
}

bool isPrivateIpv4(String address) {
  final parts = address.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((item) => item == null)) {
    return false;
  }
  final first = parts[0]!;
  final second = parts[1]!;
  return first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 169 && second == 254);
}

String? stringArg(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}

int? intArg(List<String> args, String name) => int.tryParse(stringArg(args, name) ?? '');

String? env(String name) {
  final value = Platform.environment[name];
  return value == null || value.trim().isEmpty ? null : value.trim();
}

bool envFlag(String name, bool fallback) {
  final value = env(name)?.toLowerCase();
  if (value == null) return fallback;
  return !['0', 'false', 'no', 'off'].contains(value);
}

List<String> splitEnv(String name) {
  return (env(name) ?? '')
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

String joinPath(String first, String second) {
  final normalized = second.replaceAll('/', Platform.pathSeparator);
  return first.endsWith(Platform.pathSeparator)
      ? '$first$normalized'
      : '$first${Platform.pathSeparator}$normalized';
}
