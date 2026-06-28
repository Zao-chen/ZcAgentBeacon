import 'codex_adapter.dart';
import 'claude_adapter.dart';
import 'models.dart';

class LocalAgentAdapter {
  LocalAgentAdapter({
    CodexAdapter? codexAdapter,
    ClaudeAdapter? claudeAdapter,
  })  : codexAdapter = codexAdapter ?? CodexAdapter(),
        claudeAdapter = claudeAdapter ?? ClaudeAdapter();

  final CodexAdapter codexAdapter;
  final ClaudeAdapter claudeAdapter;

  Future<AgentSnapshot> collect() async {
    final codex = await codexAdapter.collect();
    final claude = await claudeAdapter.collect();
    final errors = [
      ...codex.errors,
      ...claude.errors,
    ];
    if (claude.rawConversations.isNotEmpty || claude.codexRunning) {
      errors.removeWhere(
        (item) => item.startsWith('Codex state database not found:'),
      );
    }
    return AgentSnapshot(
      nodeId: codex.nodeId.isNotEmpty ? codex.nodeId : claude.nodeId,
      hostname: codex.hostname.isNotEmpty ? codex.hostname : claude.hostname,
      os: codex.os.isNotEmpty ? codex.os : claude.os,
      codexRunning: codex.codexRunning || claude.codexRunning,
      rawConversations: [
        ...codex.rawConversations,
        ...claude.rawConversations,
      ],
      errors: errors,
      collectedAt: _latest(codex.collectedAt, claude.collectedAt),
      agentVersion: '0.3.0-dart-raw-signals+multi-agent',
    );
  }
}

DateTime _latest(DateTime first, DateTime second) {
  return first.isAfter(second) ? first : second;
}
