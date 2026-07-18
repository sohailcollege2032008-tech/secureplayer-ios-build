import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart'
    hide InteractiveViewer, TransformationController;
// ignore: implementation_imports
import 'package:pdfx/src/renderer/interfaces/document.dart';
// ignore: implementation_imports
import 'package:pdfx/src/renderer/interfaces/page.dart';
// ignore: implementation_imports
import 'package:pdfx/src/viewer/base/base_pdf_builders.dart';
// ignore: implementation_imports
import 'package:pdfx/src/viewer/base/base_pdf_controller.dart';
// ignore: implementation_imports
import 'package:pdfx/src/viewer/interactive_viewer.dart';
// ignore: implementation_imports
import 'package:pdfx/src/viewer/wrappers/pdf_texture.dart';
// ignore: depend_on_referenced_packages
import 'package:vector_math/vector_math_64.dart' as math64;

import '../../core/models/course_metadata.dart';
import 'bold_ghost_watermark_painter.dart';
import 'corner_watermark_painter.dart';
import 'tiled_watermark_painter.dart';

// ── Builders ─────────────────────────────────────────────────────────────────

typedef SecurePdfViewPinchBuilder<T> = Widget Function(
  BuildContext context,
  SecurePdfViewPinchBuilders<T> builders,
  PdfLoadingState state,
  WidgetBuilder loadedBuilder,
  PdfDocument? document,
  Exception? loadingError,
);

class SecurePdfViewPinchBuilders<T> {
  final WidgetBuilder? documentLoaderBuilder;
  final WidgetBuilder? pageLoaderBuilder;
  final Widget Function(BuildContext, Exception error)? errorBuilder;
  final SecurePdfViewPinchBuilder<T> builder;
  final T options;

  const SecurePdfViewPinchBuilders({
    required this.options,
    this.builder = _SecurePdfViewPinchState._builder,
    this.documentLoaderBuilder,
    this.pageLoaderBuilder,
    this.errorBuilder,
  });
}

// ── Controller ───────────────────────────────────────────────────────────────

