import 'dart:async';

import 'package:aurora/core/aurora_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selector confirmation waits for matching core readback', () async {
    final groups = StreamController<List<OutboundGroupInfo>>.broadcast();
    var sent = false;
    final pending = selectOutboundWithConfirmation(
      groups: groups.stream,
      group: 'proxy',
      tag: 'fail-closed',
      send: () async => sent = true,
    );

    await Future<void>.delayed(Duration.zero);
    expect(sent, isTrue);
    groups.add([group(selected: 'relay-public-auto')]);
    await Future<void>.delayed(Duration.zero);
    groups.add([group(selected: 'fail-closed')]);

    await pending;
    await groups.close();
  });

  test(
    'selector confirmation propagates send errors and readback timeout',
    () async {
      final groups = StreamController<List<OutboundGroupInfo>>.broadcast();
      await expectLater(
        selectOutboundWithConfirmation(
          groups: groups.stream,
          group: 'proxy',
          tag: 'fail-closed',
          send: () async => throw StateError('command_unavailable'),
        ),
        throwsStateError,
      );
      await expectLater(
        selectOutboundWithConfirmation(
          groups: groups.stream,
          group: 'proxy',
          tag: 'fail-closed',
          timeout: const Duration(milliseconds: 1),
          send: () async {},
        ),
        throwsStateError,
      );
      await groups.close();
    },
  );

  test('selector confirmation also bounds a stalled send', () async {
    final groups = StreamController<List<OutboundGroupInfo>>.broadcast();
    final never = Completer<void>();
    await expectLater(
      selectOutboundWithConfirmation(
        groups: groups.stream,
        group: 'proxy',
        tag: 'fail-closed',
        timeout: const Duration(milliseconds: 1),
        send: () => never.future,
      ),
      throwsStateError,
    );
    await groups.close();
  });
}

OutboundGroupInfo group({required String selected}) => OutboundGroupInfo(
  tag: 'proxy',
  type: 'selector',
  selected: selected,
  selectable: true,
  items: const [],
);
