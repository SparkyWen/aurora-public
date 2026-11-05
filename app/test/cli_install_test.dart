import 'dart:io';

import 'package:aurora/cli/cli_install.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory installDir;

  setUp(() {
    installDir = Directory.systemTemp.createTempSync('aurora-cli-install');
  });

  tearDown(() => installDir.deleteSync(recursive: true));

  File assetFile(String relative) =>
      File('${installDir.path}/data/flutter_assets/$relative')
        ..createSync(recursive: true);

  group('version', () {
    test('reads version.json from the install - same source as the GUI', () {
      // Flutter writes this file into the bundle itself, and on Linux
      // package_info_plus reads it too. The CLI reads the same one, so the two
      // entry points never report different versions.
      assetFile('version.json').writeAsStringSync(
        '{"app_name":"aurora","version":"1.9.11","build_number":"34"}',
      );

      expect(readAuroraVersion(installDir), '1.9.11');
    });

    test('returns 0.0.0 when the file is missing instead of reporting a made-up version', () {
      // Reporting too low only makes the contract's min_client_version reject a
      // remote refresh (the local contract is used and still connects); reporting
      // too high could let a contract this version should not use be accepted.
      expect(readAuroraVersion(installDir), '0.0.0');
    });

    test('a corrupt file does not crash', () {
      assetFile('version.json').writeAsStringSync('not json');

      expect(readAuroraVersion(installDir), '0.0.0');
    });
  });

  group('rule sets', () {
    test('accepted only when all three .srs files are present', () {
      for (final name in const [
        'geosite-cn.srs',
        'geoip-cn.srs',
        'geosite-geolocation-!cn.srs',
      ]) {
        assetFile('assets/rule_sets/$name').writeAsStringSync('x');
      }

      final paths = auroraRuleSetPaths(installDir);

      expect(paths.keys, hasLength(3));
      expect(paths['geoip-cn'], endsWith('geoip-cn.srs'));
    });

    test('one missing file voids the set: refuse smart rather than compile a config that references a missing file', () {
      assetFile('assets/rule_sets/geoip-cn.srs').writeAsStringSync('x');

      expect(auroraRuleSetPaths(installDir), isEmpty);
    });
  });

  group('state directory', () {
    test('prefers XDG_STATE_HOME', () {
      expect(
        defaultCliStateDir(const {'XDG_STATE_HOME': '/x/state', 'HOME': '/h'}).path,
        '/x/state/aurora',
      );
    });

    test('otherwise falls back to ~/.local/state', () {
      expect(defaultCliStateDir(const {'HOME': '/h'}).path, '/h/.local/state/aurora');
    });

    test('is a per-user directory, unrelated to aurora-svc\'s /var/lib/aurora', () {
      // Hard constraint in CONTRIBUTING.md: no path that crosses the privilege
      // boundary may be derived by one side. The CLI's cache is read only by the CLI
      // and the config is handed to the service as bytes, so a per-user directory is
      // safe and correct.
      expect(defaultCliStateDir(const {'HOME': '/h'}).path, isNot(contains('/var/lib')));
    });
  });
}
