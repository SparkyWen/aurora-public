import 'dart:async';

import 'package:http/http.dart' as http;

import '../core/contract.dart';
import '../core/bounded_http.dart';
import '../core/egress_lease.dart';
import 'secure_store.dart';

class EgressLeaseRepository {
  EgressLeaseRepository({
    http.Client? client,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _now = now ?? DateTime.now;

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  final Duration timeout;
  final StreamController<EgressLease> _leases =
      StreamController<EgressLease>.broadcast();

  Stream<EgressLease> get leases => _leases.stream;

  Future<EgressLease> refresh(
    EgressPolicy policy,
    DeliveryInfo delivery,
  ) async {
    _requireEndpoint(policy);
    final current = await loadValid(policy);
    late http.Response response;
    try {
      response = await boundedRequest(
        _client,
        http.Request('GET', policy.leaseUrl!)
          ..followRedirects = false
          ..headers['x-aurora-token'] = delivery.token ?? '',
        timeout,
      );
    } on TimeoutException {
      if (current != null && current.isValidAt(_now())) return current;
      throw StateError('lease_refresh_failed');
    } on http.ClientException {
      if (current != null && current.isValidAt(_now())) return current;
      throw StateError('lease_refresh_failed');
    } catch (_) {
      if (current != null && current.isValidAt(_now())) return current;
      throw StateError('lease_refresh_failed');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      if (current != null && current.isValidAt(_now())) return current;
      throw StateError('lease_auth_failed');
    }
    if (response.statusCode != 200 || response.body.isEmpty) {
      if (current != null && current.isValidAt(_now())) return current;
      throw StateError('lease_refresh_failed');
    }
    EgressLease candidate;
    try {
      candidate = await EgressLeaseVerifier.verify(
        response.body,
        policy: policy,
        minimumSequence: current?.sequence ?? 0,
        now: _now(),
      );
    } catch (_) {
      if (current != null && current.isValidAt(_now())) return current;
      throw StateError('lease_refresh_failed');
    }
    if (current != null && candidate.sequence == current.sequence) {
      return _validAtReturn(current);
    }
    _validAtReturn(candidate);
    await SecureStore.saveEgressLease(response.body);
    _validAtReturn(candidate);
    _leases.add(candidate);
    return candidate;
  }

  Future<EgressLease?> loadValid(EgressPolicy policy, {DateTime? now}) async {
    if (!policy.hasSignedLease) return null;
    final raw = await SecureStore.loadEgressLease();
    if (raw == null || raw.isEmpty) return null;
    try {
      final lease = await EgressLeaseVerifier.verify(
        raw,
        policy: policy,
        minimumSequence: 0,
        now: now ?? _now(),
      );
      return lease.isValidAt(now ?? _now()) ? lease : null;
    } catch (_) {
      return null;
    }
  }

  EgressLease _validAtReturn(EgressLease lease) {
    if (!lease.isValidAt(_now())) throw StateError('lease_refresh_failed');
    return lease;
  }

  Future<void> close() async {
    await _leases.close();
    if (_ownsClient) _client.close();
  }

  static void _requireEndpoint(EgressPolicy policy) {
    final endpoint = policy.leaseUrl;
    if (!policy.hasSignedLease ||
        endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.path != '/v2/egress-lease' ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw StateError('lease_policy_invalid');
    }
  }
}
