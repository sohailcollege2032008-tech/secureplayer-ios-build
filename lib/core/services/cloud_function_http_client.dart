import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';

import '../../security_layer/cert_pinning/cert_pinning_service.dart';

/// Calls a Firebase Cloud Function over raw HTTP — needed on Windows, where
/// the `cloud_functions` plugin has no platform implementation at all
/// (confirmed: no `windows:` entry in its own pubspec, no
/// `cloud_functions_windows` in the lockfile). Every Windows call site
/// (import, profile fetch, key repair) goes through this one helper so
/// cert pinning and auth-header handling live in exactly one place instead
/// of being duplicated per call site.
Future<Map<String, dynamic>> callCloudFunctionViaHttp(
  String name,
  Map<String, dynamic> payload, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) throw StateError('Not signed in');
  final idToken = await user.getIdToken();
  final uri = Uri.parse(
      'https://us-central1-stud-future-platform-db.cloudfunctions.net/$name');

  final client = CertPinningService.createPinnedClient();
  client.connectionTimeout = timeout;
  try {
    final req = await client.postUrl(uri);
    final bodyBytes = utf8.encode(jsonEncode({'data': payload}));
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.headers.set('Authorization', 'Bearer $idToken');
    req.headers.set('Content-Length', '${bodyBytes.length}');
    req.add(bodyBytes);
    final resp = await req.close();
    final body = jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      final err = body['error'] as Map? ?? {};
      throw HttpException(
          '${err['status'] ?? 'unknown'} — ${err['message'] ?? 'error'}');
    }
    return body['result'] as Map<String, dynamic>;
  } finally {
    client.close();
  }
}
