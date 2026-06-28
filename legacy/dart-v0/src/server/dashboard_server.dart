import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../shared/agent_models.dart';

class DashboardSettings {
  const DashboardSettings({
    this.pollIntervalMs = 2000,
    this.staleAfterSeconds = 15,
    this.offlineAfterSeconds = 45,
    this.showDetails = true,
  });

  final int pollIntervalMs;
  final int staleAfterSeconds;
  final int offlineAfterSeconds;
  final bool showDetails;

  DashboardSettings copyWith({
    int? pollIntervalMs,
    int? staleAfterSeconds,
    int? offlineAfterSeconds,
    bool? showDetails,
  }) {
    return DashboardSettings(
      pollIntervalMs: pollIntervalMs ?? this.pollIntervalMs,
      staleAfterSeconds: staleAfterSeconds ?? this.staleAfterSeconds,
      offlineAfterSeconds: offlineAfterSeconds ?? this.offlineAfterSeconds,
      showDetails: showDetails ?? this.showDetails,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'pollIntervalMs': pollIntervalMs,
      'staleAfterSeconds': staleAfterSeconds,
      'offlineAfterSeconds': offlineAfterSeconds,
      'showDetails': showDetails,
    };
  }

  factory DashboardSettings.fromJson(Map<String, Object?> json) {
    return DashboardSettings(
      pollIntervalMs: _int(json['pollIntervalMs'], fallback: 2000),
      staleAfterSeconds: _int(json['staleAfterSeconds'], fallback: 15),
      offlineAfterSeconds: _int(json['offlineAfterSeconds'], fallback: 45),
      showDetails: json['showDetails'] != false,
    );
  }
}

class DashboardServer {
  DashboardServer({
    required this.host,
    required this.port,
    this.webRoot = 'build/web',
    this.discoveryAddress = '239.255.42.99',
    this.discoveryPort = 42179,
  });

  final String host;
  final int port;
  final String webRoot;
  final String discoveryAddress;
  final int discoveryPort;

