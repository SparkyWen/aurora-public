/// Entry point of `aurora-cli`.
///
/// Only wiring lives here. The logic is in `lib/cli/`, all pure Dart, so it compiles
/// into an executable that needs no display. To build:
///
/// ```
/// cd app
/// dart build cli -o build/cli        # -> build/cli/bundle/bin/aurora_cli
/// ```
///
/// `dart build cli` rather than `dart compile exe`: this package's dependency graph
/// holds a package with a build hook (`objective_c`, pulled in by
/// `path_provider_foundation`), which `dart compile` refuses. The hook does nothing on
/// non-Apple platforms, so the Linux bundle holds only this executable.
///
/// Installs to `/opt/aurora/aurora-cli` next to the Flutter bundle. Version, optional
/// embedded contract and rule sets are all found relative to the executable (see
/// `cli_install.dart`).
library;

import 'dart:io';

import 'package:aurora/cli/cli_app.dart';
import 'package:aurora/cli/cli_contract_source.dart';
import 'package:aurora/cli/cli_install.dart';
import 'package:aurora/cli/cli_options.dart';
import 'package:aurora/core/aurora_bridge_svc.dart';

Future<void> main(List<String> args) async {
  final options = parseAuroraCliArgs(args);
  final installDir = auroraInstallDir();
  final version = readAuroraVersion(installDir);
  final source = CliContractSource(
    installDir: installDir,
    stateDir: defaultCliStateDir(),
    clientVersion: version,
  );

  final app = AuroraCliApp(
    bridge: AuroraBridgeSvc.forPlatform(),
    loadContract: () => source.load(
      explicitPath: options.contractPath,
      refresh: options.refresh,
    ),
    out: stdout.writeln,
    contractSource: source,
    ruleSetPaths: auroraRuleSetPaths(installDir),
    version: version,
  );

  final code = await app.run(options);
  // The bridge may still hold a polling timer (AuroraBridgeSvc._startPolling). Without
  // an explicit exit the process would hang on the event loop.
  exit(code);
}
