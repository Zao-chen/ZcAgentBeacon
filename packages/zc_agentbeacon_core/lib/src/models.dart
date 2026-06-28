import 'dart:convert';

enum ConversationStatus {
  thinking,
  working,
  toolRunning,
  waitingForUser,
  idle,
  interrupted,
  stale,
  errorOffline,
}

extension ConversationStatusWire on ConversationStatus {
  String get wireName => switch (this) {
    ConversationStatus.thinking => 'thinking',
    ConversationStatus.working => 'working',
    ConversationStatus.toolRunning => 'tool_running',
    ConversationStatus.waitingForUser => 'waiting_for_user',
    ConversationStatus.idle => 'idle',
    ConversationStatus.interrupted => 'interrupted',
    ConversationStatus.stale => 'stale',
    ConversationStatus.errorOffline => 'error_offline',
  };

  bool get isActive =>
      this == ConversationStatus.thinking ||
      this == ConversationStatus.working ||
      this == ConversationStatus.toolRunning ||
      this == ConversationStatus.waitingForUser;
}

ConversationStatus conversationStatusFromWire(Object? value) {
  return switch (value?.toString()) {
    'thinking' => ConversationStatus.thinking,
    'working' => ConversationStatus.working,
    'tool_running' => ConversationStatus.toolRunning,
    'waiting_for_user' => ConversationStatus.waitingForUser,
    'interrupted' => ConversationStatus.interrupted,
    'stale' => ConversationStatus.stale,
    'error_offline' => ConversationStatus.errorOffline,
    _ => ConversationStatus.idle,
  };
}

class RawEventSignal {
  const RawEventSignal({
    required this.type,
    required this.kind,
    this.turnId,
    this.eventAt,
    this.completedAt,
    this.callId,
    this.toolName,
    this.role,
    this.terminalStatus,
    this.messageSummary,
    this.argumentsSummary,
    this.outputSummary,
    this.explanation,
  });

  final String type;
  final String kind;
  final String? turnId;
  final DateTime? eventAt;
  final DateTime? completedAt;
  final String? callId;
  final String? toolName;
  final String? role;
  final String? terminalStatus;
  final String? messageSummary;
  final String? argumentsSummary;
  final String? outputSummary;
  final String? explanation;

  Map<String, Object?> toJson() => {
    'type': type,
    'kind': kind,
    'turnId': turnId,
    'eventAt': eventAt?.toUtc().toIso8601String(),
    'completedAt': completedAt?.toUtc().toIso8601String(),
    'callId': callId,
    'toolName': toolName,
    'role': role,
    'terminalStatus': terminalStatus,
    'messageSummary': messageSummary,
    'argumentsSummary': argumentsSummary,
    'outputSummary': outputSummary,
    'explanation': explanation,
  }..removeWhere((_, value) => value == null || value == '');

  factory RawEventSignal.fromJson(Map<String, Object?> json) {
    return RawEventSignal(
      type: string(json['type']),
      kind: string(json['kind'], fallback: 'event'),
      turnId: nullableString(json['turnId']),
      eventAt: date(json['eventAt']),
      completedAt: date(json['completedAt']),
      callId: nullableString(json['callId']),
      toolName: nullableString(json['toolName']),
      role: nullableString(json['role']),
      terminalStatus: nullableString(json['terminalStatus']),
      messageSummary: nullableString(json['messageSummary']),
      argumentsSummary: nullableString(json['argumentsSummary']),
      outputSummary: nullableString(json['outputSummary']),
      explanation: nullableString(json['explanation']),
    );
  }
}

class RawProcessSignal {
  const RawProcessSignal({
    this.turnId,
    this.command,
    this.updatedAt,
    this.updatedAtMs,
  });

  final String? turnId;
  final String? command;
  final DateTime? updatedAt;
  final int? updatedAtMs;

  Map<String, Object?> toJson() => {
    'turnId': turnId,
    'command': command,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'updatedAtMs': updatedAtMs,
  }..removeWhere((_, value) => value == null || value == '');

