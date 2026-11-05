import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../core/bounded_http.dart';
import '../core/contract.dart';
import '../core/contract_editor.dart';
import '../core/server_bundle.dart';
import 'contract_verifier.dart';
import 'delivery.dart';
import 'secure_store.dart';

/// Thrown when no server has been added yet: the app's normal first-run state.
class NoContractException implements Exception {
  const NoContractException();
  @override
  String toString() => 'Add a server first.';
}

/// Source of the active [AuroraContract]. Priority:
/// 1. secure storage (added servers or a fetched contract)
/// 2. an optional embedded asset, for people who build a private app with their
///    own contract baked in (it seeds storage on first run)
///
/// Public builds embed nothing, so a fresh install has no contract and
/// [load] throws [NoContractException] until the user adds a server.
class ContractRepository {
  static const _embeddedAsset = 'assets/configs/aurora-contract.json';
  static String? _pendingContract;

  /// Bumped whenever servers change, so screens showing the contract can reload.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static Future<String?> _loadEmbedded() async {
    try {
      return await rootBundle.loadString(_embeddedAsset);
    } catch (_) {
      return null;
    }
  }

  static Future<AuroraContract> load() async {
    final embeddedStr = await _loadEmbedded();
    final stored = await SecureStore.loadContract();
    if (stored == null && embeddedStr == null) {
      throw const NoContractException();
    }

    // Pick the active contract:
    //  - no stored yet              -> seed from the embedded asset
    //  - embedded is NEWER than     -> adopt embedded (an app update shipped a new
    //    stored (by `updated`)         node; overrides the stale stored one)
    //  - otherwise                  -> keep stored
    String activeStr;
    if (stored == null ||
        (embeddedStr != null && _embeddedIsNewer(embeddedStr, stored))) {
      activeStr = embeddedStr!;
      await SecureStore.saveContract(embeddedStr);
    } else {
      activeStr = stored;
    }
    AuroraContract contract;
    try {
      contract = _parse(activeStr);
    } catch (_) {
      // A stored contract from a previous schema can fail to parse after an app
      // upgrade tightens validation. Without this every connect path throws and the
      // app is bricked until the user finds the reset action.
      if (identical(activeStr, embeddedStr) || embeddedStr == null) {
        await SecureStore.clearContract();
        throw const NoContractException();
      }
      contract = _parse(embeddedStr);
      activeStr = embeddedStr;
      await SecureStore.saveContract(embeddedStr);
    }

    // Remember a delivery URL so refresh() can reach the control plane even before
    // the user ever imported one.
    final url = await SecureStore.loadDeliveryUrl();
    final primary = contract.delivery.primary;
    if ((url == null || url.isEmpty) && primary != null && primary.isNotEmpty) {
      await SecureStore.saveDeliveryUrl(primary);
    }
    return contract;
  }

  /// The raw stored document, for listing and editing servers.
  static Future<Map<String, dynamic>?> _loadRaw() async {
    try {
      await load();
    } on NoContractException {
      return null;
    }
    final stored = await SecureStore.loadContract();
    return stored == null
        ? null
        : Map<String, dynamic>.from(json.decode(stored) as Map);
  }

  static Future<List<ContractServer>> listServers() async {
    final raw = await _loadRaw();
    return raw == null ? const [] : ContractEditor.listServers(raw);
  }

  /// Adds whatever [text] holds: `aurora://` links, plain share links, or a whole
  /// contract document. Returns the names of the servers added.
  static Future<List<String>> importText(String text) async {
    final raw = await _loadRaw();
    final plan = ContractEditor.plan(
      raw == null ? null : json.encode(raw),
      text,
    );
    final delivery = plan.delivery;
    if (delivery != null) {
      await _importDelivery(delivery);
      _notifyChanged();
      return [delivery.host];
    }
    final contractJson = plan.contractJson!;
    _parse(contractJson); // Never store what the compiler could not read.
    await SecureStore.saveContract(contractJson);
    _notifyChanged();
    return plan.added;
  }

  static Future<void> removeServer(String group) async {
    final raw = await _loadRaw();
    if (raw == null) return;
    final updated = ContractEditor.removeServer(raw, group);
    if (updated == null) {
      await SecureStore.clearContract();
    } else {
      await SecureStore.saveContract(json.encode(updated));
    }
    _notifyChanged();
  }

  static void _notifyChanged() => changes.value++;

  /// Fetches the first contract from a control plane. Pasting the link is the trust
  /// decision, so the key it names is what the download is checked against.
  static Future<void> _importDelivery(DeliveryLink link) async {
    final body = await _download(
      Uri.parse(link.url).replace(queryParameters: {'token': link.token}),
    );
    final AuroraContract contract;
    try {
      contract = _parse(body);
    } catch (_) {
      throw const AuroraLinkException('The server returned an invalid contract.');
    }
    final package = await PackageInfo.fromPlatform();
    await ContractVerifier.verifyRemote(
      body,
      clientVersion: package.version,
      publicKey: link.publicKey,
      keyId: link.keyId,
    );
    // Without this the contract would not carry the pin forward, and every later
    // refresh would have nothing to verify against.
    if (contract.delivery.signingPublicKey != link.publicKey) {
      throw const AuroraLinkException(
        'The contract does not pin the key named in the link.',
      );
    }
    await SecureStore.saveContract(body);
    await SecureStore.saveDeliveryUrl(link.url);
  }

  static Future<String> _download(Uri uri) async {
    final client = http.Client();
    final http.Response response;
    try {
      response = await boundedRequest(
        client,
        http.Request('GET', uri)..followRedirects = false,
        const Duration(seconds: 15),
      );
    } on TimeoutException {
      throw TimeoutException('The delivery request timed out.');
    } catch (_) {
      // ClientException/FormatException can include the complete token URL.
      throw 'The delivery request failed. Check the URL and your network.';
    } finally {
      client.close();
    }
    if (response.statusCode != 200) {
      throw 'HTTP ${response.statusCode} from the delivery URL.';
    }
    return response.body;
  }

  /// True if [embeddedStr]'s `updated` timestamp is strictly newer than
  /// [storedStr]'s. Conservative on parse failure (returns false → keep stored),
  /// except when stored has no/!parseable timestamp and embedded does.
  static bool _embeddedIsNewer(String embeddedStr, String storedStr) {
    try {
      final e = DateTime.tryParse(_parse(embeddedStr).updated ?? '');
      final s = DateTime.tryParse(_parse(storedStr).updated ?? '');
      if (e == null) return false;
      if (s == null) return true;
      return e.isAfter(s);
    } catch (_) {
      return false;
    }
  }

  /// Connect-time load: best-effort pull a fresh contract from the control
  /// plane first (reachable without the tunnel), then fall back to the stored /
  /// embedded last-known-good. Always returns a usable contract; never blocks
  /// connect for long (bounded timeout) and never throws on network failure.
  static Future<AuroraContract> loadWithRefresh() async {
    final current = await load();
    _pendingContract = null;
    // No pinned key means nothing to verify a download against, so do not fetch.
    final publicKey = current.delivery.signingPublicKey;
    if (publicKey == null || publicKey.isEmpty) return current;
    try {
      final package = await PackageInfo.fromPlatform();
      final fresh = await DeliveryService.fetchFreshContract(
        current.delivery,
        acceptCandidate: (body) async {
          await ContractVerifier.verifyRemote(
            body,
            clientVersion: package.version,
            publicKey: publicKey,
            keyId: current.delivery.signingKeyId,
          );
          return isUpgrade(current, _parse(body));
        },
      );
      if (fresh == null) return current;
      final parsed = _parse(fresh);
      // Do not overwrite the active LKG yet. ConnectPage promotes this exact
      // signed candidate only after libbox reports a successful connection.
      _pendingContract = fresh;
      return parsed;
    } catch (_) {
      return current;
    }
  }

  /// Promote the signed candidate returned by [loadWithRefresh] after libbox
  /// reaches `connected`. A failed start/disconnect leaves the previous LKG.
  static Future<void> promotePending() async {
    final pending = _pendingContract;
    if (pending == null) return;
    final parsed = _parse(pending);
    await SecureStore.saveContract(pending);
    final primary = parsed.delivery.primary;
    if (primary != null && primary.isNotEmpty) {
      await SecureStore.saveDeliveryUrl(primary);
    }
    _pendingContract = null;
  }

  static void discardPending() => _pendingContract = null;

  static bool isUpgrade(AuroraContract current, AuroraContract candidate) {
    if (candidate.revision <= 0) return false;
    if (current.revision > 0) return candidate.revision > current.revision;
    final currentUpdated = DateTime.tryParse(current.updated ?? '');
    final candidateUpdated = DateTime.tryParse(candidate.updated ?? '');
    if (currentUpdated == null || candidateUpdated == null) return true;
    return candidateUpdated.isAfter(currentUpdated);
  }

  /// Re-fetches from the control plane (the "refresh contract" action).
  static Future<AuroraContract> refresh() async {
    final current = await load();
    final publicKey = current.delivery.signingPublicKey;
    final url = await SecureStore.loadDeliveryUrl();
    if (publicKey == null || publicKey.isEmpty || url == null || url.isEmpty) {
      throw 'This setup has no control plane to refresh from.';
    }
    final body = await _download(
      DeliveryService.authenticatedUri(url, current.delivery),
    );
    final AuroraContract contract;
    try {
      contract = _parse(body);
    } catch (_) {
      // JSON/schema errors can quote the response, including node credentials.
      throw const FormatException('The delivered contract is invalid.');
    }
    final package = await PackageInfo.fromPlatform();
    await ContractVerifier.verifyRemote(
      body,
      clientVersion: package.version,
      publicKey: publicKey,
      keyId: current.delivery.signingKeyId,
    );
    if (!isUpgrade(current, contract)) {
      throw 'Refused an old or duplicate contract (revision ${contract.revision}).';
    }
    await SecureStore.saveContract(body);
    _notifyChanged();
    return contract;
  }

  /// Forgets every server. A private build falls back to its embedded contract;
  /// a public build returns to the first-run screen.
  static Future<void> reset() async {
    await SecureStore.clearContract();
    _notifyChanged();
  }

  static AuroraContract _parse(String s) =>
      AuroraContract.fromJson(json.decode(s) as Map<String, dynamic>);
}
