import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../app/ipad_window_chrome.dart';
import '../components/app_icons.dart';
import '../components/ui_components.dart';
import '../tdlib/td_image_loader.dart';
import '../tdlib/td_models.dart';
import '../theme/app_theme.dart';

class FullImageViewer extends StatefulWidget {
  const FullImageViewer({
    super.key,
    required this.items,
    this.startIndex = 0,
    this.primaryActionLabel,
    this.onPrimaryAction,
    this.onMore,
  });

  final List<TdFileRef> items;
  final int startIndex;
  final String? primaryActionLabel;
  final Future<void> Function(int index)? onPrimaryAction;
  final Future<void> Function(int index)? onMore;

  @override
  State<FullImageViewer> createState() => _FullImageViewerState();
}

class _FullImageViewerState extends State<FullImageViewer> {
  late final PageController _pageController = PageController(
    initialPage: widget.startIndex.clamp(0, _max),
  );
  late int _index = widget.startIndex.clamp(0, _max);
  double _dragY = 0;
  bool _zoomed = false;
  final _pageKeys = <int, GlobalKey<_ViewerPageState>>{};
  int? _gesturePage;
  bool _runningAction = false;

  int get _max => widget.items.isEmpty ? 0 : widget.items.length - 1;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _runAction(Future<void> Function(int index) action) async {
    if (_runningAction) return;
    setState(() => _runningAction = true);
    try {
      await action(_index);
    } finally {
      if (mounted) setState(() => _runningAction = false);
    }
  }

