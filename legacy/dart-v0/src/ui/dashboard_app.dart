import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../shared/agent_models.dart';

class AgentBeaconApp extends StatelessWidget {
  const AgentBeaconApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AgentBeacon',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff087f8c),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff6f7f8),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _api = DashboardApi();
  WebSocketChannel? _channel;
  Timer? _fallbackTimer;
  DashboardSnapshot _snapshot = DashboardSnapshot.empty();
  UiSettings _settings = const UiSettings();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connect();
    _loadInitial();
    _fallbackTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _fetchSnapshot();
    });
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _fallbackTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    await Future.wait([
      _fetchSnapshot(),
      _fetchSettings(),
    ]);
  }

  void _connect() {
    try {
      _channel = WebSocketChannel.connect(_api.wsUri('/ws'));
      _channel!.stream.listen(
        (event) => _applySnapshotJson(event.toString()),
        onError: (_) => _reconnectLater(),
        onDone: _reconnectLater,
      );
    } on Object {
      _reconnectLater();
    }
  }

  void _reconnectLater() {
    _channel?.sink.close();
    _channel = null;
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted && _channel == null) {
        _connect();
      }
    });
  }

  Future<void> _fetchSnapshot() async {
    try {
      final snapshot = await _api.fetchSnapshot();
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _fetchSettings() async {
    try {
      final settings = await _api.fetchSettings();
      if (mounted) {
        setState(() => _settings = settings);
      }
    } on Object {
      return;
    }
  }

  void _applySnapshotJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final snapshot =
          DashboardSnapshot.fromJson(decoded.cast<String, Object?>());
      if (mounted) {
        setState(() {
          _snapshot = snapshot;
          _loading = false;
          _error = null;
        });
      }
    } on Object {
      return;
    }
  }

  Future<void> _saveSettings(UiSettings settings) async {
    final saved = await _api.updateSettings(settings);
    if (mounted) {
      setState(() => _settings = saved);
    }
  }

  Future<void> _addManualDevice(String host, int port) async {
    final snapshot = await _api.addDevice(host: host, port: port);
    if (mounted) {
      setState(() => _snapshot = snapshot);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offline = _snapshot.devices
        .where((device) =>
            device.status == ConversationRuntimeStatus.errorOffline)
        .toList();
    final grouped = _groupConversations(_snapshot.conversations);

    return Scaffold(
      endDrawer: SettingsDrawer(
        settings: _settings,
        onSave: _saveSettings,
        onAddDevice: _addManualDevice,
      ),
      body: SafeArea(
        child: Builder(
          builder: (context) {
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: DashboardHeader(
                    snapshot: _snapshot,
                    loading: _loading,
                    error: _error,
                    onRefresh: _fetchSnapshot,
                    onSettings: () => Scaffold.of(context).openEndDrawer(),
                  ),
                ),
                if (offline.isNotEmpty)
                  SliverToBoxAdapter(child: OfflineBanner(devices: offline)),
                SliverToBoxAdapter(
                  child: DeviceStrip(devices: _snapshot.devices),
                ),
                if (_snapshot.conversations.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      deviceCount: _snapshot.devices.length,
                      loading: _loading,
                    ),
                  )
                else
                  for (final entry in grouped.entries) ...[
                    SliverToBoxAdapter(
                      child: SectionHeader(
                        title: entry.key,
                        count: entry.value.length,
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                      sliver: SliverGrid(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            return ConversationCard(
                              conversation: entry.value[index],
                              showDetails: _settings.showDetails,
                            );
                          },
                          childCount: entry.value.length,
                        ),
                        gridDelegate:
                            SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 430,
                          mainAxisExtent: _settings.showDetails ? 278 : 190,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                      ),
                    ),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }

  Map<String, List<AgentConversation>> _groupConversations(
    List<AgentConversation> conversations,
  ) {
    final grouped = <String, List<AgentConversation>>{};
    for (final conversation in conversations) {
      final key = conversation.deviceName ?? conversation.deviceHost ?? 'Unknown';
      grouped.putIfAbsent(key, () => []).add(conversation);
    }
    return grouped;
  }
}

class DashboardHeader extends StatelessWidget {
  const DashboardHeader({
    required this.snapshot,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onSettings,
    super.key,
  });

  final DashboardSnapshot snapshot;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final offline = snapshot.devices
        .where((device) =>
            device.status == ConversationRuntimeStatus.errorOffline)
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xff101820),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.radar, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'AgentBeacon',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ),
              Tooltip(
                message: 'Refresh',
                child: IconButton.filledTonal(
                  onPressed: onRefresh,
                  icon: loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Settings',
                child: IconButton.filledTonal(
                  onPressed: onSettings,
                  icon: const Icon(Icons.tune),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              StatBox(
                label: 'Active',
                value: snapshot.activeConversationCount.toString(),
                color: const Color(0xff087f8c),
              ),
              StatBox(
                label: 'Online',
                value: snapshot.onlineDeviceCount.toString(),
                color: const Color(0xff2f7d32),
              ),
              StatBox(
                label: 'Offline',
                value: offline.toString(),
                color: const Color(0xffb3261e),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(
              error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xffb3261e)),
            ),
          ],
        ],
      ),
    );
  }
}

