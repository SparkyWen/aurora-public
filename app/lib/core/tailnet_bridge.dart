import 'dart:async';

import 'package:flutter/services.dart';

import 'tailnet_options.dart';

abstract interface class AuroraMobileTailnet {
  Future<bool> tailnetCapability();
  Future<Map<String, Object?>> readTailnetSettings();
  Future<Map<String, Object?>> setTailnetEnabled(
    int expectedGeneration,
    bool enabled,
  );
  Future<TailnetStartContext?> prepareTailnetStart(int expectedGeneration);
  Future<void> startWithTailnet(String config, TailnetStartContext context);
  Future<Map<String, Object?>> tailnetSnapshot();
  Future<String> openTailnetAuthentication(
    String sessionId,
    String nodeGeneration,
  );
  Future<String> forgetTailnetNode(String nodeGeneration);
}

final class TailnetStartContext {
  const TailnetStartContext({
    required this.settingsGeneration,
    required this.nodeGeneration,
    required this.options,
  });
  final int settingsGeneration;
  final String nodeGeneration;
  final TailnetOptions options;
}

final class TailnetBridgeFailure implements Exception {
  const TailnetBridgeFailure(this.code);
  final String code;
  @override
  String toString() => 'Tailnet operation failed ($code)';
}

final class MethodChannelAuroraMobileTailnet implements AuroraMobileTailnet {
  const MethodChannelAuroraMobileTailnet({
    this.channel = const MethodChannel('aurora/tailnet'),
    this.timeout = const Duration(seconds: 5),
  });
  final MethodChannel channel;
  final Duration timeout;

