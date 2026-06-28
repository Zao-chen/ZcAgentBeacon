import 'dart:convert';

import 'package:test/test.dart';
import 'package:zc_agentbeacon_core/codex_adapter.dart';

void main() {
  test('parses session metadata for subagent sessions', () {
    final adapter = CodexAdapter();
    final events = adapter.parseRawSessionLines([
      jsonEncode({
        'timestamp': '2026-06-28T09:38:50.510Z',
        'type': 'session_meta',
        'payload': {
          'thread_source': 'subagent',
          'source': {
            'subagent': {'other': 'guardian'},
          },
        },
      }),
    ]);

    expect(events, hasLength(1));
    expect(events.single.kind, 'session_meta');
    expect(events.single.role, 'subagent');
    expect(events.single.messageSummary, contains('guardian'));
  });
}
