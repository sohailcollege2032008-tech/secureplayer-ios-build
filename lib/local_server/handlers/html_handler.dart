import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import '../decryption/aes_decryptor.dart';

/// GET /html/:lectureId/:fileId/:filename
///
/// Decrypts an AES-128-CBC encrypted HTML file, injects a server-side
/// watermark overlay + anti-selection CSS, and returns it with a strict
/// Content-Security-Policy that blocks all external network requests.
///
/// Auth: Bearer token in Authorization header OR ?t= query param.
/// Watermark text: supplied as a server-side closure parameter — NOT from
/// the URL query string. Android WebView normalises %25 → %, corrupting
/// percent-encoded values in query params when a name contains '%'.
/// Size guard: files > 10 MB are served as-is (no injection) to avoid OOM.
Future<Response> htmlHandler(
  String lectureId,
  String fileId,
  String filename,
  String keyHex,
  Map<String, String> fileIvMap,
  String appDocPath,
  String watermarkText,
) async {
  try {
    if (_hasPathTraversal(filename) ||
        _hasPathTraversal(fileId) ||
        _hasPathTraversal(lectureId)) {
      return Response.forbidden('Invalid path');
    }

    // Empty string = watermark disabled; don't fall back to 'SECURE PLAYER'.
  final wmText = watermarkText;
    final ivHex = fileIvMap[fileId];

    final primaryPath = '$appDocPath/courses/$lectureId/files/$fileId';
    final fallbackPath = '$appDocPath/courses/$lectureId/$fileId';
    final file = File(primaryPath).existsSync()
        ? File(primaryPath)
        : File(fallbackPath).existsSync()
            ? File(fallbackPath)
            : null;
    if (file == null) return Response.notFound('File not found: $filename');

    final Uint8List decrypted;
    if (ivHex == null) {
      decrypted = await file.readAsBytes();
    } else {
      final encryptedBytes = await file.readAsBytes();
      final key = AesDecryptor.hexToBytes(keyHex);
      final iv = AesDecryptor.hexToBytes(ivHex);
      decrypted = await Isolate.run(() => AesDecryptor.decrypt(
            encryptedBytes: encryptedBytes,
            key: key,
            iv: iv,
            segmentName: filename,
          ));
    }

    final Uint8List responseBytes;
    if (decrypted.length > 10 * 1024 * 1024) {
      // Too large to inject safely — serve raw
      responseBytes = decrypted;
    } else {
      final htmlStr = utf8.decode(decrypted, allowMalformed: true);
      final injected = _injectWatermark(htmlStr, wmText);
      responseBytes = Uint8List.fromList(utf8.encode(injected));
    }
    // wmText is empty when watermark is disabled — overlay is skipped in _injectWatermark.

    return Response.ok(
      responseBytes,
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Length': '${responseBytes.length}',
        'Cache-Control': 'no-store, no-cache, max-age=0',
        // Blocks all external fetch/XHR; allows inline scripts/styles for
        // educational HTML that commonly uses inline JS/CSS.
        'Content-Security-Policy':
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: blob:; "
            "connect-src 'none'; "
            "frame-src 'none'; "
            "object-src 'none';",
      },
    );
  } on FileSystemException {
    return Response.notFound('File missing: $filename');
  } catch (e) {
    return Response.internalServerError(body: 'HTML error: $e');
  }
}

/// Injects anti-selection CSS/JS (always) and watermark overlay (only when
/// [wmText] is non-empty) before </body>. Falls back to appending at end.
String _injectWatermark(String html, String wmText) {
  final safe = wmText
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  // Watermark overlay div — omitted when watermark is disabled (wmText empty).
  final overlayStyle = wmText.isNotEmpty
      ? '''
#__sp_wm{position:fixed;inset:0;pointer-events:none;z-index:2147483647;overflow:hidden}
#__sp_wm span{position:absolute;white-space:nowrap;font-size:14px;
font-weight:700;color:rgba(0,0,0,0.4);transform:rotate(-30deg);
font-family:-apple-system,BlinkMacSystemFont,Arial,sans-serif}'''
      : '';

  final overlayDiv = wmText.isNotEmpty
      ? '''
<div id="__sp_wm">
<span style="top:8%;left:5%">$safe</span>
<span style="top:35%;left:42%">$safe</span>
<span style="top:62%;left:18%">$safe</span>
<span style="top:85%;left:60%">$safe</span>
</div>'''
      : '';

  final adaptColorScript = wmText.isNotEmpty
      ? '''
  function lum(r,g,b){return 0.299*r+0.587*g+0.114*b;}
  function getBg(){
    var s=window.getComputedStyle(document.body).backgroundColor;
    if(!s||s==='transparent'||s==='rgba(0, 0, 0, 0)')
      s=window.getComputedStyle(document.documentElement).backgroundColor;
    return s||'rgb(255,255,255)';
  }
  function update(){
    var m=getBg().match(/\\d+/g);
    if(!m)return;
    var c=lum(+m[0],+m[1],+m[2])>100?'rgba(0,0,0,0.4)':'rgba(255,255,255,0.4)';
    var spans=document.querySelectorAll('#__sp_wm span');
    for(var i=0;i<spans.length;i++)spans[i].style.color=c;
  }
  update();
  setInterval(update,600);'''
      : '';

  final inject = '''
<style id="__sp_wm_style">
html,body{-webkit-user-select:none!important;user-select:none!important}$overlayStyle
</style>$overlayDiv
<script>
(function(){
  var p=function(e){e.preventDefault();return false;};
  document.addEventListener('contextmenu',p,true);
  document.addEventListener('selectstart',p,true);
  document.addEventListener('copy',p,true);
$adaptColorScript})();
</script>''';

  final match = RegExp(r'</body\s*>', caseSensitive: false).firstMatch(html);
  if (match != null) {
    return html.substring(0, match.start) + inject + html.substring(match.start);
  }
  return html + inject;
}

bool _hasPathTraversal(String s) =>
    s.contains('/') || s.contains('\\') || s.contains('..');
