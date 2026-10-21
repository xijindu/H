import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../components/app_icons.dart';
import '../components/ui_components.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

enum _VideoRecordGesture { continueRecording, lock, cancel }

_VideoRecordGesture _videoRecordGestureForDelta({
  required double dx,
  required double dy,
}) {
  if (dx < -90) return _VideoRecordGesture.cancel;
  if (dy < -70) return _VideoRecordGesture.lock;
  return _VideoRecordGesture.continueRecording;
}

class AppCameraResult {
  const AppCameraResult.capture(this.file) : openGallery = false;
  const AppCameraResult.gallery() : file = null, openGallery = true;

  final XFile? file;
  final bool openGallery;
}

@visibleForTesting
bool appCameraShouldRetryOnResume({required bool recording}) => !recording;

class AppCameraView extends StatefulWidget {
  const AppCameraView({
    super.key,
    this.allowVideo = true,
    this.allowGallery = true,
    @visibleForTesting this.availableCamerasForTesting,
    @visibleForTesting this.controllerForTesting,
  });

  final bool allowVideo;

  final bool allowGallery;

  final Future<List<CameraDescription>> Function()? availableCamerasForTesting;
  final CameraController Function(CameraDescription camera, bool enableAudio)?
  controllerForTesting;

  @override
  State<AppCameraView> createState() => _AppCameraViewState();
}

