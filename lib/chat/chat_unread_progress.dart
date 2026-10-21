import 'package:flutter/widgets.dart';

enum ChatBottomIndicator { none, newMessages, jumpToBottom }

enum ChatNewMessagesControlPlacement { hidden, top, bottom }

class ChatNewMessagesControlShell extends StatelessWidget {
  const ChatNewMessagesControlShell({
    super.key,
    required this.unreadBadge,
  });

  static const unreadBadgeKey = ValueKey('chatUnreadMessagesBadge');

  final Widget unreadBadge;

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: unreadBadgeKey, child: unreadBadge);
}

ChatBottomIndicator chatBottomIndicator({
  required bool isScrolledUp,
  required bool hasNewMessages,
}) {
  if (!isScrolledUp) return ChatBottomIndicator.none;
  return hasNewMessages
      ? ChatBottomIndicator.newMessages
      : ChatBottomIndicator.jumpToBottom;
}

ChatNewMessagesControlPlacement chatNewMessagesControlPlacement({
  required bool isScrolledUp,
  required bool hasNewMessages,
  required bool isEntryUnread,
}) {
  if (!hasNewMessages) return ChatNewMessagesControlPlacement.hidden;
  if (isScrolledUp) return ChatNewMessagesControlPlacement.bottom;
  return isEntryUnread
      ? ChatNewMessagesControlPlacement.top
      : ChatNewMessagesControlPlacement.hidden;
}

class ChatLiveMessageBuffer {
  final Set<int> _messageIds = <int>{};

  bool add(int messageId) => _messageIds.add(messageId);

  List<int> takeAll() {
    if (_messageIds.isEmpty) return const <int>[];
    final result = _messageIds.toList(growable: false);
    _messageIds.clear();
    return result;
  }
}

List<int> appendedLiveIncomingMessageIds({
  required int? previousNewestMessageId,
  required Iterable<int> liveIncomingMessageIds,
  required Iterable<int> currentMessageIds,
}) {
  final currentIds = currentMessageIds.toSet();
  return liveIncomingMessageIds
      .where(
        (id) =>
            (previousNewestMessageId == null || id > previousNewestMessageId) &&
            currentIds.contains(id),
      )
      .toList(growable: false);
}

int? firstUnreadMessageIdAfterBoundary({
  required Iterable<int> incomingMessageIds,
  required int lastReadInboxId,
}) {
  int? earliest;
  for (final messageId in incomingMessageIds) {
    if (messageId <= lastReadInboxId) continue;
    if (earliest == null || messageId < earliest) earliest = messageId;
  }
  return earliest;
}

bool isCapturedEntryUnreadMessage({
  required int messageId,
  required int lastReadInboxId,
  required int latestMessageId,
}) => messageId > lastReadInboxId && messageId <= latestMessageId;

bool isCapturedUnreadDividerMessage({
  required int entryUnreadCount,
  required int? firstUnreadMessageId,
  required int messageId,
  required bool isIncoming,
  required bool isService,
  required int lastReadInboxId,
  required int latestMessageId,
}) {
  if (entryUnreadCount <= 0 ||
      firstUnreadMessageId == null ||
      messageId != firstUnreadMessageId ||
      !isIncoming ||
      isService) {
    return false;
  }
  if (!isCapturedEntryUnreadMessage(
    messageId: messageId,
    lastReadInboxId: lastReadInboxId,
    latestMessageId: latestMessageId,
  )) {
    return false;
  }
  return true;
}

int resolveCapturedEntryLatestMessageId({
  required int knownLatestMessageId,
  required int loadedLatestMessageId,
}) => knownLatestMessageId > 0 ? knownLatestMessageId : loadedLatestMessageId;

class ChatUnreadProgress {
  final Set<int> _seenInitialMessageIds = <int>{};
  final Set<int> _liveMessageIds = <int>{};
  final Set<int> _reportedVisibleMessageIds = <int>{};

  int get liveCount => _liveMessageIds.length;

  int initialRemaining({required int entryUnreadCount}) =>
      (entryUnreadCount - _seenInitialMessageIds.length).clamp(0, 1 << 30);

  int remaining({required int entryUnreadCount}) =>
      initialRemaining(entryUnreadCount: entryUnreadCount) + liveCount;

  int badgeCount({required int entryUnreadCount}) => liveCount > 0
      ? liveCount
      : initialRemaining(entryUnreadCount: entryUnreadCount);

  bool addLiveMessage(int messageId) => _liveMessageIds.add(messageId);

  bool addLiveMessages(Iterable<int> messageIds) {
    var changed = false;
    for (final messageId in messageIds) {
      changed = _liveMessageIds.add(messageId) || changed;
    }
    return changed;
  }

  bool markVisible({required int messageId, required bool initialUnread}) {
    if (_liveMessageIds.remove(messageId)) return true;
    return initialUnread && _seenInitialMessageIds.add(messageId);
  }

  ({bool shouldReportViewed, bool unreadCountChanged}) observeVisibleIncoming({
    required int messageId,
    required bool initialUnread,
  }) => (
    shouldReportViewed: _reportedVisibleMessageIds.add(messageId),
    unreadCountChanged: markVisible(
      messageId: messageId,
      initialUnread: initialUnread,
    ),
  );

  bool clearLiveMessages() {
    if (_liveMessageIds.isEmpty) return false;
    _liveMessageIds.clear();
    return true;
  }
}
