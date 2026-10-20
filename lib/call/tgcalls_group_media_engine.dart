import 'package:flutter/services.dart';

import 'group_call_media_engine.dart';

class TgcallsGroupMediaEngine implements GroupCallMediaEngine {
  static const _methods = MethodChannel('handy/call_media');

  @override
  Future<bool> get isSupported async =>
      await _methods.invokeMethod<bool>('isSupported') ?? false;

  @override
  Future<GroupCallJoinPayload> createJoinPayload({
    required int groupCallId,
    required bool isVideo,
  }) async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'createGroup',
      {'groupCallId': groupCallId, 'isVideo': isVideo},
    );
    if (raw == null) {
      throw StateError('tgcalls returned no group-call join payload');
    }
    final audioSourceId = (raw['audioSourceId'] as num?)?.toInt();
    final payload = raw['payload'] as String?;
    if (audioSourceId == null || payload == null || payload.isEmpty) {
      throw StateError('tgcalls returned an invalid group-call join payload');
    }
    return GroupCallJoinPayload(audioSourceId: audioSourceId, payload: payload);
  }

  @override
  Future<void> connect(String responsePayload) => _methods.invokeMethod<void>(
    'connectGroup',
    {'responsePayload': responsePayload},
  );

  @override
  void stop() {
    _methods.invokeMethod<void>('stop').catchError((Object _) {});
  }

  @override
  void setMuted(bool muted) {
    _methods.invokeMethod<void>('setMuted', muted).catchError((Object _) {});
  }

  @override
  void setSpeaker(bool speaker) {
    _methods
        .invokeMethod<void>('setSpeaker', speaker)
        .catchError((Object _) {});
  }

  @override
  Future<GroupCallJoinPayload?> setVideoEnabled(
    bool enabled, {
    bool front = true,
  }) async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'setVideoEnabled',
      {'enabled': enabled, 'front': front},
    );
    if (raw == null) return null;
    final audioSourceId = (raw['audioSourceId'] as num?)?.toInt();
    final payload = raw['payload'] as String?;
    if (audioSourceId == null || payload == null || payload.isEmpty) {
      throw StateError('tgcalls returned an invalid video rejoin payload');
    }
    return GroupCallJoinPayload(audioSourceId: audioSourceId, payload: payload);
  }

  @override
  void switchCamera() {
    _methods.invokeMethod<void>('switchCamera').catchError((Object _) {});
  }

  @override
  void setRequestedVideoChannels(List<GroupCallVideoChannel> channels) {
    _methods
        .invokeMethod<void>(
          'setRequestedVideoChannels',
          channels.map((channel) => channel.toJson()).toList(),
        )
        .catchError((Object error) {
          logGroupCallMediaError('setRequestedVideoChannels', error);
        });
  }

  @override
  void setMediaChannelDescriptions(
    List<GroupCallMediaChannelDescription> descriptions,
  ) {
    _methods
        .invokeMethod<void>(
          'setMediaChannelDescriptions',
          descriptions.map((description) => description.toJson()).toList(),
        )
        .catchError((Object error) {
          logGroupCallMediaError('setMediaChannelDescriptions', error);
        });
  }
}
