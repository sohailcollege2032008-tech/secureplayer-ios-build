import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:win32/win32.dart'
    show
        GetForegroundWindow,
        GetSystemMetrics,
        GetWindowLongPtr,
        SetWindowLongPtr,
        SetWindowPos,
        GWL_STYLE,
        WS_CAPTION,
        WS_THICKFRAME,
        SWP_FRAMECHANGED,
        SWP_NOACTIVATE,
        HWND_TOP;

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/course_metadata.dart';
import '../../core/models/quiz.dart';
import '../../core/services/pdf_page_cache.dart';
import '../../features/auth/auth_providers.dart';
import '../../features/quiz/quiz_provider.dart';
import '../../local_server/server_provider.dart';
import '../../security_layer/runtime_guard/security_guard_gate.dart';
import '../../security_layer/runtime_guard/security_guard_state.dart';
import '../../security_layer/runtime_guard/security_runtime_guard_mixin.dart';
import '../../security_layer/runtime_guard/security_runtime_guard_service.dart';
import '../../security_layer/watermark/secure_pdf_view.dart';
import '../../security_layer/watermark/watermark_overlay.dart';
import '../../shared/html_file_viewer.dart';
import '../../app/theme.dart';

class VideoPlayerScreen extends ConsumerStatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.lectureId,
    required this.videoId,
    required this.title,
    this.watermarkConfig = WatermarkConfig.off,
    this.initialAspectRatio,
  });

  final String lectureId;
  final String videoId;
  final String title;
  final WatermarkConfig watermarkConfig;
  // Real aspect ratio computed via ffprobe at encryption time (metadata.json
  // videos[].width/height). Null for legacy .sec files predating this field —
  // those fall back to runtime auto-detection via _videoAspectRatio.
  final double? initialAspectRatio;

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen>
    with WidgetsBindingObserver, SecurityRuntimeGuardMixin {
  // ── Player ────────────────────────────────────────────────────────────────
  BetterPlayerController? _controller;
  // Windows-only media_kit player (better_player does not work on Windows)
  Player? _mkPlayer;
  VideoController? _mkCtrl;
  // media_kit's Player.dispose()/open()/stop() all share one internal lock
  // per Player instance — if a screen is exited while its initial open() is
  // still buffering, our (necessarily unawaited, since State.dispose() is
  // sync) dispose() call gets queued behind that open() and doesn't actually
  // stop native playback until open() finishes on its own, sometimes several
  // seconds later. Meanwhile a fresh Player() for a re-opened video starts
  // immediately and is fully independent, so both play at once. Tracking the
  // in-flight teardown here (class-level — a new State instance from
  // re-navigating has no other way to see the old one's pending Future) lets
  // _initPlayer() await it before creating a new Player, serializing
  // teardown-then-start instead of letting them overlap.
  static Future<void>? _pendingWindowsPlayerTeardown;
  int _savedPositionMs = 0;
  String? _playerErrorMessage;
  bool _adbWarningShown = false;
  Timer? _progressTimer;
  // Loaded from disk on init so popups don't re-fire on re-entry.
  final Set<String> _triggeredPopupIds = {};

  // ── File panel ────────────────────────────────────────────────────────────
  List<LectureFile> _files = [];
  int _selectedFileIdx = 0;
  bool _filePanelOpen = false; // landscape overlay toggle
  // PDF docs: each file.id → open PdfDocument (kept for lifecycle/closing).
  // Rendering itself (lazy per-page textures + pinch-zoom) is owned by
  // SecurePdfViewPinch via a matching SecurePdfControllerPinch per file.id —
  // switching which controller is shown (keyed by file.id) forces correct
  // widget/state recreation per file, fixing the old bare-ListView glitch
  // where only one file's pages would ever render.
  final Map<String, PdfDocument> _pdfDocs = {};
  final Map<String, SecurePdfControllerPinch> _pdfControllers = {};
  final Map<String, bool> _pdfLoadingMap = {};
  final Map<String, double> _pdfProgressMap = {};
  Map<String, String> _fileIvMap = {};
  String _courseDir = '';

  // ── Custom controls ───────────────────────────────────────────────────────
  bool _controlsVisible = true;
  Timer? _controlsHideTimer;
  double _playbackSpeed = 1.0;
  bool _isDraggingSeek = false;
  Duration? _dragSeekPosition;
  String? _seekFeedbackMsg;
  Timer? _seekFeedbackTimer;
  bool _seekFeedbackLeft = false;
  // Playback state kept in our own vars so we never touch a disposed controller.
  bool _isPlaying = false;
  Duration _videoPosition = Duration.zero;
  Duration _videoDuration = Duration.zero;
  bool _isFullscreen = false;
  // Real aspect ratio of the currently-loaded video (set once known); falls
  // back to 16:9 until then. Replaces a hardcoded 16:9 that squashed/
  // letterboxed videos shot in other ratios (e.g. vertical "shorts").
  double? _videoAspectRatio;
  // Tracks the device orientation from the previous build so a fullscreen
  // toggle is only auto-applied on the EDGE of a rotation, not recomputed
  // continuously — otherwise manually exiting fullscreen while the device
  // is still physically landscape gets immediately overridden back to
  // fullscreen just because isLandscape is still true.
  Orientation? _lastOrientation;
  // Suppresses the auto-fullscreen-on-rotation edge detector for a moment
  // after a manual toggle. _toggleFullscreen() briefly forces portraitUp
  // then releases back to all 4 orientations; on a physically-landscape
  // device the sensor then reports landscape again, which would otherwise
  // look like a fresh user rotation and immediately re-engage fullscreen.
  bool _suppressAutoFullscreen = false;

  // Windows fullscreen state
  int _winSavedHwnd = 0;
  int _winSavedStyle = 0;

  VideoPlaybackArgs get _args => VideoPlaybackArgs(
        lectureId: widget.lectureId,
        videoId: widget.videoId,
        watermarkEnabled: widget.watermarkConfig.applyToFiles,
      );

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Seed from the pre-computed metadata.json value (baked in at encryption
    // time via ffprobe) BEFORE the player is even created, so the outer
    // AspectRatio box is correctly shaped from the very first frame — not
    // just once BetterPlayer/media_kit fires its own "initialized" event.
    // Legacy .sec files without this field fall back to runtime detection.
    _videoAspectRatio = widget.initialAspectRatio;
    WidgetsBinding.instance.addObserver(this);
    startSecurityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadSavedPosition();
      await _loadFiles();
      await _loadTriggeredPopups();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopSecurityGuard();
    _progressTimer?.cancel();
    _controlsHideTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _savePosition();
    // Undo any orientation lock this screen applied (entering fullscreen
    // restricts to landscape-only). Without this, leaving the screen while
    // still in fullscreen/landscape traps every other screen in landscape
    // too, since main.dart's app-wide default (all 4 orientations, sensor
    // decides) never gets restored.
    if (Platform.isAndroid) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      // Same reasoning as the orientation restore above — leaving the
      // screen while still in fullscreen must not leave the status bar
      // hidden for every other screen in the app.
      _applyAndroidSystemUiMode(false);
    }
    // Null our reference first so in-flight timer/event callbacks bail early.
    final ctrl = _controller;
    _controller = null;
    ctrl?.removeEventsListener(_onPlayerEvent);
    // Defer the actual dispose() to the next microtask so that Flutter's widget
    // tree teardown can first call _BetterPlayerState.dispose() — which removes
    // its WidgetsBindingObserver — before we release the VideoPlayerController.
    // This prevents a race where a lifecycle event fires between our dispose()
    // call and _BetterPlayerState removing its observer, hitting a disposed
    // VideoPlayerController. forceDispose:true is required because we set
    // autoDispose:false in the configuration above.
    Future.microtask(() => ctrl?.dispose(forceDispose: true));
    _disposeWindowsPlayer();
    final docsToClose = Map<String, PdfDocument>.from(_pdfDocs);
    final controllersToDispose =
        Map<String, SecurePdfControllerPinch>.from(_pdfControllers);
    _pdfDocs.clear();
    _pdfControllers.clear();
    super.dispose(); // unmounts SecurePdfViewPinch's pages before closing docs
    for (final controller in controllersToDispose.values) {
      controller.dispose();
    }
    for (final doc in docsToClose.values) {
      doc.close();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (Platform.isWindows) {
        _mkPlayer?.pause();
      } else {
        _controller?.pause();
      }
    } else if (state == AppLifecycleState.resumed) {
      notifyAppResumedForSecurity();
    }
  }

  // ── File loading ──────────────────────────────────────────────────────────

  Future<void> _loadFiles() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final metaFile =
          File('${appDir.path}/courses/${widget.lectureId}/metadata.json');
      if (!await metaFile.exists()) return;
      final meta =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      _courseDir = '${appDir.path}/courses/${widget.lectureId}';
      final rawIvMap = meta['file_iv_map'] as Map<String, dynamic>? ?? {};
      _fileIvMap = rawIvMap.map((k, v) => MapEntry(k, v as String));
      final rawFiles = meta['files'] as List? ?? [];
      final files = rawFiles
          .map((f) => LectureFile.fromJson(f as Map<String, dynamic>))
          .where(
              (f) => f.videoIds.isEmpty || f.videoIds.contains(widget.videoId))
          .toList();
      if (mounted) setState(() => _files = files);
    } catch (_) {}
  }

  Future<void> _switchFile(int idx) async {
    if (idx == _selectedFileIdx) return;
    if (mounted) setState(() => _selectedFileIdx = idx);
  }

  // ── Position save/load ────────────────────────────────────────────────────

  Future<File> get _positionFile async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(
        '${appDir.path}/courses/${widget.lectureId}/videos/${widget.videoId}');
    return File('${dir.path}/last_position.json');
  }

  Future<void> _loadSavedPosition() async {
    try {
      final f = await _positionFile;
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map;
        _savedPositionMs = (data['position_ms'] as int?) ?? 0;
      }
    } catch (_) {}
  }

  // Loads which popup quizzes have already fired (persisted across sessions).
  Future<void> _loadTriggeredPopups() async {
    try {
      final f = await _positionFile;
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map;
        final ids = data['triggered_popup_ids'] as List?;
        if (ids != null) _triggeredPopupIds.addAll(ids.cast<String>());
      }
    } catch (_) {}
  }

  // Called immediately when a popup is triggered — prevents re-fire on re-entry.
  Future<void> _persistTriggeredPopup(String quizId) async {
    _triggeredPopupIds.add(quizId);
    try {
      final f = await _positionFile;
      await f.parent.create(recursive: true);
      final Map<String, dynamic> data;
      if (await f.exists()) {
        data = Map<String, dynamic>.from(
            jsonDecode(await f.readAsString()) as Map);
      } else {
        data = {};
      }
      data['triggered_popup_ids'] = _triggeredPopupIds.toList();
      await f.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _savePosition() async {
    try {
      final pos = Platform.isWindows
          ? _mkPlayer?.state.position
          : _controller?.videoPlayerController?.value.position;
      if (pos != null && pos.inMilliseconds > 0) {
        final f = await _positionFile;
        await f.parent.create(recursive: true);
        // Preserve triggered_popup_ids when updating position.
        final Map<String, dynamic> data;
        if (await f.exists()) {
          data = Map<String, dynamic>.from(
              jsonDecode(await f.readAsString()) as Map);
        } else {
          data = {};
        }
        data['position_ms'] = pos.inMilliseconds;
        data['triggered_popup_ids'] = _triggeredPopupIds.toList();
        await f.writeAsString(jsonEncode(data));
      }
    } catch (_) {}
  }

  // ── Player init ───────────────────────────────────────────────────────────

  void _initPlayer(String hlsUrl, String sessionToken) {
    if (!mounted) return;
    if (Platform.isWindows && _mkCtrl != null) return;
    if (!Platform.isWindows && _controller != null) return;

    // ── Windows: media_kit ────────────────────────────────────────────────
    if (Platform.isWindows) {
      final pending = _pendingWindowsPlayerTeardown;
      if (pending != null) {
        pending.whenComplete(() {
          if (mounted && _mkPlayer == null) {
            _startWindowsPlayer(hlsUrl, sessionToken);
          }
        });
      } else {
        _startWindowsPlayer(hlsUrl, sessionToken);
      }
      return;
    }

    // ── Android: better_player ────────────────────────────────────────────
    _initAndroidPlayer(hlsUrl, sessionToken);
  }

  void _startWindowsPlayer(String hlsUrl, String sessionToken) {
    if (!mounted || _mkPlayer != null) return;
    final player = Player();
    _mkPlayer = player;
    _mkCtrl = VideoController(player);
    player
        .open(Media(hlsUrl,
            httpHeaders: {'Authorization': 'Bearer $sessionToken'}))
        .then((_) async {
      if (!mounted) return;
      if (_savedPositionMs > 0) {
        await _mkPlayer!.seek(Duration(milliseconds: _savedPositionMs));
      }
    });
    _mkPlayer!.stream.position.listen((pos) {
      if (!mounted || _isDraggingSeek) return;
      setState(() {
        _videoPosition = pos;
        _videoDuration = _mkPlayer!.state.duration;
        _isPlaying = _mkPlayer!.state.playing;
      });
      _checkMkQuizTrigger(pos);
    });
    // Use the video's real dimensions instead of a hardcoded 16:9 so
    // vertical/"short"-style videos aren't squashed into widescreen. Same
    // precomputed-value-wins rule as the BetterPlayer path below — only
    // used as a fallback for legacy .sec files.
    _mkPlayer!.stream.width.listen((w) {
      final h = _mkPlayer!.state.height;
      if (widget.initialAspectRatio == null &&
          mounted &&
          w != null &&
          h != null &&
          h > 0) {
        setState(() => _videoAspectRatio = w / h);
      }
    });
    setState(() {});
  }

  // Starts (and tracks) tearing down the current media_kit Player, if any.
  // Always route Windows player teardown through here — see the comment on
  // _pendingWindowsPlayerTeardown for why a bare `_mkPlayer?.dispose()` isn't
  // enough to guarantee the old native player actually stops before a new
  // one can start.
  void _disposeWindowsPlayer() {
    final playerToDispose = _mkPlayer;
    _mkPlayer = null;
    _mkCtrl = null;
    if (playerToDispose != null) {
      _pendingWindowsPlayerTeardown =
          playerToDispose.dispose().catchError((_) {});
    }
  }

  void _initAndroidPlayer(String hlsUrl, String sessionToken) {
    final dataSource = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      hlsUrl,
      videoFormat: BetterPlayerVideoFormat.hls,
      headers: {'Authorization': 'Bearer $sessionToken'},
    );

    _controller = BetterPlayerController(
      BetterPlayerConfiguration(
        autoPlay: true,
        looping: false,
        allowedScreenSleep: false,
        fullScreenByDefault: false,
        // Pass the pre-computed real aspect ratio straight in when known
        // (from metadata.json, baked in via ffprobe at encryption time) so
        // BetterPlayer renders at the correct ratio from frame one instead
        // of relying on its own runtime auto-detection. Our outer
        // AspectRatio wrapper (see _buildPlayer) uses the same value via
        // _videoAspectRatio. Falls back to auto-detect (null) only for
        // legacy .sec files that predate this field.
        aspectRatio: widget.initialAspectRatio,
        // Do not let BetterPlayer react to AppLifecycleState changes — it
        // calls pause() without await and then immediately disposes the
        // VideoPlayerController, causing a StateError on the next microtask.
        handleLifecycle: false,
        // autoDispose:false prevents the fullscreen _BetterPlayerState from
        // disposing the shared controller when the fullscreen route is popped.
        // We dispose it ourselves in _VideoPlayerScreenState.dispose().
        autoDispose: false,
        controlsConfiguration: BetterPlayerControlsConfiguration(
          playerTheme: BetterPlayerTheme.custom,
          customControlsBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ),
      betterPlayerDataSource: dataSource,
    );

    _controller!.addEventsListener(_onPlayerEvent);
    _resetHideTimer();
    _progressTimer = Timer.periodic(
      const Duration(seconds: 1),
      _checkPopupTrigger,
    );
    setState(() {});
  }

  void _onPlayerEvent(BetterPlayerEvent event) {
    if (!mounted || _controller == null) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.initialized:
        if (_savedPositionMs > 0) {
          _controller?.seekTo(Duration(milliseconds: _savedPositionMs));
        }
        final vc = _controller?.videoPlayerController;
        if (vc != null && mounted) {
          setState(() {
            _videoDuration = vc.value.duration ?? Duration.zero;
            // Only fall back to BetterPlayer's own runtime-detected ratio
            // when metadata.json didn't already give us a precomputed value
            // (legacy .sec files). The precomputed ffprobe value is treated
            // as authoritative — never overwritten by runtime detection —
            // since that runtime path is what produced the squashed-video
            // bug reported multiple times before this field existed.
            if (widget.initialAspectRatio == null && vc.value.aspectRatio > 0) {
              _videoAspectRatio = vc.value.aspectRatio;
            }
          });
        }
      case BetterPlayerEventType.play:
        if (mounted) setState(() => _isPlaying = true);
      case BetterPlayerEventType.pause:
        if (mounted) setState(() => _isPlaying = false);
      case BetterPlayerEventType.exception:
        final msg =
            event.parameters?['exception']?.toString() ?? 'Playback error';
        if (mounted) setState(() => _playerErrorMessage = msg);
      default:
        break;
    }
  }

  Future<void> _checkPopupTrigger(Timer t) async {
    if (!mounted || _controller == null) return;

    final vc = _controller!.videoPlayerController;
    if (vc == null) return;
    final pos = vc.value.position;
    // Keep our own playback state in sync (avoids ValueListenableBuilder on disposed controller).
    if (!_isDraggingSeek) {
      setState(() {
        _videoPosition = pos;
        _videoDuration = vc.value.duration ?? Duration.zero;
        _isPlaying = vc.value.isPlaying;
      });
    }
    final quizzes =
        ref.read(courseQuizzesProvider(widget.lectureId)).valueOrNull ?? [];
    for (final q in quizzes) {
      if (!q.isPopupQuiz) continue;
      if (!q.appliesToVideo(widget.videoId)) continue;
      if (_triggeredPopupIds.contains(q.id)) continue;
      if (pos.inSeconds >= q.triggerAtSecond && q.triggerAtSecond > 0) {
        // Persist before showing so re-entry never re-triggers.
        await _persistTriggeredPopup(q.id);
        _controller!.pause();
        _showPopupQuiz(q);
        break;
      }
    }
  }

  Future<void> _showPopupQuiz(Quiz quiz) async {
    final resume = await context.push<bool>(
      '/quiz/${widget.lectureId}/${quiz.id}',
      extra: {'quiz': quiz, 'videoId': widget.videoId, 'isPopup': true},
    );
    if (mounted && resume == true) _playerPlay();
  }

  Future<void> _retry() async {
    if (Platform.isWindows) {
      _disposeWindowsPlayer();
    } else {
      _controller?.removeEventsListener(_onPlayerEvent);
      _controller?.dispose();
      _controller = null;
    }
    if (mounted) {
      setState(() {
        _playerErrorMessage = null;
        _adbWarningShown = false;
      });
    }
    ref.invalidate(videoServerProvider(_args));
  }

  // ── Platform-agnostic player helpers ─────────────────────────────────────

  void _playerPlay() {
    Platform.isWindows ? _mkPlayer?.play() : _controller?.play();
  }

  void _playerPause() {
    Platform.isWindows ? _mkPlayer?.pause() : _controller?.pause();
  }

  void _playerSeekTo(Duration pos) {
    Platform.isWindows ? _mkPlayer?.seek(pos) : _controller?.seekTo(pos);
  }

  void _playerSetSpeed(double speed) {
    Platform.isWindows
        ? _mkPlayer?.setRate(speed)
        : _controller?.setSpeed(speed);
  }

  Duration _playerPosition() {
    return Platform.isWindows
        ? (_mkPlayer?.state.position ?? Duration.zero)
        : (_controller?.videoPlayerController?.value.position ?? Duration.zero);
  }

  Duration _playerDuration() {
    return Platform.isWindows
        ? (_mkPlayer?.state.duration ?? Duration.zero)
        : (_controller?.videoPlayerController?.value.duration ?? Duration.zero);
  }

  // Quiz trigger driven by media_kit stream (Windows-only, replaces Timer-based check)
  Future<void> _checkMkQuizTrigger(Duration pos) async {
    if (!mounted) return;
    final quizzes =
        ref.read(courseQuizzesProvider(widget.lectureId)).valueOrNull ?? [];
    for (final q in quizzes) {
      if (!q.isPopupQuiz) continue;
      if (!q.appliesToVideo(widget.videoId)) continue;
      if (_triggeredPopupIds.contains(q.id)) continue;
      if (pos.inSeconds >= q.triggerAtSecond && q.triggerAtSecond > 0) {
        await _persistTriggeredPopup(q.id);
        _mkPlayer?.pause();
        _showPopupQuiz(q);
        break;
      }
    }
  }

  // ── Custom controls logic ─────────────────────────────────────────────────

  void _showControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _resetHideTimer();
  }

  void _resetHideTimer() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _onDoubleTap(TapDownDetails details, double videoWidth) {
    final isLeft = details.localPosition.dx < videoWidth / 2;
    _seekRelative(isLeft ? -10 : 10);
    _seekFeedbackTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _seekFeedbackLeft = isLeft;
      _seekFeedbackMsg = isLeft ? '- 10s' : '+ 10s';
    });
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFeedbackMsg = null);
    });
  }

  void _seekRelative(int seconds) {
    final pos = _playerPosition();
    final dur = _playerDuration();
    final newPos = Duration(
      milliseconds:
          (pos.inMilliseconds + seconds * 1000).clamp(0, dur.inMilliseconds),
    );
    _playerSeekTo(newPos);
    _showControls();
  }

  void _setSpeed(double speed) {
    if (!mounted) return;
    setState(() => _playbackSpeed = speed);
    _playerSetSpeed(speed);
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // Fullscreen previously only locked orientation — the status bar (and its
  // notification/quick-settings pull-down) stayed on screen the whole time,
  // overlapping controls near the top edge (e.g. the file-switch button)
  // in landscape. Keep it in sync with every place _isFullscreen changes,
  // not just the manual toggle, since rotation can also drive it.
  void _applyAndroidSystemUiMode(bool fullscreen) {
    if (!Platform.isAndroid) return;
    SystemChrome.setEnabledSystemUIMode(
      fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _toggleFullscreen() {
    if (_isFullscreen) {
      setState(() => _isFullscreen = false);
      if (Platform.isAndroid) {
        _applyAndroidSystemUiMode(false);
        // Manual toggle takes priority — ignore the rotation-driven
        // auto-fullscreen edge detector until the forced-portrait flash
        // below has fully settled, otherwise the sensor reporting
        // landscape again (because the device is still physically
        // sideways) would look like a fresh rotation and re-engage
        // fullscreen immediately.
        _suppressAutoFullscreen = true;
        // Force portrait immediately so the user sees the exit.
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        Future.delayed(const Duration(milliseconds: 400), () {
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
          Future.delayed(const Duration(milliseconds: 500), () {
            _suppressAutoFullscreen = false;
          });
        });
      } else if (Platform.isWindows) {
        _exitWindowsFullscreen();
      }
    } else {
      setState(() => _isFullscreen = true);
      if (Platform.isAndroid) {
        _applyAndroidSystemUiMode(true);
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else if (Platform.isWindows) {
        _enterWindowsFullscreen();
      }
    }
    _showControls();
  }

  void _enterWindowsFullscreen() {
    try {
      final hwnd = GetForegroundWindow();
      if (hwnd == 0) return;
      _winSavedHwnd = hwnd;
      _winSavedStyle = GetWindowLongPtr(hwnd, GWL_STYLE);
      // Remove title bar + resize border
      SetWindowLongPtr(
          hwnd, GWL_STYLE, _winSavedStyle & ~(WS_CAPTION | WS_THICKFRAME));
      // Fill entire screen (SM_CXSCREEN=0, SM_CYSCREEN=1)
      final sw = GetSystemMetrics(0);
      final sh = GetSystemMetrics(1);
      SetWindowPos(
          hwnd, HWND_TOP, 0, 0, sw, sh, SWP_FRAMECHANGED | SWP_NOACTIVATE);
    } catch (_) {}
  }

  void _exitWindowsFullscreen() {
    try {
      if (_winSavedHwnd == 0) return;
      SetWindowLongPtr(_winSavedHwnd, GWL_STYLE, _winSavedStyle);
      SetWindowPos(_winSavedHwnd, HWND_TOP, 100, 100, 1280, 720,
          SWP_FRAMECHANGED | SWP_NOACTIVATE);
      _winSavedHwnd = 0;
      _winSavedStyle = 0;
    } catch (_) {}
  }

  void _hideControls() {
    _controlsHideTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = false);
  }

  void _showSettingsSheet() {
    _controlsHideTimer?.cancel();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Settings',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15),
            ),
          ),
          // Speed section header
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Playback Speed',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ),
          ...[0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((sp) => ListTile(
                dense: true,
                title: Text(
                  sp == 1.0 ? 'Normal' : '${sp}x',
                  style: TextStyle(
                    color: sp == _playbackSpeed
                        ? AppTheme.primary
                        : Colors.white70,
                    fontWeight: sp == _playbackSpeed
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                trailing: sp == _playbackSpeed
                    ? const Icon(Icons.check_rounded,
                        color: AppTheme.primary, size: 18)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  _setSpeed(sp);
                  _showControls();
                },
              )),
          const SizedBox(height: 16),
        ],
      ),
    ).then((_) => _showControls());
  }

  // ── Custom controls widgets ───────────────────────────────────────────────

  Widget _buildCustomControlsOverlay(double videoWidth) {
    final hasPlayer = Platform.isWindows
        ? _mkCtrl != null
        : (_controller?.videoPlayerController != null);
    if (!hasPlayer) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1: always-active detector — shows controls when hidden, handles double-tap seek.
        GestureDetector(
          onTap: _controlsVisible ? null : _showControls,
          onDoubleTapDown: (d) => _onDoubleTap(d, videoWidth),
          behavior: HitTestBehavior.translucent,
          child: const SizedBox.expand(),
        ),
        // Layer 2: seek ripple feedback (pointer-transparent)
        if (_seekFeedbackMsg != null)
          IgnorePointer(child: _buildSeekFeedback()),
        // Layer 3: controls overlay — opaque GestureDetector hides on tap of empty areas.
        IgnorePointer(
          ignoring: !_controlsVisible,
          child: GestureDetector(
            onTap: _hideControls,
            behavior: HitTestBehavior.opaque,
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.52),
                ),
                child: Stack(
                  children: [
                    Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _buildControlsTopBar()),
                    Center(child: _buildCenterControls()),
                    Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: _buildControlsBottomBar()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSeekFeedback() {
    final isLeft = _seekFeedbackLeft;
    final msg = _seekFeedbackMsg ?? '';
    final icon = isLeft ? Icons.replay_10_rounded : Icons.forward_10_rounded;
    final ripple = Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white, size: 40),
          const SizedBox(height: 6),
          Text(msg,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
    return Row(
      children: [
        if (isLeft)
          Expanded(child: ripple)
        else
          const Expanded(child: SizedBox()),
        if (!isLeft)
          Expanded(child: ripple)
        else
          const Expanded(child: SizedBox()),
      ],
    );
  }

  Widget _buildControlsTopBar() {
    final hasFiles = _files.isNotEmpty;
    final fileLabel = hasFiles
        ? (_files[_selectedFileIdx].title.isNotEmpty
            ? _files[_selectedFileIdx].title
            : _files[_selectedFileIdx].filename)
        : null;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
        child: Row(
          children: [
            // Back button — exits fullscreen when fullscreen, otherwise pops route
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 20),
              onPressed:
                  _isFullscreen ? _toggleFullscreen : () => context.pop(),
              padding: const EdgeInsets.all(8),
            ),
            const Spacer(),
            // Lecture file pill — only visible in landscape (toggles side panel)
            if (hasFiles && isLandscape)
              GestureDetector(
                onTap: () {
                  if (isLandscape) {
                    setState(() => _filePanelOpen = !_filePanelOpen);
                  }
                  _showControls();
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.25), width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _files[_selectedFileIdx].mimeType.contains('pdf')
                            ? Icons.picture_as_pdf_rounded
                            : Icons.image_rounded,
                        color: Colors.white70,
                        size: 13,
                      ),
                      const SizedBox(width: 5),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(
                          fileLabel ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(width: 6),
            // Settings gear
            GestureDetector(
              onTap: _showSettingsSheet,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.settings_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _controlIconBtn(Icons.replay_10_rounded,
            onTap: () => _seekRelative(-10), size: 44),
        const SizedBox(width: 32),
        GestureDetector(
          onTap: () {
            if (_isPlaying) {
              _playerPause();
              setState(() => _isPlaying = false);
            } else {
              _playerPlay();
              setState(() => _isPlaying = true);
            }
            _showControls();
          },
          child: Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.28),
            ),
            child: Icon(
              _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 42,
            ),
          ),
        ),
        const SizedBox(width: 32),
        _controlIconBtn(Icons.forward_10_rounded,
            onTap: () => _seekRelative(10), size: 44),
      ],
    );
  }

  Widget _controlIconBtn(IconData icon,
      {required VoidCallback onTap, double size = 32}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        onTap();
        _showControls();
      },
      child: Container(
        width: size + 20,
        height: size + 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.22),
        ),
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
  }

  Widget _buildControlsBottomBar() {
    final dur = _videoDuration.inMilliseconds.toDouble();
    final pos = _isDraggingSeek
        ? (_dragSeekPosition?.inMilliseconds.toDouble() ?? 0)
        : _videoPosition.inMilliseconds.toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 4, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: SliderComponentShape.noOverlay,
              activeTrackColor: AppTheme.primary,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: pos.clamp(0.0, dur > 0 ? dur : 1.0),
              min: 0,
              max: dur > 0 ? dur : 1.0,
              onChangeStart: (_) {
                setState(() => _isDraggingSeek = true);
                _controlsHideTimer?.cancel();
              },
              onChanged: (v) => setState(
                  () => _dragSeekPosition = Duration(milliseconds: v.toInt())),
              onChangeEnd: (v) {
                _playerSeekTo(Duration(milliseconds: v.toInt()));
                setState(() {
                  _videoPosition = Duration(milliseconds: v.toInt());
                  _isDraggingSeek = false;
                  _dragSeekPosition = null;
                });
                _resetHideTimer();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
            child: Row(
              children: [
                Text(
                  '${_fmtDuration(_videoPosition)} / ${_fmtDuration(_videoDuration)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const Spacer(),
                // Fullscreen toggle
                GestureDetector(
                  onTap: _toggleFullscreen,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      _isFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final serverAsync = ref.watch(videoServerProvider(_args));
    final profile = ref.watch(studentProfileProvider).valueOrNull;

    // Every cause that used to be tracked separately here (HDMI, recording,
    // plus ADB/root/Frida/focus-loss) is now unified in one guard state —
    // pause on anything but clear, auto-resume the instant it clears again.
    ref.listen<SecurityGuardState>(securityRuntimeGuardProvider, (previous, next) {
      if (next is SecurityGuardClear) {
        if (previous != null && previous is! SecurityGuardClear) _playerPlay();
      } else {
        _playerPause();
      }
    });

    return Scaffold(
      backgroundColor: Colors.black,
      // No AppBar — back button lives inside the custom controls overlay.
      body: SecurityGuardGate(
        child: serverAsync.when(
          loading: () => _spinner('Starting player...'),
          error: (err, _) => _buildErrorState(_formatError(err)),
          data: (ready) {
            if (_playerErrorMessage != null) {
              return _buildErrorState(_playerErrorMessage!);
            }
            final playerReady =
                Platform.isWindows ? _mkCtrl != null : _controller != null;
            if (!playerReady) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _initPlayer(ready.hlsUrl, ready.sessionToken);
                if (kDebugMode && ready.adbDetected && !_adbWarningShown) {
                  _adbWarningShown = true;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content:
                          Text('[DEV] ADB detected — blocked in release build'),
                      backgroundColor: Colors.orange,
                      duration: Duration(seconds: 5),
                    ),
                  );
                }
              });
              return _spinner('Loading video...');
            }
            return _buildPlayer(profile, ready);
          },
        ),
      ),
    );
  }

  // ── Player layouts ────────────────────────────────────────────────────────

  Widget _buildPlayer(StudentProfile? profile, VideoServerReady ready) {
    final screenWidth = MediaQuery.of(context).size.width;
    final currentOrientation = MediaQuery.of(context).orientation;

    // Auto-engage/disengage fullscreen on the edge of a rotation, not on
    // every build. Recomputing "should be fullscreen" from the current
    // orientation on every build meant a manual fullscreen-off toggle got
    // instantly overridden back to fullscreen whenever the device just
    // happened to still be physically landscape (isLandscape still true).
    // The FIRST build is also treated as an edge (there's no "previous"
    // orientation to compare against otherwise) — without this, opening the
    // video screen while the device is already landscape never engages
    // fullscreen at all, leaving the portrait layout's height-capped player
    // rendered small and centered inside a landscape screen.
    if (Platform.isAndroid && !_suppressAutoFullscreen) {
      final isFirstBuild = _lastOrientation == null;
      if (isFirstBuild || _lastOrientation != currentOrientation) {
        final shouldBeFullscreen = currentOrientation == Orientation.landscape;
        if (shouldBeFullscreen != _isFullscreen) {
          _applyAndroidSystemUiMode(shouldBeFullscreen);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _isFullscreen = shouldBeFullscreen);
          });
        }
      }
    }
    _lastOrientation = currentOrientation;

    // Video + watermark + custom controls in a single Stack.
    final basePlayer = Platform.isWindows
        ? Video(controller: _mkCtrl!, controls: NoVideoControls)
        : BetterPlayer(controller: _controller!);
    final withWatermark =
        (profile != null && widget.watermarkConfig.applyToVideos)
            ? WatermarkOverlay(
                studentName: profile.name,
                phoneNumber: profile.phone,
                studentEmail: profile.email,
                config: widget.watermarkConfig,
                child: basePlayer,
              )
            : basePlayer;

    final playerArea = AspectRatio(
      aspectRatio: _videoAspectRatio ?? (16 / 9),
      child: Stack(
        fit: StackFit.expand,
        children: [
          withWatermark,
          _buildCustomControlsOverlay(screenWidth),
        ],
      ),
    );

    // Windows desktop is always wide — always use landscape layout.
    // Android: _isFullscreen is the sole source of truth (kept in sync with
    // device rotation via the edge detector above) — NOT raw device
    // orientation directly, which would override a manual fullscreen-off
    // toggle the instant the device happens to still be held sideways.
    final useLandscapeLayout = Platform.isWindows || _isFullscreen;
    return useLandscapeLayout
        ? _buildLandscapeLayout(playerArea, ready)
        : _buildPortraitLayout(playerArea, ready);
  }

  // Portrait: SafeArea top → video → title → file chips → file content
  // (Quiz access lives in the lecture's content list, not the player —
  // see _AttachedQuizRow in course_detail_screen.dart.)
  Widget _buildPortraitLayout(Widget playerArea, VideoServerReady ready) {
    // CrossAxisAlignment.stretch forces playerArea to full screen width with
    // no height cap. For a wide video that's fine (AspectRatio computes a
    // short height). For a genuinely tall/vertical video, computing height
    // from a full-width AspectRatio produces a box taller than the screen
    // itself, causing a RenderFlex overflow below (and cramming everything
    // else off-screen) instead of just letterboxing the video.
    //
    // Only applied to genuinely tall/portrait videos (aspect ratio < 1) —
    // Center always expands to fill the full maxHeight box, then centers
    // the AspectRatio-sized video within it, which left visible black bars
    // above/below every normal wide video even though it had no overflow
    // risk to guard against. Wide videos skip the wrapper entirely and size
    // to their own AspectRatio at full stretched width, so the video's box
    // is exactly as tall as the video needs — no reserved dead space, and
    // the file panel's Expanded below picks up whatever height that frees.
    final aspectRatio = _videoAspectRatio ?? (16 / 9);
    final isTallVideo = aspectRatio < 1;
    final maxVideoHeight = MediaQuery.of(context).size.height * 0.5;
    final videoBox = isTallVideo
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxVideoHeight),
            child: Center(child: playerArea),
          )
        : playerArea;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Status-bar padding (no AppBar so we handle it manually)
        SizedBox(height: MediaQuery.of(context).padding.top),
        videoBox,
        // Title row (YouTube-style below video)
        if (widget.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (_files.isNotEmpty) ...[
          if (_files.length > 1) _buildFileChipsBar(),
          Expanded(child: _buildActiveFileContent(ready)),
        ],
      ],
    );
  }

  // Landscape: video fills scaffold body, overlay panel slides in from right.
  // No content below video — quiz button only in portrait.
  Widget _buildLandscapeLayout(Widget playerArea, VideoServerReady ready) {
    final panelWidth = MediaQuery.of(context).size.width * 0.38;

    // Stack(fit: expand) fills whatever space the Scaffold body provides.
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(child: playerArea),
        if (_files.isNotEmpty)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            right: _filePanelOpen ? 0 : -panelWidth,
            top: 0,
            bottom: 0,
            width: panelWidth,
            child: _buildLandscapePanel(ready),
          ),
        if (_files.isNotEmpty)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            right: _filePanelOpen ? panelWidth + 6 : 6,
            top: 6,
            child: _buildPanelToggleButton(),
          ),
      ],
    );
  }

  // ── File panel widgets ────────────────────────────────────────────────────

  Widget _buildLandscapePanel(VideoServerReady ready) {
    return Container(
      color: AppTheme.background,
      child: Column(
        children: [
          // Header: close + file selector
          Container(
            height: 44,
            color: AppTheme.surface,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white54, size: 18),
                  onPressed: () => setState(() => _filePanelOpen = false),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
                if (_files.length > 1)
                  Expanded(
                    child: _buildFileSelectorRow(),
                  )
                else
                  Expanded(
                    child: Text(
                      _files.isNotEmpty
                          ? (_files[_selectedFileIdx].title.isNotEmpty
                              ? _files[_selectedFileIdx].title
                              : _files[_selectedFileIdx].filename)
                          : '',
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _buildActiveFileContent(ready)),
        ],
      ),
    );
  }

  // Chips bar shown in portrait above file content (only when >1 file)
  Widget _buildFileChipsBar() {
    return Container(
      height: 44,
      color: AppTheme.surface,
      child: _buildFileSelectorRow(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
    );
  }

  Widget _buildFileSelectorRow({EdgeInsets? padding}) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding:
          padding ?? const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      itemCount: _files.length,
      itemBuilder: (_, i) => _buildFileChip(i),
    );
  }

  Widget _buildFileChip(int i) {
    final selected = _selectedFileIdx == i;
    final file = _files[i];
    final label = file.title.isNotEmpty ? file.title : file.filename;
    final icon = file.mimeType.contains('pdf')
        ? Icons.picture_as_pdf_rounded
        : Icons.image_rounded;

    return GestureDetector(
      onTap: () => _switchFile(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary
              : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppTheme.primary
                : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: selected ? Colors.white : Colors.white54, size: 13),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white54,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
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
    return result.isEmpty ? 'SECURE PLAYER' : result;
  }

  /// pdfx-based lazy per-page texture rendering + pinch-zoom. Keyed by
  /// file.id so switching between files forces correct widget/state
  /// recreation instead of reusing a stale ListView position.
  Widget _buildPdfView(LectureFile file) {
    return KeyedSubtree(
      key: ValueKey(file.id),
      child: SecurePdfViewPinch(
        controller: _pdfControllers[file.id]!,
        watermarkText: _getWatermarkText(),
        watermarkConfig: widget.watermarkConfig,
        onPageChanged: (page) =>
            PdfPageCache.save(widget.lectureId, file.id, page),
      ),
    );
  }

  Widget _buildActiveFileContent(VideoServerReady ready) {
    if (_files.isEmpty) return const SizedBox.shrink();
    final file = _files[_selectedFileIdx];
    final isEncrypted = _fileIvMap.containsKey(file.id);

    if (file.mimeType.contains('pdf')) {
      if (_pdfControllers.containsKey(file.id)) {
        return _buildPdfView(file);
      }
      if (_pdfLoadingMap[file.id] != true) {
        _pdfLoadingMap[file.id] = true;
        if (isEncrypted) {
          _loadPdfFromServer(file, ready);
        } else {
          _loadPdfFromDisk(file);
        }
      }
      final progress = _pdfProgressMap[file.id];
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (progress != null) ...[
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: Colors.white12,
                  color: AppTheme.primary,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(height: 10),
                Text(
                  'Loading PDF (${(progress * 100).toInt()}%)',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ] else
                const CircularProgressIndicator(color: AppTheme.primary),
            ],
          ),
        ),
      );
    }

    if (file.mimeType.startsWith('image/')) {
      if (isEncrypted) {
        final url = 'http://127.0.0.1:${ready.port}'
            '/file/${widget.lectureId}/${file.id}/${file.filename}'
            '?t=${ready.sessionToken}';
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Center(
            child: Image.network(
              url,
              headers: {'Authorization': 'Bearer ${ready.sessionToken}'},
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(Icons.broken_image_rounded,
                    color: Colors.white24, size: 48),
              ),
            ),
          ),
        );
      } else {
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Center(
            child: Image.file(
              File('$_courseDir/${file.filename}'),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(Icons.broken_image_rounded,
                    color: Colors.white24, size: 48),
              ),
            ),
          ),
        );
      }
    }

    if (file.mimeType.contains('html') || file.mimeType == 'text/html') {
      final htmlUrl = 'http://127.0.0.1:${ready.port}'
          '/html/${widget.lectureId}/${file.id}/${file.filename}'
          '?t=${ready.sessionToken}';
      return HtmlFileViewer(url: htmlUrl, sessionToken: ready.sessionToken);
    }

    return Center(
      child: Text(
        'Cannot preview: ${file.filename}',
        style: const TextStyle(color: Colors.white38, fontSize: 13),
      ),
    );
  }

  Future<void> _loadPdfFromDisk(LectureFile file) async {
    try {
      final doc = await PdfDocument.openFile('$_courseDir/${file.filename}');
      if (!mounted) {
        await doc.close();
        return;
      }
      final cachedPage = await PdfPageCache.load(widget.lectureId, file.id);
      if (!mounted) {
        await doc.close();
        return;
      }
      setState(() {
        _pdfDocs[file.id] = doc;
        _pdfControllers[file.id] = SecurePdfControllerPinch(
          document: Future.value(doc),
          initialPage: cachedPage,
        );
        _pdfLoadingMap[file.id] = false;
      });
    } catch (_) {
      if (mounted) setState(() => _pdfLoadingMap[file.id] = false);
    }
  }

  Future<void> _loadPdfFromServer(
      LectureFile file, VideoServerReady ready) async {
    try {
      final url = 'http://127.0.0.1:${ready.port}'
          '/file/${widget.lectureId}/${file.id}/${file.filename}';
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Authorization', 'Bearer ${ready.sessionToken}');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('Server returned ${response.statusCode}');
      }
      final total = response.contentLength;
      final builder = BytesBuilder();
      var received = 0;
      await for (final chunk in response) {
        builder.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) {
          setState(() =>
              _pdfProgressMap[file.id] = (received / total).clamp(0.0, 1.0));
        }
      }
      client.close();
      if (!mounted) return;
      final doc = await PdfDocument.openData(builder.takeBytes());
      if (!mounted) {
        await doc.close();
        return;
      }
      final cachedPage = await PdfPageCache.load(widget.lectureId, file.id);
      if (!mounted) {
        await doc.close();
        return;
      }
      setState(() {
        _pdfDocs[file.id] = doc;
        _pdfControllers[file.id] = SecurePdfControllerPinch(
          document: Future.value(doc),
          initialPage: cachedPage,
        );
        _pdfProgressMap.remove(file.id);
        _pdfLoadingMap[file.id] = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _pdfProgressMap.remove(file.id);
          _pdfLoadingMap[file.id] = false;
        });
      }
    }
  }

  Widget _buildPanelToggleButton() {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _filePanelOpen = !_filePanelOpen),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(
            _filePanelOpen
                ? Icons.chrome_reader_mode
                : Icons.chrome_reader_mode_outlined,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _spinner(String label) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: AppTheme.primary),
            const SizedBox(height: 16),
            Text(label, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      );

  String _formatError(Object err) {
    if (err is AppException) return err.message;
    return 'Failed to start video server: $err';
  }

  Widget _buildErrorState(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.redAccent, size: 56),
              const SizedBox(height: 16),
              Text(message,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
}
