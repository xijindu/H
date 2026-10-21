import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart' show FrameRate;
import 'package:provider/provider.dart';

import '../components/photo_avatar.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../theme/theme_controller.dart';
import 'animated_sticker_view.dart';
import 'sticker_item.dart';
import 'video_sticker_view.dart';

List<StickerItem> parseStickers(List<Map<String, dynamic>>? array) {
  if (array == null) return [];
  final out = <StickerItem>[];
  for (final sticker in array) {
    final file = sticker.obj('sticker');
    final id = file?.integer('id');
    if (file == null || id == null) continue;
    final format = sticker.obj('format')?.type;
    final isAnimated = format == 'stickerFormatTgs';
    final isVideo = format == 'stickerFormatWebm';
    final thumb =
        TDParse.fileRef(sticker.obj('thumbnail')?.obj('file')) ??
        (isVideo || isAnimated ? null : TdFileRef(id: id));
    out.add(
      StickerItem(
        id: id,
        remoteId: file.obj('remote')?.str('id'),
        width: sticker.integer('width') ?? 512,
        height: sticker.integer('height') ?? 512,
        emoji: sticker.str('emoji') ?? '',
        isAnimated: isAnimated,
        isVideo: isVideo,
        thumb: thumb,
        customEmojiId: sticker.obj('full_type')?.int64('custom_emoji_id') ?? 0,
      ),
    );
  }
  return out;
}

class CustomEmojiSticker {
  CustomEmojiSticker({
    this.file,
    this.thumb,
    this.isTgs = false,
    this.isWebm = false,
    this.needsRepainting = false,
  });
  final TdFileRef? file;
  final TdFileRef? thumb;
  final bool isTgs;
  final bool isWebm;
  final bool needsRepainting;
}

enum CustomEmojiPresentation { staticThumbnail, tgs, webm, image }

CustomEmojiPresentation customEmojiPresentation(
  CustomEmojiSticker sticker, {
  required bool animate,
}) {
  if (!animate && (sticker.isTgs || sticker.isWebm) && sticker.thumb != null) {
    return CustomEmojiPresentation.staticThumbnail;
  }
  if (sticker.isTgs && sticker.file != null) {
    return CustomEmojiPresentation.tgs;
  }
  if (sticker.isWebm && sticker.file != null && animate) {
    return CustomEmojiPresentation.webm;
  }
  return CustomEmojiPresentation.image;
}

class CustomEmojiCenter {
  CustomEmojiCenter._();
  static final CustomEmojiCenter shared = CustomEmojiCenter._();

  final Map<int, CustomEmojiSticker> _cache = {};
  final Set<int> _pending = {};
  bool _scheduled = false;
  int _generation = 0;
  final StreamController<int> _resolved = StreamController.broadcast();

  Stream<int> get onResolved => _resolved.stream;
  CustomEmojiSticker? get(int id) => _cache[id];

  void reset() {
    _generation += 1;
    _cache.clear();
    _pending.clear();
    _scheduled = false;
  }

  void request(int id) {
    if (id == 0 || _cache.containsKey(id) || _pending.contains(id)) return;
    _pending.add(id);
    if (_scheduled) return;
    _scheduled = true;
    Future.delayed(const Duration(milliseconds: 40), _flush);
  }

  Future<void> _flush() async {
    final generation = _generation;
    _scheduled = false;
    final ids = _pending.toList();
    _pending.clear();
    for (var i = 0; i < ids.length; i += 200) {
      final batch = ids.sublist(i, math.min(i + 200, ids.length));
      try {
        final res = await TdClient.shared.query({
          '@type': 'getCustomEmojiStickers',
          'custom_emoji_ids': batch.map((e) => e.toString()).toList(),
        });
        final stickers =
            res.objects('stickers') ?? const <Map<String, dynamic>>[];
        if (generation != _generation) return;
        for (final s in stickers) {
          final cid = s.obj('full_type')?.int64('custom_emoji_id');
          if (cid == null) continue;
          final format = s.obj('format')?.type;
          _cache[cid] = CustomEmojiSticker(
            file: TDParse.fileRef(s.obj('sticker')),
            thumb: TDParse.fileRef(s.obj('thumbnail')?.obj('file')),
            isTgs: format == 'stickerFormatTgs',
            isWebm: format == 'stickerFormatWebm',
            needsRepainting:
                s.obj('full_type')?.boolean('needs_repainting') ?? false,
          );
          _resolved.add(cid);
        }
      } catch (_) {}
    }
  }
}

