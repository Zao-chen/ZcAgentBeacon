import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../shared/agent_models.dart';
import '../shared/secret_masker.dart';
import 'codex_paths.dart';
import 'process_detector.dart';
import 'session_parser.dart';
import 'thread_store.dart';

class ChatProcessRecord {
  const ChatProcessRecord({
    required this.conversationId,
    required this.turnId,
    required this.cwd,
    required this.command,
    required this.updatedAtMs,
    this.chatTitle,
    this.itemId,
  });

  final String conversationId;
  final String? turnId;
  final String cwd;
  final String command;
  final int updatedAtMs;
  final String? chatTitle;
  final String? itemId;

  DateTime get updatedAt {
    return DateTime.fromMillisecondsSinceEpoch(updatedAtMs, isUtc: true);
  }
}

class CodexDataReader {
  CodexDataReader({
    CodexThreadStore? threadStore,
    CodexSessionParser? sessionParser,
    CodexProcessDetector? processDetector,
    SecretMasker? masker,
  })  : _threadStore = threadStore ?? CodexThreadStore(),
        _sessionParser = sessionParser ?? CodexSessionParser(masker: masker),
        _processDetector = processDetector ?? CodexProcessDetector(),
        _masker = masker ?? SecretMasker();

  static const int _maxThreadsToScan = 80;
  static const int _tailBytes = 768 * 1024;
  static const int _tailLines = 5000;
  static const Duration _processFreshness = Duration(seconds: 45);

  final CodexThreadStore _threadStore;
  final CodexSessionParser _sessionParser;
  final CodexProcessDetector _processDetector;
  final SecretMasker _masker;

  Future<AgentSnapshot> collect() async {
    final errors = <String>[];
    final codexHome = CodexPaths.codexHome();
    final nodeId = await _readNodeId(codexHome);
    final hostname = Platform.localHostname;
    final processCount = await _processDetector.countCodexProcesses();

    final threads = await _threadStore.readUnarchivedThreads(
      codexHome: codexHome,
      errors: errors,
    );
    final threadById = {for (final thread in threads) thread.id: thread};
    final processRecords = await _readChatProcesses(
      codexHome: codexHome,
      errors: errors,
    );
    final freshProcesses = _freshProcessRecords(processRecords);
    final active = <String, AgentConversation>{};
    final activityByConversation = <String, CodexSessionActivity>{};

    for (final thread in threads.take(_maxThreadsToScan)) {
      final sessionFile = await _resolveSessionFile(codexHome, thread);
      if (sessionFile == null) {
        continue;
      }

      final lines = await _readTailLines(sessionFile);
      final activity = _sessionParser.parseLines(lines);
      activityByConversation[thread.id] = activity;
      if (!activity.isActive) {
        continue;
      }

      active[thread.id] = _conversationFromActivity(
        thread: thread,
        activity: activity,
        status: activity.hasPendingTool
            ? ConversationRuntimeStatus.toolRunning
            : ConversationRuntimeStatus.working,
      );
    }

    for (final process in freshProcesses) {
      final activity = activityByConversation[process.conversationId];
      if (_completedAfterProcessUpdate(activity, process)) {
        continue;
      }

      final thread = threadById[process.conversationId];
      final current = active[process.conversationId];
      active[process.conversationId] = AgentConversation(
        conversationId: process.conversationId,
        title: current?.title ??
            process.chatTitle ??
            thread?.title ??
            process.conversationId,
        cwd: current?.cwd ?? process.cwd,
        status: ConversationRuntimeStatus.toolRunning,
        turnId: process.turnId ?? current?.turnId,
        lastEventAt: _latestDate(current?.lastEventAt, process.updatedAt),
        lastToolName: current?.lastToolName ?? 'tool',
        lastCommand: _masker.mask(process.command),
        lastToolOutput: current?.lastToolOutput,
        lastMessageSummary: current?.lastMessageSummary,
        detailLevel: 'full',
      );
    }

    final conversations = active.values.toList()
      ..sort((a, b) {
        final aTime = a.lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });

    return AgentSnapshot(
      nodeId: nodeId,
      hostname: hostname,
      os: Platform.operatingSystem,
      codexRunning: processCount > 0,
      conversations: conversations,
      errors: errors,
      collectedAt: DateTime.now().toUtc(),
    );
  }

