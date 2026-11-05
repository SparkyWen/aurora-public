import 'dart:convert';

import 'package:aurora/core/aurora_bridge_svc.dart';
import 'package:aurora/core/aurora_svc_client.dart';
import 'package:aurora/core/path_health.dart';
import 'package:aurora/data/connection_probe.dart';
import 'package:aurora/features/settings/diagnostics_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  DiagnosticReport tlsDiagnostic() => DiagnosticReport.build(
    expectedIpv4: '203.0.113.9',
    pathStatus: const {},
    egressVerified: false,
    dnsStatus: 'indeterminate',
    ipv6Status: 'blocked',
    mtu: 1400,
    udpBlockStatus: 'pending',
    githubAssetsStatus: 'fail',
    connectionProbe: const ConnectionProbeReport([
      ProbeResult(
        name: 'Google 204',
        category: ProbeCategory.tls,
        tlsFailure: TlsFailure.certificateValidation,
      ),
      ProbeResult(
        name: 'Cloudflare 204',
        category: ProbeCategory.tls,
        tlsFailure: TlsFailure.handshakeClosed,
      ),
      ProbeResult(
        name: 'GitHub assets',
        category: ProbeCategory.http,
        statusCode: 503,
      ),
      ProbeResult(
        name: 'https://private.example/198.51.100.7?token=test-secret',
        category: ProbeCategory.tls,
        tlsFailure: TlsFailure.handshake,
      ),
    ]),
    egressProbe: const EgressProbeReport(
      egress: EgressStatus.unknown,
      category: ProbeCategory.tls,
      tlsFailure: TlsFailure.handshakeClosed,
      transportFailure: true,
    ),
  );

  test('diagnostic serialization retains safe per-target TLS evidence', () {
    final text = tlsDiagnostic().toSanitizedJson();
    final data = jsonDecode(text) as Map<String, dynamic>;
    expect(data['connection'], {
      'healthy': false,
      'category': 'tls',
      'probes': [
        {
          'target': 'google_204',
          'category': 'tls',
          'tls_failure': 'certificateValidation',
        },
        {
          'target': 'cloudflare_204',
          'category': 'tls',
          'tls_failure': 'handshakeClosed',
        },
        {'target': 'github_assets', 'category': 'http', 'status': 503},
        {'target': 'unknown', 'category': 'tls', 'tls_failure': 'handshake'},
      ],
    });
    expect((data['egress'] as Map)['category'], 'tls');
    expect((data['egress'] as Map)['tls_failure'], 'handshakeClosed');
    for (final sensitive in [
      'private.example',
      '198.51.100.7',
      'test-secret',
      'https://',
    ]) {
      expect(text, isNot(contains(sensitive)));
    }
  });

  test('throughput update preserves TLS evidence in the support export', () {
    final report = tlsDiagnostic().withThroughputStatus('12.5-mbps-manual');
    final text = report.toSanitizedJson();
    expect(jsonDecode(text)['throughput'], '12.5-mbps-manual');
    final bundle = buildSupportBundle(
      appVersion: 'test',
      platform: 'windows',
      svcState: 'running',
      lastFailureDetail: null,
      logTail: '',
      configSha256: '',
      diagnosticReport: report,
    );
    expect(bundle, contains('certificateValidation'));
    expect(bundle, contains('handshakeClosed'));
    expect(bundle, contains('github_assets'));
    expect(bundle, contains('12.5-mbps-manual'));
    for (final sensitive in [
      'private.example',
      '198.51.100.7',
      'test-secret',
      'https://',
    ]) {
      expect(bundle, isNot(contains(sensitive)));
    }
  });

  test('diagnostic report covers nine paths, lease and leak controls', () {
    final report = DiagnosticReport.build(
      expectedIpv4: '203.0.113.9',
      pathStatus: const {
        'home-via-relay-public-reality': 'pass',
        'home-via-relay-public-hy2': 'pass',
        'home-via-relay-public-ss': 'pass',
        'home-via-relay-tailnet-reality': 'pass',
        'home-via-relay-tailnet-hy2': 'pass',
        'home-via-relay-tailnet-ss': 'pass',
        'home-reality': 'pass',
        'home-hy2': 'pass',
        'home-ss': 'pass',
      },
      egressVerified: true,
      dnsStatus: 'pass',
      ipv6Status: 'blocked',
      mtu: 1400,
      udpBlockStatus: 'not-detected',
      githubAssetsStatus: 'pass',
      leaseStatus: 'valid',
      leaseKeyId: 'home-egress-1',
      leaseSequence: 123456,
      leaseExpiryStatus: 'valid-for-over-60m',
    );
    final text = report.toSanitizedJson();

    for (final path in DiagnosticReport.ninePaths) {
      expect(text, contains(path));
    }
    expect(text, contains('egress_hash'));
    expect(text, contains('dns'));
    expect(text, contains('ipv6'));
    expect(text, contains('mtu'));
    expect(text, contains('udp_block'));
    expect(text, contains('github_assets'));
    expect(text, contains('throughput'));
    expect(text, contains('home-egress-1'));
    expect(text, contains('3456'));
    expect(text, isNot(contains('123456')));
    expect(text, isNot(contains('203.0.113.9')));
  });

  test('itdog is manual-only and sanitizer removes sensitive material', () {
    final report = DiagnosticReport.build(
      expectedIpv4: '203.0.113.9',
      pathStatus: const {},
      egressVerified: false,
      dnsStatus: 'pending',
      ipv6Status: 'pending',
      mtu: 1400,
      udpBlockStatus: 'pending',
      githubAssetsStatus: 'pending',
    );
    final text = report.toSanitizedJson();
    expect(text, contains('itdog.cn'));
    expect(text, contains('manual_only'));
    expect(text, contains('"automated": false'));

    final sanitized = sanitizeDiagnosticValue({
      'password': 'secret-value',
      'uuid': '00000000-0000-0000-0000-000000000000',
      'message': 'peer 198.51.100.7 failed',
      'tailnet': '100.64.12.34',
      'signature': 'raw-signature',
    }).toString();
    expect(sanitized, isNot(contains('secret-value')));
    expect(sanitized, isNot(contains('00000000')));
    expect(sanitized, isNot(contains('198.51.100.7')));
    expect(sanitized, isNot(contains('100.64.12.34')));
    expect(sanitized, isNot(contains('raw-signature')));
  });

  group('supportBundle', () {
    test('carries everything needed to locate a problem, but never the config itself', () {
      final bundle = buildSupportBundle(
        appVersion: '1.0.10',
        platform: 'linux 6.9.0',
        svcState: 'error',
        lastFailureDetail: 'FATAL start service: bind: address already in use',
        logTail: 'FATAL start service: bind: address already in use',
        configSha256: 'a' * 64,
      );
      expect(bundle, contains('1.0.10'));
      expect(bundle, contains('address already in use'));
      expect(bundle, contains('a' * 64));
      // The config holds real credentials. A fingerprint is enough to confirm which
      // one was running; not one line of the original may get in.
      expect(bundle.contains('"uuid"'), isFalse);
      expect(bundle.contains('"password"'), isFalse);
    });

    test('builds a bundle without throwing when there is no failure reason', () {
      final bundle = buildSupportBundle(
        appVersion: '1.0.10',
        platform: 'linux 6.9.0',
        svcState: 'stopped',
        lastFailureDetail: null,
        logTail: '',
        configSha256: '',
      );
      expect(bundle, contains('stopped'));
    });

    // buildSupportBundle must not touch dart:io, including not reading Platform;
    // otherwise it could only ever produce the one report for whatever platform the
    // test host happens to be. The caller passes `platform`, and this test
    // deliberately passes one that differs from the host, proving the function does
    // not depend on Platform.operatingSystem.
    test('produces a report for a platform other than the host (proves it does not read Platform)', () {
      final bundle = buildSupportBundle(
        appVersion: '1.0.10',
        platform: 'windows 10.0.19045',
        svcState: 'running',
        lastFailureDetail: null,
        logTail: '',
        configSha256: '',
      );
      expect(bundle, contains('platform: windows 10.0.19045'));
    });

    // "Shows connected but there is no internet" cannot be seen from inside the app:
    // "connected" is judged only by the Clash API answering, which proves the core
    // is up and nothing more. The interface table the privileged side sees is what
    // can answer that question.
    test('includes the local network state as seen by the privileged service', () {
      final bundle = buildSupportBundle(
        appVersion: '1.0.14',
        platform: 'windows 10.0.22631',
        svcState: 'running',
        lastFailureDetail: null,
        logTail: '',
        configSha256: '',
        networkState:
            '{"tun_present": true, "interfaces": [{"name": "vEthernet (WSL)"}]}',
      );
      expect(bundle, contains('Local network state'));
      expect(bundle, contains('vEthernet (WSL)'));
    });

    test('omits the whole network section when the state is unavailable, with no placeholder', () {
      for (final absent in [null, '', '   ']) {
        final bundle = buildSupportBundle(
          appVersion: '1.0.14',
          platform: 'windows 10.0.22631',
          svcState: 'running',
          lastFailureDetail: null,
          logTail: '',
          configSha256: '',
          networkState: absent,
        );
        expect(bundle, isNot(contains('Local network state')));
      }
    });
  });

  group('readSvcStatusInfo', () {
    // The core scenario: aurora-svc not running or unreachable is exactly the state
    // this button exists to diagnose. This step must never throw, or it would take
    // down the on-disk log tail the caller reads afterwards, which has nothing to do
    // with this HTTP request (see the doc comment on _exportDiagnostics in
    // diagnostics_page.dart).
    test('an unreachable service yields a descriptive state, does not throw, and keeps the locally cached failure detail', () async {
      final bridge = AuroraBridgeSvc.debugInstance();
      bridge.debugPublishDetail(
        'FATAL start service: bind: address already in use',
      );
      final failingClient = AuroraSvcClient(
        base: Uri.parse('http://127.0.0.1:1'),
        token: () => '',
        client: MockClient((_) async => throw Exception('connection refused')),
      );

      final info = await readSvcStatusInfo(bridge, client: failingClient);

      expect(info.state, contains('cannot connect to aurora-svc'));
      expect(
        info.detail,
        'FATAL start service: bind: address already in use',
      );
    });

    test('a reachable service returns state and detail as is', () async {
      final bridge = AuroraBridgeSvc.debugInstance();
      final okClient = AuroraSvcClient(
        base: Uri.parse('http://127.0.0.1:1'),
        token: () => '',
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'state': 'error', 'detail': 'boom'}), 200),
        ),
      );

      final info = await readSvcStatusInfo(bridge, client: okClient);

      expect(info.state, 'error');
      expect(info.detail, 'boom');
    });
  });
}
