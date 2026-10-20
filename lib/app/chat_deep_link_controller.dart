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

/// The slot a deep link must open in, or null when it must not be opened at
/// all.
///
/// A chat id only means something inside the account that produced it. Opening
/// one against whichever account happens to be active does not fail loudly —
/// it lands on a different conversation that happens to share the id, which
/// reads as the app having opened the wrong chat. So a link naming an account
/// that is not signed in is dropped, and so is one naming no account while
/// several are signed in, because there is nothing to disambiguate it with.
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
  // Naming no account is only safe when there is a single account it could
  // have meant. A lone account is the common case, and the one that predates
  // notifications carrying an identity at all.
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

  /// Whether a host (MainTabView) is listening and can act on a request.
  ///
  /// Callers route through this controller so a conversation lands in the
  /// split pane; without a host they must open the chat themselves rather
  /// than drop the request on the floor.
  bool get hasHost => hasListeners;
}
