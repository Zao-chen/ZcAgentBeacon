import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zc_agentbeacon_core/codex_adapter.dart' show ClaudeAdapter;
import 'package:zc_agentbeacon_core/zc_agentbeacon_core.dart'
    show ConversationStatus, ZcStatusEngine;

void main() {
  test('parses Claude Code transcript into raw signals', () async {
    final directory = await Directory.systemTemp.createTemp('zc-claude-');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final file = File('${directory.path}/session-1.jsonl');
    await file.writeAsString('');
    final adapter = ClaudeAdapter();
    final lines = [
      jsonEncode({
        'type': 'user',
        'promptId': 'turn-1',
        'timestamp': '2026-06-28T10:00:00Z',
        'sessionId': 'session-1',
        'cwd': '/work/project',
        'message': {
          'role': 'user',
          'content': '请检查文件',
        },
      }),
      jsonEncode({
        'type': 'assistant',
        'timestamp': '2026-06-28T10:00:02Z',
        'sessionId': 'session-1',
        'cwd': '/work/project',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': '我先看文件'},
          ],
        },
      }),
      jsonEncode({
        'type': 'assistant',
        'timestamp': '2026-06-28T10:00:03Z',
        'sessionId': 'session-1',
        'cwd': '/work/project',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call-1',
              'name': 'Read',
              'input': {'file_path': '/work/project/a.dart'},
            },
          ],
        },
      }),
      jsonEncode({
        'type': 'user',
        'timestamp': '2026-06-28T10:00:04Z',
        'sessionId': 'session-1',
        'cwd': '/work/project',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call-1',
              'content': 'file content',
            },
          ],
        },
      }),
      jsonEncode({
        'type': 'assistant',
        'timestamp': '2026-06-28T10:00:05Z',
        'sessionId': 'session-1',
        'cwd': '/work/project',
        'message': {
          'role': 'assistant',
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': '检查完成'},
          ],
        },
      }),
      jsonEncode({
        'type': 'ai-title',
        'sessionId': 'session-1',
        'aiTitle': '文件检查',
      }),
    ];

    final raw = await adapter.parseTranscript(file, lines);

    expect(raw, isNotNull);
    expect(raw!.conversationId, 'claude:session-1');
    expect(raw.title, '文件检查');
    expect(raw.cwd, '/work/project');
    expect(raw.events.map((item) => item.kind), contains('tool_call'));
    expect(raw.events.map((item) => item.kind), contains('tool_output'));
    expect(raw.events.last.kind, 'turn_end');
  });

  test('new Claude user prompt after completion stays pending', () async {
    final directory = await Directory.systemTemp.createTemp('zc-claude-');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final file = File('${directory.path}/session-2.jsonl');
    await file.writeAsString('');
    final adapter = ClaudeAdapter();
    final lines = [
      jsonEncode({
        'type': 'user',
        'promptId': 'turn-1',
        'timestamp': '2026-06-28T10:00:00Z',
        'sessionId': 'session-2',
        'cwd': '/work/project',
        'message': {'role': 'user', 'content': '第一轮'},
      }),
      jsonEncode({
        'type': 'assistant',
        'timestamp': '2026-06-28T10:00:05Z',
        'sessionId': 'session-2',
        'cwd': '/work/project',
        'message': {
          'role': 'assistant',
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': '第一轮完成'},
          ],
        },
      }),
      jsonEncode({
        'type': 'user',
        'promptId': 'turn-2',
        'timestamp': '2026-06-28T10:00:08Z',
        'sessionId': 'session-2',
        'cwd': '/work/project',
        'message': {'role': 'user', 'content': '继续读图'},
      }),
    ];

    final raw = await adapter.parseTranscript(file, lines);
    final views = ZcStatusEngine().conversationsFromRaw(
      [raw!],
      now: DateTime.parse('2026-06-28T10:00:09Z'),
    );

    expect(views.single.status, ConversationStatus.thinking);
    expect(views.single.completedAt, isNull);
  });
}
