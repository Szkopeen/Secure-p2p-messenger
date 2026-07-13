import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/codec.dart';
import '../models/cloud_account.dart';

class CloudAuthResult {
  const CloudAuthResult({
    required this.session,
    required this.encryptedVault,
  });

  final CloudSession session;
  final Map<String, dynamic>? encryptedVault;
}

abstract class CloudEvent {
  const CloudEvent();
}

class CloudReady extends CloudEvent {
  const CloudReady();
}

class CloudMessageEvent extends CloudEvent {
  const CloudMessageEvent(this.message);

  final CloudStoredMessage message;
}

class CloudConversationEvent extends CloudEvent {
  const CloudConversationEvent(this.conversation);

  final CloudConversation conversation;
}

class CloudProblem extends CloudEvent {
  const CloudProblem(this.message);

  final String message;
}

class CloudApiClient {
  CloudApiClient({
    required this.serverUrl,
    this.token,
  });

  final String serverUrl;
  final String? token;
  final StreamController<CloudEvent> _events =
      StreamController<CloudEvent>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  Stream<CloudEvent> get events => _events.stream;

  Uri _httpUri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(serverUrl.trim());
    final scheme = switch (base.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      'http' || 'https' => base.scheme,
      _ => throw ArgumentError(
          'Adres serwera musi zaczynac sie od https:// albo http://.'),
    };
    _assertSafeTransport(scheme, base.host);
    return base.replace(
      scheme: scheme,
      path: path,
      queryParameters: query,
      fragment: null,
    );
  }

  Uri _wsUri() {
    final base = Uri.parse(serverUrl.trim());
    final scheme = switch (base.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      'ws' || 'wss' => base.scheme,
      _ => throw ArgumentError(
          'Adres serwera musi zaczynac sie od https:// albo http://.'),
    };
    _assertSafeTransport(scheme, base.host);
    return base.replace(
      scheme: scheme,
      path: '/v2/ws',
      queryParameters: {'token': token ?? ''},
      fragment: null,
    );
  }

  Future<CloudAuthResult> register({
    required String username,
    required String password,
    required String deviceId,
    required String deviceName,
    required String keyAgreementPublicKey,
    required String identityPublicKey,
    required String keyAgreementPublicKeySignature,
    required String vaultSalt,
    required String vaultKey,
    required Map<String, dynamic> encryptedVault,
  }) async {
    final raw = await _post('/v2/register', {
      'username': username,
      'password': password,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'keyAgreementPublicKey': keyAgreementPublicKey,
      'identityPublicKey': identityPublicKey,
      'keyAgreementPublicKeySignature': keyAgreementPublicKeySignature,
      'vaultSalt': vaultSalt,
      'encryptedVault': encryptedVault,
    });
    return _authResult(raw, serverUrl, vaultKey);
  }

  Future<CloudAuthResult> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceName,
    required String vaultKey,
  }) async {
    final raw = await _post('/v2/login', {
      'username': username,
      'password': password,
      'deviceId': deviceId,
      'deviceName': deviceName,
    });
    return _authResult(raw, serverUrl, vaultKey);
  }

  Future<List<CloudPublicUser>> users() async {
    final raw = await _get('/v2/users');
    final items = raw['users'] as List? ?? const [];
    return items
        .map((item) =>
            CloudPublicUser.fromJson((item as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>?> vault() async {
    final raw = await _get('/v2/vault');
    final vault = raw['encryptedVault'];
    if (vault is Map) return vault.cast<String, dynamic>();
    return null;
  }

  Future<void> saveVault(Map<String, dynamic> encryptedVault) async {
    await _put('/v2/vault', {'encryptedVault': encryptedVault});
  }

  Future<void> updateKeyBundle({
    required String keyAgreementPublicKey,
    required String identityPublicKey,
    required String keyAgreementPublicKeySignature,
    Map<String, dynamic>? identityRotationProof,
  }) async {
    await _put('/v2/keys', {
      'keyAgreementPublicKey': keyAgreementPublicKey,
      'identityPublicKey': identityPublicKey,
      'keyAgreementPublicKeySignature': keyAgreementPublicKeySignature,
      if (identityRotationProof != null)
        'identityRotationProof': identityRotationProof,
    });
  }

  Future<List<CloudConversation>> conversations() async {
    final raw = await _get('/v2/conversations');
    final items = raw['conversations'] as List? ?? const [];
    return items
        .map((item) =>
            CloudConversation.fromJson((item as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<CloudConversation> createDirectConversation({
    required String peerUserId,
    required Map<String, dynamic> memberKeys,
  }) async {
    final raw = await _post('/v2/conversations/direct', {
      'peerUserId': peerUserId,
      'memberKeys': memberKeys,
    });
    return CloudConversation.fromJson(
      asStringKeyMap(raw['conversation'], 'conversation'),
    );
  }

  Future<List<CloudStoredMessage>> messages({
    required String conversationId,
    int afterSeq = 0,
  }) async {
    final raw = await _get('/v2/messages', {
      'conversationId': conversationId,
      'afterSeq': afterSeq.toString(),
    });
    final items = raw['messages'] as List? ?? const [];
    return items
        .map((item) =>
            CloudStoredMessage.fromJson((item as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<CloudStoredMessage> sendMessage({
    required String conversationId,
    required String messageId,
    required Map<String, dynamic> payload,
  }) async {
    final raw = await _post('/v2/messages', {
      'conversationId': conversationId,
      'messageId': messageId,
      'payload': payload,
    });
    return CloudStoredMessage.fromJson(
      asStringKeyMap(raw['message'], 'message'),
    );
  }

  Future<void> connectEvents() async {
    if (token == null || token!.isEmpty) return;
    await disconnectEvents();
    _channel = WebSocketChannel.connect(_wsUri());
    _subscription = _channel!.stream.listen(
      _handleEvent,
      onError: (Object error) => _events.add(CloudProblem(error.toString())),
      onDone: () => _events
          .add(const CloudProblem('Polaczenie cloud zostalo zamkniete.')),
    );
  }

  Future<void> disconnectEvents() async {
    await _subscription?.cancel();
    await _channel?.sink.close();
    _subscription = null;
    _channel = null;
  }

  Future<void> dispose() async {
    await disconnectEvents();
    await _events.close();
  }

  void _handleEvent(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (json['type']) {
        case 'ready':
          _events.add(const CloudReady());
          break;
        case 'message':
          _events.add(
            CloudMessageEvent(
              CloudStoredMessage.fromJson(
                asStringKeyMap(json['message'], 'message'),
              ),
            ),
          );
          break;
        case 'conversation':
          _events.add(
            CloudConversationEvent(
              CloudConversation.fromJson(
                asStringKeyMap(json['conversation'], 'conversation'),
              ),
            ),
          );
          break;
        default:
          break;
      }
    } catch (error) {
      _events.add(CloudProblem('Nie mozna przetworzyc eventu cloud: $error'));
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    return _request('GET', path, null, query);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) {
    return _request('POST', path, body);
  }

  Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body) {
    return _request('PUT', path, body);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path,
    Map<String, dynamic>? body, [
    Map<String, String>? query,
  ]) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, _httpUri(path, query));
      request.headers.contentType = ContentType.json;
      if (token != null && token!.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      final json = (decoded as Map).cast<String, dynamic>();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
            json['error']?.toString() ?? 'HTTP ${response.statusCode}');
      }
      if (json['ok'] == false) {
        throw StateError(json['error']?.toString() ?? 'Blad serwera.');
      }
      return json;
    } finally {
      client.close(force: true);
    }
  }

  CloudAuthResult _authResult(
    Map<String, dynamic> raw,
    String serverUrl,
    String vaultKey,
  ) {
    final user = asStringKeyMap(raw['user'], 'user');
    final session = CloudSession(
      serverUrl: serverUrl,
      token: requiredString(raw, 'token'),
      userId: requiredString(user, 'userId'),
      username: requiredString(user, 'username'),
      displayName:
          user['displayName'] as String? ?? requiredString(user, 'username'),
      deviceId: requiredString(raw, 'deviceId'),
      vaultSalt: requiredString(raw, 'vaultSalt'),
      vaultKey: vaultKey,
    );
    final vault = raw['encryptedVault'];
    return CloudAuthResult(
      session: session,
      encryptedVault: vault is Map ? vault.cast<String, dynamic>() : null,
    );
  }

  void _assertSafeTransport(String scheme, String host) {
    final secure = scheme == 'https' || scheme == 'wss';
    if (secure || _isLocalDevelopmentHost(host)) return;
    throw ArgumentError(
      'Poza localhostem polaczenie z serwerem musi uzywac HTTPS/WSS.',
    );
  }

  bool _isLocalDevelopmentHost(String host) {
    final value = host.toLowerCase();
    return value == 'localhost' ||
        value == '127.0.0.1' ||
        value == '::1' ||
        value.endsWith('.localhost');
  }
}
