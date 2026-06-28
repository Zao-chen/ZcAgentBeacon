import 'models.dart';
import 'secret_masker.dart';

const processFreshness = Duration(seconds: 45);
const activeEventFreshness = Duration(minutes: 10);

final _machineId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class ZcStatusEngine {
  ZcStatusEngine({SecretMasker? masker}) : _masker = masker ?? SecretMasker();

  final SecretMasker _masker;

  List<ConversationView> conversationsFromRaw(
    Iterable<RawConversation> rawItems, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now().toUtc();
    final out = <ConversationView>[];
    for (final raw in rawItems) {
      if (raw.conversationId.isEmpty) {
        continue;
      }
      final item = conversationFromRaw(raw, now: current);
      if (item != null) {
        out.add(item);
      }
    }
    return foldAuxiliaryConversations(out);
  }

  ConversationView? conversationFromRaw(
    RawConversation raw, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now().toUtc();
    final activity = _activityFromSignals(raw);
    for (final process in raw.processes) {
      final procTime = process.updatedAt ??
          (process.updatedAtMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  process.updatedAtMs!,
                  isUtc: true,
                ));
      if (procTime == null || procTime.isBefore(current.subtract(processFreshness))) {
        continue;
      }
      final procTurn = process.turnId;
      if (procTurn != null && activity.completedTurnIds.contains(procTurn)) {
        continue;
      }
      if (activity.lastTaskCompleteAt != null &&
          !activity.lastTaskCompleteAt!.isBefore(procTime)) {
        continue;
      }
      activity.pendingCalls.add('process:${procTurn ?? procTime.toIso8601String()}');
      activity.turnId = process.turnId ?? activity.turnId;
      activity.lastToolName ??= 'tool';
      activity.lastCommand ??= _masker.mask(process.command);
      activity.lastResponseAt = latest(activity.lastResponseAt, procTime);
      activity.lastEventAt = latest(activity.lastEventAt, procTime);
      activity.setDisplay(_masker.mask(process.command), procTime, 'process');
    }

    var active = activity.hasOpenTurn || activity.pendingCalls.isNotEmpty;
    active = active ||
        (activity.lastResponseAt != null &&
            current.difference(activity.lastResponseAt!) <= activeEventFreshness &&
            (activity.lastTaskCompleteAt == null ||
                activity.lastResponseAt!.isAfter(activity.lastTaskCompleteAt!)));

    final status = active
        ? (activity.pendingCalls.isNotEmpty
            ? ConversationStatus.toolRunning
            : ConversationStatus.thinking)
        : (activity.lastTerminalStatus == 'interrupted' &&
                activity.lastTaskCompleteAt != null &&
                current.difference(activity.lastTaskCompleteAt!) <= activeEventFreshness)
            ? ConversationStatus.interrupted
            : ConversationStatus.idle;

    final eventAt = [
      activity.lastResponseAt,
      activity.lastTaskCompleteAt,
      activity.lastEventAt,
      raw.updatedAt,
    ].whereType<DateTime>().fold<DateTime?>(null, latest);
    if (eventAt == null) {
      return null;
    }
    if (status == ConversationStatus.idle &&
        eventAt.isBefore(current.subtract(activeEventFreshness))) {
      return null;
    }

    final auxiliary = machineGeneratedTitle(raw.title, raw.conversationId) &&
        raw.processes.isNotEmpty &&
        raw.events.isEmpty;
    return ConversationView(
      conversationId: raw.conversationId,
      title: preferredTitle(raw.title, raw.conversationId, raw.cwd),
      cwd: raw.cwd,
      status: status,
      turnId: activity.turnId,
      lastEventAt: eventAt,
      lastToolName: activity.lastToolName,
      lastCommand: activity.lastCommand,
      lastToolOutput: activity.lastToolOutput,
      lastExplanation: activity.lastExplanation,
      lastMessageSummary: activity.lastMessageSummary,
      displayDetail: activity.displayDetail,
      displaySource: activity.displaySource,
      detailLevel: 'signals',
      suppressCompletion: auxiliary,
      isAuxiliaryProcess: auxiliary,
    );
  }

  _Activity _activityFromSignals(RawConversation raw) {
    final activity = _Activity(_masker);
    final events = [...raw.events]..sort((a, b) {
        final aTime = eventTime(a) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = eventTime(b) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return aTime.compareTo(bTime);
      });

    for (final event in events) {
      final kind = event.kind;
      final eventAt = eventTime(event);
      activity.lastEventAt = latest(activity.lastEventAt, eventAt);
      final turnId = event.turnId;
      if (kind == 'turn_start' || event.type == 'task_started') {
        activity.hasOpenTurn = true;
        activity.turnId = turnId;
        if (turnId != null) {
          activity.completedTurnIds.remove(turnId);
        }
        activity.lastActivityKind = 'task_started';
      } else if (kind == 'turn_end' ||
          event.type == 'task_complete' ||
          isAbortEvent(event.type)) {
        final terminal = event.terminalStatus == 'interrupted' || isAbortEvent(event.type)
            ? 'interrupted'
            : 'idle';
        final completedAt = event.completedAt ?? eventAt;
        activity.finishTurn(turnId, completedAt ?? eventAt, terminal);
        if (event.messageSummary != null) {
          activity.lastMessageSummary = _masker.mask(event.messageSummary);
          activity.setDisplay(activity.lastMessageSummary, completedAt ?? eventAt, terminal);
        }
      } else if (kind == 'tool_call') {
        if (turnId != null && activity.completedTurnIds.contains(turnId)) {
          continue;
        }
        activity.noteResponse('function_call', eventAt, turnId);
        final callId = event.callId;
        if (callId != null) {
          activity.pendingCalls.add(callId);
        }
        final explanation = event.explanation;
        if (explanation != null && explanation.trim().isNotEmpty) {
          activity.lastExplanation = _masker.mask(explanation, limit: 360);
          activity.lastMessageSummary = activity.lastExplanation;
          activity.lastToolName =
              event.toolName == 'update_plan' ? 'explanation' : event.toolName;
          activity.lastCommand = '';
          activity.setDisplay(activity.lastExplanation, eventAt, 'explanation');
        } else {
          activity.lastToolName = event.toolName ?? 'tool';
          activity.lastCommand = _masker.mask(event.argumentsSummary);
          activity.setDisplay(activity.lastCommand, eventAt, 'command');
        }
      } else if (kind == 'tool_output') {
        if (turnId != null && activity.completedTurnIds.contains(turnId)) {
          continue;
        }
        activity.noteResponse('function_call_output', eventAt, turnId);
        final callId = event.callId;
        if (callId != null) {
          activity.pendingCalls.remove(callId);
        }
        activity.lastToolOutput = _masker.mask(event.outputSummary);
        activity.setDisplay(activity.lastToolOutput, eventAt, 'output');
      } else if (kind == 'assistant_message' || kind == 'message') {
        if (turnId != null && activity.completedTurnIds.contains(turnId)) {
          continue;
        }
        if (kind == 'message' && ['user', 'developer', 'system'].contains(event.role)) {
          continue;
        }
        if (event.messageSummary == null) {
          continue;
        }
        activity.noteResponse('message', eventAt, turnId);
        activity.lastMessageSummary = _masker.mask(event.messageSummary);
        activity.setDisplay(activity.lastMessageSummary, eventAt, 'message');
      } else if (kind == 'reasoning') {
        if (turnId != null && activity.completedTurnIds.contains(turnId)) {
          continue;
        }
        activity.noteResponse('reasoning', eventAt, turnId);
        if (event.explanation != null && event.explanation!.trim().isNotEmpty) {
          activity.lastExplanation = _masker.mask(event.explanation, limit: 360);
          activity.lastMessageSummary = activity.lastExplanation;
          activity.setDisplay(activity.lastExplanation, eventAt, 'explanation');
        } else if (event.messageSummary != null) {
          activity.lastMessageSummary = _masker.mask(event.messageSummary);
          activity.setDisplay(activity.lastMessageSummary, eventAt, 'reasoning');
        } else if (activity.displayDetail == null) {
          activity.setDisplay('正在思考...', eventAt, 'reasoning');
        }
      }
    }
    return activity;
  }
}

