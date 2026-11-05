// Verifies a signed Aurora contract against the key it pins for itself. Note this
// only proves the document is internally consistent; the trust decision is which key
// you pinned when you first imported it. Usage:
//   dart run tool/verify_contract.dart <contract.json> [client-version]
import 'dart:convert';
import 'dart:io';

import 'package:aurora/core/contract.dart';
import 'package:aurora/data/contract_verifier.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: verify_contract <contract.json> [client-version]');
    exitCode = 2;
    return;
  }
  final body = File(args[0]).readAsStringSync();
  final delivery = AuroraContract.fromJson(
    json.decode(body) as Map<String, dynamic>,
  ).delivery;
  final publicKey = delivery.signingPublicKey;
  if (publicKey == null) {
    stderr.writeln('this contract pins no signing key (delivery.signing)');
    exitCode = 1;
    return;
  }
  await ContractVerifier.verifyRemote(
    body,
    clientVersion: args.length > 1 ? args[1] : '0.1.3',
    publicKey: publicKey,
    keyId: delivery.signingKeyId,
  );
  stdout.writeln('signature/expiry/client-version: PASS');
}
