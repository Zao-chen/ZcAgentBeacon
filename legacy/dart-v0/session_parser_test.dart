import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zc_agentbeacon/src/agent/session_parser.dart';

void main() {
  test('detects an open task as working', () {
    final parser = CodexSessionParser();

    final activity = parser.parseLines([
      _event('2026-06-27T01:00:00Z', {
        'type': 'task_started',
        'turn_id': 'turn-1',
      }),
      _event('2026-06-27T01:00:01Z', {
        'type': 'agent_message',
        'message': 'Thinking through the plan',
      }),
    ]);

    expect(activity.hasOpenTurn, isTrue);
    expect(activity.hasPendingTool, isFalse);
    expect(activity.turnId, 'turn-1');
    expect(activity.lastMessageSummary, contains('Thinking'));
  });

  test('detects pending function calls and clears them on output', () {
    final parser = CodexSessionParser();

    final pending = parser.parseLines([
      _event('2026-06-27T01:00:00Z', {
        'type': 'task_started',
        'turn_id': 'turn-1',
      }),
      _event('2026-06-27T01:00:02Z', {
        'type': 'function_call',
        'name': 'shell_command',
        'call_id': 'call-1',
        'arguments': {'command': 'echo hello'},
      }),
    ]);

    expect(pending.hasPendingTool, isTrue);
    expect(pending.lastToolName, 'shell_command');
    expect(pending.lastCommand, contains('echo hello'));

    final complete = parser.parseLines([
      _event('2026-06-27T01:00:00Z', {
        'type': 'task_started',
        'turn_id': 'turn-1',
      }),
      _event('2026-06-27T01:00:02Z', {
        'type': 'function_call',
        'name': 'shell_command',
        'call_id': 'call-1',
        'arguments': {'command': 'echo hello'},
      }),
      _event('2026-06-27T01:00:03Z', {
        'type': 'function_call_output',
        'call_id': 'call-1',
        'output': 'hello',
      }),
      _event('2026-06-27T01:00:04Z', {
        'type': 'task_complete',
        'turn_id': 'turn-1',
        'last_agent_message': 'Done',
      }),
    ]);

    expect(complete.isActive, isFalse);
    expect(complete.lastTaskCompleteAt, isNotNull);
  });
}

String _event(String timestamp, Map<String, Object?> payload) {
  return jsonEncode({
    'timestamp': timestamp,
    'type': 'event_msg',
    'payload': payload,
  });
}
