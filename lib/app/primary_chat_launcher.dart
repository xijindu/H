import 'package:flutter/widgets.dart';

import '../chat/chat_view.dart';
import 'adaptive_split_layout.dart';
import 'app_navigator.dart';
import 'chat_deep_link_controller.dart';

/// Opens a conversation at the app level, preferring the split pane when the
/// current layout has one.
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

/// Whether a conversation opened from [context] belongs in the split pane.
///
/// On a split layout the conversation is the detail half of the window; pushing
/// it as a page would cover the sidebar and the chat list. The host check
/// matters because the request is delivered through
/// [ChatDeepLinkController] — with nobody listening it would be dropped, so the
/// caller opens the chat itself instead.
bool prefersSplitPaneChat(BuildContext context) =>
    usesSplitSelectionLayout(MediaQuery.sizeOf(context)) &&
    ChatDeepLinkController.shared.hasHost;

/// Shows [chatId] in the split pane and dismisses the screen that asked.
///
/// Search results, profiles and shared media all sit on routes above the split
/// layout; leaving them stacked would hide the conversation they just opened.
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