class _AppCameraViewState extends State<AppCameraView>
    with WidgetsBindingObserver {
  static const _maximumVideoDuration = Duration(seconds: 60);

  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _initializing = true;
  bool _capturing = false;
  bool _recording = false;
  bool _paused = false;
  bool _locked = false;
  bool _finishing = false;
  bool _flashEnabled = false;
  double _pressStartX = 0;
  double _pressStartY = 0;
  Duration _elapsed = Duration.zero;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadCameras());
  }

  Future<void> _loadCameras() async {
    setState(() => _initializing = true);
    try {
      final cameras =
          await (widget.availableCamerasForTesting ?? availableCameras)();
      if (!mounted) return;
      if (cameras.isEmpty) throw StateError('No camera is available.');
      _cameras = cameras;
      final back = cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      _cameraIndex = back >= 0 ? back : 0;
      await _initializeCamera(_cameraIndex);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
      });
    }
  }

  Future<void> _initializeCamera(int index) async {
    if (_cameras.isEmpty || index < 0 || index >= _cameras.length) return;
    setState(() {
      _initializing = true;
    });
    await _disposeController();
    final controller =
        widget.controllerForTesting?.call(_cameras[index], widget.allowVideo) ??
        CameraController(
          _cameras[index],
          ResolutionPreset.high,
          enableAudio: widget.allowVideo,
        );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted || !identical(_controller, controller)) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraIndex = index;
        _initializing = false;
      });
    } on CameraException catch (_) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
      });
    }
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    if (controller != null) await controller.dispose();
  }

  Future<void> _capturePhoto() async {
    final controller = _controller;
    if (_capturing ||
        _recording ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final file = await controller.takePicture();
      if (mounted) Navigator.of(context).pop(AppCameraResult.capture(file));
    } on CameraException catch (error) {
      debugPrint('Camera photo capture failed: ${error.code}');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _startRecording({bool locked = false}) async {
    final controller = _controller;
    if (!widget.allowVideo ||
        _capturing ||
        _recording ||
        _finishing ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    try {
      await controller.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _paused = false;
        _locked = locked;
        _elapsed = Duration.zero;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted || !_recording || _paused) return;
        setState(() => _elapsed += const Duration(milliseconds: 100));
        if (_elapsed >= _maximumVideoDuration) unawaited(_finishRecording());
      });
    } on CameraException catch (error) {
      debugPrint('Camera video recording failed: ${error.code}');
    }
  }

  Future<void> _togglePause() async {
    final controller = _controller;
    if (!_recording || _finishing || controller == null) return;
    try {
      if (_paused) {
        await controller.resumeVideoRecording();
      } else {
        await controller.pauseVideoRecording();
      }
      if (mounted) setState(() => _paused = !_paused);
    } on CameraException catch (error) {
      debugPrint('Camera pause/resume failed: ${error.code}');
    }
  }

  Future<void> _finishRecording() async {
    final controller = _controller;
    if (!_recording || _capturing || _finishing || controller == null) return;
    _finishing = true;
    _timer?.cancel();
    setState(() => _capturing = true);
    try {
      final file = await controller.stopVideoRecording();
      if (mounted) Navigator.of(context).pop(AppCameraResult.capture(file));
    } on CameraException catch (_) {
      if (mounted) {
        setState(() {
          _recording = false;
          _paused = false;
          _locked = false;
        });
      }
    } finally {
      _finishing = false;
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _cancelRecording() async {
    final controller = _controller;
    if (!_recording || _finishing || controller == null) return;
    _finishing = true;
    _timer?.cancel();
    try {
      final file = await controller.stopVideoRecording();
      try {
        final tempFile = File(file.path);
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {
      }
    } catch (_) {
    } finally {
      _finishing = false;
      if (mounted) {
        setState(() {
          _recording = false;
          _paused = false;
          _locked = false;
          _elapsed = Duration.zero;
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_recording || _capturing || _cameras.length < 2) return;
    final currentDirection = _cameras[_cameraIndex].lensDirection;
    var next = (_cameraIndex + 1) % _cameras.length;
    for (var offset = 1; offset <= _cameras.length; offset++) {
      final candidate = (_cameraIndex + offset) % _cameras.length;
      if (_cameras[candidate].lensDirection != currentDirection) {
        next = candidate;
        break;
      }
    }
    await _initializeCamera(next);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (_recording || controller == null || !controller.value.isInitialized) {
      return;
    }
    try {
      final enabled = !_flashEnabled;
      await controller.setFlashMode(enabled ? FlashMode.auto : FlashMode.off);
      if (mounted) setState(() => _flashEnabled = enabled);
    } on CameraException catch (error) {
      debugPrint('Camera flash failed: ${error.code}');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        appCameraShouldRetryOnResume(recording: _recording)) {
      if (_initializing) return;
      unawaited(
        _cameras.isEmpty ? _loadCameras() : _initializeCamera(_cameraIndex),
      );
      return;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_recording) {
        unawaited(_finishRecording());
      } else {
        unawaited(_disposeController());
      }
    }
  }

  String get _elapsedLabel {
    final seconds = _elapsed.inSeconds.clamp(0, 60);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.xxl),
                  child: ColoredBox(
                    color: const Color(0xFF1C1C1E),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (controller != null &&
                            controller.value.isInitialized)
                          Center(
                            child: CameraPreview(controller),
                          )
                        else if (_initializing)
                          const Center(
                            child: AppActivityIndicator(color: Colors.white),
                          )
                        else
                          _permissionMessage(),
                        Positioned(
                          left: 14,
                          top: 14,
                          child: _roundButton(
                            icon: HeroAppIcons.xmark,
                            label: AppStrings.t(
                              AppStringKeys.videoNoteRecorderCloseCamera,
                            ),
                            onTap: _recording
                                ? () => unawaited(_cancelRecording())
                                : () => Navigator.of(context).pop(),
                          ),
                        ),
                        Positioned(
                          right: 14,
                          top: 14,
                          child: _roundButton(
                            icon: HeroAppIcons.flash,
                            label: AppStrings.t(
                              AppStringKeys.cameraAutomaticFlash,
                            ),
                            active: _flashEnabled,
                            onTap: _toggleFlash,
                          ),
                        ),
                        if (_recording)
                          Positioned(
                            top: 22,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xB3000000),
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.lg,
                                  ),
                                ),
                                child: Text(
                                  _paused
                                      ? '${AppStrings.t(AppStringKeys.composerRecordingPaused)} · $_elapsedLabel'
                                      : _elapsedLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 128,
              child: _recording && _locked
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _roundButton(
                          icon: HeroAppIcons.trash,
                          label: AppStrings.t(
                            AppStringKeys.videoNoteRecorderCancelRecording,
                          ),
                          onTap: () => unawaited(_cancelRecording()),
                        ),
                        _roundButton(
                          icon: _paused
                              ? HeroAppIcons.play
                              : HeroAppIcons.pause,
                          label: _paused
                              ? 'Resume recording'
                              : 'Pause recording',
                          onTap: _togglePause,
                        ),
                        _recordButtonLocked(
                          onTap: () => unawaited(_finishRecording()),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        if (widget.allowGallery)
                          _roundButton(
                            icon: HeroAppIcons.images,
                            label: AppStrings.t(AppStringKeys.cameraOpenGallery),
                            onTap: () => Navigator.of(
                              context,
                            ).pop(const AppCameraResult.gallery()),
                          )
                        else
                          const SizedBox.square(dimension: 48),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _capturePhoto,
                          onLongPressStart: widget.allowVideo
                              ? (details) {
                                  _pressStartX = details.globalPosition.dx;
                                  _pressStartY = details.globalPosition.dy;
                                  unawaited(_startRecording());
                                }
                              : null,
                          onLongPressMoveUpdate: widget.allowVideo
                              ? (details) {
                                  if (!_recording || _locked) return;
                                  final dx =
                                      details.globalPosition.dx - _pressStartX;
                                  final dy =
                                      details.globalPosition.dy - _pressStartY;
                                  switch (_videoRecordGestureForDelta(
                                    dx: dx,
                                    dy: dy,
                                  )) {
                                    case _VideoRecordGesture.cancel:
                                      unawaited(_cancelRecording());
                                    case _VideoRecordGesture.lock:
                                      setState(() => _locked = true);
                                    case _VideoRecordGesture.continueRecording:
                                      break;
                                  }
                                }
                              : null,
                          onLongPressEnd: widget.allowVideo
                              ? (_) {
                                  if (_recording && !_locked) {
                                    unawaited(_finishRecording());
                                  }
                                }
                              : null,
                          child: _recordButton(),
                        ),
                        _roundButton(
                          icon: HeroAppIcons.arrowsRotate,
                          label: AppStrings.t(
                            AppStringKeys.videoNoteRecorderSwitchCamera,
                          ),
                          onTap: _cameras.length > 1 ? _switchCamera : null,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionMessage() {
    final noCamera = _cameras.isEmpty;
    final offersGallery = noCamera && widget.allowGallery;
    final description = noCamera
        ? (widget.allowGallery ? AppStringKeys.chooseMediaHint : null)
        : AppStringKeys.cameraAccessDescription;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 82,
              height: 82,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: const AppIcon(
                HeroAppIcons.camera,
                size: 38,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              (noCamera
                      ? AppStringKeys.cameraUnavailable
                      : AppStringKeys.cameraAccessTitle)
                  .l10n(context),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 10),
              Text(
                description.l10n(context),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFA1A1AA),
                  fontSize: 14,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 22),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: !noCamera
                  ? openAppSettings
                  : offersGallery
                  ? () => Navigator.of(
                      context,
                    ).pop(const AppCameraResult.gallery())
                  : () => Navigator.of(context).pop(),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.brand,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Text(
                  (!noCamera
                          ? AppStringKeys.openSystemSettings
                          : offersGallery
                          ? AppStringKeys.galleryOption
                          : AppStringKeys.videoNoteRecorderCloseCamera)
                      .l10n(context),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recordButton() => Container(
        width: 78,
        height: 78,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: !_recording
                ? Colors.white
                : _locked
                    ? AppTheme.brand
                    : const Color(0xFFE53935),
            shape: !_recording || !_locked
                ? BoxShape.circle
                : BoxShape.rectangle,
            borderRadius: _recording && _locked
                ? BorderRadius.circular(AppRadius.card)
                : null,
          ),
        ),
      );

  Widget _recordButtonLocked({VoidCallback? onTap}) {
    final button = Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.brand,
        borderRadius: BorderRadius.circular(10),
      ),
      child: AppIcon(
        HeroAppIcons.square,
        size: 22,
        color: Colors.white.withValues(alpha: onTap == null ? 0.4 : 1),
      ),
    );
    return onTap == null
        ? button
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: button,
          );
  }

  Widget _roundButton({
    required AppIconData icon,
    required String label,
    FutureOr<void> Function()? onTap,
    bool active = false,
  }) => Semantics(
    button: true,
    enabled: onTap != null,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? AppTheme.brand
              : Colors.black.withValues(alpha: onTap == null ? 0.28 : 0.58),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: AppIcon(
          icon,
          size: 22,
          color: Colors.white.withValues(alpha: onTap == null ? 0.38 : 1),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_controller?.dispose());
    _controller = null;
    super.dispose();
  }
}

