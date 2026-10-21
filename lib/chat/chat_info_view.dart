import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:handy/l10n/app_localizations.dart';
import 'package:handy/notifications/scope_notification_settings.dart';
import 'package:provider/provider.dart';

import '../app/primary_chat_launcher.dart';
import '../chats/chat_delete_dialog.dart';
import '../chats/chat_delete_policy.dart';
import '../chats/chat_removal_actions.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/icon_grid.dart';
import '../components/photo_avatar.dart';
import '../components/toast.dart';
import '../components/ui_components.dart';
import '../notifications/notification_settings_payload.dart';
import '../profile/qr_code_view.dart';
import '../settings/hidden_sender_store.dart';
import '../settings/hidden_senders_view.dart';
import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../tdlib/td_user_index.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'add_members_view.dart';
import 'chat_members_cache.dart';
import 'chat_members_view.dart';
import 'chat_search_view.dart';
import 'group_management_view.dart';
import 'shared_media_view.dart';
import 'telegram_rich_text.dart';

class ChatMember {
  ChatMember(this.id, this.name, this.photo, {this.role, this.roleTitle});

  final int id;
  final String name;
  final TdFileRef? photo;
  final MemberRole? role;
  final String? roleTitle;
}

@visibleForTesting
class ChatInfoGroupDetailsCard extends StatelessWidget {
  const ChatInfoGroupDetailsCard({
    super.key,
    required this.groupName,
    required this.announcement,
    required this.onOpenAnnouncement,
  });

  final String groupName;
  final String announcement;
  final VoidCallback onOpenAnnouncement;

  @override
  Widget build(BuildContext context) => SettingsCard(
    children: [
      _GroupDetailRow(
        key: const ValueKey('chatInfoGroupNameRow'),
        title: AppStringKeys.groupManagementGroupName,
        value: groupName,
      ),
      const InsetDivider(leadingInset: AppSpacing.xxl),
      _GroupAnnouncementRow(
        announcement: announcement,
        onTap: onOpenAnnouncement,
      ),
    ],
  );
}

