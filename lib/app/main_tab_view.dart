import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/account_store.dart';
import '../auth/auth_manager.dart';
import '../channels/topic_chat_view.dart';
import '../chat/chat_picker_view.dart';
import '../chat/chat_view.dart';
import '../chat/media_send_preview_view.dart';
import '../chat/music_player_controller.dart';
import '../chat/outgoing_attachment.dart';
import '../chats/archived_chats_view.dart';
import '../chats/chat_list_view.dart';
import '../communities/community_view.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/drawer_controller.dart' as dc;
import '../components/ui_components.dart';
import '../contacts/contacts_view.dart';
import '../l10n/app_localizations.dart';
import '../platform/android_share_intent.dart';
import '../profile/profile_view.dart';
import '../settings/topic_group_display_mode.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../tdlib/td_requests.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../update/update_checker.dart';
import 'adaptive_split_layout.dart';
import 'app_navigator.dart';
import 'bottom_bar_layout.dart';
import 'chat_deep_link_controller.dart';
import 'chat_pane.dart';
import 'detail_content_reveal.dart';
import 'horizontal_safe_viewport.dart';
import 'liquid_glass_bottom_bar.dart';
import 'native_bottom_tab_bar.dart';
import 'primary_chat_launcher.dart';
import 'unread_badge_model.dart';

class MainTabView extends StatefulWidget {
  const MainTabView({super.key});

  @override
  State<MainTabView> createState() => _MainTabViewState();
}

class MainSplitRootView extends StatefulWidget {
  const MainSplitRootView({super.key});

  @override
  State<MainSplitRootView> createState() => _MainSplitRootViewState();
}

class _MainTabViewState extends _MainRootViewState<MainTabView> {
  @override
  bool get checkForUpdates => true;
}

class _MainSplitRootViewState extends _MainRootViewState<MainSplitRootView> {}

abstract class _MainRootViewState<T extends StatefulWidget> extends State<T> {
  bool get checkForUpdates => false;

  int _selection = 0;
  late final dc.TabBarVisibility _tabBar = dc.TabBarVisibility();
  late final UnreadBadgeModel _unread = UnreadBadgeModel()..start();
  late final ChatListController _chatListController = ChatListController();
  late final ChatViewExitController _messageChatExitController =
      ChatViewExitController();
  ChatListSelection? _selectedMessageChat;
  final _chatPaneController = ChatPaneController();
  CommunityListSelection? _selectedMessageCommunity;
  ArchivedChatListSelection? _selectedArchivedChats;
  Widget? _selectedContactDetail;
  ChatDeepLinkController? _chatDeepLinks;
  AccountStore? _observedAccounts;
  int? _observedAccountSlot;
  final _splitSidebarWidth = ValueNotifier<double?>(null);
  bool? _wasUsingSplitSelection;
  final _androidShareIntent = AndroidShareIntentController.shared;
  bool _presentingAndroidShare = false;