  _ViewerPageState? get _gesturePageState =>
      _pageKeys[_gesturePage]?.currentState;

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _gesturePage ??= _index;
    _gesturePageState?._onPointerDown(event);
  }

  void _onPointerMove(PointerMoveEvent event) {
    final page = _gesturePageState;
    final viewport = context.size;
    if (page != null && viewport != null) {
      page._onPointerMove(event, viewport);
    }
  }

  void _onPointerEnd(PointerEvent event) {
    final page = _gesturePageState;
    page?._onPointerEnd(event);
    if (page == null || page._touches.isEmpty) _gesturePage = null;
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dragY.abs() / 260).clamp(0.0, 1.0);
    return ColoredBox(
      color: const Color(0xFF000000).withValues(alpha: 1 - progress * 0.85),
      child: Stack(
        children: [
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerEnd,
            onPointerCancel: _onPointerEnd,
            child: GestureDetector(
              onVerticalDragUpdate: _zoomed
                  ? null
                  : (d) => setState(() => _dragY += d.delta.dy),
              onVerticalDragEnd: _zoomed
                  ? null
                  : (_) {
                      if (_dragY.abs() > 110) {
                        Navigator.of(context).pop();
                      } else {
                        setState(() => _dragY = 0);
                      }
                    },
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: PageView.builder(
                  controller: _pageController,
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  onPageChanged: (i) => setState(() => _index = i),
                  itemCount: widget.items.length,
                  itemBuilder: (context, i) => _ViewerPage(
                    key: _pageKeys.putIfAbsent(
                      i,
                      GlobalKey<_ViewerPageState>.new,
                    ),
                    ref: widget.items[i],
                    onPinchStart: () {
                      setState(() {
                        _dragY = 0;
                        _zoomed = true;
                      });
                      _pageController.jumpToPage(_index);
                    },
                    onZoomChanged: (z) {
                      if (z != _zoomed) setState(() => _zoomed = z);
                    },
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top:
                MediaQuery.of(context).padding.top +
                iPadWindowChromeInsetOf(context) +
                8,
            left: 16,
            right: 16,
            child: Opacity(
              opacity: 1 - progress,
              child: Row(
                children: [
                  _circleAppIcon(
                    HeroAppIcons.xmark,
                    () => Navigator.of(context).pop(),
                    key: const ValueKey('image-viewer-close'),
                  ),
                  Expanded(
                    child: Center(
                      child: widget.items.length > 1
                          ? Container(
                              key: const ValueKey('image-viewer-counter'),
                              height: 32,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFFFFFFF,
                                ).withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.lg,
                                ),
                              ),
                              child: Center(
                                widthFactor: 1,
                                child: Text(
                                  '${_index + 1} / ${widget.items.length}',
                                  style: const TextStyle(
                                    color: Color(0xFFFFFFFF),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  if (widget.onMore != null)
                    _circleAppIcon(
                      HeroAppIcons.ellipsis,
                      _runningAction
                          ? null
                          : () => unawaited(_runAction(widget.onMore!)),
                      key: const ValueKey('image-viewer-more'),
                    )
                  else
                    const SizedBox(width: 40, height: 40),
                ],
              ),
            ),
          ),
          if (widget.primaryActionLabel != null &&
              widget.onPrimaryAction != null)
            Positioned(
              left: 22,
              right: 22,
              bottom: MediaQuery.of(context).padding.bottom + 18,
              child: Opacity(
                opacity: 1 - progress,
                child: Semantics(
                  button: true,
                  label: widget.primaryActionLabel,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _runningAction
                        ? null
                        : () => unawaited(_runAction(widget.onPrimaryAction!)),
                    child: Container(
                      key: const ValueKey('image-viewer-primary-action'),
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppTheme.brand,
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x55000000),
                            blurRadius: 18,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      child: _runningAction
                          ? const AppActivityIndicator(
                              size: 20,
                              color: Color(0xFFFFFFFF),
                            )
                          : Text(
                              widget.primaryActionLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppTheme.onBrand,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _circleAppIcon(AppIconData name, VoidCallback? onTap, {Key? key}) =>
      GestureDetector(
        key: key,
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFFFFFFF).withValues(alpha: 0.18),
            shape: BoxShape.circle,
          ),
          child: AppIcon(name, size: 18, color: const Color(0xFFFFFFFF)),
        ),
      );
}

class _ViewerPage extends StatefulWidget {
  const _ViewerPage({
    super.key,
    required this.ref,
    required this.onZoomChanged,
    required this.onPinchStart,
  });
  final TdFileRef ref;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback onPinchStart;

  @override
  State<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<_ViewerPage> {
  final _controller = TransformationController();
  final _touches = <int, Offset>{};
  bool _touchZoomActive = false;
  double _pinchStartSpan = 1;
  double _pinchStartScale = 1;
  Offset _pinchScenePoint = Offset.zero;
  File? _file;
  File? _thumbnailFile;
  int _resolutionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransform);
    _resolveFiles();
  }

  @override
  void didUpdateWidget(covariant _ViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isSameFile(oldWidget.ref, widget.ref)) {
      _file = null;
      _thumbnailFile = null;
      _controller.value = Matrix4.identity();
      widget.onZoomChanged(false);
      _resolveFiles();
    }
  }

  bool _isSameFile(TdFileRef a, TdFileRef b) =>
      a.id == b.id &&
      a.localPath == b.localPath &&
      a.thumbnail?.id == b.thumbnail?.id &&
      a.thumbnail?.localPath == b.thumbnail?.localPath;

  void _resolveFiles() {
    final generation = ++_resolutionGeneration;
    final ref = widget.ref;
    TdFileCenter.shared.pathFor(ref).then((path) {
      if (!mounted || generation != _resolutionGeneration || path == null) {
        return;
      }
      setState(() => _file = File(path));
    });

    final thumbnail = ref.thumbnail;
    if (thumbnail == null || thumbnail.id == ref.id) return;
    TdFileCenter.shared.pathFor(thumbnail).then((path) {
      if (!mounted || generation != _resolutionGeneration || path == null) {
        return;
      }
      setState(() => _thumbnailFile = File(path));
    });
  }

  void _onTransform() {
    widget.onZoomChanged(
      _touchZoomActive || _controller.value.getMaxScaleOnAxis() > 1.01,
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touches[event.pointer] = event.localPosition;
    if (_touches.length != 2) return;
    setState(() => _touchZoomActive = true);
    widget.onPinchStart();
    final points = _touches.values.toList();
    _pinchStartSpan = math.max(1, (points[1] - points[0]).distance);
    _pinchStartScale = _controller.value.getMaxScaleOnAxis();
    _pinchScenePoint = _controller.toScene((points[0] + points[1]) / 2);
  }

  void _onPointerMove(PointerMoveEvent event, Size viewport) {
    final previous = _touches[event.pointer];
    if (previous == null) return;
    _touches[event.pointer] = event.localPosition;
    if (!_touchZoomActive) return;
    if (_touches.length >= 2) {
      final points = _touches.values.take(2).toList();
      final scale =
          (_pinchStartScale *
                  (points[1] - points[0]).distance /
                  _pinchStartSpan)
              .clamp(1.0, 5.0);
      _setTouchTransform(
        scale,
        (points[0] + points[1]) / 2 - _pinchScenePoint * scale,
        viewport,
      );
    } else {
      final translation = _controller.value.getTranslation();
      _setTouchTransform(
        _controller.value.getMaxScaleOnAxis(),
        Offset(translation.x, translation.y) + event.localPosition - previous,
        viewport,
      );
    }
  }

  void _setTouchTransform(double scale, Offset offset, Size viewport) {
    _controller.value = Matrix4.identity()
      ..setTranslationRaw(
        offset.dx.clamp(viewport.width * (1 - scale), 0),
        offset.dy.clamp(viewport.height * (1 - scale), 0),
        0,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _onPointerEnd(PointerEvent event) {
    _touches.remove(event.pointer);
    if (_touches.isEmpty && _touchZoomActive) {
      setState(() => _touchZoomActive = false);
      _onTransform();
    }
  }

  void _toggleZoom() {
    final current = _controller.value.getMaxScaleOnAxis();
    final next = current > 1.01 ? 1.0 : 2.0;
    _controller.value = Matrix4.diagonal3Values(next, next, 1);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransform);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: _buildPage);
  }

  Widget _buildPage(BuildContext context, BoxConstraints constraints) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final size = constraints.biggest;
    final cacheWidth = (size.width * ratio).ceil();
    final cacheHeight = (size.height * ratio).ceil();
    Widget fittedImage(ImageProvider<Object> image) => SizedBox(
      width: size.width,
      height: size.height,
      child: Image(image: image, fit: BoxFit.contain),
    );
    Widget interactive(Widget child) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1,
        maxScale: 5,
        panEnabled: !_touchZoomActive,
        scaleEnabled: !_touchZoomActive,
        trackpadScrollCausesScale: true,
        child: child,
      ),
    );
    if (_file == null) {
      if (_thumbnailFile != null) {
        return interactive(
          fittedImage(
            ResizeImage(
              FileImage(_thumbnailFile!),
              width: cacheWidth,
              height: cacheHeight,
              policy: ResizeImagePolicy.fit,
            ),
          ),
        );
      }
      if (widget.ref.miniThumb != null) {
        return Center(
          child: interactive(
            fittedImage(
              ResizeImage(
                MemoryImage(widget.ref.miniThumb!),
                width: cacheWidth,
                height: cacheHeight,
                policy: ResizeImagePolicy.fit,
              ),
            ),
          ),
        );
      }
      return const Center(
        child: AppActivityIndicator(size: 24, color: Color(0xFFFFFFFF)),
      );
    }
    return interactive(
      fittedImage(
        ResizeImage(
          FileImage(_file!),
          width: cacheWidth,
          height: cacheHeight,
          policy: ResizeImagePolicy.fit,
        ),
      ),
    );
  }
}
