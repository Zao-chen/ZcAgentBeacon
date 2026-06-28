class SecretMasker {
  SecretMasker({
    this.replacement = '[secret]',
    this.maxLength = 1200,
  });

  final String replacement;
  final int maxLength;

  static final List<RegExp> _patterns = [
    RegExp(
      "(?i)(api[_-]?key|token|secret|password|passwd|authorization|bearer)\\s*[:=]\\s*[\"']?[^\"'\\s,;]+",
    ),
    RegExp(r'(?i)bearer\s+[a-z0-9._\-]{16,}'),
    RegExp(r'sk-[a-zA-Z0-9_\-]{16,}'),
    RegExp(r'tp-[a-zA-Z0-9_\-]{16,}'),
    RegExp(r'gh[pousr]_[a-zA-Z0-9_]{20,}'),
    RegExp(r'AKIA[0-9A-Z]{16}'),
  ];

  String mask(String? value) {
    if (value == null || value.isEmpty) {
      return '';
    }

    var masked = value;
    for (final pattern in _patterns) {
      masked = masked.replaceAllMapped(pattern, (match) {
        final matched = match.group(0) ?? '';
        final separator = RegExp(r'[:=]').firstMatch(matched);
        if (separator == null) {
          return replacement;
        }

        return '${matched.substring(0, separator.end).trimRight()} $replacement';
      });
    }

    masked = masked.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (masked.length <= maxLength) {
      return masked;
    }

    return '${masked.substring(0, maxLength)}...';
  }
}
