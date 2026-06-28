import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zc_agentbeacon_core/codex_adapter.dart';

const productName = 'ZcAgentBeacon';
const companionVersion = '0.1.0';
const discoveryAddress = '239.255.42.99';
const discoveryPort = 42179;
const defaultPort = 42180;

Future<void> main(List<String> args) async {
  final port =
      intArg(args, '--port') ??
      int.tryParse(env('ZC_AGENTBEACON_COMPANION_PORT') ?? '') ??
      defaultPort;
  final host =
      stringArg(args, '--host') ??
      env('ZC_AGENTBEACON_COMPANION_HOST') ??
      await defaultLanHost();
  final allowedServer =
      stringArg(args, '--allow-server') ?? env('ZC_AGENTBEACON_ALLOWED_SERVER');
  final token = stringArg(args, '--token') ?? env('ZC_AGENTBEACON_TOKEN');

  final server = CompanionServer(
    host: host,
    port: port,
    allowedServer: allowedServer,
    token: token,
  );
  await server.start();
  stdout.writeln(
    '$productName Companion listening on http://$host:$port/status',
  );
}

class CompanionServer {
  CompanionServer({
    required this.host,
    required this.port,
    this.allowedServer,
    this.token,
    CodexAdapter? adapter,
  }) : adapter = adapter ?? CodexAdapter();

  final String host;
  final int port;
  final String? allowedServer;
  final String? token;
  final CodexAdapter adapter;

  HttpServer? _httpServer;
  RawDatagramSocket? _beaconSocket;
  Timer? _beaconTimer;

  Future<void> start() async {
    final bind = host == '0.0.0.0'
        ? InternetAddress.anyIPv4
        : InternetAddress(host);
    _httpServer = await HttpServer.bind(bind, port);
    _httpServer!.listen(handleRequest);
    await startBeaconing();
  }

  Future<void> stop() async {
    _beaconTimer?.cancel();
    _beaconSocket?.close();
    await _httpServer?.close(force: true);
  }

  Future<void> handleRequest(HttpRequest request) async {
    setCors(request.response);
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (!isAllowed(request)) {
      await jsonResponse(request, {'error': 'forbidden'}, HttpStatus.forbidden);
      return;
    }
    if (request.uri.path == '/health') {
      await jsonResponse(request, {
        'ok': true,
        'product': productName,
        'version': companionVersion,
      });
      return;
    }
    if (request.uri.path == '/status') {
      final snapshot = await adapter.collect();
      await jsonResponse(request, snapshot.toJson());
      return;
    }
    await jsonResponse(request, {'error': 'not_found'}, HttpStatus.notFound);
  }

  bool isAllowed(HttpRequest request) {
    final expectedToken = token?.trim();
    if (expectedToken != null && expectedToken.isNotEmpty) {
      final header = request.headers.value('authorization') ?? '';
      final query = request.uri.queryParameters['token'] ?? '';
      if (header != 'Bearer $expectedToken' && query != expectedToken) {
        return false;
      }
    }
    final allowed = allowedServer
        ?.split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
    if (allowed == null || allowed.isEmpty) {
      return true;
    }
    final remote = request.connectionInfo?.remoteAddress.address;
    return remote != null && allowed.contains(remote);
  }

  Future<void> startBeaconing() async {
    _beaconSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sendBeacon();
    _beaconTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => sendBeacon(),
    );
  }

  void sendBeacon() {
    final socket = _beaconSocket;
    if (socket == null) {
      return;
    }
    final payload = jsonEncode({
      'kind': 'zc-agentbeacon.companion',
      'version': companionVersion,
      'hostname': Platform.localHostname,
      'os': Platform.operatingSystem,
      'port': port,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
    });
    socket.send(
      utf8.encode(payload),
      InternetAddress(discoveryAddress),
      discoveryPort,
    );
  }
}

Future<void> jsonResponse(
  HttpRequest request,
  Object body, [
  int status = HttpStatus.ok,
]) async {
  final encoded = jsonEncode(body);
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.headers.set('Cache-Control', 'no-store, max-age=0');
  request.response.write(encoded);
  await request.response.close();
}

void setCors(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  response.headers.set(
    'Access-Control-Allow-Headers',
    'Content-Type,Authorization',
  );
}

String? stringArg(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}

int? intArg(List<String> args, String name) {
  return int.tryParse(stringArg(args, name) ?? '');
}

Future<String> defaultLanHost() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (isPrivateIpv4(address.address)) {
          return address.address;
        }
      }
    }
  } on Object {
    return '0.0.0.0';
  }
  return '0.0.0.0';
}

bool isPrivateIpv4(String address) {
  final parts = address.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((part) => part == null)) {
    return false;
  }
  final first = parts[0]!;
  final second = parts[1]!;
  return first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 169 && second == 254);
}
