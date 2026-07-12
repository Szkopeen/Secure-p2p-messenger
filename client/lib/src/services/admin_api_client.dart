import 'dart:convert';
import 'dart:io';

import '../models/admin_user.dart';
import '../models/identity.dart';

class AdminApiException implements Exception {
  const AdminApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AdminApiClient {
  AdminApiClient(this.settings);

  final AdminSettings settings;

  Future<AdminUsersResult> listUsers() async {
    final json = await _request('GET', '/admin/users');
    return AdminUsersResult.fromJson(json);
  }

  Future<AdminUser> getUser(String userId) async {
    final json =
        await _request('GET', '/admin/users/${Uri.encodeComponent(userId)}');
    return AdminUser.fromJson((json['user'] as Map).cast<String, dynamic>());
  }

  Future<AdminActionResult> banUser(String userId) async {
    final json = await _request(
      'POST',
      '/admin/users/${Uri.encodeComponent(userId)}/ban',
    );
    return AdminActionResult.fromJson(
      (json['result'] as Map).cast<String, dynamic>(),
    );
  }

  Future<AdminActionResult> unbanUser(String userId) async {
    final json = await _request(
      'POST',
      '/admin/users/${Uri.encodeComponent(userId)}/unban',
    );
    return AdminActionResult.fromJson(
      (json['result'] as Map).cast<String, dynamic>(),
    );
  }

  Future<AdminActionResult> deleteUser(
    String userId, {
    required bool ban,
  }) async {
    final json = await _request(
      'DELETE',
      '/admin/users/${Uri.encodeComponent(userId)}',
      queryParameters: {'ban': ban ? 'true' : 'false'},
    );
    return AdminActionResult.fromJson(
      (json['result'] as Map).cast<String, dynamic>(),
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.openUrl(
        method,
        _buildUri(path, queryParameters: queryParameters),
      );
      request.headers.set(
          HttpHeaders.authorizationHeader, 'Bearer ${settings.adminToken}');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final body = await response.transform(utf8.decoder).join();
      final decoded = body.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(body) as Map).cast<String, dynamic>();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = decoded['error'] as String? ??
            'Blad API administratora: HTTP ${response.statusCode}.';
        throw AdminApiException(message);
      }

      if (decoded['ok'] != true) {
        throw AdminApiException(
          decoded['error'] as String? ??
              'Relay odrzucil operacje administratora.',
        );
      }

      return decoded;
    } on AdminApiException {
      rethrow;
    } on SocketException catch (error) {
      throw AdminApiException(
          'Nie mozna polaczyc sie z relay: ${error.message}');
    } on FormatException {
      throw const AdminApiException(
          'Relay zwrocil niepoprawna odpowiedz JSON.');
    } finally {
      client.close(force: true);
    }
  }

  Uri _buildUri(
    String path, {
    Map<String, String>? queryParameters,
  }) {
    final base = Uri.parse(settings.serverUrl.trim());
    final scheme = switch (base.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      _ => base.scheme,
    };
    if (scheme != 'https' && scheme != 'http') {
      throw const AdminApiException(
          'Adres admina musi zaczynac sie od https:// albo http://.');
    }

    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      scheme: scheme,
      path: '$basePath$path',
      queryParameters: queryParameters,
      fragment: '',
    );
  }
}
