import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'models.dart';
import 'secret_masker.dart';

class CodexThreadRecord {
  const CodexThreadRecord({
    required this.id,
    required this.title,
    required this.cwd,
    required this.rolloutPath,
    required this.updatedAtMs,
  });

  final String id;
  final String title;
  final String cwd;
  final String rolloutPath;
  final int updatedAtMs;
}

class ChatProcessRecord {
  const ChatProcessRecord({
    required this.conversationId,
    required this.cwd,
    required this.command,
    required this.updatedAtMs,
    this.turnId,
    this.chatTitle,
  });

  final String conversationId;
  final String cwd;
  final String command;
  final int updatedAtMs;
  final String? turnId;
  final String? chatTitle;

  DateTime get updatedAt =>
      DateTime.fromMillisecondsSinceEpoch(updatedAtMs, isUtc: true);
}

class CodexAdapter {
  CodexAdapter({
    SecretMasker? masker,
    String? sqliteCommand,
    int? tailBytes,
    int? tailLines,
    int? maxThreads,
    int? rawEventLimit,
  })  : _masker = masker ?? SecretMasker(),
        _sqliteCommand = sqliteCommand ??
            env('ZC_AGENTBEACON_SQLITE3') ??
            'sqlite3',
        _tailBytes = tailBytes ??
            int.tryParse(env('ZC_AGENTBEACON_TAIL_BYTES') ?? '') ??
            384 * 1024,
        _tailLines = tailLines ??
            int.tryParse(env('ZC_AGENTBEACON_TAIL_LINES') ?? '') ??
            2500,
        _maxThreads = maxThreads ??
            int.tryParse(env('ZC_AGENTBEACON_MAX_THREADS') ?? '') ??
            10,
        _rawEventLimit = rawEventLimit ??
            int.tryParse(env('ZC_AGENTBEACON_RAW_EVENT_LIMIT') ?? '') ??
            360;

  static const _processFreshness = Duration(seconds: 45);
  static const _activeEventFreshness = Duration(minutes: 10);

  final SecretMasker _masker;
  final String _sqliteCommand;
  final int _tailBytes;
  final int _tailLines;
  final int _maxThreads;
  final int _rawEventLimit;

  Future<AgentSnapshot> collect() async {
    final errors = <String>[];
    final home = codexHome();
    final processCount = await countCodexProcesses();
    final threads = await readThreads(home, errors);
    final threadById = {for (final item in threads) item.id: item};
    final processes = await readChatProcesses(home, errors);
    final processIds = processes.map((item) => item.conversationId).toSet();
    final raw = <String, RawConversation>{};
    final cutoff = DateTime.now().toUtc().subtract(_activeEventFreshness);

    final candidates = <CodexThreadRecord>[];
    for (final thread in threads) {
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(
        thread.updatedAtMs,
        isUtc: true,
      );
      if (processIds.contains(thread.id) || updatedAt.isAfter(cutoff)) {
        candidates.add(thread);
      }
      if (candidates.length >= _maxThreads) {
        break;
      }
    }

    for (final thread in candidates) {
      final session = await resolveSessionFile(home, thread);
      if (session == null) {
        continue;
      }
      final lines = await readTailLines(session);
      raw[thread.id] = RawConversation(
        conversationId: thread.id,
        title: thread.title,
        cwd: thread.cwd,
        updatedAt: thread.updatedAtMs == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(thread.updatedAtMs, isUtc: true),
        events: parseRawSessionLines(lines),
        processes: const [],
      );
    }

    for (final process in processes) {
      final thread = threadById[process.conversationId];
      final existing = raw[process.conversationId];
      final conversation = existing ??
          RawConversation(
            conversationId: process.conversationId,
            title: process.chatTitle ?? thread?.title ?? process.conversationId,
            cwd: process.cwd.isNotEmpty ? process.cwd : thread?.cwd ?? '',
            updatedAt: process.updatedAt,
          );
      raw[process.conversationId] = RawConversation(
        conversationId: conversation.conversationId,
        title: conversation.title,
        cwd: conversation.cwd,
        updatedAt: conversation.updatedAt,
        events: conversation.events,
        processes: [
          ...conversation.processes,
          RawProcessSignal(
            turnId: process.turnId,
            command: _masker.mask(process.command, limit: 500),
            updatedAt: process.updatedAt,
            updatedAtMs: process.updatedAtMs,
          ),
        ],
      );
    }

    return AgentSnapshot(
      nodeId: await nodeId(home),
      hostname: Platform.localHostname,
      os: Platform.operatingSystem,
      codexRunning: processCount > 0,
      rawConversations: raw.values.toList(),
      errors: errors,
      collectedAt: DateTime.now().toUtc(),
    );
  }

