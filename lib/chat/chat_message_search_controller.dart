import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../app/adaptive_split_layout.dart';
import '../chats/search_token_suggestions.dart';
import '../l10n/app_localizations.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import 'chat_search_query.dart';

const double chatSearchResultsPaneWidth = 300;

bool chatSearchUsesResultsPane({
  required Size windowSize,
  required double conversationWidth,
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
}) =>
    usesSplitSelectionLayout(windowSize, platform: platform, isWeb: isWeb) &&
    conversationWidth >= chatSearchResultsPaneWidth + splitDetailMinWidth;

List<InlineSpan> chatSearchHighlightSpans({
  required String text,
  required String query,
  required TextStyle matchStyle,
}) {
  final needle = query.trim();
  if (needle.isEmpty || text.isEmpty) return [TextSpan(text: text)];
  final haystack = text.toLowerCase();
  final lowerNeedle = needle.toLowerCase();
  final spans = <InlineSpan>[];
  var start = 0;
  while (start < text.length) {
    final index = haystack.indexOf(lowerNeedle, start);
    if (index < 0) break;
    if (index > start) spans.add(TextSpan(text: text.substring(start, index)));
    final end = index + needle.length;
    spans.add(TextSpan(text: text.substring(index, end), style: matchStyle));
    start = end;
  }
  if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
  return spans.isEmpty ? [TextSpan(text: text)] : spans;
}

enum ChatSearchFilter {
  all,
  media,
  links,
  files,
  music,
  voice;

  String get labelKey => switch (this) {
    ChatSearchFilter.all => AppStringKeys.sharedMediaFilterAll,
    ChatSearchFilter.media => AppStringKeys.searchTabMedia,
    ChatSearchFilter.links => AppStringKeys.searchTabLinks,
    ChatSearchFilter.files => AppStringKeys.searchTabFiles,
    ChatSearchFilter.music => AppStringKeys.searchTabMusic,
    ChatSearchFilter.voice => AppStringKeys.searchTabVoiceMessages,
  };

  String get tdlibFilter => switch (this) {
    ChatSearchFilter.all => 'searchMessagesFilterEmpty',
    ChatSearchFilter.media => 'searchMessagesFilterPhotoAndVideo',
    ChatSearchFilter.links => 'searchMessagesFilterUrl',
    ChatSearchFilter.files => 'searchMessagesFilterDocument',
    ChatSearchFilter.music => 'searchMessagesFilterAudio',
    ChatSearchFilter.voice => 'searchMessagesFilterVoiceNote',
  };
}

class _SearchSender {
  const _SearchSender({required this.name, this.photo});

  final String name;
  final TdFileRef? photo;
}

class ChatMessageSearchController extends ChangeNotifier {
  ChatMessageSearchController({
    required this.chatId,
    TdClient? client,
    this.onActivateResult,
    this.autoActivateFirstResult = true,
  }) : _client = client ?? TdClient.shared;

  static const Duration _debounceDelay = Duration(milliseconds: 280);
  static const int _pageSize = 40;

  final int chatId;
  final TdClient _client;

  final void Function(ChatMessage message, {required bool automatic})?
  onActivateResult;

  final bool autoActivateFirstResult;

  final TextEditingController textController = TextEditingController();
  final FocusNode focusNode = FocusNode();

  final Map<int, _SearchSender> _senders = {};
  Timer? _debounce;
  Timer? _suggestDebounce;
  int _runId = 0;
  bool _disposed = false;
  bool _active = false;
  bool _loading = false;
  bool _loadingMore = false;
  String _query = '';
  int _totalCount = 0;
  int _nextFromMessageId = 0;
  int _activeIndex = -1;
  List<ChatMessage> _results = const [];
  ChatSearchFilter _filter = ChatSearchFilter.all;
  ChatSearchTokens _tokens = const ChatSearchTokens(text: '');
  _SearchSenderFilter? _senderFilter;
  late final ChatSearchTokenSuggester _suggester = ChatSearchTokenSuggester(
    client: _client,
  );
  ChatSearchActiveToken? _activeToken;

  _SearchSenderFilter? _committedSender;
  List<ChatSearchTokenSuggestion> _suggestions = const [];
  int _suggestRunId = 0;

