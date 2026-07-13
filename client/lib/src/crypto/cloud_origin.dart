String normalizeCloudServerUrl(String value) => canonicalCloudOrigin(value);

String canonicalCloudOrigin(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError('Adres serwera nie moze byc pusty.');
  }

  final lower = trimmed.toLowerCase();
  if (RegExp(r'^[a-z][a-z0-9+.-]*:').hasMatch(lower) &&
      !lower.startsWith('http://') &&
      !lower.startsWith('https://') &&
      !lower.startsWith('ws://') &&
      !lower.startsWith('wss://')) {
    throw ArgumentError('Nieobslugiwany schemat adresu serwera.');
  }

  final withScheme = switch (lower) {
    final text when text.startsWith('ws://') =>
      'http://${trimmed.substring('ws://'.length)}',
    final text when text.startsWith('wss://') =>
      'https://${trimmed.substring('wss://'.length)}',
    final text when text.startsWith('http://') || text.startsWith('https://') =>
      trimmed,
    _ => 'https://$trimmed',
  };

  final uri = Uri.parse(withScheme);
  final scheme = uri.scheme.toLowerCase();
  final host = _canonicalHost(uri.host);
  if (host.isEmpty || !uri.hasAuthority) {
    throw ArgumentError('Adres serwera musi zawierac host.');
  }
  if (uri.userInfo.isNotEmpty) {
    throw ArgumentError('Adres serwera nie moze zawierac loginu ani hasla.');
  }
  if (scheme == 'http' && !isLocalDevelopmentHost(host)) {
    throw ArgumentError(
      'Poza localhostem aplikacja wymaga HTTPS. Uzyj https:// albo domeny z TLS.',
    );
  }
  if (scheme != 'https' && scheme != 'http') {
    throw ArgumentError('Adres serwera musi zaczynac sie od https://.');
  }

  final hasDefaultPort = (scheme == 'https' && uri.port == 443) ||
      (scheme == 'http' && uri.port == 80);
  final port = uri.hasPort && !hasDefaultPort ? ':${uri.port}' : '';
  return '$scheme://${_formatHost(host)}$port';
}

bool isLocalDevelopmentHost(String host) {
  final value = host.toLowerCase();
  return value == 'localhost' ||
      value == '127.0.0.1' ||
      value == '::1' ||
      value.endsWith('.localhost');
}

String _formatHost(String host) {
  if (host.contains(':') && !host.startsWith('[')) return '[$host]';
  return host;
}

String _canonicalHost(String host) {
  var value = Uri.decodeComponent(host.trim()).toLowerCase();
  while (value.endsWith('.')) {
    value = value.substring(0, value.length - 1);
  }
  if (value.isEmpty) {
    throw ArgumentError('Adres serwera musi zawierac host.');
  }

  if (value.contains(':')) return value;

  final labels = value.split('.');
  if (labels.any((label) => label.isEmpty)) {
    throw ArgumentError('Host serwera zawiera pusta etykiete DNS.');
  }

  final asciiLabels = labels.map(_toAsciiDnsLabel).toList(growable: false);
  final asciiHost = asciiLabels.join('.');
  if (asciiHost.length > 253) {
    throw ArgumentError('Host serwera jest zbyt dlugi.');
  }
  return asciiHost;
}

String _toAsciiDnsLabel(String label) {
  final asciiOnly = label.runes.every((codePoint) => codePoint <= 0x7f);
  final ascii = asciiOnly ? label : 'xn--${_punycodeEncode(label)}';
  if (ascii.length > 63) {
    throw ArgumentError('Etykieta DNS jest zbyt dluga.');
  }
  if (!RegExp(r'^[a-z0-9-]+$').hasMatch(ascii) ||
      ascii.startsWith('-') ||
      ascii.endsWith('-')) {
    throw ArgumentError('Host serwera zawiera niepoprawna etykiete DNS.');
  }
  return ascii;
}

String _punycodeEncode(String input) {
  const base = 36;
  const tMin = 1;
  const tMax = 26;
  const initialBias = 72;
  const initialN = 128;
  const delimiter = '-';

  final codePoints = input.runes.toList(growable: false);
  final output = StringBuffer();
  var basicCount = 0;
  for (final codePoint in codePoints) {
    if (codePoint < 0x80) {
      output.writeCharCode(codePoint);
      basicCount++;
    }
  }
  var handledCount = basicCount;
  if (basicCount > 0) output.write(delimiter);

  var n = initialN;
  var delta = 0;
  var bias = initialBias;
  while (handledCount < codePoints.length) {
    var m = 0x10ffff;
    for (final codePoint in codePoints) {
      if (codePoint >= n && codePoint < m) m = codePoint;
    }

    delta += (m - n) * (handledCount + 1);
    n = m;

    for (final codePoint in codePoints) {
      if (codePoint < n) delta++;
      if (codePoint == n) {
        var q = delta;
        for (var k = base;; k += base) {
          final t = k <= bias
              ? tMin
              : k >= bias + tMax
                  ? tMax
                  : k - bias;
          if (q < t) break;
          output.write(_punycodeDigit(t + ((q - t) % (base - t))));
          q = (q - t) ~/ (base - t);
        }
        output.write(_punycodeDigit(q));
        bias =
            _punycodeAdapt(delta, handledCount + 1, handledCount == basicCount);
        delta = 0;
        handledCount++;
      }
    }

    delta++;
    n++;
  }

  return output.toString();
}

int _punycodeAdapt(int delta, int points, bool firstTime) {
  const base = 36;
  const tMin = 1;
  const tMax = 26;
  const skew = 38;
  const damp = 700;

  var value = firstTime ? delta ~/ damp : delta ~/ 2;
  value += value ~/ points;
  var k = 0;
  while (value > ((base - tMin) * tMax) ~/ 2) {
    value ~/= base - tMin;
    k += base;
  }
  return k + (((base - tMin + 1) * value) ~/ (value + skew));
}

String _punycodeDigit(int value) {
  if (value < 26) return String.fromCharCode(0x61 + value);
  if (value < 36) return String.fromCharCode(0x30 + value - 26);
  throw ArgumentError('Niepoprawna cyfra Punycode.');
}
