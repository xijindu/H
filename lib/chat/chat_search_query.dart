import 'chat_message_search_controller.dart';

class ChatSearchTokens {
  const ChatSearchTokens({
    required this.text,
    this.fromQuery,
    this.inQuery,
    this.filter,
  });

  final String text;

  final String? fromQuery;

  final String? inQuery;

  final ChatSearchFilter? filter;

  bool get isEmpty =>
      text.trim().isEmpty && fromQuery == null && inQuery == null;
}

enum ChatSearchTokenKind { from, chat }

class ChatSearchActiveToken {
  const ChatSearchActiveToken({
    required this.kind,
    required this.value,
    required this.start,
    required this.end,
  });

  final ChatSearchTokenKind kind;

  final String value;

  final int start;
  final int end;
}

const _filterAliases = <String, ChatSearchFilter>{
  'link': ChatSearchFilter.links,
  'links': ChatSearchFilter.links,
  'url': ChatSearchFilter.links,
  'embed': ChatSearchFilter.links,
  'file': ChatSearchFilter.files,
  'files': ChatSearchFilter.files,
  'doc': ChatSearchFilter.files,
  'document': ChatSearchFilter.files,
  'photo': ChatSearchFilter.media,
  'image': ChatSearchFilter.media,
  'video': ChatSearchFilter.media,
  'media': ChatSearchFilter.media,
  'voice': ChatSearchFilter.voice,
  'music': ChatSearchFilter.music,
  'audio': ChatSearchFilter.music,
  'sound': ChatSearchFilter.music,
};

Iterable<String> get chatSearchHasAliases => _filterAliases.keys;

final _tokenPattern = RegExp(
  r'\b(from|in|has):("([^"]*)"|\S*)',
  caseSensitive: false,
);

ChatSearchActiveToken? activeChatSearchToken(String raw, int caretOffset) {
  final caret = caretOffset.clamp(0, raw.length);
  for (final match in _tokenPattern.allMatches(raw)) {
    if (caret < match.start || caret > match.end) continue;
    final key = match.group(1)!.toLowerCase();
    final kind = switch (key) {
      'from' => ChatSearchTokenKind.from,
      'in' => ChatSearchTokenKind.chat,
      _ => null,
    };
    if (kind == null) return null;
    return ChatSearchActiveToken(
      kind: kind,
      value: (match.group(3) ?? match.group(2) ?? '').trim(),
      start: match.start,
      end: match.end,
    );
  }
  return null;
}

({String text, int caret}) applyChatSearchToken(
  String raw,
  ChatSearchActiveToken token,
  String value,
) {
  final key = switch (token.kind) {
    ChatSearchTokenKind.from => 'from',
    ChatSearchTokenKind.chat => 'in',
  };
  final quoted = value.contains(' ') ? '"$value"' : value;
  final followedBySpace =
      token.end < raw.length && raw[token.end].trim().isEmpty;
  final replacement = followedBySpace ? '$key:$quoted' : '$key:$quoted ';
  final text = raw.replaceRange(token.start, token.end, replacement);
  final caret = token.start + replacement.length + (followedBySpace ? 1 : 0);
  return (text: text, caret: caret);
}

({String text, int caret}) removeChatSearchToken(
  String raw,
  ChatSearchActiveToken token,
) {
  var end = token.end;
  if (end < raw.length && raw[end].trim().isEmpty) end += 1;
  return (text: raw.replaceRange(token.start, end, ''), caret: token.start);
}

ChatSearchTokens parseChatSearchQuery(String raw) {
  String? fromQuery;
  String? inQuery;
  ChatSearchFilter? filter;
  final text = raw
      .replaceAllMapped(_tokenPattern, (match) {
        final key = match.group(1)!.toLowerCase();
        final value = (match.group(3) ?? match.group(2) ?? '').trim();
        if (key == 'from') {
          if (value.isNotEmpty) fromQuery = value;
          return '';
        }
        if (key == 'in') {
          if (value.isNotEmpty) inQuery = value;
          return '';
        }
        final resolved = _filterAliases[value.toLowerCase()];
        if (resolved == null) return match.group(0)!;
        filter = resolved;
        return '';
      })
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return ChatSearchTokens(
    text: text,
    fromQuery: fromQuery,
    inQuery: inQuery,
    filter: filter,
  );
}
