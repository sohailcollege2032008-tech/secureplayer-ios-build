import 'dart:io';

import 'package:shelf/shelf.dart';

/// Serves a FairPlay package's files (manifests + fMP4/CMAF segments) over
/// the local loopback HTTP server, byte-for-byte — no decryption happens
/// here. AVFoundation's own secure decode path decrypts segments in-place
/// once AVContentKeySession has a valid content key; this handler's only
/// job is making the files HTTP-reachable at all.
///
/// Exists because AVPlayer/AVURLAsset cannot stream an HLS .m3u8 playlist
/// directly from a file:// URL — HLS is fundamentally an HTTP-based
/// protocol (confirmed by Apple engineering on the developer forums), and
/// attempting it produces "CoreMediaErrorDomain error -12865" regardless of
/// Simulator vs real device. fairplay_service.dart originally assumed a
/// local file:// URL would work directly since Shaka Packager's manifests
/// use plain relative filenames with no server-side patching needed for
/// Android/Windows-style double-decryption — that assumption about
/// AVFoundation itself was wrong, not the manifest format.
Future<Response> fairplayStaticHandler(
  String lectureId,
  String videoId,
  String filename,
  String appDocumentsPath,
  String host,
  int port,
  String token,
) async {
  final packageDir =
      '$appDocumentsPath/fairplay_lectures/$lectureId/videos/$videoId';
  final file = File('$packageDir/$filename');
  if (!await file.exists()) {
    return Response.notFound('FairPlay asset not found: $filename');
  }

  if (filename.endsWith('.m3u8')) {
    var content = await file.readAsString();
    final base = 'http://$host:$port/fairplay/$lectureId/$videoId';

    // Quoted references: EXT-X-MEDIA URI="audio.m3u8" and
    // EXT-X-MAP URI="video_init.mp4"/"audio_init.mp4". Deliberately does
    // NOT match "skd://..." (the FairPlay key URI) — that has no
    // .m3u8/.mp4 extension so this pattern never touches it.
    content = content.replaceAllMapped(
      RegExp(r'URI="([\w.-]+\.(?:m3u8|mp4))"'),
      (m) => 'URI="$base/${m.group(1)}?t=$token"',
    );

    // Bare filename lines: the master playlist's "video.m3u8" reference,
    // and every segment line in a sub-playlist (video_1.m4s, etc).
    content = content.replaceAllMapped(
      RegExp(r'^([\w.-]+\.(?:m3u8|mp4|m4s))$', multiLine: true),
      (m) => '$base/${m.group(1)}?t=$token',
    );

    return Response.ok(
      content,
      headers: const {
        'Content-Type': 'application/vnd.apple.mpegurl',
        'Cache-Control': 'no-store',
      },
    );
  }

  return Response.ok(
    file.openRead(),
    headers: const {
      'Content-Type': 'video/mp4',
      'Cache-Control': 'no-store',
    },
  );
}
