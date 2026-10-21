import 'package:flutter/services.dart';

class ScreenWakelock {
  ScreenWakelock._();

  static const _channel = MethodChannel('handy/screen_wakelock');

  static Future<void> enable() async {
    try {
      await _channel.invokeMethod<void>('enable');
    } on MissingPluginException {
    } catch (_) {}
  }

  static Future<void> disable() async {
    try {
      await _channel.invokeMethod<void>('disable');
    } on MissingPluginException {
    } catch (_) {}
  }
}