  List<RawEventSignal> parseRawSessionLines(Iterable<String> lines) {
    final signals = <RawEventSignal>[];
    for (final line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          final signal = rawEventSignal(decoded.cast<String, Object?>());
          if (signal != null) {
            signals.add(signal);
          }
        }
      } on FormatException {
        continue;
      }
    }
    if (signals.length <= _rawEventLimit) {
      return signals;
    }
    return signals.sublist(signals.length - _rawEventLimit);
  }

  RawEventSignal? rawEventSignal(Map<String, Object?> decoded) {
    final eventAt = parseTime(
      decoded['timestamp'] ?? decoded['ts'] ?? decoded['created_at'],
    );
    final payload = asMap(decoded['payload']);
    final item = asMap(payload['item']);
    final data = item.isEmpty ? payload : item;
    final eventType = (data['type'] ?? payload['type'])?.toString();
    if (eventType == null || eventType.isEmpty) {
      return null;
    }
    final turnId = eventTurnId(data, payload);
    final callId = (data['call_id'] ?? data['id'])?.toString();
    final toolName = data['name']?.toString();
    final role = data['role']?.toString();
    final completedAt = terminalCompletedAt(data, eventAt);
    final messageSummary = firstText(data, [
      'last_agent_message',
      'reason',
      'message',
      'error',
    ]);
    final arguments = data.containsKey('arguments')
        ? _masker.mask(summarize(data['arguments']), limit: 500)
        : null;
    final output = data.containsKey('output')
        ? _masker.mask(summarize(data['output']), limit: 500)
        : null;
    final explanation = extractExplanation(data['arguments']);

    if (eventType == 'task_started') {
      return RawEventSignal(
        type: eventType,
        kind: 'turn_start',
        turnId: turnId,
        eventAt: eventAt,
      );
    }
    if (eventType == 'task_complete' || isAbortEvent(eventType)) {
      return RawEventSignal(
        type: eventType,
        kind: 'turn_end',
        turnId: turnId,
        eventAt: eventAt,
        completedAt: completedAt,
        terminalStatus: isAbortEvent(eventType) ? 'interrupted' : 'complete',
        messageSummary: _masker.mask(messageSummary, limit: 360),
      );
    }
    if (eventType == 'function_call') {
      return RawEventSignal(
        type: eventType,
        kind: 'tool_call',
        turnId: turnId,
        eventAt: eventAt,
        callId: callId,
        toolName: toolName ?? 'tool',
        argumentsSummary: arguments,
        explanation: _masker.mask(explanation, limit: 360),
      );
    }
    if (eventType == 'function_call_output') {
      return RawEventSignal(
        type: eventType,
        kind: 'tool_output',
        turnId: turnId,
        eventAt: eventAt,
        callId: callId,
        outputSummary: output,
      );
    }
    if (eventType == 'agent_message') {
      return RawEventSignal(
        type: eventType,
        kind: 'assistant_message',
        turnId: turnId,
        eventAt: eventAt,
        messageSummary: _masker.mask(summarize(data['message']), limit: 360),
      );
    }
    if (eventType == 'message') {
      return RawEventSignal(
        type: eventType,
        kind: 'message',
        turnId: turnId,
        eventAt: eventAt,
        role: role,
        messageSummary: isAssistantMessage(data)
            ? _masker.mask(contentText(data['content']), limit: 360)
            : null,
      );
    }
    if (eventType == 'reasoning') {
      final summary = contentText(data['summary']);
      final reasoningExplanation = contentText(data['explanation']);
      return RawEventSignal(
        type: eventType,
        kind: 'reasoning',
        turnId: turnId,
        eventAt: eventAt,
        messageSummary: _masker.mask(summary, limit: 360),
        explanation: _masker.mask(reasoningExplanation, limit: 360),
      );
    }
    return RawEventSignal(
      type: eventType,
      kind: 'event',
      turnId: turnId,
      eventAt: eventAt,
      messageSummary: _masker.mask(messageSummary, limit: 360),
    );
  }

  Future<List<CodexThreadRecord>> readThreads(
    Directory home,
    List<String> errors,
  ) async {
    final database = File(pathJoin(home.path, 'state_5.sqlite'));
    if (!await database.exists()) {
      errors.add('Codex state database not found: ${database.path}');
      return const [];
    }
    const query = '''
select
  id,
  replace(replace(coalesce(nullif(title, ''), nullif(preview, ''), id), char(9), ' '), char(10), ' '),
  replace(replace(cwd, char(9), ' '), char(10), ' '),
  replace(replace(rollout_path, char(9), ' '), char(10), ' '),
  coalesce(updated_at_ms, updated_at * 1000)
from threads
where archived = 0
order by coalesce(recency_at_ms, updated_at_ms, updated_at * 1000) desc;
''';
    try {
      final result = await Process.run(
        _sqliteCommand,
        ['-separator', '\t', database.path, query],
      );
      if (result.exitCode != 0) {
        errors.add('sqlite3 read failed: ${result.stderr}'.trim());
        return const [];
      }
      return result.stdout
          .toString()
          .split(RegExp(r'\r?\n'))
          .where((line) => line.trim().isNotEmpty)
          .map(parseThreadLine)
          .whereType<CodexThreadRecord>()
          .toList();
    } on Object catch (error) {
      errors.add('sqlite3 read failed: $error');
      return const [];
    }
  }

  CodexThreadRecord? parseThreadLine(String line) {
    final parts = line.split('\t');
    if (parts.length < 5) {
      return null;
    }
    return CodexThreadRecord(
      id: parts[0],
      title: truncate(parts[1].isEmpty ? 'Untitled' : parts[1], 180),
      cwd: parts[2],
      rolloutPath: parts[3],
      updatedAtMs: int.tryParse(parts[4]) ?? 0,
    );
  }

  Future<List<ChatProcessRecord>> readChatProcesses(
    Directory home,
    List<String> errors,
  ) async {
    final file = File(pathJoin(home.path, 'process_manager/chat_processes.json'));
    if (!await file.exists()) {
      return const [];
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        return const [];
      }
      final cutoff = DateTime.now().toUtc().subtract(_processFreshness);
      return decoded
          .whereType<Map>()
          .map((item) => chatProcessFromJson(item.cast<String, Object?>()))
          .whereType<ChatProcessRecord>()
          .where((item) => item.updatedAt.isAfter(cutoff))
          .toList();
    } on Object catch (error) {
      errors.add('Unable to read chat_processes.json: $error');
      return const [];
    }
  }

  ChatProcessRecord? chatProcessFromJson(Map<String, Object?> json) {
    final conversationId = json['conversationId']?.toString();
    final updatedAtMs = integer(json['updatedAtMs']) ?? integer(json['startedAtMs']);
    if (conversationId == null || conversationId.isEmpty || updatedAtMs == null) {
      return null;
    }
    return ChatProcessRecord(
      conversationId: conversationId,
      turnId: nullableString(json['turnId']),
      cwd: string(json['cwd']),
      command: string(json['command']),
      chatTitle: nullableString(json['chatTitle']),
      updatedAtMs: updatedAtMs,
    );
  }

  Future<File?> resolveSessionFile(Directory home, CodexThreadRecord thread) async {
    if (thread.rolloutPath.isNotEmpty) {
      final direct = File(thread.rolloutPath);
      if (await direct.exists()) {
        return direct;
      }
      final relative = File(pathJoin(home.path, thread.rolloutPath));
      if (await relative.exists()) {
        return relative;
      }
    }
    final sessions = Directory(pathJoin(home.path, 'sessions'));
    if (!await sessions.exists()) {
      return null;
    }
    await for (final entity in sessions.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          entity.path.endsWith('.jsonl') &&
          entity.path.contains(thread.id)) {
        return entity;
      }
    }
    return null;
  }

  Future<List<String>> readTailLines(File file) async {
    final length = await file.length();
    final start = max(0, length - _tailBytes);
    final raf = await file.open();
    try {
      await raf.setPosition(start);
      final bytes = await raf.read(length - start);
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = const LineSplitter().convert(text);
      final clean = start > 0 && lines.isNotEmpty ? lines.sublist(1) : lines;
      if (clean.length <= _tailLines) {
        return clean;
      }
      return clean.sublist(clean.length - _tailLines);
    } finally {
      await raf.close();
    }
  }
}