  final Map<String, _DeviceState> _devices = {};
  final Set<WebSocket> _sockets = {};
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);

  DashboardSettings _settings = const DashboardSettings();
  HttpServer? _server;
  RawDatagramSocket? _discoverySocket;
  Timer? _pollTimer;

  Future<void> start() async {
    _loadManualDevicesFromEnvironment();
    await _startDiscovery();
    await _startHttp();
    _restartPollTimer();
    await _pollAll();
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _discoverySocket?.close();
    for (final socket in _sockets.toList()) {
      await socket.close();
    }
    _client.close(force: true);
    await _server?.close(force: true);
  }

  Future<void> _startHttp() async {
    final bindAddress =
        host == '0.0.0.0' ? InternetAddress.anyIPv4 : host;
    _server = await HttpServer.bind(bindAddress, port);
    _server!.listen(_handleRequest);
  }

  Future<void> _startDiscovery() async {
    final multicast = InternetAddress(discoveryAddress);
    _discoverySocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    try {
      _discoverySocket!.joinMulticast(multicast);
    } on SocketException {
      // Some platforms still receive local multicast without explicit join.
    }
    _discoverySocket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = _discoverySocket!.receive();
        if (datagram != null) {
          _handleBeacon(datagram);
        }
      }
    });
  }

  void _handleBeacon(Datagram datagram) {
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map || decoded['kind'] != 'agentbeacon.agent') {
        return;
      }

      final port = _int(decoded['port'], fallback: 42180);
      final host = datagram.address.address;
      final key = '$host:$port';
      final device = _devices.putIfAbsent(
        key,
        () => _DeviceState(
          key: key,
          nodeId: key,
          host: host,
          port: port,
          hostname: decoded['hostname']?.toString() ?? host,
          os: decoded['os']?.toString() ?? '',
        ),
      );
      device
        ..host = host
        ..port = port
        ..hostname = decoded['hostname']?.toString() ?? device.hostname
        ..os = decoded['os']?.toString() ?? device.os
        ..lastBeaconAt = DateTime.now().toUtc();
    } on Object {
      return;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _setCors(request.response);
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    if (request.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.add(_snapshot().encode());
      socket.done.whenComplete(() => _sockets.remove(socket));
      return;
    }

    if (request.uri.path == '/api/conversations') {
      await _json(request, _snapshot().toJson());
      return;
    }

    if (request.uri.path == '/api/devices' && request.method == 'GET') {
      await _json(
        request,
        {'devices': _snapshot().devices.map((device) => device.toJson()).toList()},
      );
      return;
    }

    if (request.uri.path == '/api/devices' && request.method == 'POST') {
      await _addManualDevice(request);
      return;
    }

    if (request.uri.path == '/api/settings' && request.method == 'GET') {
      await _json(request, _settings.toJson());
      return;
    }

    if (request.uri.path == '/api/settings' && request.method == 'POST') {
      await _updateSettings(request);
      return;
    }

    await _serveStatic(request);
  }

  Future<void> _addManualDevice(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      await _json(request, {'error': 'invalid_json'}, statusCode: HttpStatus.badRequest);
      return;
    }

    final host = decoded['host']?.toString().trim() ?? '';
    final port = _int(decoded['port'], fallback: 42180);
    if (host.isEmpty || port <= 0) {
      await _json(request, {'error': 'invalid_device'}, statusCode: HttpStatus.badRequest);
      return;
    }

    final key = 'manual:$host:$port';
    final hostname = decoded['hostname']?.toString().trim() ?? '';
    _devices[key] = _DeviceState(
      key: key,
      nodeId: key,
      host: host,
      port: port,
      hostname: hostname.isNotEmpty ? hostname : host,
      os: decoded['os']?.toString() ?? '',
      manual: true,
    );
    await _pollAll();
    await _json(request, _snapshot().toJson(), statusCode: HttpStatus.created);
  }

  Future<void> _updateSettings(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      await _json(request, {'error': 'invalid_json'}, statusCode: HttpStatus.badRequest);
      return;
    }
    _settings = DashboardSettings.fromJson(decoded.cast<String, Object?>());
    _restartPollTimer();
    _broadcast();
    await _json(request, _settings.toJson());
  }

  void _restartPollTimer() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      Duration(milliseconds: _settings.pollIntervalMs),
      (_) => _pollAll(),
    );
  }

  Future<void> _pollAll() async {
    await Future.wait(_devices.values.map(_pollDevice));
    _broadcast();
  }

  Future<void> _pollDevice(_DeviceState device) async {
    try {
      final uri = Uri(
        scheme: 'http',
        host: device.host,
        port: device.port,
        path: '/status',
      );
      final request = await _client.getUrl(uri).timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(const Duration(seconds: 3));
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}: $body');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('Agent returned non-object JSON');
      }

      final snapshot = AgentSnapshot.fromJson(decoded.cast<String, Object?>());
      device
        ..nodeId = snapshot.nodeId.isEmpty ? device.nodeId : snapshot.nodeId
        ..hostname = snapshot.hostname.isEmpty ? device.hostname : snapshot.hostname
        ..os = snapshot.os.isEmpty ? device.os : snapshot.os
        ..snapshot = snapshot
        ..lastSeenAt = DateTime.now().toUtc()
        ..lastError = null;
    } on Object catch (error) {
      device.lastError = error.toString();
    }
  }

  DashboardSnapshot _snapshot() {
    final now = DateTime.now().toUtc();
    final deviceViews = _devices.values.map((device) {
      final status = _deviceStatus(device, now);
      return DeviceStatusView(
        nodeId: device.nodeId,
        hostname: device.hostname,
        host: device.host,
        port: device.port,
        os: device.os,
        status: status,
        codexRunning: device.snapshot?.codexRunning ?? false,
        conversationCount: device.snapshot?.conversations.length ?? 0,
        lastSeenAt: device.lastSeenAt,
        lastBeaconAt: device.lastBeaconAt,
        lastError: device.lastError,
        manual: device.manual,
      );
    }).toList()
      ..sort((a, b) => a.hostname.compareTo(b.hostname));

    final conversations = <AgentConversation>[];
    for (final device in _devices.values) {
      if (_deviceStatus(device, now) == ConversationRuntimeStatus.errorOffline) {
        continue;
      }
      for (final conversation in device.snapshot?.conversations ?? const []) {
        if (!conversation.status.isActive) {
          continue;
        }
        conversations.add(
          conversation.copyWithDevice(
            deviceId: device.nodeId,
            deviceName: device.hostname,
            deviceHost: '${device.host}:${device.port}',
          ),
        );
      }
    }
    conversations.sort((a, b) {
      final aTime = a.lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });

    return DashboardSnapshot(
      devices: deviceViews,
      conversations: conversations,
      generatedAt: now,
    );
  }

  ConversationRuntimeStatus _deviceStatus(_DeviceState device, DateTime now) {
    final lastSeen = device.lastSeenAt;
    if (lastSeen == null) {
      return ConversationRuntimeStatus.errorOffline;
    }
    final age = now.difference(lastSeen);
    if (age.inSeconds >= _settings.offlineAfterSeconds) {
      return ConversationRuntimeStatus.errorOffline;
    }
    if (age.inSeconds >= _settings.staleAfterSeconds) {
      return ConversationRuntimeStatus.stale;
    }
    return ConversationRuntimeStatus.idle;
  }

  void _broadcast() {
    final encoded = _snapshot().encode();
    for (final socket in _sockets.toList()) {
      if (socket.readyState == WebSocket.open) {
        socket.add(encoded);
      }
    }
  }

  Future<void> _serveStatic(HttpRequest request) async {
    final root = Directory(webRoot);
    var path = Uri.decodeComponent(request.uri.path);
    if (path == '/') {
      path = '/index.html';
    }
    path = path.replaceAll('\\', '/');
    if (path.contains('..')) {
      await _json(request, {'error': 'forbidden'}, statusCode: HttpStatus.forbidden);
      return;
    }

    final file = File(_join(root.path, path.substring(1)));
    if (await file.exists()) {
      request.response.headers.contentType = _contentType(file.path);
      await file.openRead().pipe(request.response);
      return;
    }

    final index = File(_join(root.path, 'index.html'));
    if (await index.exists()) {
      request.response.headers.contentType = ContentType.html;
      await index.openRead().pipe(request.response);
      return;
    }

    request.response.headers.contentType = ContentType.html;
    request.response.write('''
<!doctype html>
<html>
<head><meta charset="utf-8"><title>AgentBeacon</title></head>
<body><h1>AgentBeacon server is running</h1><p>Build Flutter Web into build/web to serve the dashboard.</p></body>
</html>
''');
    await request.response.close();
  }

  ContentType _contentType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.html')) {
      return ContentType.html;
    }
    if (lower.endsWith('.js')) {
      return ContentType('application', 'javascript', charset: 'utf-8');
    }
    if (lower.endsWith('.css')) {
      return ContentType('text', 'css', charset: 'utf-8');
    }
    if (lower.endsWith('.json')) {
      return ContentType.json;
    }
    if (lower.endsWith('.png')) {
      return ContentType('image', 'png');
    }
    if (lower.endsWith('.svg')) {
      return ContentType('image', 'svg+xml');
    }
    return ContentType.binary;
  }

  Future<void> _json(
    HttpRequest request,
    Object body, {
    int statusCode = HttpStatus.ok,
  }) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  void _setCors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  }

  void _loadManualDevicesFromEnvironment() {
    final devices = Platform.environment['AGENTBEACON_DEVICES'];
    if (devices == null || devices.trim().isEmpty) {
      return;
    }
    for (final entry in devices.split(',')) {
      final parts = entry.trim().split(':');
      if (parts.length != 2) {
        continue;
      }
      final host = parts[0].trim();
      final port = int.tryParse(parts[1].trim()) ?? 42180;
      if (host.isEmpty) {
        continue;
      }
      final key = 'manual:$host:$port';
      _devices[key] = _DeviceState(
        key: key,
        nodeId: key,
        host: host,
        port: port,
        hostname: host,
        os: '',
        manual: true,
      );
    }
  }

  String _join(String first, String second) {
    final separator = Platform.pathSeparator;
    return first.endsWith(separator) ? '$first$second' : '$first$separator$second';
  }
}

class _DeviceState {
  _DeviceState({
    required this.key,
    required this.nodeId,
    required this.host,
    required this.port,
    required this.hostname,
    required this.os,
    this.manual = false,
  });

  final String key;
  String nodeId;
  String host;
  int port;
  String hostname;
  String os;
  bool manual;
  DateTime? lastBeaconAt;
  DateTime? lastSeenAt;
  AgentSnapshot? snapshot;
  String? lastError;
}

int _int(Object? value, {required int fallback}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}
