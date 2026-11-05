import 'dart:convert';
import 'dart:io';

import 'package:aurora/app/path_health_activation_gate.dart';
import 'package:aurora/core/aurora_bridge.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/path_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final contract = AuroraContract.fromJson(
    json.decode(
          File(
            'test/fixtures/contract.dual-path.sample.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>,
  );

  test(
    'connection outcome cannot start path health before NE is connected',
    () {
      final gate = PathHealthActivationGate();

      gate.register(contract, PathPreference.auto);

      expect(gate.takeReady(), isNull);
      gate.statusChanged(AuroraStatus.connecting);
      expect(gate.takeReady(), isNull);
      gate.statusChanged(AuroraStatus.connected);
      final ready = gate.takeReady();
      expect(ready?.contract, same(contract));
      expect(ready?.preference, PathPreference.auto);
      expect(gate.takeReady(), isNull);
    },
  );

  test(
    'connected-before-outcome race activates once outcome is registered',
    () {
      final gate = PathHealthActivationGate();

      gate.statusChanged(AuroraStatus.connected);
      expect(gate.takeReady(), isNull);
      gate.register(contract, PathPreference.homeDirect);

      expect(gate.takeReady()?.preference, PathPreference.homeDirect);
      expect(gate.takeReady(), isNull);
    },
  );

  test('disconnect discards the pending connection session', () {
    final gate = PathHealthActivationGate();
    gate.register(contract, PathPreference.auto);
    gate.statusChanged(AuroraStatus.disconnected);
    gate.statusChanged(AuroraStatus.connected);

    expect(gate.takeReady(), isNull);
  });
}