class _Activity {
  _Activity(this.masker);

  final SecretMasker masker;
  bool hasOpenTurn = false;
  final pendingCalls = <String>{};
  final completedTurnIds = <String>{};
  String? turnId;
  DateTime? lastEventAt;
  DateTime? lastResponseAt;
  DateTime? lastTaskCompleteAt;
  String? lastTerminalStatus;
  String? lastActivityKind;
  String? lastToolName;
  String? lastCommand;
  String? lastToolOutput;
  String? lastExplanation;
  String? lastMessageSummary;
  String? displayDetail;
  String? displaySource;
  DateTime? displayAt;

  void noteResponse(String kind, DateTime? eventAt, String? newTurnId) {
    if (newTurnId != null && !completedTurnIds.contains(newTurnId)) {
      turnId = newTurnId;
    }
    lastTerminalStatus = null;
    if (eventAt != null) {
      lastResponseAt = eventAt;
      lastActivityKind = kind;
    }
  }

  void finishTurn(String? finishedTurnId, DateTime? completedAt, String terminal) {
    hasOpenTurn = false;
    pendingCalls.clear();
    if (finishedTurnId != null) {
      completedTurnIds.add(finishedTurnId);
    }
    lastTaskCompleteAt = completedAt;
    lastTerminalStatus = terminal;
    lastActivityKind = terminal;
  }

