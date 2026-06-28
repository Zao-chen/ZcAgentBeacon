import 'dart:io';

class CodexProcessDetector {
  Future<int> countCodexProcesses() async {
    if (Platform.isWindows) {
      return _countWindows();
    }
    return _countPosix();
  }

  Future<int> _countWindows() async {
    try {
      final result = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
      if (result.exitCode != 0) {
        return 0;
      }
      final stdout = result.stdout.toString().toLowerCase();
      return RegExp(r'"codex\.exe"', caseSensitive: false)
          .allMatches(stdout)
          .length;
    } on Object {
      return 0;
    }
  }

  Future<int> _countPosix() async {
    try {
      final result = await Process.run('ps', ['-axo', 'comm=']);
      if (result.exitCode != 0) {
        return 0;
      }
      return LineSplitterCompat.split(result.stdout.toString())
          .where((line) => line.trim().toLowerCase() == 'codex')
          .length;
    } on Object {
      return 0;
    }
  }
}

class LineSplitterCompat {
  LineSplitterCompat._();

  static List<String> split(String value) {
    return value.split(RegExp(r'\r?\n'));
  }
}