  factory RawProcessSignal.fromJson(Map<String, Object?> json) {
    return RawProcessSignal(
      turnId: nullableString(json['turnId']),
      command: nullableString(json['command']),
      updatedAt: date(json['updatedAt']),
      updatedAtMs: integer(json['updatedAtMs']),
    );
  }
}

class RawConversation {
  const RawConversation({
    required this.conversationId,
    required this.title,
    required this.cwd,
    this.updatedAt,
    this.events = const [],
    this.processes = const [],
    this.detailLevel = 'signals',
  });

  final String conversationId;
  final String title;
  final String cwd;
  final DateTime? updatedAt;
  final List<RawEventSignal> events;
  final List<RawProcessSignal> processes;
  final String detailLevel;

  Map<String, Object?> toJson() => {
    'conversationId': conversationId,
    'title': title,
    'cwd': cwd,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'events': events.map((item) => item.toJson()).toList(),
    'processes': processes.map((item) => item.toJson()).toList(),
    'detailLevel': detailLevel,
  };

  factory RawConversation.fromJson(Map<String, Object?> json) {
    return RawConversation(
      conversationId: string(json['conversationId']),
      title: string(json['title']),
      cwd: string(json['cwd']),
      updatedAt: date(json['updatedAt']),
      events: list(json['events'])
          .whereType<Map>()
          .map((item) => RawEventSignal.fromJson(item.cast<String, Object?>()))
          .toList(),
      processes: list(json['processes'])
          .whereType<Map>()
          .map(
            (item) => RawProcessSignal.fromJson(item.cast<String, Object?>()),
          )
          .toList(),
      detailLevel: string(json['detailLevel'], fallback: 'signals'),
    );
  }
}

class AgentSnapshot {
  const AgentSnapshot({
    required this.nodeId,
    required this.hostname,
    required this.os,
    required this.codexRunning,
    required this.rawConversations,
    required this.errors,
    required this.collectedAt,
    this.agentVersion = '0.3.0-dart-raw-signals',
  });

  final String nodeId;
  final String hostname;
  final String os;
  final bool codexRunning;
  final List<RawConversation> rawConversations;
  final List<String> errors;
  final DateTime collectedAt;
  final String agentVersion;

  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    'hostname': hostname,
    'os': os,
    'agentVersion': agentVersion,
    'codexRunning': codexRunning,
    'rawConversations': rawConversations.map((item) => item.toJson()).toList(),
    'errors': errors,
    'collectedAt': collectedAt.toUtc().toIso8601String(),
  };

  factory AgentSnapshot.fromJson(Map<String, Object?> json) {
    return AgentSnapshot(
      nodeId: string(json['nodeId']),
      hostname: string(json['hostname']),
      os: string(json['os']),
      agentVersion: string(json['agentVersion'], fallback: 'unknown'),
      codexRunning: json['codexRunning'] == true,
      rawConversations: list(json['rawConversations'])
          .whereType<Map>()
          .map((item) => RawConversation.fromJson(item.cast<String, Object?>()))
          .toList(),
      errors: list(json['errors']).map((item) => item.toString()).toList(),
      collectedAt: date(json['collectedAt']) ?? DateTime.now().toUtc(),
    );
  }
}

class ConversationView {
  const ConversationView({
    required this.conversationId,
    required this.title,
    required this.cwd,
    required this.status,
    this.turnId,
    this.lastEventAt,
    this.completedAt,
    this.lastToolName,
    this.lastCommand,
    this.lastToolOutput,
    this.lastExplanation,
    this.lastMessageSummary,
    this.displayDetail,
    this.displaySource,
    this.detailLevel = 'signals',
    this.deviceId,
    this.deviceName,
    this.deviceHost,
    this.seenAt,
    this.suppressCompletion = false,
    this.isAuxiliaryProcess = false,
    this.foldedAuxiliaryIds = const [],
  });

