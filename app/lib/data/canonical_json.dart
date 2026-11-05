import 'dart:collection';
import 'dart:convert';

abstract final class CanonicalJson {
  static String encode(Object? value) => json.encode(_sorted(value));

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final result = SplayTreeMap<String, dynamic>();
      for (final entry in value.entries) {
        result[entry.key.toString()] = _sorted(entry.value);
      }
      return result;
    }
    if (value is List) return value.map(_sorted).toList();
    if (value == null || value is String || value is bool || value is num) {
      return value;
    }
    throw FormatException(
      'unsupported canonical JSON value: ${value.runtimeType}',
    );
  }
}
