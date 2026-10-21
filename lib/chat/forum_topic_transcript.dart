import '../tdlib/json_helpers.dart';

const generalForumTopicId = 1;

int? forumTopicIdOfRawMessage(Map<String, dynamic> raw) {
  final topic = raw.obj('topic_id');
  if (topic == null || topic.type != 'messageTopicForum') return null;
  return topic.integer('forum_topic_id');
}

bool rawMessageBelongsToForumTopic(Map<String, dynamic> raw, int forumTopicId) {
  final topic = raw.obj('topic_id');
  if (topic == null) return forumTopicId == generalForumTopicId;
  return forumTopicIdOfRawMessage(raw) == forumTopicId;
}

Map<String, dynamic> forumTopicHistoryRequest(
  Map<String, dynamic> request,
  int forumTopicId,
) {
  switch (request.type) {
    case 'getChatHistory':
      return {
        '@type': 'getForumTopicHistory',
        'chat_id': request['chat_id'],
        'forum_topic_id': forumTopicId,
        'from_message_id': request['from_message_id'] ?? 0,
        'offset': request['offset'] ?? 0,
        'limit': request['limit'] ?? 40,
      };
    case 'searchChatMessages':
      return Map<String, dynamic>.from(request)
        ..['topic_id'] = {
          '@type': 'messageTopicForum',
          'forum_topic_id': forumTopicId,
        };
    default:
      return request;
  }
}

Map<String, dynamic> forumTopicThreadHistoryRequest(
  Map<String, dynamic> request,
) => {
  '@type': 'getMessageThreadHistory',
  'chat_id': request['chat_id'],
  'message_id': request['forum_topic_id'],
  'from_message_id': request['from_message_id'] ?? 0,
  'offset': request['offset'] ?? 0,
  'limit': request['limit'] ?? 40,
};

Map<String, dynamic> forumTopicChatSnapshot(
  Map<String, dynamic> chat,
  Map<String, dynamic>? topic,
) {
  final snapshot = Map<String, dynamic>.from(chat)
    ..remove('last_message')
    ..remove('draft_message')
    ..['is_marked_as_unread'] = false
    ..['unread_count'] = 0
    ..['last_read_inbox_message_id'] = 0
    ..['unread_mention_count'] = 0
    ..['unread_reaction_count'] = 0;
  if (topic == null) return snapshot;
  for (final key in const [
    'last_message',
    'draft_message',
    'unread_count',
    'last_read_inbox_message_id',
    'last_read_outbox_message_id',
    'unread_mention_count',
    'unread_reaction_count',
  ]) {
    if (topic.containsKey(key)) snapshot[key] = topic[key];
  }
  return snapshot;
}