  final String conversationId;
  final String title;
  final String cwd;
  final ConversationStatus status;
  final String? turnId;
  final DateTime? lastEventAt;
  final DateTime? completedAt;
  final String? lastToolName;
  final String? lastCommand;
  final String? lastToolOutput;
  final String? lastExplanation;
  final String? lastMessageSummary;
  final String? displayDetail;
  final String? displaySource;
  final String detailLevel;
  final String? deviceId;
  final String? deviceName;
  final String? deviceHost;
  final DateTime? seenAt;
  final bool suppressCompletion;
  final bool isAuxiliaryProcess;
  final List<String> foldedAuxiliaryIds;

  ConversationView copyWith({
    ConversationStatus? status,
    String? turnId,
    DateTime? lastEventAt,
    DateTime? completedAt,
    String? lastToolName,
    String? lastCommand,
    String? lastToolOutput,
    String? lastExplanation,
    String? lastMessageSummary,
    String? displayDetail,
    String? displaySource,
    String? deviceId,
    String? deviceName,
    String? deviceHost,
    DateTime? seenAt,
    List<String>? foldedAuxiliaryIds,
  }) {
    return ConversationView(
      conversationId: conversationId,
      title: title,
      cwd: cwd,
      status: status ?? this.status,
      turnId: turnId ?? this.turnId,
      lastEventAt: lastEventAt ?? this.lastEventAt,
      completedAt: completedAt ?? this.completedAt,
      lastToolName: lastToolName ?? this.lastToolName,
      lastCommand: lastCommand ?? this.lastCommand,
      lastToolOutput: lastToolOutput ?? this.lastToolOutput,
      lastExplanation: lastExplanation ?? this.lastExplanation,
      lastMessageSummary: lastMessageSummary ?? this.lastMessageSummary,
      displayDetail: displayDetail ?? this.displayDetail,
      displaySource: displaySource ?? this.displaySource,
      detailLevel: detailLevel,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      deviceHost: deviceHost ?? this.deviceHost,
      seenAt: seenAt ?? this.seenAt,
      suppressCompletion: suppressCompletion,
      isAuxiliaryProcess: isAuxiliaryProcess,
      foldedAuxiliaryIds: foldedAuxiliaryIds ?? this.foldedAuxiliaryIds,
    );
  }

  Map<String, Object?> toJson() => {
    'conversationId': conversationId,
    'title': title,
    'cwd': cwd,
    'status': status.wireName,
    'turnId': turnId,
    'lastEventAt': lastEventAt?.toUtc().toIso8601String(),
    'completedAt': completedAt?.toUtc().toIso8601String(),
    'lastToolName': lastToolName,
    'lastCommand': lastCommand,
    'lastToolOutput': lastToolOutput,
    'lastExplanation': lastExplanation,
    'lastMessageSummary': lastMessageSummary,
    'displayDetail': displayDetail,
    'displaySource': displaySource,
    'detailLevel': detailLevel,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'deviceHost': deviceHost,
    'seenAt': seenAt?.toUtc().toIso8601String(),
    'suppressCompletion': suppressCompletion,
    'isAuxiliaryProcess': isAuxiliaryProcess,
    'foldedAuxiliaryIds': foldedAuxiliaryIds,
  }..removeWhere((_, value) => value == null);

  factory ConversationView.fromJson(Map<String, Object?> json) {
    return ConversationView(
      conversationId: string(json['conversationId']),
      title: string(json['title'], fallback: '未命名会话'),
      cwd: string(json['cwd']),
      status: conversationStatusFromWire(json['status']),
      turnId: nullableString(json['turnId']),
      lastEventAt: date(json['lastEventAt']),
      completedAt: date(json['completedAt']),
      lastToolName: nullableString(json['lastToolName']),
      lastCommand: nullableString(json['lastCommand']),
      lastToolOutput: nullableString(json['lastToolOutput']),
      lastExplanation: nullableString(json['lastExplanation']),
      lastMessageSummary: nullableString(json['lastMessageSummary']),
      displayDetail: nullableString(json['displayDetail']),
      displaySource: nullableString(json['displaySource']),
      detailLevel: string(json['detailLevel'], fallback: 'signals'),
      deviceId: nullableString(json['deviceId']),
      deviceName: nullableString(json['deviceName']),
      deviceHost: nullableString(json['deviceHost']),
      seenAt: date(json['seenAt']),
      suppressCompletion: json['suppressCompletion'] == true,
      isAuxiliaryProcess: json['isAuxiliaryProcess'] == true,
      foldedAuxiliaryIds: list(
        json['foldedAuxiliaryIds'],
      ).map((item) => item.toString()).toList(),
    );
  }
}

