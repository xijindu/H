//
//  chat_list_view.dart
//
//  The 消息 tab: a custom reference header (avatar → profile drawer, name +
//  online, trailing "+") over a search pill and the chat list. Rows use a custom
//  left-swipe that reveals flush, full-height action blocks (置顶 / 标为未读 /
//  删除), matching the reference rather than the rounded native swipe. The "+"
//  opens a dropdown of create actions. Port of the Swift `ChatListView`.
//

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:handy/l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../app/app_navigator.dart';
import '../app/bottom_bar_layout.dart';
import '../app/horizontal_safe_viewport.dart';
import '../app/ipad_window_chrome.dart';
import '../auth/account_store.dart';
import '../channels/forum_topic_browser_view.dart';
import '../chat/chat_view.dart';
import '../chat/link_handler.dart';
import '../communities/community_models.dart';
import '../communities/community_view.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/app_press_ripple.dart';
import '../components/chat_folder_icons.dart';
import '../components/toast.dart';
import '../components/ui_components.dart';
import '../contacts/create_group_view.dart';
import '../security/local_app_lock_controller.dart';
import '../settings/chat_folder_management_view.dart';
import '../settings/chat_folder_service.dart';
import '../settings/edit_field_view.dart';
import '../settings/topic_group_display_mode.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'archived_chats_view.dart';
import 'chat_delete_dialog.dart';
import 'chat_delete_policy.dart';
import 'chat_folder_tag_controller.dart';
import 'chat_list_preview.dart';
import 'chat_list_view_model.dart';
import 'chat_removal_actions.dart';
import 'chat_row_view.dart';
import 'filtered_chats_view.dart';
import 'qr_scanner_view.dart';
import '../profile/qr_code_view.dart';
import 'search_view.dart';

class ChatListController extends ChangeNotifier {
  final sideFolders = ValueNotifier<Widget?>(null);
  Object? _sideFoldersOwner;
  bool _disposed = false;

  void publishSideFolders(Object owner, Widget? child) {
    if (_disposed) return;
    _sideFoldersOwner = owner;
    sideFolders.value = child;
  }

  void clearSideFolders(Object owner) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && identical(owner, _sideFoldersOwner)) {
        sideFolders.value = null;
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    sideFolders.dispose();
    super.dispose();
  }

  int _scrollToFirstUnreadRequests = 0;
  int _toggleFirstUnreadRequests = 0;
  int _markAllReadRequests = 0;
  int _newChatRequests = 0;
  int _focusSearchRequests = 0;
  bool _toggleRequestMayHaveUnread = false;
  int get scrollToFirstUnreadRequests => _scrollToFirstUnreadRequests;
  int get toggleFirstUnreadRequests => _toggleFirstUnreadRequests;
  int get markAllReadRequests => _markAllReadRequests;
  int get newChatRequests => _newChatRequests;
  int get focusSearchRequests => _focusSearchRequests;
  bool get toggleRequestMayHaveUnread => _toggleRequestMayHaveUnread;

  void scrollToFirstUnread() {
    _scrollToFirstUnreadRequests++;
    notifyListeners();
  }

  void toggleFirstUnreadOrTop({required bool mayHaveUnread}) {
    _toggleRequestMayHaveUnread = mayHaveUnread;
    _toggleFirstUnreadRequests++;
    notifyListeners();
  }

  void markAllRead() {
    _markAllReadRequests++;
    notifyListeners();
  }

  void openNewChat() {
    _newChatRequests++;
    notifyListeners();
  }

  void focusSearch() {
    _focusSearchRequests++;
    notifyListeners();
  }
}

class ChatFolderRail extends StatelessWidget {
  const ChatFolderRail({
    super.key,
    required this.filters,
    required this.selectedFolderId,
    required this.onSelect,
    this.keyForFolder,
    this.onEdit,
    this.highlights = const {},
  });
  final List<ChatFilterOption> filters;
  final int? selectedFolderId;
  final ValueChanged<ChatFilterOption> onSelect;
  final Key? Function(int? folderId)? keyForFolder;
  final ValueChanged<ChatFilterOption>? onEdit;

  /// Live page-transition highlights; omitted for a settled folder rail.
  final Map<int?, double> highlights;

