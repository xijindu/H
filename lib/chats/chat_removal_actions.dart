import '../tdlib/json_helpers.dart';
import 'chat_delete_policy.dart';

typedef ChatRemovalQuery =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

class ChatRemovalUnavailable implements Exception {
  const ChatRemovalUnavailable();
}

class ChatLeaveHistoryCleanupFailed implements Exception {
  const ChatLeaveHistoryCleanupFailed(this.cause);

  final Object cause;
}

Future<void> clearChatHistoryForSelf({
  required int chatId,
  required ChatRemovalQuery query,
  bool removeFromChatList = false,
}) async {
  final chat = await query({'@type': 'getChat', 'chat_id': chatId});
  if (!chatDeleteCapabilities(chat).canDeleteForSelf) {
    throw const ChatRemovalUnavailable();
  }
  await query(
    deleteChatHistoryRequest(
      chatId: chatId,
      scope: ChatDeleteScope.self,
      removeFromChatList: removeFromChatList,
    ),
  );
}

Future<void> deleteChatForAllMembers({
  required int chatId,
  required ChatRemovalQuery query,
  required void Function() onDeleted,
}) async {
  final chat = await query({'@type': 'getChat', 'chat_id': chatId});
  if (!chatDeleteCapabilities(chat).canDeleteForAllUsers) {
    throw const ChatRemovalUnavailable();
  }
  await query({'@type': 'deleteChat', 'chat_id': chatId});
  onDeleted();
}

Future<void> leaveChatAndRemoveFromList({
  required int chatId,
  required ChatRemovalQuery query,
  required void Function() onLeft,
}) async {
  final chat = await query({'@type': 'getChat', 'chat_id': chatId});
  final type = chat.obj('type')?.type;
  if (type != 'chatTypeBasicGroup' && type != 'chatTypeSupergroup') {
    throw const ChatRemovalUnavailable();
  }
  await query({'@type': 'leaveChat', 'chat_id': chatId});
  onLeft();

  if (type == 'chatTypeBasicGroup') {
    try {
      await clearChatHistoryForSelf(
        chatId: chatId,
        query: query,
        removeFromChatList: true,
      );
    } catch (error) {
      throw ChatLeaveHistoryCleanupFailed(error);
    }
  }
}