class SecurePdfControllerPinch extends TransformationController
    with BasePdfController {
  SecurePdfControllerPinch({
    required this.document,
    this.initialPage = 1,
    this.viewportFraction = 1.0,
  }) : assert(viewportFraction > 0.0);

  @override
  final ValueNotifier<PdfLoadingState> loadingState =
      ValueNotifier(PdfLoadingState.loading);

  Future<PdfDocument> document;
  late int initialPage;
  int? _pendingInitialPage;

  int? get pendingInitialPage {
    final value = _pendingInitialPage;
    _pendingInitialPage = null;
    return value;
  }

  final double viewportFraction;

  _SecurePdfViewPinchState? _state;
  PdfDocument? _document;

  double _documentProgress = 0;
  double get documentProgress => _documentProgress;

  @override
  late final ValueNotifier<int> pageListenable = ValueNotifier(initialPage);

  @override
  int get page {
    MapEntry<int, double>? max;
    for (final v in visiblePages.entries) {
      if (max == null || max.value < v.value) {
        max = v;
      }
    }
    return max?.key ?? initialPage;
  }

  late int _prevPage = initialPage;

  @override
  int? get pagesCount => _document?.pagesCount;

  Rect? getPageRect(int pageNumber) => _state!._pages[pageNumber - 1].rect;

  Future<void> loadDocument(
    Future<PdfDocument> documentFuture, {
    int initialPage = 1,
  }) {
    loadingState.value = PdfLoadingState.loading;
    return _loadDocument(documentFuture, initialPage: initialPage);
  }

  Future<void> _loadDocument(
    Future<PdfDocument> documentFuture, {
    int initialPage = 1,
  }) async {
    assert(_state != null);

    try {
      _state?._releasePages();

      _document = await documentFuture;

      _state!._pages.clear();
      final List<_SecurePdfPageState> pages = [];
      final firstPage = await _document!.getPage(1, autoCloseAndroid: true);
      final firstPageSize = Size(
        firstPage.width,
        firstPage.height,
      );
      for (int i = 0; i < _document!.pagesCount; i++) {
        pages.add(_SecurePdfPageState._(
          pageNumber: i + 1,
          pageSize: firstPageSize,
        ));
      }
      _state!._firstControllerAttach = true;
      _state!._pages.addAll(pages);

      if (initialPage > 1) {
        _pendingInitialPage = initialPage;
      }

      loadingState.value = PdfLoadingState.success;
    } catch (error) {
      _state!._loadingError =
          error is Exception ? error : Exception('Unknown error');
      loadingState.value = PdfLoadingState.error;
    }
  }

  void _setViewerState(_SecurePdfViewPinchState? state) {
    _state = state;
    if (_state != null) {
      notifyListeners();
    }
  }

  void _attach(_SecurePdfViewPinchState pdfViewState) {
    if (_state != null) {
      return;
    }

    _state = pdfViewState;

    addListener(() {
      if (page != _prevPage) {
        _state!.widget.onPageChanged?.call(page);
        pageListenable.value = page;
        _prevPage = page;
      }
    });

    if (_document == null || _state!._pages.isEmpty) {
      _loadDocument(document, initialPage: initialPage);
    }
  }

  void jumpToPage(int page) => animateToPage(
        pageNumber: page + 1,
        duration: Duration.zero,
        curve: Curves.linear,
      );

  Future<void> goTo({
    Matrix4? destination,
    Duration duration = const Duration(milliseconds: 200),
    Curve curve = Curves.easeInOut,
  }) =>
      _state!._goTo(
        destination: destination,
        duration: duration,
        curve: curve,
      );

  Future<void> animateToPage({
    required int pageNumber,
    double? padding,
    Duration duration = const Duration(milliseconds: 500),
    Curve curve = Curves.easeInOut,
  }) {
    if (pageNumber < 1 || pageNumber > _document!.pagesCount) {
      return Future.value();
    }

    return goTo(
      destination: calculatePageFitMatrix(
        pageNumber: pageNumber,
        padding: padding,
      ),
      duration: duration,
    );
  }

  Future<void> nextPage({
    required Duration duration,
    required Curve curve,
  }) =>
      animateToPage(pageNumber: page + 1, duration: duration, curve: curve);

  Future<void> previousPage({
    required Duration duration,
    required Curve curve,
  }) =>
      animateToPage(pageNumber: page - 1, duration: duration, curve: curve);

  Rect get viewRect => Rect.fromLTWH(
        -value.row0[3],
        -value.row1[3],
        _state!._lastViewSize!.width,
        _state!._lastViewSize!.height,
      );

  double get zoomRatio => value.row0[0];

  Map<int, double> get visiblePages => _state!._visiblePages;

  Matrix4? calculatePageFitMatrix({required int pageNumber, double? padding}) {
    final rect = getPageRect(pageNumber)?.inflate(padding ?? _state!._padding);
    if (rect == null) {
      return null;
    }
    final scale = _state!._lastViewSize!.width / rect.width;
    final left = max(
        0.0,
        min(
          rect.left,
          _state!._docSize!.width - _state!._lastViewSize!.width,
        ));
    final top = max(
        0.0,
        min(
          rect.top,
          _state!._docSize!.height - _state!._lastViewSize!.height,
        ));
    return Matrix4.compose(
      math64.Vector3(-left, -top, 0),
      math64.Quaternion.identity(),
      math64.Vector3(scale, scale, 1),
    );
  }

  void _detach() {
    _state = null;
  }
}

enum _PdfPageLoadingStatus {
  notInitialized,
  initializing,
  initialized,
  pageLoading,
  pageLoaded,
  disposed
}

class _SecurePdfPageState {
  _SecurePdfPageState._({
    required this.pageNumber,
    required this.pageSize,
  });

  final int pageNumber;
  late final PdfPage pdfPage;
  Rect? rect;
  Size pageSize;
  PdfPageTexture? preview;
  // Windows has no native texture/SurfaceProducer support in pdfx (its
  // createTexture() throws UnimplementedError there) — the page is rendered
  // to bytes via PdfPage.render() instead and painted with Image.memory.
  Uint8List? previewImageBytes;
  Rect? realSizeOverlayRect;
  PdfPageTexture? realSize;
  bool isVisibleInsideView = false;
  _PdfPageLoadingStatus status = _PdfPageLoadingStatus.notInitialized;

  final _previewNotifier = ValueNotifier<int>(0);
  final _realSizeNotifier = ValueNotifier<int>(0);

