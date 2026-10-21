import 'dart:async';

import 'package:flutter/material.dart';
import 'package:handy/l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../app/app_navigator.dart';
import '../app/bottom_bar_layout.dart';
import '../app/ipad_window_chrome.dart';
import '../app/primary_chat_launcher.dart';
import '../chat/chat_view.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/photo_avatar.dart';
import '../components/ui_components.dart';
import '../profile/adaptive_profile_launcher.dart';
import '../profile/profile_detail_view.dart';
import '../tdlib/chat_membership.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'add_people_view.dart';

bool contactMatchesQuery(Contact contact, String rawQuery) => _contactMatches(
  contact,
  rawQuery.trim().toLowerCase().replaceFirst(RegExp(r'^@+'), ''),
);

bool _contactMatches(Contact contact, String query) {
  if (query.isEmpty) return true;
  return contact.name.toLowerCase().contains(query) ||
      contact.usernames.any(
        (username) => username.toLowerCase().contains(query),
      ) ||
      (contact.username?.toLowerCase().contains(query) ?? false);
}

class ContactRowView extends StatelessWidget {
  const ContactRowView({
    super.key,
    required this.contact,
    required this.onTap,
  });

  final Contact contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return AppInteractiveSurface(
      semanticLabel: contact.name,
      semanticValue: contact.statusText.isEmpty
          ? null
          : contact.statusText.l10n(context),
      onTap: onTap,
      child: SizedBox(
        height: AppMetric.listRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          child: Row(
            children: [
              PhotoAvatar(
                title: contact.name,
                photo: contact.photo,
                size: 44.0,
                showOnlineDot: contact.isOnline,
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTextSize.bodyLarge,
                        color: c.textPrimary,
                      ),
                    ),
                    if (contact.statusText.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        contact.statusText.l10n(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTextSize.footnote,
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ContactsView extends StatefulWidget {
  const ContactsView({
    super.key,
    this.onOpenDetail,
  });

  final ValueChanged<Widget>? onOpenDetail;

  @override
  State<ContactsView> createState() => _ContactsViewState();
}

class _ContactsViewState extends State<ContactsView> {
  final _vm = ContactsViewModel();
  final _searchController = TextEditingController();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _vm.addListener(() {
      if (mounted) setState(() {});
    });
    _vm.onAppear();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _vm.dispose();
    super.dispose();
  }

  void _showAddMenu() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AddPeopleView()));
  }

  void _openDetail(Widget detail, {bool outsideTabs = false}) {
    if (widget.onOpenDetail != null) {
      widget.onOpenDetail!(detail);
      return;
    }
    final route = detail is ChatView
        ? AppChatPageRoute<void>(builder: (_) => detail)
        : MaterialPageRoute<void>(builder: (_) => detail);
    if (outsideTabs) {
      pushAppChatRoute(context, route);
      return;
    }
    Navigator.of(context).push(route);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final query = _searchController.text.trim().toLowerCase();
    final contactQuery = query.replaceFirst(RegExp(r'^@+'), '');
    return Container(
      color: c.groupedBackground,
      child: Column(
        children: [
          _header(),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _searchPill()),
                SliverToBoxAdapter(child: _tabs()),
                switch (_tab) {
                  0 => _contactSliver(
                    _filterContacts(_vm.contacts, contactQuery),
                    loading: _vm.contactsLoading,
                  ),
                  1 => _chatSliver(
                    _filterChats(_vm.groups, query),
                    loading: _vm.chatsLoading,
                  ),
                  2 => _chatSliver(
                    _filterChats(_vm.channels, query),
                    loading: _vm.chatsLoading,
                  ),
                  _ => _contactSliver(
                    _filterContacts(_vm.bots, contactQuery),
                    loading: _vm.contactsLoading,
                  ),
                },
                SliverToBoxAdapter(
                  child: SizedBox(height: BottomBarInset.of(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Contact> _filterContacts(List<Contact> source, String query) => source
      .where((contact) => _contactMatches(contact, query))
      .toList(growable: false);

  List<ChatSummary> _filterChats(List<ChatSummary> source, String query) =>
      query.isEmpty
      ? source
      : source
            .where((chat) => chat.title.toLowerCase().contains(query))
            .toList(growable: false);

  Widget _header() {
    final c = context.colors;
    return Container(
      key: const ValueKey('contacts-root-header'),
      color: c.listHeaderTint,
      padding: EdgeInsets.only(
        top:
            MediaQuery.of(context).padding.top +
            iPadWindowChromeInsetOf(context),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Text(
              AppStringKeys.tabContacts.l10n(context),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
            const Spacer(),
            AppInteractiveSurface(
              semanticLabel: AppStringKeys.addPeopleFindPeople.l10n(context),
              onTap: _showAddMenu,
              borderRadius: BorderRadius.circular(AppRadius.control),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: AppIcon(
                  HeroAppIcons.userPlus,
                  size: 22,
                  color: c.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchPill() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: _searchField(),
    );
  }

  Widget _searchField() {
    final c = context.colors;
    return Container(
      key: const ValueKey('contacts-search-field'),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.searchFill,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        children: [
          AppIcon(
            HeroAppIcons.magnifyingGlass,
            size: 16,
            color: c.textTertiary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 14, color: c.textPrimary),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: AppStringKeys.topicChatSearch.l10n(context),
                hintStyle: TextStyle(fontSize: 14, color: c.textTertiary),
              ),
            ),
          ),
          if (_searchController.text.isNotEmpty)
            AppInteractiveSurface(
              semanticLabel: AppStringKeys.countryPickerCancel.l10n(context),
              onTap: () {
                _searchController.clear();
                setState(() {});
              },
              borderRadius: BorderRadius.circular(AppRadius.control),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: AppIcon(
                  HeroAppIcons.xmark,
                  size: 14,
                  color: c.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tabs() {
    final c = context.colors;
    const labels = [
      AppStringKeys.contactsFriends,
      AppStringKeys.chatInfoGroupChat,
      AppStringKeys.tabChannels,
      AppStringKeys.chatsSearchBots,
    ];
    return Container(
      key: const ValueKey('contacts-tabs'),
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: c.card,
        border: Border(bottom: BorderSide(color: c.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: _contactTab(
                index: i,
                label: labels[i].l10n(context),
              ),
            ),
        ],
      ),
    );
  }

  Widget _contactTab({required int index, required String label}) {
    final c = context.colors;
    final selected = _tab == index;
    return AppInteractiveSurface(
      key: ValueKey('contacts-tab-$index'),
      semanticLabel: label,
      selected: selected,
      onTap: () => setState(() => _tab = index),
      child: SizedBox(
        height: 50,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    label,
                    key: ValueKey('contacts-tab-label-$index'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
            AnimatedContainer(
              key: ValueKey('contacts-tab-indicator-$index'),
              duration: const Duration(milliseconds: 180),
              width: selected ? 44 : 0,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.brand,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(List<Widget> children) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
      child: Container(
        decoration: BoxDecoration(color: c.card),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      ),
    );
  }

  Widget _rowCard(BuildContext context, Widget row, {required bool last}) {
    return ColoredBox(
      color: context.colors.card,
      child: last
          ? row
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [row, const InsetDivider(leadingInset: 70)],
            ),
    );
  }

  Widget _contactSliver(List<Contact> contacts, {required bool loading}) {
    if (contacts.isEmpty) {
      return SliverToBoxAdapter(
        child: _stateCard(
          loading: loading,
          emptyText: _tab == 3
              ? AppStringKeys.contactsNoBots
              : AppStringKeys.contactsNoContacts,
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 24),
      sliver: SliverList.builder(
        itemCount: contacts.length,
        itemBuilder: (context, index) {
          final contact = contacts[index];
          return _rowCard(
            context,
            ContactRowView(
              contact: contact,
              onTap: () => unawaited(
                openAdaptiveUserProfile(
                  context,
                  userId: contact.id,
                  name: contact.name,
                  preferInlinePane: widget.onOpenDetail != null,
                  openFallback: () => _openDetail(
                    ProfileDetailView(
                      userId: contact.id,
                      name: contact.name,
                      showBackButton: widget.onOpenDetail == null,
                    ),
                  ),
                ),
              ),
            ),
            last: index == contacts.length - 1,
          );
        },
      ),
    );
  }

  Widget _chatSliver(List<ChatSummary> chats, {required bool loading}) {
    final c = context.colors;
    final circleGroups = context.watch<ThemeController>().circularGroupAvatars;
    const rowHeight = AppMetric.listRowHeight;
    const avatarSize = 44.0;
    const titleFontSize = AppTextSize.bodyLarge;
    if (chats.isEmpty) {
      return SliverToBoxAdapter(
        child: _stateCard(
          loading: loading,
          emptyText: _tab == 2
              ? AppStringKeys.contactsNoChannels
              : AppStringKeys.contactsNoGroupChats,
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 24),
      sliver: SliverList.builder(
        itemCount: chats.length,
        itemBuilder: (context, index) {
          final group = chats[index];
          return _rowCard(
            context,
            AppInteractiveSurface(
              semanticLabel: group.title,
              onTap: () => unawaited(
                openChatFromCurrentWindow(
                  context,
                  chatId: group.id,
                  title: group.title,
                  openFallback: () async => _openDetail(
                    ChatView(
                      chatId: group.id,
                      title: group.title,
                      showBackButton: widget.onOpenDetail == null,
                      showHeaderDivider: widget.onOpenDetail == null,
                    ),
                    outsideTabs: true,
                  ),
                ),
              ),
              child: SizedBox(
                height: rowHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xl,
                  ),
                  child: Row(
                    children: [
                      PhotoAvatar(
                        title: group.title,
                        photo: group.photo,
                        size: avatarSize,
                        square: !circleGroups,
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        child: Text(
                          group.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: titleFontSize,
                            color: c.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            last: index == chats.length - 1,
          );
        },
      ),
    );
  }

  Widget _stateCard({required bool loading, required String emptyText}) {
    final c = context.colors;
    return _card([
      SizedBox(
        height: 180,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              else
                AppIcon(HeroAppIcons.users, size: 30, color: c.textTertiary),
              const SizedBox(height: 12),
              Text(
                (loading ? AppStringKeys.contactsLoading : emptyText).l10n(
                  context,
                ),
                style: TextStyle(fontSize: 14, color: c.textSecondary),
              ),
            ],
          ),
        ),
      ),
    ]);
  }
}

class ContactsViewModel extends ChangeNotifier {
  List<Contact> contacts = [];
  List<Contact> bots = [];
  List<ChatSummary> groups = [];
  List<ChatSummary> channels = [];
  bool contactsLoading = true;
  bool chatsLoading = true;

  bool _started = false;
  final Map<int, ChatSummary> _groupIndex = {};
  final Map<int, ChatSummary> _channelIndex = {};
  final Map<int, Contact> _botIndex = {};
  final Set<int> _resolvingBots = {};
  final Set<String> _loadingChatLists = {};
  final Set<String> _exhaustedChatLists = {};
  final Set<int> _hydratedChats = {};
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _refreshTimer;
  bool _disposed = false;
  static const _pageSize = 100;
  static const _prefetchPasses = 8;

  void onAppear() {
    if (_started) return;
    _started = true;
    _loadContacts();
    _subscribe();
    _prefetchChats();
  }

  Future<void> _loadContacts() async {
    contactsLoading = true;
    _safeNotify();
    try {
      final result = await TdClient.shared.query({'@type': 'getContacts'});
      if (_disposed) return;
      final ids = result.int64Array('user_ids') ?? const <int>[];
      final loaded = <Contact>[];
      for (final id in ids.take(300)) {
        if (_disposed) return;
        try {
          final user = await TdClient.shared.query({
            '@type': 'getUser',
            'user_id': id,
          });
          if (_disposed) return;
          final contact = _contactFromUser(id, user);
          if (_isBotUser(user)) {
            _botIndex[id] = contact;
          } else {
            loaded.add(contact);
          }
        } catch (_) {}
      }
      loaded.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      contacts = loaded;
      _sortBots();
    } catch (_) {
    } finally {
      contactsLoading = false;
      _safeNotify();
    }
  }

  Contact _contactFromUser(int id, Map<String, dynamic> user) {
    final usernames = TDParse.activeUsernames(user);
    return Contact(
      id: id,
      name: TDParse.userName(user),
      username: usernames.isEmpty ? null : usernames.first,
      usernames: usernames,
      statusText: _isBotUser(user)
          ? AppStringKeys.chatsSearchBots
          : TDParse.userStatus(user),
      photo: TDParse.smallPhoto(user.obj('profile_photo')),
      isOnline: TDParse.isUserOnline(user),
    );
  }

  bool _isBotUser(Map<String, dynamic> user) =>
      user.obj('type')?.type == 'userTypeBot' ||
      user.obj('type')?.type == 'userTypeRegularBot' ||
      user.boolean('is_bot') == true;

  String _chatListKey(Map<String, dynamic> list) =>
      switch (list.type ?? list['@type']) {
        'chatListArchive' => 'archive',
        'chatListFolder' => 'folder:${list.integer('chat_folder_id') ?? 0}',
        _ => 'main',
      };

  Future<bool> _loadChatList(Map<String, dynamic> list, int limit) async {
    final key = _chatListKey(list);
    if (_loadingChatLists.contains(key) || _exhaustedChatLists.contains(key)) {
      return false;
    }
    _loadingChatLists.add(key);
    try {
      await TdClient.shared.query({
        '@type': 'loadChats',
        'chat_list': list,
        'limit': limit,
      });
      return true;
    } catch (error) {
      if (error is TdError && error.code == 404) {
        _exhaustedChatLists.add(key);
      }
      return false;
    } finally {
      _loadingChatLists.remove(key);
    }
  }

  Future<void> _hydrateChatList(Map<String, dynamic> list, int limit) async {
    try {
      final res = await TdClient.shared.query({
        '@type': 'getChats',
        'chat_list': list,
        'limit': limit,
      });
      final ids = res.int64Array('chat_ids') ?? const <int>[];
      for (final id in ids) {
        if (_disposed) return;
        if (_hydratedChats.contains(id)) continue;
        try {
          final chat = await TdClient.shared.query({
            '@type': 'getChat',
            'chat_id': id,
          });
          if (_disposed) return;
          _hydratedChats.add(id);
          await _ingestChat(chat);
        } catch (_) {}
      }
    } catch (_) {}
  }

  void _prefetchChats() {
    Future<void>(() async {
      chatsLoading = true;
      _safeNotify();
      const lists = [
        {'@type': 'chatListMain'},
        {'@type': 'chatListArchive'},
      ];
      for (final list in lists) {
        await _prefetchChatList(list);
      }
      chatsLoading = false;
      _flushChatLists();
    });
  }

  Future<void> _prefetchChatList(Map<String, dynamic> list) async {
    final key = _chatListKey(list);
    await _hydrateChatList(list, _pageSize);
    var passes = 0;
    while (!_disposed &&
        !_exhaustedChatLists.contains(key) &&
        passes < _prefetchPasses) {
      passes += 1;
      final loaded = await _loadChatList(list, _pageSize);
      await _hydrateChatList(list, _pageSize * (passes + 1));
      if (_disposed || !loaded) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void _subscribe() {
    _subscription = TdClient.shared
        .updatesOfAny(const [
          'updateNewChat',
          'updateChatAddedToList',
          'updateChatPosition',
          'updateChatRemovedFromList',
          'updateChatTitle',
          'updateChatPhoto',
        ])
        .listen((update) {
          if (_disposed) return;
          switch (update.type) {
            case 'updateNewChat':
              final chat = update.obj('chat');
              if (chat != null) unawaited(_ingestChat(chat));
            case 'updateChatAddedToList':
              final id = update.int64('chat_id');
              if (id != null) _ensureChatLoaded(id);
            case 'updateChatPosition':
              final id = update.int64('chat_id');
              if (id != null) _ensureChatLoaded(id);
            case 'updateChatRemovedFromList':
              final id = update.int64('chat_id');
              if (id != null) _ensureChatLoaded(id);
            case 'updateChatTitle':
              final id = update.int64('chat_id');
              final existing = id != null ? _chatById(id) : null;
              if (existing != null) {
                existing.title = update.str('title') ?? existing.title;
                _ingest(existing);
              }
            case 'updateChatPhoto':
              final id = update.int64('chat_id');
              final existing = id != null ? _chatById(id) : null;
              if (existing != null) {
                existing.photo = TDParse.smallPhoto(update.obj('photo'));
                _ingest(existing);
              }
          }
        });
  }

  ChatSummary? _chatById(int id) => _groupIndex[id] ?? _channelIndex[id];

  void _ensureChatLoaded(int id) {
    TdClient.shared
        .query({'@type': 'getChat', 'chat_id': id})
        .then((chat) {
          if (!_disposed) unawaited(_ingestChat(chat));
        })
        .catchError((_) {});
  }

  Future<void> _ingestChat(Map<String, dynamic> chat) async {
    final summary = TDParse.chat(chat);
    if (summary == null) return;
    final type = chat.obj('type');
    if (summary.kind == ChatKind.privateChat) {
      final userId = type?.int64('user_id');
      if (userId != null) _resolveBot(userId);
      return;
    }
    if (!await isJoinedGroupOrChannelChat(summary.id, chat: chat)) {
      _removeChat(summary.id);
      return;
    }
    _ingest(summary);
  }

  void _removeChat(int id) {
    var changed = false;
    changed = _groupIndex.remove(id) != null || changed;
    changed = _channelIndex.remove(id) != null || changed;
    if (!changed) return;
    _scheduleChatListRefresh();
  }

  void _ingest(ChatSummary summary) {
    switch (summary.kind) {
      case ChatKind.group:
        _groupIndex[summary.id] = summary;
      case ChatKind.channel:
        _channelIndex[summary.id] = summary;
      default:
        return;
    }
    _scheduleChatListRefresh();
  }

  void _scheduleChatListRefresh() {
    if (_disposed || _refreshTimer != null) return;
    _refreshTimer = Timer(const Duration(milliseconds: 80), _flushChatLists);
  }

  void _flushChatLists() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_disposed) return;
    _refreshChatLists();
    _safeNotify();
  }

  void _refreshChatLists() {
    groups = _sortedByTitle(_groupIndex.values);
    channels = _sortedByTitle(_channelIndex.values);
  }

  List<ChatSummary> _sortedByTitle(Iterable<ChatSummary> chats) {
    final keyed = [
      for (final chat in chats) (key: chat.title.toLowerCase(), chat: chat),
    ]..sort((a, b) => a.key.compareTo(b.key));
    return [for (final entry in keyed) entry.chat];
  }

  void _resolveBot(int userId) {
    if (_disposed) return;
    if (_botIndex.containsKey(userId) || _resolvingBots.contains(userId)) {
      return;
    }
    _resolvingBots.add(userId);
    TdClient.shared
        .query({'@type': 'getUser', 'user_id': userId})
        .then((user) {
          if (_disposed) return;
          _resolvingBots.remove(userId);
          if (!_isBotUser(user)) return;
          _botIndex[userId] = _contactFromUser(userId, user);
          _sortBots();
          _safeNotify();
        })
        .catchError((_) {
          if (_disposed) return;
          _resolvingBots.remove(userId);
        });
  }

  void _sortBots() {
    bots = _botIndex.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
