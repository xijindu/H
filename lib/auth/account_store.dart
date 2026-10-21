import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/custom_emoji.dart';
import '../chat/emoji_store.dart';
import '../notifications/notification_preferences.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import 'auth_manager.dart';

class AccountSummary {
  AccountSummary({
    required this.slot,
    required this.userId,
    required this.name,
    required this.phone,
    this.avatarPath,
    this.emojiStatusId = 0,
    this.isPremium = false,
  });
  final int slot;
  final int userId;
  final String name;
  final String phone;
  final String? avatarPath;
  final int emojiStatusId;

  final bool isPremium;

  AccountSummary copyWith({String? avatarPath}) => AccountSummary(
    slot: slot,
    userId: userId,
    name: name,
    phone: phone,
    avatarPath: avatarPath ?? this.avatarPath,
    emojiStatusId: emojiStatusId,
    isPremium: isPremium,
  );

  Map<String, Object?> toJson() => {
    'slot': slot,
    'userId': userId,
    'name': name,
    'phone': phone,
    'avatarPath': avatarPath,
    'emojiStatusId': emojiStatusId,
    'isPremium': isPremium,
  };

  static AccountSummary? fromJson(Object? json) {
    if (json is! Map) return null;
    final slot = json['slot'];
    final userId = json['userId'];
    final name = json['name'];
    if (slot is! int || userId is! int || name is! String || name.isEmpty) {
      return null;
    }
    final avatarPath = json['avatarPath'];
    final phone = json['phone'];
    final statusId = json['emojiStatusId'];
    return AccountSummary(
      slot: slot,
      userId: userId,
      name: name,
      phone: phone is String ? phone : '',
      avatarPath: avatarPath is String ? avatarPath : null,
      emojiStatusId: statusId is int ? statusId : 0,
      isPremium: json['isPremium'] == true,
    );
  }
}

sealed class _SlotIdentity {
  const _SlotIdentity();
}

final class _SlotResolved extends _SlotIdentity {
  const _SlotResolved(this.summary, this.avatarFileId);
  final AccountSummary summary;
  final int? avatarFileId;
}

final class _SlotGone extends _SlotIdentity {
  const _SlotGone();
}

final class _SlotUnknown extends _SlotIdentity {
  const _SlotUnknown();
}

class AccountStore extends ChangeNotifier {
  AccountStore(SharedPreferences prefs)
    : _prefs = prefs,
      _activeSlot = prefs.getInt('drachma.activeSlot') ?? 0,
      _summaries = _readCachedSummaries(prefs) {
    _selfIds.addAll(_summaries.map((summary) => summary.userId));
    _pendingSlot = prefs.getInt(_pendingKey);
    _returnSlot = prefs.getInt(_returnKey) ?? 0;
    TdClient.shared
        .updatesOfAny(const ['updateAuthorizationState', 'updateUser'])
        .listen((u) {
          if (u.type == 'updateAuthorizationState') {
            final state = u.obj('authorization_state');
            if (state?.type == 'authorizationStateReady') {
              unawaited(refresh());
            }
            return;
          }
          if (u.type != 'updateUser') return;
          final uid = u.obj('user')?.int64('id');
          if (uid != null && _selfIds.contains(uid)) refresh();
        });
  }

  static const _pendingKey = 'drachma.pendingSlot';
  static const _returnKey = 'drachma.pendingReturnSlot';
  static const _summariesKey = 'drachma.accountSummaries';