  bool get isActive => _active;
  String get query => _query;
  List<ChatMessage> get results => _results;
  int get activeIndex => _activeIndex;
  ChatMessage? get activeResult =>
      _activeIndex >= 0 && _activeIndex < _results.length
      ? _results[_activeIndex]
      : null;
  int? get activeMessageId => activeResult?.id;

  ChatSearchFilter get filter => _tokens.filter ?? _filter;

  int? get senderUserId => (_committedSender ?? _senderFilter)?.userId;
  String? get senderName => (_committedSender ?? _senderFilter)?.name;

  String? get senderQuery => _tokens.fromQuery;

  ChatSearchActiveToken? get activeToken => _activeToken;
  List<ChatSearchTokenSuggestion> get suggestions => _suggestions;

  bool get isLoading => _loading || _debounce?.isActive == true;
  bool get hasQuery => _query.trim().isNotEmpty;

  bool get hasSearch =>
      _tokens.text.trim().isNotEmpty ||
      filter != ChatSearchFilter.all ||
      _tokens.fromQuery != null;
  bool get hasResults => _results.isNotEmpty;
  bool get hasMore => _nextFromMessageId != 0;

  int get matchCount => math.max(_totalCount, _results.length);

  int get matchPosition => _activeIndex < 0 ? 0 : _activeIndex + 1;

  bool get canStepOlder =>
      _activeIndex + 1 < _results.length || (hasMore && hasResults);
  bool get canStepNewer => _activeIndex > 0;

  void open({String? initialQuery}) {
    if (_disposed) return;
    final seed = initialQuery?.trim() ?? '';
    if (!_active) {
      _active = true;
      notifyListeners();
    }
    if (seed.isNotEmpty && seed != _query) {
      textController.value = TextEditingValue(
        text: seed,
        selection: TextSelection.collapsed(offset: seed.length),
      );
      updateQuery(seed);
    }
    focusNode.requestFocus();
  }

  void close() {
    if (_disposed || !_active) return;
    _cancelRun();
    _active = false;
    _query = '';
    _results = const [];
    _activeIndex = -1;
    _totalCount = 0;
    _nextFromMessageId = 0;
    _loading = false;
    _loadingMore = false;
    _filter = ChatSearchFilter.all;
    _tokens = const ChatSearchTokens(text: '');
    _senderFilter = null;
    _activeToken = null;
    _committedSender = null;
    _suggestions = const [];
    _suggestDebounce?.cancel();
    _suggestDebounce = null;
    _suggestRunId++;
    textController.clear();
    focusNode.unfocus();
    notifyListeners();
  }

  void updateQuery(String value) {
    if (_disposed) return;
    _query = value;
    _tokens = parseChatSearchQuery(value);
    final caret = textController.selection.baseOffset;
    final token = activeChatSearchToken(
      value,
      caret < 0 ? value.length : caret,
    );
    _activeToken = token?.kind == ChatSearchTokenKind.from ? token : null;
    if (_senderFilter?.query != _tokens.fromQuery) _senderFilter = null;
    _startSuggestions();
    _restart();
  }