class DeviceView {
  const DeviceView({
    required this.nodeId,
    required this.hostname,
    required this.host,
    required this.port,
    required this.os,
    required this.status,
    required this.codexRunning,
    required this.conversationCount,
    this.lastSeenAt,
    this.lastBeaconAt,
    this.lastError,
    this.manual = false,
  });

  final String nodeId;
  final String hostname;
  final String host;
  final int port;
  final String os;
  final ConversationStatus status;
  final bool codexRunning;
  final int conversationCount;
  final DateTime? lastSeenAt;
  final DateTime? lastBeaconAt;
  final String? lastError;
  final bool manual;

  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    'hostname': hostname,
    'host': host,
    'port': port,
    'os': os,
    'status': status.wireName,
    'codexRunning': codexRunning,
    'conversationCount': conversationCount,
    'lastSeenAt': lastSeenAt?.toUtc().toIso8601String(),
    'lastBeaconAt': lastBeaconAt?.toUtc().toIso8601String(),
    'lastError': lastError,
    'manual': manual,
  }..removeWhere((_, value) => value == null);

  factory DeviceView.fromJson(Map<String, Object?> json) {
    return DeviceView(
      nodeId: string(json['nodeId']),
      hostname: string(json['hostname']),
      host: string(json['host']),
      port: integer(json['port']) ?? 0,
      os: string(json['os']),
      status: conversationStatusFromWire(json['status']),
      codexRunning: json['codexRunning'] == true,
      conversationCount: integer(json['conversationCount']) ?? 0,
      lastSeenAt: date(json['lastSeenAt']),
      lastBeaconAt: date(json['lastBeaconAt']),
      lastError: nullableString(json['lastError']),
      manual: json['manual'] == true,
    );
  }
}

class DashboardSnapshot {
  const DashboardSnapshot({
    required this.generatedAt,
    required this.devices,
    required this.conversations,
    this.screen,
  });

  final DateTime generatedAt;
  final List<DeviceView> devices;
  final List<ConversationView> conversations;
  final Map<String, Object?>? screen;

  int get activeConversationCount =>
      conversations.where((item) => item.status.isActive).length;

  Map<String, Object?> toJson() => {
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'devices': devices.map((item) => item.toJson()).toList(),
    'conversations': conversations.map((item) => item.toJson()).toList(),
    'screen': screen,
  }..removeWhere((_, value) => value == null);

  String encode() => jsonEncode(toJson());

  factory DashboardSnapshot.fromJson(Map<String, Object?> json) {
    return DashboardSnapshot(
      generatedAt: date(json['generatedAt']) ?? DateTime.now().toUtc(),
      devices: list(json['devices'])
          .whereType<Map>()
          .map((item) => DeviceView.fromJson(item.cast<String, Object?>()))
          .toList(),
      conversations: list(json['conversations'])
          .whereType<Map>()
          .map(
            (item) => ConversationView.fromJson(item.cast<String, Object?>()),
          )
          .toList(),
      screen: json['screen'] is Map
          ? (json['screen'] as Map).cast<String, Object?>()
          : null,
    );
  }

  factory DashboardSnapshot.empty() {
    return DashboardSnapshot(
      generatedAt: DateTime.now().toUtc(),
      devices: const [],
      conversations: const [],
    );
  }
}

String string(Object? value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  final text = value.toString();
  return text.isEmpty ? fallback : text;
}

String? nullableString(Object? value) {
  if (value == null) {
    return null;
  }
  final text = value.toString();
  return text.isEmpty ? null : text;
}

List<Object?> list(Object? value) {
  if (value is List) {
    return value.cast<Object?>();
  }
  return const [];
}

int? integer(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

DateTime? date(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is DateTime) {
    return value.toUtc();
  }
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  return DateTime.tryParse(value.toString())?.toUtc();
}
