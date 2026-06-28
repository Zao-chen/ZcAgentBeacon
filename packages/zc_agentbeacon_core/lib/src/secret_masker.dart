class SecretMasker {
  SecretMasker({this.maxLength = 1200});

  final int maxLength;

  static final List<RegExp> _patterns = [
    RegExp(
      r'''(?i)(?:\$env:|env:)?[A-Z0-9_]*(?:PASS|PASSWORD|TOKEN|SECRET|API[_-]?KEY|ACCESS[_-]?KEY)[A-Z0-9_]*\s*=\s*["']?[^"'\s,;]+''',
    ),
    RegExp(
      r'''(?i)(api[_-]?key|token|secret|password|passwd|authorization|bearer)\s*[:=]\s*["']?[^"'\s,;]+''',
    ),
    RegExp(r'(?i)bearer\s+[a-z0-9._\-]{16,}'),
    RegExp(r'sk-[a-zA-Z0-9_\-]{16,}'),
    RegExp(r'tp-[a-zA-Z0-9_\-]{16,}'),
    RegExp(r'gh[pousr]_[a-zA-Z0-9_]{20,}'),
    RegExp(r'AKIA[0-9A-Z]{16}'),
  ];

  String mask(Object? value, {int? limit}) {
    if (value == null) {
      return '';
    }
    var text = value.toString();
    for (final pattern in _patterns) {
      text = text.replaceAllMapped(pattern, (match) {
        final found = match.group(0) ?? '';
        final equals = found.indexOf('=');
        final colon = found.indexOf(':');
        final index = [equals, colon].where((item) => item >= 0).fold<int>(
          -1,
          (previous, item) => previous < 0 || item < previous ? item : previous,
        );
        if (index < 0) {
          return '[secret]';
        }
        return '${found.substring(0, index + 1).trimRight()} [secret]';
      });
    }
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final max = limit ?? maxLength;
    if (text.length > max) {
      return '${text.substring(0, max)}...';
    }
    return text;
  }
}
