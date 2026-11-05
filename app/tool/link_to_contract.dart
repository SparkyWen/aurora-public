// Expands `aurora://` links into a contract file, using the same code as the app. Used
// by the end-to-end test, and to prepare a contract for `aurora --contract` or for the
// control plane. Usage:
//   dart run tool/link_to_contract.dart <out.json> '<aurora://link>' ['<link>' ...]
import 'dart:io';

import 'package:aurora/core/contract_editor.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln("usage: link_to_contract <out.json> '<aurora://link>' ...");
    exit(2);
  }
  final plan = ContractEditor.plan(null, args.sublist(1).join('\n'));
  final contractJson = plan.contractJson;
  if (contractJson == null) {
    stderr.writeln('that link does not describe a server');
    exit(1);
  }
  File(args[0]).writeAsStringSync(contractJson);
}
