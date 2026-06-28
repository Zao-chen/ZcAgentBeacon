import 'package:test/test.dart';
import 'package:zc_agentbeacon_core/zc_agentbeacon_core.dart';

void main() {
  final engine = ZcStatusEngine();

  test('detects open turn as thinking', () {
    final now = DateTime.utc(2026, 6, 28, 1);
    final items = engine.conversationsFromRaw([
      RawConversation(
        conversationId: 'conv-1',
        title: '会话',
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
      ),
    ], now: now);

    expect(items.single.status, ConversationStatus.thinking);
  });

  test('task completion becomes idle and uses final message', () {
    final now = DateTime.utc(2026, 6, 28, 1);
    final items = engine.conversationsFromRaw([
      RawConversation(
        conversationId: 'conv-1',
        title: '会话',
        cwd: '/tmp/project',
        updatedAt: now,
        events: [
          RawEventSignal(
            type: 'task_started',
            kind: 'turn_start',
            turnId: 'turn-1',
            eventAt: now.subtract(const Duration(seconds: 4)),
          ),
          RawEventSignal(
            type: 'task_complete',
            kind: 'turn_end',
            turnId: 'turn-1',
            eventAt: now,
            completedAt: now,
            messageSummary: '已经完成',
          ),
        ],
      ),
    ], now: now);

    expect(items.single.status, ConversationStatus.idle);
    expect(items.single.displayDetail, '已经完成');
  });

  test('explanation is preferred as display detail', () {
    final now = DateTime.utc(2026, 6, 28, 1);
    final items = engine.conversationsFromRaw([
      RawConversation(
        conversationId: 'conv-1',
        title: '会话',
        cwd: '/tmp/project',
        updatedAt: now,
        events: [
          RawEventSignal(
            type: 'function_call',
            kind: 'tool_call',
            callId: 'call-1',
            toolName: 'update_plan',
            eventAt: now,
            explanation: '正在整理计划',
          ),
        ],
      ),
    ], now: now);

    expect(items.single.status, ConversationStatus.toolRunning);
    expect(items.single.displayDetail, '正在整理计划');
  });

  test('folds uuid process-only auxiliary conversation into real conversation', () {
    final now = DateTime.utc(2026, 6, 28, 1);
    final items = engine.conversationsFromRaw([
      RawConversation(
        conversationId: '019f0973-452d-7f92-952d-6fab0cc180fe',
        title: '寻找近月少女选题',
        cwd: '/Users/me/project',
        updatedAt: now,
        events: [
          RawEventSignal(
            type: 'task_started',
            kind: 'turn_start',
            turnId: 'turn-real',
            eventAt: now,
          ),
        ],
      ),
      RawConversation(
        conversationId: '019f0979-5e37-7e90-b2b0-9d81ab32bf52',
        title: '019f0979-5e37-7e90-b2b0-9d81ab32bf52',
        cwd: '/Users/me/project',
        updatedAt: now,
        processes: [
          RawProcessSignal(command: 'sed -n 1,20p file.json', updatedAt: now),
        ],
      ),
    ], now: now);

    expect(items, hasLength(1));
    expect(items.single.title, '寻找近月少女选题');
    expect(items.single.status, ConversationStatus.toolRunning);
    expect(items.single.foldedAuxiliaryIds, contains('019f0979-5e37-7e90-b2b0-9d81ab32bf52'));
  });
}
