/// Argument parsing for `aurora-cli`. **Pure Dart: no Flutter imports.** All of
/// `lib/cli/` must compile with `dart build cli` into a binary that needs no display
/// (GTK cannot start on a headless server or in an SSH session).
library;

import '../core/config_compiler.dart' show AuroraMode;

enum AuroraCliVerb { connect, disconnect, status, version, help, import, servers, remove }

/// Everything one command-line invocation asks for.
///
/// [mode] and [line] stay null when unspecified, and the caller applies the shared
/// default. They are deliberately not filled in here: the default has one source
/// (`resolveDefaultRouteTarget`) that both the GUI and the CLI read.
class AuroraCliOptions {
  const AuroraCliOptions({
    required this.verb,
    this.mode,
    this.line,
    this.contractPath,
    this.refresh = true,
    this.json = false,
    this.timeout = const Duration(seconds: 30),
    this.error,
    this.arguments = const [],
  });

  final AuroraCliVerb verb;

  /// Null means the default (global).
  final AuroraMode? mode;

  /// Null means the default route; `'auto'` explicitly asks for automatic
  /// selection; anything else is a route family id.
  final String? line;

  /// An explicit contract file. Null means: refresh, then local cache, then embedded.
  final String? contractPath;

  final bool refresh;
  final bool json;
  final Duration timeout;

  /// Why parsing failed, in plain words. When set, the caller must print it and
  /// exit non-zero.
  final String? error;

  /// Positional arguments of `import` (links) and `remove` (server name).
  final List<String> arguments;

  AuroraCliOptions asError(String message) =>
      AuroraCliOptions(verb: verb, error: message);
}

const _verbs = <String, AuroraCliVerb>{
  'connect': AuroraCliVerb.connect,
  'disconnect': AuroraCliVerb.disconnect,
  'stop': AuroraCliVerb.disconnect,
  'status': AuroraCliVerb.status,
  'version': AuroraCliVerb.version,
  'help': AuroraCliVerb.help,
  'import': AuroraCliVerb.import,
  'servers': AuroraCliVerb.servers,
  'remove': AuroraCliVerb.remove,
};

/// Turns argv into [AuroraCliOptions]. Anything unrecognized becomes
/// [AuroraCliOptions.error]. The most dangerous thing a CLI can do is shrug and run
/// the default: the user believes they named a route, ends up somewhere else, and the
/// screen still says "connected".
AuroraCliOptions parseAuroraCliArgs(List<String> args) {
  var verb = AuroraCliVerb.connect;
  AuroraMode? mode;
  String? line;
  String? contractPath;
  var refresh = true;
  var jsonOutput = false;
  var timeout = const Duration(seconds: 30);

  final rest = <String>[...args];
  if (rest.isNotEmpty && !rest.first.startsWith('-')) {
    final named = _verbs[rest.first];
    if (named == null) {
      return AuroraCliOptions(
        verb: AuroraCliVerb.help,
        error: 'Unknown command "${rest.first}".',
      );
    }
    verb = named;
    rest.removeAt(0);
  }

  // `import` and `remove` take positional arguments, and an aurora:// link can hold
  // characters that look like option syntax, so they skip flag parsing entirely.
  if (verb == AuroraCliVerb.import || verb == AuroraCliVerb.remove) {
    if (rest.isEmpty) {
      return AuroraCliOptions(
        verb: verb,
        error: verb == AuroraCliVerb.import
            ? 'import needs a link: aurora import \'aurora://v1/...\''
            : 'remove needs a server name (see: aurora servers).',
      );
    }
    return AuroraCliOptions(verb: verb, arguments: rest);
  }

  String? take(String flag, Iterator<String> it, String? inline) {
    if (inline != null) return inline;
    if (!it.moveNext()) return null;
    return it.current;
  }

  final it = rest.iterator;
  while (it.moveNext()) {
    final raw = it.current;
    final equals = raw.indexOf('=');
    final flag = equals < 0 ? raw : raw.substring(0, equals);
    final inline = equals < 0 ? null : raw.substring(equals + 1);

    switch (flag) {
      case '-h':
      case '--help':
        verb = AuroraCliVerb.help;
      case '--json':
        jsonOutput = true;
      case '--no-refresh':
        refresh = false;
      case '--mode':
        final value = take(flag, it, inline);
        if (value == null) {
          return AuroraCliOptions(verb: verb, error: '$flag needs a value.');
        }
        mode = switch (value) {
          'global' => AuroraMode.global,
          'smart' => AuroraMode.smart,
          _ => null,
        };
        if (mode == null) {
          return AuroraCliOptions(
            verb: verb,
            error: '$flag must be global or smart, got "$value".',
          );
        }
      case '--line':
        final value = take(flag, it, inline);
        if (value == null || value.isEmpty) {
          return AuroraCliOptions(verb: verb, error: '$flag needs a value.');
        }
        line = value;
      case '--contract':
        final value = take(flag, it, inline);
        if (value == null || value.isEmpty) {
          return AuroraCliOptions(verb: verb, error: '$flag needs a value.');
        }
        contractPath = value;
      case '--timeout':
        final value = take(flag, it, inline);
        final seconds = int.tryParse(value ?? '');
        if (seconds == null || seconds <= 0) {
          return AuroraCliOptions(
            verb: verb,
            error: '$flag needs a positive number of seconds, got "${value ?? ''}".',
          );
        }
        timeout = Duration(seconds: seconds);
      default:
        return AuroraCliOptions(verb: verb, error: 'Unknown option "$raw".');
    }
  }

  return AuroraCliOptions(
    verb: verb,
    mode: mode,
    line: line,
    contractPath: contractPath,
    refresh: refresh,
    json: jsonOutput,
    timeout: timeout,
  );
}
