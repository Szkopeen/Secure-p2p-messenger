import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

final Random _secureRandom = Random.secure();

String b64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

Uint8List unb64(String value) {
  final normalized = base64Url.normalize(value);
  return Uint8List.fromList(base64Url.decode(normalized));
}

Uint8List secureRandomBytes(int length) {
  return Uint8List.fromList(
    List<int>.generate(length, (_) => _secureRandom.nextInt(256), growable: false),
  );
}

Uint8List utf8Bytes(String value) => Uint8List.fromList(utf8.encode(value));

String canonicalJson(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return jsonEncode(value);
  }

  if (value is List) {
    return '[${value.map(canonicalJson).join(',')}]';
  }

  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    final parts = <String>[];
    for (final key in keys) {
      parts.add('${jsonEncode(key)}:${canonicalJson(value[key])}');
    }
    return '{${parts.join(',')}}';
  }

  throw ArgumentError('Nieobslugiwany typ JSON: ${value.runtimeType}');
}

Uint8List canonicalJsonBytes(Object? value) => utf8Bytes(canonicalJson(value));

Map<String, dynamic> asStringKeyMap(Object? value, String name) {
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  throw FormatException('$name musi byc obiektem JSON.');
}

String requiredString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Brak pola tekstowego $key.');
}

int requiredInt(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is int) return value;
  throw FormatException('Brak pola liczbowego $key.');
}