class _GroupDetailRow extends StatelessWidget {
  const _GroupDetailRow({
    super.key,
    required this.title,
    required this.value,
  });

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppInteractiveSurface(
      onTap: null,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: AppMetric.settingsRowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xxl,
            AppSpacing.md,
            AppSpacing.xl,
            AppSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title.l10n(context),
                  style: AppTextStyle.body(c.textPrimary),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: AppTextStyle.footnote(c.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupAnnouncementRow extends StatelessWidget {
  const _GroupAnnouncementRow({
    required this.announcement,
    required this.onTap,
  });

  final String announcement;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final empty = announcement.trim().isEmpty;
    return AppInteractiveSurface(
      key: const ValueKey('chatInfoGroupAnnouncementRow'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xxl,
            AppSpacing.lg,
            AppSpacing.xl,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      AppStringKeys.chatInfoGroupAnnouncement.l10n(context),
                      style: AppTextStyle.body(c.textPrimary),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  AppIcon(
                    HeroAppIcons.chevronRight,
                    size: AppIconSize.chevron,
                    color: c.textTertiary,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                empty
                    ? AppStringKeys.chatInfoGroupAnnouncementEmpty.l10n(context)
                    : announcement,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: empty ? c.textTertiary : c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class GroupAnnouncementView extends StatelessWidget {
  const GroupAnnouncementView({
    super.key,
    required this.announcement,
    required this.entities,
  });

  final String announcement;
  final List<MessageTextEntity> entities;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final empty = announcement.trim().isEmpty;
    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: Column(
        children: [
          NavHeader(
            title: AppStringKeys.chatInfoGroupAnnouncement,
            onBack: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: ListView(
              padding: AppInsets.screen,
              children: [
                Container(
                  width: double.infinity,
                  padding: AppInsets.card,
                  decoration: BoxDecoration(
                    color: c.card,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: empty
                      ? Text(
                          AppStringKeys.chatInfoGroupAnnouncementEmpty.l10n(
                            context,
                          ),
                          style: AppTextStyle.body(c.textTertiary),
                        )
                      : TelegramRichText(
                          text: announcement,
                          entities: entities,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.45,
                            color: c.textPrimary,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

typedef ChatInfoSearchChatLauncher =
    Future<void> Function({
      required int chatId,
      required String title,
      required int initialMessageId,
    });

class ChatInfoView extends StatefulWidget {
  const ChatInfoView({
    super.key,
    required this.chatId,
    required this.title,
    this.showBackButton = true,
    @visibleForTesting this.searchChatLauncher,
  });
  final int chatId;
  final String title;
  final bool showBackButton;
  @visibleForTesting
  final ChatInfoSearchChatLauncher? searchChatLauncher;

  @override
  State<ChatInfoView> createState() => _ChatInfoViewState();
}

class _ChatInfoViewState extends State<ChatInfoView> {
  late final ChatInfoViewModel _vm = ChatInfoViewModel(
    chatId: widget.chatId,
    title: widget.title,
  );

  @override
  void initState() {
    super.initState();
    _vm.addListener(() {
      final notice = _vm.takeNotice();
      if (notice != null && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showToast(context, notice);
        });
      }
      if (mounted) setState(() {});
    });
    _vm.load();
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  void _openMembers() {
    if (!_vm.isGroup) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChatMembersView(chatId: widget.chatId, title: _vm.title),
      ),
    );
  }

  Future<void> _openDirectMessages() async {
    final chatId = _vm.directMessagesChatId;
    if (chatId == 0) return;
    await openChatFromCurrentWindow(context, chatId: chatId, title: _vm.title);
  }

  Future<void> _openSearchHistory() async {
    final messageId = await Navigator.of(context).push<int>(
      MaterialPageRoute<int>(
        builder: (_) =>
            ChatSearchView(chatId: widget.chatId, title: widget.title),
      ),
    );
    if (!mounted || messageId == null) return;
    if (!widget.showBackButton) {
      final launcher = widget.searchChatLauncher;
      if (launcher != null) {
        await launcher(
          chatId: widget.chatId,
          title: widget.title,
          initialMessageId: messageId,
        );
      } else {
        await openChatFromCurrentWindow(
          context,
          chatId: widget.chatId,
          title: widget.title,
          initialMessageId: messageId,
        );
      }
      return;
    }
    Navigator.of(context).pop(messageId);
  }

  void _openGroupAnnouncement() {
    Navigator.of(context).push(
      AppPageRoute<void>(
        pageBuilder: (_, _, _) => GroupAnnouncementView(
          announcement: _vm.description,
          entities: _vm.descriptionEntities,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: Column(
        children: [
          NavHeader(
            title: AppStrings.t(AppStringKeys.chatInfoTitle),
            onBack: widget.showBackButton
                ? () => Navigator.of(context).pop()
                : null,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              children: [
                _topCard(),
                if (_vm.isGroup && !_vm.isChannel) ...[
                  const SizedBox(height: 14),
                  ChatInfoGroupDetailsCard(
                    groupName: _vm.title,
                    announcement: _vm.description,
                    onOpenAnnouncement: _openGroupAnnouncement,
                  ),
                ],
                if (_vm.isChannel && _vm.description.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _descriptionCard(),
                ],
                if (_vm.isGroup) ...[
                  const SizedBox(height: 14),
                  _memberGridCard(),
                ],
                const SizedBox(height: 14),
                _rowsCard(),
                const SizedBox(height: 14),
                _togglesCard(),
                const SizedBox(height: 14),
                _destructiveCard(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration get _card => BoxDecoration(
    color: context.colors.card,
    borderRadius: BorderRadius.circular(AppRadius.card),
  );

  void _openQR() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            QRCodeView(name: _vm.title, chatId: widget.chatId, isGroup: true),
      ),
    );
  }

  Widget _topCard() {
    final c = context.colors;
    final circleGroups = context.watch<ThemeController>().circularGroupAvatars;
    return Container(
      decoration: _card,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _vm.isGroup ? _openQR : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
          child: Row(
            children: [
              PhotoAvatar(
                title: _vm.title,
                photo: _vm.photo,
                size: 56,
                square: _vm.isGroup && !circleGroups,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _vm.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 5),
                    _subtitle(),
                  ],
                ),
              ),
              if (_vm.isGroup) ...[
                const SizedBox(width: 8),
                AppIcon(HeroAppIcons.qrcode, size: 22, color: c.textSecondary),
                const SizedBox(width: 6),
                AppIcon(
                  HeroAppIcons.chevronRight,
                  size: 15,
                  color: c.textTertiary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _descriptionCard() {
    final c = context.colors;
    return Container(
      decoration: _card,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: TelegramRichText(
          text: _vm.description,
          entities: _vm.descriptionEntities,
          style: TextStyle(fontSize: 15, height: 1.4, color: c.textPrimary),
        ),
      ),
    );
  }

  Widget _subtitle() {
    final c = context.colors;
    if (!_vm.isGroup) {
      final sub = (_vm.username?.isNotEmpty ?? false) ? '@${_vm.username}' : '';
      return sub.isEmpty
          ? const SizedBox.shrink()
          : Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: c.textSecondary),
            );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppStrings.t(AppStringKeys.chatInfoGroupChat),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 4),
        if (_vm.isPublic && (_vm.username?.isNotEmpty ?? false))
          Text(
            '@${_vm.username}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: AppTheme.brand),
          )
        else
          _lockBadge(AppStrings.t(AppStringKeys.chatInfoNotSearchable)),
      ],
    );
  }

  Widget _lockBadge(String text) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.searchFill,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(HeroAppIcons.lock, size: 10, color: c.textTertiary),
          const SizedBox(width: 3),
          Text(text, style: TextStyle(fontSize: 11, color: c.textTertiary)),
        ],
      ),
    );
  }

  Widget _memberGridCard() {
    final c = context.colors;
    return Container(
      decoration: _card,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openMembers,
            child: Row(
              children: [
                Text(
                  AppStrings.t(AppStringKeys.chatInfoGroupMembers),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                ),
                const Spacer(),
                if (_vm.memberCount > 0)
                  Text(
                    AppStrings.t(AppStringKeys.topicChatMemberCount, {
                      'value1': _vm.memberCount,
                    }),
                    style: TextStyle(fontSize: 14, color: c.textSecondary),
                  ),
                const SizedBox(width: 6),
                AppIcon(
                  HeroAppIcons.chevronRight,
                  size: 14,
                  color: c.textTertiary,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final perRow =
                  (constraints.maxWidth / 70).floor().clamp(5, 12).toInt();
              final actionTiles =
                  (_vm.canInvite ? 1 : 0) + (_vm.canRemove ? 1 : 0);
              final maxTiles = perRow * 3;
              final memberSlots = (maxTiles - actionTiles).clamp(0, maxTiles);
              final shown = _vm.members.take(memberSlots).toList();
              return IconGrid(
                perRow: perRow,
                children: [
                  for (final m in shown)
                    GestureDetector(
                      onTap: _openMembers,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PhotoAvatar(title: m.name, photo: m.photo, size: 48),
                          const SizedBox(height: 6),
                          Text(
                            m.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: c.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_vm.canInvite)
                    _actionTile(
                      HeroAppIcons.plus.data,
                      AppStrings.t(AppStringKeys.topicChatInvite),
                      () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AddMembersView(chatId: widget.chatId),
                        ),
                      ),
                    ),
                  if (_vm.canRemove)
                    _actionTile(
                      HeroAppIcons.minus.data,
                      AppStrings.t(AppStringKeys.chatInfoRemove),
                      _openMembers,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _actionTile(IconData icon, String label, VoidCallback onTap) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.searchFill,
            ),
            child: Icon(icon, size: 22, color: c.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: c.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _rowsCard() {
    return Container(
      decoration: _card,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _infoRow(
            AppStrings.t(AppStringKeys.chatInfoSearchHistory),
            () => unawaited(_openSearchHistory()),
          ),
          if (_vm.isGroup && !_vm.isChannel)
            ListenableBuilder(
              listenable: HiddenSenderStore.shared,
              builder: (context, _) {
                final hidden = HiddenSenderStore.shared
                    .entriesFor(widget.chatId)
                    .length;
                if (hidden == 0) return const SizedBox.shrink();
                return Column(
                  children: [
                    const InsetDivider(leadingInset: 14),
                    _infoRow(
                      '${AppStrings.t(AppStringKeys.hiddenSendersTitle)} ($hidden)',
                      () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              HiddenSendersView(chatId: widget.chatId),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          if (_vm.canOpenDirectMessages) ...[
            const InsetDivider(leadingInset: 14),
            _infoRow(
              AppStrings.t(AppStringKeys.channelDirectMessages),
              _openDirectMessages,
            ),
          ],
          if (!_vm.isGroup) ...[
            const InsetDivider(leadingInset: 14),
            _infoRow(
              AppStrings.t(AppStringKeys.topicPostContentFile),
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SharedMediaView(
                    chatId: widget.chatId,
                    title: widget.title,
                    initialTab: 1,
                    displayTitle: AppStringKeys.topicPostContentFile,
                    lockedTab: true,
                  ),
                ),
              ),
            ),
            const InsetDivider(leadingInset: 14),
            _infoRow(
              AppStrings.t(AppStringKeys.chatInfoGroupVideos),
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SharedMediaView(
                    chatId: widget.chatId,
                    title: widget.title,
                    initialTab: 4,
                    displayTitle: AppStringKeys.chatInfoGroupVideos,
                    lockedTab: true,
                  ),
                ),
              ),
            ),
          ],
          if (_vm.isGroup && _vm.canManageGroup) ...[
            const InsetDivider(leadingInset: 14),
            _infoRow(
              AppStrings.t(
                _vm.isChannel
                    ? AppStringKeys.chatInfoManageChannel
                    : AppStringKeys.chatInfoManageGroup,
              ),
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupManagementView(
                    chatId: widget.chatId,
                    title: _vm.title,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(String title, VoidCallback onTap) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Text(title, style: TextStyle(fontSize: 15, color: c.textPrimary)),
              const Spacer(),
              AppIcon(
                HeroAppIcons.chevronRight,
                size: 14,
                color: c.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _togglesCard() {
    return SettingsCard(
      children: [
        SettingsSwitchRow(
          title: AppStrings.t(AppStringKeys.chatInfoPinChat),
          value: _vm.isPinned,
          onChanged: _vm.setPinned,
          height: 52,
          leadingInset: 14,
        ),
        const InsetDivider(leadingInset: 14),
        SettingsSwitchRow(
          title: AppStrings.t(AppStringKeys.topicChatMuteMessagesToggle),
          value: _vm.isMuted,
          onChanged: _vm.setMuted,
          height: 52,
          leadingInset: 14,
        ),
        const InsetDivider(leadingInset: 14),
        SettingsSwitchRow(
          title: AppStrings.t(AppStringKeys.chatInfoMoveToGroupAssistant),
          value: _vm.isArchived,
          onChanged: _vm.setArchived,
          height: 52,
          leadingInset: 14,
        ),
        const InsetDivider(leadingInset: 14),
        SettingsRow(
          title: AppStrings.t(AppStringKeys.chatInfoAutoDeleteMessages),
          value: TDParse.formatDuration(_vm.autoDeleteTime),
          onTap: _vm.canChangeAutoDelete ? _chooseAutoDelete : null,
          showChevron: _vm.canChangeAutoDelete,
          height: 52,
          leadingInset: 14,
        ),
      ],
    );
  }

  Future<void> _chooseAutoDelete() async {
    if (!_vm.canChangeAutoDelete) return;
    final options = <(String, int)>[
      (AppStrings.t(AppStringKeys.chatInfoAutoDeleteOff), 0),
      (AppStrings.t(AppStringKeys.chatInfoAutoDeleteOneDay), 86400),
      (AppStrings.t(AppStringKeys.chatInfoAutoDeleteSevenDays), 604800),
      (AppStrings.t(AppStringKeys.chatInfoAutoDeleteOneMonth), 2592000),
    ];
    final selected = await showAppCupertinoModalPopup<int>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(AppStrings.t(AppStringKeys.chatInfoAutoDeleteMessages)),
        actions: [
          for (final option in options)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(option.$2),
              child: Text(option.$1),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.t(AppStringKeys.countryPickerCancel)),
        ),
      ),
    );
    if (selected == null) return;
    _vm.setAutoDeleteTime(selected);
  }

  Widget _destructiveCard() {
    final canLeave = _vm.isGroup && _vm.isMember;
    if (!_vm.canClearHistory && !canLeave) return const SizedBox.shrink();
    return Container(
      decoration: _card,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (_vm.canClearHistory)
            _destructiveRow(
              AppStrings.t(AppStringKeys.chatInfoClearHistory),
              _clearHistory,
            ),
          if (canLeave) ...[
            if (_vm.canClearHistory) const InsetDivider(leadingInset: 0),
            _destructiveRow(
              AppStrings.t(
                _vm.isChannel
                    ? AppStringKeys.topicChatLeaveChannel
                    : AppStringKeys.chatInfoLeaveGroup,
              ),
              _leaveChat,
            ),
          ],
        ],
      ),
    );
  }

  Widget _destructiveRow(String title, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Center(
          child: Text(
            title,
            style: TextStyle(fontSize: 15, color: AppTheme.tagRed),
          ),
        ),
      ),
    );
  }

  Future<void> _clearHistory() async {
    final confirmed = await showTwoStepClearHistoryDialog(
      context,
      chatTitle: widget.title,
    );
    if (!mounted || !confirmed) return;
    try {
      await _vm.clearHistory();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) showToast(context, _vm.actionErrorNotice(error));
    }
  }

  Future<void> _leaveChat() async {
    final action = _vm.isChannel
        ? AppStringKeys.topicChatLeaveChannel
        : AppStringKeys.chatInfoLeaveGroup;
    final impact = AppStrings.t(AppStringKeys.chatLeaveAndDeleteDescription, {
      'value1': widget.title,
    });
    final confirmed = await showTwoStepDestructiveConfirmation(
      context,
      firstTitle: action,
      firstMessage: impact,
      firstConfirmText: AppStringKeys.confirmContinue,
      finalTitle: AppStrings.t(AppStringKeys.chatDeleteFinalQuestion, {
        'value1': widget.title,
      }),
      finalMessage:
          '$impact\n\n${AppStringKeys.chatDeleteFinalWarning.l10n(context)}',
      finalConfirmText: action,
    );
    if (!mounted || !confirmed) return;
    try {
      await _vm.leaveChat();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) showToast(context, _vm.actionErrorNotice(error));
    }
  }
}
class ChatInfoViewModel extends ChangeNotifier {
  ChatInfoViewModel({required this.chatId, required this.title});

  final int chatId;
  String title;
  TdFileRef? photo;
  bool isGroup = false;
  bool isChannel = false;
  int memberCount = 0;
  String? username;
  bool isPublic = false;
  bool isPinned = false;
  bool isMuted = false;
  bool isArchived = false;
  int autoDeleteTime = 0;
  List<ChatMember> members = [];
  bool _paintedFromCache = false;
  bool canInvite = false;
  bool canRemove = false;
  bool canManageGroup = false;
  bool canManageDirectMessages = false;
  bool isDirectMessagesGroup = false;
  bool isAdministeredDirectMessagesGroup = false;
  int directMessagesChatId = 0;
  bool get canOpenDirectMessages =>
      directMessagesChatId != 0 && !isDirectMessagesGroup;
  bool get opensDirectMessagesAsTopics =>
      isAdministeredDirectMessagesGroup || canManageDirectMessages;
  bool canChangeAutoDelete = false;
  bool isMember = false;
  bool canClearHistory = false;
  bool _loaded = false;
  String? _notice;
  String description = '';
  List<MessageTextEntity> descriptionEntities = const [];

  String? takeNotice() {
    final value = _notice;
    _notice = null;
    return value;
  }

  void _setDescription(String text) {
    description = text;
    if (text.isEmpty) {
      descriptionEntities = const [];
      return;
    }
    final entities = <MessageTextEntity>[];
    final urlPattern = RegExp(r'https?://[^\s]+');
    final emailPattern = RegExp(
      r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}',
    );
    final mentionPattern = RegExp(r'@[a-zA-Z0-9_]{5,}');

    void addMatches(
      RegExp pattern,
      String entityType, {
      String? url,
      int? userId,
    }) {
      for (final match in pattern.allMatches(text)) {
        if (entities.any((e) => match.start < e.end && match.end > e.offset)) {
          continue;
        }
        entities.add(
          MessageTextEntity(
            offset: match.start,
            length: match.end - match.start,
            type: entityType,
            url: url,
            userId: userId,
          ),
        );
      }
    }

    addMatches(urlPattern, 'textEntityTypeUrl');
    addMatches(emailPattern, 'textEntityTypeEmailAddress');
    addMatches(mentionPattern, 'textEntityTypeMention');

    entities.sort((a, b) => a.offset.compareTo(b.offset));
    descriptionEntities = entities;
  }

  void load() {
    if (_loaded) return;
    _loaded = true;
    _seedMembersFromCache();
    _loadAsync();
  }

  void _seedMembersFromCache() {
    final cached = ChatMembersCache.shared.read(
      accountSlot: TdClient.shared.activeSlot,
      chatId: chatId,
    );
    if (cached == null) return;
    members = cached.members;
    memberCount = cached.memberCount;
    _paintedFromCache = true;
  }

  Future<void> _loadAsync() async {
    Map<String, dynamic> chat;
    try {
      chat = await TdClient.shared.query({
        '@type': 'getChat',
        'chat_id': chatId,
      });
    } catch (_) {
      _loaded = false;
      return;
    }
    final t = chat.str('title');
    if (t != null && t.isNotEmpty) title = t;
    photo = TDParse.smallPhoto(chat.obj('photo'));
    final kind = TDParse.chatKind(chat);
    isChannel = kind == ChatKind.channel;
    isGroup = kind == ChatKind.group || kind == ChatKind.channel;
    canClearHistory = chatDeleteCapabilities(chat).canDeleteForSelf;
    canChangeAutoDelete = !isGroup;
    isMuted = ScopeNotificationSettings.shared.isMuted(chat);
    autoDeleteTime =
        chat.obj('message_auto_delete_time')?.integer('time') ??
        chat.integer('message_auto_delete_time') ??
        chat.integer('auto_delete_time') ??
        0;
    for (final pos
        in chat.objects('positions') ?? const <Map<String, dynamic>>[]) {
      switch (pos.obj('list')?.type) {
        case 'chatListMain':
          isPinned = pos.boolean('is_pinned') ?? false;
        case 'chatListArchive':
          isArchived = (pos.int64('order') ?? 0) > 0;
      }
    }
    notifyListeners();
    if (isGroup) {
      await _loadGroupMeta(chat);
      await _loadSelfPermissions(chat);
    }
    await _loadMembers(chat);
  }

  Future<void> _loadGroupMeta(Map<String, dynamic> chat) async {
    final type = chat.obj('type');
    try {
      if (type?.type == 'chatTypeSupergroup') {
        final sgid = type?.int64('supergroup_id');
        final sg = await TdClient.shared.query({
          '@type': 'getSupergroup',
          'supergroup_id': sgid,
        });
        final uname = sg.obj('usernames')?.str('editable_username') ?? '';
        username = uname.isEmpty ? null : uname;
        isPublic = uname.isNotEmpty;
        isDirectMessagesGroup = sg.boolean('is_direct_messages_group') ?? false;
        isAdministeredDirectMessagesGroup =
            sg.boolean('is_administered_direct_messages_group') ?? false;
        if (isAdministeredDirectMessagesGroup) {
          directMessagesChatId = chatId;
          canManageDirectMessages = true;
        }
        _applySelfStatus(sg.obj('status'), defaultInvite: false);
        try {
          final info = await TdClient.shared.query({
            '@type': 'getSupergroupFullInfo',
            'supergroup_id': sgid,
          });
          final desc = info.str('description') ?? '';
          _setDescription(desc);
          memberCount = info.integer('member_count') ?? memberCount;
          final linkedDirectMessagesChatId =
              info.int64('direct_messages_chat_id') ?? 0;
          if (linkedDirectMessagesChatId != 0 &&
              !isAdministeredDirectMessagesGroup) {
            directMessagesChatId = linkedDirectMessagesChatId;
          }
        } catch (_) {}
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _loadSelfPermissions(Map<String, dynamic> chat) async {
    final defaultInvite =
        chat.obj('permissions')?.boolean('can_invite_users') ?? false;
    try {
      final me = await TdClient.shared.query({'@type': 'getMe'});
      final uid = me.int64('id');
      final member = await TdClient.shared.query({
        '@type': 'getChatMember',
        'chat_id': chatId,
        'member_id': {'@type': 'messageSenderUser', 'user_id': uid},
      });
      _applySelfStatus(member.obj('status'), defaultInvite: defaultInvite);
    } catch (_) {
      canInvite = defaultInvite;
      canRemove = false;
      canManageGroup = false;
      canChangeAutoDelete = !isGroup;
      isMember = isMember && isChannel;
    }
    notifyListeners();
  }

  void _applySelfStatus(
    Map<String, dynamic>? status, {
    required bool defaultInvite,
  }) {
    switch (status?.type) {
      case 'chatMemberStatusCreator':
        isMember = true;
        canInvite = true;
        canRemove = true;
        canManageGroup = true;
        canManageDirectMessages = true;
        canChangeAutoDelete = true;
      case 'chatMemberStatusAdministrator':
        final rights = status?.obj('rights');
        isMember = true;
        canInvite = rights?.boolean('can_invite_users') ?? false;
        canRemove = rights?.boolean('can_restrict_members') ?? false;
        canManageGroup = true;
        canManageDirectMessages =
            rights?.boolean('can_manage_direct_messages') ?? false;
        canChangeAutoDelete = rights?.boolean('can_change_info') ?? false;
      case 'chatMemberStatusMember':
        isMember = true;
        canInvite = defaultInvite;
        canRemove = false;
        canManageGroup = false;
        canManageDirectMessages = false;
        canChangeAutoDelete = false;
      case 'chatMemberStatusRestricted':
        isMember = status?.boolean('is_member') ?? false;
        canInvite = defaultInvite;
        canRemove = false;
        canManageGroup = false;
        canManageDirectMessages = false;
        canChangeAutoDelete = false;
      case 'chatMemberStatusLeft':
      case 'chatMemberStatusBanned':
        isMember = false;
        canInvite = false;
        canRemove = false;
        canManageGroup = false;
        canManageDirectMessages = false;
        canChangeAutoDelete = false;
      default:
        isMember = false;
        canInvite = defaultInvite;
        canRemove = false;
        canManageGroup = false;
        canManageDirectMessages = false;
        canChangeAutoDelete = !isGroup;
    }
  }

  Future<void> _loadMembers(Map<String, dynamic> chat) async {
    final type = chat.obj('type');
    try {
      if (type?.type == 'chatTypeBasicGroup') {
        final gid = type?.int64('basic_group_id');
        if (gid == null) return;
        final full = await TdClient.shared.query({
          '@type': 'getBasicGroupFullInfo',
          'basic_group_id': gid,
        });
        final raw = full.objects('members') ?? const <Map<String, dynamic>>[];
        memberCount = raw.length;
        await _resolveMembers(raw);
        final desc = full.str('description') ?? '';
        _setDescription(desc);
      } else if (type?.type == 'chatTypeSupergroup') {
        final sgid = type?.int64('supergroup_id');
        if (sgid == null) return;
        final result = await TdClient.shared.query({
          '@type': 'getSupergroupMembers',
          'supergroup_id': sgid,
          'filter': {'@type': 'supergroupMembersFilterRecent'},
          'offset': 0,
          'limit': 30,
        });
        final raw = result.objects('members') ?? const <Map<String, dynamic>>[];
        if (memberCount == 0) {
          memberCount =
              result.integer('member_count') ??
              result.integer('total_count') ??
              raw.length;
        }
        await _resolveMembers(raw);
      }
    } catch (_) {}
  }

  Future<void> _resolveMembers(List<Map<String, dynamic>> raw) async {
    final result = <ChatMember>[];
    for (final entry in raw.take(20)) {
      final memberId = entry.obj('member_id');
      if (memberId?.type != 'messageSenderUser') continue;
      final uid = memberId?.int64('user_id');
      if (uid == null) continue;
      try {
        final user =
            TdUserIndex.shared.userFor(TdClient.shared.activeSlot, uid) ??
            await TdClient.shared.query({'@type': 'getUser', 'user_id': uid});
        final status = entry.obj('status');
        final roleTitle = _memberTitle(entry, status);
        var role = switch (status?.type) {
          'chatMemberStatusCreator' => MemberRole.owner,
          'chatMemberStatusAdministrator' => MemberRole.admin,
          _ => null,
        };
        if (role == null && roleTitle != null) role = MemberRole.member;
        result.add(
          ChatMember(
            uid,
            TDParse.userName(user),
            TDParse.smallPhoto(user.obj('profile_photo')),
            role: role,
            roleTitle: roleTitle,
          ),
        );
        if (!_paintedFromCache) {
          members = List.of(result);
          notifyListeners();
        }
      } catch (_) {}
    }
    if (result.isNotEmpty) {
      if (_paintedFromCache) {
        members = List.of(result);
        notifyListeners();
      }
      ChatMembersCache.shared.store(
        accountSlot: TdClient.shared.activeSlot,
        chatId: chatId,
        members: result,
        memberCount: memberCount,
      );
    }
  }

  String? _memberTitle(
    Map<String, dynamic> member,
    Map<String, dynamic>? status,
  ) {
    final raw =
        status?.str('custom_title') ??
        member.str('custom_title') ??
        member.str('tag') ??
        status?.str('title') ??
        member.str('title');
    final title = raw?.trim();
    return title == null || title.isEmpty ? null : title;
  }

  void setPinned(bool value) {
    isPinned = value;
    notifyListeners();
    unawaited(_setPinned(value));
  }

  Future<void> _setPinned(bool value) async {
    try {
      await TdClient.shared.query({
        '@type': 'toggleChatIsPinned',
        'chat_list': {'@type': 'chatListMain'},
        'chat_id': chatId,
        'is_pinned': value,
      });
    } catch (e) {
      isPinned = !value;
      _notice = _pinErrorNotice(e);
      notifyListeners();
    }
  }

  void setMuted(bool value) {
    isMuted = value;
    notifyListeners();
    TdClient.shared.send({
      '@type': 'setChatNotificationSettings',
      'chat_id': chatId,
      'notification_settings': inheritedChatNotificationSettings(
        muteFor: value ? 2147483647 : 0,
      ),
    });
  }

  void setArchived(bool value) {
    isArchived = value;
    notifyListeners();
    TdClient.shared
        .query({
          '@type': 'addChatToList',
          'chat_id': chatId,
          'chat_list': {'@type': value ? 'chatListArchive' : 'chatListMain'},
        })
        .catchError((_) {
          isArchived = !value;
          notifyListeners();
          return <String, dynamic>{};
        });
  }

  void setAutoDeleteTime(int seconds) {
    if (!canChangeAutoDelete) return;
    autoDeleteTime = seconds;
    notifyListeners();
    TdClient.shared.send({
      '@type': 'setChatMessageAutoDeleteTime',
      'chat_id': chatId,
      'message_auto_delete_time': {
        '@type': 'messageAutoDeleteTime',
        'time': seconds,
      },
    });
  }

  Future<void> clearHistory() async {
    try {
      await clearChatHistoryForSelf(
        chatId: chatId,
        query: TdClient.shared.query,
      );
    } on ChatRemovalUnavailable {
      canClearHistory = false;
      notifyListeners();
      rethrow;
    }
    TdClient.shared.emitLocalUpdate({
      '@type': 'mithkaChatHistoryCleared',
      'chat_id': chatId,
    });
  }

  Future<void> leaveChat() async {
    await leaveChatAndRemoveFromList(
      chatId: chatId,
      query: TdClient.shared.query,
      onLeft: () {
        isMember = false;
        canClearHistory = false;
        notifyListeners();
        TdClient.shared.emitLocalUpdate(chatLeftLocalUpdate(chatId));
      },
    );
  }

  String actionErrorNotice(Object error) {
    if (error is ChatRemovalUnavailable) {
      return AppStrings.t(AppStringKeys.chatDeleteUnavailable);
    }
    if (error is ChatLeaveHistoryCleanupFailed) {
      return AppStrings.t(AppStringKeys.chatLeaveHistoryCleanupFailed);
    }
    final message = error is TdError ? error.message : error.toString();
    final text = message.trim();
    return text.isEmpty
        ? AppStrings.t(AppStringKeys.topicPostContentActionFailed)
        : '${AppStrings.t(AppStringKeys.topicPostContentActionFailed)}: $text';
  }

  String _pinErrorNotice(Object error) {
    final message = error is TdError ? error.message : error.toString();
    final text = message.trim();
    final normalized = text.toLowerCase().replaceAll('_', ' ');
    final hitPinned =
        normalized.contains('pin') ||
        normalized.contains('pinned') ||
        normalized.contains(AppStrings.t(AppStringKeys.chatInfoPin));
    final hitLimit =
        normalized.contains('limit') ||
        normalized.contains('too many') ||
        normalized.contains('too much') ||
        normalized.contains('many') ||
        normalized.contains('much') ||
        normalized.contains(AppStrings.t(AppStringKeys.chatInfoPinLimit));
    if (hitPinned && hitLimit) {
      return AppStrings.t(AppStringKeys.chatInfoPinLimitReachedError);
    }
    return text.isEmpty
        ? AppStrings.t(AppStringKeys.chatInfoPinFailed)
        : AppStrings.t(AppStringKeys.chatInfoPinFailedWithReason, {
            'value1': text,
          });
  }
}