Directory codexHome() {
  final override = env('ZC_AGENTBEACON_CODEX_HOME');
  if (override != null) {
    return Directory(override);
  }
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return Directory(pathJoin(home, '.codex'));
}

Future<String> nodeId(Directory home) async {
  final override = env('ZC_AGENTBEACON_NODE_ID');
  if (override != null) {
    return override;
  }
  final installationId = File(pathJoin(home.path, 'installation_id'));
  if (await installationId.exists()) {
    final value = (await installationId.readAsString()).trim();
    if (value.isNotEmpty) {
      return value;
    }
  }
  return '${Platform.localHostname}-${Platform.operatingSystem}';
}

Future<int> countCodexProcesses() async {
  try {
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
      return RegExp(r'"codex\.exe"', caseSensitive: false)
          .allMatches(result.stdout.toString())
          .length;
    }
    final result = await Process.run('ps', ['-axo', 'comm=']);
    return result.stdout
        .toString()
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().toLowerCase() == 'codex')
        .length;
  } on Object {
    return 0;
  }
}

String? env(String name) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}

DateTime? parseTime(Object? value) => date(value);

Map<String, Object?> asMap(Object? value) {
  if (value is Map) {
    return value.cast<String, Object?>();
  }
  return const {};
}

String? eventTurnId(Map<String, Object?> data, Map<String, Object?> payload) {
  final metadata = asMap(
    data['internal_chat_message_metadata_passthrough'] ??
        payload['internal_chat_message_metadata_passthrough'],
  );
  return (data['turn_id'] ?? payload['turn_id'] ?? metadata['turn_id'])?.toString();
}

