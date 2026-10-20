import 'json_helpers.dart';
import 'td_client.dart';

bool isJoinedMemberStatus(Map<String, dynamic>? status) {
  switch (status?.type) {
    case 'chatMemberStatusCreator':
    case 'chatMemberStatusAdministrator':
    case 'chatMemberStatusMember':
      return true;
    case 'chatMemberStatusRestricted':
      return status?.boolean('is_member') ?? false;
    case 'chatMemberStatusLeft':
    case 'chatMemberStatusBanned':
      return false;
  }
  return true;
}

Future<bool> isJoinedGroupOrChannelChat(
  int chatId, {
  Map<String, dynamic>? chat,
  int? clientId,
}) async {
  Future<Map<String, dynamic>> query(Map<String, dynamic> request) {
    return clientId == null
        ? TdClient.shared.query(request)
        : TdClient.shared.queryTo(request, clientId);
  }

  try {
    final raw = chat ?? await query({'@type': 'getChat', 'chat_id': chatId});
    final type = raw.obj('type');
    switch (type?.type) {
      case 'chatTypeBasicGroup':
        final id = type?.int64('basic_group_id');
        if (id == null) return true;
        final group = await query({
          '@type': 'getBasicGroup',
          'basic_group_id': id,
        });
        return isJoinedMemberStatus(group.obj('status'));
      case 'chatTypeSupergroup':
        final id = type?.int64('supergroup_id');
        if (id == null) return true;
        final group = await query({
          '@type': 'getSupergroup',
          'supergroup_id': id,
        });
        return isJoinedMemberStatus(group.obj('status'));
    }
  } catch (_) {
    return true;
  }
  return true;
}
