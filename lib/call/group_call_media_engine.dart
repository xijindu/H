import 'package:flutter/foundation.dart';

class GroupCallJoinPayload {
  const GroupCallJoinPayload({
    required this.audioSourceId,
    required this.payload,
  });

  final int audioSourceId;
  final String payload;
}

class GroupCallVideoSourceGroup {
  const GroupCallVideoSourceGroup({
    required this.semantics,
    required this.sourceIds,
  });

  final String semantics;
  final List<int> sourceIds;

  Map<String, dynamic> toJson() => {
    'semantics': semantics,
    'sourceIds': sourceIds,
  };
}

enum GroupCallVideoQuality { thumbnail, medium, full }

class GroupCallVideoChannel {
  const GroupCallVideoChannel({
    required this.audioSourceId,
    required this.userId,
    required this.endpointId,
    required this.sourceGroups,
    this.minQuality = GroupCallVideoQuality.thumbnail,
    this.maxQuality = GroupCallVideoQuality.full,
  });

  final int audioSourceId;
  final int userId;
  final String endpointId;
  final List<GroupCallVideoSourceGroup> sourceGroups;
  final GroupCallVideoQuality minQuality;
  final GroupCallVideoQuality maxQuality;

  Map<String, dynamic> toJson() => {
    'audioSourceId': audioSourceId,
    'userId': userId,
    'endpointId': endpointId,
    'sourceGroups': sourceGroups.map((group) => group.toJson()).toList(),
    'minQuality': minQuality.name,
    'maxQuality': maxQuality.name,
  };
}

class GroupCallMediaChannelDescription {
  const GroupCallMediaChannelDescription({
    required this.audioSourceId,
    required this.userId,
  });

  final int audioSourceId;
  final int userId;

  Map<String, dynamic> toJson() => {
    'audioSourceId': audioSourceId,
    'userId': userId,
  };
}

/// Media transport used by Telegram video chats. TDLib owns the Telegram
/// signaling objects, while this engine creates the tgcalls join payload and
/// carries the actual microphone, speaker, camera, and remote video streams.
abstract class GroupCallMediaEngine {
  Future<bool> get isSupported;

  Future<GroupCallJoinPayload> createJoinPayload({
    required int groupCallId,
    required bool isVideo,
  });

  Future<void> connect(String responsePayload);
  void stop();
  void setMuted(bool muted);
  void setSpeaker(bool speaker);

  /// Telegram's native group-call engine emits a fresh join payload when local
  /// video is enabled or disabled. Android's engine currently returns `null`
  /// because it renegotiates internally.
  Future<GroupCallJoinPayload?> setVideoEnabled(
    bool enabled, {
    bool front = true,
  });
  void switchCamera();

  /// Replaces the complete requested-channel set, matching Telegram iOS's
  /// `setRequestedVideoChannels` subscription model.
  void setRequestedVideoChannels(List<GroupCallVideoChannel> channels);

  /// Supplies the SSRC-to-participant lookup used by Telegram's native media
  /// engine when it asks for incoming audio channel descriptions.
  void setMediaChannelDescriptions(
    List<GroupCallMediaChannelDescription> descriptions,
  );
}

/// Kept for platforms whose tgcalls binary isn't present. It fails before
/// TDLib is asked to join, instead of advertising a fake media payload.
class UnsupportedGroupCallMediaEngine implements GroupCallMediaEngine {
  @override
  Future<bool> get isSupported async => false;

  @override
  Future<GroupCallJoinPayload> createJoinPayload({
    required int groupCallId,
    required bool isVideo,
  }) {
    return Future.error(
      UnsupportedError(
        'Telegram group-call media is unavailable on this build',
      ),
    );
  }

  @override
  Future<void> connect(String responsePayload) async {}

  @override
  void stop() {}

  @override
  void setMuted(bool muted) {}

  @override
  void setSpeaker(bool speaker) {}

  @override
  Future<GroupCallJoinPayload?> setVideoEnabled(
    bool enabled, {
    bool front = true,
  }) async => null;

  @override
  void switchCamera() {}

  @override
  void setRequestedVideoChannels(List<GroupCallVideoChannel> channels) {}

  @override
  void setMediaChannelDescriptions(
    List<GroupCallMediaChannelDescription> descriptions,
  ) {}
}

void logGroupCallMediaError(String operation, Object error) {
  debugPrint('👥 [group-media] $operation failed: $error');
}