  // A timeout does not cancel the native operation. Never retry here: native
  // admission must still enforce the supplied generation and session owner.
  Future<Object?> _call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await channel
          .invokeMethod<Object?>(method, arguments)
          .timeout(timeout);
    } on MissingPluginException {
      throw const TailnetBridgeFailure('unsupported');
    } on TimeoutException {
      throw const TailnetBridgeFailure('timeout');
    } on PlatformException catch (error) {
      const safeCodes = {
        'unsupported',
        'busy',
        'stale',
        'storage',
        'invalid-state',
      };
      // Native messages/details may contain upstream authentication URLs.
      throw TailnetBridgeFailure(
        safeCodes.contains(error.code) ? error.code : 'native-failure',
      );
    }
  }

  static Never _invalid() =>
      throw const FormatException('Invalid Tailnet response');
  static bool _generation(Object? value) => value is int && value >= 0;
  static bool _uuid(Object? value) =>
      value is String &&
      value.length == 36 &&
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(value);
  static void _requireGeneration(int value) {
    if (!_generation(value)) throw ArgumentError('Invalid Tailnet generation');
  }

  static void _requireUuid(String value) {
    if (!_uuid(value)) throw ArgumentError('Invalid Tailnet identity');
  }

  static Map<String, Object?> _map(Object? value, Set<String> keys) {
    if (value is! Map ||
        value.length != keys.length ||
        value.keys.any((key) => key is! String || !keys.contains(key)) ||
        value['schema'] is! int ||
        value['schema'] != 1) {
      _invalid();
    }
    return Map<String, Object?>.unmodifiable(value);
  }

  static Map<String, Object?> _settings(Object? value) {
    final map = _map(value, {
      'schema',
      'settingsGeneration',
      'enabled',
      'nodeGeneration',
    });
    if (!_generation(map['settingsGeneration']) ||
        map['enabled'] is! bool ||
        (map['nodeGeneration'] != null && !_uuid(map['nodeGeneration']))) {
      _invalid();
    }
    return map;
  }

  static String _result(Object? value, Set<String> allowed) {
    if (value is! String || !allowed.contains(value)) _invalid();
    return value;
  }

  @override
  Future<bool> tailnetCapability() async {
    try {
      final value = await _call('capability');
      if (value is! bool) _invalid();
      return value;
    } on TailnetBridgeFailure catch (error) {
      if (error.code == 'unsupported') return false;
      rethrow;
    }
  }

  @override
  Future<Map<String, Object?>> readTailnetSettings() async =>
      _settings(await _call('readSettings'));
  @override
  Future<Map<String, Object?>> setTailnetEnabled(
    int expectedGeneration,
    bool enabled,
  ) async {
    _requireGeneration(expectedGeneration);
    final result = _settings(
      await _call('setEnabled', {
        'expectedGeneration': expectedGeneration,
        'enabled': enabled,
      }),
    );
    if ((result['settingsGeneration'] as int) < expectedGeneration ||
        result['enabled'] != enabled) {
      _invalid();
    }
    return result;
  }

  @override
  Future<TailnetStartContext?> prepareTailnetStart(
    int expectedGeneration,
  ) async {
    _requireGeneration(expectedGeneration);
    final value = await _call('prepareStart', {
      'expectedGeneration': expectedGeneration,
    });
    if (value == null) return null;
    final map = _map(value, {
      'schema',
      'settingsGeneration',
      'nodeGeneration',
      'stateDirectory',
      'hostname',
    });
    if (!_generation(map['settingsGeneration']) ||
        map['settingsGeneration'] != expectedGeneration ||
        !_uuid(map['nodeGeneration']) ||
        map['stateDirectory'] is! String ||
        map['hostname'] is! String) {
      _invalid();
    }
    try {
      return TailnetStartContext(
        settingsGeneration: expectedGeneration,
        nodeGeneration: map['nodeGeneration'] as String,
        options: TailnetOptions(
          stateDirectory: map['stateDirectory'] as String,
          hostname: map['hostname'] as String,
        ),
      );
    } on ArgumentError {
      _invalid();
    }
  }

  @override
  Future<void> startWithTailnet(
    String config,
    TailnetStartContext context,
  ) async {
    _requireGeneration(context.settingsGeneration);
    _requireUuid(context.nodeGeneration);
    if (config.isEmpty) throw ArgumentError('Empty Tailnet configuration');
    final result = await _call('start', {
      'config': config,
      'settingsGeneration': context.settingsGeneration,
      'nodeGeneration': context.nodeGeneration,
    });
    if (result != null) _invalid();
  }

  @override
  Future<Map<String, Object?>> tailnetSnapshot() async {
    final map = _map(await _call('snapshot'), {
      'schema',
      'sessionId',
      'nodeGeneration',
      'publicStatus',
      'tailnetStatus',
      'authAvailable',
    });
    const publicStates = {
      'disconnected',
      'connecting',
      'connected',
      'disconnecting',
      'error',
    };
    const tailnetStates = {
      'disabled',
      'stopped',
      'starting',
      'needsLogin',
      'unverified',
      'error',
    };
    if ((map['sessionId'] != null && !_uuid(map['sessionId'])) ||
        (map['nodeGeneration'] != null && !_uuid(map['nodeGeneration'])) ||
        !publicStates.contains(map['publicStatus']) ||
        !tailnetStates.contains(map['tailnetStatus']) ||
        map['authAvailable'] is! bool) {
      _invalid();
    }
    if (map['authAvailable'] == true &&
        (map['tailnetStatus'] != 'needsLogin' ||
            map['sessionId'] == null ||
            map['nodeGeneration'] == null)) {
      _invalid();
    }
    return map;
  }

  @override
  Future<String> openTailnetAuthentication(
    String sessionId,
    String nodeGeneration,
  ) async {
    _requireUuid(sessionId);
    _requireUuid(nodeGeneration);
    return _result(
      await _call('openAuthentication', {
        'sessionId': sessionId,
        'nodeGeneration': nodeGeneration,
      }),
      {'opened', 'unavailable', 'stale'},
    );
  }

  @override
  Future<String> forgetTailnetNode(String nodeGeneration) async {
    _requireUuid(nodeGeneration);
    return _result(await _call('forget', {'nodeGeneration': nodeGeneration}), {
      'forgotten',
      'busy',
      'stale',
    });
  }
}
