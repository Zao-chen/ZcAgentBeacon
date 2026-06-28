import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'models.dart';
import 'secret_masker.dart';

class ClaudeAdapter {
  ClaudeAdapter({
    SecretMasker? masker,
    int? tailBytes,
    int? tailLines,
    int? maxSessions,
    int? rawEventLimit,
  })  : _masker = masker ?? SecretMasker(),
        _tailBytes = tailBytes ??
            int.tryParse(env('ZC_AGENTBEACON_CLAUDE_TAIL_BYTES') ?? '') ??
            384 * 1024,
        _tailLines = tailLines ??
            int.tryParse(env('ZC_AGENTBEACON_CLAUDE_TAIL_LINES') ?? '') ??
            2500,
        _maxSessions = maxSessions ??
            int.tryParse(env('ZC_AGENTBEACON_CLAUDE_MAX_SESSIONS') ?? '') ??
            10,
        _rawEventLimit = rawEventLimit ??
            int.tryParse(
                  env('ZC_AGENTBEACON_CLAUDE_RAW_EVENT_LIMIT') ?? '',
                ) ??
            360;

  static const _activeEventFreshness = Duration(minutes: 10);

  final SecretMasker _masker;
  final int _tailBytes;
  final int _tailLines;
  final int _maxSessions;
  final int _rawEventLimit;

  Future<AgentSnapshot> collect() async {
    final errors = <String>[];
    final home = claudeHome();
    final processCount = await countClaudeProcesses();
    final sessions = await findSessionFiles(home, errors);
    final raw = <RawConversation>[];

    for (final file in sessions.take(_maxSessions)) {
      final lines = await readTailLines(file);
      final conversation = await parseTranscript(file, lines);
      if (conversation != null) {
        raw.add(conversation);
      }
    }

    return AgentSnapshot(
      nodeId: await claudeNodeId(home),
      hostname: Platform.localHostname,
      os: Platform.operatingSystem,
      codexRunning: processCount > 0,
      rawConversations: raw,
      errors: errors,
      collectedAt: DateTime.now().toUtc(),
      agentVersion: '0.3.0-dart-raw-signals+claude',
    );
  }

