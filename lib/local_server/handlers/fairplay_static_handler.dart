import 'dart:io';

import 'package:shelf/shelf.dart';

import '../security/path_safety.dart';

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
  Request request,
  String lectureId,
  String videoId,
  String filename,
  String appDocumentsPath,
  String host,
  int port,
  String token,
) async {
  if (hasPathTraversal(filename) ||
      hasPathTraversal(lectureId) ||
      hasPathTraversal(videoId)) {
    return Response.forbidden('Invalid path');
  }

  final file = File(
    '$appDocumentsPath/fairplay_lectures/$lectureId/videos/$videoId/$filename',
  );
  if (!await file.exists()) {
    return Response.notFound('FairPlay asset not found: $filename');
  }

  if (filename.endsWith('.m3u8')) {
    final base = 'http://$host:$port/fairplay/$lectureId/$videoId';
    return Response.ok(
      _absolutizeManifestUrls(await file.readAsString(), base, token),
      headers: const {
        'Content-Type': 'application/vnd.apple.mpegurl',
        'Cache-Control': 'no-store',
      },
    );
  }

  return _serveBytes(file, request.headers['range']);
}

/// Rewrites the relative filenames Shaka Packager emits into absolute URLs
/// pointing back at this server, carrying the session token.
String _absolutizeManifestUrls(String manifest, String base, String token) {
  // Quoted references: EXT-X-MEDIA URI="audio.m3u8" and EXT-X-MAP
  // URI="video_init.mp4". Deliberately does NOT match the FairPlay key URI
  // "skd://..." — that has no .m3u8/.mp4 extension so this never touches it,
  // which matters because rewriting it would break the key request entirely.
  var rewritten = manifest.replaceAllMapped(
    RegExp(r'URI="([\w.-]+\.(?:m3u8|mp4))"'),
    (m) => 'URI="$base/${m.group(1)}?t=$token"',
  );

  // Bare filename lines: the master playlist's "video.m3u8" reference, and
  // every segment line in a sub-playlist (video_1.m4s, ...).
  return rewritten.replaceAllMapped(
    RegExp(r'^([\w.-]+\.(?:m3u8|mp4|m4s))$', multiLine: true),
    (m) => '$base/${m.group(1)}?t=$token',
  );
}

/// Serves fMP4 bytes, honouring a single-range request.
///
/// AVPlayer is far stricter than ExoPlayer here: it issues byte-range
/// requests against fMP4 segments and expects a real Content-Length. The
/// original `Response.ok(file.openRead())` sent chunked encoding with no
/// length and ignored Range entirely, which surfaced on a real device as a
/// bare "Cannot Open". Every other handler in this server already sets
/// Content-Length explicitly; this one also has to answer Range.
Future<Response> _serveBytes(File file, String? rangeHeader) async {
  final length = await file.length();
  final range = _parseSingleByteRange(rangeHeader, length);

  if (range == null) {
    return Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': 'video/mp4',
        'Content-Length': '$length',
        'Accept-Ranges': 'bytes',
        'Cache-Control': 'no-store',
      },
    );
  }

  return Response(
    206, // Partial Content
    body: file.openRead(range.start, range.end + 1),
    headers: {
      'Content-Type': 'video/mp4',
      'Content-Length': '${range.end - range.start + 1}',
      'Content-Range': 'bytes ${range.start}-${range.end}/$length',
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'no-store',
    },
  );
}

/// Resolves a `Range: bytes=...` header into concrete inclusive offsets.
/// Returns null when the range should simply be ignored and the full body
/// served instead — RFC 7233 explicitly permits that for anything the
/// server chooses not to honour, which keeps this free of an unsatisfiable
/// 416 branch no real player exercises.
///
/// cases: "bytes=0-499" (closed) / "bytes=500-" (open end, to EOF) /
/// "bytes=-500" (SUFFIX — the last 500 bytes, not the first 500) /
/// suffix longer than the file / end past EOF (clamp) / multi-range /
/// non-numeric / absent header / start past EOF
({int start, int end})? _parseSingleByteRange(String? header, int length) {
  if (header == null || !header.startsWith('bytes=')) return null;

  final spec = header.substring(6).trim();
  if (spec.contains(',')) return null; // multi-range: serve the whole body
  final dash = spec.indexOf('-');
  if (dash < 0) return null;

  final rawStart = spec.substring(0, dash);
  final rawEnd = spec.substring(dash + 1);

  final int start;
  final int end;
  if (rawStart.isEmpty) {
    // Suffix form: "-N" means the LAST N bytes. Reading it as 0..N — which
    // a naive split('-') does — returns the wrong bytes, silently.
    final suffixLength = int.tryParse(rawEnd);
    if (suffixLength == null || suffixLength <= 0) return null;
    start = suffixLength >= length ? 0 : length - suffixLength;
    end = length - 1;
  } else {
    final parsedStart = int.tryParse(rawStart);
    if (parsedStart == null) return null;
    start = parsedStart;
    final parsedEnd = rawEnd.isEmpty ? length - 1 : int.tryParse(rawEnd);
    if (parsedEnd == null) return null;
    end = parsedEnd >= length ? length - 1 : parsedEnd;
  }

  if (start >= length || end < start) return null;
  return (start: start, end: end);
}
