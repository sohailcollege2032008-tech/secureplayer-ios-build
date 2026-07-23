import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart';

import '../../core/models/course_metadata.dart';
import '../../core/services/pdf_page_cache.dart';
import '../../features/auth/auth_providers.dart';
import '../../local_server/server_provider.dart';
import '../../security_layer/runtime_guard/security_guard_gate.dart';
import '../../security_layer/runtime_guard/security_runtime_guard_mixin.dart';
import '../../security_layer/watermark/bold_ghost_watermark_painter.dart';
import '../../security_layer/watermark/corner_watermark_painter.dart';
import '../../security_layer/watermark/secure_pdf_view.dart';
import '../../security_layer/watermark/tiled_watermark_painter.dart';
import '../../shared/html_file_viewer.dart';
import '../../app/theme.dart';

class FileViewerScreen extends ConsumerStatefulWidget {
  const FileViewerScreen({
    super.key,
    required this.lectureId,
    required this.fileId,
    required this.filename,
    required this.title,
    required this.mimeType,
    required this.fileIvMap,
    this.watermarkConfig = WatermarkConfig.off,
  });

  final String lectureId;
  final String fileId;
  final String filename;
  final String title;
  final String mimeType;
  final Map<String, String> fileIvMap;
  final WatermarkConfig watermarkConfig;

  bool get isEncrypted => fileIvMap.containsKey(fileId);
  bool get isPdf => mimeType.contains('pdf');
  bool get isImage => mimeType.startsWith('image/');
  bool get isHtml => mimeType.contains('html') || mimeType == 'text/html';

