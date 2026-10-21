import 'package:flutter/widgets.dart';

import '../app/chat_deep_link_controller.dart';

typedef InternalChatMessageOpener = Future<void> Function(int messageId);

class InternalChatLinkTarget {
  const InternalChatLinkTarget({
    required this.chatId,
    required this.accountSlot,
    required this.openMessage,
  });

  final int chatId;
  final int accountSlot;
  final InternalChatMessageOpener openMessage;
}

class InternalChatLinkScope extends InheritedWidget {
  const InternalChatLinkScope({
    super.key,
    required this.target,
    required super.child,
  });

  final InternalChatLinkTarget target;

  static InternalChatLinkTarget? targetOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<InternalChatLinkScope>()?.target;

  @override
  bool updateShouldNotify(InternalChatLinkScope oldWidget) =>
      target.chatId != oldWidget.target.chatId ||
      target.accountSlot != oldWidget.target.accountSlot ||
      target.openMessage != oldWidget.target.openMessage;
}

enum InternalChatLinkDisposition {
  scrolledWithinCurrentChat,
  keptCurrentChat,
  requestedAdaptiveNavigation,
}

Future<InternalChatLinkDisposition> routeResolvedInternalChatLink({
  required int chatId,
  required String title,
  int? messageId,
  InternalChatLinkTarget? source,
  ChatDeepLinkController? controller,
}) async {
  final targetMessageId = messageId != null && messageId > 0 ? messageId : null;
  if (source?.chatId == chatId) {
    if (targetMessageId == null) {
      return InternalChatLinkDisposition.keptCurrentChat;
    }
    await source!.openMessage(targetMessageId);
    return InternalChatLinkDisposition.scrolledWithinCurrentChat;
  }

  (controller ?? ChatDeepLinkController.shared).openChat(
    chatId: chatId,
    title: title,
    messageId: targetMessageId,
    accountSlot: source?.accountSlot,
    preserveChatStack: source != null,
  );
  return InternalChatLinkDisposition.requestedAdaptiveNavigation;
}
