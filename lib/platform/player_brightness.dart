import 'package:flutter/services.dart';

class PlayerBrightness {
  PlayerBrightness._();

  static const _channel = MethodChannel('handy/player_brightness');

  static Future<double?> current() async {
    try {
      return await _channel.invokeMethod<double>('get');
    } catch (_) {
      return null;
    }
  }

  static Future<void> set(double value) async {
    try {
      await _channel.invokeMethod<void>('set', value.clamp(0.01, 1.0));
    } catch (_) {}
  }

  static Future<void> restore(double value) async {
    try {
      await _channel.invokeMethod<void>('restore', value.clamp(0.01, 1.0));
    } catch (_) {}
  }
}

class PlayerBrightnessSession {
  PlayerBrightnessSession._(this.initialBrightness);

  final double initialBrightness;
  Future<void> _pendingWrite = Future<void>.value();
  Future<void>? _restoreFuture;
  bool _changed = false;
  bool _restoreRequested = false;

  static Future<PlayerBrightnessSession?> capture() async {
    final initialBrightness = await PlayerBrightness.current();
    if (initialBrightness == null) return null;
    return PlayerBrightnessSession._(initialBrightness);
  }

  Future<void> set(double value) {
    if (_restoreRequested) return Future<void>.value();
    _changed = true;
    final write = _pendingWrite.then((_) => PlayerBrightness.set(value));
    _pendingWrite = write;
    return write;
  }

  Future<void> restore() => _restoreFuture ??= _restore();

  Future<void> _restore() async {
    _restoreRequested = true;
    await _pendingWrite;
    if (_changed) await PlayerBrightness.restore(initialBrightness);
  }
}
