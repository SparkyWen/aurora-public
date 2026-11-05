import 'dart:convert';

import 'package:aurora/core/config_compiler.dart';
import 'package:aurora/core/contract.dart';
import 'package:aurora/core/link_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Sanitized share links matching the VPS links.txt format.
  final ssUserInfo =
      base64.encode(utf8.encode('2022-blake3-aes-128-gcm:SSPASS'));
  final links = '''
# Aurora node share links
vless://00000000-0000-0000-0000-000000000000@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBKEY&sid=0123abcd&type=tcp&headerType=none#Example-Reality
hysteria2://HY2PASS@203.0.113.10:443/?sni=www.bing.com&insecure=1&alpn=h3#Example-Hysteria2
ss://$ssUserInfo@203.0.113.10:8443#Example-SS2022
''';

  test('parses all three link types into contract nodes', () {
    final contract = LinkParser.parseToContract(links)!;
    final nodes = contract['nodes'] as List;
    expect(nodes.length, 3);

    final reality = nodes[0] as Map;
    expect(reality['protocol'], 'vless-reality');
    expect(reality['port'], 443);
    expect((reality['params'] as Map)['uuid'],
        '00000000-0000-0000-0000-000000000000');
    expect((reality['params'] as Map)['public_key'], 'PUBKEY');
    expect((reality['params'] as Map)['short_id'], '0123abcd');

    final hy2 = nodes[1] as Map;
    expect(hy2['protocol'], 'hysteria2');
    expect((hy2['params'] as Map)['password'], 'HY2PASS');
    expect((hy2['params'] as Map)['sni'], 'www.bing.com');

    final ss = nodes[2] as Map;
    expect(ss['protocol'], 'shadowsocks-2022');
    expect(ss['port'], 8443);
    expect((ss['params'] as Map)['method'], '2022-blake3-aes-128-gcm');
    expect((ss['params'] as Map)['password'], 'SSPASS');
  });

  test('parsed contract compiles to a valid sing-box structure', () {
    final contract =
        AuroraContract.fromJson(LinkParser.parseToContract(links)!);
    final cfg = ConfigCompiler.compile(
      contract,
      mode: AuroraMode.global,
      platform: AuroraPlatform.android,
    );
    final outbounds = cfg['outbounds'] as List;
    final tags = outbounds.map((o) => (o as Map)['tag']).toList();
    expect(tags, containsAll(['proxy', 'auto', 'direct']));
    // one outbound per parsed node + selector + urltest + direct
    expect(outbounds.length, 6);
  });

  test('ignores comments and blanks; returns null when empty', () {
    expect(LinkParser.parseToContract('# only a comment\n\n'), isNull);
  });
}