  AgentConversation _conversationFromActivity({
    required CodexThreadRecord thread,
    required CodexSessionActivity activity,
    required ConversationRuntimeStatus status,
  }) {
    return AgentConversation(
      conversationId: thread.id,
      title: thread.title,
      cwd: thread.cwd,
      status: status,
      turnId: activity.turnId,
      lastEventAt: activity.lastEventAt,
      lastToolName: activity.lastToolName,
      lastCommand: activity.lastCommand,
      lastToolOutput: activity.lastToolOutput,
      lastMessageSummary: activity.lastMessageSummary,
      detailLevel: 'full',
    );
  }

  bool _completedAfterProcessUpdate(
    CodexSessionActivity? activity,
    ChatProcessRecord process,
  ) {
    final completedAt = activity?.lastTaskCompleteAt;
    if (completedAt == null) {
      return false;
    }
    return completedAt.isAfter(process.updatedAt) ||
        completedAt.isAtSameMomentAs(process.updatedAt);
  }

  Future<String> _readNodeId(Directory codexHome) async {
    final override = Platform.environment['AGENTBEACON_NODE_ID'];
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }

    final installationId = CodexPaths.installationIdFile(codexHome);
    if (await installationId.exists()) {
      final value = (await installationId.readAsString()).trim();
      if (value.isNotEmpty) {
        return value;
      }
    }

    return '${Platform.localHostname}-${Platform.operatingSystem}';
  }

  Future<List<ChatProcessRecord>> _readChatProcesses({
    required Directory codexHome,
    required List<String> errors,
  }) async {
    final file = CodexPaths.processManagerFile(codexHome);
    if (!await file.exists()) {
      return const [];
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        return const [];
      }

      return decoded
          .whereType<Map>()
          .map((item) => _chatProcessFromJson(item.cast<String, Object?>()))
          .whereType<ChatProcessRecord>()
          .toList();
    } on Object catch (error) {
      errors.add('Unable to read chat_processes.json: $error');
      return const [];
    }
  }

  ChatProcessRecord? _chatProcessFromJson(Map<String, Object?> json) {
    final conversationId = json['conversationId']?.toString();
    if (conversationId == null || conversationId.isEmpty) {
      return null;
    }
    final updatedAtMs = _int(json['updatedAtMs']) ?? _int(json['startedAtMs']);
    if (updatedAtMs == null) {
      return null;
    }

    return ChatProcessRecord(
      conversationId: conversationId,
      turnId: json['turnId']?.toString(),
      itemId: json['itemId']?.toString(),
      cwd: json['cwd']?.toString() ?? '',
      command: json['command']?.toString() ?? '',
      chatTitle: json['chatTitle']?.toString(),
      updatedAtMs: updatedAtMs,
    );
  }

  List<ChatProcessRecord> _freshProcessRecords(List<ChatProcessRecord> input) {
    final minimum = DateTime.now().toUtc().subtract(_processFreshness);
    return input.where((record) => record.updatedAt.isAfter(minimum)).toList();
  }

  Future<File?> _resolveSessionFile(
    Directory codexHome,
    CodexThreadRecord thread,
  ) async {
    if (thread.rolloutPath.isNotEmpty) {
      final direct = File(thread.rolloutPath);
      if (await direct.exists()) {
        return direct;
      }

      final relative = File(_join(codexHome.path, thread.rolloutPath));
      if (await relative.exists()) {
        return relative;
      }
    }

    final sessions = CodexPaths.sessionsDirectory(codexHome);
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

  Future<List<String>> _readTailLines(File file) async {
    final length = await file.length();
    final start = max(0, length - _tailBytes);
    final raf = await file.open();
    try {
      await raf.setPosition(start);
      final bytes = await raf.read(length - start);
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = const LineSplitter().convert(text);
      final cleanLines = start > 0 && lines.isNotEmpty ? lines.sublist(1) : lines;
      if (cleanLines.length <= _tailLines) {
        return cleanLines;
      }
      return cleanLines.sublist(cleanLines.length - _tailLines);
    } finally {
      await raf.close();
    }
  }

  int? _int(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  DateTime? _latestDate(DateTime? first, DateTime? second) {
    if (first == null) {
      return second;
    }
    if (second == null) {
      return first;
    }
    return first.isAfter(second) ? first : second;
  }

  String _join(String first, String second) {
    final separator = Platform.pathSeparator;
    return first.endsWith(separator) ? '$first$second' : '$first$separator$second';
  }
}
