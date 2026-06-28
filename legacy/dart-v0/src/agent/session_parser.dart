import 'dart:convert';

import '../shared/secret_masker.dart';

class CodexSessionActivity {
  const CodexSessionActivity({
    required this.hasOpenTurn,
    required this.hasPendingTool,
    required this.pendingCallIds,
    this.turnId,
    this.lastEventAt,
    this.lastTaskCompleteAt,
    this.lastToolName,
    this.lastCommand,
    this.lastToolOutput,
    this.lastMessageSummary,
  });

  final bool hasOpenTurn;
  final bool hasPendingTool;
  final Set<String> pendingCallIds;
  final String? turnId;
  final DateTime? lastEventAt;
  final DateTime? lastTaskCompleteAt;
  final String? lastToolName;
  final String? lastCommand;
  final String? lastToolOutput;
  final String? lastMessageSummary;

  bool get isActive => hasOpenTurn || hasPendingTool;
}

class CodexSessionParser {
  CodexSessionParser({SecretMasker? masker})
      : _masker = masker ?? SecretMasker();

  final SecretMasker _masker;

  CodexSessionActivity parseLines(Iterable<String> lines) {
    String? openTurnId;
    DateTime? lastEventAt;
    DateTime? lastTaskCompleteAt;
    String? lastToolName;
    String? lastCommand;
    String? lastToolOutput;
    String? lastMessageSummary;
    final pendingCalls = <String>{};

    for (final line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }

      final decoded = _decodeMap(line);
      if (decoded == null) {
        continue;
      }

      final eventAt = _readEventTime(decoded);
      if (eventAt != null &&
          (lastEventAt == null || eventAt.isAfter(lastEventAt))) {
        lastEventAt = eventAt;
      }

      final payload = _asMap(decoded['payload']);
      final item = _asMap(payload['item']);
      final data = item.isEmpty ? payload : item;
      final type = (data['type'] ?? payload['type'])?.toString();

      switch (type) {
        case 'task_started':
          openTurnId = data['turn_id']?.toString();
          break;
        case 'task_complete':
          final completeAt = _date(data['completed_at']) ?? eventAt;
          lastTaskCompleteAt = completeAt ?? lastTaskCompleteAt;
          openTurnId = null;
          pendingCalls.clear();
          final message = data['last_agent_message']?.toString();
          if (message != null && message.trim().isNotEmpty) {
            lastMessageSummary = _masker.mask(message);
          }
          break;
        case 'function_call':
          final callId = _callId(data);
          if (callId != null) {
            pendingCalls.add(callId);
          }
          lastToolName = data['name']?.toString();
          lastCommand = _masker.mask(_summarize(data['arguments']));
          break;
        case 'function_call_output':
          final callId = _callId(data);
          if (callId != null) {
            pendingCalls.remove(callId);
          }
          lastToolOutput = _masker.mask(_summarize(data['output']));
          break;
        case 'agent_message':
          lastMessageSummary = _masker.mask(_summarize(data['message']));
          break;
        case 'message':
          lastMessageSummary = _masker.mask(_summarize(data['content']));
          break;
        case 'reasoning':
          final summary = _summarize(data['summary']);
          if (summary.isNotEmpty) {
            lastMessageSummary = _masker.mask(summary);
          }
          break;
      }
    }

    return CodexSessionActivity(
      hasOpenTurn: openTurnId != null,
      hasPendingTool: pendingCalls.isNotEmpty,
      pendingCallIds: pendingCalls,
      turnId: openTurnId,
      lastEventAt: lastEventAt,
      lastTaskCompleteAt: lastTaskCompleteAt,
      lastToolName: lastToolName,
      lastCommand: lastCommand,
      lastToolOutput: lastToolOutput,
      lastMessageSummary: lastMessageSummary,
    );
  }

  Map<String, Object?>? _decodeMap(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        return decoded.cast<String, Object?>();
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  DateTime? _readEventTime(Map<String, Object?> decoded) {
    return _date(decoded['timestamp']) ??
        _date(decoded['ts']) ??
        _date(decoded['created_at']);
  }

  Map<String, Object?> _asMap(Object? value) {
    if (value is Map) {
      return value.cast<String, Object?>();
    }
    return const <String, Object?>{};
  }

  String? _callId(Map<String, Object?> data) {
    return (data['call_id'] ?? data['id'])?.toString();
  }

  DateTime? _date(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    }
    return DateTime.tryParse(value.toString())?.toUtc();
  }

  String _summarize(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is String) {
      return value;
    }
    return jsonEncode(value);
  }
}
