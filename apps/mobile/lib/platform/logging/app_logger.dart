import 'dart:developer' as developer;

/// Minimal structured logger. Content text, translations and credentials are
/// never logged; only identifiers, sizes, durations and failure categories.
class AppLogger {
  const AppLogger(this.name);

  final String name;

  void info(String event, [Map<String, Object?> context = const {}]) {
    _log('INFO', event, context);
  }

  void warn(String event, [Map<String, Object?> context = const {}]) {
    _log('WARN', event, context);
  }

  void error(String event, [Map<String, Object?> context = const {}]) {
    _log('ERROR', event, context);
  }

  void _log(String level, String event, Map<String, Object?> context) {
    final suffix =
        context.isEmpty ? '' : ' ${_format(context)}';
    developer.log('$level $event$suffix', name: name);
  }

  static String _format(Map<String, Object?> context) => context.entries
      .map((e) => '${e.key}=${e.value}')
      .join(' ');
}