  @override
  ConsumerState<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends ConsumerState<FileViewerScreen>
    with WidgetsBindingObserver, SecurityRuntimeGuardMixin {
  // PDF state — SecurePdfViewPinch (pdfx-based) handles lazy per-page
  // texture rendering + pinch-zoom internally; we just own the underlying
  // PdfDocument for lifecycle (closing) and the last-read-page cache.
  PdfDocument? _pdfDoc;
  SecurePdfControllerPinch? _pdfController;
  int _currentPage = 1;
  String? _loadError;
  bool _pdfLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    startSecurityGuard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopSecurityGuard();
    if (_pdfDoc != null) {
      PdfPageCache.save(widget.lectureId, widget.fileId, _currentPage);
    }
    final docToClose = _pdfDoc;
    _pdfDoc = null;
    super.dispose(); // unmounts SecurePdfViewPinch's pages before closing doc
    docToClose?.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      notifyAppResumedForSecurity();
    }
  }

  /// Opens the PDF document from the shelf server. Page rendering (lazy,
  /// per-page textures + pinch-zoom) is handled by [SecurePdfViewPinch].
  Future<void> _initPdf(String url, String token) async {
    if (_pdfDoc != null || _pdfLoading) return;
    setState(() => _pdfLoading = true);
    try {
      final bytes = await _fetchBytes(url, token);
      if (!mounted) return;
      final doc = await PdfDocument.openData(bytes);
      if (!mounted) {
        await doc.close();
        return;
      }
      final cachedPage = await PdfPageCache.load(widget.lectureId, widget.fileId);
      _currentPage = cachedPage;
      if (!mounted) {
        await doc.close();
        return;
      }
      setState(() {
        _pdfDoc = doc;
        _pdfController = SecurePdfControllerPinch(
          document: Future.value(doc),
          initialPage: cachedPage,
        );
        _pdfLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load PDF: $e';
        _pdfLoading = false;
      });
    }
  }

  static Future<Uint8List> _fetchBytes(String url, String token) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Authorization', 'Bearer $token');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('Server returned ${response.statusCode}');
      }
      final builder = BytesBuilder();
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        foregroundColor: Colors.white,
        title: Text(
          widget.title.isNotEmpty ? widget.title : widget.filename,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
      body: SecurityGuardGate(
        child: widget.isEncrypted ? _buildEncryptedBody() : _buildLegacyBody(),
      ),
    );
  }

  Widget _buildEncryptedBody() {
    // This screen only ever shows files (PDF/image/HTML), never videos, so
    // the server-side watermark gate must follow applyToFiles — same fix
    // already applied to VideoPlaybackArgs in video_player_screen.dart.
    final args = VideoPlaybackArgs(
      lectureId: widget.lectureId,
      videoId: '',
      watermarkEnabled: widget.watermarkConfig.applyToFiles,
    );
    final serverAsync = ref.watch(videoServerProvider(args));
    return serverAsync.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppTheme.primary)),
      error: (e, _) => _errorView('Could not start secure server: $e'),
      data: (server) {
        final base = 'http://127.0.0.1:${server.port}'
            '/file/${widget.lectureId}/${widget.fileId}/${widget.filename}';
        final urlWithToken = '$base?t=${server.sessionToken}';

        if (_loadError != null) return _errorView(_loadError!);

        Widget content;
        if (widget.isPdf) {
          if (_pdfDoc == null) {
            if (!_pdfLoading) _initPdf(base, server.sessionToken);
            content = const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            );
          } else {
            content = _buildPdfView();
          }
        } else if (widget.isImage) {
          content = _buildNetworkImage(urlWithToken, server.sessionToken);
        } else if (widget.isHtml) {
          final htmlUrl = 'http://127.0.0.1:${server.port}'
              '/html/${widget.lectureId}/${widget.fileId}/${widget.filename}'
              '?t=${server.sessionToken}';
          content =
              HtmlFileViewer(url: htmlUrl, sessionToken: server.sessionToken);
        } else {
          content = _buildUnsupportedView();
        }

        return content;
      },
    );
  }

  /// pdfx-based lazy per-page texture rendering + pinch-zoom, with
  /// correctly-gated (applyToFiles) watermarking.
  Widget _buildPdfView() {
    return SecurePdfViewPinch(
      controller: _pdfController!,
      watermarkText: _getWatermarkText(),
      watermarkConfig: widget.watermarkConfig,
      onPageChanged: (page) {
        _currentPage = page;
        PdfPageCache.save(widget.lectureId, widget.fileId, page);
      },
    );
  }

  Widget _buildLegacyBody() {
    return _buildUnsupportedView();
  }

  String _getWatermarkText() {
    final profile = ref.watch(studentProfileProvider).valueOrNull;
    final name = profile?.name ?? '';
    final phone = profile?.phone ?? '';
    final email = profile?.email ?? '';

    final parts = <String>[];
    if (widget.watermarkConfig.showName && name.isNotEmpty) parts.add(name);
    if (widget.watermarkConfig.showPhone && phone.isNotEmpty) parts.add(phone);
    if (widget.watermarkConfig.showEmail && email.isNotEmpty) parts.add(email);
    final result = parts.join(' - ');
    if (result.isEmpty) return 'SECURE PLAYER';
    return result;
  }

  Widget _buildNetworkImage(String url, String token) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image.network(
              url,
              headers: {'Authorization': 'Bearer $token'},
              fit: BoxFit.contain,
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : const Center(
                      child:
                          CircularProgressIndicator(color: AppTheme.primary)),
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(Icons.broken_image_rounded,
                    color: Colors.white38, size: 64),
              ),
            ),
            if (widget.watermarkConfig.applyToFiles)
              if (widget.watermarkConfig.mode == WatermarkMode.boldGhost) ...[
                Positioned.fill(
                    child: IgnorePointer(
                        child: CustomPaint(
                  painter: BoldGhostWatermarkPainter(
                      text: _getWatermarkText(),
                      opacity: widget.watermarkConfig.opacity),
                ))),
                Positioned.fill(
                    child: IgnorePointer(
                        child: CustomPaint(
                  painter: CornerWatermarkPainter(
                      text: _getWatermarkText(),
                      opacity: widget.watermarkConfig.opacity),
                ))),
              ] else
                Positioned.fill(
                    child: IgnorePointer(
                        child: CustomPaint(
                  painter: TiledWatermarkPainter(
                      text: _getWatermarkText(),
                      opacity: widget.watermarkConfig.opacity,
                      fontSize: widget.watermarkConfig.fontSize),
                ))),
          ],
        ),
      ),
    );
  }

  Widget _buildUnsupportedView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_rounded,
              color: Colors.white38, size: 64),
          const SizedBox(height: 16),
          Text(widget.filename,
              style: const TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 8),
          const Text(
            'Preview not available for this file type.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _errorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Colors.redAccent, size: 48),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
