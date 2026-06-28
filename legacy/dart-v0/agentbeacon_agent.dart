import 'dart:io';

import 'package:zc_agentbeacon/src/agent/agent_http_server.dart';

Future<void> main(List<String> args) async {
  final port = _intArg(args, '--port') ??
      int.tryParse(_env('AGENTBEACON_AGENT_PORT')) ??
      42180;
  final host = _stringArg(args, '--host') ??
      _env('AGENTBEACON_AGENT_HOST') ??
      await _defaultLanHost();
  final allowedServer =
      _stringArg(args, '--allow-server') ?? _env('AGENTBEACON_ALLOWED_SERVER');

  final server = AgentHttpServer(
    host: host,
    port: port,
    allowedServer: allowedServer,
  );
  await server.start();
  // ignore: avoid_print
  print('AgentBeacon agent listening on http://$host:$port/status');
}

String? _env(String key) {
  final value = Platform.environment[key];
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}

String? _stringArg(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}

int? _intArg(List<String> args, String name) {
  return int.tryParse(_stringArg(args, name) ?? '');
}

Future<String> _defaultLanHost() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (_isPrivateIpv4(address.address)) {
          return address.address;
        }
      }
    }
  } on Object {
    return '0.0.0.0';
  }
  return '0.0.0.0';
}

bool _isPrivateIpv4(String address) {
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
