import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:handy/l10n/app_localizations.dart';

import '../app/ipad_window_chrome.dart';
import '../app/primary_chat_launcher.dart';
import '../components/app_icons.dart';
import '../components/photo_avatar.dart';
import '../components/ui_components.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../theme/app_theme.dart';
import '../theme/date_text.dart';
import 'chat_row_view.dart';
import 'mini_apps_page.dart';
import 'public_discovery_view.dart';

const FontWeight _searchEmphasisWeight = AppTextWeight.medium;

class SearchView extends StatefulWidget {
  const SearchView({
    super.key,
    this.initialQuery = '',
    this.initialTab,
    this.showBackButton = true,
  });

  final String initialQuery;

  final SearchTab? initialTab;
  final bool showBackButton;

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  late final TextEditingController _controller;
  final _focus = FocusNode();
  final _vm = _SearchViewModel();
  late SearchTab _tab = widget.initialTab ?? SearchTab.chats;
  late String _query;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery.trim();
    _controller = TextEditingController(text: _query);
    _vm.addListener(() => setState(() {}));
    _vm.search(_query, _tab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted) _focus.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    _vm.dispose();
    super.dispose();
  }

  void _scheduleSearch(String q) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 240), () {
      if (mounted) _vm.search(q, _tab);
    });
  }

  void _searchNow(String q, SearchTab tab) {
    _searchDebounce?.cancel();
    _vm.search(q, tab);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return CupertinoPageScaffold(
      backgroundColor: c.groupedBackground,
      child: Column(
        children: [
          _header(),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _header() {
    final c = context.colors;
    return Container(
      padding: EdgeInsets.only(
        top:
            MediaQuery.of(context).padding.top +
            iPadWindowChromeInsetOf(context),
      ),
      decoration: BoxDecoration(
        color: c.listHeaderTint,
        border: Border(bottom: BorderSide(color: c.divider, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  if (widget.showBackButton)
                    GestureDetector(
                      key: const ValueKey('search-view-back'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).pop(),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: AppIcon(
                          HeroAppIcons.chevronLeft,
                          size: 22,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: c.searchFill,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          AppIcon(
                            HeroAppIcons.magnifyingGlass,
                            size: 15,
                            color: c.textTertiary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: CupertinoTextField(
                              controller: _controller,
                              focusNode: _focus,
                              autocorrect: false,
                              textInputAction: TextInputAction.search,
                              style: TextStyle(
                                fontSize: 15,
                                color: c.textPrimary,
                              ),
                              placeholder: AppStrings.t(
                                AppStringKeys.topicChatSearch,
                              ),
                              placeholderStyle: TextStyle(
                                fontSize: 15,
                                color: c.textTertiary,
                              ),
                              padding: EdgeInsets.zero,
                              decoration: null,
                              onChanged: (q) {
                                setState(() => _query = q);
                                _scheduleSearch(q);
                              },
                            ),
                          ),
                          if (_query.isNotEmpty)
                            GestureDetector(
                              onTap: () {
                                _controller.clear();
                                setState(() => _query = '');
                                _searchNow('', _tab);
                              },
                              child: AppIcon(
                                HeroAppIcons.xmark,
                                size: 16,
                                color: c.textTertiary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _focus.unfocus();
                      Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) =>
                              PublicDiscoveryView(initialQuery: _query),
                        ),
                      );
                    },
                    child: SizedBox(
                      width: 34,
                      height: 34,
                      child: Center(
                        child: AppIcon(
                          HeroAppIcons.globe,
                          size: 21,
                          color: AppTheme.brand,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _tabBar(),
        ],
      ),
    );
  }

  Widget _results() {
    final c = context.colors;
    if (_tab == SearchTab.miniApps) {
      return MiniAppsSearchTab(query: _query);
    }
    final hits = _vm.resultsFor(_tab);
    final allowEmptyQuery = _tab != SearchTab.chats;
    if (_query.trim().isEmpty && !allowEmptyQuery) {
      return _empty(AppStrings.t(AppStringKeys.chatsSearchPlaceholder));
    }
    if (_vm.isLoading(_tab) && hits.isEmpty) {
      return Container(
        color: c.groupedBackground,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 22,
          height: 22,
          child: CupertinoActivityIndicator(radius: 11),
        ),
      );
    }
    if (hits.isEmpty) {
      return _empty(AppStrings.t(AppStringKeys.chatsSearchNoResults));
    }
    return Container(
      color: c.background,
      child: ListView.builder(
        padding: EdgeInsets.zero,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: hits.length,
        itemBuilder: (context, i) {
          final hit = hits[i];
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _open(hit),
                child: hit.chat != null
                    ? ChatRowView(chat: hit.chat!)
                    : _hitRow(hit),
              ),
              const InsetDivider(leadingInset: 78),
            ],
          );
        },
      ),
    );
  }

  Future<void> _open(_SearchHit hit) async {
    await _openSearchHit(context, hit);
  }

  Widget _hitRow(_SearchHit hit) {
    final c = context.colors;
    final thumb = _hitThumb(hit);
    return Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: c.background,
      child: Row(
        children: [
          thumb,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hit.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: _searchEmphasisWeight,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hit.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: c.textSecondary),
                ),
              ],
            ),
          ),
          if (hit.timeLabel.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text(
              hit.timeLabel,
              style: TextStyle(fontSize: 13, color: c.textTertiary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hitThumb(_SearchHit hit) {
    final image = hit.thumbnail ?? hit.photo;
    if (hit.chat != null || hit.userId != null && hit.message == null) {
      return PhotoAvatar(title: hit.title, photo: hit.photo, size: 54);
    }
    if (image != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: SizedBox(
          width: 54,
          height: 54,
          child: Stack(
            fit: StackFit.expand,
            children: [
              TDImage(photo: image),
              if (hit.message?.video != null)
                Center(
                  child: Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF000000).withValues(alpha: 0.50),
                      shape: BoxShape.circle,
                    ),
                    child: const AppIcon(
                      HeroAppIcons.play,
                      size: 13,
                      color: Color(0xFFFFFFFF),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Container(
      width: 54,
      height: 54,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hit.tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: AppIcon(hit.icon, size: 24, color: hit.tint),
    );
  }

  Widget _empty(String text) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      color: c.groupedBackground,
      alignment: Alignment.center,
      child: Text(text, style: TextStyle(fontSize: 14, color: c.textTertiary)),
    );
  }

  Widget _tabBar() {
    final c = context.colors;
    return Container(
      height: 44,
      color: c.listHeaderTint,
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [for (final tab in SearchTab.values) _tabButton(tab)],
        ),
      ),
    );
  }

  Widget _tabButton(SearchTab tab) {
    final c = context.colors;
    final selected = _tab == tab;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_tab == tab) return;
        setState(() => _tab = tab);
        _searchNow(_query, tab);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: SizedBox(
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 160),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected
                      ? _searchEmphasisWeight
                      : AppTextWeight.regular,
                  color: selected ? AppTheme.brand : c.textSecondary,
                ),
                child: Text(tab.label, maxLines: 1),
              ),
              Positioned(
                bottom: 4,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: selected ? 18 : 0,
                  height: 3,
                  decoration: BoxDecoration(
                    color: AppTheme.brand,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _openSearchHit(BuildContext context, _SearchHit hit) async {
  if (hit.message != null && hit.chatId != null) {
    final title = hit.sourceTitle;
    await openChatFromCurrentWindow(
      context,
      chatId: hit.chatId!,
      title: title.isEmpty ? hit.title : title,
      initialMessageId: hit.message!.id,
    );
    return;
  }
  final chat = hit.chat;
  if (chat != null) {
    await openChatFromCurrentWindow(
      context,
      chatId: chat.id,
      title: chat.title,
    );
    return;
  }
  final userId = hit.userId;
  if (userId == null) return;
  try {
    final chat = await TdClient.shared.query({
      '@type': 'createPrivateChat',
      'user_id': userId,
      'force': false,
    });
    final summary = TDParse.chat(chat);
    if (!context.mounted || summary == null) return;
    await openChatFromCurrentWindow(
      context,
      chatId: summary.id,
      title: summary.title,
    );
  } catch (_) {}
}

enum SearchTab {
  chats,
  miniApps,
  posts,
  media,
  links,
  files,
  music,
  voice;

  String get label => switch (this) {
    SearchTab.chats => AppStrings.t(AppStringKeys.searchTabChats),
    SearchTab.miniApps => AppStrings.t(AppStringKeys.searchTabMiniApps),
    SearchTab.posts => AppStrings.t(AppStringKeys.searchTabMessages),
    SearchTab.media => AppStrings.t(AppStringKeys.searchTabMedia),
    SearchTab.links => AppStrings.t(AppStringKeys.searchTabLinks),
    SearchTab.files => AppStrings.t(AppStringKeys.searchTabFiles),
    SearchTab.music => AppStrings.t(AppStringKeys.searchTabMusic),
    SearchTab.voice => AppStrings.t(AppStringKeys.searchTabVoiceMessages),
  };

  String? get filter => switch (this) {
    SearchTab.chats => null,
    SearchTab.miniApps => null,
    SearchTab.posts => 'searchMessagesFilterEmpty',
    SearchTab.media => 'searchMessagesFilterPhotoAndVideo',
    SearchTab.links => 'searchMessagesFilterUrl',
    SearchTab.files => 'searchMessagesFilterDocument',
    SearchTab.music => 'searchMessagesFilterAudio',
    SearchTab.voice => 'searchMessagesFilterVoiceNote',
  };
}

class _SearchViewModel extends ChangeNotifier {
  int? scopeChatId;

  int? senderUserId;

  final Map<int, List<int>> _commonChatCache = {};

  final Map<SearchTab, List<_SearchHit>> _results = {
    for (final tab in SearchTab.values) tab: <_SearchHit>[],
  };
  final Set<SearchTab> _loading = {};
  final Map<SearchTab, String> _queries = {
    for (final tab in SearchTab.values) tab: '',
  };
  final Map<SearchTab, int> _runIds = {
    for (final tab in SearchTab.values) tab: 0,
  };
  bool _disposed = false;

  List<_SearchHit> resultsFor(SearchTab tab) => _results[tab] ?? const [];
  bool isLoading(SearchTab tab) => _loading.contains(tab);

  void search(String q, SearchTab tab) {
    if (_disposed) return;
    _startSearch(q.trim(), tab, resultLimit: 60);
    notifyListeners();
  }

  void searchMany(
    String q,
    Iterable<SearchTab> tabs, {
    required int resultLimitPerTab,
  }) {
    if (_disposed) return;
    final trimmed = q.trim();
    for (final tab in tabs) {
      _startSearch(trimmed, tab, resultLimit: resultLimitPerTab);
    }
    notifyListeners();
  }

  void clearTabs(Iterable<SearchTab> tabs) {
    if (_disposed) return;
    for (final tab in tabs) {
      _queries[tab] = '';
      _runIds[tab] = (_runIds[tab] ?? 0) + 1;
      _results[tab] = const [];
      _loading.remove(tab);
    }
    notifyListeners();
  }

  void _startSearch(String trimmed, SearchTab tab, {required int resultLimit}) {
    if (_disposed) return;
    final runId = (_runIds[tab] ?? 0) + 1;
    _runIds[tab] = runId;
    _queries[tab] = trimmed;
    if (tab == SearchTab.miniApps) {
      _results[tab] = const [];
      _loading.remove(tab);
      return;
    }
    if (trimmed.isEmpty && tab == SearchTab.chats) {
      _results[tab] = const [];
      _loading.remove(tab);
      return;
    }
    _loading.add(tab);
    if (tab == SearchTab.chats) {
      unawaited(_runChats(trimmed, tab, runId, resultLimit));
    } else {
      unawaited(_runMessages(trimmed, tab, runId, resultLimit));
    }
  }

  Future<ChatSummary?> _fetchChat(int id) async {
    try {
      return TDParse.chat(
        await TdClient.shared.query({'@type': 'getChat', 'chat_id': id}),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _runChats(
    String trimmed,
    SearchTab tab,
    int runId,
    int resultLimit,
  ) async {
    try {
      final out = <_SearchHit>[];
      final seenChats = <int>{};
      final seenUsers = <int>{};

      Future<void> addChat(int id, {String? subtitle}) async {
        if (!_isCurrent(tab, runId, trimmed) ||
            out.length >= resultLimit ||
            !seenChats.add(id)) {
          return;
        }
        try {
          final chat = await TdClient.shared.query({
            '@type': 'getChat',
            'chat_id': id,
          });
          final s = TDParse.chat(chat);
          if (s == null) return;
          out.add(_SearchHit.chat(s, subtitle: subtitle));
          final uid = s.peerUserId;
          if (uid != null) seenUsers.add(uid);
        } catch (_) {}
      }

      final local = await TdClient.shared.query({
        '@type': 'searchChats',
        'query': trimmed,
        'type_filter': null,
        'limit': resultLimit,
      });
      if (!_isCurrent(tab, runId, trimmed)) return;
      final localIds = <int>[
        for (final id in (local.int64Array('chat_ids') ?? const <int>[]).take(
          resultLimit,
        ))
          if (seenChats.add(id)) id,
      ];
      final localChats = await Future.wait(localIds.map(_fetchChat));
      if (!_isCurrent(tab, runId, trimmed)) return;
      for (final s in localChats) {
        if (s == null || out.length >= resultLimit) continue;
        out.add(_SearchHit.chat(s));
        final uid = s.peerUserId;
        if (uid != null) seenUsers.add(uid);
      }

      try {
        final contacts = await TdClient.shared.query({
          '@type': 'searchContacts',
          'query': trimmed,
          'limit': resultLimit,
        });
        for (final id
            in (contacts.int64Array('user_ids') ?? const <int>[]).take(
              resultLimit,
            )) {
          if (!_isCurrent(tab, runId, trimmed) || out.length >= resultLimit) {
            break;
          }
          if (!seenUsers.add(id)) continue;
          try {
            final user = await TdClient.shared.query({
              '@type': 'getUser',
              'user_id': id,
            });
            out.add(_SearchHit.user(id, user));
          } catch (_) {}
        }
      } catch (_) {}
      if (!_isCurrent(tab, runId, trimmed)) return;

      try {
        final public = await TdClient.shared.query({
          '@type': 'searchPublicChats',
          'query': trimmed,
          'type_filter': null,
        });
        for (final id in (public.int64Array('chat_ids') ?? const <int>[]).take(
          resultLimit,
        )) {
          await addChat(
            id,
            subtitle: AppStrings.t(
              AppStringKeys.chatsSearchPublicGroupsAndChannels,
            ),
          );
        }
      } catch (_) {}
      if (!_isCurrent(tab, runId, trimmed)) return;

      final handle = _usernameOf(trimmed);
      if (handle != null) {
        try {
          final chat = await TdClient.shared.query({
            '@type': 'searchPublicChat',
            'username': handle,
          });
          final id = chat.int64('id');
          if (id != null) await addChat(id, subtitle: '@$handle');
        } catch (_) {}
      }

      _finish(tab, runId, trimmed, out.take(resultLimit).toList());
    } catch (_) {
      _finish(tab, runId, trimmed, const []);
    }
  }

  Future<void> _runMessages(
    String trimmed,
    SearchTab tab,
    int runId,
    int resultLimit,
  ) async {
    final filter = tab.filter;
    if (filter == null) return;
    final scopeChatId = this.scopeChatId;
    final senderUserId = this.senderUserId;
    try {
      final List<List<Map<String, dynamic>>> pages;
      if (scopeChatId != null) {
        pages = [
          await _searchMessagesInChat(
            chatId: scopeChatId,
            query: trimmed,
            filter: filter,
            limit: resultLimit,
            senderUserId: senderUserId,
          ),
        ];
      } else if (senderUserId != null) {
        final chatIds = await _commonChatIds(senderUserId);
        if (!_isCurrent(tab, runId, trimmed)) return;
        pages = await Future.wait([
          for (final chatId in chatIds)
            _searchMessagesInChat(
              chatId: chatId,
              query: trimmed,
              filter: filter,
              limit: resultLimit,
              senderUserId: senderUserId,
            ),
        ]);
      } else {
        pages = await Future.wait([
          _searchMessagesInList(
            query: trimmed,
            filter: filter,
            chatList: {'@type': 'chatListMain'},
            limit: resultLimit,
          ),
          _searchMessagesInList(
            query: trimmed,
            filter: filter,
            chatList: {'@type': 'chatListArchive'},
            limit: resultLimit,
          ),
        ]);
      }
      if (!_isCurrent(tab, runId, trimmed)) return;
      final raw = <Map<String, dynamic>>[for (final page in pages) ...page]
        ..sort(
          (a, b) => (b.integer('date') ?? 0).compareTo(a.integer('date') ?? 0),
        );
      final seen = <String>{};
      final out = <_SearchHit>[];
      for (final object in raw) {
        if (!_isCurrent(tab, runId, trimmed) || out.length >= resultLimit) {
          break;
        }
        final chatId = object.int64('chat_id');
        final message = TDParse.message(object);
        if (chatId == null || message == null) continue;
        final key = '$chatId:${message.id}';
        if (!seen.add(key)) continue;
        final source = await _sourceFor(chatId);
        out.add(_SearchHit.message(message, chatId: chatId, source: source));
      }
      _finish(tab, runId, trimmed, out);
    } catch (_) {
      _finish(tab, runId, trimmed, const []);
    }
  }

  Future<List<int>> _commonChatIds(int userId) async {
    final cached = _commonChatCache[userId];
    if (cached != null) return cached;
    final ids = <int>[userId];
    try {
      final response = await TdClient.shared.query({
        '@type': 'getGroupsInCommon',
        'user_id': userId,
        'offset_chat_id': 0,
        'limit': 100,
      });
      ids.addAll(response.int64Array('chat_ids') ?? const <int>[]);
    } catch (_) {}
    final unique = List<int>.unmodifiable(ids.toSet());
    _commonChatCache[userId] = unique;
    return unique;
  }

  Future<List<Map<String, dynamic>>> _searchMessagesInChat({
    required int chatId,
    required String query,
    required String filter,
    required int limit,
    int? senderUserId,
  }) async {
    try {
      final res = await TdClient.shared.query({
        '@type': 'searchChatMessages',
        'chat_id': chatId,
        'query': query,
        'sender_id': senderUserId == null
            ? null
            : {'@type': 'messageSenderUser', 'user_id': senderUserId},
        'from_message_id': 0,
        'offset': 0,
        'limit': limit,
        'filter': {'@type': filter},
      });
      return res.objects('messages') ?? const <Map<String, dynamic>>[];
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> _searchMessagesInList({
    required String query,
    required String filter,
    required Map<String, dynamic> chatList,
    required int limit,
  }) async {
    try {
      final res = await TdClient.shared.query({
        '@type': 'searchMessages',
        'chat_list': chatList,
        'query': query,
        'offset': '',
        'limit': limit,
        'filter': {'@type': filter},
        'chat_type_filter': null,
        'min_date': 0,
        'max_date': 0,
      });
      return res.objects('messages') ?? const <Map<String, dynamic>>[];
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<_SearchSource> _sourceFor(int chatId) async {
    try {
      final chat = await TdClient.shared.query({
        '@type': 'getChat',
        'chat_id': chatId,
      });
      return _SearchSource(
        title: chat.str('title') ?? '',
        photo: TDParse.smallPhoto(chat.obj('photo')),
      );
    } catch (_) {
      return const _SearchSource(title: '', photo: null);
    }
  }

  void _finish(SearchTab tab, int runId, String query, List<_SearchHit> out) {
    if (!_isCurrent(tab, runId, query)) return;
    _results[tab] = out;
    _loading.remove(tab);
    notifyListeners();
  }

  bool _isCurrent(SearchTab tab, int runId, String query) =>
      !_disposed && _runIds[tab] == runId && _queries[tab] == query;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final tab in SearchTab.values) {
      _runIds[tab] = (_runIds[tab] ?? 0) + 1;
    }
    _loading.clear();
    super.dispose();
  }

  static final RegExp _handleLink = RegExp(
    r'(?:https?://)?(?:t\.me|telegram\.me)/(@?[A-Za-z0-9_]+)',
    caseSensitive: false,
  );
  static final RegExp _handleShape = RegExp(r'^[A-Za-z0-9_]{3,32}$');

  String? _usernameOf(String q) {
    var s = q.trim();
    final link = _handleLink.firstMatch(s);
    if (link != null) s = link.group(1)!;
    if (s.startsWith('@')) s = s.substring(1);
    return _handleShape.hasMatch(s) ? s : null;
  }
}

class _SearchHit {
  _SearchHit({
    required this.title,
    required this.subtitle,
    this.timeLabel = '',
    this.date = 0,
    this.sourceTitle = '',
    this.thumbnail,
    AppIconData? icon,
    this.tint = const Color(0xFF12B7F5),
    this.photo,
    this.chat,
    this.userId,
    this.chatId,
    this.message,
  }) : icon = icon ?? HeroAppIcons.message;

  factory _SearchHit.chat(ChatSummary chat, {String? subtitle}) => _SearchHit(
    title: chat.title,
    subtitle: subtitle ?? _chatSubtitle(chat),
    photo: chat.photo,
    chat: chat,
    userId: chat.peerUserId,
  );

  factory _SearchHit.user(int id, Map<String, dynamic> user) {
    final username = user.obj('usernames')?.str('editable_username');
    return _SearchHit(
      title: TDParse.userName(user),
      subtitle: username != null && username.isNotEmpty
          ? '@$username'
          : TDParse.userStatus(user),
      photo: TDParse.smallPhoto(user.obj('profile_photo')),
      userId: id,
    );
  }

  factory _SearchHit.message(
    ChatMessage message, {
    required int chatId,
    required _SearchSource source,
  }) {
    final document = message.document;
    final music = message.music;
    final title = document?.fileName ?? music?.title ?? _messageTitle(message);
    final subtitle = _messageSubtitle(message, source.title);
    return _SearchHit(
      title: title,
      subtitle: subtitle,
      timeLabel: DateText.listLabel(message.date),
      date: message.date,
      sourceTitle: source.title,
      photo: source.photo,
      thumbnail: message.previewImage ?? music?.cover,
      chatId: chatId,
      message: message,
      icon: _messageIcon(message),
      tint: _messageTint(message),
    );
  }

  final String title;
  final String subtitle;
  final String timeLabel;
  final int date;
  final String sourceTitle;
  final TdFileRef? photo;
  final TdFileRef? thumbnail;
  final ChatSummary? chat;
  final int? userId;
  final int? chatId;
  final ChatMessage? message;
  final AppIconData icon;
  final Color tint;

  static String _chatSubtitle(ChatSummary chat) {
    if (chat.kind == ChatKind.group) {
      return AppStrings.t(AppStringKeys.linkHandlerGroupLabel);
    }
    if (chat.kind == ChatKind.channel) {
      return AppStrings.t(AppStringKeys.tabChannels);
    }
    if (chat.kind == ChatKind.bot) {
      return AppStrings.t(AppStringKeys.chatsSearchBots);
    }
    return chat.lastMessage.isEmpty
        ? AppStrings.t(AppStringKeys.audioSearchChatTab)
        : chat.lastMessage;
  }

  static String _messageTitle(ChatMessage message) {
    if (message.music != null) return message.music!.title;
    if (message.voice != null) {
      return AppStrings.t(AppStringKeys.sharedMediaVoiceMessages);
    }
    if (message.video != null) {
      final text = message.text.trim();
      return text.isEmpty ||
              text == AppStrings.t(AppStringKeys.chatVideoPlaceholder)
          ? AppStrings.t(AppStringKeys.chatVideoPlaceholder)
          : text;
    }
    if (message.image != null) {
      final text = message.text.trim();
      return text.isEmpty ||
              text == AppStrings.t(AppStringKeys.composerImagePreview)
          ? AppStrings.t(AppStringKeys.composerImagePreview)
          : text;
    }
    return message.text.trim().isEmpty
        ? AppStrings.t(AppStringKeys.chatSearchMessageResultLabel)
        : message.text.trim();
  }

  static String _messageSubtitle(ChatMessage message, String sourceTitle) {
    final pieces = <String>[];
    final document = message.document;
    if (document != null && document.size > 0) {
      pieces.add(_fileSize(document.size));
    }
    final music = message.music;
    if (music?.performer?.isNotEmpty == true) pieces.add(music!.performer!);
    if (message.voice != null && message.voice!.duration > 0) {
      pieces.add(_duration(message.voice!.duration));
    }
    if (sourceTitle.isNotEmpty) pieces.add(sourceTitle);
    final text = message.text.trim();
    if (text.isNotEmpty &&
        document == null &&
        music == null &&
        message.voice == null &&
        text != AppStrings.t(AppStringKeys.composerImagePreview) &&
        text != AppStrings.t(AppStringKeys.chatVideoPlaceholder)) {
      pieces.add(text.replaceAll('\n', ' '));
    }
    return pieces.join(' · ');
  }

  static AppIconData _messageIcon(ChatMessage message) {
    if (message.document != null) return HeroAppIcons.solidFile;
    if (message.music != null) return HeroAppIcons.music;
    if (message.voice != null) return HeroAppIcons.microphone;
    if (message.linkPreview != null) return HeroAppIcons.link;
    if (message.video != null) return HeroAppIcons.video;
    if (message.image != null) return HeroAppIcons.solidImage;
    return HeroAppIcons.message;
  }

  static Color _messageTint(ChatMessage message) {
    if (message.document != null) return const Color(0xFF4AA3F0);
    if (message.music != null) return const Color(0xFFFF8A2A);
    if (message.voice != null) return const Color(0xFF28A878);
    if (message.linkPreview != null) return const Color(0xFF8E7BFF);
    if (message.video != null) return const Color(0xFF7B61FF);
    if (message.image != null) return const Color(0xFF15A7F7);
    return AppTheme.brand;
  }

  static String _fileSize(int bytes) {
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  static String _duration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _SearchSource {
  const _SearchSource({required this.title, required this.photo});
  final String title;
  final TdFileRef? photo;
}
