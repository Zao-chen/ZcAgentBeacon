import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:zc_agentbeacon_core/zc_agentbeacon_core.dart';

class ZcAgentBeaconApp extends StatelessWidget {
  const ZcAgentBeaconApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ZcAgentBeacon',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const DashboardScreen(),
    );
  }
}

ThemeData _theme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff087f8c),
      brightness: brightness,
    ),
    scaffoldBackgroundColor: dark
        ? const Color(0xff0f141b)
        : const Color(0xfff5f6f7),
  );
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final api = DashboardApi();
  DashboardSnapshot snapshot = DashboardSnapshot.empty();
  WebSocketChannel? channel;
  Timer? fallbackTimer;
  bool loaded = false;
  final knownStatuses = <String, ConversationStatus>{};
  final notifiedCompletions = <String>{};
  final justCompleted = <String, DateTime>{};

  @override
  void initState() {
    super.initState();
    connect();
    fetch();
    fallbackTimer = Timer.periodic(const Duration(seconds: 5), (_) => fetch());
  }

  @override
  void dispose() {
    fallbackTimer?.cancel();
    channel?.sink.close();
    super.dispose();
  }

  void connect() {
    try {
      channel = WebSocketChannel.connect(api.wsUri('/ws'));
      channel!.stream.listen(
        (event) => applyJson(event.toString()),
        onDone: reconnectLater,
        onError: (_) => reconnectLater(),
      );
    } on Object {
      reconnectLater();
    }
  }

  void reconnectLater() {
    channel?.sink.close();
    channel = null;
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted && channel == null) {
        connect();
      }
    });
  }

  Future<void> fetch() async {
    try {
      final next = await api.fetchSnapshot();
      if (mounted) {
        applySnapshot(next);
      }
    } on Object {
      return;
    }
  }

  void applyJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        applySnapshot(
          DashboardSnapshot.fromJson(decoded.cast<String, Object?>()),
        );
      }
    } on Object {
      return;
    }
  }

  void applySnapshot(DashboardSnapshot next) {
    detectCompletions(next.conversations);
    setState(() {
      snapshot = next;
      loaded = true;
    });
  }

  void detectCompletions(List<ConversationView> conversations) {
    final present = <String>{};
    final now = DateTime.now();
    for (final conversation in conversations) {
      final key = conversationKey(conversation);
      present.add(key);
      final previous = knownStatuses[key];
      final doneId =
          '$key:${conversation.completedAt ?? conversation.lastEventAt ?? conversation.seenAt}';
      if (loaded &&
          !conversation.suppressCompletion &&
          previous != null &&
          previous.isActive &&
          conversation.status == ConversationStatus.idle &&
          !notifiedCompletions.contains(doneId)) {
        notifiedCompletions.add(doneId);
        justCompleted[key] = now;
        showCompletion(conversation);
      }
      knownStatuses[key] = conversation.status;
    }
    knownStatuses.removeWhere((key, _) => !present.contains(key));
    justCompleted.removeWhere(
      (_, value) => now.difference(value).inSeconds > 9,
    );
  }

  void showCompletion(ConversationView conversation) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '${conversation.deviceName ?? '未知设备'} · ${conversation.title} 已完成',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conversations = [...snapshot.conversations]
      ..sort((a, b) {
        final aTime =
            a.lastEventAt ?? a.seenAt ?? a.completedAt ?? DateTime(1970);
        final bTime =
            b.lastEventAt ?? b.seenAt ?? b.completedAt ?? DateTime(1970);
        return bTime.compareTo(aTime);
      });
    final active = conversations.where((item) => item.status.isActive).length;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 38, 0),
          child: Column(
            children: [
              Header(active: active, devices: snapshot.devices.length),
              Expanded(
                child: conversations.isEmpty
                    ? EmptyState(
                        deviceCount: snapshot.devices.length,
                        loaded: loaded,
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        itemCount: conversations.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 7),
                        itemBuilder: (context, index) {
                          final item = conversations[index];
                          return ConversationRow(
                            conversation: item,
                            justCompleted: justCompleted.containsKey(
                              conversationKey(item),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Header extends StatelessWidget {
  const Header({required this.active, required this.devices, super.key});

  final int active;
  final int devices;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 64,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'ZcAgentBeacon',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
          ),
          StatTile(label: '活跃', value: active, color: const Color(0xff087f8c)),
          const SizedBox(width: 6),
          StatTile(label: '设备', value: devices, color: const Color(0xff2f7d32)),
        ],
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({
    required this.label,
    required this.value,
    required this.color,
    super.key,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 56,
      height: 40,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 26,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$value',
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ConversationRow extends StatelessWidget {
  const ConversationRow({
    required this.conversation,
    required this.justCompleted,
    super.key,
  });

  final ConversationView conversation;
  final bool justCompleted;

  @override
  Widget build(BuildContext context) {
    final info = statusInfo(conversation.status);
    final colors = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: justCompleted ? 1 : 0, end: 0),
      duration: const Duration(milliseconds: 1200),
      builder: (context, flash, child) {
        return Container(
          minHeight: 70,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Color.lerp(
              colors.surface,
              const Color(0xff2f7d32),
              flash * .12,
            ),
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              if (conversation.status == ConversationStatus.thinking ||
                  conversation.status == ConversationStatus.working)
                BoxShadow(
                  color: info.color.withOpacity(.16),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: Row(
            children: [
              Container(width: 7, height: 54, color: info.color),
              const SizedBox(width: 8),
              SizedBox(
                width: 66,
                child: StatusBadge(status: conversation.status),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        DeviceChip(
                          name:
                              conversation.deviceName ??
                              conversation.deviceHost ??
                              '未知设备',
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            conversation.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail(conversation),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 44,
                child: Text(
                  relative(
                    conversation.lastEventAt ??
                        conversation.seenAt ??
                        conversation.completedAt,
                  ),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.status, super.key});

  final ConversationStatus status;

  @override
  Widget build(BuildContext context) {
    final info = statusInfo(status);
    return Container(
      height: 35,
      decoration: BoxDecoration(
        border: Border.all(color: info.color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MotionDot(status: status, color: info.color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              info.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: info.color,
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MotionDot extends StatefulWidget {
  const MotionDot({required this.status, required this.color, super.key});

  final ConversationStatus status;
  final Color color;

  @override
  State<MotionDot> createState() => _MotionDotState();
}

class _MotionDotState extends State<MotionDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.status == ConversationStatus.toolRunning) {
      return RotationTransition(
        turns: controller,
        child: SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(widget.color),
          ),
        ),
      );
    }
    final active =
        widget.status == ConversationStatus.thinking ||
        widget.status == ConversationStatus.working;
    return ScaleTransition(
      scale: active
          ? Tween(begin: .75, end: 1.2).animate(
              CurvedAnimation(parent: controller, curve: Curves.easeInOut),
            )
          : const AlwaysStoppedAnimation<double>(.85),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

class DeviceChip extends StatelessWidget {
  const DeviceChip({required this.name, super.key});

  final String name;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxWidth: 104),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.deviceCount,
    required this.loaded,
    super.key,
  });

  final int deviceCount;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            loaded ? Icons.check_circle_outline : Icons.sync,
            size: 42,
            color: colors.primary,
          ),
          const SizedBox(height: 12),
          Text(
            loaded ? '暂无会话记录' : '正在连接',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            '$deviceCount 台设备已连接',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class DashboardApi {
  Uri apiUri(String path) {
    final base = Uri.base;
    final host = base.host.isEmpty ? '127.0.0.1' : base.host;
    final scheme = base.scheme == 'https' ? 'https' : 'http';
    final port = base.hasPort ? base.port : 42178;
    return Uri(scheme: scheme, host: host, port: port, path: path);
  }

  Uri wsUri(String path) {
    final uri = apiUri(path);
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  Future<DashboardSnapshot> fetchSnapshot() async {
    final response = await http.get(apiUri('/api/conversations'));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Invalid dashboard JSON');
    }
    return DashboardSnapshot.fromJson(decoded.cast<String, Object?>());
  }
}

class StatusInfo {
  const StatusInfo(this.label, this.color);
  final String label;
  final Color color;
}

StatusInfo statusInfo(ConversationStatus status) {
  return switch (status) {
    ConversationStatus.toolRunning => const StatusInfo('工具', Color(0xffb15f00)),
    ConversationStatus.thinking => const StatusInfo('思考', Color(0xff087f8c)),
    ConversationStatus.working => const StatusInfo('运行', Color(0xff087f8c)),
    ConversationStatus.waitingForUser => const StatusInfo(
      '等待',
      Color(0xff3366cc),
    ),
    ConversationStatus.interrupted => const StatusInfo('中断', Color(0xffb3261e)),
    ConversationStatus.stale => const StatusInfo('过期', Color(0xffb15f00)),
    ConversationStatus.errorOffline => const StatusInfo(
      '离线',
      Color(0xffb3261e),
    ),
    ConversationStatus.idle => const StatusInfo('完成', Color(0xff66717d)),
  };
}

String conversationKey(ConversationView conversation) {
  return [
    conversation.deviceId ??
        conversation.deviceHost ??
        conversation.deviceName ??
        'device',
    conversation.conversationId,
  ].join(':');
}

String detail(ConversationView c) {
  final parts = <String>[];
  if ((c.displayDetail ?? '').isNotEmpty) {
    parts.add(c.displayDetail!);
  } else if ((c.lastExplanation ?? '').isNotEmpty) {
    parts.add(c.lastExplanation!);
  } else if ((c.lastCommand ?? '').isNotEmpty) {
    parts.add(c.lastCommand!);
  } else if ((c.lastMessageSummary ?? '').isNotEmpty) {
    parts.add(c.lastMessageSummary!);
  } else if ((c.lastToolName ?? '').isNotEmpty) {
    parts.add(c.lastToolName!);
  }
  final base = basename(c.cwd);
  if (base.isNotEmpty) {
    parts.add(base);
  }
  final text = parts.join(' / ');
  return text.length > 220
      ? '${text.substring(0, 220)}...'
      : (text.isEmpty ? '暂无详情' : text);
}

String basename(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((item) => item.isNotEmpty)
      .toList();
  return parts.isEmpty ? '' : parts.last;
}

String relative(DateTime? time) {
  if (time == null) {
    return '未知';
  }
  final age = DateTime.now().toUtc().difference(time.toUtc());
  if (age.inSeconds < 15) return '刚刚';
  if (age.inMinutes < 1) return '${age.inSeconds}秒前';
  if (age.inHours < 1) return '${age.inMinutes}分钟前';
  if (age.inDays < 1) return '${age.inHours}小时前';
  return '${age.inDays}天前';
}
