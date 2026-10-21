import 'package:flutter/foundation.dart';

class CallReadyConfig {
  CallReadyConfig({
    required this.callId,
    required this.servers,
    required this.encryptionKey,
    required this.config,
    required this.customParameters,
    required this.libraryVersions,
    required this.maxLayer,
    required this.isOutgoing,
    required this.isVideo,
    required this.allowP2p,
  });

  final int callId;
  final List<Map<String, dynamic>> servers;
  final Uint8List encryptionKey;
  final String config;
  final String customParameters;
  final List<String> libraryVersions;
  final int maxLayer;
  final bool isOutgoing;
  final bool isVideo;
  final bool allowP2p;
}

abstract class CallMediaEngine {
  void start(CallReadyConfig config);
  void stop();
  void setMuted(bool muted);
  void setSpeaker(bool speaker);

  void setVideoEnabled(bool enabled, {bool front = true});

  void switchCamera() {}

  void receiveSignaling(Uint8List data) {}

  set onSignalingData(void Function(Uint8List data)? callback) {}

  Future<Map<String, dynamic>?> queryProtocol() async => null;
}

class NoopCallMediaEngine implements CallMediaEngine {
  @override
  void start(CallReadyConfig config) {
    debugPrint(
      '📞 [media] start outgoing=${config.isOutgoing} '
      'video=${config.isVideo} servers=${config.servers.length} '
      'keyBytes=${config.encryptionKey.length} '
      'versions=${config.libraryVersions.join(",")}',
    );
  }

  @override
  void stop() => debugPrint('📞 [media] stop');

  @override
  void setMuted(bool muted) => debugPrint('📞 [media] setMuted $muted');

  @override
  void setSpeaker(bool speaker) => debugPrint('📞 [media] setSpeaker $speaker');

  @override
  void setVideoEnabled(bool enabled, {bool front = true}) =>
      debugPrint('📞 [media] setVideoEnabled $enabled front=$front');

  @override
  void switchCamera() => debugPrint('📞 [media] switchCamera');

  @override
  void receiveSignaling(Uint8List data) {}

  @override
  set onSignalingData(void Function(Uint8List data)? callback) {}

  @override
  Future<Map<String, dynamic>?> queryProtocol() async => null;
}