class CustomEmojiView extends StatefulWidget {
  const CustomEmojiView({
    super.key,
    required this.id,
    this.size = 20,
    this.color,
    this.animate = true,
  });
  final int id;
  final double size;
  final Color? color;
  final bool animate;

  @override
  State<CustomEmojiView> createState() => _CustomEmojiViewState();
}

class _CustomEmojiViewState extends State<CustomEmojiView> {
  StreamSubscription<int>? _sub;

  @override
  void initState() {
    super.initState();
    _syncRequest();
  }

  @override
  void didUpdateWidget(covariant CustomEmojiView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _syncRequest();
  }

  void _syncRequest() {
    _sub?.cancel();
    _sub = null;
    final center = CustomEmojiCenter.shared;
    if (center.get(widget.id) == null) {
      center.request(widget.id);
      _sub = center.onResolved.listen((rid) {
        if (rid != widget.id) return;
        _sub?.cancel();
        _sub = null;
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = CustomEmojiCenter.shared.get(widget.id);
    if (s == null) return SizedBox(width: widget.size, height: widget.size);
    final cacheSize = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil();
    Widget child;
    switch (customEmojiPresentation(s, animate: widget.animate)) {
      case CustomEmojiPresentation.staticThumbnail:
        child = TDImage(
          photo: s.thumb!,
          cornerRadius: 0,
          fit: BoxFit.contain,
          cacheWidth: cacheSize,
          cacheHeight: cacheSize,
        );
        break;
      case CustomEmojiPresentation.tgs:
        child = AnimatedStickerView(
          file: s.file!,
          frameRate: const FrameRate(30),
          animate: widget.animate,
        );
        break;
      case CustomEmojiPresentation.webm:
        child = VideoStickerView(file: s.file!, fallback: s.thumb);
        break;
      case CustomEmojiPresentation.image:
        final img = s.file ?? s.thumb;
        if (img == null) {
          return SizedBox(width: widget.size, height: widget.size);
        }
        child = TDImage(
          photo: img,
          cornerRadius: 0,
          fit: BoxFit.contain,
          cacheWidth: cacheSize,
          cacheHeight: cacheSize,
        );
        break;
    }
    if (s.needsRepainting && widget.color != null) {
      child = ColorFiltered(
        colorFilter: ColorFilter.mode(widget.color!, BlendMode.srcATop),
        child: child,
      );
    }
    return SizedBox(width: widget.size, height: widget.size, child: child);
  }
}

class SelectableCustomEmojiView extends StatelessWidget {
  const SelectableCustomEmojiView({
    super.key,
    required this.id,
    required this.fallbackText,
    this.size = 20,
    this.color,
  });

  final int id;
  final String fallbackText;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: CustomEmojiView(id: id, size: size, color: color),
        ),
        Text(
          fallbackText,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.transparent,
            fontSize: size * 0.9,
            height: 1,
          ),
        ),
      ],
    ),
  );
}

class StatusEmojiView extends StatelessWidget {
  const StatusEmojiView({
    super.key,
    required this.id,
    this.size = 20,
    this.color,
    this.animate,
  });

  final int id;
  final double size;
  final Color? color;
  final bool? animate;

  @override
  Widget build(BuildContext context) {
    var shouldAnimate = animate ?? true;
    if (animate == null) {
      try {
        shouldAnimate = context.watch<ThemeController>().animateStatusEmoji;
      } on ProviderNotFoundException catch (_) {}
    }
    return CustomEmojiView(
      id: id,
      size: size,
      color: color,
      animate: shouldAnimate,
    );
  }
}
