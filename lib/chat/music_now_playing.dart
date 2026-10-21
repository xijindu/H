import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../tdlib/td_image_loader.dart';
import '../tdlib/td_models.dart';

abstract interface class NowPlayingTarget implements Listenable {
  ChatMessage? get current;
  bool get isPlaying;
  bool get isLoading;
  Duration get position;
  Duration get total;
  String get playbackSourceTitle;
  void resume();
  void pause();
  void toggleCurrent();
  void next();
  void previous();
  void seekTo(Duration target);
  void closeWidget();
}

@immutable
class NowPlayingState {
  const NowPlayingState({
    required this.fileId,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.position,
    required this.playing,
    this.artworkPath,
  });

  final int fileId;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final Duration position;
  final bool playing;
  final String? artworkPath;

  Map<String, Object?> toArguments() => {
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': duration.inMilliseconds,
    'positionMs': position.inMilliseconds,
    'playing': playing,
    'artworkPath': artworkPath,
    'labels': {
      'channel': AppStrings.t(AppStringKeys.profileDetailMusic),
      'play': AppStrings.t(AppStringKeys.musicPlayerPlay),
      'pause': AppStrings.t(AppStringKeys.musicPlayerPause),
      'next': AppStrings.t(AppStringKeys.musicPlayerNextTrack),
      'previous': AppStrings.t(AppStringKeys.musicPlayerPreviousTrack),
    },
  };
}

class MusicNowPlayingBridge {
  MusicNowPlayingBridge(
    this.target, {
    this.channel = const MethodChannel(channelName),
    bool? enabled,
    Future<String?> Function(TdFileRef cover)? resolveArtwork,
  }) : _enabled = enabled ?? _platformSupported,
       _resolveArtwork = resolveArtwork ?? _defaultArtwork;

  static const channelName = 'mithka/now_playing';

  static const seekTolerance = Duration(milliseconds: 1500);

  final NowPlayingTarget target;
  final MethodChannel channel;
  final bool _enabled;
  final Future<String?> Function(TdFileRef cover) _resolveArtwork;

  NowPlayingState? _published;
  DateTime? _publishedAt;
  bool _attached = false;
  bool _visible = false;
  int? _artworkFileId;
  String? _artworkPath;

  int _artworkGeneration = 0;

  static bool get _platformSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  static Future<String?> _defaultArtwork(TdFileRef cover) =>
      TdFileCenter.shared.pathFor(cover);

  void attach() {
    if (!_enabled || _attached) return;
    _attached = true;
    channel.setMethodCallHandler(_onCall);
    target.addListener(_sync);
    _sync();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    target.removeListener(_sync);
    channel.setMethodCallHandler(null);
    if (_visible) unawaited(_invoke('clear'));
    _visible = false;
    _published = null;
    _invalidateArtwork();
  }

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'play':
        target.resume();
      case 'pause':
        target.pause();
      case 'toggle':
        target.toggleCurrent();
      case 'next':
        target.next();
      case 'previous':
        target.previous();
      case 'seek':
        final ms = call.arguments;
        if (ms is int) target.seekTo(Duration(milliseconds: ms));
      case 'stop':
        target.closeWidget();
    }
  }

  void _sync() {
    final message = target.current;
    final music = message?.music;
    final file = music?.file;
    if (music == null || file == null) {
      if (_visible) unawaited(_invoke('clear'));
      _visible = false;
      _published = null;
      _invalidateArtwork();
      return;
    }
    if (_artworkFileId != file.id) {
      _artworkFileId = file.id;
      _artworkPath = null;
      _artworkGeneration++;
      final cover = music.cover;
      if (cover != null) unawaited(_loadArtwork(file.id, cover));
    }
    final total = target.total.inMilliseconds > 0
        ? target.total
        : Duration(seconds: music.duration);
    final state = NowPlayingState(
      fileId: file.id,
      title: music.title,
      artist: (music.performer ?? '').trim(),
      album: target.playbackSourceTitle,
      duration: total,
      position: target.position,
      playing: target.isPlaying || target.isLoading,
      artworkPath: _artworkPath,
    );
    if (!_shouldPublish(state)) return;
    _published = state;
    _publishedAt = DateTime.now();
    _visible = true;
    unawaited(_invoke('update', state.toArguments()));
  }

  bool _shouldPublish(NowPlayingState next) {
    final last = _published;
    if (last == null) return true;
    if (last.fileId != next.fileId ||
        last.playing != next.playing ||
        last.title != next.title ||
        last.artist != next.artist ||
        last.album != next.album ||
        last.artworkPath != next.artworkPath ||
        (last.duration - next.duration).abs() > seekTolerance) {
      return true;
    }
    final since = _publishedAt == null
        ? Duration.zero
        : DateTime.now().difference(_publishedAt!);
    final expected = last.playing ? last.position + since : last.position;
    return (next.position - expected).abs() > seekTolerance;
  }

  void _invalidateArtwork() {
    _artworkFileId = null;
    _artworkPath = null;
    _artworkGeneration++;
  }

  Future<void> _loadArtwork(int fileId, TdFileRef cover) async {
    final generation = _artworkGeneration;
    final path = await _resolveArtwork(cover);
    if (!_attached ||
        _artworkFileId != fileId ||
        _artworkGeneration != generation ||
        path == null) {
      return;
    }
    _artworkPath = path;
    _sync();
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
    } on PlatformException {}
  }
}
