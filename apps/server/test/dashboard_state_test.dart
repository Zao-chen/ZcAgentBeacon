import 'package:test/test.dart';
import 'package:zc_agentbeacon_core/zc_agentbeacon_core.dart';

import '../bin/zc_agentbeacon_server.dart' hide main;

void main() {
  AgentSnapshot snapshot({
    required String nodeId,
    required List<RawConversation> rawConversations,
  }) {
    return AgentSnapshot(
      nodeId: nodeId,
      hostname: 'workstation',
      os: 'test',
      codexRunning: true,
      rawConversations: rawConversations,
      errors: const [],
      collectedAt: DateTime.now().toUtc(),
    );
  }

  RawConversation activeConversation(DateTime now) {
    return RawConversation(
      conversationId: 'conv-image',
      title: '读图测试',
      cwd: '/tmp/project',
      updatedAt: now,
      events: [
        RawEventSignal(
          type: 'task_started',
          kind: 'turn_start',
          turnId: 'turn-1',
          eventAt: now,
        ),
      ],
    );
  }

  test('keeps active conversation while a snapshot is temporarily missing it',
      () {
    final state = DashboardState()
      ..settings = const DashboardSettings(
        missingConversationGraceSeconds: 60,
      );
    state.addManualDevice('127.0.0.1', 42180, 'workstation');
    final key = state.devices.keys.single;
    final engine = ZcStatusEngine();
    final now = DateTime.now().toUtc();

    state.mergeSnapshot(
      key,
      snapshot(nodeId: 'node-1', rawConversations: [activeConversation(now)]),
      engine,
    );
    state.mergeSnapshot(
      key,
      snapshot(nodeId: 'node-1', rawConversations: const []),
      engine,
    );

    final item = state.snapshot().conversations.single;
    expect(item.status, ConversationStatus.thinking);
    expect(item.completedAt, isNull);
  });

  test('marks missing active conversation stale instead of completed', () {
    final state = DashboardState()
      ..settings = const DashboardSettings(
        missingConversationGraceSeconds: 0,
      );
    state.addManualDevice('127.0.0.1', 42180, 'workstation');
    final key = state.devices.keys.single;
    final engine = ZcStatusEngine();
    final now = DateTime.now().toUtc();

    state.mergeSnapshot(
      key,
      snapshot(nodeId: 'node-1', rawConversations: [activeConversation(now)]),
      engine,
    );
    state.mergeSnapshot(
      key,
      snapshot(nodeId: 'node-1', rawConversations: const []),
      engine,
    );

    final item = state.snapshot().conversations.single;
    expect(item.status, ConversationStatus.stale);
    expect(item.completedAt, isNull);
  });
}
