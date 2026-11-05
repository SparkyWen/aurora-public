import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted storage for the active contract + delivery URL. Backed by Android
/// EncryptedSharedPreferences / Keystore (never plain prefs, never git).
class SecureStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static const _migration = MethodChannel('aurora/secure-store');
  static Future<void>? _ready;

  // The plugin includes accessibility in its lookup. Migrating before every
  // kind of operation prevents a legacy item being mistaken for a missing one.
  static Future<void> _prepare() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
    var ready = _ready;
    if (ready == null) {
      ready = _migration.invokeMethod<bool>('prepareBackgroundAccess').then((
        ok,
      ) {
        if (ok != true) {
          throw PlatformException(code: 'keychain_migration_incomplete');
        }
      });
      _ready = ready;
      final pending = ready;
      // A caller may time out while securityd is still working. Only the
      // actual native failure permits another migration; no parallel retries.
      unawaited(
        pending.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            if (identical(_ready, pending)) _ready = null;
          },
        ),
      );
    }
    await ready.timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          throw PlatformException(code: 'keychain_migration_timeout'),
    );
  }

  static Future<String?> _read(String key) async {
    await _prepare();
    return _storage.read(key: key);
  }

  static Future<void> _write(String key, String value) async {
    await _prepare();
    await _storage.write(key: key, value: value);
  }

  static Future<void> _delete(String key) async {
    await _prepare();
    await _storage.delete(key: key);
  }

  static const _kContract = 'aurora_contract_json';
  static const _kDeliveryUrl = 'aurora_delivery_url';
  static const _kMode = 'aurora_mode';
  static const _kPathPreference = 'aurora_path_preference';
  static const _kEgressLease = 'aurora_egress_lease_json';
  static const _kRouteFamily = 'aurora_route_family';
  static const _kEgressInterface = 'aurora_egress_interface';

  static Future<void> saveContract(String contractJson) =>
      _write(_kContract, contractJson);

  static Future<String?> loadContract() => _read(_kContract);

  static Future<void> clearContract() => _delete(_kContract);

  static Future<void> saveDeliveryUrl(String url) => _write(_kDeliveryUrl, url);

  static Future<String?> loadDeliveryUrl() => _read(_kDeliveryUrl);

  static Future<void> saveMode(String mode) => _write(_kMode, mode);

  static Future<String?> loadMode() => _read(_kMode);

  static Future<void> savePathPreference(String preference) =>
      _write(_kPathPreference, preference);

  static Future<String?> loadPathPreference() => _read(_kPathPreference);

  static Future<void> saveEgressLease(String leaseJson) =>
      _write(_kEgressLease, leaseJson);

  static Future<String?> loadEgressLease() => _read(_kEgressLease);

  static Future<void> clearEgressLease() => _delete(_kEgressLease);

  static Future<void> saveRouteFamily(String family) =>
      _write(_kRouteFamily, family);

  static Future<String?> loadRouteFamily() => _read(_kRouteFamily);

  // "Switch back to auto" needs to be able to delete the stored choice rather than
  // write an 'auto' placeholder: resolveRouteFamily treats null and 'auto' alike,
  // but without a key to clear, the UI could not express the act of "returning to
  // auto" itself (symmetric with clearEgressLease).
  static Future<void> clearRouteFamily() => _delete(_kRouteFamily);

  /// The egress NIC name pinned on desktop (`route.default_interface`).
  ///
  /// Empty means "follow the system default route", i.e. the `auto_detect_interface`
  /// path. What is stored is the interface name reported by aurora-svc `/diagnose`,
  /// because that list uses the same names as sing-box's own interface monitor; see
  /// the `_route` comment in config_compiler.dart.
  static Future<void> saveEgressInterface(String name) =>
      _write(_kEgressInterface, name);

  static Future<String?> loadEgressInterface() => _read(_kEgressInterface);

  static Future<void> clearEgressInterface() => _delete(_kEgressInterface);
}
