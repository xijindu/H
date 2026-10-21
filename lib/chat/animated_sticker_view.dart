import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../tdlib/td_client.dart';
import '../tdlib/td_image_loader.dart';
import '../tdlib/td_models.dart';

Uint8List _inflateTgsSticker(Uint8List bytes) {
  return Uint8List.fromList(const GZipDecoder().decodeBytes(bytes));
}

final Map<String, Future<Uint8List?>> _inflatedTgsCache = {};

void clearAnimatedStickerMemoryCache() {
  _inflatedTgsCache.clear();
  Lottie.cache.clear();
}

bool _lottieCacheBounded = false;

void _boundLottieCache() {
  if (_lottieCacheBounded) return;
  _lottieCacheBounded = true;
  Lottie.cache.maximumSize = defaultTargetPlatform == TargetPlatform.android
      ? 128
      : 256;
}

int get _maxInflatedTgsCacheEntries =>
    defaultTargetPlatform == TargetPlatform.android ? 32 : 80;

Future<Uint8List?> _loadInflatedTgsSticker(String cacheKey, String path) {
  final cached = _inflatedTgsCache.remove(cacheKey);
  if (cached != null) {
    _inflatedTgsCache[cacheKey] = cached;
    return cached;
  }

  final future = File(path)
      .readAsBytes()
      .then((bytes) => compute(_inflateTgsSticker, bytes))
      .then<Uint8List?>((bytes) => bytes)
      .catchError((_) {
        _inflatedTgsCache.remove(cacheKey);
        return null;
      });
  _inflatedTgsCache[cacheKey] = future;
  while (_inflatedTgsCache.length > _maxInflatedTgsCacheEntries) {
    _inflatedTgsCache.remove(_inflatedTgsCache.keys.first);
  }
  return future;
}

const int _maxConcurrentTgsParses = 2;
int _activeTgsParses = 0;
final List<Completer<void>> _tgsParseQueue = <Completer<void>>[];

Future<void> _prewarmTgsComposition(
  Uint8List bytes,
  bool Function() stillWanted,
) async {
  _boundLottieCache();
  if (_activeTgsParses >= _maxConcurrentTgsParses) {
    final turn = Completer<void>();
    _tgsParseQueue.add(turn);
    await turn.future;
    if (!stillWanted()) {
      if (_tgsParseQueue.isNotEmpty) _tgsParseQueue.removeAt(0).complete();
      return;
    }
  }
  _activeTgsParses++;
  try {
    await MemoryLottie(bytes, backgroundLoading: true).load();
  } catch (_) {
  } finally {
    _activeTgsParses--;
    if (_tgsParseQueue.isNotEmpty) _tgsParseQueue.removeAt(0).complete();
  }
}

class AnimatedStickerView extends StatefulWidget {
  const AnimatedStickerView({
    super.key,
    required this.file,
    this.onReady,
    this.frameRate,
    this.animate = true,
  });
  final TdFileRef file;
  final VoidCallback? onReady;
  final bool animate;

  final FrameRate? frameRate;

  @override
  State<AnimatedStickerView> createState() => _AnimatedStickerViewState();
}

class _AnimatedStickerViewState extends State<AnimatedStickerView> {
  Uint8List? _bytes;
  int? _loadedId;
  int? _loadedSlot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AnimatedStickerView old) {
    super.didUpdateWidget(old);
    _load();
  }

  Future<void> _load() async {
    final ref = widget.file;
    final slot = TdClient.shared.activeSlot;
    if (_loadedId == ref.id && _loadedSlot == slot) return;
    _loadedId = ref.id;
    _loadedSlot = slot;

    final path = await TdFileCenter.shared.pathFor(ref);
    if (!mounted || path == null || _loadedId != ref.id) return;
    final inflated = await _loadInflatedTgsSticker('$slot:${ref.id}', path);
    if (!mounted || _loadedId != ref.id || inflated == null) return;
    await _prewarmTgsComposition(
      inflated,
      () => mounted && _loadedId == ref.id,
    );
    if (!mounted || _loadedId != ref.id) return;
    setState(() => _bytes = inflated);
    widget.onReady?.call();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const SizedBox.expand();
    return Lottie.memory(
      bytes,
      backgroundLoading: true,
      fit: BoxFit.contain,
      animate: widget.animate,
      repeat: widget.animate,
      frameRate: widget.frameRate,
    );
  }
}
