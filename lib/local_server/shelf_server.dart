import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../core/constants/server_constants.dart';
import 'handlers/file_handler.dart';
import 'handlers/html_handler.dart';
import 'handlers/segment_handler.dart';
import 'handlers/key_handler.dart';
import 'security/constant_time_compare.dart';

/// Builds the shelf handler for v2 (lecture-level, multi-video).
/// Routes:
///   GET /key/:lectureId            → raw 16-byte AES key (for HLS player)
///   GET /segment/:lectureId/:videoId/:fileName → strip outer GCM, return inner CBC
///   GET /playlist/:lectureId/:videoId          → patched HLS playlist
Handler buildShelfHandler({
  required String lectureId,
  required int actualPort,
  required String lectureDir,
  required String keyHex,
  required String deviceId,
  required String appDocPath,
  required String sessionToken,
  Map<String, String> fileIvMap = const {},
  String watermarkText = 'SECURE PLAYER',
}) {
  final router = Router();

  router.get('/key/<lid>',
      (Request req, String lid) async {
    if (!_isValidToken(req, sessionToken)) return Response.forbidden('');
    return keyHandler(Uri.decodeComponent(lid), keyHex);
  });

  router.get('/segment/<lid>/<vid>/<fileName>',
      (Request req, String lid, String vid, String fileName) async {
    if (!_isValidToken(req, sessionToken)) return Response.forbidden('');
    return segmentHandlerV2(req, Uri.decodeComponent(lid), Uri.decodeComponent(vid),
        Uri.decodeComponent(fileName), keyHex, deviceId, appDocPath);
  });

  router.get('/playlist/<lid>/<vid>',
      (Request req, String lid, String vid) async {
    if (!_isValidToken(req, sessionToken)) return Response.forbidden('');
    return _playlistHandlerV2(Uri.decodeComponent(lid), Uri.decodeComponent(vid),
        lectureDir, actualPort, sessionToken);
  });

  // ── Encrypted HTML file route ────────────────────────────────────────────
  // Auth via header OR ?t= (WebView on Windows cannot set custom headers).
  // Injects watermark CSS/overlay and CSP header server-side.
  router.get('/html/<lid>/<fid>/<filename>',
      (Request req, String lid, String fid, String filename) async {
    if (!_isValidTokenOrParam(req, sessionToken)) return Response.forbidden('');
    return htmlHandler(Uri.decodeComponent(lid), Uri.decodeComponent(fid),
        Uri.decodeComponent(filename), keyHex, fileIvMap, appDocPath, watermarkText);
  });

  // ── Encrypted file route ─────────────────────────────────────────────────
  router.get('/file/<lid>/<fid>/<filename>',
      (Request req, String lid, String fid, String filename) async {
    // Accept token via Authorization header OR ?t= query param (for PDF viewers)
    if (!_isValidTokenOrParam(req, sessionToken)) return Response.forbidden('');
    return fileHandler(req, Uri.decodeComponent(lid), Uri.decodeComponent(fid),
        Uri.decodeComponent(filename), keyHex, fileIvMap, appDocPath);
  });

  // ── V1 legacy routes (keep for backward compat) ───────────────────────────
  router.get('/segment/<cid>/<fileName>',
      (Request req, String cid, String fileName) async {
    if (!_isValidToken(req, sessionToken)) return Response.forbidden('');
    return segmentHandlerV1(req, Uri.decodeComponent(cid),
        Uri.decodeComponent(fileName), keyHex, {}, appDocPath, deviceId);
  });

  router.get('/playlist/<cid>',
      (Request req, String cid) async {
    if (!_isValidToken(req, sessionToken)) return Response.forbidden('');
    return _playlistHandlerV1(Uri.decodeComponent(cid), lectureDir, actualPort);
  });

  return router.call;
}

bool _isValidToken(Request req, String expected) {
  final auth = req.headers['authorization'] ?? '';
  return constantTimeEquals(auth, 'Bearer $expected');
}

// For file routes accessed by PDF/image viewers that can't set custom headers.
bool _isValidTokenOrParam(Request req, String expected) {
  if (_isValidToken(req, expected)) return true;
  return constantTimeEquals(req.url.queryParameters['t'] ?? '', expected);
}

Future<Response> _playlistHandlerV2(
  String lectureId,
  String videoId,
  String lectureDir,
  int actualPort,
  String sessionToken,
) async {
  final playlistFile =
      File('$lectureDir/videos/$videoId/playlist.m3u8');
  if (!playlistFile.existsSync()) {
    return Response.notFound('Playlist not found: $lectureId/$videoId');
  }

  String content = playlistFile.readAsStringSync();

  // Patch port in key URI and segment references
  content = content.replaceAll(
    RegExp(r'http://127\.0\.0\.1:\d+/'),
    'http://${ServerConstants.localhost}:$actualPort/',
  );

  // Ensure /key/ URIs carry the session token as query param so the
  // player request passes the auth check (better_player passes custom headers).
  // Actually better_player supports custom headers — handled in VideoPlayer widget.

  // Rewrite segment filenames to full URLs the shelf server can route:
  // seg000.ts → http://127.0.0.1:{port}/segment/{lid}/{vid}/seg000.ts
  content = content.replaceAllMapped(
    RegExp(r'^(seg\d+\.ts)$', multiLine: true),
    (m) =>
        'http://${ServerConstants.localhost}:$actualPort/segment/$lectureId/$videoId/${m.group(1)}',
  );

  return Response.ok(
    content,
    headers: {
      'Content-Type': 'application/vnd.apple.mpegurl',
      'Cache-Control': 'no-store',
    },
  );
}

Future<Response> _playlistHandlerV1(
  String courseId,
  String courseDir,
  int actualPort,
) async {
  final playlistFile = File('$courseDir/playlist.m3u8');
  if (!playlistFile.existsSync()) {
    return Response.notFound('Playlist not found: $courseId');
  }

  String content = playlistFile.readAsStringSync();
  content = content.replaceAll(RegExp(r'#EXT-X-KEY:[^\n]+\n?'), '');
  content = content.replaceAll(
    RegExp(r'http://127\.0\.0\.1:\d+/'),
    'http://${ServerConstants.localhost}:$actualPort/',
  );
  content = content.replaceAll(
    RegExp(r'/segment/[^/]+/'),
    '/segment/$courseId/',
  );

  return Response.ok(
    content,
    headers: {
      'Content-Type': 'application/vnd.apple.mpegurl',
      'Cache-Control': 'no-store',
    },
  );
}
