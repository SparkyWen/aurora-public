import 'package:aurora/data/canonical_json.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recursively sorts object keys and preserves list order', () {
    expect(
      CanonicalJson.encode({
        'z': 1,
        'a': {
          'd': 2,
          'b': ['\u540e', '\u5148'], // non-ASCII data: must survive canonical JSON/signing
        },
      }),
      '{"a":{"b":["\u540e","\u5148"],"d":2},"z":1}',
    );
  });

  test('rejects values outside the signed JSON subset', () {
    expect(() => CanonicalJson.encode(DateTime.now()), throwsFormatException);
  });
}