class StatBox extends StatelessWidget {
  const StatBox({
    required this.label,
    required this.value,
    required this.color,
    super.key,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 132,
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd8dde3)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xff5f6975)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({required this.devices, super.key});

  final List<DeviceStatusView> devices;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xffffece8),
        border: Border.all(color: const Color(0xffffb4a8)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Color(0xffb3261e)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              devices.map((device) => device.hostname).join(', '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xff8c1d18),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DeviceStrip extends StatelessWidget {
  const DeviceStrip({required this.devices, super.key});

  final List<DeviceStatusView> devices;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: devices.isEmpty ? 0 : 54,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          final device = devices[index];
          final color = _statusColor(device.status);
          return Container(
            width: 210,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xffd8dde3)),
            ),
            child: Row(
              children: [
                Icon(Icons.computer, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        device.hostname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${device.conversationCount} active',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff5f6975),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemCount: devices.length,
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({required this.title, required this.count, super.key});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
          Text(
            count.toString(),
            style: const TextStyle(
              color: Color(0xff5f6975),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class ConversationCard extends StatelessWidget {
  const ConversationCard({
    required this.conversation,
    required this.showDetails,
    super.key,
  });

  final AgentConversation conversation;
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(conversation.status);
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xffd8dde3)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 11,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0,
                          ),
                        ),
                        Text(
                          _basename(conversation.cwd),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xff5f6975),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  StatusPill(status: conversation.status),
                ],
              ),
              const SizedBox(height: 12),
              InfoLine(
                icon: Icons.memory,
                label: conversation.lastToolName ?? 'turn',
                value: conversation.turnId ?? conversation.conversationId,
              ),
              const SizedBox(height: 8),
              InfoLine(
                icon: Icons.schedule,
                label: 'updated',
                value: _relativeTime(conversation.lastEventAt),
              ),
              if (showDetails) ...[
                const SizedBox(height: 12),
                DetailBlock(
                  icon: Icons.terminal,
                  value: conversation.lastCommand,
                ),
                const SizedBox(height: 8),
                DetailBlock(
                  icon: Icons.chat_bubble_outline,
                  value: conversation.lastMessageSummary,
                ),
                const SizedBox(height: 8),
                DetailBlock(
                  icon: Icons.output,
                  value: conversation.lastToolOutput,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({required this.status, super.key});

  final ConversationRuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    return Container(
      height: 28,
      constraints: const BoxConstraints(minWidth: 92),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.38)),
      ),
      alignment: Alignment.center,
      child: Text(
        _statusLabel(status),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class InfoLine extends StatelessWidget {
  const InfoLine({
    required this.icon,
    required this.label,
    required this.value,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xff5f6975)),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xff5f6975),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class DetailBlock extends StatelessWidget {
  const DetailBlock({
    required this.icon,
    required this.value,
    super.key,
  });

  final IconData icon;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final text = value?.trim();
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xfff2f4f6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xff5f6975)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text == null || text.isEmpty ? '...' : text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, height: 1.18),
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.deviceCount,
    required this.loading,
    super.key,
  });

  final int deviceCount;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 360,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xffd8dde3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              loading ? Icons.sync : Icons.check_circle_outline,
              size: 42,
              color: loading ? const Color(0xff087f8c) : const Color(0xff2f7d32),
            ),
            const SizedBox(height: 12),
            Text(
              loading ? 'Syncing' : 'No active Codex turns',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$deviceCount devices',
              style: const TextStyle(color: Color(0xff5f6975)),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsDrawer extends StatefulWidget {
  const SettingsDrawer({
    required this.settings,
    required this.onSave,
    required this.onAddDevice,
    super.key,
  });

  final UiSettings settings;
  final Future<void> Function(UiSettings settings) onSave;
  final Future<void> Function(String host, int port) onAddDevice;

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  late UiSettings _settings;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _hostController = TextEditingController();
    _portController = TextEditingController(text: '42180');
  }

  @override
  void didUpdateWidget(covariant SettingsDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) {
      _settings = widget.settings;
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Settings',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Close',
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            SwitchListTile(
              value: _settings.showDetails,
              onChanged: (value) => setState(() {
                _settings = _settings.copyWith(showDetails: value);
              }),
              contentPadding: EdgeInsets.zero,
              title: const Text('Detailed fields'),
            ),
            SliderSetting(
              label: 'Poll',
              value: _settings.pollIntervalMs / 1000,
              min: 1,
              max: 10,
              divisions: 9,
              suffix: 's',
              onChanged: (value) => setState(() {
                _settings = _settings.copyWith(
                  pollIntervalMs: (value * 1000).round(),
                );
              }),
            ),
            SliderSetting(
              label: 'Stale',
              value: _settings.staleAfterSeconds.toDouble(),
              min: 5,
              max: 120,
              divisions: 23,
              suffix: 's',
              onChanged: (value) => setState(() {
                _settings = _settings.copyWith(
                  staleAfterSeconds: value.round(),
                );
              }),
            ),
            SliderSetting(
              label: 'Offline',
              value: _settings.offlineAfterSeconds.toDouble(),
              min: 10,
              max: 240,
              divisions: 23,
              suffix: 's',
              onChanged: (value) => setState(() {
                _settings = _settings.copyWith(
                  offlineAfterSeconds: value.round(),
                );
              }),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _saving ? null : _saveSettings,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: const Text('Save'),
            ),
            const Divider(height: 34),
            TextField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: 'Agent host',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _saving ? null : _addDevice,
              icon: const Icon(Icons.add_link),
              label: const Text('Add device'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveSettings() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(_settings);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _addDevice() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 42180;
    if (host.isEmpty) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onAddDevice(host, port);
      _hostController.clear();
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}

class SliderSetting extends StatelessWidget {
  const SliderSetting({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.suffix,
    required this.onChanged,
    super.key,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text('${value.round()}$suffix'),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class UiSettings {
  const UiSettings({
    this.pollIntervalMs = 2000,
    this.staleAfterSeconds = 15,
    this.offlineAfterSeconds = 45,
    this.showDetails = true,
  });

  final int pollIntervalMs;
  final int staleAfterSeconds;
  final int offlineAfterSeconds;
  final bool showDetails;

  UiSettings copyWith({
    int? pollIntervalMs,
    int? staleAfterSeconds,
    int? offlineAfterSeconds,
    bool? showDetails,
  }) {
    return UiSettings(
      pollIntervalMs: pollIntervalMs ?? this.pollIntervalMs,
      staleAfterSeconds: staleAfterSeconds ?? this.staleAfterSeconds,
      offlineAfterSeconds: offlineAfterSeconds ?? this.offlineAfterSeconds,
      showDetails: showDetails ?? this.showDetails,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'pollIntervalMs': pollIntervalMs,
      'staleAfterSeconds': staleAfterSeconds,
      'offlineAfterSeconds': offlineAfterSeconds,
      'showDetails': showDetails,
    };
  }

  factory UiSettings.fromJson(Map<String, Object?> json) {
    return UiSettings(
      pollIntervalMs: _int(json['pollIntervalMs'], 2000),
      staleAfterSeconds: _int(json['staleAfterSeconds'], 15),
      offlineAfterSeconds: _int(json['offlineAfterSeconds'], 45),
      showDetails: json['showDetails'] != false,
    );
  }
}

class DashboardApi {
  Uri apiUri(String path) {
    final base = Uri.base;
    final host = base.host.isEmpty ? '127.0.0.1' : base.host;
    final scheme = base.scheme == 'https' ? 'https' : 'http';
    final port = base.host.isEmpty ? 42178 : base.port;
    return Uri(scheme: scheme, host: host, port: port, path: path);
  }

  Uri wsUri(String path) {
    final base = apiUri(path);
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');
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

  Future<UiSettings> fetchSettings() async {
    final response = await http.get(apiUri('/api/settings'));
    if (response.statusCode != 200) {
      return const UiSettings();
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      return const UiSettings();
    }
    return UiSettings.fromJson(decoded.cast<String, Object?>());
  }

  Future<UiSettings> updateSettings(UiSettings settings) async {
    final response = await http.post(
      apiUri('/api/settings'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(settings.toJson()),
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      return settings;
    }
    return UiSettings.fromJson(decoded.cast<String, Object?>());
  }

  Future<DashboardSnapshot> addDevice({
    required String host,
    required int port,
  }) async {
    final response = await http.post(
      apiUri('/api/devices'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'host': host, 'port': port}),
    );
    if (response.statusCode != 201) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Invalid dashboard JSON');
    }
    return DashboardSnapshot.fromJson(decoded.cast<String, Object?>());
  }
}

Color _statusColor(ConversationRuntimeStatus status) {
  return switch (status) {
    ConversationRuntimeStatus.working => const Color(0xff087f8c),
    ConversationRuntimeStatus.toolRunning => const Color(0xffc77700),
    ConversationRuntimeStatus.waitingForUser => const Color(0xff3366cc),
    ConversationRuntimeStatus.idle => const Color(0xff2f7d32),
    ConversationRuntimeStatus.stale => const Color(0xffa35b00),
    ConversationRuntimeStatus.errorOffline => const Color(0xffb3261e),
  };
}

String _statusLabel(ConversationRuntimeStatus status) {
  return switch (status) {
    ConversationRuntimeStatus.working => 'WORKING',
    ConversationRuntimeStatus.toolRunning => 'TOOL',
    ConversationRuntimeStatus.waitingForUser => 'WAITING',
    ConversationRuntimeStatus.idle => 'IDLE',
    ConversationRuntimeStatus.stale => 'STALE',
    ConversationRuntimeStatus.errorOffline => 'OFFLINE',
  };
}

String _basename(String path) {
  if (path.isEmpty) {
    return '';
  }
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

String _relativeTime(DateTime? time) {
  if (time == null) {
    return 'unknown';
  }
  final age = DateTime.now().toUtc().difference(time.toUtc());
  if (age.inSeconds < 10) {
    return 'now';
  }
  if (age.inMinutes < 1) {
    return '${age.inSeconds}s ago';
  }
  if (age.inHours < 1) {
    return '${age.inMinutes}m ago';
  }
  return '${age.inHours}h ago';
}

int _int(Object? value, int fallback) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}
