import 'package:flutter/foundation.dart';

class ChatDeepLinkRequest {
  const ChatDeepLinkRequest({
    required this.chatId,
    required this.title,
    this.messageId,
    this.accountUserId,
    this.accountSlot,
    this.preserveChatStack = false,
  });

  final int chatId;
  final String title;
  final int? messageId;
  final int? accountUserId;
  final int? accountSlot;
  final bool preserveChatStack;

  ChatDeepLinkRequest scopedToAccountSlot(int slot) => ChatDeepLinkRequest(
    chatId: chatId,
    title: title,
    messageId: messageId,
    accountUserId: accountUserId,
    accountSlot: slot,
    preserveChatStack: preserveChatStack,
  );
}

int? resolveDeepLinkAccountSlot({
  required int? requestedSlot,
  required int? requestedUserId,
  required int activeSlot,
  required List<({int slot, int? userId})> accounts,
}) {
  if (requestedSlot != null) return requestedSlot;
  if (requestedUserId != null) {
    return accounts
        .where((account) => account.userId == requestedUserId)
        .map((account) => account.slot)
        .firstOrNull;
  }
  return accounts.length <= 1 ? activeSlot : null;
}

class ChatDeepLinkController extends ChangeNotifier {
  ChatDeepLinkController._();

  static final ChatDeepLinkController shared = ChatDeepLinkController._();

  ChatDeepLinkRequest? _pending;

  void openChat({
    required int chatId,
    required String title,
    int? messageId,
    int? accountUserId,
    int? accountSlot,
    bool preserveChatStack = false,
  }) {
    _pending = ChatDeepLinkRequest(
      chatId: chatId,
      title: title,
      messageId: messageId,
      accountUserId: accountUserId,
      accountSlot: accountSlot,
      preserveChatStack: preserveChatStack,
    );
    notifyListeners();
  }

  ChatDeepLinkRequest? consumePending() {
    final request = _pending;
    _pending = null;
    return request;
  }

  bool get hasHost => hasListeners;
}
