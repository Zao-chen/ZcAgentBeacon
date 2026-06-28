import 'dart:io';

import 'codex_paths.dart';

class CodexThreadRecord {
  const CodexThreadRecord({
    required this.id,
    required this.title,
    required this.cwd,
    required this.rolloutPath,
    required this.updatedAtMs,
  });

  final String id;
  final String title;
  final String cwd;
  final String rolloutPath;
  final int updatedAtMs;
}

class CodexThreadStore {
  CodexThreadStore({
    String? sqliteCommand,
  }) : _sqliteCommand = sqliteCommand ??
            Platform.environment['AGENTBEACON_SQLITE3'] ??
            'sqlite3';

  final String _sqliteCommand;

  Future<List<CodexThreadRecord>> readUnarchivedThreads({
    required Directory codexHome,
    required List<String> errors,
  }) async {
    final database = CodexPaths.stateDatabase(codexHome);
    if (!await database.exists()) {
      errors.add('Codex state database not found: ${database.path}');
      return const [];
    }

    const query = '''
select
  id,
  replace(replace(coalesce(nullif(title, ''), nullif(preview, ''), id), char(9), ' '), char(10), ' '),
  replace(replace(cwd, char(9), ' '), char(10), ' '),
  replace(replace(rollout_path, char(9), ' '), char(10), ' '),
  coalesce(updated_at_ms, updated_at * 1000)
from threads
where archived = 0
order by coalesce(recency_at_ms, updated_at_ms, updated_at * 1000) desc;
''';

    final result = await _runSqlite(database.path, query);
    if (result.exitCode != 0) {
      errors.add('sqlite3 read failed: ${result.stderr}'.trim());
      return const [];
    }

    return result.stdout
        .toString()
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .map(_parseThreadLine)
        .whereType<CodexThreadRecord>()
        .toList();
  }

  Future<ProcessResult> _runSqlite(String database, String query) async {
    final args = ['-separator', '\t', database, query];
    try {
      return Process.run(_sqliteCommand, args);
    } on Object catch (error) {
      return ProcessResult(0, 1, '', error.toString());
    }
  }

  CodexThreadRecord? _parseThreadLine(String line) {
    final parts = line.split('\t');
    if (parts.length < 5) {
      return null;
    }
    return CodexThreadRecord(
      id: parts[0],
      title: _truncate(parts[1].isEmpty ? 'Untitled' : parts[1], 180),
      cwd: parts[2],
      rolloutPath: parts[3],
      updatedAtMs: int.tryParse(parts[4]) ?? 0,
    );
  }

  String _truncate(String value, int maxLength) {
    final trimmed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length <= maxLength) {
      return trimmed;
    }
    return '${trimmed.substring(0, maxLength)}...';
  }
}
