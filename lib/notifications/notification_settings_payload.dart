import '../tdlib/json_helpers.dart';

enum StoryNotificationMode { topFive, all, off }

Map<String, dynamic> scopeNotificationSettingsPayload(
  Map<String, dynamic> settings,
) {
  return {
    '@type': 'scopeNotificationSettings',
    'mute_for': settings.integer('mute_for') ?? 0,
    'sound_id': _notificationSoundId(settings.int64('sound_id')),
    'show_preview': settings.boolean('show_preview') ?? true,
    'use_default_mute_stories':
        settings.boolean('use_default_mute_stories') ?? true,
    'mute_stories': settings.boolean('mute_stories') ?? false,
    'story_sound_id': _notificationSoundId(settings.int64('story_sound_id')),
    'show_story_poster':
        settings.boolean('show_story_poster') ??
        settings.boolean('show_story_sender') ??
        true,
    'disable_pinned_message_notifications':
        settings.boolean('disable_pinned_message_notifications') ?? false,
    'disable_mention_notifications':
        settings.boolean('disable_mention_notifications') ?? false,
  };
}

StoryNotificationMode storyNotificationMode(Map<String, dynamic>? settings) {
  if (settings?.boolean('use_default_mute_stories') ?? true) {
    return StoryNotificationMode.topFive;
  }
  return (settings?.boolean('mute_stories') ?? false)
      ? StoryNotificationMode.off
      : StoryNotificationMode.all;
}

Map<String, dynamic> withStoryNotificationMode(
  Map<String, dynamic> settings,
  StoryNotificationMode mode,
) {
  return {
    ...settings,
    'use_default_mute_stories': mode == StoryNotificationMode.topFive,
    'mute_stories': mode == StoryNotificationMode.off,
  };
}

Map<String, dynamic> reactionNotificationSettingsPayload(
  Map<String, dynamic> settings,
) {
  return {
    '@type': 'reactionNotificationSettings',
    'message_reaction_source':
        settings.obj('message_reaction_source') ??
        const {'@type': 'reactionNotificationSourceContacts'},
    'story_reaction_source':
        settings.obj('story_reaction_source') ??
        const {'@type': 'reactionNotificationSourceContacts'},
    'sound_id': _notificationSoundId(settings.int64('sound_id')),
    'show_preview': settings.boolean('show_preview') ?? true,
  };
}

bool reactionSourceEnabled(Map<String, dynamic>? source) =>
    source?.type != 'reactionNotificationSourceNone';

Map<String, dynamic> reactionSource(bool enabled) => {
  '@type': enabled
      ? 'reactionNotificationSourceContacts'
      : 'reactionNotificationSourceNone',
};

int _notificationSoundId(int? value) => value != null && value > 0 ? value : 0;

bool reactionSourceIsEveryone(Map<String, dynamic>? source) =>
    source?.type == 'reactionNotificationSourceAll';

Map<String, dynamic> reactionSourceWithAudience({required bool everyone}) => {
  '@type': everyone
      ? 'reactionNotificationSourceAll'
      : 'reactionNotificationSourceContacts',
};

Map<String, dynamic> inheritedChatNotificationSettings({
  required int muteFor,
  bool useDefaultMuteFor = false,
}) {
  return {
    '@type': 'chatNotificationSettings',
    'use_default_mute_for': useDefaultMuteFor,
    'mute_for': muteFor,
    'use_default_sound': true,
    'use_default_show_preview': true,
    'use_default_mute_stories': true,
    'use_default_story_sound': true,
    'use_default_show_story_poster': true,
    'use_default_disable_pinned_message_notifications': true,
    'use_default_disable_mention_notifications': true,
  };
}

bool hasLegacyHiddenNotificationPreview(Map<String, dynamic>? settings) {
  if (settings == null) return false;
  return !(settings.boolean('use_default_show_preview') ?? false) &&
      !(settings.boolean('show_preview') ?? false) &&
      !(settings.boolean('use_default_sound') ?? false) &&
      (settings.int64('sound_id') ?? 0) == 0 &&
      !(settings.boolean('use_default_mute_stories') ?? false) &&
      !(settings.boolean('mute_stories') ?? false) &&
      !(settings.boolean('use_default_story_sound') ?? false) &&
      (settings.int64('story_sound_id') ?? 0) == 0 &&
      !(settings.boolean('use_default_show_story_poster') ??
          settings.boolean('use_default_show_story_sender') ??
          false) &&
      !(settings.boolean('show_story_poster') ??
          settings.boolean('show_story_sender') ??
          false) &&
      !(settings.boolean('use_default_disable_pinned_message_notifications') ??
          false) &&
      !(settings.boolean('disable_pinned_message_notifications') ?? false) &&
      !(settings.boolean('use_default_disable_mention_notifications') ??
          false) &&
      !(settings.boolean('disable_mention_notifications') ?? false);
}

Map<String, dynamic> repairedChatNotificationSettings(
  Map<String, dynamic> settings,
) {
  return inheritedChatNotificationSettings(
    muteFor: settings.integer('mute_for') ?? 0,
    useDefaultMuteFor: settings.boolean('use_default_mute_for') ?? false,
  );
}