  Future<List<File>> findSessionFiles(
    Directory home,
    List<String> errors,
  ) async {
    final projects = Directory(pathJoin(home.path, 'projects'));
    if (!await projects.exists()) {
      return const [];
    }
    final cutoff = DateTime.now().toUtc().subtract(_activeEventFreshness);
    final files = <File>[];
    try {
      await for (final entity in projects.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.jsonl')) {
          continue;
        }
        final normalized = entity.path.replaceAll('\\', '/');
        if (normalized.contains('/subagents/')) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.modified.toUtc().isAfter(cutoff)) {
          files.add(entity);
        }
      }
    } on Object catch (error) {
      errors.add('Unable to read Claude Code transcripts: $error');
    }
    files.sort((a, b) {
      final aTime = a.statSync().modified;
      final bTime = b.statSync().modified;
      return bTime.compareTo(aTime);
    });
    return files;
  }

  Future<RawConversation?> parseTranscript(
    File file,
    Iterable<String> lines,
  ) async {
    final parser = _ClaudeTranscriptParser(_masker);
    for (final line in lines) {
      parser.accept(line);
    }
    final sessionId = parser.sessionId ?? sessionIdFromPath(file.path);
    if (sessionId.isEmpty) {
      return null;
    }
    final stat = await file.stat();
    final updatedAt = stat.modified.toUtc();
    final cwd = parser.cwd ?? cwdFromProjectPath(file.parent.path);
    final title = parser.title ?? parser.lastPrompt ?? sessionId;
    final events = parser.events.length <= _rawEventLimit
        ? parser.events
        : parser.events.sublist(parser.events.length - _rawEventLimit);
    return RawConversation(
      conversationId: 'claude:$sessionId',
      title: truncate(title, 180),
      cwd: cwd,
      agentRuntime: AgentRuntime.claudeCode,
      updatedAt: updatedAt,
      events: events,
      detailLevel: 'claude_signals',
    );
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

class _ClaudeTranscriptParser {
  _ClaudeTranscriptParser(this.masker);

  final SecretMasker masker;
  final events = <RawEventSignal>[];
  String? sessionId;
  String? cwd;
  String? title;
  String? lastPrompt;
  String? currentTurnId;

  void accept(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        acceptJson(decoded.cast<String, Object?>());
      }
    } on FormatException {
      return;
    }
  }

  void acceptJson(Map<String, Object?> json) {
    sessionId ??= nullableString(json['sessionId']);
    cwd = nullableString(json['cwd']) ?? cwd;
    final type = string(json['type']);
    final eventAt = date(json['timestamp']);

    if (type == 'ai-title') {
      title = nullableString(json['aiTitle']) ?? title;
      return;
    }
    if (type == 'last-prompt') {
      lastPrompt = masker.mask(json['lastPrompt']?.toString(), limit: 180);
      return;
    }
    if (json['isSidechain'] == true) {
      return;
    }
    if (type == 'user') {
      acceptUser(json, eventAt);
      return;
    }
    if (type == 'assistant') {
      acceptAssistant(json, eventAt);
    }
  }

  void acceptUser(Map<String, Object?> json, DateTime? eventAt) {
    final message = asMap(json['message']);
    final content = message['content'];
    final toolResult = firstContentOfType(content, 'tool_result');
    if (toolResult != null) {
      events.add(
        RawEventSignal(
          type: 'tool_result',
          kind: 'tool_output',
          turnId: currentTurnId,
          eventAt: eventAt,
          callId: nullableString(toolResult['tool_use_id']),
          outputSummary: masker.mask(
            contentText(toolResult['content']),
            limit: 500,
          ),
        ),
      );
      return;
    }

    currentTurnId = nullableString(json['promptId']) ??
        nullableString(json['uuid']) ??
        currentTurnId;
    events.add(
      RawEventSignal(
        type: 'task_started',
        kind: 'turn_start',
        turnId: currentTurnId,
        eventAt: eventAt,
      ),
    );
    final summary = masker.mask(contentText(content), limit: 360);
    if (summary.isNotEmpty) {
      lastPrompt = summary;
      events.add(
        RawEventSignal(
          type: 'message',
          kind: 'message',
          turnId: currentTurnId,
          eventAt: eventAt,
          role: 'user',
          messageSummary: summary,
        ),
      );
    }
  }

  void acceptAssistant(Map<String, Object?> json, DateTime? eventAt) {
    final message = asMap(json['message']);
    final content = list(message['content']);
    var finalText = '';
    for (final item in content.whereType<Map>()) {
      final data = item.cast<String, Object?>();
      final contentType = string(data['type']);
      if (contentType == 'thinking') {
        final thinking = masker.mask(contentText(data['thinking']), limit: 360);
        events.add(
          RawEventSignal(
            type: 'reasoning',
            kind: 'reasoning',
            turnId: currentTurnId,
            eventAt: eventAt,
            explanation: thinking,
            messageSummary: thinking,
          ),
        );
      } else if (contentType == 'tool_use') {
        events.add(
          RawEventSignal(
            type: 'tool_use',
            kind: 'tool_call',
            turnId: currentTurnId,
            eventAt: eventAt,
            callId: nullableString(data['id']),
            toolName: nullableString(data['name']) ?? 'tool',
            argumentsSummary: masker.mask(summarize(data['input']), limit: 500),
          ),
        );
      } else if (contentType == 'text') {
        final text = masker.mask(contentText(data['text']), limit: 360);
        if (text.isNotEmpty) {
          finalText = text;
          events.add(
            RawEventSignal(
              type: 'agent_message',
              kind: 'assistant_message',
              turnId: currentTurnId,
              eventAt: eventAt,
              messageSummary: text,
            ),
          );
        }
      }
    }

    final stopReason = nullableString(message['stop_reason']);
    if (finalText.isNotEmpty && stopReason != null) {
      events.add(
        RawEventSignal(
          type: 'task_complete',
          kind: 'turn_end',
          turnId: currentTurnId,
          eventAt: eventAt,
          completedAt: eventAt,
          terminalStatus: stopReason == 'interrupted'
              ? 'interrupted'
              : 'complete',
          messageSummary: finalText,
        ),
      );
    }
  }
}

Directory claudeHome() {
  final override = env('ZC_AGENTBEACON_CLAUDE_HOME') ?? env('CLAUDE_CONFIG_DIR');
  if (override != null) {
    return Directory(override);
  }
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  return Directory(pathJoin(home, '.claude'));
}

Future<String> claudeNodeId(Directory home) async {
  final override = env('ZC_AGENTBEACON_NODE_ID');
  if (override != null) {
    return override;
  }
  final marker = File(pathJoin(home.path, 'installation_id'));
  if (await marker.exists()) {
    final value = (await marker.readAsString()).trim();
    if (value.isNotEmpty) {
      return value;
    }
  }
  return '${Platform.localHostname}-${Platform.operatingSystem}';
}

Future<int> countClaudeProcesses() async {
  try {
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
      return RegExp(
        r'"claude(\.exe)?"',
        caseSensitive: false,
      ).allMatches(result.stdout.toString()).length;
    }
    final result = await Process.run('ps', ['-axo', 'comm=']);
    return result.stdout
        .toString()
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().toLowerCase() == 'claude')
        .length;
  } on Object {
    return 0;
  }
}

String sessionIdFromPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final name = normalized.split('/').last;
  return name.endsWith('.jsonl')
      ? name.substring(0, name.length - '.jsonl'.length)
      : name;
}

String cwdFromProjectPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.split('/').last.replaceAll('-', Platform.pathSeparator);
}

Map<String, Object?> asMap(Object? value) {
  if (value is Map) {
    return value.cast<String, Object?>();
  }
  return const {};
}

Map<String, Object?>? firstContentOfType(Object? value, String type) {
  for (final item in list(value).whereType<Map>()) {
    final data = item.cast<String, Object?>();
    if (data['type'] == type) {
      return data;
    }
  }
  return null;
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
    return contentText(value['text'] ?? value['content'] ?? value['message']);
  }
  return value.toString();
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

String? env(String name) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}
