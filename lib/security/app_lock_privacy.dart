import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppLockPrivacyPlatform {
  const AppLockPrivacyPlatform._();

  static const _channel = MethodChannel('handy/app_lock_privacy');

  static Future<void> setPrivacyShieldVisible(bool visible) async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      return;
    }
    await _channel.invokeMethod<void>('setPrivacyShieldVisible', {
      'visible': visible,
    });
  }
}
