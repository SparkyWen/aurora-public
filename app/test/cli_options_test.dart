import 'package:aurora/cli/cli_options.dart';
import 'package:aurora/core/config_compiler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no arguments means connect', () {
    final options = parseAuroraCliArgs(const []);

    expect(options.verb, AuroraCliVerb.connect);
    expect(options.error, isNull);
    // All left null = use the defaults. The defaults themselves are decided by the
    // shared ConnectFlow/route_family logic; the parser does not repeat them.
    expect(options.mode, isNull);
    expect(options.line, isNull);
  });

  test('verbs can be written explicitly', () {
    expect(parseAuroraCliArgs(const ['connect']).verb, AuroraCliVerb.connect);
    expect(
      parseAuroraCliArgs(const ['disconnect']).verb,
      AuroraCliVerb.disconnect,
    );
    expect(parseAuroraCliArgs(const ['status']).verb, AuroraCliVerb.status);
    expect(parseAuroraCliArgs(const ['version']).verb, AuroraCliVerb.version);
    expect(parseAuroraCliArgs(const ['help']).verb, AuroraCliVerb.help);
    expect(parseAuroraCliArgs(const ['--help']).verb, AuroraCliVerb.help);
    expect(parseAuroraCliArgs(const ['-h']).verb, AuroraCliVerb.help);
  });

  test('mode and route can override the defaults', () {
    final options = parseAuroraCliArgs(const [
      'connect',
      '--mode',
      'smart',
      '--line',
      'direct',
    ]);

    expect(options.mode, AuroraMode.smart);
    expect(options.line, 'direct');
  });

  test('--line=auto means automatic route selection, not "unspecified"', () {
    // "Unspecified" is null (use the default route); an explicit auto must be
    // preserved, otherwise the CLI cannot express "I want automatic" at all.
    expect(parseAuroraCliArgs(const ['--line=auto']).line, 'auto');
    expect(parseAuroraCliArgs(const []).line, isNull);
  });

  test('both spellings of long options are accepted', () {
    expect(parseAuroraCliArgs(const ['--mode=global']).mode, AuroraMode.global);
    expect(
      parseAuroraCliArgs(const ['--contract=/tmp/c.json']).contractPath,
      '/tmp/c.json',
    );
  });

  test('--no-refresh turns off control-plane refresh', () {
    expect(parseAuroraCliArgs(const []).refresh, isTrue);
    expect(parseAuroraCliArgs(const ['--no-refresh']).refresh, isFalse);
  });

  test('status --json selects machine-readable output', () {
    expect(parseAuroraCliArgs(const ['status', '--json']).json, isTrue);
  });

  test('unrecognised verbs, options and values are reported, never silently run with defaults', () {
    // Silently running with defaults means the user thinks they chose one route and
    // actually connects through another.
    expect(parseAuroraCliArgs(const ['conect']).error, contains('conect'));
    expect(parseAuroraCliArgs(const ['--wat']).error, contains('--wat'));
    expect(parseAuroraCliArgs(const ['--mode', 'bogus']).error, contains('bogus'));
    expect(parseAuroraCliArgs(const ['--mode']).error, isNotNull);
  });
}