  void updatePreview() {
    if (status != _PdfPageLoadingStatus.disposed) {
      _previewNotifier.value++;
    }
  }

  void _updateRealSizeOverlay() {
    if (status != _PdfPageLoadingStatus.disposed) {
      _realSizeNotifier.value++;
    }
  }

  bool releaseRealSize() {
    realSize?.dispose();
    realSize = null;
    return true;
  }

  bool releaseTextures() => _releaseTextures(_PdfPageLoadingStatus.initialized);

  bool _releaseTextures(_PdfPageLoadingStatus newStatus) {
    preview?.dispose();
    preview = null;
    previewImageBytes = null;
    releaseRealSize();
    status = newStatus;
    return true;
  }

  void dispose() {
    _releaseTextures(_PdfPageLoadingStatus.disposed);
    _previewNotifier.dispose();
    _realSizeNotifier.dispose();
  }
}

// ── Widget ───────────────────────────────────────────────────────────────────

class SecurePdfViewPinch extends StatefulWidget {
  const SecurePdfViewPinch({
    required this.controller,
    required this.watermarkText,
    required this.watermarkConfig,
    this.onPageChanged,
    this.onDocumentLoaded,
    this.onDocumentError,
    this.builders = const SecurePdfViewPinchBuilders<DefaultBuilderOptions>(
      options: DefaultBuilderOptions(),
    ),
    this.scrollDirection = Axis.vertical,
    this.padding = 10,
    this.minScale = 1.0,
    this.maxScale = 20.0,
    this.backgroundDecoration = const BoxDecoration(
      color: Color.fromARGB(255, 250, 250, 250),
      boxShadow: [
        BoxShadow(
          color: Color(0x73000000),
          blurRadius: 4,
          offset: Offset(2, 2),
        ),
      ],
    ),
    super.key,
  });

  final double padding;
  final double minScale;
  final double maxScale;
  final SecurePdfControllerPinch controller;
  final void Function(int page)? onPageChanged;
  final void Function(PdfDocument document)? onDocumentLoaded;
  final void Function(Object error)? onDocumentError;
  final SecurePdfViewPinchBuilders builders;
  final Axis scrollDirection;
  final BoxDecoration backgroundDecoration;

  final String watermarkText;
  final WatermarkConfig watermarkConfig;

  @override
  State<SecurePdfViewPinch> createState() => _SecurePdfViewPinchState();
}