  static List<AccountSummary> _readCachedSummaries(SharedPreferences prefs) {
    final raw = prefs.getString(_summariesKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map(AccountSummary.fromJson)
          .whereType<AccountSummary>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  void _writeCachedSummaries() {
    unawaited(
      _prefs.setString(
        _summariesKey,
        jsonEncode([for (final summary in _summaries) summary.toJson()]),
      ),
    );
  }

  final SharedPreferences _prefs;
  int _activeSlot;
  List<AccountSummary> _summaries;
  final Set<int> _selfIds = {};

  int? _pendingSlot;
  int _returnSlot = 0;

  void _persistPending() {
    final p = _pendingSlot;
    if (p == null) {
      _prefs.remove(_pendingKey);
      _prefs.remove(_returnKey);
    } else {
      _prefs.setInt(_pendingKey, p);
      _prefs.setInt(_returnKey, _returnSlot);
    }
  }

  int get activeSlot => _activeSlot;
  List<AccountSummary> get summaries => _summaries;

  bool get activeIsPremium {
    for (final summary in _summaries) {
      if (summary.slot == _activeSlot) return summary.isPremium;
    }
    return false;
  }

  int? get activeUserId {
    for (final summary in _summaries) {
      if (summary.slot == _activeSlot) return summary.userId;
    }
    return null;
  }

  void _activeAccountChanged() {
    CustomEmojiCenter.shared.reset();
    EmojiStore.shared.reset();
  }

  bool get hasPendingAdd => _pendingSlot != null && _pendingSlot == _activeSlot;

  String? get returnAccountName {
    if (!hasPendingAdd) return null;
    for (final s in _summaries) {
      if (s.slot == _returnSlot) return s.name;
    }
    return null;
  }

  Future<void> recoverPendingAddOnStartup(AuthManager auth) async {
    final pending = _pendingSlot;
    if (pending == null) return;

    for (var i = 0; i < 25; i += 1) {
      if (TdClient.shared.configuredSlots.contains(pending)) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (_pendingSlot != pending ||
        !TdClient.shared.configuredSlots.contains(pending)) {
      return;
    }
    if (TdClient.shared.activeSlot != pending) return;

    final preferredReturn =
        TdClient.shared.configuredSlots.contains(_returnSlot) &&
            _returnSlot != pending &&
            await _slotIsReady(_returnSlot)
        ? _returnSlot
        : null;
    final target = preferredReturn ?? await _nextReadySlot(after: pending);
    if (target == null || target == pending) return;

    _pendingSlot = null;
    _persistPending();
    TdClient.shared.setActive(target);
    _activeAccountChanged();
    _activeSlot = target;
    TdClient.shared.removeSlot(pending);
    await TdClient.shared.deleteSlotData(pending);
    notifyListeners();
    auth.reloadAuthState();
    await refresh();
  }

  Future<void> refresh() async {
    _activeSlot = TdClient.shared.activeSlot;
    final slots = TdClient.shared.configuredSlots;
    final ordered = [
      if (slots.contains(_activeSlot)) _activeSlot,
      ...slots.where((slot) => slot != _activeSlot),
    ];
    final resolved = <int, AccountSummary?>{};

    void publish() {
      final cached = {for (final summary in _summaries) summary.slot: summary};
      _summaries = [
        for (final slot in slots)
          if (resolved.containsKey(slot)) ?resolved[slot] else ?cached[slot],
      ];
      _writeCachedSummaries();
      notifyListeners();
    }

    for (final slot in ordered) {
      switch (await _identityForSlot(slot)) {
        case _SlotResolved(:final summary, :final avatarFileId):
          resolved[slot] = summary;
          publish();
          final avatarPath = await _downloadAvatar(slot, avatarFileId);
          if (avatarPath != null && avatarPath != summary.avatarPath) {
            resolved[slot] = summary.copyWith(avatarPath: avatarPath);
            publish();
          }
        case _SlotGone():
          resolved[slot] = null;
          publish();
        case _SlotUnknown():
          break;
      }
    }
    publish();
  }

  Future<_SlotIdentity> _identityForSlot(int slot) async {
    final cid = TdClient.shared.clientId(slot);
    if (cid == null) return const _SlotUnknown();
    Map<String, dynamic> me;
    try {
      me = await TdClient.shared.queryTo({'@type': 'getMe'}, cid);
    } on TdError catch (error) {
      return error.code == 401 ? const _SlotGone() : const _SlotUnknown();
    } catch (_) {
      return const _SlotUnknown();
    }
    final selfId = me.int64('id');
    if (selfId != null) {
      _selfIds.add(selfId);
      if (slot == _pendingSlot) {
        _pendingSlot = null;
        _persistPending();
      }
    }
    final name = TDParse.userName(me);
    if (selfId == null || name.isEmpty) return const _SlotGone();
    final phone = TDParse.formatPhone(me.str('phone_number'));
    String? cachedAvatar;
    for (final summary in _summaries) {
      if (summary.slot == slot && summary.userId == selfId) {
        cachedAvatar = summary.avatarPath;
      }
    }
    final avatarFileId = me.obj('profile_photo')?.obj('small')?.integer('id');
    return _SlotResolved(
      AccountSummary(
        slot: slot,
        userId: selfId,
        name: name,
        phone: phone,
        avatarPath: avatarFileId == null ? null : cachedAvatar,
        emojiStatusId: TDParse.emojiStatusCustomEmojiId(me.obj('emoji_status')),
        isPremium: me.boolean('is_premium') ?? false,
      ),
      avatarFileId,
    );
  }

  Future<String?> _downloadAvatar(int slot, int? fileId) async {
    final cid = TdClient.shared.clientId(slot);
    if (cid == null || fileId == null) return null;
    try {
      final res = await TdClient.shared.queryTo({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': 1,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      }, cid);
      final path = res.obj('local')?.str('path');
      return path == null || path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  void switchTo(int slot, AuthManager auth) {
    if (slot == _activeSlot) return;
    TdClient.shared.setActive(slot);
    _activeAccountChanged();
    _activeSlot = slot;
    notifyListeners();
    auth.reloadAuthState();
    refresh();
  }

  void addAccount(AuthManager auth) {
    _returnSlot = _activeSlot;
    final slot = TdClient.shared.addSlot();
    _pendingSlot = slot;
    _persistPending();
    TdClient.shared.setActive(slot);
    _activeAccountChanged();
    _activeSlot = slot;
    notifyListeners();
    auth.reloadAuthState();
    refresh();
  }

  void cancelAddAccount(AuthManager auth) {
    final pending = _pendingSlot;
    if (pending == null) return;
    _pendingSlot = null;
    _persistPending();
    final slots = TdClient.shared.configuredSlots;
    final target = slots.contains(_returnSlot) && _returnSlot != pending
        ? _returnSlot
        : slots.firstWhere((s) => s != pending, orElse: () => pending);
    if (target == pending) {
      _activeSlot = TdClient.shared.replaceActiveWithFreshLoginSlot();
      _activeAccountChanged();
    } else {
      TdClient.shared.setActive(target);
      _activeAccountChanged();
      _activeSlot = target;
      TdClient.shared.removeSlot(pending);
    }
    notifyListeners();
    auth.reloadAuthState();
    refresh();
  }

  Future<void> removeAccount(int slot, AuthManager auth) async {
    final slots = TdClient.shared.configuredSlots;
    if (!slots.contains(slot)) return;
    final userId = await _userIdForSlot(slot);
    if (slots.length <= 1) {
      if (slot == _pendingSlot) {
        _pendingSlot = null;
        _persistPending();
      }
      _activeSlot = TdClient.shared.replaceActiveWithFreshLoginSlot();
      _activeAccountChanged();
      await TdClient.shared.deleteSlotData(slot);
      if (userId != null) {
        await NotificationPreferences.shared.removeAccount(userId);
      }
      notifyListeners();
      auth.reloadAuthState();
      await refresh();
      return;
    }
    if (slot == _activeSlot) {
      final target = slots.firstWhere((s) => s != slot);
      TdClient.shared.setActive(target);
      _activeAccountChanged();
      _activeSlot = target;
      auth.reloadAuthState();
    }
    if (slot == _pendingSlot) {
      _pendingSlot = null;
      _persistPending();
    }
    TdClient.shared.removeSlot(slot);
    await TdClient.shared.deleteSlotData(slot);
    if (userId != null) {
      await NotificationPreferences.shared.removeAccount(userId);
    }
    notifyListeners();
    await refresh();
  }

  Future<void> logOutActive(AuthManager auth) =>
      logOutAccount(_activeSlot, auth);

  Future<void> logOutAccount(int slot, AuthManager auth) async {
    final userId = await _userIdForSlot(slot);
    final slots = TdClient.shared.configuredSlots;
    if (!slots.contains(slot)) return;
    final oldClientId = TdClient.shared.clientId(slot);
    final isActiveSlot = slot == _activeSlot;
    final target = isActiveSlot ? await _nextReadySlot(after: slot) : null;

    if (isActiveSlot && target != null) {
      TdClient.shared.setActive(target);
      _activeAccountChanged();
      _activeSlot = target;
      if (slot == _pendingSlot) {
        _pendingSlot = null;
        _persistPending();
      }
      notifyListeners();
      auth.reloadAuthState();
    }

    if (oldClientId != null) {
      try {
        await TdClient.shared
            .queryTo({'@type': 'logOut'}, oldClientId)
            .timeout(const Duration(seconds: 8));
      } catch (_) {}
    }

    if (slot == _pendingSlot) {
      _pendingSlot = null;
      _persistPending();
    }

    if (isActiveSlot && target == null) {
      _activeSlot = TdClient.shared.replaceActiveWithFreshLoginSlot();
      _activeAccountChanged();
      notifyListeners();
      auth.reloadAuthState();
    } else if (TdClient.shared.configuredSlots.contains(slot)) {
      TdClient.shared.removeSlot(slot);
    }
    await TdClient.shared.deleteSlotData(slot);
    if (userId != null) {
      await NotificationPreferences.shared.removeAccount(userId);
    }
    await refresh();
  }

  Future<int?> _userIdForSlot(int slot) async {
    for (final summary in _summaries) {
      if (summary.slot == slot) return summary.userId;
    }
    final cid = TdClient.shared.clientId(slot);
    if (cid == null) return null;
    try {
      final me = await TdClient.shared
          .queryTo({'@type': 'getMe'}, cid)
          .timeout(const Duration(seconds: 2));
      return me.int64('id');
    } catch (_) {
      return null;
    }
  }

  Future<int?> _nextReadySlot({required int after}) async {
    final slots = TdClient.shared.configuredSlots;
    if (slots.length <= 1) return null;
    final index = slots.indexOf(after);
    final candidates = <int>[
      if (index >= 0) ...slots.skip(index + 1),
      if (index >= 0) ...slots.take(index),
      if (index < 0) ...slots,
    ].where((slot) => slot != after);
    for (final slot in candidates) {
      if (await _slotIsReady(slot)) return slot;
    }
    return null;
  }

  Future<bool> _slotIsReady(int slot) async {
    final cid = TdClient.shared.clientId(slot);
    if (cid == null) return false;
    try {
      final state = await TdClient.shared
          .queryTo({'@type': 'getAuthorizationState'}, cid)
          .timeout(const Duration(seconds: 2));
      if (state.type == 'authorizationStateReady') return true;
    } catch (_) {}
    try {
      await TdClient.shared
          .queryTo({'@type': 'getMe'}, cid)
          .timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {}
    return false;
  }
}
