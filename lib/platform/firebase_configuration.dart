import 'package:flutter/services.dart';

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
