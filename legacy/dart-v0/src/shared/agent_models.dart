import 'dart:convert';

enum ConversationRuntimeStatus {
  working,
  toolRunning,
  waitingForUser,
  idle,
  stale,
  errorOffline,
}

extension ConversationRuntimeStatusWire on ConversationRuntimeStatus {
  String get wireName {
    return switch (this) {
      ConversationRuntimeStatus.working => 'working',
      ConversationRuntimeStatus.toolRunning => 'tool_running',
      ConversationRuntimeStatus.waitingForUser => 'waiting_for_user',
      ConversationRuntimeStatus.idle => 'idle',
      ConversationRuntimeStatus.stale => 'stale',
      ConversationRuntimeStatus.errorOffline => 'error_offline',
    };
  }

  bool get isActive {
    return this == ConversationRuntimeStatus.working ||
        this == ConversationRuntimeStatus.toolRunning;
  }
}

ConversationRuntimeStatus conversationStatusFromWire(String? value) {
  return switch (value) {
    'working' => ConversationRuntimeStatus.working,
    'tool_running' => ConversationRuntimeStatus.toolRunning,
    'waiting_for_user' => ConversationRuntimeStatus.waitingForUser,
    'idle' => ConversationRuntimeStatus.idle,
    'stale' => ConversationRuntimeStatus.stale,
    'error_offline' => ConversationRuntimeStatus.errorOffline,
    _ => ConversationRuntimeStatus.idle,
  };
}

class AgentConversation {
  const AgentConversation({
    required this.conversationId,
    required this.title,
    required this.cwd,
    required this.status,
    this.turnId,
    this.lastEventAt,
    this.lastToolName,
    this.lastCommand,
    this.lastToolOutput,
    this.lastMessageSummary,
    this.detailLevel = 'full',
    this.deviceId,
    this.deviceName,
    this.deviceHost,
  });

  final String conversationId;
  final String title;
  final String cwd;
  final ConversationRuntimeStatus status;
  final String? turnId;
  final DateTime? lastEventAt;
  final String? lastToolName;
  final String? lastCommand;
  final String? lastToolOutput;
  final String? lastMessageSummary;
  final String detailLevel;
  final String? deviceId;
  final String? deviceName;
  final String? deviceHost;

  AgentConversation copyWithDevice({
    required String deviceId,
    required String deviceName,
    required String deviceHost,
  }) {
    return AgentConversation(
      conversationId: conversationId,
      title: title,
      cwd: cwd,
      status: status,
      turnId: turnId,
      lastEventAt: lastEventAt,
      lastToolName: lastToolName,
      lastCommand: lastCommand,
      lastToolOutput: lastToolOutput,
      lastMessageSummary: lastMessageSummary,
      detailLevel: detailLevel,
      deviceId: deviceId,
      deviceName: deviceName,
      deviceHost: deviceHost,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'conversationId': conversationId,
      'title': title,
      'cwd': cwd,
      'status': status.wireName,
      'turnId': turnId,
      'lastEventAt': lastEventAt?.toUtc().toIso8601String(),
      'lastToolName': lastToolName,
      'lastCommand': lastCommand,
      'lastToolOutput': lastToolOutput,
      'lastMessageSummary': lastMessageSummary,
      'detailLevel': detailLevel,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'deviceHost': deviceHost,
    };
  }

  factory AgentConversation.fromJson(Map<String, Object?> json) {
    return AgentConversation(
      conversationId: _string(json, 'conversationId'),
      title: _string(json, 'title', fallback: 'Untitled'),
      cwd: _string(json, 'cwd'),
      status: conversationStatusFromWire(_nullableString(json, 'status')),
      turnId: _nullableString(json, 'turnId'),
      lastEventAt: _date(json['lastEventAt']),
      lastToolName: _nullableString(json, 'lastToolName'),
      lastCommand: _nullableString(json, 'lastCommand'),
      lastToolOutput: _nullableString(json, 'lastToolOutput'),
      lastMessageSummary: _nullableString(json, 'lastMessageSummary'),
      detailLevel: _string(json, 'detailLevel', fallback: 'full'),
      deviceId: _nullableString(json, 'deviceId'),
      deviceName: _nullableString(json, 'deviceName'),
      deviceHost: _nullableString(json, 'deviceHost'),
    );
  }
}

