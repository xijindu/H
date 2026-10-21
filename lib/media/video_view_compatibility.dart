import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../chat/video_playback_preferences.dart';

VideoViewType _preferredVideoViewType = VideoViewType.textureView;

@visibleForTesting
bool needsDirectVideoSurface({
  int? sdkInt,
  required String? manufacturer,
  required String? model,
  required String? hardware,
}) {
  if (sdkInt != null && sdkInt >= 34) return true;

  final normalizedManufacturer = manufacturer?.trim().toLowerCase();
  final normalizedModel = model?.trim().toLowerCase();
  final normalizedHardware = hardware?.trim().toLowerCase();
  return normalizedManufacturer == 'nothing' &&
      normalizedModel == 'a142' &&
      normalizedHardware == 'mt6886';
}

VideoViewType get preferredCompatibleVideoViewType => _preferredVideoViewType;

@visibleForTesting
void resetCompatibleVideoViewType() {
  _preferredVideoViewType = VideoViewType.textureView;
}

Future<void> initializeCompatibleVideoViewType() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    _preferredVideoViewType = VideoViewType.textureView;
    return;
  }
  try {
    final preferences = await VideoPlaybackPreferences.load();
    if (!preferences.androidVideoCompatibility) {
      _preferredVideoViewType = VideoViewType.textureView;
      return;
    }
    final info = await const MethodChannel(
      'handy/app_info',
    ).invokeMapMethod<String, Object?>('info');
    if (needsDirectVideoSurface(
      sdkInt: info?['sdkInt'] as int?,
      manufacturer: info?['manufacturer'] as String?,
      model: info?['model'] as String?,
      hardware: info?['hardware'] as String?,
    )) {
      _preferredVideoViewType = VideoViewType.platformView;
      return;
    }
  } catch (_) {
  }
  _preferredVideoViewType = VideoViewType.textureView;
}
