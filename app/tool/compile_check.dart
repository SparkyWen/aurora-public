// Dev tool: compile a real aurora-contract.json into sing-box JSON for
// `sing-box check`. Usage:
//   dart run tool/compile_check.dart <contract.json> <global|smart> <out.json>
import 'dart:convert';
import 'dart:io';

import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/core/contract.dart';

void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln(
      'usage: compile_check <contract.json> <global|smart> <out.json> '
      '[android|ios|desktop|windows|linux] [clashSecret] [defaultInterface]',
    );
    exit(2);
  }
  final contract = AuroraContract.fromJson(
    json.decode(File(args[0]).readAsStringSync()) as Map<String, dynamic>,
  );
  final mode = args[1] == 'smart' ? AuroraMode.smart : AuroraMode.global;
  final platform = switch (args.length >= 4 ? args[3] : 'android') {
    'ios' => AuroraPlatform.ios,
    'desktop' => AuroraPlatform.desktop,
    'windows' => AuroraPlatform.windows,
    'linux' => AuroraPlatform.linux,
    _ => AuroraPlatform.android,
  };
  final secret = platform.usesClashApi
      ? (args.length >= 5 ? args[4] : 'compile-check-secret')
      : null;
  final ruleSetPaths = mode == AuroraMode.smart
      ? {
          'geosite-cn': File('assets/rule_sets/geosite-cn.srs').absolute.path,
          'geoip-cn': File('assets/rule_sets/geoip-cn.srs').absolute.path,
          'geosite-geolocation-!cn': File(
            'assets/rule_sets/geosite-geolocation-!cn.srs',
          ).absolute.path,
        }
      : const <String, String>{};
  // 6th argument: the pinned exit adapter (route.default_interface). It exists because this
  // branch must be actually verified by `sing-box check` — it is mutually exclusive with auto_detect_interface,
  // and a mistake is invisible to unit tests; only the core would reject it.
  final defaultInterface = args.length >= 6 ? args[5] : null;
  final cfg = ConfigCompiler.compile(
    contract,
    mode: mode,
    platform: platform,
    ruleSetPaths: ruleSetPaths,
    clashApiSecret: secret,
    defaultInterface: defaultInterface,
  );
  File(
    args[2],
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg));
  stdout.writeln('wrote ${args[2]} (${mode.name})');
}