bool isAbortEvent(String? eventType) {
  final value = (eventType ?? '').toLowerCase();
  return value.contains('abort') ||
      value.contains('cancel') ||
      value.contains('interrupt');
}

DateTime? terminalCompletedAt(Map<String, Object?> data, DateTime? eventAt) {
  for (final key in [
    'completed_at',
    'aborted_at',
    'cancelled_at',
    'canceled_at',
    'interrupted_at',
    'ended_at',
  ]) {
    final parsed = parseTime(data[key]);
    if (parsed != null) {
      return parsed;
    }
  }
  return eventAt;
}

String firstText(Map<String, Object?> data, Iterable<String> keys) {
  for (final key in keys) {
    final value = data[key];
    if (value != null && value.toString().trim().isNotEmpty) {
      return value.toString();
    }
  }
  return '';
}

String contentText(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is String) {
    return value;
  }
  if (value is List) {
    return value.map(contentText).where((item) => item.isNotEmpty).join(' ');
  }
  if (value is Map) {
    return (value['text'] ?? value['message'] ?? '').toString();
  }
  return value.toString();
}

String extractExplanation(Object? arguments) {
  if (arguments == null) {
    return '';
  }
  Object? data = arguments;
  if (arguments is String) {
    try {
      data = jsonDecode(arguments);
    } on FormatException {
      return '';
    }
  }
  if (data is Map) {
    return contentText(data['explanation']);
  }
  return '';
}

bool isAssistantMessage(Map<String, Object?> data) {
  final role = data['role']?.toString();
  if (role == 'user' || role == 'developer' || role == 'system') {
    return false;
  }
  final content = data['content'];
  if (content is List) {
    return content.whereType<Map>().any((item) => item['type'] == 'output_text');
  }
  return content != null && contentText(content).isNotEmpty;
}

String summarize(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is String) {
    return value;
  }
  return jsonEncode(value);
}

String truncate(String value, int maxLength) {
  final trimmed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return '${trimmed.substring(0, maxLength)}...';
}

String pathJoin(String first, String second) {
  final normalized = second.replaceAll('/', Platform.pathSeparator);
  if (first.endsWith(Platform.pathSeparator)) {
    return '$first$normalized';
  }
  return '$first${Platform.pathSeparator}$normalized';
}
