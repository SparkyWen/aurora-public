import 'package:aurora/features/settings/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // '\u4ee5\u592a\u7f51' is a localized (Chinese) Windows adapter name: non-ASCII test data.
  group('what happens to a pinned egress NIC on a refresh', () {
    test('nothing saved means automatic, and there is nothing to clear', () {
      final d = resolveEgressPin(null, const ['\u4ee5\u592a\u7f51', 'WLAN']);
      expect(d.pinned, isNull);
      expect(d.clearSaved, isFalse);
    });

    test('a saved adapter that is still present stays pinned', () {
      final d = resolveEgressPin('WLAN', const ['\u4ee5\u592a\u7f51', 'WLAN']);
      expect(d.pinned, 'WLAN');
      expect(d.clearSaved, isFalse);
    });

    // Cable unplugged or machine replaced: compiling a name the core cannot find into
    // the config would make every later connection fail, so this must fall back to
    // automatic and also clear the saved value.
    test('the list was obtained but the adapter is really gone: fall back to automatic and clear the saved value', () {
      final d = resolveEgressPin('\u4ee5\u592a\u7f51', const ['WLAN']);
      expect(d.pinned, isNull);
      expect(d.clearSaved, isTrue);
    });

    // This is the reason the file exists. An empty list does NOT mean "that adapter
    // is gone"; it only means the query got no answer this time (aurora-svc not
    // running, blocked by a firewall, timed out). Get it backwards and a user who
    // merely opens settings while the service is unreachable has the pinned choice
    // silently cleared, and the next connection follows the system default route,
    // i.e. exactly the adapter they explicitly did not want.
    test('when the query got no answer, the saved value must never be treated as stale', () {
      final d = resolveEgressPin('\u4ee5\u592a\u7f51', const []);
      expect(d.pinned, '\u4ee5\u592a\u7f51');
      expect(d.clearSaved, isFalse);
    });

    test('a blank saved value is the same as nothing saved', () {
      for (final saved in ['', '   ']) {
        final d = resolveEgressPin(saved, const ['WLAN']);
        expect(d.pinned, isNull, reason: '"$saved"');
        expect(d.clearSaved, isFalse, reason: '"$saved"');
      }
    });
  });
}
