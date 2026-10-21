import '../tdlib/td_models.dart';

bool isPendingChatMessage(ChatMessage message) => message.isSending;

int compareChatMessagesChronologically(ChatMessage a, ChatMessage b) {
  if (isPendingChatMessage(a) || isPendingChatMessage(b)) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
  }
  return a.id.compareTo(b.id);
}

int latestServerMessageId(Iterable<ChatMessage> messages) {
  var latest = 0;
  for (final message in messages) {
    if (!isPendingChatMessage(message) &&
        message.id > 0 &&
        message.id > latest) {
      latest = message.id;
    }
  }
  return latest;
}

int latestServerMessageReadBoundary({
  required Iterable<ChatMessage> visibleMessages,
  required Iterable<ChatMessage> allMessages,
}) {
  final visible = latestServerMessageId(visibleMessages);
  return visible > 0 ? visible : latestServerMessageId(allMessages);
}

bool isOutgoingServerMessageRead({
  required ChatMessage message,
  required int lastReadOutboxId,
}) {
  return message.isOutgoing &&
      !message.isSending &&
      message.id > 0 &&
      message.id <= lastReadOutboxId;
}

bool confirmsOlderHistoryExhausted({required bool onlyLocal}) {
  return !onlyLocal;
}

const kThinInitialHistoryMessageCount = 12;

bool isThinInitialHistoryWindow(int messageCount) =>
    messageCount > 0 && messageCount < kThinInitialHistoryMessageCount;

bool shouldLoadInitialHistoryAroundLastRead({
  required bool openAtLatest,
  required int lastReadInboxId,
  required int unreadCount,
}) => !openAtLatest && lastReadInboxId > 0 && unreadCount > 0;

List<ChatMessage> mergeChatMessages(
  Iterable<ChatMessage> current,
  Iterable<ChatMessage> incoming, {
  Set<int> ignoredMessageIds = const <int>{},
}) {
  final byId = {for (final message in current) message.id: message};
  for (final message in incoming) {
    if (ignoredMessageIds.contains(message.id)) continue;
    final existing = byId[message.id];
    if (existing != null) {
      message.isSendAcknowledged = existing.isSendAcknowledged;
      message.senderName ??= existing.senderName;
      message.senderIsChat = message.senderIsChat || existing.senderIsChat;
      message.senderPhoto ??= existing.senderPhoto;
      message.senderRole ??= existing.senderRole;
      message.senderTitle ??= existing.senderTitle;
      if (!message.commentThreadMetadataKnown &&
          existing.commentThreadMetadataKnown) {
        message.hasCommentThread = existing.hasCommentThread;
        message.commentCount = existing.commentCount;
        message.lastCommentMessageId = existing.lastCommentMessageId;
        message.commentThreadMetadataKnown = true;
      }
    }
    byId[message.id] = message;
  }
  return byId.values.toList()..sort(compareChatMessagesChronologically);
}

List<ChatMessage> mergeChatHistoryWindow({
  required Iterable<ChatMessage> currentAtRequestStart,
  required Iterable<ChatMessage> currentAtCompletion,
  required Iterable<ChatMessage> fetched,
  required bool replaceCurrentWindow,
  bool preserveLiveArrivals = true,
  Set<int> ignoredMessageIds = const <int>{},
}) {
  if (!replaceCurrentWindow) {
    return mergeChatMessages(
      currentAtCompletion,
      fetched,
      ignoredMessageIds: ignoredMessageIds,
    );
  }

  final startingIds = currentAtRequestStart
      .map((message) => message.id)
      .toSet();
  final liveArrivals = preserveLiveArrivals
      ? currentAtCompletion.where(
          (message) => !startingIds.contains(message.id),
        )
      : const <ChatMessage>[];
  return mergeChatMessages(
    fetched,
    liveArrivals,
    ignoredMessageIds: ignoredMessageIds,
  );
}

bool shouldMergeLiveMessageIntoChatWindow({
  required bool historyReachesLatest,
}) => historyReachesLatest;

enum ChatMediaAlbumKind { visual, document }

ChatMediaAlbumKind? chatMediaAlbumKind(ChatMessage message) {
  if (message.isService || message.isContentRestricted) return null;
  if (message.isAlbumVisualMedia) return ChatMediaAlbumKind.visual;
  if (message.contentType == 'messageDocument' && message.document != null) {
    return ChatMediaAlbumKind.document;
  }
  return null;
}

bool areMessagesInSameMediaAlbum(ChatMessage previous, ChatMessage next) {
  final previousKind = chatMediaAlbumKind(previous);
  if (previousKind == null || previousKind != chatMediaAlbumKind(next)) {
    return false;
  }
  if (previous.isOutgoing != next.isOutgoing) return false;
  if (previous.senderId != next.senderId) return false;
  return previous.mediaAlbumId != 0 &&
      previous.mediaAlbumId == next.mediaAlbumId;
}
