/// How the command line gets the contract. Pure Dart (see the note in `cli_app.dart`).
///
/// The GUI goes through `ContractRepository`: `flutter_secure_storage` for the LKG,
/// `rootBundle` for the embedded asset, `package_info_plus` for the version. All three need the Flutter engine,
/// and the command line can use none of them — in an SSH session the libsecret keyring is usually still locked. So this
/// is another implementation of the same **discipline**:
///
///   explicit file → control plane refresh (signature check + rollback guard) → per-user cache → embedded in the package (optional, private builds only)
///
/// And like the GUI, a refreshed contract is promoted to LKG only **after it connects** ([CliContractLoad.promote]):
/// a contract that verifies but cannot connect must not overwrite the one known to work.
library;

import 'dart:convert';
import 'dart:io';

import '../core/contract.dart';
import '../core/contract_editor.dart';
import '../core/server_bundle.dart';
import '../data/contract_verifier.dart';
import '../data/delivery.dart';
import 'cli_app.dart' show CliContractLoad;

typedef CliContractFetch = Future<String?> Function(DeliveryInfo delivery);
typedef CliContractVerify =
    Future<void> Function(
      String contractJson,
      String clientVersion,
      DeliveryInfo delivery,
    );

class CliContractSource {
  static const _embeddedSource = 'embedded in the install package';

  CliContractSource({
    required this.installDir,
    required this.stateDir,
    this.clientVersion = '0.0.0',
    this.fetch,
    CliContractVerify? verify,
  }) : verify =
           verify ??
           ((contractJson, clientVersion, delivery) =>
               ContractVerifier.verifyRemote(
                 contractJson,
                 clientVersion: clientVersion,
                 publicKey: delivery.signingPublicKey!,
                 keyId: delivery.signingKeyId,
               ));

  /// Directory of the executable. The embedded contract is at `<installDir>/data/flutter_assets/...`
  /// — Flutter's Linux output layout, with `aurora-cli` and `aurora` side by side in it.
  final Directory installDir;

  /// Per-user state directory (`$XDG_STATE_HOME/aurora` or `~/.local/state/aurora`).
  ///
  /// Note this is a **user** directory, unrelated to aurora-svc's root-owned `/var/lib/aurora`:
  /// the command line never hands a path it computed to the privileged service (the config is sent as bytes),
  /// so it does not touch the privilege-boundary hard constraint in CONTRIBUTING.md.
  final Directory stateDir;

  /// Client version reported for contract signature verification (used by `min_client_version`). See
  /// `readAuroraVersion` in `cli_install.dart`.
  final String clientVersion;

  final CliContractFetch? fetch;
  final CliContractVerify verify;

  File get _cacheFile => File('${stateDir.path}/contract.json');

  File get _embeddedFile => File(
    '${installDir.path}/data/flutter_assets/assets/configs/aurora-contract.json',
  );

  Future<CliContractLoad> load({
    String? explicitPath,
    bool refresh = true,
  }) async {
    if (explicitPath != null) {
      final file = File(explicitPath);
      if (!file.existsSync()) {
        throw Exception('Contract file not found: $explicitPath');
      }
      return CliContractLoad(
        _parse(file.readAsStringSync()),
        'file $explicitPath',
      );
    }

    final local = _bestLocal();
    if (local == null) {
      throw Exception(
        'No server has been added yet. Run: aurora import \'<link from install.sh>\'',
      );
    }
    if (!refresh) return local;

    final fresh = await _refresh(local.contract);
    return fresh ?? local;
  }

  /// Adds [text] (`aurora://` links, share links, or a contract document) to the
  /// local contract and returns the names of the servers added.
  ///
  /// This is an explicit, user-typed command, so it is a trust root in the same way
  /// as the GUI's paste box. Control-plane links need the GUI's verified download
  /// path and network access, which a server-side CLI rarely wants at import time;
  /// they are refused here with instructions rather than half-handled.
  List<String> importText(String text) {
    final current = _bestLocal();
    final plan = ContractEditor.plan(
      current == null ? null : _readRaw(current),
      text,
    );
    if (plan.delivery != null) {
      throw const AuroraLinkException(
        'Control-plane links are added in the app. On a headless machine, publish '
        'a contract file and pass it with --contract.',
      );
    }
    final contractJson = plan.contractJson!;
    _parse(contractJson);
    _writeCache(contractJson);
    return plan.added;
  }

