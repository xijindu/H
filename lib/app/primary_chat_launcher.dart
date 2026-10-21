import 'package:flutter/widgets.dart';

import '../chat/chat_view.dart';
import 'adaptive_split_layout.dart';
import 'app_navigator.dart';
import 'chat_deep_link_controller.dart';

Future<void> openChatFromCurrentWindow(
  BuildContext context, {
  required int chatId,
  required String title,
  int? initialMessageId,
  bool replaceCurrent = false,
  Future<void> Function()? openFallback,
}) async {
  if (!context.mounted) return;
  if (openFallback != null) {
    await openFallback();
    return;
  }
  if (prefersSplitPaneChat(context)) {
    selectChatInSplitPane(
      context,
      chatId: chatId,
      title: title,
      initialMessageId: initialMessageId,
    );
    return;
  }
  final route = AppChatPageRoute<void>(
    builder: (_) => ChatView(
      chatId: chatId,
      title: title,
      initialMessageId: initialMessageId,
    ),
  );
  if (replaceCurrent) {
    await replaceWithAppChatRoute<void, void>(context, route);
  } else {
    await pushAppChatRoute<void>(context, route);
  }
}

bool prefersSplitPaneChat(BuildContext context) =>
    usesSplitSelectionLayout(MediaQuery.sizeOf(context)) &&
    ChatDeepLinkController.shared.hasHost;

void selectChatInSplitPane(
  BuildContext context, {
  required int chatId,
  required String title,
  int? initialMessageId,
}) {
  Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
  ChatDeepLinkController.shared.openChat(
    chatId: chatId,
    title: title,
    messageId: initialMessageId,
  );
}
