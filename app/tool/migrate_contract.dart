// One-time safe migration for a gitignored legacy contract.
//
// Usage:
//   dart run tool/migrate_contract.dart <contract.json> <hy2-spki-base64>
//
// It never prints node credentials or the resulting JSON.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: migrate_contract <contract.json> <hy2-spki-base64>');
    exit(2);
  }
  final pin = base64.decode(args[1]);
  if (pin.length != 32) {
    throw const FormatException('SPKI pin must be 32 bytes');
  }

  final file = File(args[0]);
  final contract = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  contract['revision'] = DateTime.now().millisecondsSinceEpoch;
  contract['updated'] = DateTime.now().toUtc().toIso8601String();
  contract['network'] = {
    'mtu': 1400,
    'ipv6_mode': 'block',
    'suppress_https_rr': false,
    ...?contract['network'] as Map<String, dynamic>?,
  };

  var migrated = 0;
  for (final value in contract['nodes'] as List? ?? const []) {
    final node = value as Map<String, dynamic>;
    if (node['protocol'] != 'hysteria2') continue;
    final params = node['params'] as Map<String, dynamic>;
    params['certificate_public_key_sha256'] = args[1];
    params.remove('cert_sha256');
    params.remove('insecure');
    migrated++;
  }
  if (migrated == 0) throw StateError('contract has no Hysteria2 node');

  final group = contract['outbound_group'] as Map<String, dynamic>;
  for (final key in ['selector', 'urltest']) {
    final members = ((group[key] as Map<String, dynamic>)['members'] as List)
        .toList();
    members.removeWhere((value) => value == 'direct');
    (group[key] as Map<String, dynamic>)['members'] = members;
  }
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(contract)}\n',
    flush: true,
  );
  stdout.writeln('contract migrated: MTU/IPv6/fail-closed/Hy2 SPKI');
}
