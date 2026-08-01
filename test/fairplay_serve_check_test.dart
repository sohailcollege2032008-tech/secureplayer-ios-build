// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
//
// Printing IS the point here — this harness reports each check to stdout.
// Live end-to-end check of the FairPlay static route against a real .secfp.
//
// Runs the ACTUAL production handler (buildShelfHandler) over a real
// extracted package and exercises it the way AVPlayer does: fetch the master
// playlist, follow it to the variant playlist, follow that to the init
// segment and media segments, including a byte-range request. Everything in
// this path had previously only been reasoned about or unit-tested in
// isolation — the server itself was never once run.
//
// Usage:
//   dart run tool/fairplay_serve_check.dart <path-to.secfp>

import 'dart:convert';
import 'dart:io';

import 'package:secure_player/local_server/shelf_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:flutter_test/flutter_test.dart';

const _token = 'testtoken';
var _failures = 0;

void check(bool ok, String label, [String detail = '']) {
  if (ok) {
    print('  PASS  $label');
  } else {
    _failures++;
    print('  FAIL  $label${detail.isEmpty ? '' : '\n          $detail'}');
  }
}

void main() {
  test('FairPlay static route serves a real .secfp end to end', () async {
    final args = [const String.fromEnvironment('SECFP')];
    await _run(args);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _run(List<String> args) async {
  if (args.isEmpty) {
    fail('pass --dart-define=SECFP=<path>');
  }

  final tmp = await Directory.systemTemp.createTemp('fpcheck_');
  final appDocuments = tmp.path;

  // Mirror exactly what FairplayImporter produces on device:
  //   {appDocuments}/fairplay_lectures/{lectureId}/{metadata.json, videos/...}
  final unzipRoot = Directory('$appDocuments/unzip')..createSync(recursive: true);
  // Expand-Archive refuses any extension other than .zip, so hand it a copy.
  final asZip = '$appDocuments/package.zip';
  File(args[0]).copySync(asZip);
  final unzip = await Process.run(
    'powershell',
    ['-NoProfile', '-Command',
     "Expand-Archive -LiteralPath '$asZip' -DestinationPath '${unzipRoot.path}' -Force"],
  );
  if (unzip.exitCode != 0) {
    stderr.writeln('unzip failed: ${unzip.stderr}');
    exit(1);
  }

  final metadata =
      jsonDecode(File('${unzipRoot.path}/metadata.json').readAsStringSync())
          as Map<String, dynamic>;
  final lectureId = metadata['lecture_id'] as String;
  final videoId = (metadata['videos'] as List).first['id'] as String;

  final lectureDir = Directory('$appDocuments/fairplay_lectures/$lectureId');
  lectureDir.createSync(recursive: true);
  await Process.run('powershell', [
    '-NoProfile', '-Command',
    "Copy-Item -Path '${unzipRoot.path}\\*' -Destination '${lectureDir.path}' -Recurse -Force"
  ]);

  print('lecture=$lectureId video=$videoId');

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  shelf_io.serveRequests(
    server,
    buildShelfHandler(
      lectureId: lectureId,
      actualPort: port,
      lectureDir: '$appDocuments/courses/$lectureId',
      keyHex: '0' * 32,
      deviceId: 'testdevice',
      appDocPath: appDocuments,
      sessionToken: _token,
      appDocumentsPath: appDocuments,
    ),
  );

  final client = HttpClient();
  Future<HttpClientResponse> get(String path, {String? range}) async {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    if (range != null) req.headers.set('range', range);
    return req.close();
  }

  final base = '/fairplay/$lectureId/$videoId';

  print('\n[1] master.m3u8');
  final master = await get('$base/master.m3u8?t=$_token');
  final masterBody = await master.transform(utf8.decoder).join();
  check(master.statusCode == 200, 'HTTP 200', 'got ${master.statusCode}');
  check(masterBody.contains('http://127.0.0.1:$port$base/video.m3u8?t=$_token'),
      'variant URL absolutized');

  print('\n[2] auth is enforced');
  final noAuth = await get('$base/master.m3u8');
  check(noAuth.statusCode == 403, 'rejects missing token', 'got ${noAuth.statusCode}');
  final badAuth = await get('$base/master.m3u8?t=wrong');
  check(badAuth.statusCode == 403, 'rejects wrong token', 'got ${badAuth.statusCode}');

  print('\n[3] path traversal blocked');
  final trav = await get('/fairplay/$lectureId/$videoId/..%2F..%2Fmetadata.json?t=$_token');
  check(trav.statusCode == 403 || trav.statusCode == 404,
      'traversal refused', 'got ${trav.statusCode}');

  print('\n[4] variant playlist + key URI untouched');
  final variant = await get('$base/video.m3u8?t=$_token');
  final variantBody = await variant.transform(utf8.decoder).join();
  check(variant.statusCode == 200, 'HTTP 200', 'got ${variant.statusCode}');
  check(variantBody.contains('URI="skd://'), 'skd:// key URI preserved');
  check(!variantBody.contains('skd://') || !RegExp(r'URI="skd://[^"]*\?t=').hasMatch(variantBody),
      'skd:// NOT given a token');
  check(variantBody.contains('#EXT-X-MAP:URI="http://127.0.0.1:$port$base/'),
      'init segment absolutized');

  // Every media line must be a fetchable absolute URL.
  final segmentUrls = RegExp(r'^http://127\.0\.0\.1:\d+/fairplay/\S+$', multiLine: true)
      .allMatches(variantBody)
      .map((m) => m.group(0)!)
      .toList();
  check(segmentUrls.isNotEmpty, 'segment lines absolutized (${segmentUrls.length} found)');

  print('\n[5] init segment + media segments fetch');
  final mapUri = RegExp(r'#EXT-X-MAP:URI="([^"]+)"').firstMatch(variantBody)?.group(1);
  if (mapUri != null) {
    final initRes = await get(Uri.parse(mapUri).path + '?t=$_token');
    final initBytes = await initRes.fold<int>(0, (n, c) => n + c.length);
    check(initRes.statusCode == 200, 'init segment HTTP 200', 'got ${initRes.statusCode}');
    check(initBytes > 0, 'init segment has bytes ($initBytes)');
    check(initRes.headers.value('content-length') == '$initBytes',
        'Content-Length matches body',
        'header=${initRes.headers.value('content-length')} actual=$initBytes');
  }

  for (final url in segmentUrls.take(3)) {
    final u = Uri.parse(url);
    final res = await get('${u.path}?t=$_token');
    final bytes = await res.fold<int>(0, (n, c) => n + c.length);
    check(res.statusCode == 200 && bytes > 0,
        'segment ${u.pathSegments.last} (${res.statusCode}, $bytes bytes)');
  }

  print('\n[6] byte-range (AVPlayer relies on this)');
  final firstSeg = Uri.parse(segmentUrls.first).path;
  final ranged = await get('$firstSeg?t=$_token', range: 'bytes=0-99');
  final rangedBytes = await ranged.fold<int>(0, (n, c) => n + c.length);
  check(ranged.statusCode == 206, 'HTTP 206', 'got ${ranged.statusCode}');
  check(rangedBytes == 100, 'returned exactly 100 bytes', 'got $rangedBytes');
  check(ranged.headers.value('content-range')?.startsWith('bytes 0-99/') ?? false,
      'Content-Range correct', 'got ${ranged.headers.value('content-range')}');

  final full = await get('$firstSeg?t=$_token');
  final fullLen = await full.fold<int>(0, (n, c) => n + c.length);
  final suffix = await get('$firstSeg?t=$_token', range: 'bytes=-50');
  final suffixBytes = await suffix.fold<int>(0, (n, c) => n + c.length);
  check(suffix.statusCode == 206 && suffixBytes == 50,
      'suffix range returns last 50 bytes',
      'status=${suffix.statusCode} bytes=$suffixBytes');
  check(suffix.headers.value('content-range') == 'bytes ${fullLen - 50}-${fullLen - 1}/$fullLen',
      'suffix Content-Range points at the END of the file',
      'got ${suffix.headers.value('content-range')}');

  print('\n${_failures == 0 ? "ALL CHECKS PASSED" : "*** $_failures CHECK(S) FAILED ***"}');
  client.close();
  await server.close(force: true);
  tmp.deleteSync(recursive: true);
  expect(_failures, 0, reason: 'see FAIL lines above');
}
