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

  Future<GroupCallJoinPayload?> setVideoEnabled(
    bool enabled, {
    bool front = true,
  });
  void switchCamera();

  void setRequestedVideoChannels(List<GroupCallVideoChannel> channels);

  void setMediaChannelDescriptions(
    List<GroupCallMediaChannelDescription> descriptions,
  );
}

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