class _SecurePdfViewPinchState extends State<SecurePdfViewPinch>
    with SingleTickerProviderStateMixin {
  SecurePdfControllerPinch get _controller => widget.controller;
  final List<_SecurePdfPageState> _pages = [];
  final List<_SecurePdfPageState> _pendedPageDisposes = [];
  Exception? _loadingError;
  Size? _lastViewSize;
  Timer? _realSizeUpdateTimer;
  Size? _docSize;
  final Map<int, double> _visiblePages = <int, double>{};

  late AnimationController _animController;
  Animation<Matrix4>? _animGoTo;

  bool _firstControllerAttach = true;
  bool _forceUpdatePagePreviews = true;

  double get _padding => widget.padding;
  double get _minScale => widget.minScale;
  double get _maxScale => widget.maxScale;

  @override
  void initState() {
    super.initState();
    _controller._attach(this);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    widget.controller.loadingState.addListener(() {
      switch (widget.controller.loadingState.value) {
        case PdfLoadingState.loading:
          _pages.clear();
          break;
        case PdfLoadingState.success:
          widget.onDocumentLoaded?.call(widget.controller._document!);
          break;
        case PdfLoadingState.error:
          widget.onDocumentError?.call(_loadingError!);
          break;
      }

      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _controller._detach();
    _cancelLastRealSizeUpdate();
    _releasePages();
    _handlePendedPageDisposes();
    _controller.removeListener(_determinePagesToShow);
    _animController.dispose();
    super.dispose();
  }

  void _releasePages() {
    if (_pages.isEmpty) {
      return;
    }
    for (final p in _pages) {
      p.releaseTextures();
    }
    _pendedPageDisposes.addAll(_pages);
    _pages.clear();
  }

  void _handlePendedPageDisposes() {
    for (final p in _pendedPageDisposes) {
      p.releaseTextures();
    }
    _pendedPageDisposes.clear();
  }

  Future<void> _goTo({
    Matrix4? destination,
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.easeInOut,
  }) async {
    try {
      if (destination == null) {
        return;
      }
      _animGoTo?.removeListener(_updateControllerMatrix);
      _animController.reset();
      _animGoTo = Matrix4Tween(begin: _controller.value, end: destination)
          .animate(_animController);
      _animGoTo!.addListener(_updateControllerMatrix);
      await _animController
          .animateTo(1.0, duration: duration, curve: curve)
          .orCancel;
    } on TickerCanceled {
      // expected
    }
  }

  void _updateControllerMatrix() {
    _controller.value = _animGoTo!.value;
  }

  void _reLayout(Size? viewSize) {
    if (_pages.isEmpty) {
      return;
    }
    _reLayoutDefault(viewSize!);
    _lastViewSize = viewSize;

    if (_firstControllerAttach) {
      _firstControllerAttach = false;

      Future.delayed(Duration.zero, () {
        _controller
          ..addListener(_determinePagesToShow)
          .._setViewerState(this);

        if (mounted) {
          final initialPage = _controller.initialPage;
          if (initialPage != 1) {
            final m =
                _controller.calculatePageFitMatrix(pageNumber: initialPage);
            if (m != null) {
              _controller.value = m;
            }
          }
          _forceUpdatePagePreviews = true;
          _determinePagesToShow();
        }
      });
      return;
    }

    _determinePagesToShow();
  }

  void _reLayoutDefault(Size viewSize) {
    final maxWidth = _pages.fold<double>(
        0.0, (maxWidth, page) => max(maxWidth, page.pageSize.width));
    final ratio = (viewSize.width - _padding * 2) / maxWidth;
    if (widget.scrollDirection == Axis.horizontal) {
      var left = _padding;
      for (int i = 0; i < _pages.length; i++) {
        final page = _pages[i];
        final w = page.pageSize.width * ratio;
        final h = page.pageSize.height * ratio;
        page.rect = Rect.fromLTWH(left, _padding, w, h);
        left += w + _padding;
      }
      _docSize = Size(left, viewSize.height);
    } else {
      var top = _padding;
      for (int i = 0; i < _pages.length; i++) {
        final page = _pages[i];
        final w = page.pageSize.width * ratio;
        final h = page.pageSize.height * ratio;
        page.rect = Rect.fromLTWH(_padding, top, w, h);
        top += h + _padding;
      }
      _docSize = Size(viewSize.width, top);
    }
  }

  static const _extraBufferAroundView = 150.0;

  void _determinePagesToShow() {
    if (_lastViewSize == null || _pages.isEmpty) {
      return;
    }

    Matrix4? m;
    final pendingInitialPage = _controller.pendingInitialPage;
    bool shouldNotifyPageChanged = false;
    if (pendingInitialPage != null) {
      m = _controller.calculatePageFitMatrix(pageNumber: pendingInitialPage);
      shouldNotifyPageChanged = true;
    }
    m ??= _controller.value;

    final r = m.row0[0];
    final exposed = Rect.fromLTWH(
        -m.row0[3], -m.row1[3], _lastViewSize!.width, _lastViewSize!.height);

    if (_lastViewSize?.height != null) {
      final rawDocumentProgress =
          ((exposed.bottom / r - _lastViewSize!.height) /
              (_docSize!.height - _lastViewSize!.height));
      const precisionFactor = 10000;
      _controller._documentProgress =
          ((rawDocumentProgress * precisionFactor).round() / precisionFactor)
              .clamp(0.0, 1.0);
    }

    var pagesToUpdate = 0;
    var changeCount = 0;
    _visiblePages.clear();
    for (final page in _pages) {
      if (page.rect == null) {
        page.isVisibleInsideView = false;
        continue;
      }
      final pageRectZoomed = Rect.fromLTRB(page.rect!.left * r,
          page.rect!.top * r, page.rect!.right * r, page.rect!.bottom * r);
      final part = pageRectZoomed.intersect(exposed);
      final isVisible = !part.isEmpty;
      if (isVisible) {
        _visiblePages[page.pageNumber] = part.width * part.height;
      }
      if (page.isVisibleInsideView != isVisible) {
        page.isVisibleInsideView = isVisible;
        changeCount++;
        if (isVisible) {
          pagesToUpdate++;
        }
      }
    }

    _cancelLastRealSizeUpdate();

    if (changeCount > 0) {
      _needReLayout();
    }
    if (pagesToUpdate > 0 || _forceUpdatePagePreviews) {
      _needPagePreviewGeneration();
    } else {
      _needRealSizeOverlayUpdate();
    }

    if (shouldNotifyPageChanged && pendingInitialPage != null) {
      widget.onPageChanged?.call(pendingInitialPage);
      _controller.pageListenable.value = pendingInitialPage;
    }
  }

  void _needReLayout() {
    Future.delayed(Duration.zero, () => setState(() {}));
  }

  void _needPagePreviewGeneration() {
    Future.delayed(Duration.zero, _updatePageState);
  }

  Future<void> _updatePageState() async {
    if (_pages.isEmpty) {
      return;
    }
    _forceUpdatePagePreviews = false;
    for (var i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      if (page.rect == null) {
        continue;
      }
      final m = _controller.value;
      final r = m.row0[0];
      final exposed = Rect.fromLTWH(-m.row0[3], -m.row1[3],
              _lastViewSize!.width, _lastViewSize!.height)
          .inflate(_extraBufferAroundView);

      final pageRectZoomed = Rect.fromLTRB(page.rect!.left * r,
          page.rect!.top * r, page.rect!.right * r, page.rect!.bottom * r);
      final part = pageRectZoomed.intersect(exposed);
      if (part.isEmpty) {
        continue;
      }

      if (page.status == _PdfPageLoadingStatus.notInitialized) {
        page
          ..status = _PdfPageLoadingStatus.initializing
          ..pdfPage = await _controller._document!.getPage(
            page.pageNumber,
            autoCloseAndroid: true,
          );
        final prevPageSize = page.pageSize;
        page
          ..pageSize = Size(page.pdfPage.width, page.pdfPage.height)
          ..status = _PdfPageLoadingStatus.initialized;
        if (prevPageSize != page.pageSize && mounted) {
          _reLayout(_lastViewSize);
          return;
        }
      }
      if (page.status == _PdfPageLoadingStatus.initialized) {
        page.status = _PdfPageLoadingStatus.pageLoading;
        if (Platform.isWindows) {
          await _renderWindowsPreview(page);
        } else {
          page.preview = await page.pdfPage.createTexture();
          final w = page.pdfPage.width;
          final h = page.pdfPage.height;

          await page.preview!.updateRect(
            documentId: _controller._document!.id,
            width: w.toInt(),
            height: h.toInt(),
            textureWidth: w.toInt(),
            textureHeight: h.toInt(),
            fullWidth: w,
            fullHeight: h,
            allowAntiAliasing: true,
            backgroundColor: '#ffffff',
          );
        }

        page
          ..status = _PdfPageLoadingStatus.pageLoaded
          ..updatePreview();
        // Yield to the event loop so frame rendering isn't blocked
        // between successive page texture uploads.
        await Future.delayed(Duration.zero);
      }
    }

    _needRealSizeOverlayUpdate();
  }

  // pdfx has no native texture/SurfaceProducer support on Windows —
  // PdfPage.createTexture() throws UnimplementedError there (upstream pdfx
  // source confirms Windows was never migrated to the Pigeon/SurfaceProducer
  // path used by iOS/macOS/Android). PdfPage.render() is a separate API that
  // IS implemented on Windows (FPDF_RenderPageBitmap over the native method
  // channel), so pages are rendered to bytes and painted with Image.memory
  // instead of PdfTexture. Rendered above the PDF's native point-size
  // resolution (devicePixelRatio + headroom) since there's no Windows
  // real-size-overlay tier to sharpen a pinch-zoomed view (see
  // _updateRealSizeOverlay's early return below).
  static const _windowsRenderMaxDimension = 2400.0;

  Future<void> _renderWindowsPreview(_SecurePdfPageState page) async {
    final dpr = View.of(context).devicePixelRatio;
    var w = page.pdfPage.width * dpr * 2.0;
    var h = page.pdfPage.height * dpr * 2.0;
    if (w > _windowsRenderMaxDimension || h > _windowsRenderMaxDimension) {
      final scale = _windowsRenderMaxDimension / max(w, h);
      w *= scale;
      h *= scale;
    }
    final image = await page.pdfPage.render(
      width: w,
      height: h,
      format: PdfPageImageFormat.png,
      backgroundColor: '#ffffff',
    );
    page.previewImageBytes = image?.bytes;
  }

  Future<void> _updateRealSizeOverlay() async {
    // No texture support on Windows at all (see _renderWindowsPreview), so
    // there's nothing to sharpen with a real-size overlay there — the base
    // preview is already rendered at headroom resolution instead.
    if (_pages.isEmpty || Platform.isWindows) {
      return;
    }

    const fullPurgeDistThreshold = 33;
    const partialRemovalDistThreshold = 8;

    final dpr = View.of(context).devicePixelRatio;
    final m = _controller.value;
    final r = m.row0[0];
    final exposed = Rect.fromLTWH(
        -m.row0[3], -m.row1[3], _lastViewSize!.width, _lastViewSize!.height);
    final distBase = max(_lastViewSize!.height, _lastViewSize!.width);
    for (var i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      if (page.rect == null ||
          page.status != _PdfPageLoadingStatus.pageLoaded) {
        continue;
      }
      final pageRectZoomed = Rect.fromLTRB(page.rect!.left * r,
          page.rect!.top * r, page.rect!.right * r, page.rect!.bottom * r);
      final part = pageRectZoomed.intersect(exposed);
      if (part.isEmpty) {
        final dist = (exposed.center - pageRectZoomed.center).distance;
        if (dist > distBase * fullPurgeDistThreshold) {
          page.releaseTextures();
        } else if (dist > distBase * partialRemovalDistThreshold) {
          page.releaseRealSize();
        }
        continue;
      }
      final fw = pageRectZoomed.width * dpr;
      final fh = pageRectZoomed.height * dpr;
      if (page.preview?.hasUpdatedTexture == true &&
          fw <= page.preview!.textureWidth! &&
          fh <= page.preview!.textureHeight!) {
        page.realSizeOverlayRect = null;
      } else {
        final offset = part.topLeft - pageRectZoomed.topLeft;
        page
          ..realSizeOverlayRect = Rect.fromLTWH(
            offset.dx / r,
            offset.dy / r,
            part.width / r,
            part.height / r,
          )
          ..realSize ??= await page.pdfPage.createTexture();
        final w = (part.width * dpr).toInt();
        final h = (part.height * dpr).toInt();
        await page.realSize!.updateRect(
          documentId: _controller._document!.id,
          width: w,
          height: h,
          sourceX: (offset.dx * dpr).toInt(),
          sourceY: (offset.dy * dpr).toInt(),
          textureWidth: w,
          textureHeight: h,
          fullWidth: fw,
          fullHeight: fh,
          allowAntiAliasing: true,
          backgroundColor: '#ffffff',
        );
        page._updateRealSizeOverlay();
      }
    }
  }

  void _cancelLastRealSizeUpdate() {
    if (_realSizeUpdateTimer != null) {
      _realSizeUpdateTimer!.cancel();
      _realSizeUpdateTimer = null;
    }
  }

  final _realSizeOverlayUpdateBufferDuration =
      const Duration(milliseconds: 100);

  void _needRealSizeOverlayUpdate() {
    _cancelLastRealSizeUpdate();
    _realSizeUpdateTimer =
        Timer(_realSizeOverlayUpdateBufferDuration, _updateRealSizeOverlay);
  }

  @override
  Widget build(BuildContext context) {
    return widget.builders.builder(
      context,
      widget.builders,
      _controller.loadingState.value,
      _buildLoaded,
      widget.controller._document,
      _loadingError,
    );
  }

  static Widget _builder(
    BuildContext context,
    SecurePdfViewPinchBuilders builders,
    PdfLoadingState state,
    WidgetBuilder loadedBuilder,
    PdfDocument? document,
    Exception? loadingError,
  ) {
    final Widget content = () {
      switch (state) {
        case PdfLoadingState.loading:
          return KeyedSubtree(
            key: const Key('pdfx.root.loading'),
            child: builders.documentLoaderBuilder?.call(context) ??
                const SizedBox(),
          );
        case PdfLoadingState.error:
          return KeyedSubtree(
            key: const Key('pdfx.root.error'),
            child: builders.errorBuilder?.call(context, loadingError!) ??
                Center(child: Text(loadingError.toString())),
          );
        case PdfLoadingState.success:
          return KeyedSubtree(
            key: Key('pdfx.root.success.${document!.id}'),
            child: loadedBuilder(context),
          );
      }
    }();

    final defaultBuilder =
        builders as SecurePdfViewPinchBuilders<DefaultBuilderOptions>;
    final options = defaultBuilder.options;

    return AnimatedSwitcher(
      duration: options.loaderSwitchDuration,
      transitionBuilder: options.transitionBuilder,
      child: content,
    );
  }

  Widget _buildLoaded(BuildContext context) {
    Future.microtask(_handlePendedPageDisposes);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        _reLayout(viewSize);
        final docSize = _docSize ?? const Size(10, 10);
        return InteractiveViewer(
          transformationController: _controller,
          scrollControls: InteractiveViewerScrollControls.scrollPans,
          constrained: false,
          alignPanAxis: false,
          boundaryMargin: _minScale < 1
              ? const EdgeInsets.all(double.infinity)
              : EdgeInsets.zero,
          minScale: _minScale,
          maxScale: _maxScale,
          panEnabled: true,
          scaleEnabled: true,
          child: Stack(
            children: <Widget>[
              SizedBox(width: docSize.width, height: docSize.height),
              ...iterateLaidOutPages(viewSize)
            ],
          ),
        );
      },
    );
  }

  Iterable<Widget> iterateLaidOutPages(Size viewSize) sync* {
    if (!_firstControllerAttach && _pages.isNotEmpty) {
      final m = _controller.value;
      final r = m.row0[0];
      final exposed =
          Rect.fromLTWH(-m.row0[3], -m.row1[3], viewSize.width, viewSize.height)
              .inflate(_padding);

      for (var i = 0; i < _pages.length; i++) {
        final page = _pages[i];
        if (page.rect == null) {
          continue;
        }
        final pageRectZoomed = Rect.fromLTRB(page.rect!.left * r,
            page.rect!.top * r, page.rect!.right * r, page.rect!.bottom * r);
        final part = pageRectZoomed.intersect(exposed);
        page.isVisibleInsideView = !part.isEmpty;
        if (!page.isVisibleInsideView) {
          continue;
        }

        yield Positioned(
          left: page.rect!.left,
          top: page.rect!.top,
          width: page.rect!.width,
          height: page.rect!.height,
          child: Container(
            width: page.rect!.width,
            height: page.rect!.height,
            decoration: widget.backgroundDecoration,
            child: Stack(
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: page._previewNotifier,
                  builder: (context, value, child) {
                    if (page.previewImageBytes != null) {
                      return Positioned.fill(
                        child: Image.memory(
                          page.previewImageBytes!,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                      );
                    }
                    return page.preview != null
                        ? Positioned.fill(
                            child: PdfTexture(textureId: page.preview!.id),
                          )
                        : Container();
                  },
                ),
                ValueListenableBuilder<int>(
                  valueListenable: page._realSizeNotifier,
                  builder: (context, value, child) =>
                      page.realSizeOverlayRect != null && page.realSize != null
                          ? Positioned(
                              left: page.realSizeOverlayRect!.left,
                              top: page.realSizeOverlayRect!.top,
                              width: page.realSizeOverlayRect!.width,
                              height: page.realSizeOverlayRect!.height,
                              child: PdfTexture(textureId: page.realSize!.id),
                            )
                          : Container(),
                ),
                // Watermark drawn directly on each page.
                // Mode is driven by metadata.json watermarkConfig.mode.
                if (widget.watermarkConfig.applyToFiles)
                  if (widget.watermarkConfig.mode ==
                      WatermarkMode.boldGhost) ...[
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: BoldGhostWatermarkPainter(
                            text: widget.watermarkText,
                            opacity: widget.watermarkConfig.opacity,
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: CornerWatermarkPainter(
                            text: widget.watermarkText,
                            opacity: widget.watermarkConfig.opacity,
                          ),
                        ),
                      ),
                    ),
                  ] else
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: TiledWatermarkPainter(
                            text: widget.watermarkText,
                            opacity: widget.watermarkConfig.opacity,
                            fontSize: widget.watermarkConfig.fontSize,
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        );
      }
    }
  }
}