class AgentSnapshot {
  const AgentSnapshot({
    required this.nodeId,
    required this.hostname,
    required this.os,
    required this.codexRunning,
    required this.conversations,
    required this.errors,
    required this.collectedAt,
    this.agentVersion = '0.1.0',
  });

  final String nodeId;
  final String hostname;
  final String os;
  final bool codexRunning;
  final List<AgentConversation> conversations;
  final List<String> errors;
  final DateTime collectedAt;
  final String agentVersion;

  Map<String, Object?> toJson() {
    return {
      'nodeId': nodeId,
      'hostname': hostname,
      'os': os,
      'agentVersion': agentVersion,
      'codexRunning': codexRunning,
      'conversations': conversations.map((item) => item.toJson()).toList(),
      'errors': errors,
      'collectedAt': collectedAt.toUtc().toIso8601String(),
    };
  }

  factory AgentSnapshot.fromJson(Map<String, Object?> json) {
    return AgentSnapshot(
      nodeId: _string(json, 'nodeId'),
      hostname: _string(json, 'hostname'),
      os: _string(json, 'os'),
      agentVersion: _string(json, 'agentVersion', fallback: '0.1.0'),
      codexRunning: json['codexRunning'] == true,
      conversations: _list(json['conversations'])
          .whereType<Map>()
          .map((item) => AgentConversation.fromJson(item.cast<String, Object?>()))
          .toList(),
      errors: _list(json['errors']).map((item) => item.toString()).toList(),
      collectedAt: _date(json['collectedAt']) ?? DateTime.now().toUtc(),
    );
  }
}

class DeviceStatusView {
  const DeviceStatusView({
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
  final ConversationRuntimeStatus status;
  final bool codexRunning;
  final int conversationCount;
  final DateTime? lastSeenAt;
  final DateTime? lastBeaconAt;
  final String? lastError;
  final bool manual;

  Map<String, Object?> toJson() {
    return {
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
    };
  }

  factory DeviceStatusView.fromJson(Map<String, Object?> json) {
    return DeviceStatusView(
      nodeId: _string(json, 'nodeId'),
      hostname: _string(json, 'hostname'),
      host: _string(json, 'host'),
      port: _int(json['port']),
      os: _string(json, 'os'),
      status: conversationStatusFromWire(_nullableString(json, 'status')),
      codexRunning: json['codexRunning'] == true,
      conversationCount: _int(json['conversationCount']),
      lastSeenAt: _date(json['lastSeenAt']),
      lastBeaconAt: _date(json['lastBeaconAt']),
      lastError: _nullableString(json, 'lastError'),
      manual: json['manual'] == true,
    );
  }
}

class DashboardSnapshot {
  const DashboardSnapshot({
    required this.devices,
    required this.conversations,
    required this.generatedAt,
  });

  final List<DeviceStatusView> devices;
  final List<AgentConversation> conversations;
  final DateTime generatedAt;

  int get activeConversationCount => conversations.length;

  int get onlineDeviceCount {
    return devices
        .where((device) =>
            device.status != ConversationRuntimeStatus.errorOffline)
        .length;
  }

  Map<String, Object?> toJson() {
    return {
      'generatedAt': generatedAt.toUtc().toIso8601String(),
      'devices': devices.map((device) => device.toJson()).toList(),
      'conversations': conversations.map((item) => item.toJson()).toList(),
    };
  }

  String encode() => jsonEncode(toJson());

  factory DashboardSnapshot.fromJson(Map<String, Object?> json) {
    return DashboardSnapshot(
      generatedAt: _date(json['generatedAt']) ?? DateTime.now().toUtc(),
      devices: _list(json['devices'])
          .whereType<Map>()
          .map((item) => DeviceStatusView.fromJson(item.cast<String, Object?>()))
          .toList(),
      conversations: _list(json['conversations'])
          .whereType<Map>()
          .map((item) => AgentConversation.fromJson(item.cast<String, Object?>()))
          .toList(),
    );
  }

  factory DashboardSnapshot.empty() {
    return DashboardSnapshot(
      devices: const [],
      conversations: const [],
      generatedAt: DateTime.now().toUtc(),
    );
  }
}

String _string(
  Map<String, Object?> json,
  String key, {
  String fallback = '',
}) {
  final value = json[key];
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  final text = value.toString();
  return text.isEmpty ? null : text;
}

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<Object?> _list(Object? value) {
  if (value is List) {
    return value.cast<Object?>();
  }
  return const [];
}

DateTime? _date(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  return DateTime.tryParse(value.toString())?.toUtc();
}
