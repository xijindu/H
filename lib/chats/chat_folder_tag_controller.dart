import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../theme/app_theme.dart';

const List<Color> chatFolderTagColors = [
  Color(0xFFE85D5D),
  Color(0xFFF09A44),
  Color(0xFF8C6AD8),
  Color(0xFF57A957),
  Color(0xFF45AEB8),
  Color(0xFF4B8CD8),
  Color(0xFFD85C9D),
];

Color? chatFolderTagColor(int colorId) =>
    colorId >= 0 && colorId < chatFolderTagColors.length
    ? chatFolderTagColors[colorId]
    : null;

@immutable
class ChatFolderTag {
  const ChatFolderTag({
    required this.id,
    required this.title,
    required this.color,
  });

  final int id;
  final String title;
  final Color? color;

  @override
  bool operator ==(Object other) =>
      other is ChatFolderTag &&
      other.id == id &&
      other.title == title &&
      other.color == color;

  @override
  int get hashCode => Object.hash(id, title, color);
}

typedef ChatFolderTagQuery =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

class ChatFolderTagController extends ChangeNotifier {
  ChatFolderTagController(
    this._preferences, {
    ChatFolderTagQuery? query,
    Stream<Map<String, dynamic>>? folderUpdates,
    Map<String, dynamic>? initialFolders,
  }) : _query = query ?? TdClient.shared.query {
    _enabled = _preferences?.getBool(preferenceKey) ?? false;
    final seed =
        initialFolders ??
        (folderUpdates == null
            ? TdClient.shared.latestChatFoldersUpdate
            : null);
    if (seed != null) _applyFolders(seed, notify: false);
    _updates = (folderUpdates ?? TdClient.shared.updatesOf('updateChatFolders'))
        .listen(_applyFolders);
  }

  static const preferenceKey = 'mithka.chatFolderTags.v1';

  final SharedPreferences? _preferences;
  final ChatFolderTagQuery _query;
  StreamSubscription<Map<String, dynamic>>? _updates;

  Map<int, ChatFolderTag> _folders = const {};
  bool _enabled = false;
  bool _isPremium = false;

  bool? _serverEnabled;

  bool get enabled => _enabled;

  bool get isPremium => _isPremium;

  Map<int, ChatFolderTag> get folders => _folders;

  List<ChatFolderTag> tagsFor(Set<int> folderIds) {
    if (!_enabled || _folders.isEmpty || folderIds.isEmpty) {
      return const <ChatFolderTag>[];
    }
    return [
      for (final entry in _folders.entries)
        if (folderIds.contains(entry.key)) entry.value,
    ];
  }

  Future<void> refresh() async {
    final isPremium = await _optionBool('is_premium') ?? false;
    final enabled = isPremium
        ? (_serverEnabled ?? _preferences?.getBool(preferenceKey) ?? false)
        : _preferences?.getBool(preferenceKey) ?? false;
    if (_isPremium == isPremium && _enabled == enabled) {
      unawaited(_warmFolderLists());
      return;
    }
    _isPremium = isPremium;
    _enabled = enabled;
    notifyListeners();
    unawaited(_warmFolderLists());
  }

  static const _warmLimit = 500;

  final Set<int> _warmedFolders = {};

  Future<void> _warmFolderLists() async {
    if (!_enabled) return;
    for (final id in _folders.keys.toList()) {
      if (!_warmedFolders.add(id)) continue;
      try {
        await _query({
          '@type': 'loadChats',
          'chat_list': {'@type': 'chatListFolder', 'chat_folder_id': id},
          'limit': _warmLimit,
        });
      } catch (_) {
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    unawaited(_warmFolderLists());
    await _preferences?.setBool(preferenceKey, value);
    if (!_isPremium) return;
    try {
      await _query({
        '@type': 'toggleChatFolderTags',
        'are_tags_enabled': value,
      });
    } catch (_) {
    }
  }

  void _applyFolders(Map<String, dynamic> update, {bool notify = true}) {
    final raw =
        update.objects('chat_folders') ??
        update.objects('chat_folder_infos') ??
        const <Map<String, dynamic>>[];
    final folders = <int, ChatFolderTag>{};
    for (final folder in raw) {
      final id = folder.integer('id') ?? folder.integer('chat_folder_id');
      if (id == null) continue;
      final title =
          folder.obj('name')?.obj('text')?.str('text') ??
          folder.obj('title')?.str('text') ??
          folder.str('title') ??
          '';
      if (title.trim().isEmpty) continue;
      folders[id] = ChatFolderTag(
        id: id,
        title: title,
        color: chatFolderTagColor(folder.integer('color_id') ?? -1),
      );
    }

    final serverEnabled = update.boolean('are_tags_enabled');
    var changed = false;
    if (serverEnabled != null && serverEnabled != _serverEnabled) {
      _serverEnabled = serverEnabled;
      if (_isPremium && _enabled != serverEnabled) {
        _enabled = serverEnabled;
        changed = true;
      }
    }
    if (!_sameFolders(folders)) {
      _folders = folders;
      changed = true;
    }
    if (changed && notify) notifyListeners();
    unawaited(_warmFolderLists());
  }

  bool _sameFolders(Map<int, ChatFolderTag> next) {
    if (next.length != _folders.length) return false;
    for (final entry in next.entries) {
      if (_folders[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<bool?> _optionBool(String name) async {
    try {
      final option = await _query({'@type': 'getOption', 'name': name});
      return option.boolean('value');
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    _updates = null;
    super.dispose();
  }
}

double chatListRowExtentFor(BuildContext context, {bool listen = true}) =>
    AppMetric.chatListRowExtent(
      context,
      null,
      (listen
                  ? context.watch<ChatFolderTagController?>()
                  : context.read<ChatFolderTagController?>())
              ?.enabled ??
          false,
    );
