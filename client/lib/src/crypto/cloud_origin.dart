String normalizeCloudServerUrl(String value) => canonicalCloudOrigin(value);

String canonicalCloudOrigin(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError('Adres serwera nie moze byc pusty.');
  }

  final lower = trimmed.toLowerCase();
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
  final host = uri.host.toLowerCase();
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
