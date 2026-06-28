import 'dart:io';

import 'package:zc_agentbeacon/src/server/dashboard_server.dart';

Future<void> main(List<String> args) async {
  final host = _stringArg(args, '--host') ??
      Platform.environment['AGENTBEACON_SERVER_HOST'] ??
      '0.0.0.0';
  final port = _intArg(args, '--port') ??
      int.tryParse(Platform.environment['AGENTBEACON_SERVER_PORT'] ?? '') ??
      42178;
  final webRoot = _stringArg(args, '--web-root') ??
      Platform.environment['AGENTBEACON_WEB_ROOT'] ??
      'build/web';

  final server = DashboardServer(host: host, port: port, webRoot: webRoot);
  await server.start();
  // ignore: avoid_print
  print('AgentBeacon dashboard listening on http://$host:$port');
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
