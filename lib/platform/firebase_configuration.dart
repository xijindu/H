import 'package:flutter/services.dart';

/// Reports whether the native app has a usable Firebase configuration.
class FirebaseConfiguration {
  FirebaseConfiguration._();

  static const _channel = MethodChannel('handy/firebase_configuration');

  static Future<bool> get isAvailable async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }
}