  void setDisplay(String? detail, DateTime? eventAt, String source) {
    if (detail == null || detail.trim().isEmpty) {
      return;
    }
    if (displayAt != null && eventAt != null && eventAt.isBefore(displayAt!)) {
      return;
    }
    displayDetail = masker.mask(detail, limit: 360);
    displayAt = eventAt;
    displaySource = source;
  }
}

DateTime? eventTime(RawEventSignal event) {
  return event.eventAt ?? event.completedAt;
}

DateTime? latest(DateTime? first, DateTime? second) {
  if (first == null) {
    return second;
  }
  if (second == null) {
    return first;
  }
  return first.isAfter(second) ? first : second;
}

bool isAbortEvent(String? type) {
  final value = (type ?? '').toLowerCase();
  return value.contains('abort') ||
      value.contains('cancel') ||
      value.contains('interrupt');
}

String normalizeCwd(String cwd) {
  return cwd.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();
}

String cwdBasename(String cwd) {
  final normalized = cwd.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  if (normalized.isEmpty) {
    return '';
  }
  return normalized.split('/').last;
}

bool machineGeneratedTitle(String? title, String? conversationId) {
  final text = (title ?? '').trim();
  final id = (conversationId ?? '').trim();
  if (text.isEmpty) {
    return true;
  }
  return (id.isNotEmpty && text == id) || _machineId.hasMatch(text);
}

String preferredTitle(String title, String conversationId, String cwd) {
  if (machineGeneratedTitle(title, conversationId)) {
    final base = cwdBasename(cwd);
    return base.isEmpty ? '未命名会话' : base;
  }
  return title;
}

bool auxiliaryProcessShadow(ConversationView item) {
  if (item.isAuxiliaryProcess) {
    return true;
  }
  if (!machineGeneratedTitle(item.title, item.conversationId)) {
    return false;
  }
  if (item.displaySource == 'process') {
    return true;
  }
  return (item.lastCommand ?? '').isNotEmpty &&
      (item.lastMessageSummary ?? '').isEmpty &&
      (item.lastExplanation ?? '').isEmpty;
}

List<ConversationView> foldAuxiliaryConversations(List<ConversationView> items) {
  final visible = <ConversationView>[];
  final byCwd = <String, List<int>>{};
  final shadows = <ConversationView>[];

  for (final item in items) {
    if (auxiliaryProcessShadow(item)) {
      shadows.add(item);
      continue;
    }
    byCwd.putIfAbsent(normalizeCwd(item.cwd), () => <int>[]).add(visible.length);
    visible.add(item);
  }

  for (final shadow in shadows) {
    final peers = byCwd[normalizeCwd(shadow.cwd)] ?? const <int>[];
    if (peers.isEmpty) {
      if (shadow.status.isActive) {
        visible.add(shadow.copyWith());
      }
      continue;
    }
    if (!shadow.status.isActive) {
      continue;
    }
    final targetIndex = peers.reduce((a, b) {
      final aTime = visible[a].lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = visible[b].lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return aTime.isAfter(bTime) ? a : b;
    });
    visible[targetIndex] = mergeAuxiliaryShadow(visible[targetIndex], shadow);
  }

  visible.sort((a, b) {
    final aTime = a.lastEventAt ?? a.seenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bTime = b.lastEventAt ?? b.seenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bTime.compareTo(aTime);
  });
  return visible;
}

ConversationView mergeAuxiliaryShadow(
  ConversationView target,
  ConversationView shadow,
) {
  if (!shadow.status.isActive) {
    return target;
  }
  final shadowAt = shadow.lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  final targetAt = target.lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  final shadowIsLatest = !shadowAt.isBefore(targetAt);
  final folded = [...target.foldedAuxiliaryIds];
  if (!folded.contains(shadow.conversationId)) {
    folded.add(shadow.conversationId);
  }
  return target.copyWith(
    status: shadow.status == ConversationStatus.toolRunning || !target.status.isActive
        ? shadow.status
        : target.status,
    turnId: shadow.turnId ?? target.turnId,
    lastEventAt: shadowIsLatest ? shadow.lastEventAt : target.lastEventAt,
    lastToolName:
        shadowIsLatest ? shadow.lastToolName : target.lastToolName,
    lastCommand: shadowIsLatest ? shadow.lastCommand : target.lastCommand,
    displayDetail:
        shadowIsLatest ? shadow.displayDetail : target.displayDetail,
    displaySource:
        shadowIsLatest ? shadow.displaySource : target.displaySource,
    foldedAuxiliaryIds: folded,
  );
}
