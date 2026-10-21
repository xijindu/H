import 'package:handy/tdlib/json_helpers.dart';
import 'package:handy/tdlib/td_client.dart';
import 'package:handy/tdlib/td_models.dart' show ChatKind;

class ScopeNotificationSettings {
  ScopeNotificationSettings._();
  static final ScopeNotificationSettings shared = ScopeNotificationSettings._();

  static const _private = 'notificationSettingsScopePrivateChats';
  static const _group = 'notificationSettingsScopeGroupChats';
  static const _channel = 'notificationSettingsScopeChannelChats';

  final Map<String, int> _muteFor = {};
  final Map<String, bool> _showPreview = {};
  final Map<String, int> _soundId = {};

  Future<void> load() async {
    final client = TdClient.shared;
    for (final scope in const [_private, _group, _channel]) {
      try {
        final s = await client.query({
          '@type': 'getScopeNotificationSettings',
          'scope': {'@type': scope},
        });
        _muteFor[scope] = s.integer('mute_for') ?? 0;
        _showPreview[scope] = s.boolean('show_preview') ?? true;
        _soundId[scope] = s.int64('sound_id') ?? -1;
      } catch (_) {
        _muteFor[scope] = _muteFor[scope] ?? 0;
        _showPreview[scope] = _showPreview[scope] ?? true;
        _soundId[scope] = _soundId[scope] ?? -1;
      }
    }
  }

  void update(String scope, int muteFor) {
    _muteFor[scope] = muteFor;
  }

  void updateShowPreview(String scope, bool showPreview) {
    _showPreview[scope] = showPreview;
  }

  void updateSoundId(String scope, int soundId) {
    _soundId[scope] = soundId;
  }

  int getMuteForScope(String tag) => _muteFor[tag] ?? 0;

  String scopeTagForKind(ChatKind kind) {
    switch (kind) {
      case ChatKind.privateChat:
        return _private;
      case ChatKind.group:
        return _group;
      case ChatKind.channel:
        return _channel;
      default:
        return _private;
    }
  }

  String _scopeForChat(Map<String, dynamic> chat) {
    final type = chat.obj('type');
    switch (type?.type) {
      case 'chatTypePrivate':
      case 'chatTypeSecret':
        return _private;
      case 'chatTypeBasicGroup':
        return _group;
      case 'chatTypeSupergroup':
        final isChannel = type?.boolean('is_channel') ?? false;
        return isChannel ? _channel : _group;
      default:
        return _private;
    }
  }

  String scopeTagForChat(Map<String, dynamic> chat) => _scopeForChat(chat);

  bool isMuted(Map<String, dynamic> chat) {
    final settings = chat.obj('notification_settings');
    final useDefault = settings?.boolean('use_default_mute_for') ?? false;
    final muteFor = useDefault
        ? getMuteForScope(_scopeForChat(chat))
        : (settings?.integer('mute_for') ?? 0);
    return muteFor > 0;
  }

  bool showPreview(Map<String, dynamic> chat) {
    final settings = chat.obj('notification_settings');
    final useDefault = settings?.boolean('use_default_show_preview') ?? true;
    return useDefault
        ? (_showPreview[_scopeForChat(chat)] ?? true)
        : (settings?.boolean('show_preview') ?? true);
  }

  bool soundEnabled(Map<String, dynamic> chat) {
    final settings = chat.obj('notification_settings');
    final useDefault = settings?.boolean('use_default_sound') ?? true;
    final soundId = useDefault
        ? (_soundId[_scopeForChat(chat)] ?? -1)
        : (settings?.int64('sound_id') ?? -1);
    return soundId != 0;
  }
}
