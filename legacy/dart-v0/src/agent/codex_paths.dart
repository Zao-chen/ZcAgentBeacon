import 'dart:io';

class CodexPaths {
  CodexPaths._();

  static Directory codexHome() {
    final override = Platform.environment['AGENTBEACON_CODEX_HOME'];
    if (override != null && override.trim().isNotEmpty) {
      return Directory(override.trim());
    }

    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return Directory(_join(home, '.codex'));
  }

  static File stateDatabase(Directory codexHome) {
    return File(_join(codexHome.path, 'state_5.sqlite'));
  }

  static File processManagerFile(Directory codexHome) {
    return File(_join(codexHome.path, 'process_manager', 'chat_processes.json'));
  }

  static Directory sessionsDirectory(Directory codexHome) {
    return Directory(_join(codexHome.path, 'sessions'));
  }

  static File installationIdFile(Directory codexHome) {
    return File(_join(codexHome.path, 'installation_id'));
  }

  static String _join(String first, String second, [String? third]) {
    final separator = Platform.pathSeparator;
    final joined = first.endsWith(separator) ? '$first$second' : '$first$separator$second';
    if (third == null) {
      return joined;
    }
    return joined.endsWith(separator) ? '$joined$third' : '$joined$separator$third';
  }
}