  double _highlight(ChatFilterOption filter) =>
      highlights[filter.folderId] ??
      (filter.folderId == selectedFolderId ? 1 : 0);
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      key: const PageStorageKey('side-chat-folders'),
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        for (final filter in filters)
          AppInteractiveSurface(
              key: keyForFolder?.call(filter.folderId),
              semanticLabel: filter.title.l10n(context),
              selected: filter.folderId == selectedFolderId,
              borderRadius: BorderRadius.circular(AppRadius.control),
              onTap: () => onSelect(filter),
              child: Container(
                key: ValueKey('side-folder-${filter.folderId ?? 'all'}'),
                constraints: const BoxConstraints(minHeight: 56),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  color: c.linkBlue.withValues(
                    alpha: 0.10 * _highlight(filter),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ChatFolderIcon(
                      filter.isAll ? 'All' : filter.iconName,
                      size: 22,
                      color: Color.lerp(
                        c.textSecondary,
                        c.linkBlue,
                        _highlight(filter),
                      )!,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      filter.title.l10n(context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: _highlight(filter) >= 0.5
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: Color.lerp(
                          c.textSecondary,
                          c.linkBlue,
                          _highlight(filter),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class ChatListSelection {
  const ChatListSelection({
    required this.chatId,
    required this.title,
    this.chat,
    this.resolvedKind,
    this.initialMessageId,
    this.forumTopicId,
    this.composerFocusRequestId = 0,
  });

  ChatListSelection.fromChat(
    ChatSummary chat, {
    this.composerFocusRequestId = 0,
  }) : chatId = chat.id,
       title = chat.title,
       chat = chat,
       resolvedKind = chat.kind,
       initialMessageId = null,
       forumTopicId = null;

  final int chatId;
  final String title;
  final ChatSummary? chat;
  final ChatKind? resolvedKind;
  final int? initialMessageId;

  /// The forum topic shown as an ordinary transcript when topics are folded
  /// into the group chat; null shows the whole chat.
  final int? forumTopicId;
  final int composerFocusRequestId;

  ChatKind? get kind => chat?.kind ?? resolvedKind;
  bool get isForum => chat?.isForum ?? false;
  bool get supportsTopics => chat?.supportsTopics ?? false;

  ChatListSelection withResolvedKind(ChatKind kind) => ChatListSelection(
    chatId: chatId,
    title: title,
    chat: chat,
    resolvedKind: kind,
    initialMessageId: initialMessageId,
    forumTopicId: forumTopicId,
    composerFocusRequestId: composerFocusRequestId,
  );

  ChatListSelection withForumTopic(int? topicId) => ChatListSelection(
    chatId: chatId,
    title: title,
    chat: chat,
    resolvedKind: resolvedKind,
    forumTopicId: topicId,
    composerFocusRequestId: composerFocusRequestId,
  );
}

/// Keeps the active conversation visually anchored in split layouts.
///
/// The subtle wash composes the user-selected brand color over the row's
/// current themed surface. The short leading rail stays crisp in both light
/// and dark/custom themes without changing the row's hit testing.
class ChatListSelectionHighlight extends StatelessWidget {
  const ChatListSelectionHighlight({
    super.key,
    required this.selected,
    required this.child,
  });

  static const tintKey = ValueKey('chat-list-selected-tint');
  static const railKey = ValueKey('chat-list-selected-rail');
  static const semanticsKey = ValueKey('chat-list-selected-semantics');

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!selected) return child;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final brand = AppTheme.brand;
    return Semantics(
      key: semanticsKey,
      container: true,
      selected: true,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                key: tintKey,
                color: brand.withValues(alpha: isDark ? 0.13 : 0.08),
              ),
            ),
          ),
          PositionedDirectional(
            start: 0,
            top: AppSpacing.sm,
            bottom: AppSpacing.sm,
            child: IgnorePointer(
              child: Container(
                key: railKey,
                width: 3,
                decoration: BoxDecoration(
                  color: brand,
                  borderRadius: const BorderRadiusDirectional.horizontal(
                    end: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live archive-list data handed to the adaptive shell when Archived Chats
/// should replace only the list pane.
///
/// The chat list remains mounted behind that pane, so [chatsProvider] and
/// [updates] continue to expose current archive contents while it is open.
class ArchivedChatListSelection {
  const ArchivedChatListSelection({
    required this.chatsProvider,
    required this.updates,
    required this.onClearUnread,
    this.onUnarchive,
  });

  final List<ChatSummary> Function() chatsProvider;
  final Listenable updates;
  final ValueChanged<ChatSummary> onClearUnread;
  final ValueChanged<ChatSummary>? onUnarchive;
}

bool chatListPreviewSupportsQuickReply(ChatSummary chat) =>
    !chat.supportsTopics &&
    switch (chat.kind) {
      ChatKind.privateChat ||
      ChatKind.group ||
      ChatKind.bot ||
      ChatKind.secret => true,
      ChatKind.channel || ChatKind.unknown => false,
    };

/// Returns the exact leading offset for a chat-list item.
///
/// Chat rows do not include a separator in their layout, so even a fractional
/// per-row adjustment accumulates into a visible error for targets farther
/// down the list.
double chatListItemScrollOffset({
  required int itemIndex,
  required double rowHeight,
  required double maxScrollExtent,
  double leadingExtent = 0,
}) => math.min(leadingExtent + itemIndex * rowHeight, maxScrollExtent);

/// Keeps the pull-down archive slot after the search row when search is shown.
int chatListPullDownArchiveItemIndex({required bool showSearch}) =>
    showSearch ? 1 : 0;

/// Resolves the requested archive display mode for the current platform.
ArchivedChatsDisplayMode effectiveChatListArchiveDisplayMode(
  ArchivedChatsDisplayMode requested, {
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
}) => requested.effectiveForPlatform(platform: platform, isWeb: isWeb);

/// Returns the distance that leading chat-list content must move up to cancel
/// the viewport's native top overscroll in the same frame.
double chatListTopOverscrollOffset(
  double scrollPixels, {
  double minScrollExtent = 0,
}) => math.max(0.0, minScrollExtent - scrollPixels).toDouble();

/// Whether the current pull has crossed the archive reveal threshold.
bool chatListShouldRevealPullDownArchive({
  required double pullOffset,
  required double rowHeight,
}) => pullOffset >= rowHeight * 0.45;

/// Whether forward scrolling has moved far enough to hide the archive row.
bool chatListShouldHidePullDownArchive({
  required double scrollPixels,
  required double minScrollExtent,
  required double rowHeight,
}) => scrollPixels - minScrollExtent > rowHeight * 0.5;

/// Keeps leading pull-down content visually fixed while the surrounding list
/// uses bouncing scroll physics.
class ChatListTopOverscrollPin extends StatelessWidget {
  const ChatListTopOverscrollPin({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
  });

  final ScrollController controller;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        final positions = controller.positions;
        final position = positions.length == 1 ? positions.single : null;
        final pullOffset = position != null && position.hasContentDimensions
            ? chatListTopOverscrollOffset(
                position.pixels,
                minScrollExtent: position.minScrollExtent,
              )
            : 0.0;
        return Transform.translate(
          offset: Offset(0, -pullOffset),
          child: child,
        );
      },
    );
  }
}

/// Animates the pull-down archive row without letting viewport overscroll move
/// the row's painted position.
class ChatListPullDownArchiveSlot extends StatelessWidget {
  const ChatListPullDownArchiveSlot({
    super.key,
    required this.controller,
    required this.rowHeight,
    required this.visible,
    required this.child,
    this.duration = const Duration(milliseconds: 180),
  });

  final ScrollController controller;
  final double rowHeight;
  final bool visible;
  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return ChatListTopOverscrollPin(
      controller: controller,
      child: AnimatedSize(
        duration: duration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: visible
            ? SizedBox(height: rowHeight, child: child)
            : const SizedBox(width: double.infinity),
      ),
    );
  }
}

@visibleForTesting
enum ChatListConnectionStatus { online, connecting, disconnected }

@visibleForTesting
ChatListConnectionStatus chatListConnectionStatusForTdState(String? stateType) {
  return switch (stateType) {
    'connectionStateReady' ||
    'connectionStateUpdating' => ChatListConnectionStatus.online,
    'connectionStateWaitingForNetwork' => ChatListConnectionStatus.disconnected,
    _ => ChatListConnectionStatus.connecting,
  };
}

@visibleForTesting
class ChatListConnectionStatusView extends StatelessWidget {
  const ChatListConnectionStatusView({super.key, required this.status});

  static const indicatorKey = ValueKey('chat-list-connection-indicator');
  static const labelKey = ValueKey('chat-list-connection-label');

  final ChatListConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = switch (status) {
      ChatListConnectionStatus.online => AppStrings.t(
        AppStringKeys.presenceOnline,
      ),
      ChatListConnectionStatus.connecting => AppStrings.t(
        AppStringKeys.presenceConnecting,
      ),
      ChatListConnectionStatus.disconnected => AppStrings.t(
        AppStringKeys.presenceDisconnected,
      ),
    };
    final muted = status == ChatListConnectionStatus.disconnected;

    return Semantics(
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status == ChatListConnectionStatus.connecting)
              SizedBox(
                key: indicatorKey,
                width: AppMetric.onlineDot + 2,
                height: AppMetric.onlineDot + 2,
                child: CircularProgressIndicator(
                  strokeWidth: 1.4,
                  color: c.textSecondary,
                  backgroundColor: c.textTertiary.withValues(alpha: 0.22),
                ),
              )
            else
              Container(
                key: indicatorKey,
                width: AppMetric.onlineDot,
                height: AppMetric.onlineDot,
                decoration: BoxDecoration(
                  color: status == ChatListConnectionStatus.online
                      ? AppTheme.onlineDot
                      : c.textTertiary,
                  shape: BoxShape.circle,
                ),
              ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              key: labelKey,
              style: TextStyle(
                fontSize: AppTextSize.tiny,
                color: muted ? c.textTertiary : c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CommunityListSelection {
  const CommunityListSelection({
    required this.community,
    required this.chats,
    required this.viewableChats,
    required this.onCollapsedChanged,
    this.updates,
    this.chatsProvider,
    this.viewableChatsProvider,
  });

  final CommunitySummary community;
  final List<ChatSummary> chats;
  final List<ChatSummary> viewableChats;
  final ValueChanged<bool> onCollapsedChanged;
  final Listenable? updates;
  final List<ChatSummary> Function()? chatsProvider;
  final List<ChatSummary> Function()? viewableChatsProvider;
}

class ChatListView extends StatefulWidget {
  const ChatListView({
    super.key,
    this.controller,
    this.onChatSelected,
    this.onCommunitySelected,
    this.onOpenArchived,
    this.selectedChatId,
    this.selectedCommunityId,
  });

  final ChatListController? controller;
  final ValueChanged<ChatListSelection>? onChatSelected;
  final ValueChanged<CommunityListSelection>? onCommunitySelected;
  final ValueChanged<ArchivedChatListSelection>? onOpenArchived;
  final int? selectedChatId;
  final int? selectedCommunityId;

  @override
  State<ChatListView> createState() => _ChatListViewState();
}

class _ChatListViewState extends State<ChatListView>
    with SingleTickerProviderStateMixin {
  final ChatListViewModel _model = ChatListViewModel();
  late final ScrollController _scrollController = _newScrollController();

  int? _meId;
  StreamSubscription? _userSub;
  StreamSubscription? _connectionSub;
  StreamSubscription? _activeSlotSub;
  ChatListConnectionStatus _connectionStatus =
      ChatListConnectionStatus.connecting;
  int _connectionRefreshGeneration = 0;
  int? _openSwipeChat;
  bool _showPlusMenu = false;
  bool _showFilterMenu = false;
  int? _pendingScrollToFirstUnreadRequest;
  bool _pendingScrollShouldToggle = false;
  bool _pendingToggleMayHaveUnread = false;
  int _lastHandledScrollToFirstUnreadRequest = 0;
  int _lastHandledToggleFirstUnreadRequest = 0;
  int _lastHandledMarkAllReadRequest = 0;
  int _lastHandledNewChatRequest = 0;
  int _lastHandledFocusSearchRequest = 0;
  int _pendingScrollAttempts = 0;
  bool _toggleUnreadTargetNext = true;
  bool _archiveRevealed = false;
  double _refreshPullDistance = 0;
  bool _isRefreshing = false;
  bool _viewTickerEnabled = true;
  bool _modelDirtyWhileInactive = false;
  bool _reactivationSyncScheduled = false;
  int _lastVisibleRows = 1;
  final ScrollController _folderTabScrollController = ScrollController();
  final Map<int?, GlobalKey> _folderTabKeys = {};
  final Map<int?, GlobalKey> _sideFolderKeys = {};
  int _nextComposerFocusRequestId = 0;

  static const double _refreshPullThreshold = 72;

  ScrollController _newScrollController({double initialScrollOffset = 0}) {
    return ScrollController(initialScrollOffset: initialScrollOffset)
      ..addListener(_onScroll);
  }

  @override
  void initState() {
    super.initState();
    _model.onAppear();
    _model.addListener(_onModel);
    widget.controller?.addListener(_onControllerRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onControllerRequest();
    });
    _loadMe();
    // Keep the header's name/status/photo live — TDLib emits updateUser for us
    // when the status or profile changes.
    _userSub = TdClient.shared.updatesOf('updateUser').listen((u) {
      if (u.obj('user')?.int64('id') == _meId) _loadMe();
    });
    _connectionSub = TdClient.shared
        .updatesOf('updateConnectionState')
        .listen(_applyConnectionUpdate);
    _activeSlotSub = TdClient.shared.subscribeActiveSlotChanges().listen((_) {
      _setConnectionStatus(ChatListConnectionStatus.connecting);
      unawaited(_refreshConnectionStatus());
    });
    unawaited(_refreshConnectionStatus());
  }

  @override
  void didUpdateWidget(covariant ChatListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller?.removeListener(_onControllerRequest);
    widget.controller?.addListener(_onControllerRequest);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final reactivated = !_viewTickerEnabled && tickerEnabled;
    _viewTickerEnabled = tickerEnabled;
    if (!reactivated ||
        !_modelDirtyWhileInactive ||
        _reactivationSyncScheduled) {
      return;
    }
    _reactivationSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reactivationSyncScheduled = false;
      if (!mounted || !_viewTickerEnabled || !_modelDirtyWhileInactive) return;
      _onModel();
    });
  }

  void _onModel() {
    if (!mounted) return;
    if (!_viewTickerEnabled) {
      _modelDirtyWhileInactive = true;
      return;
    }
    _modelDirtyWhileInactive = false;
    if (_model.notice != null && mounted) {
      final text = _model.notice!;
      _model.clearNotice();
      showToast(context, text);
    }
    setState(() {});
    if (_pendingScrollToFirstUnreadRequest != null) {
      _tryScrollToFirstUnread();
    }
  }

  void _onScroll() {
    if (!mounted) return;
    final positions = _scrollController.positions;
    if (positions.length != 1) return;
    final position = positions.single;
    final theme = context.read<ThemeController>();
    final rowHeight = chatListRowExtentFor(context, listen: false) + 0.5;
    final archiveMode = effectiveChatListArchiveDisplayMode(
      theme.archivedChatsDisplayMode,
    );
    final archiveEnabled =
        _model.isAllFilter &&
        _model.archived.isNotEmpty &&
        archiveMode == ArchivedChatsDisplayMode.pullDown;
    if (archiveEnabled && position.hasContentDimensions) {
      final pullOffset = chatListTopOverscrollOffset(
        position.pixels,
        minScrollExtent: position.minScrollExtent,
      );
      if (!_archiveRevealed &&
          chatListShouldRevealPullDownArchive(
            pullOffset: pullOffset,
            rowHeight: rowHeight,
          )) {
        setState(() => _archiveRevealed = true);
      } else if (_archiveRevealed &&
          chatListShouldHidePullDownArchive(
            scrollPixels: position.pixels,
            minScrollExtent: position.minScrollExtent,
            rowHeight: rowHeight,
          )) {
        setState(() => _archiveRevealed = false);
      }
    }
    if (position.extentAfter < rowHeight * 8) {
      _model.loadMore();
    }
  }

  @override
  void dispose() {
    widget.controller?.clearSideFolders(this);
    _userSub?.cancel();
    _connectionSub?.cancel();
    _activeSlotSub?.cancel();
    widget.controller?.removeListener(_onControllerRequest);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _folderTabScrollController.dispose();
    _model.removeListener(_onModel);
    _model.dispose();
    super.dispose();
  }

  Future<void> _loadMe() async {
    try {
      final me = await TdClient.shared.query({'@type': 'getMe'});
      if (mounted) {
        setState(() {
          _meId = me.int64('id');
          _model.meId = _meId;
        });
      }
    } catch (_) {}
  }

  void _applyConnectionUpdate(Map<String, dynamic> update) {
    _setConnectionStatus(
      chatListConnectionStatusForTdState(update.obj('state')?.type),
    );
  }

  void _setConnectionStatus(ChatListConnectionStatus status) {
    if (!mounted || status == _connectionStatus) return;
    setState(() => _connectionStatus = status);
  }

  Future<void> _refreshConnectionStatus() async {
    final generation = ++_connectionRefreshGeneration;
    final slot = TdClient.shared.activeSlot;
    try {
      final state = await TdClient.shared.queryForSlot({
        '@type': 'getConnectionState',
      }, slot);
      if (!mounted ||
          generation != _connectionRefreshGeneration ||
          slot != TdClient.shared.activeSlot) {
        return;
      }
      _setConnectionStatus(chatListConnectionStatusForTdState(state.type));
    } catch (_) {
      if (!mounted ||
          generation != _connectionRefreshGeneration ||
          slot != TdClient.shared.activeSlot) {
        return;
      }
      _setConnectionStatus(ChatListConnectionStatus.disconnected);
    }
  }

  Future<void> _openChat(ChatSummary chat, {bool focusComposer = false}) async {
    final composerFocusRequestId = focusComposer
        ? ++_nextComposerFocusRequestId
        : 0;
    final onChatSelected = widget.onChatSelected;
    if (onChatSelected != null) {
      onChatSelected(
        ChatListSelection.fromChat(
          chat,
          composerFocusRequestId: composerFocusRequestId,
        ),
      );
      return;
    }
    if (chat.isSavedMessages) {
      unawaited(
        pushAppChatRoute(
          context,
          _chatEntryRoute(
            ChatView(
              chatId: chat.id,
              title: AppStrings.t(AppStringKeys.savedMessages),
              seedMessage: chat.lastChatMessage,
              requestComposerFocusOnReady: focusComposer,
            ),
          ),
        ),
      );
      return;
    }
    if (chat.supportsTopics) {
      final mode = await TopicGroupDisplayPreference.load();
      if (!mounted) return;
      final topicsAsChat = context
          .read<ThemeController>()
          .forumTopicsAsGroupChat;
      if (mode.isChat || topicsAsChat) {
        unawaited(
          pushAppChatRoute(
            context,
            _chatEntryRoute(
              ChatView(
                chatId: chat.id,
                title: chat.title,
                seedMessage: chat.lastChatMessage,
                requestComposerFocusOnReady: focusComposer,
              ),
            ),
          ),
        );
        return;
      }
      final railChats = <int, ChatSummary>{};
      for (final summary in [..._model.chats, ..._model.archived]) {
        railChats[summary.id] = summary;
      }
      unawaited(
        pushAppChatRoute(
          context,
          _standardEntryRoute(
            ForumTopicBrowserView(
              chats: railChats.values.toList(),
              initialChat: chat,
            ),
          ),
        ),
      );
      return;
    }
    unawaited(
      pushAppChatRoute(
        context,
        _chatEntryRoute(
          ChatView(
            chatId: chat.id,
            title: chat.title,
            seedMessage: chat.lastChatMessage,
            requestComposerFocusOnReady: focusComposer,
          ),
        ),
      ),
    );
  }

  void _openCommunity(CommunityGroupEntry entry) {
    if (!context.read<ThemeController>().communitiesEnabled) return;
    final selection = CommunityListSelection(
      community: entry.community,
      chats: _model.chatsInCommunity(entry.community.id),
      viewableChats: _model.viewableChatsInCommunity(entry.community.id),
      onCollapsedChanged: (value) =>
          _model.setCommunityCollapsed(entry.community.id, value),
      updates: _model,
      chatsProvider: () => _model.chatsInCommunity(entry.community.id),
      viewableChatsProvider: () =>
          _model.viewableChatsInCommunity(entry.community.id),
    );
    final onCommunitySelected = widget.onCommunitySelected;
    if (onCommunitySelected != null) {
      onCommunitySelected(selection);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CommunityView(
          community: selection.community,
          chats: selection.chats,
          viewableChats: selection.viewableChats,
          updates: selection.updates,
          chatsProvider: selection.chatsProvider,
          viewableChatsProvider: selection.viewableChatsProvider,
          onCollapsedChanged: selection.onCollapsedChanged,
        ),
      ),
    );
  }

  void _showAddMenu() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const QRCodeView()));
  }

  void _createGroup() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const CreateGroupView()));
  }

  Future<void> _createChannel() async {
    final title = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const EditFieldView(
          title: AppStringKeys.chatListCreateChannel,
          initial: '',
          hint: AppStringKeys.chatListChannelName,
        ),
      ),
    );
    if (title == null || title.isEmpty) return;
    try {
      final chat = await TdClient.shared.query({
        '@type': 'createNewSupergroupChat',
        'title': title,
        'is_channel': true,
        'description': '',
      });
      final id = chat.int64('id') ?? chat.int64('chat_id');
      if (!mounted || id == null) return;
      final selection = ChatListSelection(chatId: id, title: title);
      if (widget.onChatSelected != null) {
        widget.onChatSelected!(selection);
        return;
      }
      unawaited(
        pushAppChatRoute(
          context,
          _chatEntryRoute(ChatView(chatId: id, title: title)),
        ),
      );
    } catch (_) {
      if (mounted) {
        showToast(context, AppStringKeys.chatListCreateChannelFailed);
      }
    }
  }

  void _selectPlusMenuItem(String label) {
    setState(() => _showPlusMenu = false);
    switch (label) {
      case AppStringKeys.chatListScanQrCode:
        _openQrScanner();
      case AppStringKeys.chatListCreateGroup:
        _createGroup();
      case AppStringKeys.chatListCreateChannel:
        _createChannel();
      case AppStringKeys.qrCodeMineTitle:
        _showAddMenu();
      case AppStringKeys.communityTitle:
        _openCommunityDirectory();
    }
  }

  void _openPlusMenu() {
    setState(() {
      _showPlusMenu = true;
      _showFilterMenu = false;
    });
  }

  void _openCommunityDirectory() {
    if (!context.read<ThemeController>().communitiesEnabled) return;
    final entries = [
      for (final community in _model.availableCommunities)
        CommunityGroupEntry(
          community: community,
          chats: [
            ..._model.chatsInCommunity(community.id),
            ..._model.viewableChatsInCommunity(community.id),
          ],
        ),
    ];
    if (entries.isEmpty) return;
    if (entries.length == 1) {
      _openCommunity(entries.single);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            _CommunityDirectoryView(entries: entries, onOpen: _openCommunity),
      ),
    );
  }

  Future<void> _openQrScanner() async {
    final value = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScannerView()));
    if (!mounted || value == null || value.trim().isEmpty) return;
    await openLink(context, value);
  }

  Future<void> _editFolderAppearance(ChatFilterOption filter) async {
    final id = filter.folderId;
    if (id == null) return;
    final client = TdClient.shared;
    final clientId = client.activeClientId;
    final service = ChatFolderService(
      query: (request) => client.queryTo(request, clientId),
    );
    try {
      final raw = await service.getFolder(id);
      if (!mounted || client.activeClientId != clientId) return;
      final original = ChatFolderDraft.fromRaw(raw);
      final edited = await Navigator.of(context, rootNavigator: true)
          .push<ChatFolderDraft>(
            AppPageRoute(
              pageBuilder: (_, _, _) => ChatFolderEditorView(
                initial: original,
                folderId: id,
                service: service,
                tagsEnabled: false,
                appearanceOnly: true,
              ),
            ),
          );
      if (edited == null || !mounted || client.activeClientId != clientId) {
        return;
      }
      await service.editAppearance(
        id,
        title: edited.title == original.title ? null : edited.title,
        iconName: edited.iconName == original.iconName ? null : edited.iconName,
      );
    } catch (error) {
      if (mounted) {
        showToast(
          context,
          AppStrings.t(
            AppStringKeys.chatFolderManagementCouldnTUpdateFolderValue1,
            {'value1': error},
          ),
        );
      }
    }
  }

  void _selectFilter(ChatFilterOption filter) {
    if (!mounted) return;
    setState(() => _showFilterMenu = false);
    _switchToFilter(filter);
  }

  void _switchToFilter(ChatFilterOption filter) {
    final currentFolderId = _model.selectedFilter.folderId;
    if (filter.folderId == currentFolderId) return;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() {
      _openSwipeChat = null;
      _archiveRevealed = false;
      _refreshPullDistance = 0;
    });
    _model.selectFilter(filter);
  }

  void _onControllerRequest() {
    final markAllRequest = widget.controller?.markAllReadRequests ?? 0;
    if (markAllRequest > _lastHandledMarkAllReadRequest) {
      _lastHandledMarkAllReadRequest = markAllRequest;
      _model.markAllRead();
    }

    final newChatRequest = widget.controller?.newChatRequests ?? 0;
    if (newChatRequest > _lastHandledNewChatRequest) {
      _lastHandledNewChatRequest = newChatRequest;
      _openPlusMenu();
    }

    final focusSearchRequest = widget.controller?.focusSearchRequests ?? 0;
    if (focusSearchRequest > _lastHandledFocusSearchRequest) {
      _lastHandledFocusSearchRequest = focusSearchRequest;
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const SearchView()));
    }

    final request = widget.controller?.scrollToFirstUnreadRequests ?? 0;
    if (request > _lastHandledScrollToFirstUnreadRequest) {
      _beginScrollRequest(request, toggle: false, mayHaveUnread: true);
    }

    final toggleRequest = widget.controller?.toggleFirstUnreadRequests ?? 0;
    if (toggleRequest > _lastHandledToggleFirstUnreadRequest) {
      _beginScrollRequest(
        toggleRequest,
        toggle: true,
        mayHaveUnread: widget.controller?.toggleRequestMayHaveUnread ?? false,
      );
    }
  }

  void _beginScrollRequest(
    int request, {
    required bool toggle,
    required bool mayHaveUnread,
  }) {
    _pendingScrollToFirstUnreadRequest = request;
    _pendingScrollShouldToggle = toggle;
    _pendingToggleMayHaveUnread = mayHaveUnread;
    _pendingScrollAttempts = 0;
    _model.selectAllFilter();
    _model.loadMore();
    _tryScrollToFirstUnread();
  }

  void _tryScrollToFirstUnread() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingScrollToFirstUnreadRequest == null) return;
      if (!_scrollController.hasClients ||
          !_scrollController.position.hasContentDimensions) {
        _retryScrollToFirstUnread();
        return;
      }
      final firstUnread = _firstUnreadScrollOffset();
      final target = _targetScrollOffsetForRequest(firstUnread);
      if (target == null ||
          (_pendingScrollShouldToggle &&
              _pendingToggleMayHaveUnread &&
              firstUnread == null)) {
        _model.loadMore();
        _retryScrollToFirstUnread();
        return;
      }

      if (_pendingScrollShouldToggle) {
        _lastHandledToggleFirstUnreadRequest =
            _pendingScrollToFirstUnreadRequest!;
        _toggleUnreadTargetNext = firstUnread == null || target == 0;
      } else {
        _lastHandledScrollToFirstUnreadRequest =
            _pendingScrollToFirstUnreadRequest!;
      }
      _pendingScrollToFirstUnreadRequest = null;
      _pendingScrollShouldToggle = false;
      _pendingToggleMayHaveUnread = false;
      _pendingScrollAttempts = 0;
      _animateListTo(target);
    });
  }

  double? _targetScrollOffsetForRequest(double? firstUnread) {
    if (!_pendingScrollShouldToggle) return firstUnread;
    if (firstUnread == null) return 0;
    return _toggleUnreadTargetNext ? firstUnread : 0;
  }

  void _retryScrollToFirstUnread() {
    _pendingScrollAttempts++;
    if (_pendingScrollAttempts > 160) {
      final request = _pendingScrollToFirstUnreadRequest;
      final wasToggle = _pendingScrollShouldToggle;
      _pendingScrollToFirstUnreadRequest = null;
      _pendingScrollShouldToggle = false;
      _pendingToggleMayHaveUnread = false;
      _pendingScrollAttempts = 0;
      if (wasToggle && request != null) {
        _lastHandledToggleFirstUnreadRequest = request;
        _toggleUnreadTargetNext = true;
        _animateListTo(0);
      }
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 35), () {
      if (mounted) _tryScrollToFirstUnread();
    });
  }

  double? _firstUnreadScrollOffset() {
    final entries = _model.chatListEntries(
      communitiesEnabled: context.read<ThemeController>().communitiesEnabled,
    );
    final entryIndex = entries.indexWhere(
      (entry) => entry.showsUnreadIndicator,
    );
    if (entryIndex < 0) return null;

    var itemIndex = entryIndex;
    if (_model.isAllFilter && _model.filtered.isNotEmpty) itemIndex++;
    final archiveMode = effectiveChatListArchiveDisplayMode(
      context.read<ThemeController>().archivedChatsDisplayMode,
    );
    final pullDownArchiveVisible =
        archiveMode == ArchivedChatsDisplayMode.pullDown && _archiveRevealed;
    if (_model.isAllFilter &&
        _model.archived.isNotEmpty &&
        (archiveMode.isInline || pullDownArchiveVisible)) {
      final archiveIndex = pullDownArchiveVisible
          ? 0
          : archiveMode.insertionIndex(
              chatCount: entries.length,
              visibleRows: _lastVisibleRows,
            );
      if (archiveIndex <= entryIndex) itemIndex++;
    }
    return chatListItemScrollOffset(
      itemIndex: itemIndex,
      rowHeight: chatListRowExtentFor(context, listen: false),
      maxScrollExtent: _scrollController.position.maxScrollExtent,
      leadingExtent: _leadingListControlsExtent(
        context.read<ThemeController>(),
      ),
    );
  }

  void _animateListTo(double target) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final clamped = target.clamp(0.0, position.maxScrollExtent).toDouble();
    final distance = (position.pixels - clamped).abs();
    if (distance < 1) return;
    final duration = Duration(
      milliseconds: (220 + distance * 0.22).clamp(260, 520).round(),
    );
    _scrollController.animateTo(
      clamped,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final theme = context.watch<ThemeController>();
    final folderMode = theme.chatFolderDisplayMode;
    final tabCount = 4;
    final sideFolders =
        widget.controller != null &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS &&
            SideNavigationGeometry.of(
                  context,
                )?.fits(tabCount, SideNavigationGeometry.itemExtent) ==
                true);
    final folderRail =
        sideFolders &&
            folderMode == ChatFolderDisplayMode.tabs &&
            _model.filters.length > 1
        ? _chatFolderRail()
        : null;
    final controller = widget.controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(widget.controller, controller)) {
        controller?.publishSideFolders(this, folderRail);
      }
    });
    if (folderMode == ChatFolderDisplayMode.hidden && !_model.isAllFilter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_model.isAllFilter) {
          _model.selectFilter(_model.filters.first);
        }
      });
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          color: c.background,
          child: Column(
            children: [
              _header(),
              if (!sideFolders &&
                  folderMode == ChatFolderDisplayMode.tabs &&
                  _model.filters.length > 1)
                _chatFolderTabs(),
              Expanded(
                child: _chatList(),
              ),
            ],
          ),
        ),
        _plusMenuOverlay(visible: _showPlusMenu),
        _filterMenuOverlay(
          visible: folderMode == ChatFolderDisplayMode.menu && _showFilterMenu,
        ),
      ],
    );
  }

  // MARK: - Header

  Widget _header() {
    final c = context.colors;
    final theme = context.watch<ThemeController>();
    final appLock = context.watch<LocalAppLockController?>();
    final useFilterMenu =
        theme.chatFolderDisplayMode == ChatFolderDisplayMode.menu;
    final activeFilter = _model.selectedFilter;
    return Container(
      color: c.listHeaderTint,
      padding: EdgeInsets.only(
        top:
            MediaQuery.of(context).padding.top +
            iPadWindowChromeInsetOf(context),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxl,
          vertical: AppSpacing.md + AppSpacing.xxs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                AppStringKeys.tabMessages.l10n(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTextSize.title,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
            ),
            if (useFilterMenu && !activeFilter.isAll) ...[
              const SizedBox(width: AppSpacing.md),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 132),
                child: Text(
                  activeFilter.title.l10n(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: AppTextSize.callout,
                    color: c.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
            ],
            if (useFilterMenu && _model.filters.isNotEmpty)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() {
                  _showFilterMenu = true;
                  _showPlusMenu = false;
                }),
                child: SizedBox(
                  width: AppMetric.hitTarget,
                  height: AppMetric.hitTarget,
                  child: AppIcon(
                    HeroAppIcons.folder,
                    size: AppIconSize.toolbar,
                    color: c.textPrimary,
                  ),
                ),
              ),
            if (appLock?.enabled == true) ...[
              const SizedBox(width: AppSpacing.xs),
              Semantics(
                button: true,
                label: AppStringKeys.appLockLockNow.l10n(context),
                child: GestureDetector(
                  key: const ValueKey('chat-list-app-lock'),
                  behavior: HitTestBehavior.opaque,
                  onTap: appLock!.lock,
                  child: SizedBox(
                    width: AppMetric.hitTarget,
                    height: AppMetric.hitTarget,
                    child: AppIcon(
                      HeroAppIcons.lock,
                      size: AppIconSize.toolbar,
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SearchView()),
                );
              },
              child: SizedBox(
                width: AppMetric.hitTarget,
                height: AppMetric.hitTarget,
                child: AppIcon(
                  HeroAppIcons.magnifyingGlass,
                  size: AppIconSize.toolbar,
                  color: c.textPrimary,
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openPlusMenu,
              child: SizedBox(
                width: AppMetric.hitTarget,
                height: AppMetric.hitTarget,
                child: AppIcon(
                  HeroAppIcons.plus,
                  size: AppIconSize.add,
                  color: c.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chatFolderRail() => ChatFolderRail(
    filters: _model.filters,
    selectedFolderId: _model.selectedFilter.folderId,
    highlights: {
      for (final filter in _model.filters)
        filter.folderId:
            filter.folderId == _model.selectedFilter.folderId ? 1.0 : 0.0,
    },
    onSelect: _selectFilter,
    onEdit: _editFolderAppearance,
    keyForFolder: (id) => _sideFolderKeys.putIfAbsent(id, GlobalKey.new),
  );

  Widget _chatFolderTabs() {
    final c = context.colors;
    final selectedFolderId = _model.selectedFilter.folderId;
    // The strip scrolls horizontally, so its height is fixed; grow it with the
    // label that sits above the selection indicator.
    final tabHeight = AppMetric.rowExtentFor(
      context,
      base: 44,
      lines: const [AppTextSize.callout],
    );
    return Container(
      height: tabHeight,
      decoration: BoxDecoration(
        color: c.listHeaderTint,
        border: Border(bottom: BorderSide(color: c.divider, width: 0.5)),
      ),
      child: ListView.separated(
        controller: _folderTabScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: _model.filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 28),
        itemBuilder: (context, index) {
          final filter = _model.filters[index];
          final selected = filter.folderId == selectedFolderId;
          final key = _folderTabKeys.putIfAbsent(
            filter.folderId,
            GlobalKey.new,
          );
          final highlight = selected ? 1.0 : 0.0;
          final accent = Color.lerp(
            c.textSecondary,
            AppTheme.brand,
            highlight,
          );
          return GestureDetector(
            key: key,
            behavior: HitTestBehavior.opaque,
            onTap: () => _selectFilter(filter),
            child: SizedBox(
              height: tabHeight,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ChatFolderIcon(
                        filter.isAll ? 'All' : filter.iconName,
                        size: 17,
                        color: accent ?? c.textSecondary,
                      ),
                      const SizedBox(width: AppSpacing.xs + 1),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 168),
                        child: Text(
                          filter.title.l10n(context),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTextSize.callout,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: c.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.brand.withValues(alpha: highlight),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // MARK: - List

  Widget _chatList() {
    final c = context.colors;
    final theme = context.watch<ThemeController>();
    final archiveMode = effectiveChatListArchiveDisplayMode(
      theme.archivedChatsDisplayMode,
    );
    return Container(
      color: c.background,
      child: LayoutBuilder(
        builder: (context, geo) {
          final rowH = chatListRowExtentFor(context) + 0.5;
          final visibleRows = math.max(1, (geo.maxHeight / rowH).ceil());
          _lastVisibleRows = visibleRows;
          final entries = _model.chatListEntries(
            communitiesEnabled: theme.communitiesEnabled,
          );
          final hasFiltered = _model.isAllFilter && _model.filtered.isNotEmpty;
          final hasArchive = _model.isAllFilter && _model.archived.isNotEmpty;
          final showPulledDownArchive =
              hasArchive &&
              archiveMode == ArchivedChatsDisplayMode.pullDown &&
              _archiveRevealed;
          final hasPullDownArchiveSlot =
              hasArchive && archiveMode == ArchivedChatsDisplayMode.pullDown;
          final archiveIndex = archiveMode.insertionIndex(
            chatCount: entries.length,
            visibleRows: visibleRows,
          );
          final showInlineArchive = hasArchive && archiveMode.isInline;
          final listPhysics = showPulledDownArchive
              ? const ClampingScrollPhysics()
              : const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                );
          Widget list;
          if (entries.isEmpty &&
              _model.isInitialLoading &&
              !showInlineArchive &&
              !hasFiltered) {
            list = ListView.builder(
              controller: _scrollController,
              physics: listPhysics,
              padding: EdgeInsets.only(bottom: BottomBarInset.of(context)),
              itemCount:
                  visibleRows + (hasPullDownArchiveSlot ? 1 : 0),
              itemBuilder: (context, index) {
                if (hasPullDownArchiveSlot && index == 0) {
                  return _pullDownArchiveSlot(
                    rowHeight: rowH,
                    visible: showPulledDownArchive,
                  );
                }
                return const _ChatRowPlaceholder();
              },
            );
          } else if (entries.isEmpty && !showInlineArchive && !hasFiltered) {
            list = ListView(
              controller: _scrollController,
              physics: listPhysics,
              padding: EdgeInsets.only(bottom: BottomBarInset.of(context)),
              children: [
                if (hasPullDownArchiveSlot)
                  _pullDownArchiveSlot(
                    rowHeight: rowH,
                    visible: showPulledDownArchive,
                  ),
                SizedBox(
                  height: math.max(
                    180,
                    geo.maxHeight -
                        BottomBarInset.of(context) -
                        (showPulledDownArchive ? rowH : 0),
                  ),
                  child: _emptyChatList(),
                ),
              ],
            );
          } else {
            list = ListView.builder(
              controller: _scrollController,
              physics: listPhysics,
              padding: EdgeInsets.only(bottom: BottomBarInset.of(context)),
              itemCount:
                  entries.length +
                  (hasPullDownArchiveSlot ? 1 : 0) +
                  (showInlineArchive ? 1 : 0) +
                  (hasFiltered ? 1 : 0),
              itemBuilder: (context, index) {
                if (hasPullDownArchiveSlot && index == 0) {
                  return _pullDownArchiveSlot(
                    rowHeight: rowH,
                    visible: showPulledDownArchive,
                  );
                }
                final contentIndex =
                    hasPullDownArchiveSlot ? index - 1 : index;
                if (hasFiltered && contentIndex == 0) {
                  return _filteredChatsRow();
                }
                final listIndex = hasFiltered
                    ? contentIndex - 1
                    : contentIndex;
                if (showInlineArchive && listIndex == archiveIndex) {
                  return _assistantRow();
                }
                final entryIndex = showInlineArchive && listIndex > archiveIndex
                    ? listIndex - 1
                    : listIndex;
                final entry = entries[entryIndex];
                return switch (entry) {
                  CommunityChatEntry(:final chat) => _swipeRow(chat),
                  CommunityGroupEntry() => _communityRow(entry),
                };
              },
            );
          }

          return NotificationListener<ScrollNotification>(
            onNotification: _handleChatListPull,
            child: list,
          );
        },
      ),
    );
  }

  double _leadingListControlsExtent(ThemeController theme) => 0;

  Widget _pullDownArchiveSlot({
    required double rowHeight,
    required bool visible,
  }) {
    final duration = MediaQuery.maybeOf(context)?.disableAnimations ?? false
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return ChatListPullDownArchiveSlot(
      controller: _scrollController,
      rowHeight: rowHeight,
      visible: visible,
      duration: duration,
      child: _assistantRow(),
    );
  }

  bool _handleChatListPull(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (_isRefreshing) return false;

    if (notification is ScrollStartNotification) {
      _refreshPullDistance = 0;
    } else if (notification is OverscrollNotification &&
        notification.overscroll < 0) {
      _refreshPullDistance += -notification.overscroll;
    } else if (notification is ScrollUpdateNotification &&
        notification.metrics.pixels < 0) {
      _refreshPullDistance = math.max(
        _refreshPullDistance,
        -notification.metrics.pixels,
      );
    } else if (notification is ScrollEndNotification) {
      final pull = _refreshPullDistance;
      _refreshPullDistance = 0;
      if (pull >= _refreshPullThreshold) {
        unawaited(_refreshChats());
      }
    }
    return false;
  }

  Future<void> _refreshChats() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await _model.refresh();
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Widget _communityRow(CommunityGroupEntry entry) {
    return GestureDetector(
      key: ValueKey('community-${entry.community.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _openCommunity(entry),
      child: CommunityChatListRow(
        entry: entry,
        selected: widget.selectedCommunityId == entry.community.id,
        onClearUnread: () {
          for (final chat in entry.chats) {
            _model.markRead(chat);
          }
        },
      ),
    );
  }

  Widget _swipeRow(ChatSummary chat) {
    final selected = widget.selectedChatId == chat.id;
    return ChatSwipeRow(
      key: ValueKey(chat.id),
      rowId: chat.id,
      openRowId: _openSwipeChat,
      onOpenChanged: (id) => setState(() => _openSwipeChat = id),
      onTap: () => _openChat(chat),
      onLongPress: () => _showChatPreview(chat),
      horizontalSwipeEnabled: false,
      child: ChatListSelectionHighlight(
        selected: selected,
        child: ChatRowView(
          chat: chat,
          selected: selected,
          onClearUnread: () => _model.markRead(chat),
        ),
      ),
    );
  }

  void _showChatPreview(ChatSummary chat) {
    if (_openSwipeChat != null) setState(() => _openSwipeChat = null);
    final hasUnread = chat.unreadCount > 0 || chat.isMarkedUnread;
    final accounts = context.read<AccountStore>();
    final activeAccount = accounts.summaries
        .where((account) => account.slot == accounts.activeSlot)
        .firstOrNull;
    final avatarPath = activeAccount?.avatarPath?.trim();
    unawaited(
      showChatListPreview(
        context,
        chat: chat,
        meName: activeAccount?.name,
        mePhoto: avatarPath == null || avatarPath.isEmpty
            ? null
            : TdFileRef(id: 0, localPath: avatarPath),
        actions: [
          if (chatListPreviewSupportsQuickReply(chat))
            ChatListPreviewAction(
              label: AppStringKeys.chatInputBarReply,
              icon: HeroAppIcons.reply,
              onSelected: () => unawaited(_openChat(chat, focusComposer: true)),
            ),
          ChatListPreviewAction(
            label: AppStringKeys.linkHandlerOpenChat,
            icon: HeroAppIcons.message,
            onSelected: () => unawaited(_openChat(chat)),
          ),
          ChatListPreviewAction(
            label: hasUnread
                ? AppStringKeys.channelDirectMessagesMarkRead
                : AppStringKeys.chatListMarkUnread,
            icon: hasUnread ? HeroAppIcons.circleCheck : HeroAppIcons.eyeSlash,
            onSelected: () =>
                hasUnread ? _model.markRead(chat) : _model.markUnread(chat),
          ),
          ChatListPreviewAction(
            label: chat.isPinned
                ? AppStringKeys.chatListUnpin
                : AppStringKeys.chatInfoPin,
            icon: HeroAppIcons.thumbtack,
            onSelected: () => _model.togglePin(chat),
          ),
          ChatListPreviewAction(
            label: chat.isMuted
                ? AppStringKeys.chatUnmute
                : AppStringKeys.callMute,
            icon: chat.isMuted ? HeroAppIcons.bell : HeroAppIcons.bellSlash,
            onSelected: () => _model.toggleMute(chat),
          ),
          ChatListPreviewAction(
            label: _deleteOrLeaveTitle(chat),
            icon: HeroAppIcons.trash,
            destructive: true,
            onSelected: () => unawaited(_confirmDeleteChat(chat)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteChat(ChatSummary chat) async {
    final isGroupOrChannel =
        chat.kind == ChatKind.group || chat.kind == ChatKind.channel;
    final savedMessagesResolution = await _model.resolveIsSavedMessages(chat);
    if (!mounted) return;
    if (savedMessagesResolution == null) {
      showToast(context, AppStringKeys.chatDeleteUnavailable);
      return;
    }
    final isSavedMessages = savedMessagesResolution;
    final capabilities = isSavedMessages
        ? const ChatDeleteCapabilities.selfOnly()
        : await _model.deleteCapabilities(chat);
    if (!mounted) return;
    if (!capabilities.canDelete) {
      showToast(context, AppStringKeys.chatDeleteUnavailable);
      return;
    }
    final scope = await showTwoStepChatDeleteDialog(
      context,
      title: AppStringKeys.chatListDeleteChatQuestion,
      selfOnlyDescription: isGroupOrChannel
          ? AppStrings.t(AppStringKeys.chatLeaveAndDeleteDescription, {
              'value1': chat.title,
            })
          : AppStrings.t(AppStringKeys.chatInfoClearHistoryDescription),
      capabilities: capabilities,
      isGroupOrChannel: isGroupOrChannel,
      isSavedMessages: isSavedMessages,
      chatTitle: chat.title,
      selfConfirmText: _deleteOrLeaveTitle(chat),
    );
    if (!mounted || scope == null) return;
    try {
      if (isSavedMessages) {
        await _model.clearSavedMessages(chat);
      } else {
        await _model.deleteChat(chat, scope: scope);
      }
    } catch (error) {
      if (!mounted) return;
      final message = switch (error) {
        ChatRemovalUnavailable() => AppStringKeys.chatDeleteUnavailable,
        ChatLeaveHistoryCleanupFailed() =>
          AppStringKeys.chatLeaveHistoryCleanupFailed,
        TdError() => error.message,
        _ => error.toString(),
      };
      showToast(
        context,
        message.trim().isEmpty ? AppStringKeys.chatDelete : message,
      );
    }
  }

  String _deleteOrLeaveTitle(ChatSummary chat) {
    if (chat.isSavedMessages) return AppStringKeys.savedMessagesClear;
    if (chat.kind == ChatKind.channel) {
      return AppStringKeys.topicChatLeaveChannel;
    }
    if (chat.kind == ChatKind.group) return AppStringKeys.chatInfoLeaveGroup;
    return AppStringKeys.chatDelete;
  }

  PageRoute<T> _chatEntryRoute<T>(ChatView child) {
    return AppChatPageRoute<T>(builder: (_) => child);
  }

  PageRoute<T> _standardEntryRoute<T>(Widget child) {
    return AppPageRoute<T>(pageBuilder: (_, _, _) => child);
  }

  Widget _assistantRow() {
    return GestureDetector(
      onTap: _openArchivedChats,
      child: ArchivedChatsRow(
        archived: _model.archived,
        onClearUnread: () => _model.markChatsRead(_model.archived),
      ),
    );
  }

  void _openArchivedChats() {
    final onOpenArchived = widget.onOpenArchived;
    if (onOpenArchived != null) {
      onOpenArchived(
        ArchivedChatListSelection(
          chatsProvider: () => _model.archived,
          updates: _model,
          onClearUnread: _model.markRead,
          onUnarchive: _model.unarchive,
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveArchivedChatsView(
          updates: _model,
          chatsProvider: () => _model.archived,
          onClearUnread: _model.markRead,
          onUnarchive: _model.unarchive,
        ),
      ),
    );
  }

  Widget _filteredChatsRow() {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FilteredChatsView(
            chats: _model.filtered,
            onClearUnread: _model.markRead,
          ),
        ),
      ),
      child: FilteredChatsRow(
        chats: _model.filtered,
        onClearUnread: () => _model.markChatsRead(_model.filtered),
      ),
    );
  }

  // MARK: - "+" dropdown

  Widget _plusMenuOverlay({required bool visible}) {
    return _AnimatedAnchoredMenuOverlay(
      visible: visible,
      top: MediaQuery.paddingOf(context).top + 48,
      onDismiss: () => setState(() => _showPlusMenu = false),
      child: PlusMenu(
        onSelect: _selectPlusMenuItem,
        showCommunities:
            context.watch<ThemeController>().communitiesEnabled &&
            _model.availableCommunities.isNotEmpty,
      ),
    );
  }

  Widget _filterMenuOverlay({required bool visible}) {
    return _AnimatedAnchoredMenuOverlay(
      visible: visible,
      top: MediaQuery.paddingOf(context).top + 48,
      onDismiss: () => setState(() => _showFilterMenu = false),
      child: ChatFilterMenu(
        filters: _model.filters,
        selected: _model.selectedFilter,
        onSelect: _selectFilter,
      ),
    );
  }

  Widget _emptyChatList() {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(HeroAppIcons.message, size: 34, color: c.textTertiary),
            const SizedBox(height: 12),
            Text(
              AppStringKeys.chatListNoChats.l10n(context),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                height: 1.35,
                color: c.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps anchored menus mounted through their reverse animation so the
/// barrier, hit testing, and menu surface leave as one coherent motion.
class _AnimatedAnchoredMenuOverlay extends StatefulWidget {
  const _AnimatedAnchoredMenuOverlay({
    required this.visible,
    required this.top,
    required this.onDismiss,
    required this.child,
  });

  final bool visible;
  final double top;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_AnimatedAnchoredMenuOverlay> createState() =>
      _AnimatedAnchoredMenuOverlayState();
}

class _AnimatedAnchoredMenuOverlayState
    extends State<_AnimatedAnchoredMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.responsive,
    reverseDuration: AppMotion.quick,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDuration();
    if (AppMotion.isReduced(context)) {
      _controller.value = widget.visible ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedAnchoredMenuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDuration();
    if (oldWidget.visible == widget.visible) return;
    if (AppMotion.isReduced(context)) {
      _controller.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _syncDuration() {
    _controller.duration = AppMotion.duration(context, AppMotion.responsive);
    _controller.reverseDuration = AppMotion.duration(context, AppMotion.quick);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          if (_controller.isDismissed) return const SizedBox.shrink();
          final progress = AppMotion.emphasized.transform(_controller.value);
          return IgnorePointer(
            ignoring: _controller.value == 0,
            child: ExcludeSemantics(
              excluding: _controller.value == 0,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onDismiss,
                      child: ColoredBox(
                        color: Colors.black.withValues(
                          alpha: 0.12 * _controller.value,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(top: widget.top, right: 10),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {},
                        child: Opacity(
                          opacity: progress,
                          child: Transform.translate(
                            offset: Offset(0, -8 * (1 - progress)),
                            child: Transform.scale(
                              alignment: Alignment.topRight,
                              scale: 0.94 + 0.06 * progress,
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ChatRowPlaceholder extends StatelessWidget {
  const _ChatRowPlaceholder();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rowHeight = chatListRowExtentFor(context);
    return SizedBox(
      height: rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Row(
          children: [
            Container(
              width: AppMetric.avatarSize,
              height: AppMetric.avatarSize,
              decoration: BoxDecoration(
                color: c.searchFill,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    widthFactor: 0.34,
                    child: _PlaceholderBar(height: 16, color: c.searchFill),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FractionallySizedBox(
                    widthFactor: 0.68,
                    child: _PlaceholderBar(height: 13, color: c.searchFill),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            _PlaceholderBar(width: 44, height: 12, color: c.searchFill),
          ],
        ),
      ),
    );
  }
}

class _CommunityDirectoryView extends StatelessWidget {
  const _CommunityDirectoryView({required this.entries, required this.onOpen});

  final List<CommunityGroupEntry> entries;
  final ValueChanged<CommunityGroupEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          NavHeader(
            title: AppStringKeys.communityTitle,
            onBack: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    Navigator.of(context).pop();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      onOpen(entry);
                    });
                  },
                  child: CommunityChatListRow(entry: entry),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaceholderBar extends StatelessWidget {
  const _PlaceholderBar({
    required this.height,
    required this.color,
    this.width,
  });

  final double? width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
  }
}

/// Reference-style "+" dropdown of create actions.
class PlusMenu extends StatelessWidget {
  const PlusMenu({
    super.key,
    required this.onSelect,
    this.showCommunities = false,
  });
  final ValueChanged<String> onSelect;
  final bool showCommunities;

  static const _baseItems = [
    (HeroAppIcons.qrcode, AppStringKeys.chatListScanQrCode),
    (HeroAppIcons.circlePlus, AppStringKeys.chatListCreateGroup),
    (HeroAppIcons.grip, AppStringKeys.chatListCreateChannel),
    (HeroAppIcons.userPlus, AppStringKeys.qrCodeMineTitle),
  ];

  List<(AppIconData, String)> get _items => [
    if (showCommunities)
      (HeroAppIcons.objectGroup, AppStringKeys.communityTitle),
    ..._baseItems,
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final inset = AppMetric.popupMenuInset();
    return Material(
      color: Colors.transparent,
      child: Container(
        width: AppMetric.popupMenuWidth(),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          // The card and the empty content area behind it are the same colour
          // in the light theme, so without an edge the menu did not read as a
          // surface at all.
          border: Border.all(color: c.divider, width: 0.75),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in _items)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(item.$2),
                child: SizedBox(
                  height: AppMetric.popupMenuRowHeight(),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    child: Row(
                      children: [
                        SizedBox(
                          width: AppMetric.popupMenuIconSlot(),
                          child: AppIcon(
                            item.$1,
                            size: AppMetric.popupMenuIconSlot() - 3,
                            color: c.textPrimary,
                          ),
                        ),
                        SizedBox(width: inset * 0.75),
                        Expanded(
                          child: Text(
                            item.$2.l10n(context),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppMetric.popupMenuTextSize(),
                              color: c.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ChatFilterMenu extends StatelessWidget {
  const ChatFilterMenu({
    super.key,
    required this.filters,
    required this.selected,
    required this.onSelect,
  });

  final List<ChatFilterOption> filters;
  final ChatFilterOption selected;
  final ValueChanged<ChatFilterOption> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: AppMetric.popupMenuWidth(),
        constraints: const BoxConstraints(maxHeight: 360),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ListView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: filters.length,
          itemBuilder: (context, index) {
            final filter = filters[index];
            final selectedFilter = filter.folderId == selected.folderId;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(filter),
              child: SizedBox(
                height: AppMetric.popupMenuRowHeight(),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppMetric.popupMenuInset(),
                  ),
                  child: Row(
                    children: [
                      ChatFolderIcon(
                        filter.isAll ? 'All' : filter.iconName,
                        size: AppMetric.popupMenuIconSlot() - 3,
                        color: c.textPrimary,
                      ),
                      SizedBox(width: AppMetric.popupMenuInset() * 0.75),
                      Expanded(
                        child: Text(
                          filter.title.l10n(context),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppMetric.popupMenuTextSize(),
                            color: c.textPrimary,
                          ),
                        ),
                      ),
                      if (selectedFilter)
                        AppIcon(
                          HeroAppIcons.check,
                          size: AppMetric.popupMenuIconSlot() - 4,
                          color: AppTheme.brand,
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Wraps a chat row with tap/long-press semantics.
class ChatSwipeRow extends StatefulWidget {
  const ChatSwipeRow({
    super.key,
    required this.rowId,
    required this.openRowId,
    required this.onOpenChanged,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.requiresLongPressDrag = false,
    this.horizontalSwipeEnabled = false,
    this.pressRippleEnabled = true,
  });

  final int rowId;
  final int? openRowId;
  final ValueChanged<int?> onOpenChanged;
  final VoidCallback onTap;
  final Widget child;
  final VoidCallback? onLongPress;
  final bool requiresLongPressDrag;
  final bool horizontalSwipeEnabled;
  final bool pressRippleEnabled;

  @override
  State<ChatSwipeRow> createState() => _ChatSwipeRowState();
}

class _ChatSwipeRowState extends State<ChatSwipeRow> {
  @override
  Widget build(BuildContext context) {
    final rowGesture = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: widget.child,
    );
    return widget.pressRippleEnabled
        ? AppPressRipple(child: rowGesture)
        : rowGesture;
  }
}