  /// Servers in the local contract.
  List<ContractServer> listServers() {
    final current = _bestLocal();
    if (current == null) return const [];
    return ContractEditor.listServers(
      Map<String, dynamic>.from(json.decode(_readRaw(current)!) as Map),
    );
  }

  /// Returns false when no such server exists.
  bool removeServer(String group) {
    final current = _bestLocal();
    if (current == null) return false;
    final raw = Map<String, dynamic>.from(
      json.decode(_readRaw(current)!) as Map,
    );
    final known = ContractEditor.listServers(raw).any((s) => s.group == group);
    if (!known) return false;
    final updated = ContractEditor.removeServer(raw, group);
    if (updated == null) {
      if (_cacheFile.existsSync()) _cacheFile.deleteSync();
    } else {
      _writeCache(json.encode(updated));
    }
    return true;
  }

  void _writeCache(String contractJson) {
    stateDir.createSync(recursive: true);
    _cacheFile.writeAsStringSync(contractJson, flush: true);
    // The contract holds node credentials; the state dir may be group-readable.
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['600', _cacheFile.path]);
    }
  }

  String? _readRaw(CliContractLoad load) {
    final file = load.source == _embeddedSource ? _embeddedFile : _cacheFile;
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// The newer of the cache and the embedded one.
  ///
  /// The embedded one may be newer: a newly installed package carries rotated nodes. The cache may be newer too:
  /// the control plane delivered it. Whichever is newer wins, with the same criterion as the GUI's `ContractRepository`
  /// (revision first, then the `updated` timestamp).
  CliContractLoad? _bestLocal() {
    final cached = _tryRead(_cacheFile);
    final embedded = _tryRead(_embeddedFile);
    if (cached == null && embedded == null) return null;
    if (cached == null) {
      return CliContractLoad(embedded!, _embeddedSource);
    }
    if (embedded == null) {
      return CliContractLoad(cached, 'local cache');
    }
    return _isUpgrade(cached, embedded)
        ? CliContractLoad(embedded, _embeddedSource)
        : CliContractLoad(cached, 'local cache');
  }

  Future<CliContractLoad?> _refresh(AuroraContract current) async {
    // No pinned key means nothing to verify a download against, so do not fetch.
    if (fetch == null && !current.delivery.canVerifyRemote) return null;
    final String? body;
    try {
      body =
          await (fetch?.call(current.delivery) ??
              DeliveryService.fetchFreshContract(
                current.delivery,
                acceptCandidate: (body) async {
                  await verify(body, clientVersion, current.delivery);
                  return _isUpgrade(current, _parse(body));
                },
              ));
    } catch (_) {
      // Offline, blocked, DNS poisoned — a failed refresh must never stop a connection; the local contract exists
      // for exactly this.
      return null;
    }
    if (body == null || body.isEmpty) return null;
    try {
      await verify(body, clientVersion, current.delivery);
      final candidate = _parse(body);
      if (!_isUpgrade(current, candidate)) return null;
      return CliContractLoad(
        candidate,
        'control plane (revision ${candidate.revision})',
        promote: () async => _writeCache(body!),
      );
    } catch (_) {
      // Signature check failed / unparseable: treat as not refreshed. A remote contract is the only untrusted source.
      return null;
    }
  }

  /// Whether [candidate] is newer than [current]. Rollback guard: revision can only go up.
  static bool _isUpgrade(AuroraContract current, AuroraContract candidate) {
    if (candidate.revision > 0 && current.revision > 0) {
      return candidate.revision > current.revision;
    }
    final a = DateTime.tryParse(current.updated ?? '');
    final b = DateTime.tryParse(candidate.updated ?? '');
    if (candidate.revision > 0 && current.revision <= 0) {
      // Same migration gate as the GUI: the first signed revision cannot
      // replace a dated legacy LKG with older node credentials.
      return a == null || b == null || b.isAfter(a);
    }
    if (a == null || b == null) return false;
    return b.isAfter(a);
  }

  static AuroraContract? _tryRead(File file) {
    try {
      if (!file.existsSync()) return null;
      return _parse(file.readAsStringSync());
    } catch (_) {
      // A corrupt cache must not make the command line unusable altogether — ignore it, the other copy is still there.
      return null;
    }
  }

  static AuroraContract _parse(String body) =>
      AuroraContract.fromJson(json.decode(body) as Map<String, dynamic>);
}
