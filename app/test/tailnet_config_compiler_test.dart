import 'dart:convert';
import 'dart:io';
import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/tailnet_options.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> sample([String name = 'contract.sample.json']) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;
TailnetOptions options() => TailnetOptions(
  stateDirectory:
      '/private/var/mobile/Containers/Shared/AppGroup/FIXTURE/working/tailnet/state-v1',
  hostname: 'aurora-ios-fixture',
);
Map<String, dynamic> compile({
  Map<String, dynamic>? source,
  AuroraPlatform platform = AuroraPlatform.ios,
  AuroraMode mode = AuroraMode.global,
  TailnetOptions? tailnet,
  String? debugLogPath,
}) => ConfigCompiler.compile(
  AuroraContract.fromJson(source ?? sample()),
  platform: platform,
  mode: mode,
  tailnet: tailnet,
  debugLogPath: debugLogPath,
);

void main() {
  for (final path in [
    '/data/user/0/com.aurora.vpn/files/tailnet/state-v1',
    '/private/var/mobile/Containers/Shared/AppGroup/ABC-123/working/tailnet/state-v1',
    '/private/native/Aurora State/tailnet',
  ]) {
    test('preserves canonical absolute POSIX path $path', () {
      final value = TailnetOptions(stateDirectory: path, hostname: 'a-1');
      expect(value.stateDirectory, path);
      expect(value.hostname, 'a-1');
    });
  }
  for (final path in [
    '',
    '/',
    'tailnet/state-v1',
    '//data/tailnet',
    '/data//tailnet',
    '/data/tailnet/',
    '/data/./tailnet',
    '/data/../tailnet',
    r'C:\data\tailnet',
    r'/data\tailnet',
    r'/data/$HOME/tailnet',
    r'/data/${USER}/tailnet',
    '/data/\u0000tailnet',
    '/data/\ntailnet',
    '/data/\ttailnet',
    '/data/\u007ftailnet',
    ' /data/tailnet',
    '/data/tailnet ',
  ]) {
    test('rejects unsafe/noncanonical path ${jsonEncode(path)}', () {
      expect(
        () => TailnetOptions(stateDirectory: path, hostname: 'aurora-ios'),
        throwsArgumentError,
      );
    });
  }
  for (final hostname in ['a', '0', 'aurora-android-123', 'a' * 63]) {
    test('accepts bounded DNS label $hostname', () {
      expect(
        TailnetOptions(
          stateDirectory: '/native/tailnet',
          hostname: hostname,
        ).hostname,
        hostname,
      );
    });
  }
  for (final hostname in [
    '',
    'AURORA',
    '-aurora',
    'aurora-',
    'aurora.local',
    'aurora_ios',
    'a' * 64,
    'aurora ios',
    'aurora\n',
    '\u624b\u673a', // CJK ("phone"): non-ASCII must be rejected too
    ' a',
  ]) {
    test('rejects invalid hostname ${jsonEncode(hostname)}', () {
      expect(
        () => TailnetOptions(
          stateDirectory: '/native/tailnet',
          hostname: hostname,
        ),
        throwsArgumentError,
      );
    });
  }
  for (final platform in AuroraPlatform.values) {
    test('null option preserves existing $platform output', () {
      final original = ConfigCompiler.compile(
        AuroraContract.fromJson(sample()),
        mode: AuroraMode.global,
        platform: platform,
      );
      expect(compile(platform: platform), original);
      expect(original.containsKey('endpoints'), isFalse);
    });
  }
  for (final platform in [
    AuroraPlatform.desktop,
    AuroraPlatform.windows,
    AuroraPlatform.linux,
  ]) {
    test('nonempty options refuse $platform', () {
      expect(
        () => compile(platform: platform, tailnet: options()),
        throwsArgumentError,
      );
    });
  }
  test(
    'Tailnet refuses debug output while ordinary debug remains unchanged',
    () {
      for (final path in ['', '/private/debug.log']) {
        expect(
          () => compile(tailnet: options(), debugLogPath: path),
          throwsArgumentError,
        );
      }
      expect(compile(debugLogPath: '/private/debug.log')['log'], {
        'level': 'debug',
        'timestamp': true,
        'output': '/private/debug.log',
      });
    },
  );
  for (final platform in [AuroraPlatform.android, AuroraPlatform.ios]) {
    test(
      '$platform adds one userspace endpoint without identity/authority inputs',
      () {
        final value = options();
        final output = compile(platform: platform, tailnet: value);
        expect(output['endpoints'], [
          {
            'type': 'tailscale',
            'tag': 'aurora-tailnet',
            'state_directory': value.stateDirectory,
            'hostname': value.hostname,
            'system_interface': false,
            'ephemeral': false,
            'accept_routes': false,
            'advertise_routes': <String>[],
            'advertise_exit_node': false,
            'detour': 'proxy',
          },
        ]);
        expect(output['log'], {'level': 'warn', 'timestamp': true});
        for (final key in ['inbounds', 'outbounds', 'experimental']) {
          expect(output[key], compile(platform: platform)[key]);
        }
      },
    );
    test(
      '$platform Tailnet and port53 precede public IPv6 rejection/private direct',
      () {
        final route =
            compile(platform: platform, tailnet: options())['route'] as Map;
        final rules = route['rules'] as List;
        expect(rules.take(4), [
          {
            'inbound': ['aurora-tailnet'],
            'action': 'reject',
          },
          {
            'inbound': ['tun-in'],
            'network': ['tcp', 'udp'],
            'port': [53],
            'action': 'hijack-dns',
          },
          {
            'inbound': ['tun-in'],
            'ip_cidr': ['100.64.0.0/10', 'fd7a:115c:a1e0::/48'],
            'outbound': 'aurora-tailnet',
          },
          {
            'inbound': ['tun-in'],
            'domain_suffix': ['ts.net'],
            'outbound': 'aurora-tailnet',
          },
        ]);
        final original = compile(platform: platform)['route'] as Map;
        expect(rules.skip(4), original['rules']);
        expect({...route}..remove('rules'), {...original}..remove('rules'));
        expect(rules[4]['ip_version'], 6);
      },
    );
    test(
      '$platform MagicDNS precedes AAAA/HTTPS suppression and keeps public DNS',
      () {
        final source = sample();
        source['network']['suppress_https_rr'] = true;
        final dns =
            compile(
                  source: source,
                  platform: platform,
                  tailnet: options(),
                )['dns']
                as Map;
        final original =
            compile(source: source, platform: platform)['dns'] as Map;
        expect((dns['rules'] as List).first, {
          'domain_suffix': ['ts.net'],
          'server': 'dns-tailnet',
          'strategy': 'prefer_ipv4',
        });
        expect((dns['rules'] as List).skip(1), original['rules']);
        expect((dns['servers'] as List).last, {
          'type': 'tailscale',
          'tag': 'dns-tailnet',
          'endpoint': 'aurora-tailnet',
          'accept_default_resolvers': false,
        });
        expect(
          (dns['servers'] as List).take((original['servers'] as List).length),
          original['servers'],
        );
        expect(dns['final'], 'dns-proxy');
        expect(dns['strategy'], 'ipv4_only');
      },
    );
  }
  test('native IPv6 policy still receives dedicated Tailnet rules', () {
    final source = sample();
    source['network']['ipv6_mode'] = 'native';
    final enabled = compile(source: source, tailnet: options());
    final original = compile(source: source);
    // Native IPv6 drops the AAAA suppression rule; the Tailnet rule must still
    // lead, and whatever the skeleton emits after it is exactly the untouched
    // non-Tailnet output (the local-only NXDOMAIN rule today).
    final rules = (enabled['dns'] as Map)['rules'] as List;
    expect(rules.first, {
      'domain_suffix': ['ts.net'],
      'server': 'dns-tailnet',
      'strategy': 'prefer_ipv4',
    });
    expect(rules.skip(1), (original['dns'] as Map)['rules']);
    expect(
      rules.where((rule) => (rule as Map).containsKey('query_type')),
      isEmpty,
    );
    expect(
      ((enabled['route'] as Map)['rules'] as List).skip(4),
      (original['route'] as Map)['rules'],
    );
  });
  test('Smart CN rules remain behind Tailnet rules', () {
    final enabled = compile(mode: AuroraMode.smart, tailnet: options());
    final original = compile(mode: AuroraMode.smart);
    expect(
      ((enabled['dns'] as Map)['rules'] as List).skip(1),
      (original['dns'] as Map)['rules'],
    );
    expect(
      ((enabled['route'] as Map)['rules'] as List).skip(4),
      (original['route'] as Map)['rules'],
    );
  });
  test('dual-path public selector remains fail-closed', () {
    final source = sample('contract.dual-path.sample.json');
    final original = compile(source: source, mode: AuroraMode.smart);
    final enabled = compile(
      source: source,
      mode: AuroraMode.smart,
      tailnet: options(),
    );
    expect(enabled['outbounds'], original['outbounds']);
    expect((enabled['outbounds'] as List).first['default'], 'fail-closed');
    expect(enabled['experimental'], original['experimental']);
    expect(
      ((enabled['route'] as Map)['rules'] as List).skip(4),
      (original['route'] as Map)['rules'],
    );
  });
  for (final reserved in ['aurora-tailnet', 'dns-tailnet']) {
    test('refuses outbound node tagged $reserved', () {
      final source =
          jsonDecode(
                jsonEncode(
                  sample(),
                ).replaceAll('"vps-reality"', jsonEncode(reserved)),
              )
              as Map<String, dynamic>;
      expect(
        () => compile(source: source, tailnet: options()),
        throwsArgumentError,
      );
    });
    test('refuses selector tagged $reserved', () {
      final source = sample();
      source['outbound_group']['selector']['tag'] = reserved;
      expect(
        () => compile(source: source, tailnet: options()),
        throwsArgumentError,
      );
    });
    test('refuses urltest tagged $reserved', () {
      final source =
          jsonDecode(
                jsonEncode(sample()).replaceAll('"auto"', jsonEncode(reserved)),
              )
              as Map<String, dynamic>;
      expect(
        () => compile(source: source, tailnet: options()),
        throwsArgumentError,
      );
    });
    test('refuses dual-path group tagged $reserved', () {
      final source = sample('contract.dual-path.sample.json');
      source['paths']['items']['relay']['group_tag'] = reserved;
      expect(
        () => compile(source: source, tailnet: options()),
        throwsArgumentError,
      );
    });
  }
  test('requires the original unique proxy selector for endpoint detour', () {
    final source = sample();
    source['outbound_group']['selector']['tag'] = 'other-selector';
    expect(
      () => compile(source: source, tailnet: options()),
      throwsArgumentError,
    );
  });
}
