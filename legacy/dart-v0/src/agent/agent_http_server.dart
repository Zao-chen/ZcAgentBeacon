import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'codex_data_reader.dart';

class AgentHttpServer {
  AgentHttpServer({
    required this.host,
    required this.port,
    CodexDataReader? reader,
    this.discoveryAddress = '239.255.42.99',
    this.discoveryPort = 42179,
    this.allowedServer,
  }) : _reader = reader ?? CodexDataReader();

  final String host;
  final int port;
  final String discoveryAddress;
  final int discoveryPort;
  final String? allowedServer;
  final CodexDataReader _reader;

  HttpServer? _httpServer;
  RawDatagramSocket? _discoverySocket;
  Timer? _beaconTimer;

  Future<void> start() async {
    final bindAddress =
        host == '0.0.0.0' ? InternetAddress.anyIPv4 : host;
    _httpServer = await HttpServer.bind(bindAddress, port);
    _httpServer!.listen(_handleRequest);
    await _startDiscovery();
  }

  Future<void> stop() async {
    _beaconTimer?.cancel();
    _discoverySocket?.close();
    await _httpServer?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _setCors(request.response);
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    if (!_isAllowed(request)) {
      await _json(
        request,
        {'error': 'forbidden'},
        statusCode: HttpStatus.forbidden,
      );
      return;
    }

    if (request.uri.path == '/health') {
      await _json(request, {'ok': true});
      return;
    }

    if (request.uri.path == '/status') {
      final snapshot = await _reader.collect();
      await _json(request, snapshot.toJson());
      return;
    }

    await _json(request, {'error': 'not_found'}, statusCode: HttpStatus.notFound);
  }

  bool _isAllowed(HttpRequest request) {
    if (allowedServer == null || allowedServer!.trim().isEmpty) {
      return true;
    }
    final remote = request.connectionInfo?.remoteAddress.address;
    final allowed = allowedServer!
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
    return remote != null && allowed.contains(remote);
  }

  Future<void> _startDiscovery() async {
    _discoverySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sendBeacon();
    _beaconTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _sendBeacon();
    });
  }

  void _sendBeacon() {
    final socket = _discoverySocket;
    if (socket == null) {
      return;
    }

    final beacon = jsonEncode({
      'kind': 'agentbeacon.agent',
      'version': '0.1.0',
      'hostname': Platform.localHostname,
      'os': Platform.operatingSystem,
      'port': port,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
    });
    socket.send(
      utf8.encode(beacon),
      InternetAddress(discoveryAddress),
      discoveryPort,
    );
  }

  Future<void> _json(
    HttpRequest request,
    Object body, {
    int statusCode = HttpStatus.ok,
  }) async {
    final response = request.response;
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  void _setCors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  }
}