  void _startSuggestions() {
    _suggestDebounce?.cancel();
    final token = _activeToken;
    final runId = ++_suggestRunId;
    if (token == null) {
      _suggestions = const [];
      return;
    }
    if (token.value.isEmpty) {
      _fetchSuggestions(token, runId);
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 240), () {
      if (_disposed || runId != _suggestRunId) return;
      _fetchSuggestions(token, runId);
    });
  }

  void _fetchSuggestions(ChatSearchActiveToken token, int runId) {
    unawaited(() async {
      final results = await _suggester.suggest(token, scopeChatId: chatId);
      if (_disposed || runId != _suggestRunId) return;
      _suggestions = results;
      notifyListeners();
    }());
  }

  bool get showsTokenHints =>
      focusNode.hasFocus && !hasSearch && _senderFilter == null;

  void startToken(String token) {
    if (_disposed) return;
    final text = _query.isEmpty || _query.endsWith(' ')
        ? '$_query$token'
        : '$_query $token';
    textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    focusNode.requestFocus();
    updateQuery(text);
  }

  void applySuggestion(ChatSearchTokenSuggestion suggestion) {
    final token = _activeToken;
    if (_disposed || token == null) return;
    _committedSender = _SearchSenderFilter(
      query: suggestion.token,
      userId: suggestion.id,
      name: suggestion.title,
    );
    final applied = removeChatSearchToken(_query, token);
    textController.value = TextEditingValue(
      text: applied.text,
      selection: TextSelection.collapsed(offset: applied.caret),
    );
    focusNode.requestFocus();
    updateQuery(applied.text);
  }

  void setFilter(ChatSearchFilter filter) {
    if (_disposed || filter == _filter) return;
    _filter = filter;
    _restart();
  }

  void _restart() {
    _cancelRun();
    _results = const [];
    _activeIndex = -1;
    _totalCount = 0;
    _nextFromMessageId = 0;
    _loadingMore = false;
    _loading = false;
    if (hasSearch) {
      final runId = _runId;
      _debounce = Timer(
        _debounceDelay,
        () => _runFirstPage(_tokens.text.trim(), runId),
      );
    }
    notifyListeners();
  }

  void clearSender() {
    if (_disposed || _committedSender == null) return;
    _committedSender = null;
    focusNode.requestFocus();
    _restart();
  }

  void clear() {
    if (_disposed) return;
    textController.clear();
    updateQuery('');
    focusNode.requestFocus();
  }

  void selectIndex(int index, {bool automatic = false}) {
    if (_disposed || index < 0 || index >= _results.length) return;
    _activeIndex = index;
    notifyListeners();
    onActivateResult?.call(_results[index], automatic: automatic);
  }

  void selectResult(ChatMessage message) {
    final index = _results.indexWhere((result) => result.id == message.id);
    if (index >= 0) selectIndex(index);
  }

  Future<void> stepOlder() async {
    if (_disposed || _results.isEmpty) return;
    if (_activeIndex + 1 >= _results.length) {
      if (!hasMore) return;
      await loadMore();
      if (_disposed || _activeIndex + 1 >= _results.length) return;
    }
    selectIndex(_activeIndex + 1);
  }

  void stepNewer() {
    if (_disposed || _activeIndex <= 0) return;
    selectIndex(_activeIndex - 1);
  }

  Future<void> loadMore() async {
    if (_disposed || _loadingMore || !hasMore || !hasSearch) return;
    final trimmed = _tokens.text.trim();
    final runId = _runId;
    _loadingMore = true;
    notifyListeners();
    final page = await _fetchPage(trimmed, from: _nextFromMessageId);
    if (_disposed || runId != _runId) return;
    _loadingMore = false;
    if (page == null) {
      notifyListeners();
      return;
    }
    _appendPage(page, runId: runId);
  }

  Future<void> _runFirstPage(String trimmed, int runId) async {
    if (_disposed || runId != _runId) return;
    _loading = true;
    notifyListeners();
    await _resolveSenderFilter(runId);
    if (_disposed || runId != _runId) return;
    final page = await _fetchPage(trimmed, from: 0);
    if (_disposed || runId != _runId) return;
    _loading = false;
    if (page == null) {
      notifyListeners();
      return;
    }
    _appendPage(page, runId: runId, activateFirst: true);
  }

  void _appendPage(
    _SearchPage page, {
    required int runId,
    bool activateFirst = false,
  }) {
    final known = {for (final result in _results) result.id};
    final merged = <ChatMessage>[
      ..._results,
      ...page.messages.where((message) => known.add(message.id)),
    ];
    final grew = merged.length > _results.length;
    _results = List<ChatMessage>.unmodifiable(merged);
    _totalCount = page.totalCount;
    _nextFromMessageId = grew ? page.nextFromMessageId : 0;
    notifyListeners();
    unawaited(_hydrateSenders(page.messages, runId));
    if (activateFirst && autoActivateFirstResult && _results.isNotEmpty) {
      selectIndex(0, automatic: true);
    }
  }

  Future<_SearchPage?> _fetchPage(String query, {required int from}) async {
    try {
      final response = await _client.query({
        '@type': 'searchChatMessages',
        'chat_id': chatId,
        'query': query,
        'sender_id': _senderFilter == null
            ? null
            : {'@type': 'messageSenderUser', 'user_id': _senderFilter!.userId},
        'from_message_id': from,
        'offset': 0,
        'limit': _pageSize,
        'filter': {'@type': filter.tdlibFilter},
      });
      final raw =
          response.objects('messages') ?? const <Map<String, dynamic>>[];
      final messages = raw
          .map(TDParse.message)
          .whereType<ChatMessage>()
          .where((message) => !message.isService)
          .toList(growable: false);
      final nextFromMessageId =
          response.int64('next_from_message_id') ??
          (raw.length < _pageSize ? 0 : (messages.lastOrNull?.id ?? 0));
      return _SearchPage(
        messages: messages,
        totalCount: response.integer('total_count') ?? messages.length,
        nextFromMessageId: nextFromMessageId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _resolveSenderFilter(int runId) async {
    if (_committedSender != null) return;
    final query = _tokens.fromQuery;
    if (query == null) {
      _senderFilter = null;
      return;
    }
    if (_senderFilter?.query == query) return;
    try {
      final response = await _client.query({
        '@type': 'searchChatMembers',
        'chat_id': chatId,
        'query': query,
        'limit': 1,
        'filter': null,
      });
      if (_disposed || runId != _runId) return;
      final member = (response.objects('members') ?? const []).firstOrNull;
      final sender = member?.obj('member_id');
      final userId = sender?.type == 'messageSenderUser'
          ? sender?.int64('user_id')
          : null;
      if (userId == null || userId == 0) {
        _senderFilter = null;
        return;
      }
      final resolved = await _resolveSender(userId);
      if (_disposed || runId != _runId) return;
      _senderFilter = _SearchSenderFilter(
        query: query,
        userId: userId,
        name: resolved?.name ?? query,
      );
    } catch (_) {
      if (!_disposed && runId == _runId) _senderFilter = null;
    }
  }

  Future<void> _hydrateSenders(List<ChatMessage> batch, int runId) async {
    var changed = false;
    for (final message in batch) {
      if (_disposed || runId != _runId) return;
      final senderId = message.senderId;
      if (senderId == null || senderId == 0) continue;
      if (message.isOutgoing && !message.senderIsChat) continue;
      if (message.senderName != null) continue;
      var sender = _senders[senderId];
      if (sender == null) {
        sender = await _resolveSender(senderId);
        if (_disposed || runId != _runId) return;
        if (sender == null) continue;
        _senders[senderId] = sender;
      }
      message.senderName ??= sender.name;
      message.senderPhoto ??= sender.photo;
      changed = true;
    }
    if (changed && !_disposed && runId == _runId) notifyListeners();
  }

  Future<_SearchSender?> _resolveSender(int senderId) async {
    try {
      if (senderId > 0) {
        final user = await _client.query({
          '@type': 'getUser',
          'user_id': senderId,
        });
        return _SearchSender(
          name: TDParse.userName(user),
          photo: TDParse.smallPhoto(user.obj('profile_photo')),
        );
      }
      final chat = await _client.query({
        '@type': 'getChat',
        'chat_id': senderId,
      });
      final title = chat.str('title')?.trim();
      if (title == null || title.isEmpty) return null;
      return _SearchSender(
        name: title,
        photo: TDParse.smallPhoto(chat.obj('photo')),
      );
    } catch (_) {
      return null;
    }
  }

  void _cancelRun() {
    _debounce?.cancel();
    _debounce = null;
    _runId++;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelRun();
    _suggestDebounce?.cancel();
    _suggestDebounce = null;
    textController.dispose();
    focusNode.dispose();
    super.dispose();
  }
}

class _SearchSenderFilter {
  const _SearchSenderFilter({
    required this.query,
    required this.userId,
    required this.name,
  });

  final String query;
  final int userId;
  final String name;
}

class _SearchPage {
  const _SearchPage({
    required this.messages,
    required this.totalCount,
    required this.nextFromMessageId,
  });

  final List<ChatMessage> messages;
  final int totalCount;
  final int nextFromMessageId;
}
