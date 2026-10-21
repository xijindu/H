import 'dart:collection';

import '../tdlib/td_models.dart';
import 'chat_first_contact_info.dart';

class ChatSessionRenderState {
  const ChatSessionRenderState({
    required this.messages,
    required this.anchoredHistory,
    required this.olderHistoryExhausted,
    this.firstContactInfo,
  });

  final List<ChatMessage> messages;
  final bool anchoredHistory;
  final bool olderHistoryExhausted;
  final ChatFirstContactInfo? firstContactInfo;
}

class ChatSessionCacheWriteGate {
  List<ChatMessage>? _messages;
  bool? _anchoredHistory;
  bool? _olderHistoryExhausted;
  ChatFirstContactInfo? _firstContactInfo;

  bool shouldStore({
    required List<ChatMessage> messages,
    required bool anchoredHistory,
    required bool olderHistoryExhausted,
    required ChatFirstContactInfo? firstContactInfo,
    bool force = false,
  }) {
    final changed =
        force ||
        !identical(_messages, messages) ||
        _anchoredHistory != anchoredHistory ||
        _olderHistoryExhausted != olderHistoryExhausted ||
        !identical(_firstContactInfo, firstContactInfo);
    if (!changed) return false;
    _messages = messages;
    _anchoredHistory = anchoredHistory;
    _olderHistoryExhausted = olderHistoryExhausted;
    _firstContactInfo = firstContactInfo;
    return true;
  }
}

class ChatSessionCache {
  ChatSessionCache({this.capacity = 24, this.messageCapacity = 8000})
    : assert(capacity > 0);

  final int capacity;

  final int messageCapacity;

  int _totalMessages = 0;

  final LinkedHashMap<
    ({int accountSlot, int chatId, int? forumTopicId}),
    ChatSessionRenderState
  >
  _states =
      LinkedHashMap<
        ({int accountSlot, int chatId, int? forumTopicId}),
        ChatSessionRenderState
      >();

  ChatSessionRenderState? read({
    required int accountSlot,
    required int chatId,
    int? forumTopicId,
  }) {
    final key = (
      accountSlot: accountSlot,
      chatId: chatId,
      forumTopicId: forumTopicId,
    );
    final state = _states.remove(key);
    if (state != null) _states[key] = state;
    return state;
  }

  void store({
    required int accountSlot,
    required int chatId,
    int? forumTopicId,
    required List<ChatMessage> messages,
    required bool anchoredHistory,
    bool olderHistoryExhausted = false,
    ChatFirstContactInfo? firstContactInfo,
  }) {
    final key = (
      accountSlot: accountSlot,
      chatId: chatId,
      forumTopicId: forumTopicId,
    );
    final previous = _states.remove(key);
    if (previous != null) _totalMessages -= previous.messages.length;
    if (messages.isEmpty) return;
    _states[key] = ChatSessionRenderState(
      messages: List<ChatMessage>.unmodifiable(messages),
      anchoredHistory: anchoredHistory,
      olderHistoryExhausted: olderHistoryExhausted,
      firstContactInfo: firstContactInfo,
    );
    _totalMessages += messages.length;
    while (_states.length > capacity ||
        (_totalMessages > messageCapacity && _states.length > 1)) {
      final evicted = _states.remove(_states.keys.first);
      if (evicted != null) _totalMessages -= evicted.messages.length;
    }
  }

  void clear() {
    _states.clear();
    _totalMessages = 0;
  }
}