  @override
  void initState() {
    super.initState();
    if (_androidShareIntent.supported) {
      _androidShareIntent.addListener(_handleAndroidShareIntentChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_androidShareIntent.start());
        unawaited(_presentPendingAndroidShare());
      });
    }
    if (checkForUpdates) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) UpdateChecker.maybePrompt(context);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final usesSplitSelection = _usesSplitSelection(context);
    if (_wasUsingSplitSelection == true && !usesSplitSelection) {
      _messageChatExitController.prepareExit();
      _selectedArchivedChats = null;
    }
    _wasUsingSplitSelection = usesSplitSelection;
    final accounts = context.read<AccountStore>();
    if (!identical(_observedAccounts, accounts)) {
      _observedAccounts?.removeListener(_handleAccountStoreChanged);
      _observedAccounts = accounts;
      _observedAccountSlot = accounts.activeSlot;
      accounts.addListener(_handleAccountStoreChanged);
    }
    final controller = context.read<ChatDeepLinkController>();
    if (identical(_chatDeepLinks, controller)) return;
    _chatDeepLinks?.removeListener(_handlePendingChatDeepLink);
    _chatDeepLinks = controller..addListener(_handlePendingChatDeepLink);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handlePendingChatDeepLink();
    });
  }

  @override
  void dispose() {
    _observedAccounts?.removeListener(_handleAccountStoreChanged);
    _chatDeepLinks?.removeListener(_handlePendingChatDeepLink);
    _androidShareIntent.removeListener(_handleAndroidShareIntentChanged);
    _chatListController.dispose();
    _unread.dispose();
    _tabBar.dispose();
    _splitSidebarWidth.dispose();
    super.dispose();
  }

  void _handleAndroidShareIntentChanged() {
    if (!mounted || !_androidShareIntent.hasPending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_presentPendingAndroidShare());
    });
  }

  Future<void> _presentPendingAndroidShare() async {
    if (!mounted || !_androidShareIntent.supported || _presentingAndroidShare) {
      return;
    }
    final payload = _androidShareIntent.takePending();
    if (payload == null) return;
    _presentingAndroidShare = true;
    final copiedPaths = <String>[];
    try {
      final sharedFiles = await _androidShareIntent.copyFiles(payload.uris);
      copiedPaths.addAll(sharedFiles.map((file) => file.path));
      if (!mounted) return;
      if (sharedFiles.isEmpty && payload.text.trim().isEmpty) return;

      final picked = await Navigator.of(context, rootNavigator: true)
          .push<ChatSummary>(
            MaterialPageRoute(
              builder: (_) =>
                  const ChatPickerView(title: AppStringKeys.topicChatShare),
            ),
          );
      if (!mounted || picked == null) return;

      if (sharedFiles.isEmpty) {
        await TdClient.shared.query(
          setTextChatDraftRequest(
            chatId: picked.id,
            formattedText: {'@type': 'formattedText', 'text': payload.text},
            date: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          ),
        );
        if (!mounted) return;
        await openChatFromCurrentWindow(
          context,
          chatId: picked.id,
          title: picked.title,
        );
        return;
      }

      final attachments = [
        for (final file in sharedFiles)
          OutgoingAttachment(
            path: file.path,
            kind: file.attachmentKind,
            fileName: file.fileName,
          ),
      ];
      final preview = await Navigator.of(context, rootNavigator: true)
          .push<MediaSendPreviewResult>(
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => MediaSendPreviewView(
                attachments: attachments,
                initialCaption: payload.text,
              ),
            ),
          );
      if (!mounted || preview == null || preview.attachments.isEmpty) return;
      final resolved = await resolveAttachmentListDimensions(
        preview.attachments,
      );
      final requests = buildAttachmentSendRequests(
        chatId: picked.id,
        attachments: resolved,
        caption: preview.caption,
        sendConfiguration: preview.sendConfiguration,
      );
      for (final request in requests) {
        await TdClient.shared.query(request);
      }
      if (!mounted) return;
      await openChatFromCurrentWindow(
        context,
        chatId: picked.id,
        title: picked.title,
      );
    } finally {
      await _androidShareIntent.deleteFiles(copiedPaths);
      _presentingAndroidShare = false;
      if (mounted && _androidShareIntent.hasPending) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_presentPendingAndroidShare());
        });
      }
    }
  }

  void _handleAccountStoreChanged() {
    final accounts = _observedAccounts;
    if (accounts == null || accounts.activeSlot == _observedAccountSlot) return;
    _messageChatExitController.prepareExit();
    _observedAccountSlot = accounts.activeSlot;
  }

  late final List<GlobalKey<NavigatorState>> _navKeys = List.generate(
    3,
    (_) => GlobalKey<NavigatorState>(),
  );

  static const _allTabs = [
    _MainTabItem(0, AppStringKeys.tabMessages, HeroAppIcons.solidMessage),
    _MainTabItem(1, AppStringKeys.tabContacts, HeroAppIcons.users),
    _MainTabItem(2, AppStringKeys.chatMeLabel, HeroAppIcons.solidCircleUser),
  ];

  List<_MainTabItem> _visibleTabs() {
    return [_allTabs[0], _allTabs[1], _allTabs[2]];
  }

  Widget _root(int i) => switch (i) {
    0 => ChatListView(controller: _chatListController),
    1 => const ContactsView(),
    _ => const ProfileView(),
  };

  Future<bool> _onWillPop() async {
    if (_usesSplitSelection(context)) {
      if (_chatPaneController.pop()) return false;
      switch (_selection) {
        case 0:
          if (_selectedArchivedChats != null) {
            setState(() => _selectedArchivedChats = null);
            return false;
          }
          if (_selectedMessageChat != null) {
            _messageChatExitController.prepareExit();
            setState(() => _selectedMessageChat = null);
            return false;
          }
          if (_selectedMessageCommunity != null) {
            setState(() => _selectedMessageCommunity = null);
            return false;
          }
        case 1:
          if (_selectedContactDetail != null) {
            setState(() => _selectedContactDetail = null);
            return false;
          }
      }
    }
    final nav = _navKeys[_selection].currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return false;
    }
    return true;
  }

  void _select(int i) {
    final theme = context.read<ThemeController>();
    final tabs = _visibleTabs();
    if (i < 0 || i >= tabs.length) return;
    final tabIndex = tabs[i].index;
    final shouldToggleMessages = tabIndex == 0;
    if (tabIndex == _selection) {
      if (_usesSplitSelection(context) &&
          tabIndex == 0 &&
          _selectedArchivedChats != null) {
        setState(() => _selectedArchivedChats = null);
        return;
      }
      _navKeys[tabIndex].currentState?.popUntil((r) => r.isFirst);
      if (_usesSplitSelection(context)) _clearTabletDetail(tabIndex);
      if (shouldToggleMessages) _toggleMessagesListTarget(theme);
      return;
    }
    if (_usesSplitSelection(context) && _selection == 0) {
      _messageChatExitController.prepareExit();
    }
    setState(() => _selection = tabIndex);
    if (shouldToggleMessages) _toggleMessagesListTarget(theme);
  }

  void _toggleMessagesListTarget(ThemeController theme) {
    _chatListController.toggleFirstUnreadOrTop(
      mayHaveUnread: _unread.countFor(theme.unreadBadgeMode) > 0,
    );
  }

  void _handlePendingChatDeepLink() {
    if (!mounted) return;
    final request = _chatDeepLinks?.consumePending();
    if (request == null) return;
    _openMessageDeepLink(request);
  }

  void _openMessageDeepLink(ChatDeepLinkRequest request) {
    final accounts = context.read<AccountStore>();
    final requestedSlot = resolveDeepLinkAccountSlot(
      requestedSlot: request.accountSlot,
      requestedUserId: request.accountUserId,
      activeSlot: accounts.activeSlot,
      accounts: [
        for (final account in accounts.summaries)
          (slot: account.slot, userId: account.userId),
      ],
    );
    if (requestedSlot == null) return;
    if (requestedSlot != accounts.activeSlot) {
      accounts.switchTo(requestedSlot, context.read<AuthManager>());
      final controller = _chatDeepLinks;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final replay = request.scopedToAccountSlot(requestedSlot);
        controller?.openChat(
          chatId: replay.chatId,
          title: replay.title,
          messageId: replay.messageId,
          accountUserId: replay.accountUserId,
          accountSlot: replay.accountSlot,
        );
      });
      return;
    }
    if (_usesSplitSelection(context)) {
      final nextSelection = ChatListSelection(
        chatId: request.chatId,
        title: request.title,
        initialMessageId: request.messageId,
      );
      _prepareMessageChatReplacement(nextSelection);
      setState(() {
        _selection = 0;
        _selectedMessageCommunity = null;
        _selectedMessageChat = nextSelection;
      });
      return;
    }

    setState(() => _selection = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context, rootNavigator: true);
      if (!request.preserveChatStack) {
        navigator.popUntil((route) => route.isFirst);
      }
      navigator.push(
        AppChatPageRoute(
          builder: (_) => ChatView(
            chatId: request.chatId,
            title: request.title,
            initialMessageId: request.messageId,
          ),
        ),
      );
    });
  }

  void _clearTabletDetail(int tabIndex) {
    switch (tabIndex) {
      case 0:
        if (_selectedMessageChat != null || _selectedMessageCommunity != null) {
          _messageChatExitController.prepareExit();
          setState(() {
            _selectedMessageChat = null;
            _selectedMessageCommunity = null;
          });
        }
      case 1:
        if (_selectedContactDetail != null) {
          setState(() => _selectedContactDetail = null);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _tabBar),
        ChangeNotifierProvider.value(value: _unread),
      ],
      child: Material(
        type: MaterialType.transparency,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (!didPop) await _onWillPop();
          },
          child: _classicTabs(),
        ),
      ),
    );
  }


  Widget _tabNavigator(int i) {
    return _TabNavigator(
      navigatorKey: _navKeys[i],
      tabIndex: i,
      visibility: _tabBar,
      root: _root(i),
    );
  }

  int _visibleSelection(List<_MainTabItem> tabs) {
    final index = tabs.indexWhere((tab) => tab.index == _selection);
    return index < 0 ? tabs.length - 1 : index;
  }

  Widget _stack(List<_MainTabItem> tabs) => _LazyTabStack(
    selection: _visibleSelection(tabs),
    items: tabs,
    builder: (tab) => _tabNavigator(tab.index),
  );


  Widget _classicTabs() {
    final theme = context.watch<ThemeController>();
    if (!theme.communitiesEnabled && _selectedMessageCommunity != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            context.read<ThemeController>().communitiesEnabled ||
            _selectedMessageCommunity == null) {
          return;
        }
        setState(() => _selectedMessageCommunity = null);
      });
    }
    final tabs = _visibleTabs();
    if (!tabs.any((tab) => tab.index == _selection)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selection = tabs.last.index);
      });
    }
    final selection = _visibleSelection(tabs);
    final activeTabIndex = tabs[selection].index;
    final showSplitPanes =
        _usesTabletSplit(context) && !_hasCompactNavigationStack;
    if (showSplitPanes || _retainsCompactDetail) {
      return _tabletSplitTabs(
        tabs,
        selection,
        activeTabIndex,
        compact: !showSplitPanes,
      );
    }
    return AnimatedBuilder(
      animation: _tabBar,
      builder: (context, _) {
        if (_usesTabletSplit(context) && !_hasCompactNavigationStack) {
          return _tabletSplitTabs(tabs, selection, activeTabIndex);
        }
        final showTabBar = _tabBar.depth(activeTabIndex) == 0;
        final bottomBar = showTabBar
            ? AnimatedBuilder(
                animation: _unread,
                builder: (context, _) => _MainBottomBar(
                  chatListController: _chatListController,
                  selection: selection,
                  onSelect: _select,
                  items: tabs,
                  onClearUnread: _chatListController.markAllRead,
                  unread: _unread.countFor(theme.unreadBadgeMode),
                ),
              )
            : const SizedBox.shrink();
        return BottomBarLayout(
          overlay: showTabBar,
          body: _musicAwareContent(_stack(tabs)),
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _fixedMusicPlayer(safeBottom: !showTabBar),
              bottomBar,
            ],
          ),
        );
      },
    );
  }

  Widget _fixedMusicPlayer({required bool safeBottom}) {
    return AnimatedBuilder(
      animation: MusicPlayerController.shared,
      builder: (context, _) {
        final player = MusicPlayerController.shared;
        final content =
            player.isVisible &&
                !player.collapsed &&
                !player.hasEmbeddedPlayerHost
            ? GlobalMusicPlayerBar(
                bottomPadding: safeBottom
                    ? MediaQuery.paddingOf(context).bottom.clamp(0, 12)
                    : 0,
              )
            : const SizedBox.shrink();
        if (AppMotion.isReduced(context)) return content;
        return AnimatedSize(
          duration: AppMotion.duration(context, AppMotion.responsive),
          curve: AppMotion.standard,
          child: content,
        );
      },
    );
  }

  Widget _musicAwareContent(Widget child, {bool reserveForShellPlayer = true}) {
    return AnimatedBuilder(
      animation: MusicPlayerController.shared,
      child: child,
      builder: (context, child) {
        final player = MusicPlayerController.shared;
        if (!reserveForShellPlayer ||
            !player.isVisible ||
            player.collapsed ||
            player.hasEmbeddedPlayerHost) {
          return child!;
        }
        return MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: child!,
        );
      },
    );
  }

  Widget _tabletSplitTabs(
    List<_MainTabItem> tabs,
    int selection,
    int activeTabIndex, {
    bool compact = false,
  }) {
    final theme = context.watch<ThemeController>();
    final size = MediaQuery.of(context).size;
    return ValueListenableBuilder<double?>(
      valueListenable: _splitSidebarWidth,
      builder: (context, requestedWidth, _) {
        final sidebarWidth = constrainSplitSidebarWidth(
          requestedWidth:
              requestedWidth ?? defaultSplitSidebarWidth(size.width),
          totalWidth: size.width,
        );
        return AnimatedBuilder(
          animation: _tabBar,
          builder: (context, _) => Column(
            children: [
              Expanded(
                child: MusicPlayerShellScope(
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: compact ? 0 : sidebarWidth,
                            child: Offstage(
                              offstage: compact,
                              child: OverflowBox(
                                minWidth: sidebarWidth,
                                maxWidth: sidebarWidth,
                                child: BottomBarLayout(
                                  overlay: true,
                                  body: _LazyTabStack(
                                    selection: selection,
                                    items: tabs,
                                    builder: (tab) =>
                                        _tabletSidebarRoot(tab.index),
                                  ),
                                  footer: AnimatedBuilder(
                                    animation: _unread,
                                    builder: (context, _) => _MainBottomBar(
                                      chatListController: _chatListController,
                                      selection: selection,
                                      onSelect: _select,
                                      items: tabs,
                                      onClearUnread:
                                          _chatListController.markAllRead,
                                      unread: _unread.countFor(
                                        theme.unreadBadgeMode,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: _musicAwareContent(
                              _animatedTabletDetailPane(
                                activeTabIndex,
                                showMessageBackButton: compact,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (!compact)
                        Positioned(
                          left: sidebarWidth - splitResizeHandleWidth / 2,
                          top: 0,
                          bottom: 0,
                          child: _splitResizeHandle(
                            totalWidth: size.width,
                            sidebarWidth: sidebarWidth,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              _fixedMusicPlayer(safeBottom: true),
            ],
          ),
        );
      },
    );
  }

  Widget _splitResizeHandle({
    required double totalWidth,
    required double sidebarWidth,
  }) {
    return _SplitResizeHandle(
      onDragStart: () {
        _splitSidebarWidth.value = sidebarWidth;
      },
      onDragUpdate: (delta) {
        final current = _splitSidebarWidth.value ?? sidebarWidth;
        _splitSidebarWidth.value = constrainSplitSidebarWidth(
          requestedWidth: current + delta,
          totalWidth: totalWidth,
        );
      },
    );
  }

  Widget _tabletSidebarRoot(int tabIndex) {
    final communitiesEnabled = context
        .watch<ThemeController>()
        .communitiesEnabled;
    return switch (tabIndex) {
      0 => _tabletMessagesSidebar(communitiesEnabled),
      1 => ContactsView(
        onOpenDetail: (detail) {
          setState(() => _selectedContactDetail = detail);
        },
      ),
      _ => const ProfileView(),
    };
  }

  Widget _tabletMessagesSidebar(bool communitiesEnabled) {
    final archivedSelection = _selectedArchivedChats;
    return IndexedStack(
      index: archivedSelection == null ? 0 : 1,
      children: [
        TickerMode(
          enabled: archivedSelection == null,
          child: ChatListView(
            controller: _chatListController,
            selectedChatId: _selectedMessageChat?.chatId,
            selectedCommunityId: communitiesEnabled
                ? _selectedMessageCommunity?.community.id
                : null,
            onChatSelected: (chat) {
              _prepareMessageChatReplacement(chat);
              setState(() {
                _selectedMessageCommunity = null;
                _selectedMessageChat = chat;
              });
            },
            onCommunitySelected: (community) {
              if (!communitiesEnabled) return;
              _messageChatExitController.prepareExit();
              setState(() {
                _selectedMessageChat = null;
                _selectedMessageCommunity = community;
              });
            },
            onOpenArchived: (selection) {
              setState(() => _selectedArchivedChats = selection);
            },
          ),
        ),
        if (archivedSelection == null)
          const SizedBox.shrink()
        else
          LiveArchivedChatsView(
            updates: archivedSelection.updates,
            chatsProvider: archivedSelection.chatsProvider,
            selectedChatId: _selectedMessageChat?.chatId,
            onClearUnread: archivedSelection.onClearUnread,
            onUnarchive: archivedSelection.onUnarchive,
            onBack: () => setState(() => _selectedArchivedChats = null),
            onChatSelected: (chat) {
              final nextSelection = ChatListSelection.fromChat(chat);
              _prepareMessageChatReplacement(nextSelection);
              setState(() {
                _selectedMessageCommunity = null;
                _selectedMessageChat = nextSelection;
              });
            },
          ),
      ],
    );
  }

  Widget _tabletDetailPane(
    int activeTabIndex, {
    bool showMessageBackButton = false,
    VoidCallback? onMessageInfoPressed,
    VoidCallback? onMessageOpenFullInfo,
    void Function(int userId, String name)? onMessageOpenUserProfile,
    Widget? messageTrailingPane,
    double messageTrailingPaneWidth = 0,
  }) => switch (activeTabIndex) {
    0 => _messageDetailPane(
      showBackButton: showMessageBackButton,
      onInfoPressed: onMessageInfoPressed,
      onOpenFullInfo: onMessageOpenFullInfo,
      onOpenUserProfile: onMessageOpenUserProfile,
      trailingPane: messageTrailingPane,
      trailingPaneWidth: messageTrailingPaneWidth,
    ),
    1 =>
      _selectedContactDetail ??
          const _SplitEmptyPane(
            icon: HeroAppIcons.users,
            title: AppStringKeys.tabSelectContact,
          ),
    _ => const SizedBox.shrink(),
  };

  Widget _animatedTabletDetailPane(
    int activeTabIndex, {
    bool showMessageBackButton = false,
    VoidCallback? onMessageInfoPressed,
    VoidCallback? onMessageOpenFullInfo,
    void Function(int userId, String name)? onMessageOpenUserProfile,
    Widget? messageTrailingPane,
    double messageTrailingPaneWidth = 0,
  }) {
    final detail = _tabletDetailPane(
      activeTabIndex,
      showMessageBackButton: showMessageBackButton,
      onMessageInfoPressed: onMessageInfoPressed,
      onMessageOpenFullInfo: onMessageOpenFullInfo,
      onMessageOpenUserProfile: onMessageOpenUserProfile,
      messageTrailingPane: messageTrailingPane,
      messageTrailingPaneWidth: messageTrailingPaneWidth,
    );
    final motionKey = switch (activeTabIndex) {
      0 when _selectedMessageCommunity != null => ValueKey(
        'tablet-message-community-${_selectedMessageCommunity!.community.id}',
      ),
      0 when _selectedMessageChat != null => ValueKey(
        'tablet-message-chat-${_selectedMessageChat!.chatId}-'
        '${_selectedMessageChat!.supportsTopics}-'
        '${_selectedMessageChat!.initialMessageId ?? 0}-'
        '${_selectedMessageChat!.composerFocusRequestId}',
      ),
      0 => const ValueKey('tablet-message-empty'),
      1 when _selectedContactDetail != null => ObjectKey(
        _selectedContactDetail!,
      ),
      1 => const ValueKey('tablet-contact-empty'),
      _ => const ValueKey('tablet-profile-root'),
    };
    return DetailContentReveal(
      motionKey: motionKey,
      child: ChatPane(
        key: ValueKey(('chat-pane', motionKey)),
        controller: _chatPaneController,
        child: detail,
      ),
    );
  }

  Widget _messageDetailPane({
    bool showBackButton = false,
    VoidCallback? onInfoPressed,
    VoidCallback? onOpenFullInfo,
    void Function(int userId, String name)? onOpenUserProfile,
    Widget? trailingPane,
    double trailingPaneWidth = 0,
  }) {
    final selectedCommunity =
        context.watch<ThemeController>().communitiesEnabled
        ? _selectedMessageCommunity
        : null;
    if (selectedCommunity != null) {
      return KeyedSubtree(
        key: ValueKey('message-community-${selectedCommunity.community.id}'),
        child: CommunityView(
          community: selectedCommunity.community,
          chats: selectedCommunity.chats,
          viewableChats: selectedCommunity.viewableChats,
          updates: selectedCommunity.updates,
          chatsProvider: selectedCommunity.chatsProvider,
          viewableChatsProvider: selectedCommunity.viewableChatsProvider,
          onCollapsedChanged: selectedCommunity.onCollapsedChanged,
          showBackButton: showBackButton,
          onBack: showBackButton
              ? () => setState(() => _selectedMessageCommunity = null)
              : null,
          onChatSelected: (chat) {
            final nextSelection = ChatListSelection.fromChat(chat);
            _prepareMessageChatReplacement(nextSelection);
            setState(() {
              _selectedMessageCommunity = null;
              _selectedMessageChat = nextSelection;
            });
          },
        ),
      );
    }
    final selected = _selectedMessageChat;
    if (selected == null) {
      return ColoredBox(color: context.colors.groupedBackground);
    }
    final chat = selected.chat;
    const headerHeight =
        AppMetric.headerAvatarSize + (AppSpacing.md + AppSpacing.xxs) * 2;
    final headerColor = context.colors.chatBackground;
    return KeyedSubtree(
      key: ValueKey(
        'message-detail-${selected.chatId}-${selected.supportsTopics}-'
        '${selected.initialMessageId ?? 0}-${selected.forumTopicId ?? 0}-'
        '${selected.composerFocusRequestId}',
      ),
      child:
          selected.supportsTopics &&
              chat != null &&
              selected.initialMessageId == null &&
              !context.read<ThemeController>().forumTopicsAsGroupChat
          ? _ForumSplitDetailPane(
              chat: chat,
              headerHeight: headerHeight,
              headerColor: headerColor,
              exitController: _messageChatExitController,
              showBackButton: showBackButton,
              onBack: () => setState(() => _selectedMessageChat = null),
              onInfoPressed: onInfoPressed,
              onOpenFullInfo: onOpenFullInfo,
              onOpenUserProfile: onOpenUserProfile,
              trailingPane: trailingPane,
              trailingPaneWidth: trailingPaneWidth,
            )
          : ChatView(
              chatId: selected.chatId,
              title: selected.title,
              seedMessage: chat?.lastChatMessage,
              initialMessageId: selected.initialMessageId,
              forumTopicId: selected.forumTopicId,
              showBackButton: showBackButton,
              headerHeight: headerHeight,
              headerColor: headerColor,
              showHeaderDivider: false,
              trailingPane: trailingPane,
              trailingPaneWidth: trailingPaneWidth,
              requestComposerFocusOnReady: selected.composerFocusRequestId != 0,
              exitController: _messageChatExitController,
              onChatKindResolved: (kind) =>
                  _handleSelectedChatKindResolved(selected.chatId, kind),
              onInfoPressed: onInfoPressed,
              onOpenFullInfo: onOpenFullInfo,
              onOpenUserProfile: onOpenUserProfile,
              onOpenTopicTranscript: (topicId) =>
                  _openSelectedChatTopic(selected.chatId, topicId),
              onBack: () => setState(() => _selectedMessageChat = null),
            ),
    );
  }

  void _prepareMessageChatReplacement(ChatListSelection? nextSelection) {
    final current = _selectedMessageChat;
    if (current == null ||
        (nextSelection != null &&
            current.chatId == nextSelection.chatId &&
            current.supportsTopics == nextSelection.supportsTopics &&
            current.initialMessageId == nextSelection.initialMessageId &&
            current.forumTopicId == nextSelection.forumTopicId &&
            current.composerFocusRequestId ==
                nextSelection.composerFocusRequestId)) {
      return;
    }
    _messageChatExitController.prepareExit();
  }

  void _openSelectedChatTopic(int chatId, int? topicId) {
    final current = _selectedMessageChat;
    if (current == null ||
        current.chatId != chatId ||
        current.forumTopicId == topicId) {
      return;
    }
    final next = current.withForumTopic(topicId);
    _prepareMessageChatReplacement(next);
    setState(() => _selectedMessageChat = next);
  }

  void _handleSelectedChatKindResolved(int chatId, ChatKind kind) {
    final current = _selectedMessageChat;
    if (current == null || current.chatId != chatId || current.kind == kind) {
      return;
    }
    setState(() => _selectedMessageChat = current.withResolvedKind(kind));
  }

  bool _usesTabletSplit(BuildContext context) {
    return usesAdaptiveSplitLayout(MediaQuery.of(context).size);
  }

  bool _usesSplitSelection(BuildContext context) {
    if (_hasCompactNavigationStack) return false;
    return _retainsCompactDetail ||
        usesSplitSelectionLayout(MediaQuery.sizeOf(context));
  }

  bool get _retainsCompactDetail =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      _selection == 0 &&
      (_selectedMessageChat != null || _selectedMessageCommunity != null);

  bool get _hasCompactNavigationStack =>
      _navKeys[_selection].currentState != null &&
      _tabBar.depth(_selection) > 0;
}

class _SplitResizeHandle extends StatefulWidget {
  const _SplitResizeHandle({
    required this.onDragStart,
    required this.onDragUpdate,
  });

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;

  @override
  State<_SplitResizeHandle> createState() => _SplitResizeHandleState();
}

class _SplitResizeHandleState extends State<_SplitResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final dividerColor = _hovered
        ? AppTheme.brand.withValues(alpha: 0.78)
        : context.colors.divider;
    return Semantics(
      label: AppStrings.t(AppStringKeys.mainTabResizeSidebar),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) {
          if (!_hovered) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: GestureDetector(
          key: const ValueKey('main-split-resize-handle'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => widget.onDragStart(),
          onHorizontalDragUpdate: (details) =>
              widget.onDragUpdate(details.delta.dx),
          child: SizedBox(
            width: splitResizeHandleWidth,
            child: Center(
              child: AnimatedContainer(
                duration: AppMotion.duration(context, AppMotion.quick),
                curve: AppMotion.standard,
                width: _hovered ? 2 : 1,
                color: dividerColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ForumSplitDetailPane extends StatefulWidget {
  const _ForumSplitDetailPane({
    required this.chat,
    required this.headerHeight,
    required this.headerColor,
    required this.exitController,
    required this.showBackButton,
    required this.onBack,
    this.onInfoPressed,
    this.onOpenFullInfo,
    this.onOpenUserProfile,
    this.trailingPane,
    this.trailingPaneWidth = 0,
  });

  final ChatSummary chat;
  final double headerHeight;
  final Color headerColor;
  final ChatViewExitController exitController;
  final bool showBackButton;
  final VoidCallback onBack;
  final VoidCallback? onInfoPressed;
  final VoidCallback? onOpenFullInfo;
  final void Function(int userId, String name)? onOpenUserProfile;
  final Widget? trailingPane;
  final double trailingPaneWidth;

  @override
  State<_ForumSplitDetailPane> createState() => _ForumSplitDetailPaneState();
}

class _ForumSplitDetailPaneState extends State<_ForumSplitDetailPane> {
  var _index = 0;
  int? _topicThreadId;

  Future<void> _showChatMode() async {
    await TopicGroupDisplayPreference.set(TopicGroupDisplayMode.chat);
    if (!mounted) return;
    setState(() => _index = 0);
  }

  Future<void> _showChannelMode([int? threadId]) async {
    await TopicGroupDisplayPreference.set(TopicGroupDisplayMode.channel);
    if (!mounted) return;
    widget.exitController.prepareExit();
    setState(() {
      _index = 1;
      _topicThreadId = threadId;
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = _index == 0
        ? ChatView(
            key: const ValueKey('forum-detail-chat'),
            chatId: widget.chat.id,
            title: widget.chat.title,
            seedMessage: widget.chat.lastChatMessage,
            showBackButton: widget.showBackButton,
            headerHeight: widget.headerHeight,
            headerColor: widget.headerColor,
            trailingPane: widget.trailingPane,
            trailingPaneWidth: widget.trailingPaneWidth,
            exitController: widget.exitController,
            onInfoPressed: widget.onInfoPressed,
            onOpenFullInfo: widget.onOpenFullInfo,
            onOpenUserProfile: widget.onOpenUserProfile,
            onBack: widget.onBack,
            onOpenTopicMode: (threadId) =>
                unawaited(_showChannelMode(threadId)),
          )
        : TopicChatView(
            key: ValueKey('${widget.chat.id}:${_topicThreadId ?? 0}'),
            chat: widget.chat,
            initialThreadId: _topicThreadId,
            showBackButton: widget.showBackButton,
            headerHeight: widget.headerHeight,
            headerColor: widget.headerColor,
            onOpenChatView: () => unawaited(_showChatMode()),
            onBack: widget.onBack,
          );
    return DetailContentReveal(
      motionKey: ValueKey('forum-detail-$_index-${_topicThreadId ?? 0}'),
      child: content,
    );
  }
}

class _SplitEmptyPane extends StatelessWidget {
  const _SplitEmptyPane({required this.icon, required this.title});

  final AppIconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.groupedBackground,
      child: Center(
        child: Opacity(
          opacity: 0.18,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(icon, size: 56, color: c.textTertiary),
              const SizedBox(height: 14),
              Text(
                title.l10n(context),
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: c.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MainTabItem {
  const _MainTabItem(this.index, this.label, this.icon);

  final int index;
  final String label;
  final AppIconData icon;
}

class _LazyTabStack extends StatefulWidget {
  const _LazyTabStack({
    required this.selection,
    required this.items,
    required this.builder,
  });

  final int selection;
  final List<_MainTabItem> items;
  final Widget Function(_MainTabItem tab) builder;

  @override
  State<_LazyTabStack> createState() => _LazyTabStackState();
}

class _LazyTabStackState extends State<_LazyTabStack>
    with SingleTickerProviderStateMixin {
  final Set<int> _builtTabIndexes = {};
  late final AnimationController _transition;
  int? _departingTabIndex;
  double _direction = 1;
  int _transitionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _transition = AnimationController(
      vsync: this,
      duration: AppMotion.deliberate,
      value: 1,
    );
    _rememberSelection();
  }

  @override
  void didUpdateWidget(covariant _LazyTabStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPosition = _selectedPosition(oldWidget);
    final oldTabIndex = oldWidget.items.isEmpty
        ? null
        : oldWidget.items[oldPosition].index;
    _builtTabIndexes.removeWhere(
      (index) => !widget.items.any((tab) => tab.index == index),
    );
    _rememberSelection();
    if (widget.items.isEmpty) return;
    final nextPosition = _selectedPosition(widget);
    final nextTabIndex = widget.items[nextPosition].index;
    if (oldTabIndex == null || oldTabIndex == nextTabIndex) return;

    _direction = nextPosition >= oldPosition ? 1 : -1;
    _departingTabIndex = widget.items.any((tab) => tab.index == oldTabIndex)
        ? oldTabIndex
        : null;
    _transition.duration = AppMotion.duration(context, AppMotion.deliberate);
    final generation = ++_transitionGeneration;
    if (_transition.duration == Duration.zero) {
      _transition.value = 1;
      _departingTabIndex = null;
      return;
    }
    _transition.forward(from: 0).whenComplete(() {
      if (!mounted || generation != _transitionGeneration) return;
      setState(() => _departingTabIndex = null);
    });
  }

  int _selectedPosition(_LazyTabStack source) => source.items.isEmpty
      ? 0
      : source.selection.clamp(0, source.items.length - 1).toInt();

  void _rememberSelection() {
    if (widget.items.isEmpty) return;
    final selectedIndex = _selectedPosition(widget);
    final selected = widget.items[selectedIndex];
    _builtTabIndexes.add(selected.index);
  }

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.expand();
    final selectedPosition = _selectedPosition(widget);
    final selectedTabIndex = widget.items[selectedPosition].index;
    return ColoredBox(
      color: context.colors.background,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _transition,
          builder: (context, _) {
            final progress = AppMotion.standard.transform(_transition.value);
            return Stack(
              fit: StackFit.expand,
              children: [
                for (final tab in widget.items)
                  _animatedTab(
                    tab: tab,
                    selectedTabIndex: selectedTabIndex,
                    progress: progress,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _animatedTab({
    required _MainTabItem tab,
    required int selectedTabIndex,
    required double progress,
  }) {
    final selected = tab.index == selectedTabIndex;
    final departing = tab.index == _departingTabIndex;
    final visible = selected || departing;
    final opacity = selected ? 1.0 : 1 - progress;
    final offset = selected
        ? _direction * 20 * (1 - progress)
        : -_direction * 10 * progress;
    final scale = selected ? 0.995 + 0.005 * progress : 1 - 0.005 * progress;

    return Offstage(
      offstage: !visible,
      child: ExcludeSemantics(
        excluding: !selected,
        child: IgnorePointer(
          ignoring: !selected,
          child: TickerMode(
            enabled: selected,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.translate(
                key: ValueKey('main-tab-translation-${tab.index}'),
                offset: Offset(offset, 0),
                child: Transform.scale(
                  key: ValueKey('main-tab-scale-${tab.index}'),
                  scale: scale,
                  child: KeyedSubtree(
                    key: ValueKey('main-tab-${tab.index}'),
                    child: _builtTabIndexes.contains(tab.index)
                        ? widget.builder(tab)
                        : const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabNavigator extends StatefulWidget {
  const _TabNavigator({
    required this.navigatorKey,
    required this.tabIndex,
    required this.visibility,
    required this.root,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final int tabIndex;
  final dc.TabBarVisibility visibility;
  final Widget root;

  @override
  State<_TabNavigator> createState() => _TabNavigatorState();
}

class _TabNavigatorState extends State<_TabNavigator> {
  late final _observer = dc.TabDepthObserver(
    widget.tabIndex,
    widget.visibility,
  );

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: widget.navigatorKey,
      observers: [_observer],
      onGenerateRoute: (settings) =>
          MaterialPageRoute(builder: (_) => widget.root, settings: settings),
    );
  }
}

class _MainBottomBar extends StatelessWidget {
  const _MainBottomBar({
    required this.selection,
    required this.onSelect,
    required this.onClearUnread,
    required this.items,
    required this.unread,
    this.chatListController,
  });
  final int selection;
  final ValueChanged<int> onSelect;
  final VoidCallback onClearUnread;
  final List<_MainTabItem> items;
  final int unread;
  final ChatListController? chatListController;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sideGeometry = SideNavigationGeometry.of(context);
    const sideItemHeight = SideNavigationGeometry.itemExtent;
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        sideGeometry?.fits(items.length, sideItemHeight) == true) {
      return SideNavigationPortal(
        fillSide: true,
        visible: ModalRoute.isCurrentOf(context) ?? true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            key: const ValueKey('side-tab-bar'),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (chatListController != null && items[selection].index == 0)
                Expanded(
                  child: ValueListenableBuilder<Widget?>(
                    valueListenable: chatListController!.sideFolders,
                    builder: (_, folders, _) =>
                        folders ?? const SizedBox.shrink(),
                  ),
                )
              else
                const Spacer(),
              const SizedBox(height: 12),
              for (var i = 0; i < items.length; i++)
                AppInteractiveSurface(
                  key: ValueKey('side-tab-${items[i].index}'),
                  semanticLabel: items[i].label.l10n(context),
                  selected: selection == i,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  onTap: () => onSelect(i),
                  child: Container(
                    height: sideItemHeight,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: selection == i
                          ? c.linkBlue.withValues(alpha: 0.10)
                          : null,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 28,
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              AppIcon(
                                items[i].icon,
                                size: 24,
                                color: selection == i
                                    ? c.linkBlue
                                    : c.textTertiary,
                              ),
                              if (i == 0 && unread > 0)
                                Positioned(
                                  right: -12,
                                  top: -4,
                                  child: UnreadBadge(
                                    count: unread,
                                    onClear: onClearUnread,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return NativeBottomTabBar(
        items: [
          for (final item in items)
            NativeBottomTabItem(
              id: item.index,
              label: item.label.l10n(context),
              icon: item.icon,
            ),
        ],
        selection: selection,
        unread: unread,
        unreadLabel: context.watch<ThemeController>().unreadBadgeOverflowMode.format(unread),
        onSelect: onSelect,
        onClearUnread: onClearUnread,
      );
    }
    final theme = context.watch<ThemeController>();
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    const barHeight = 46.0;
    final themeButton = LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxHeight;
        return SizedBox.expand(
          child: AppInteractiveSurface(
            borderRadius: BorderRadius.circular(size / 2),
            onTap: () => theme.toggleDayNight(brightness),
            child: Center(
              child: AppIcon(
                isDark ? HeroAppIcons.sun : HeroAppIcons.moon,
                size: 22,
                color: c.textPrimary,
              ),
            ),
          ),
        );
      },
    );
    final controls = SizedBox(
      height: barHeight,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            Expanded(
              child: AppInteractiveSurface(
                key: ValueKey('bottom-tab-${items[i].index}'),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                semanticLabel: items[i].label.l10n(context),
                selected: selection == i,
                onTap: () => onSelect(i),
                child: SizedBox(
                  height: barHeight,
                  child: Center(
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        const SizedBox(width: 32, height: 28),
                        TweenAnimationBuilder<double>(
                          duration: AppMotion.duration(
                            context,
                            AppMotion.responsive,
                          ),
                          curve: AppMotion.standard,
                          tween: Tween<double>(end: selection == i ? 1 : 0),
                          builder: (context, value, child) =>
                              Transform.translate(
                            offset: Offset(0, -value),
                            child: Transform.scale(
                              scale: 1 + value * 0.08,
                              child: AppIcon(
                                items[i].icon,
                                size: 24,
                                color: Color.lerp(
                                  c.textTertiary,
                                  AppTheme.brand,
                                  value,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (i == 0 && unread > 0)
                          Positioned(
                            right: -12,
                            top: -4,
                            child: UnreadBadge(
                              count: unread,
                              onClear: onClearUnread,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return LiquidGlassBottomBar(
      selection: selection,
      itemCount: items.length,
      trailing: themeButton,
      child: controls,
    );
  }
}
