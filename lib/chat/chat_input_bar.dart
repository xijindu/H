import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:geolocator/geolocator.dart';
import 'package:handy/l10n/app_localizations.dart';
import 'package:latlong2/latlong.dart';
import 'package:logger/logger.dart' show Level;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../components/app_dialog.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/confirm_dialog.dart';
import '../components/icon_grid.dart';
import '../components/photo_avatar.dart';
import '../components/toast.dart';
import '../components/ui_components.dart';
import '../media/app_asset_picker.dart';
import '../media/camera_capture.dart';
import '../platform/clipboard_images.dart';
import '../settings/business_service.dart';

import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import '../tdlib/td_models.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'audio_search_view.dart';
import 'bot_button_presentation.dart';
import 'bot_platform_service.dart';
import 'channel_direct_messages_service.dart';
import 'channel_direct_messages_view.dart';
import 'chat_view_model.dart';
import 'checklist_composer_view.dart';
import 'contact_share_picker_view.dart';
import 'custom_emoji.dart';
import 'emoji_catalog.dart';
import 'emoji_store.dart';
import 'emoji_text_controller.dart';
import 'gif_item.dart';
import 'gif_preview.dart';
import 'gif_store.dart';
import 'image_edit_view.dart';
import 'link_handler.dart';
import 'location_picker_view.dart';
import 'media_library_saver.dart';
import 'media_send_preview_view.dart';
import 'message_send_options.dart';
import 'outgoing_attachment.dart';
import 'poll_composer_view.dart';
import 'scheduled_messages_view.dart';
import 'sticker_item.dart';
import 'sticker_preview.dart';
import 'sticker_set_studio_view.dart';
import 'sticker_store.dart';
import 'telegram_ai_editor_view.dart';
import 'telegram_ai_service.dart';
import 'telegram_mini_app_view.dart';
import 'voice_audio.dart';
import 'voice_recording_clock.dart';

enum _Panel { none, function, emoji, sticker, voice }

class _ReplyKeyboard {
  const _ReplyKeyboard({required this.message, required this.rows});

  final ChatMessage message;
  final List<List<MessageButton>> rows;
}

class MentionQuery {
  const MentionQuery({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;
}

class BotCommandQuery {
  const BotCommandQuery({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;
}

MentionQuery? activeMentionQuery(String text, TextSelection selection) {
  if (!selection.isValid || !selection.isCollapsed) return null;
  final cursor = selection.extentOffset;
  if (cursor < 0 || cursor > text.length) return null;
  if (cursor < text.length && text[cursor].trim().isNotEmpty) return null;
  final beforeCursor = text.substring(0, cursor);
  final match = RegExp(
    r'(^|\s)@([\p{L}\p{M}\p{N}_]*)$',
    unicode: true,
  ).firstMatch(beforeCursor);
  if (match == null) return null;
  final leading = match.group(1)?.length ?? 0;
  return MentionQuery(
    start: match.start + leading,
    end: cursor,
    query: match.group(2) ?? '',
  );
}

BotCommandQuery? activeBotCommandQuery(String text, TextSelection selection) {
  if (!selection.isValid ||
      !selection.isCollapsed ||
      selection.extentOffset != text.length) {
    return null;
  }
  final match = RegExp(r'^/([A-Za-z0-9_]*)$').firstMatch(text);
  if (match == null) return null;
  return BotCommandQuery(
    start: 0,
    end: text.length,
    query: match.group(1) ?? '',
  );
}

List<BotCommandOption> matchingBotCommands(
  Iterable<BotCommandOption> commands,
  String query,
) {
  final normalizedQuery = query.toLowerCase();
  return commands
      .where(
        (command) =>
            command.normalizedCommand.toLowerCase().startsWith(normalizedQuery),
      )
      .toList(growable: false);
}

bool isTelegramAiDraftEligible(String text) =>
    text.trim().isNotEmpty && text.split('\n').length >= 2;

typedef _ClipboardImage = ({Uint8List data, String mimeType});

typedef _RecTick = ({double elapsed, List<double> levels});

typedef MediaSendPreviewLauncher =
    Future<MediaSendPreviewResult?> Function(
      List<OutgoingAttachment> attachments,
    );

class _SendComposerIntent extends Intent {
  const _SendComposerIntent();
}

class _InsertComposerLineBreakIntent extends Intent {
  const _InsertComposerLineBreakIntent();
}

class _SendComposerAction extends Action<_SendComposerIntent> {
  _SendComposerAction({required this.canInvoke, required this.onInvoke});

  final bool Function() canInvoke;
  final VoidCallback onInvoke;

  @override
  bool isEnabled(_SendComposerIntent intent) => canInvoke();

  @override
  Object? invoke(_SendComposerIntent intent) {
    onInvoke();
    return null;
  }
}

@visibleForTesting
bool isComposerImeEnterFallback(
  TextEditingValue oldValue,
  TextEditingValue newValue, {
  required bool shiftPressed,
  required bool controlPressed,
  bool altPressed = false,
  bool metaPressed = false,
}) {
  if (shiftPressed || controlPressed || altPressed || metaPressed) return false;
  if (!oldValue.selection.isValid || !oldValue.selection.isCollapsed) {
    return false;
  }
  if (oldValue.selection.extentOffset != oldValue.text.length) return false;
  if (oldValue.composing.isValid && !oldValue.composing.isCollapsed) {
    return false;
  }
  if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
    return false;
  }
  if (newValue.text != '${oldValue.text}\n') return false;
  return newValue.selection.isValid &&
      newValue.selection.isCollapsed &&
      newValue.selection.extentOffset == newValue.text.length;
}

class _ComposerEnterToSendFormatter extends TextInputFormatter {
  const _ComposerEnterToSendFormatter({required this.onSend});

  final VoidCallback onSend;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final keyboard = HardwareKeyboard.instance;
    if (!isComposerImeEnterFallback(
      oldValue,
      newValue,
      shiftPressed: keyboard.isShiftPressed,
      controlPressed: keyboard.isControlPressed,
      altPressed: keyboard.isAltPressed,
      metaPressed: keyboard.isMetaPressed,
    )) {
      return newValue;
    }
    onSend();
    return oldValue;
  }
}

typedef _ComposerVmState = ({
  int autoDeleteTime,
  Object? selectedSender,
  bool canChooseSender,
  bool peerIsBot,
});

@visibleForTesting
bool shouldRebuildComposerForVmUpdate({
  required bool revisionChanged,
  required bool localChanged,
  required bool hasFocus,
}) => localChanged || (revisionChanged && !hasFocus);

class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.vm,
    required this.onStartCall,
    required this.onMessageSent,
    this.onPanelGeometryChanged,
    this.onMediaSendTapped,
    this.gifPreviewBuilder,
    this.requestInitialFocus = false,
    this.enterToSend = false,
    this.quickRepliesEnabled = true,
    this.showCallAction = true,
    this.onBotTopicCreated,
    this.quickReplyLoader,
    this.quickReplySender,
    this.onVoicePanelOpenedForTesting,
    this.mobileVoiceRecorderFactory,
    this.microphonePermissionForTesting,
    this.mediaSendPreviewLauncher,
    this.botPlatformForTesting,
  });
  final ChatViewModel vm;
  final FutureOr<void> Function(bool isVideo) onStartCall;
  final VoidCallback onMessageSent;
  final VoidCallback? onPanelGeometryChanged;
  final VoidCallback? onMediaSendTapped;
  @visibleForTesting
  final Widget Function(GifItem item)? gifPreviewBuilder;
  final bool requestInitialFocus;
  final bool enterToSend;
  final bool quickRepliesEnabled;
  final bool showCallAction;
  final ValueChanged<int>? onBotTopicCreated;
  @visibleForTesting
  final Future<List<BusinessQuickReplyShortcut>> Function()? quickReplyLoader;
  @visibleForTesting
  final Future<void> Function(int chatId, int shortcutId)? quickReplySender;
  @visibleForTesting
  final VoidCallback? onVoicePanelOpenedForTesting;
  @visibleForTesting
  final FlutterSoundRecorder Function()? mobileVoiceRecorderFactory;
  @visibleForTesting
  final Future<PermissionStatus> Function()? microphonePermissionForTesting;
  @visibleForTesting
  final MediaSendPreviewLauncher? mediaSendPreviewLauncher;
  @visibleForTesting
  final BotPlatformService? botPlatformForTesting;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar>
    with WidgetsBindingObserver {
  static const _clipboardChannel = MethodChannel('handy/clipboard');
  static const _maximumPendingClipboardAttachments = 10;
  static const _gifTabId = -2;
  static const _stickerSearchTabId = -3;
  static const _emojiSearchTab = 'search';
  static const _imageMimeTypes = <String>[
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/heic',
    'image/heif',
  ];

  final _controller = EmojiTextEditingController();
  final _focus = FocusNode();
  final _panelSearch = TextEditingController();
  final List<OutgoingAttachment> _pendingClipboardAttachments = [];
  bool _wasEditingMessage = false;
  int? _syncedEditingMessageId;
  int _syncedComposerRevision = -1;
  _Panel _panel = _Panel.none;
  String _emojiTab = 'standard';
  int? _stickerPack;
  Timer? _panelSearchTimer;
  int _panelSearchGeneration = 0;
  bool _panelSearchLoading = false;
  List<String> _emojiSearchResults = const [];
  List<StickerItem> _customEmojiSearchResults = const [];
  List<StickerItem> _stickerSearchResults = const [];
  List<GifItem> _gifSearchResults = const [];
  String _gifSearchNextOffset = '';
  bool _gifSearchLoadingMore = false;

  FlutterSoundRecorder? _recorder;
  Future<void>? _recorderPreparation;
  Future<void>? _voiceStart;
  Future<void>? _voiceStop;
  bool _voiceDisposed = false;
  bool _startingRecording = false;
  bool _stoppingRecording = false;
  bool _changingRecordingPause = false;
  bool _mobilePointerHeld = false;
  int? _voicePointerId;
  bool _recording = false;
  bool _recordingPaused = false;
  bool _recordingLocked = false;
  bool _recordCancelled = false;
  double _elapsed = 0;
  double _pressStartX = 0;
  double _pressStartY = 0;
  Timer? _recTimer;
  StreamSubscription<RecordingDisposition>? _recProgress;
  final List<double> _recLevels = [];
  final ValueNotifier<_RecTick> _recTick = ValueNotifier((
    elapsed: 0.0,
    levels: const <double>[],
  ));
  String? _recPath;
  late bool _hasText = vm.draft.trim().isNotEmpty;

  late _ComposerVmState _syncedVmState;
  late bool _aiDraftEligible = isTelegramAiDraftEligible(vm.draft);
  bool _replyKeyboardVisible = false;
  Timer? _mentionSearchTimer;
  MentionQuery? _mentionQuery;
  List<MentionCandidate> _mentionCandidates = const [];
  int _mentionSearchGeneration = 0;
  BotCommandQuery? _botCommandQuery;
  List<BotCommandOption> _botCommandCandidates = const [];
  late final BotPlatformService _botPlatform;
  StreamSubscription<Map<String, dynamic>>? _botPlatformUpdates;
  final List<BotGuestQuery> _guestQueries = [];
  Timer? _inlineBotTimer;
  int _inlineBotGeneration = 0;
  bool _inlineBotLoading = false;
  BotPlatformCapabilities? _inlineBot;
  BotInlineResultsPage? _inlineBotResults;
  bool _quickRepliesLoaded = false;
  bool _quickReplyContextVisible = false;
  int? _quickReplySendingId;
  List<BusinessQuickReplyShortcut> _quickReplies = const [];
  bool _syncingControllerFromVm = false;
  bool _initialFocusRequestConsumed = false;
  bool _keyboardSendScheduled = false;
  ChatViewModel get vm => widget.vm;

  bool get _canUseQuickReplies =>
      widget.quickRepliesEnabled &&
      !vm.isGroup &&
      !vm.peerIsBot &&
      !vm.isSecretChat &&
      vm.peerUserId != vm.meId;

  bool get _canSendVoiceNotes => vm.canSendMessages && vm.canSendVoiceNotes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncedVmState = _renderedVmState;
    _botPlatform = widget.botPlatformForTesting ?? BotPlatformService();
    _wasEditingMessage = vm.editingMessage != null;
    _syncedEditingMessageId = vm.editingMessage?.id;
    _controller.setFormattedText(
      vm.composerFormattedDraft,
      vm.composerDraftEntities,
    );
    _controller.addListener(_onTextChanged);
    _panelSearch.addListener(_queuePanelSearch);
    _focus.addListener(() {
      var needsRebuild = false;
      var panelChanged = false;
      if (_focus.hasFocus && _panel != _Panel.none) {
        if (_panel == _Panel.voice) _cancelVoiceRecording();
        _panel = _Panel.none;
        needsRebuild = true;
        panelChanged = true;
      }
      if (!_focus.hasFocus) {
        _mentionSearchTimer?.cancel();
        _mentionSearchGeneration++;
        if (_mentionQuery != null || _mentionCandidates.isNotEmpty) {
          _mentionQuery = null;
          _mentionCandidates = const [];
          needsRebuild = true;
        }
      }
      if (needsRebuild && mounted) {
        setState(() {});
        if (panelChanged) widget.onPanelGeometryChanged?.call();
      }
      if (_focus.hasFocus) _updateMentionSuggestions();
    });
    vm.addListener(_syncFromVm);
    EmojiStore.shared.addListener(_onStore);
    StickerStore.shared.addListener(_onStore);
    GifStore.shared.addListener(_onStore);
    _botPlatformUpdates = TdClient.shared
        .updatesOf('updateNewGuestQuery')
        .listen(_handleBotPlatformUpdate);
    if (widget.quickReplyLoader == null) {
      BusinessQuickReplyService.shared.addListener(_syncQuickReplyCache);
      _adoptQuickReplyCache(rebuild: false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestInitialFocusIfReady();
      if (mounted && _canUseQuickReplies) {
        unawaited(_loadQuickReplies(userInitiated: false));
      }
    });
  }

  void _handleBotPlatformUpdate(Map<String, dynamic> update) {
    try {
      final query = BotGuestQuery.fromUpdate(update);
      if (!mounted) return;
      setState(() {
        _guestQueries.removeWhere((value) => value.id == query.id);
        _guestQueries.insert(0, query);
        if (_guestQueries.length > 50) {
          _guestQueries.removeRange(50, _guestQueries.length);
        }
      });
    } on FormatException {
    }
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  DateTime? _lastTyping;
  void _onTextChanged() {
    if (_syncingControllerFromVm) return;
    final (text, entities) = _controller.toFormatted();
    vm.setDraft(_controller.text, formattedText: text, entities: entities);
    final hasText = _controller.text.trim().isNotEmpty;
    final aiDraftEligible = isTelegramAiDraftEligible(_controller.text);
    if (hasText != _hasText || aiDraftEligible != _aiDraftEligible) {
      _hasText = hasText;
      _aiDraftEligible = aiDraftEligible;
      if (hasText) {
        _replyKeyboardVisible = false;
        _quickReplyContextVisible = false;
      }
      if (mounted) setState(() {});
    }
    if (vm.editingMessage != null) {
      _mentionSearchTimer?.cancel();
      _inlineBotTimer?.cancel();
      _mentionSearchGeneration++;
      _inlineBotGeneration++;
      final hadSuggestions =
          _mentionQuery != null ||
          _mentionCandidates.isNotEmpty ||
          _botCommandQuery != null ||
          _botCommandCandidates.isNotEmpty ||
          _inlineBotLoading ||
          _inlineBotResults != null;
      _mentionQuery = null;
      _mentionCandidates = const [];
      _botCommandQuery = null;
      _botCommandCandidates = const [];
      _inlineBotLoading = false;
      _inlineBotResults = null;
      if (hadSuggestions && mounted) setState(() {});
      return;
    }
    _updateMentionSuggestions();
    _updateBotCommandSuggestions();
    _queueInlineBotResults();
    final now = DateTime.now();
    if (_controller.text.isNotEmpty &&
        (_lastTyping == null || now.difference(_lastTyping!).inSeconds >= 4)) {
      _lastTyping = now;
      vm.sendTyping();
    }
  }

  void _updateMentionSuggestions() {
    final query = activeMentionQuery(_controller.text, _controller.selection);
    if (!_focus.hasFocus || query == null || !vm.isGroup) {
      _mentionSearchTimer?.cancel();
      _mentionSearchGeneration++;
      if (_mentionQuery != null || _mentionCandidates.isNotEmpty) {
        _mentionQuery = null;
        _mentionCandidates = const [];
        if (mounted) setState(() {});
      }
      return;
    }
    if (_mentionQuery?.start == query.start &&
        _mentionQuery?.end == query.end &&
        _mentionQuery?.query == query.query) {
      return;
    }
    _mentionQuery = query;
    _mentionCandidates = const [];
    if (mounted) setState(() {});
    _mentionSearchTimer?.cancel();
    final generation = ++_mentionSearchGeneration;
    _mentionSearchTimer = Timer(const Duration(milliseconds: 120), () async {
      final candidates = await vm.searchMentionCandidates(query.query);
      if (!mounted || generation != _mentionSearchGeneration) return;
      final active = activeMentionQuery(
        _controller.text,
        _controller.selection,
      );
      if (!_focus.hasFocus ||
          active == null ||
          active.start != query.start ||
          active.end != query.end ||
          active.query != query.query) {
        return;
      }
      setState(() => _mentionCandidates = candidates);
    });
  }

  void _selectMention(MentionCandidate candidate) {
    final query = activeMentionQuery(_controller.text, _controller.selection);
    final expected = _mentionQuery;
    if (query == null ||
        expected == null ||
        query.start != expected.start ||
        query.end != expected.end ||
        query.query != expected.query) {
      return;
    }
    _mentionSearchTimer?.cancel();
    _mentionSearchGeneration++;
    _mentionQuery = null;
    _mentionCandidates = const [];
    _controller.insertTextMention(
      start: query.start,
      end: query.end,
      label: candidate.name,
      userId: candidate.userId,
    );
    _focus.requestFocus();
  }

  bool get _mentionSuggestionsVisible {
    if (!_focus.hasFocus || _mentionCandidates.isEmpty) return false;
    final expected = _mentionQuery;
    final active = activeMentionQuery(_controller.text, _controller.selection);
    return expected != null &&
        active != null &&
        active.start == expected.start &&
        active.end == expected.end &&
        active.query == expected.query;
  }

  void _updateBotCommandSuggestions({bool force = false, bool rebuild = true}) {
    final query = activeBotCommandQuery(
      _controller.text,
      _controller.selection,
    );
    final supportsCommands = (vm.isGroup && !vm.isChannel) || vm.peerIsBot;
    if (query == null || !supportsCommands) {
      if (_botCommandQuery == null && _botCommandCandidates.isEmpty) return;
      _botCommandQuery = null;
      _botCommandCandidates = const [];
      if (rebuild && mounted) setState(() {});
      return;
    }
    if (!force &&
        _botCommandQuery?.start == query.start &&
        _botCommandQuery?.end == query.end &&
        _botCommandQuery?.query == query.query) {
      return;
    }
    _botCommandQuery = query;
    _botCommandCandidates = matchingBotCommands(vm.botCommands, query.query);
    if (rebuild && mounted) setState(() {});
  }

  void _sendBotCommandHint(BotCommandOption command) {
    if (!vm.sendCommand(command.targetedCommand)) return;
    _controller.clear();
    _focus.requestFocus();
    widget.onMessageSent();
  }

  void _insertBotCommandHint(BotCommandOption command) {
    final query = activeBotCommandQuery(
      _controller.text,
      _controller.selection,
    );
    if (query == null) return;
    final replacement = '${command.displayCommand} ';
    final text = _controller.text.replaceRange(
      query.start,
      query.end,
      replacement,
    );
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: query.start + replacement.length,
      ),
    );
    _focus.requestFocus();
  }

  void _queueInlineBotResults() {
    final invocation = _controller.startsWithIdBackedMention
        ? null
        : BotInlineInvocation.fromText(_controller.text);
    _inlineBotTimer?.cancel();
    final generation = ++_inlineBotGeneration;
    if (invocation == null) {
      if (_inlineBotLoading ||
          _inlineBotResults != null ||
          _inlineBot != null) {
        _inlineBotLoading = false;
        _inlineBotResults = null;
        _inlineBot = null;
        if (mounted) setState(() {});
      }
      return;
    }
    if (!_inlineBotLoading || _inlineBotResults != null) {
      _inlineBotLoading = true;
      _inlineBotResults = null;
      if (mounted) setState(() {});
    }
    _inlineBotTimer = Timer(
      const Duration(milliseconds: 260),
      () => unawaited(_loadInlineBotResults(invocation, generation)),
    );
  }

  Future<void> _loadInlineBotResults(
    BotInlineInvocation invocation,
    int generation,
  ) async {
    try {
      var bot = _inlineBot;
      if (bot == null ||
          bot.username.toLowerCase() != invocation.username.toLowerCase()) {
        bot = await _botPlatform.capabilitiesForUsername(invocation.username);
      }
      if (!bot.inlineMode) throw StateError('BOT_INLINE_MODE_DISABLED');
      final location = bot.needsLocation ? await _inlineBotLocation() : null;
      if (bot.needsLocation && location == null) {
        throw StateError('BOT_INLINE_LOCATION_UNAVAILABLE');
      }
      final response = await _botPlatform.inlineResults(
        botUserId: bot.userId,
        chatId: vm.chatId,
        query: invocation.query,
        location: location,
      );
      final page = BotInlineResultsPage.fromJson(response);
      if (!mounted || generation != _inlineBotGeneration) return;
      setState(() {
        _inlineBot = bot;
        _inlineBotResults = page;
        _inlineBotLoading = false;
      });
    } catch (_) {
      if (!mounted || generation != _inlineBotGeneration) return;
      setState(() {
        _inlineBotResults = null;
        _inlineBotLoading = false;
      });
    }
  }

  Future<Map<String, dynamic>?> _inlineBotLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    final value = await Geolocator.getCurrentPosition();
    return {
      '@type': 'location',
      'latitude': value.latitude,
      'longitude': value.longitude,
      'horizontal_accuracy': value.accuracy,
    };
  }

  _ComposerVmState get _renderedVmState => (
    autoDeleteTime: vm.messageAutoDeleteTime,
    selectedSender: vm.selectedMessageSender,
    canChooseSender: vm.canChooseMessageSender,
    peerIsBot: vm.peerIsBot,
  );

  void _syncFromVm() {
    final revision = vm.composerRevision;
    final revisionChanged = revision != _syncedComposerRevision;
    _syncedComposerRevision = revision;
    final hadText = _hasText;
    final previousVmState = _syncedVmState;
    _syncedVmState = _renderedVmState;
    final wasAiDraftEligible = _aiDraftEligible;
    final hadQuickReplyContext = _quickReplyContextVisible;
    final voicePanelWasClosed =
        (!_canSendVoiceNotes || vm.editingMessage != null) &&
        _panel == _Panel.voice;
    if (voicePanelWasClosed) {
      _cancelVoiceRecording();
      _panel = _Panel.none;
    }
    final previousBotCommandQuery = _botCommandQuery;
    final previousBotCommandCandidates = _botCommandCandidates;
    final editingMessage = vm.editingMessage;
    final editingStateChanged =
        _wasEditingMessage != (editingMessage != null) ||
        _syncedEditingMessageId != editingMessage?.id;
    if (editingStateChanged) {
      _wasEditingMessage = editingMessage != null;
      _syncedEditingMessageId = editingMessage?.id;
      _panel = _Panel.none;
      _replyKeyboardVisible = false;
      _quickReplyContextVisible = false;
      _syncingControllerFromVm = true;
      try {
        _controller.setFormattedText(
          vm.composerFormattedDraft,
          vm.composerDraftEntities,
        );
      } finally {
        _syncingControllerFromVm = false;
      }
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focus.requestFocus();
        widget.onPanelGeometryChanged?.call();
      });
    } else {
      final composing = _controller.value.composing;
      final composingLocally = _focus.hasFocus || composing.isValid;
      if (!composingLocally && vm.draft != _controller.text) {
        _controller.value = TextEditingValue(
          text: vm.draft,
          selection: TextSelection.collapsed(offset: vm.draft.length),
        );
      }
    }
    _hasText = _controller.text.trim().isNotEmpty;
    _aiDraftEligible = isTelegramAiDraftEligible(_controller.text);
    if (_hasText) _quickReplyContextVisible = false;
    if (vm.editingMessage == null) {
      _updateBotCommandSuggestions(force: true, rebuild: false);
    } else {
      _botCommandQuery = null;
      _botCommandCandidates = const [];
    }
    _requestInitialFocusIfReady();
    final localChanged =
        editingStateChanged ||
        voicePanelWasClosed ||
        hadText != _hasText ||
        wasAiDraftEligible != _aiDraftEligible ||
        hadQuickReplyContext != _quickReplyContextVisible ||
        previousVmState != _syncedVmState ||
        !identical(previousBotCommandQuery, _botCommandQuery) ||
        !identical(previousBotCommandCandidates, _botCommandCandidates);
    if (mounted &&
        shouldRebuildComposerForVmUpdate(
          revisionChanged: revisionChanged,
          localChanged: localChanged,
          hasFocus: _focus.hasFocus,
        )) {
      setState(() {});
    }
  }

  void _requestInitialFocusIfReady() {
    if (_initialFocusRequestConsumed ||
        !widget.requestInitialFocus ||
        !vm.initialLoaded) {
      return;
    }
    if (vm.draft != _controller.text) {
      _controller.value = TextEditingValue(
        text: vm.draft,
        selection: TextSelection.collapsed(offset: vm.draft.length),
      );
    }
    _initialFocusRequestConsumed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _syncQuickReplyCache() => _adoptQuickReplyCache(rebuild: true);

  void _adoptQuickReplyCache({required bool rebuild}) {
    final service = BusinessQuickReplyService.shared;
    if (!service.shortcutsLoaded) return;
    final replies = service.shortcuts;
    _quickReplies = replies;
    _quickRepliesLoaded = true;
    if (replies.isEmpty || !widget.quickRepliesEnabled) {
      _quickReplyContextVisible = false;
    }
    if (rebuild && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.vm, widget.vm)) {
      _cancelVoiceRecording();
      if (_panel == _Panel.voice) _panel = _Panel.none;
      _discardPendingClipboardAttachments();
      _initialFocusRequestConsumed = false;
    } else if (!oldWidget.requestInitialFocus && widget.requestInitialFocus) {
      _initialFocusRequestConsumed = false;
    }
    _requestInitialFocusIfReady();
    if (oldWidget.quickRepliesEnabled && !widget.quickRepliesEnabled) {
      _quickReplyContextVisible = false;
    } else if (!oldWidget.quickRepliesEnabled &&
        widget.quickRepliesEnabled &&
        _canUseQuickReplies) {
      _adoptQuickReplyCache(rebuild: false);
      unawaited(_loadQuickReplies(userInitiated: false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voiceDisposed = true;
    _recordCancelled = true;
    _clearVoicePresses();
    _discardPendingClipboardAttachments();
    vm.removeListener(_syncFromVm);
    EmojiStore.shared.removeListener(_onStore);
    StickerStore.shared.removeListener(_onStore);
    GifStore.shared.removeListener(_onStore);
    if (widget.quickReplyLoader == null) {
      BusinessQuickReplyService.shared.removeListener(_syncQuickReplyCache);
    }
    _controller.dispose();
    _panelSearch
      ..removeListener(_queuePanelSearch)
      ..dispose();
    _focus.dispose();
    _recTimer?.cancel();
    _recProgress?.cancel();
    _recTick.dispose();
    _mentionSearchTimer?.cancel();
    _panelSearchTimer?.cancel();
    _inlineBotTimer?.cancel();
    _botPlatformUpdates?.cancel();
    unawaited(_disposeVoiceRecorders());
    super.dispose();
  }

  void _discardPendingClipboardAttachments() {
    final attachments = List<OutgoingAttachment>.of(
      _pendingClipboardAttachments,
    );
    _pendingClipboardAttachments.clear();
    for (final attachment in attachments) {
      unawaited(_deleteTempFile(attachment.path));
    }
  }

  void _queuePanelSearch() {
    _panelSearchTimer?.cancel();
    final query = _panelSearch.text.trim();
    if (query.isEmpty) {
      _panelSearchGeneration++;
      if (mounted) {
        setState(() {
          _panelSearchLoading = false;
          _emojiSearchResults = const [];
          _customEmojiSearchResults = const [];
          _stickerSearchResults = const [];
          _gifSearchResults = const [];
          _gifSearchNextOffset = '';
          _gifSearchLoadingMore = false;
        });
      }
      return;
    }
    if (!_isPanelSearchSelected) return;
    _panelSearchTimer = Timer(
      const Duration(milliseconds: 320),
      () => unawaited(_runPanelSearch(query)),
    );
  }

  Future<void> _runPanelSearch(String query) async {
    if (!_isPanelSearchSelected) return;
    final generation = ++_panelSearchGeneration;
    if (mounted) setState(() => _panelSearchLoading = true);
    final languageCodes = mounted
        ? [Localizations.localeOf(context).languageCode]
        : const <String>[];
    var emoji = const <String>[];
    var customEmoji = const <StickerItem>[];
    var stickers = const <StickerItem>[];
    var gifs = const <GifItem>[];
    var gifNextOffset = '';
    try {
      if (_panel == _Panel.emoji && _emojiTab == _emojiSearchTab) {
        final results = await Future.wait([
          TdClient.shared.query({
            '@type': 'searchEmojis',
            'text': query,
            'input_language_codes': languageCodes,
          }),
          TdClient.shared.query({
            '@type': 'searchStickers',
            'sticker_type': {'@type': 'stickerTypeCustomEmoji'},
            'emojis': '',
            'query': query,
            'input_language_codes': languageCodes,
            'offset': 0,
            'limit': 80,
          }),
        ]);
        final values = <String>[];
        for (final keyword
            in results.first.objects('emoji_keywords') ??
                const <Map<String, dynamic>>[]) {
          final value = keyword.str('emoji');
          if (value != null && value.isNotEmpty && !values.contains(value)) {
            values.add(value);
          }
        }
        emoji = values;
        customEmoji = parseStickers(results.last.objects('stickers'));
      } else if (_panel == _Panel.sticker &&
          _stickerPack == _stickerSearchTabId) {
        final results = await Future.wait<dynamic>([
          TdClient.shared.query({
            '@type': 'searchStickers',
            'sticker_type': {'@type': 'stickerTypeRegular'},
            'emojis': '',
            'query': query,
            'input_language_codes': languageCodes,
            'offset': 0,
            'limit': 100,
          }),
          _searchGifs(query),
        ]);
        final result = results.first as Map<String, dynamic>;
        final gifPage = results.last as (List<GifItem>, String);
        stickers = parseStickers(result.objects('stickers'));
        gifs = gifPage.$1;
        gifNextOffset = gifPage.$2;
      }
    } catch (_) {}
    if (!mounted ||
        generation != _panelSearchGeneration ||
        query != _panelSearch.text.trim() ||
        !_isPanelSearchSelected) {
      return;
    }
    setState(() {
      _panelSearchLoading = false;
      _emojiSearchResults = emoji;
      _customEmojiSearchResults = customEmoji;
      _stickerSearchResults = stickers;
      _gifSearchResults = gifs;
      _gifSearchNextOffset = gifNextOffset;
      _gifSearchLoadingMore = false;
    });
  }

  Future<(List<GifItem>, String)> _searchGifs(
    String query, {
    String offset = '',
  }) async {
    final option = await TdClient.shared.query({
      '@type': 'getOption',
      'name': 'animation_search_bot_username',
    });
    final username = option.str('value') ?? '';
    if (username.isEmpty) return (const <GifItem>[], '');
    final botChat = await TdClient.shared.query({
      '@type': 'searchPublicChat',
      'username': username,
    });
    final botUserId = botChat.obj('type')?.int64('user_id');
    if (botUserId == null) return (const <GifItem>[], '');
    final response = await TdClient.shared.query({
      '@type': 'getInlineQueryResults',
      'bot_user_id': botUserId,
      'chat_id': vm.chatId,
      'query': query,
      'offset': offset,
    });
    final page = parseInlineGifSearchPage(response);
    return (page.items, page.nextOffset);
  }

  Future<void> _loadMoreGifSearch() async {
    final query = _panelSearch.text.trim();
    final offset = _gifSearchNextOffset;
    if (!_isPanelSearchSelected ||
        query.isEmpty ||
        offset.isEmpty ||
        _gifSearchLoadingMore) {
      return;
    }
    setState(() => _gifSearchLoadingMore = true);
    try {
      final page = await _searchGifs(query, offset: offset);
      if (!mounted ||
          query != _panelSearch.text.trim() ||
          !_isPanelSearchSelected) {
        return;
      }
      final known = _gifSearchResults.map((item) => item.id).toSet();
      setState(() {
        _gifSearchResults = [
          ..._gifSearchResults,
          ...page.$1.where((item) => known.add(item.id)),
        ];
        _gifSearchNextOffset = page.$2;
        _gifSearchLoadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _gifSearchLoadingMore = false);
    }
  }

  bool get _isPanelSearchSelected =>
      (_panel == _Panel.emoji && _emojiTab == _emojiSearchTab) ||
      (_panel == _Panel.sticker && _stickerPack == _stickerSearchTabId);

  void _setPanel(_Panel next) {
    if (_panel == next && !_quickReplyContextVisible) return;
    if (_panel == _Panel.voice && next != _Panel.voice) {
      _cancelVoiceRecording();
    }
    setState(() {
      _panel = next;
      _quickReplyContextVisible = false;
    });
    widget.onPanelGeometryChanged?.call();
  }

  void _selectEmojiTab(String tab) {
    if (_emojiTab == tab) return;
    setState(() => _emojiTab = tab);
    if (tab == _emojiSearchTab && _panelSearch.text.trim().isNotEmpty) {
      _queuePanelSearch();
    }
  }

  void _selectStickerTab(int tab) {
    if (_stickerPack == tab) return;
    setState(() => _stickerPack = tab);
    if (tab == _stickerSearchTabId && _panelSearch.text.trim().isNotEmpty) {
      _queuePanelSearch();
    } else if (tab == _gifTabId) {
      GifStore.shared.loadIfNeeded();
    } else if (tab == StickerStore.recentPackId) {
      StickerStore.shared.loadIfNeeded();
    } else {
      StickerStore.shared.loadPack(tab);
    }
  }

  void _finishPanelSend() {
    _setPanel(_Panel.none);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onMessageSent();
    });
  }


  void _toggleVoice() {
    _focus.unfocus();
    final opening = _panel != _Panel.voice;
    _setPanel(opening ? _Panel.voice : _Panel.none);
    if (opening) {
      final testingHook = widget.onVoicePanelOpenedForTesting;
      if (testingHook != null) {
        testingHook();
      } else {
        unawaited(_prepareRecorder());
      }
    }
  }

  Future<void> _prepareRecorder() async {
    if (_recorder != null) return;
    final pending = _recorderPreparation;
    if (pending != null) return pending;
    late final Future<void> preparation;
    preparation = _createMobileRecorder().whenComplete(() {
      if (identical(_recorderPreparation, preparation)) {
        _recorderPreparation = null;
      }
    });
    _recorderPreparation = preparation;
    await preparation;
  }

  Future<void> _createMobileRecorder() async {
    FlutterSoundRecorder? recorder;
    try {
      final permission = widget.microphonePermissionForTesting;
      var status = permission != null
          ? await permission()
          : await Permission.microphone.status;
      if (permission == null &&
          !status.isGranted &&
          !status.isPermanentlyDenied) {
        status = await Permission.microphone.request();
      }
      if (_voiceDisposed || !mounted) return;
      if (!status.isGranted) {
        showToast(
          context,
          AppStrings.t(
            status.isPermanentlyDenied
                ? AppStringKeys.composerMicrophonePermissionSettings
                : AppStringKeys.composerMicrophonePermissionRequired,
          ),
        );
        if (status.isPermanentlyDenied) unawaited(openAppSettings());
        return;
      }
      recorder =
          widget.mobileVoiceRecorderFactory?.call() ??
          FlutterSoundRecorder(logLevel: Level.warning);
      await recorder.openRecorder();
      await recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
      if (_voiceDisposed || !mounted) {
        await recorder.closeRecorder();
        return;
      }
      setState(() => _recorder = recorder);
    } catch (_) {
      try {
        await recorder?.closeRecorder();
      } catch (_) {}
      _showRecordingError();
    }
  }

  bool get _voicePressHeld => _mobilePointerHeld;

  bool get _canStartHeldRecording =>
      mounted &&
      !_voiceDisposed &&
      _panel == _Panel.voice &&
      _canSendVoiceNotes &&
      !_recordCancelled &&
      _voicePressHeld;

  Future<void> _beginVoiceRecording() {
    if (_voiceDisposed || _voiceStop != null || _recording) {
      return Future<void>.value();
    }
    final pending = _voiceStart;
    if (pending != null) return pending;
    _recordCancelled = false;
    _recordingPaused = false;
    _recordingLocked = false;
    _elapsed = 0;
    _recLevels.clear();
    _recTick.value = (elapsed: 0.0, levels: const <double>[]);
    setState(() => _startingRecording = true);
    late final Future<void> start;
    start =
        () async {
              await _prepareRecorder();
              if (!_canStartHeldRecording) return;
              await _startRec();
            }()
            .catchError((Object _) {
              _showRecordingError();
            })
            .whenComplete(() {
              if (identical(_voiceStart, start)) _voiceStart = null;
              _startingRecording = false;
              if (mounted && !_voiceDisposed) setState(() {});
            });
    _voiceStart = start;
    return start;
  }

  void _showRecordingError() {
    if (mounted && !_voiceDisposed && _panel == _Panel.voice) {
      showToast(context, AppStrings.t(AppStringKeys.composerRecordingFailed));
    }
  }

  Future<void> _startRec() async {
    final r = _recorder;
    if (r == null || _recording) return;
    final dir = await getTemporaryDirectory();
    const candidates = [
      (Codec.opusOGG, 'ogg'),
      (Codec.opusWebM, 'webm'),
      (Codec.aacADTS, 'aac'),
      (Codec.aacMP4, 'm4a'),
    ];
    var started = false;
    for (final (codec, extension) in candidates) {
      if (!_canStartHeldRecording) return;
      try {
        if (!await r.isEncoderSupported(codec)) continue;
        if (!_canStartHeldRecording) return;
        final path =
            '${dir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.$extension';
        _recPath = path;
        await r.startRecorder(toFile: path, codec: codec, sampleRate: 48000);
        started = true;
        break;
      } catch (_) {
        try {
          await r.stopRecorder();
        } catch (_) {}
        final path = _recPath;
        _recPath = null;
        if (path != null) await _deleteTempFile(path);
      }
    }
    if (!started) {
      _showRecordingError();
      return;
    }
    if (_voiceDisposed || !mounted) return;
    setState(() => _recording = true);
    await _recProgress?.cancel();
    final clock = VoiceRecordingClock();
    _recProgress = r.onProgress?.listen((event) {
      if (!mounted || _voiceDisposed || !_recording || _recordingPaused) return;
      clock.update(event.duration);
      _elapsed = clock.seconds;
      final level = event.decibels;
      if (level != null && level.isFinite) {
        _recLevels.add((level >= 0 ? level - 120 : level).clamp(-120.0, 0.0));
      }
      _recTick.value = (
        elapsed: _elapsed,
        levels: _recLevels.reversed.take(36).toList().reversed.toList(),
      );
    });
    _recTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted || _voiceDisposed || !_recording) return;
      if (clock.hasRecorderProgress) {
        timer.cancel();
        _recTimer = null;
        return;
      }
      clock.tick(const Duration(milliseconds: 100), paused: _recordingPaused);
      _elapsed = clock.seconds;
      _recTick.value = (elapsed: _elapsed, levels: _recTick.value.levels);
    });
  }

  Future<void> _stopRec() {
    final pending = _voiceStop;
    if (pending != null) return pending;
    if (_voiceDisposed || !mounted) return Future<void>.value();
    setState(() => _stoppingRecording = true);
    late final Future<void> stop;
    stop = _finishVoiceRecording().whenComplete(() {
      if (identical(_voiceStop, stop)) _voiceStop = null;
      _stoppingRecording = false;
      if (mounted && !_voiceDisposed) setState(() {});
    });
    _voiceStop = stop;
    return stop;
  }

  Future<void> _finishVoiceRecording() async {
    await _voiceStart;
    if (_voiceDisposed || !_recording) return;
    final target = vm;
    final duration = _elapsed.round();
    final levels = List<double>.unmodifiable(_recLevels);
    final originalPath = _recPath;
    _recTimer?.cancel();
    _recTimer = null;
    await _recProgress?.cancel();
    _recProgress = null;
    _recording = false;
    _recordingPaused = false;
    _recordingLocked = false;
    _clearVoicePresses();
    if (mounted && !_voiceDisposed) setState(() {});
    String? recordedPath;
    try {
      recordedPath = await _recorder?.stopRecorder();
    } catch (_) {
      try {
        final recorder = _recorder;
        _recorder = null;
        await recorder?.closeRecorder();
      } catch (_) {}
    }
    final url = await _waitForRecordingFile(recordedPath);
    _recPath = null;
    final cancelled =
        _recordCancelled ||
        _voiceDisposed ||
        !mounted ||
        _panel != _Panel.voice ||
        !identical(target, vm) ||
        !_canSendVoiceNotes;
    if (cancelled || duration < 1 || url == null) {
      for (final path in {originalPath, recordedPath}.whereType<String>()) {
        await _deleteTempFile(path);
      }
      if (_voiceDisposed || !mounted) return;
      if (!cancelled && duration >= 1 && url == null) _showRecordingError();
      _elapsed = 0;
      _recLevels.clear();
      _recTick.value = (elapsed: 0.0, levels: const <double>[]);
      return;
    }
    if (!mounted || _voiceDisposed) return;
    if (_voiceDisposed || !identical(target, vm)) {
      await _deleteTempFile(url);
      return;
    }
    final sent = await target.sendVoice(
      url,
      duration,
      waveform: encodeTelegramWaveform(levels),
    );
    if (!mounted || _voiceDisposed) return;
    if (sent) {
      _finishPanelSend();
    } else {
      showToast(
        context,
        AppStrings.t(AppStringKeys.topicPostContentActionFailed),
      );
    }
  }

  void _clearVoicePresses() {
    _mobilePointerHeld = false;
    _voicePointerId = null;
  }

  void _cancelVoiceRecording() {
    _clearVoicePresses();
    _recordCancelled = true;
    if (!_voiceDisposed &&
        (_recording || _voiceStart != null || _voiceStop != null)) {
      unawaited(_stopRec());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_recordingLocked && state != AppLifecycleState.detached) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached ||
        (state == AppLifecycleState.inactive && _recording)) {
      _cancelVoiceRecording();
    }
  }

  Future<void> _disposeVoiceRecorders() async {
    try {
      await _voiceStart;
      await _voiceStop;
    } catch (_) {}
    try {
      await _recorder?.closeRecorder();
    } catch (_) {}
    final path = _recPath;
    if (path != null) await _deleteTempFile(path);
  }

  Future<void> _toggleRecPause() async {
    if (!_recording || _stoppingRecording || _changingRecordingPause) return;
    _changingRecordingPause = true;
    final paused = _recordingPaused;
    try {
      if (paused) {
        await _recorder?.resumeRecorder();
      } else {
        await _recorder?.pauseRecorder();
      }
      if (mounted && !_voiceDisposed && _recording && !_stoppingRecording) {
        setState(() => _recordingPaused = !paused);
      }
    } catch (_) {
      _showRecordingError();
    } finally {
      _changingRecordingPause = false;
    }
  }

  void _cancelLockedRecording() {
    _cancelVoiceRecording();
  }

  Future<void> _deleteTempFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<String?> _waitForRecordingFile(String? path) async {
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    var previousSize = -1;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (await file.exists()) {
          final size = await file.length();
          if (size > 32 && size == previousSize) return path;
          previousSize = size;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    try {
      return await file.exists() && await file.length() > 32 ? path : null;
    } catch (_) {
      return null;
    }
  }

  static String _recTime(double seconds) {
    final s = seconds.floor();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _toggle(_Panel panel) {
    _focus.unfocus();
    _setPanel(_panel == panel ? _Panel.none : panel);
  }

  void _pickFailed(String what) {
    _setPanel(_Panel.none);
    showToast(
      context,
      AppStrings.t(AppStringKeys.composerOpenAttachmentFailed, {
        'value1': what,
      }),
    );
  }

  void _scheduleKeyboardSend() {
    if (_keyboardSendScheduled) return;
    _keyboardSendScheduled = true;
    scheduleMicrotask(() => unawaited(_sendScheduledKeyboardText()));
  }

  Future<void> _sendScheduledKeyboardText() async {
    try {
      if (mounted) await _sendCurrentText();
    } finally {
      _keyboardSendScheduled = false;
    }
  }

  Future<void> _sendCurrentText() async {
    if (vm.editingMessage != null) {
      final (text, entities) = _controller.toFormatted();
      if (!vm.editingMessageUsesCaption && text.trim().isEmpty) {
        showToast(context, AppStringKeys.chatMessageRequired);
        return;
      }
      try {
        final edited = await vm.submitMessageEdit(text, entities: entities);
        if (!mounted || !edited) return;
        _focus.requestFocus();
      } catch (error) {
        if (mounted) showToast(context, '$error');
      }
      return;
    }
    if (_pendingClipboardAttachments.isNotEmpty) {
      await _sendPendingClipboardAttachments();
      return;
    }
    if (_controller.text.trim().isEmpty) return;
    final canAttemptSend = await vm.prepareMessageSend();
    if (!mounted || !canAttemptSend) return;
    final (text, entities) = _controller.toFormatted();
    if (text.length > 4096) {
      showToast(context, AppStringKeys.composerLongMessageTitle.l10n(context));
      return;
    }
    if (vm.requiresPaidMessage) {
      final ok = await _confirmPaidMessageSend();
      if (!mounted || !ok) return;
    }
    final sent = await vm.sendFormatted(text, entities);
    if (!mounted || !sent) return;
    widget.onMessageSent();
    _controller.clear();
    _focus.requestFocus();
  }

  Future<void> _sendPendingClipboardAttachments({
    MessageSendConfiguration sendConfiguration =
        const MessageSendConfiguration(),
  }) async {
    if (_pendingClipboardAttachments.isEmpty) return;
    final canAttemptSend = await vm.prepareMessageSend();
    if (!mounted || !canAttemptSend) return;
    final (caption, entities) = _controller.toFormatted();
    if (caption.length > 4096) {
      showToast(context, AppStringKeys.composerLongMessageTitle.l10n(context));
      return;
    }
    if (vm.requiresPaidMessage) {
      final ok = await _confirmPaidMessageSend();
      if (!mounted || !ok) return;
    }
    final attachments = List<OutgoingAttachment>.unmodifiable(
      _pendingClipboardAttachments,
    );
    try {
      await vm.sendAttachments(
        attachments,
        caption: caption,
        captionEntities: entities,
        sendConfiguration: sendConfiguration,
      );
    } catch (error) {
      if (mounted) showToast(context, '$error');
      return;
    }
    if (!mounted) return;
    setState(_pendingClipboardAttachments.clear);
    widget.onPanelGeometryChanged?.call();
    widget.onMessageSent();
    _controller.clear();
    _focus.requestFocus();
  }

  Future<void> _openTelegramAiEditor() async {
    if (!vm.canUseAiComposition || _controller.text.trim().isEmpty) return;
    final (text, entities) = _controller.toFormatted();
    final result = await Navigator.of(context).push<TelegramAiFormattedText>(
      MaterialPageRoute(
        builder: (_) => TelegramAiEditorView(
          service: vm.telegramAi,
          source: TelegramAiFormattedText(text: text, entities: entities),
        ),
      ),
    );
    if (!mounted || result == null) return;
    _controller.setFormattedText(result.text, result.entities);
    _focus.requestFocus();
  }

  Future<void> _showTextSendOptions() async {
    final configuration = await showMessageSendOptionsSheet(
      context,
      allowWhenOnline: widget.vm.canSendWhenOnline,
      effects: widget.vm.availableMessageEffects,
      onOpenScheduledMessages: _openScheduledMessages,
    );
    if (!mounted || configuration == null) return;
    if (_pendingClipboardAttachments.isNotEmpty) {
      await _sendPendingClipboardAttachments(sendConfiguration: configuration);
      return;
    }
    widget.vm.useNextSendConfiguration(configuration);
    await _sendCurrentText();
  }

  void _openScheduledMessages() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ScheduledMessagesView(
            chatId: widget.vm.chatId,
            chatTitle: widget.vm.peerTitle,
          ),
        ),
      );
    });
  }

  Future<bool> _confirmPaidMessageSend() {
    return confirmDialog(
      context,
      title: AppStrings.t(AppStringKeys.composerSendPaidMessageQuestion),
      message: AppStrings.t(AppStringKeys.composerPaidMessageCost, {
        'value1': vm.paidMessageStarCount,
      }),
      confirmText: AppStrings.t(AppStringKeys.composerSend),
    );
  }

  Future<void> _handlePaste([ContextMenuButtonItem? pasteItem]) async {
    if (vm.editingMessage == null) {
      final image = await _readClipboardImage();
      if (image != null) {
        final queued = await _queueClipboardImageData(
          ClipboardImageData(data: image.data, mimeType: image.mimeType),
        );
        if (queued) return;
      }
    }

    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text;
    if (text != null && text.isNotEmpty) {
      _controller.insertText(text);
    } else {
      pasteItem?.onPressed?.call();
    }
    _restoreKeyboardFocus();
  }

  Future<void> _showComposerFormatMenu(
    EditableTextState editableTextState,
  ) async {
    final selection = _controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final start = math.min(selection.start, selection.end);
    final end = math.max(selection.start, selection.end);
    final anchor = editableTextState.contextMenuAnchors.primaryAnchor;
    editableTextState.hideToolbar();
    final action = await showGeneralDialog<_ComposerFormatAction>(
      context: context,
      requestFocus: false,
      barrierDismissible: true,
      barrierLabel: AppStringKeys.countryPickerCancel.l10n(context),
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (dialogContext, _, _) => _ComposerFormatMenu(anchor: anchor),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
    if (!mounted) return;
    if (action == null) {
      _focus.unfocus();
      return;
    }
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    if (action == _ComposerFormatAction.link) {
      final url = await showGeneralDialog<String>(
        context: context,
        barrierDismissible: true,
        barrierLabel: AppStringKeys.countryPickerCancel.l10n(context),
        barrierColor: Colors.black.withValues(alpha: 0.36),
        transitionDuration: const Duration(milliseconds: 160),
        pageBuilder: (dialogContext, _, _) => const _ComposerLinkDialog(),
      );
      if (!mounted || url == null || url.trim().isEmpty) return;
      final normalized = _normalizeComposerUrl(url);
      _controller.applyEntityFormat(start, end, {
        '@type': 'textEntityTypeTextUrl',
        'url': normalized,
      });
    } else {
      _controller.toggleFormat(action.entityType);
    }
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    _focus.requestFocus();
  }

  String _normalizeComposerUrl(String value) {
    final trimmed = value.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed?.hasScheme ?? false) return trimmed;
    return 'https://$trimmed';
  }

  void _restoreKeyboardFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final editingMessage = vm.editingMessage;
    final replyKeyboard = _activeReplyKeyboard();
    final replyKeyboardPanelVisible =
        editingMessage == null &&
        replyKeyboard != null &&
        _replyKeyboardVisible &&
        !_hasText &&
        _pendingClipboardAttachments.isEmpty;
    final panelSurfaceVisible =
        editingMessage == null &&
        (_panel != _Panel.none || replyKeyboardPanelVisible);
    final bottomSafeArea = MediaQuery.paddingOf(context).bottom;
    final bar = ColoredBox(
      key: const ValueKey('chat-input-safe-area-background'),
      color: c.inputBarBackground,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (editingMessage != null)
                  _editBanner(editingMessage)
                else if (vm.replyTo != null)
                  _replyBanner(vm.replyTo!),
                if (editingMessage == null)
                  if (_inlineBotResults != null)
                    _inlineBotResultMenu()
                  else if (_botCommandCandidates.isNotEmpty)
                    _botCommandMenu()
                  else if (_mentionSuggestionsVisible)
                    _mentionMenu()
                  else if (_quickReplyContextVisible &&
                      _quickReplies.isNotEmpty)
                    _quickReplyContextMenu(),
                if (editingMessage == null &&
                    _pendingClipboardAttachments.isNotEmpty)
                  _clipboardAttachmentStrip(),
                _inputRow(replyKeyboard),
                if (replyKeyboardPanelVisible)
                  _replyKeyboardPanel(replyKeyboard)
                else if (editingMessage == null)
                  _iconStrip(),
                if (editingMessage == null && _panel == _Panel.function)
                  _functionPanel(),
                if (editingMessage == null && _panel == _Panel.emoji)
                  _emojiPanel(),
                if (editingMessage == null && _panel == _Panel.sticker)
                  _stickerPanel(),
                if (editingMessage == null && _panel == _Panel.voice)
                  _voicePanel(),
              ],
            ),
          ),
          if (panelSurfaceVisible && bottomSafeArea > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: bottomSafeArea,
              child: IgnorePointer(
                child: ColoredBox(
                  key: const ValueKey('chat-input-panel-safe-area-background'),
                  color: c.panelBackground,
                ),
              ),
            ),
        ],
      ),
    );
    return RepaintBoundary(child: bar);
  }

  Widget _inlineBotResultMenu() {
    final c = context.colors;
    final results = _inlineBotResults?.results ?? const <BotInlineResult>[];
    Widget child;
    if (results.isEmpty) {
      child = SizedBox(
        height: 54,
        child: Center(
          child: Text(
            AppStrings.t(AppStringKeys.chatInputBarNoInlineResults),
            style: TextStyle(color: c.textSecondary, fontSize: 14),
          ),
        ),
      );
    } else {
      child = ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: results.length,
        separatorBuilder: (_, _) => const InsetDivider(leadingInset: 54),
        itemBuilder: (_, index) {
          final result = results[index];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_sendInlineBotResult(result)),
            child: SizedBox(
              height: 58,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    AppIcon(
                      _inlineResultIcon(result.type),
                      size: 23,
                      color: AppTheme.brand,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            result.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (result.description.isNotEmpty)
                            Text(
                              result.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }

    return Container(
      key: const ValueKey('inlineBotResultMenu'),
      constraints: const BoxConstraints(maxHeight: 260),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: c.divider, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  AppIconData _inlineResultIcon(String type) => switch (type) {
    'inlineQueryResultAnimation' => HeroAppIcons.gif,
    'inlineQueryResultAudio' => HeroAppIcons.music,
    'inlineQueryResultContact' => HeroAppIcons.circleUser,
    'inlineQueryResultDocument' => HeroAppIcons.file,
    'inlineQueryResultGame' => HeroAppIcons.flash,
    'inlineQueryResultLocation' ||
    'inlineQueryResultVenue' => HeroAppIcons.locationDot,
    'inlineQueryResultPhoto' => HeroAppIcons.image,
    'inlineQueryResultSticker' => HeroAppIcons.solidFaceSmile,
    'inlineQueryResultVideo' => HeroAppIcons.video,
    'inlineQueryResultVoiceNote' => HeroAppIcons.microphone,
    _ => HeroAppIcons.font,
  };

  Future<void> _sendInlineBotResult(BotInlineResult result) async {
    final page = _inlineBotResults;
    if (page == null || page.queryId == 0 || result.id.isEmpty) return;
    try {
      await _botPlatform.sendInlineResult(
        chatId: vm.chatId,
        queryId: page.queryId,
        resultId: result.id,
        topicId: vm.forumTopicSendRef,
        replyTo: vm.replyToInput,
      );
      if (!mounted) return;
      vm.setReply(null);
      _controller.clear();
      _focus.requestFocus();
      widget.onMessageSent();
    } catch (error) {
      _showBotPlatformFailure(error);
    }
  }

  Widget _botCommandMenu() {
    final c = context.colors;
    return Container(
      key: const ValueKey('groupBotCommandHints'),
      constraints: const BoxConstraints(maxHeight: 260),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: c.divider, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _botCommandCandidates.length,
        separatorBuilder: (_, _) => const InsetDivider(leadingInset: 54),
        itemBuilder: (context, index) {
          final command = _botCommandCandidates[index];
          final stableKey = '${command.botUserId}-${command.normalizedCommand}';
          return Semantics(
            button: true,
            label: '${command.botName}, ${command.displayCommand}',
            value: command.description,
            child: GestureDetector(
              key: ValueKey('groupBotCommand-$stableKey'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _sendBotCommandHint(command),
              child: SizedBox(
                height: 46,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    PhotoAvatar(
                      title: command.botName,
                      photo: command.botPhoto,
                      size: 30,
                      allowAnimation: false,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: command.displayCommand,
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (command.description.trim().isNotEmpty)
                              TextSpan(
                                text: '  ${command.description.trim()}',
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Semantics(
                      button: true,
                      label:
                          '${AppStrings.t(AppStringKeys.composerInsert)} ${command.displayCommand}',
                      child: GestureDetector(
                        key: ValueKey('insertGroupBotCommand-$stableKey'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _insertBotCommandHint(command),
                        child: SizedBox(
                          width: 42,
                          height: 46,
                          child: Center(
                            child: AppIcon(
                              HeroAppIcons.reply,
                              size: 18,
                              color: c.textTertiary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _mentionMenu() {
    final c = context.colors;
    return TextFieldTapRegion(
      child: Padding(
        key: const ValueKey('mentionSuggestions'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _mentionCandidates.length,
            separatorBuilder: (_, _) => const InsetDivider(leadingInset: 54),
            itemBuilder: (context, index) {
              final candidate = _mentionCandidates[index];
              return GestureDetector(
                key: ValueKey('mentionCandidate-${candidate.userId}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _selectMention(candidate),
                child: SizedBox(
                  height: 52,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        PhotoAvatar(
                          title: candidate.name,
                          photo: candidate.photo,
                          size: 34,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                candidate.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: c.textPrimary,
                                ),
                              ),
                              if (candidate.username.isNotEmpty)
                                Text(
                                  '@${candidate.username}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: c.textSecondary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }


  Widget _clipboardAttachmentStrip() {
    final c = context.colors;
    final tileCachePx = (58 * MediaQuery.devicePixelRatioOf(context)).ceil();
    return SizedBox(
      key: const ValueKey('clipboardAttachmentStrip'),
      height: 70,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        itemCount: _pendingClipboardAttachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final attachment = _pendingClipboardAttachments[index];
          return SizedBox(
            key: ValueKey('clipboardAttachment-$index'),
            width: 58,
            height: 58,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: c.searchFill),
                      child: Image.file(
                        File(attachment.path),
                        fit: BoxFit.cover,
                        cacheWidth: tileCachePx,
                        errorBuilder: (_, _, _) => Center(
                          child: AppIcon(
                            HeroAppIcons.image,
                            size: 21,
                            color: c.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: -5,
                  right: -5,
                  child: AppInteractiveSurface(
                    key: ValueKey('clipboardAttachmentRemove-$index'),
                    semanticLabel: AppStringKeys.chatInfoRemove.l10n(context),
                    onTap: () => _removeClipboardAttachment(index),
                    borderRadius: BorderRadius.circular(11),
                    child: Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.card,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.divider, width: 0.75),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x26000000),
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      child: AppIcon(
                        HeroAppIcons.xmark,
                        size: 13,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _removeClipboardAttachment(int index) {
    if (index < 0 || index >= _pendingClipboardAttachments.length) {
      return;
    }
    final attachment = _pendingClipboardAttachments[index];
    setState(() => _pendingClipboardAttachments.removeAt(index));
    widget.onPanelGeometryChanged?.call();
    unawaited(_deleteTempFile(attachment.path));
  }

  Widget _editBanner(ChatMessage message) {
    final c = context.colors;
    final preview = _replyPreview(message).trim();
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 8),
      child: Container(
        key: const ValueKey('composerEditBanner'),
        height: 46,
        padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            AppTheme.cloverGreen.withValues(alpha: 0.08),
            c.searchFill,
          ),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          children: [
            Container(
              width: 2.5,
              height: 30,
              decoration: BoxDecoration(
                color: AppTheme.cloverGreen,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStringKeys.chatEditMessageTitle.l10n(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.cloverGreen,
                    ),
                  ),
                  if (preview.isNotEmpty)
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                ],
              ),
            ),
            AppInteractiveSurface(
              key: const ValueKey('composerEditCancel'),
              semanticLabel: AppStringKeys.countryPickerCancel.l10n(context),
              onTap: vm.cancelMessageEdit,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: AppIcon(
                  HeroAppIcons.xmark,
                  size: 17,
                  color: c.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _replyBanner(ChatMessage m) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 8),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: c.searchFill,
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _replyLine(m),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: c.textSecondary),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => vm.setReply(null),
              child: AppIcon(
                HeroAppIcons.xmark,
                size: 18,
                color: c.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _replyLine(ChatMessage m) {
    final name = m.isOutgoing
        ? vm.meName
        : (m.senderName?.isNotEmpty ?? false)
        ? m.senderName!
        : vm.peerTitle;
    return '$name:${vm.replyQuote?.text ?? _replyPreview(m)}';
  }

  String _replyPreview(ChatMessage m) {
    if (m.document != null) {
      return AppStrings.t(AppStringKeys.composerFilePreview, {
        'value1': m.document!.fileName,
      });
    }
    if (m.voice != null) {
      return AppStrings.t(AppStringKeys.composerVoicePreview);
    }
    if (m.location != null) {
      return AppStrings.t(AppStringKeys.composerLocationPreview);
    }
    if (m.isDice) {
      return m.diceEmoji ?? m.text;
    }
    if (m.isAnimatedEmoji) {
      return m.text;
    }
    if (m.animatedSticker != null) {
      return AppStrings.t(AppStringKeys.composerAnimatedEmojiPreview);
    }
    if (m.image != null) {
      return m.text.isEmpty
          ? AppStrings.t(AppStringKeys.composerImagePreview)
          : m.text;
    }
    return m.text;
  }


  void _showSenderPicker() {
    final options = vm.availableMessageSenders;
    if (options.length <= 1) return;
    showAppModalSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final c = context.colors;
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < options.length; i++) ...[
                  _senderOptionRow(options[i]),
                  if (i < options.length - 1)
                    const InsetDivider(leadingInset: 64),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _showBotMenu({bool forceMenu = false}) {
    final commands = vm.botCommands;
    final menu = vm.botMenu;
    final showTools = vm.peerIsBot || _guestQueries.isNotEmpty;
    if (!(menu?.isWebApp ?? false) && commands.isEmpty && !showTools) return;
    if (!forceMenu && (menu?.isWebApp ?? false)) {
      unawaited(_openBotMenuWebApp(menu!));
      return;
    }
    showAppModalSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final c = context.colors;
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                if (menu?.isWebApp ?? false) ...[
                  _botMenuRow(
                    icon: HeroAppIcons.bot,
                    title: menu!.actionTitle,
                    subtitle: '',
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(_openBotMenuWebApp(menu));
                    },
                  ),
                  if (commands.isNotEmpty || showTools)
                    const InsetDivider(leadingInset: 56),
                ],
                for (var i = 0; i < commands.length; i++) ...[
                  _botMenuRow(
                    icon: HeroAppIcons.code,
                    title: '/${commands[i].command}',
                    subtitle: commands[i].description,
                    onTap: () {
                      Navigator.of(context).pop();
                      _insertBotCommand(commands[i].command);
                    },
                  ),
                  if (i < commands.length - 1 || showTools)
                    const InsetDivider(leadingInset: 56),
                ],
                if (showTools)
                  _botMenuRow(
                    icon: HeroAppIcons.gear,
                    title: AppStrings.t(AppStringKeys.chatInputBarBotTools),
                    subtitle: _guestQueries.isEmpty
                        ? 'Inline mode, topics, and automation'
                        : '${_guestQueries.length} guest ${_guestQueries.length == 1 ? 'query' : 'queries'} waiting',
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(_showBotTools());
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openBotMenuWebApp(BotMenuInfo menu) async {
    final botUserId = vm.peerUserId;
    if (botUserId == null) {
      if (!menu.isLegacyMenuUrl && menu.webAppUrl.isNotEmpty) {
        await openLink(context, menu.webAppUrl);
      }
      return;
    }
    final opened = await openTelegramMiniApp(
      context,
      chatId: vm.chatId,
      botUserId: botUserId,
      url: menu.url,
      title: menu.actionTitle,
      menuWebApp: true,
    );
    if (!opened && mounted) {
      showToast(context, AppStrings.t(AppStringKeys.miniAppCannotStart));
    }
  }

  Widget _botMenuRow({
    required AppIconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 58,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              AppIcon(icon, size: 22, color: AppTheme.brand),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: c.textPrimary),
                    ),
                    if (subtitle.trim().isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.textSecondary),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _insertBotCommand(String command) {
    final text = '/${command.trim()} ';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  Future<void> _showBotTools() async {
    BotPlatformCapabilities? capabilities;
    final botUserId = vm.peerUserId;
    if (vm.peerIsBot && botUserId != null) {
      try {
        capabilities = await _botPlatform.capabilitiesForUserId(botUserId);
      } catch (_) {
      }
    }

    var currentAccountIsBot = false;
    try {
      currentAccountIsBot = await _botPlatform.currentAccountIsBot();
    } catch (_) {
    }
    if (!mounted) return;

    await showAppModalSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final c = sheetContext.colors;
        final entries =
            <
              ({
                AppIconData icon,
                String title,
                String subtitle,
                VoidCallback onTap,
              })
            >[];
        final resolved = capabilities;
        if (resolved?.inlineMode == true &&
            resolved!.username.trim().isNotEmpty) {
          entries.add((
            icon: HeroAppIcons.at,
            title: AppStrings.t(AppStringKeys.chatInputBarUseInlineMode),
            subtitle: resolved.inlinePlaceholder.trim().isEmpty
                ? '@${resolved.username}'
                : resolved.inlinePlaceholder,
            onTap: () {
              Navigator.of(sheetContext).pop();
              _insertInlineBot(resolved);
            },
          ));
        }
        if (resolved?.hasTopics == true &&
            resolved?.allowsUsersToCreateTopics == true) {
          entries.add((
            icon: HeroAppIcons.comments,
            title: AppStrings.t(AppStringKeys.chatInputBarCreateBotTopic),
            subtitle: AppStrings.t(
              AppStringKeys.chatInputBarCreateBotTopicDetail,
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              unawaited(_createBotTopic());
            },
          ));
        }
        if (resolved?.canManageBots == true) {
          entries.add((
            icon: HeroAppIcons.userPlus,
            title: AppStrings.t(AppStringKeys.chatInputBarCreateManagedBot),
            subtitle: AppStrings.t(
              AppStringKeys.chatInputBarCreateManagedBotDetailValue1,
              {'value1': resolved!.username},
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              unawaited(_createManagedBot(resolved.userId));
            },
          ));
        }
        if (_guestQueries.isNotEmpty) {
          entries.add((
            icon: HeroAppIcons.comments,
            title: AppStrings.t(AppStringKeys.chatInputBarGuestQueries),
            subtitle: AppStrings.plural(
              AppStringKeys.chatInputBarGuestQueriesWaiting,
              _guestQueries.length,
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _showGuestQueries();
            },
          ));
        }
        if (currentAccountIsBot) {
          entries.add((
            icon: HeroAppIcons.gear,
            title: AppStrings.t(AppStringKeys.chatInputBarAutomationStatus),
            subtitle: AppStrings.t(
              AppStringKeys.chatInputBarAutomationStatusDetail,
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              unawaited(_updateBotAutomationStatus());
            },
          ));
        }

        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            clipBehavior: Clip.antiAlias,
            child: entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      AppStrings.t(
                        AppStringKeys
                            .chatInputBarNoAdditionalToolsAreAvailableForThisBot,
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textSecondary, fontSize: 14),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: entries.length,
                    separatorBuilder: (_, _) =>
                        const InsetDivider(leadingInset: 56),
                    itemBuilder: (_, index) {
                      final entry = entries[index];
                      return _botMenuRow(
                        icon: entry.icon,
                        title: entry.title,
                        subtitle: entry.subtitle,
                        onTap: entry.onTap,
                      );
                    },
                  ),
          ),
        );
      },
    );
  }

  void _insertInlineBot(BotPlatformCapabilities bot) {
    final clean = bot.username.replaceFirst('@', '').trim();
    if (clean.isEmpty) return;
    _inlineBot = bot;
    final text = '@$clean ';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  Future<void> _createBotTopic() async {
    final name = await _promptBotText(
      title: AppStrings.t(AppStringKeys.chatInputBarCreateBotTopic),
      label: AppStrings.t(AppStringKeys.chatInputBarTopicName),
      actionLabel: AppStrings.t(AppStringKeys.chatInputBarCreateAction),
    );
    if (name == null) return;
    try {
      final result = await _botPlatform.createBotTopic(
        chatId: vm.chatId,
        name: name,
      );
      final topicId = forumTopicIdFromResult(result);
      await vm.loadForumTopics();
      if (!mounted) return;
      final onBotTopicCreated = widget.onBotTopicCreated;
      if (topicId != null && topicId != 0 && onBotTopicCreated != null) {
        onBotTopicCreated(topicId);
        return;
      }
      showToast(
        context,
        AppStrings.t(AppStringKeys.chatInputBarBotTopicCreated),
      );
    } catch (error) {
      _showBotPlatformFailure(error);
    }
  }

  Future<void> _createManagedBot(
    int managerBotUserId, {
    String suggestedName = '',
    String suggestedUsername = '',
  }) async {
    final name = await _promptBotText(
      title: AppStrings.t(AppStringKeys.chatInputBarCreateManagedBot),
      label: AppStrings.t(AppStringKeys.chatInputBarBotName),
      initialValue: suggestedName,
      actionLabel: AppStrings.t(AppStringKeys.chatInputBarNextAction),
    );
    if (name == null) return;
    final username = await _promptBotText(
      title: AppStrings.t(AppStringKeys.chatInputBarCreateManagedBot),
      label: AppStrings.t(AppStringKeys.editProfileUsername),
      initialValue: suggestedUsername,
      actionLabel: AppStrings.t(AppStringKeys.chatInputBarCreateAction),
    );
    if (username == null) return;
    try {
      await _botPlatform.createManagedBot(
        managerBotUserId: managerBotUserId,
        name: name,
        username: username,
      );
      if (mounted) {
        showToast(
          context,
          AppStrings.t(AppStringKeys.chatInputBarManagedBotCreated),
        );
      }
    } catch (error) {
      _showBotPlatformFailure(error);
    }
  }

  void _showGuestQueries() {
    showAppModalSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final c = sheetContext.colors;
        return SafeArea(
          child: Container(
            constraints: const BoxConstraints(maxHeight: 420),
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _guestQueries.length,
              separatorBuilder: (_, _) => const InsetDivider(leadingInset: 56),
              itemBuilder: (_, index) {
                final query = _guestQueries[index];
                return _botMenuRow(
                  icon: HeroAppIcons.message,
                  title: _guestQueryPreview(query),
                  subtitle:
                      '${query.referenceMessages.length} reference ${query.referenceMessages.length == 1 ? 'message' : 'messages'}',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_replyToGuestQuery(query));
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  String _guestQueryPreview(BotGuestQuery query) {
    try {
      final content = query.message.obj('content');
      final text = content == null ? '' : TDParse.messageText(content).trim();
      if (text.isNotEmpty) return text;
    } catch (_) {
    }
    return AppStrings.t(AppStringKeys.chatInputBarGuestQueryValue1, {
      'value1': query.id,
    });
  }

  Future<void> _replyToGuestQuery(BotGuestQuery query) async {
    final reply = await _promptBotText(
      title: AppStrings.t(AppStringKeys.chatInputBarAnswerGuestQuery),
      label: AppStrings.t(AppStringKeys.chatInputBarReply),
      actionLabel: AppStrings.t(AppStringKeys.chatInputBarSendAction),
    );
    if (reply == null) return;
    try {
      await _botPlatform.answerGuestQuery(
        guestQueryId: query.id,
        result: {
          '@type': 'inputInlineQueryResultArticle',
          'id': 'guest_${query.id}',
          'url': '',
          'title': 'Reply',
          'description': reply,
          'thumbnail_url': '',
          'thumbnail_width': 0,
          'thumbnail_height': 0,
          'reply_markup': null,
          'input_message_content': {
            '@type': 'inputMessageText',
            'text': {
              '@type': 'formattedText',
              'text': reply,
              'entities': <Map<String, dynamic>>[],
            },
            'link_preview_options': null,
            'clear_draft': false,
          },
        },
      );
      if (!mounted) return;
      setState(() => _guestQueries.removeWhere((item) => item.id == query.id));
      showToast(
        context,
        AppStrings.t(AppStringKeys.chatInputBarGuestQueryAnswered),
      );
    } catch (error) {
      _showBotPlatformFailure(error);
    }
  }

  Future<void> _updateBotAutomationStatus() async {
    final pendingText = await _promptBotText(
      title: AppStrings.t(AppStringKeys.chatInputBarAutomationStatus),
      label: AppStrings.t(AppStringKeys.chatInputBarPendingUpdateCount),
      initialValue: '0',
      actionLabel: AppStrings.t(AppStringKeys.chatInputBarNextAction),
      keyboardType: TextInputType.number,
    );
    if (pendingText == null) return;
    final pendingCount = int.tryParse(pendingText);
    if (pendingCount == null || pendingCount < 0) {
      if (mounted) {
        showToast(
          context,
          AppStrings.t(AppStringKeys.chatInputBarEnterANonNegativeUpdateCount),
        );
      }
      return;
    }
    final errorMessage = await _promptBotText(
      title: AppStrings.t(AppStringKeys.chatInputBarAutomationStatus),
      label: AppStrings.t(AppStringKeys.chatInputBarErrorMessageOptional),
      actionLabel: AppStrings.t(AppStringKeys.chatInputBarReportAction),
      allowEmpty: true,
    );
    if (errorMessage == null) return;
    try {
      await _botPlatform.updateBotAutomationStatus(
        pendingUpdateCount: pendingCount,
        errorMessage: errorMessage,
      );
      if (mounted) {
        showToast(
          context,
          AppStrings.t(AppStringKeys.chatInputBarAutomationStatusUpdated),
        );
      }
    } catch (error) {
      _showBotPlatformFailure(error);
    }
  }

  Future<String?> _promptBotText({
    required String title,
    required String label,
    required String actionLabel,
    String initialValue = '',
    bool allowEmpty = false,
    TextInputType? keyboardType,
  }) => showAppTextEntryDialog(
    context,
    title: title,
    label: label,
    actionLabel: actionLabel,
    initial: initialValue,
    allowEmpty: allowEmpty,
    keyboardType: keyboardType,
  );

  void _showBotPlatformFailure(Object error) {
    if (!mounted) return;
    final detail = error is TdError
        ? error.message
        : AppStrings.t(AppStringKeys.chatInputBarActionFailed);
    showToast(context, detail);
  }

  Widget _senderOptionRow(MessageSenderOption option) {
    final c = context.colors;
    final selected =
        vm.selectedMessageSender?.sameSender(option.sender) == true;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: option.needsPremium
          ? null
          : () {
              Navigator.of(context).pop();
              vm.selectMessageSender(option);
            },
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              PhotoAvatar(title: option.title, photo: option.photo, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  option.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, color: c.textPrimary),
                ),
              ),
              if (option.needsPremium)
                Text(
                  AppStringKeys.premiumLabel.l10n(context),
                  style: TextStyle(fontSize: 13, color: AppTheme.brand),
                )
              else if (selected)
                AppIcon(HeroAppIcons.check, size: 18, color: AppTheme.brand),
            ],
          ),
        ),
      ),
    );
  }

  _ReplyKeyboard? _activeReplyKeyboard() {
    for (final message in vm.messages.reversed) {
      if (message.buttonRows.isEmpty) continue;
      final rows = message.buttonRows
          .map((row) => row.where((button) => button.isReplyKeyboard).toList())
          .where((row) => row.isNotEmpty)
          .toList();
      if (rows.isNotEmpty) return _ReplyKeyboard(message: message, rows: rows);
    }
    return null;
  }

  MessageButton? _webAppButton(_ReplyKeyboard? keyboard) {
    if (keyboard == null) return null;
    for (final row in keyboard.rows) {
      for (final button in row) {
        if (button.isWebApp && (button.url?.isNotEmpty ?? false)) {
          return button;
        }
      }
    }
    return null;
  }

  Future<void> _openReplyKeyboardWebApp(
    _ReplyKeyboard keyboard,
    MessageButton button,
  ) async {
    final url = button.url;
    if (url == null || url.isEmpty) return;
    final botUserId = await vm.webAppBotUserId(keyboard.message);
    if (!mounted) return;
    if (botUserId == null) {
      showToast(context, AppStrings.t(AppStringKeys.miniAppCannotStart));
      return;
    }
    final opened = await openTelegramMiniApp(
      context,
      chatId: vm.chatId,
      botUserId: botUserId,
      url: url,
      title: button.text,
      keyboardButtonText: button.text,
    );
    if (!opened && mounted) {
      showToast(context, AppStrings.t(AppStringKeys.miniAppCannotStart));
    }
  }

  void _pressReplyKeyboardButton(
    _ReplyKeyboard keyboard,
    MessageButton button,
  ) {
    if (button.isWebApp) {
      unawaited(_openReplyKeyboardWebApp(keyboard, button));
      return;
    }
    if (button.type == 'keyboardButtonTypeText') {
      vm.sendKeyboardButtonText(button.text);
      widget.onMessageSent();
      return;
    }
    if (button.type == 'keyboardButtonTypeRequestManagedBot') {
      final managerBotUserId = vm.peerUserId;
      if (managerBotUserId != null) {
        unawaited(
          _createManagedBot(
            managerBotUserId,
            suggestedName: button.suggestedName ?? '',
            suggestedUsername: button.suggestedUsername ?? '',
          ),
        );
        return;
      }
    }
    showToast(context, AppStringKeys.chatButtonUnsupported);
  }

  void _toggleReplyKeyboard() {
    setState(() {
      _replyKeyboardVisible = !_replyKeyboardVisible;
      if (_replyKeyboardVisible) {
        _panel = _Panel.none;
        _quickReplyContextVisible = false;
      }
    });
    widget.onPanelGeometryChanged?.call();
    if (_replyKeyboardVisible) _focus.unfocus();
  }

  void _handleEmptyInputTap() {
    if (_hasText || !_canUseQuickReplies || _replyKeyboardVisible) return;
    if (_quickReplyContextVisible) {
      setState(() => _quickReplyContextVisible = false);
      return;
    }
    if (_quickRepliesLoaded) {
      if (_quickReplies.isEmpty) return;
      _focus.unfocus();
      setState(() => _quickReplyContextVisible = true);
      return;
    }
    unawaited(_loadQuickReplies(userInitiated: true));
  }

  Future<List<BusinessQuickReplyShortcut>> _fetchQuickReplies() async {
    final injected = widget.quickReplyLoader;
    if (injected != null) return injected();
    return BusinessQuickReplyService.shared.preloadShortcuts();
  }

  Future<void> _loadQuickReplies({required bool userInitiated}) async {
    if (_quickRepliesLoaded || !_canUseQuickReplies) return;
    try {
      final replies = await _fetchQuickReplies();
      if (!mounted) return;
      setState(() {
        _quickReplies = replies;
        _quickRepliesLoaded = true;
        _quickReplyContextVisible =
            userInitiated && replies.isNotEmpty && _canUseQuickReplies;
      });
      if (userInitiated && replies.isNotEmpty) _focus.unfocus();
    } catch (error) {
      if (!mounted) return;
      setState(() => _quickReplyContextVisible = false);
      if (userInitiated) {
        showToast(
          context,
          AppStrings.t(
            AppStringKeys.businessToolsCouldNotLoadQuickRepliesValue1,
            {'value1': error},
          ),
        );
        _restoreKeyboardFocus();
      }
    }
  }

  Future<void> _sendQuickReply(BusinessQuickReplyShortcut shortcut) async {
    if (_quickReplySendingId != null) return;
    setState(() => _quickReplySendingId = shortcut.id);
    try {
      final injected = widget.quickReplySender;
      if (injected != null) {
        await injected(vm.chatId, shortcut.id);
      } else {
        await BusinessQuickReplyService.shared.send(vm.chatId, shortcut.id);
      }
      if (!mounted) return;
      setState(() {
        _quickReplySendingId = null;
        _quickReplyContextVisible = false;
      });
      widget.onMessageSent();
    } catch (error) {
      if (!mounted) return;
      setState(() => _quickReplySendingId = null);
      showToast(
        context,
        AppStrings.t(AppStringKeys.businessToolsCouldNotSendQuickReplyValue1, {
          'value1': error,
        }),
      );
    }
  }

  Widget _quickReplyContextMenu() {
    if (_quickReplies.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final height = math.min(44 + (_quickReplies.length * 58), 276).toDouble();
    return Container(
      key: const ValueKey('quickReplyContextMenu'),
      height: height,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.divider.withValues(alpha: 0.72)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  AppIcon(
                    HeroAppIcons.solidMessage,
                    size: 17,
                    color: AppTheme.brand,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      AppStrings.t(AppStringKeys.businessToolsQuickReplies),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  GestureDetector(
                    key: const ValueKey('closeQuickReplyContextMenu'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _quickReplyContextVisible = false),
                    child: SizedBox(
                      width: 34,
                      height: 34,
                      child: Center(
                        child: AppIcon(
                          HeroAppIcons.xmark,
                          size: 18,
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _quickReplies.length,
              itemBuilder: (context, index) {
                final shortcut = _quickReplies[index];
                final sending = _quickReplySendingId == shortcut.id;
                return GestureDetector(
                  key: ValueKey('quickReply-${shortcut.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: sending
                      ? null
                      : () => unawaited(_sendQuickReply(shortcut)),
                  child: Container(
                    height: 58,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: c.divider.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '/${shortcut.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: c.textPrimary,
                                ),
                              ),
                              if (shortcut.preview.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  shortcut.preview,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: c.textSecondary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (sending)
                          AppActivityIndicator(size: 18, color: AppTheme.brand)
                        else
                          AppIcon(
                            HeroAppIcons.paperPlane,
                            size: 18,
                            color: AppTheme.brand,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _inputRow(_ReplyKeyboard? replyKeyboard) {
    final c = context.colors;
    final editing = vm.editingMessage != null;
    final hasText =
        _hasText || editing || _pendingClipboardAttachments.isNotEmpty;
    final sender = vm.selectedMessageSender;
    final webAppButton = editing ? null : _webAppButton(replyKeyboard);
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 8, bottom: 6),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (webAppButton != null && replyKeyboard != null) ...[
                _replyKeyboardMiniAppAction(replyKeyboard, webAppButton),
                const SizedBox(width: 8),
              ] else if (!editing &&
                  (vm.peerIsBot || _guestQueries.isNotEmpty)) ...[
                Semantics(
                  button: true,
                  label: AppStrings.t(AppStringKeys.chatInputBarOpenBotMenu),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _showBotMenu,
                    onLongPress: () => _showBotMenu(forceMenu: true),
                    child: Container(
                      width: 36,
                      height: 36,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: c.searchFill,
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      alignment: Alignment.center,
                      child: AppIcon(
                        HeroAppIcons.bot,
                        size: 20,
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      child: Container(
                        key: const ValueKey('composerTextInputBox'),
                        decoration: BoxDecoration(
                          color: c.searchFill,
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          crossAxisAlignment: hasText
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.center,
                          children: [
                            if (!editing &&
                                vm.canChooseMessageSender &&
                                sender != null) ...[
                              GestureDetector(
                                key: const ValueKey('composerSenderPicker'),
                                behavior: HitTestBehavior.opaque,
                                onTap: _showSenderPicker,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    PhotoAvatar(
                                      title: sender.title,
                                      photo: sender.photo,
                                      size: 28,
                                    ),
                                    const SizedBox(width: 2),
                                    AppIcon(
                                      HeroAppIcons.chevronDown,
                                      size: 16,
                                      color: c.textTertiary,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Shortcuts(
                                shortcuts: widget.enterToSend
                                    ? const {
                                        SingleActivator(
                                          LogicalKeyboardKey.enter,
                                        ): _SendComposerIntent(),
                                        SingleActivator(
                                          LogicalKeyboardKey.numpadEnter,
                                        ): _SendComposerIntent(),
                                        SingleActivator(
                                          LogicalKeyboardKey.enter,
                                          control: true,
                                        ): _InsertComposerLineBreakIntent(),
                                        SingleActivator(
                                          LogicalKeyboardKey.numpadEnter,
                                          control: true,
                                        ): _InsertComposerLineBreakIntent(),
                                      }
                                    : const {
                                        SingleActivator(
                                          LogicalKeyboardKey.enter,
                                        ): _InsertComposerLineBreakIntent(),
                                        SingleActivator(
                                          LogicalKeyboardKey.numpadEnter,
                                        ): _InsertComposerLineBreakIntent(),
                                        SingleActivator(
                                          LogicalKeyboardKey.enter,
                                          control: true,
                                        ): _SendComposerIntent(),
                                        SingleActivator(
                                          LogicalKeyboardKey.numpadEnter,
                                          control: true,
                                        ): _SendComposerIntent(),
                                      },
                                child: Actions(
                                  actions: {
                                    PasteTextIntent:
                                        CallbackAction<PasteTextIntent>(
                                          onInvoke: (_) {
                                            unawaited(_handlePaste());
                                            return null;
                                          },
                                        ),
                                    _SendComposerIntent: _SendComposerAction(
                                      canInvoke: () =>
                                          !_hasActiveTextComposition,
                                      onInvoke: () =>
                                          unawaited(_sendCurrentText()),
                                    ),
                                    _InsertComposerLineBreakIntent:
                                        CallbackAction<
                                          _InsertComposerLineBreakIntent
                                        >(
                                          onInvoke: (_) {
                                            _insertComposerLineBreak();
                                            return null;
                                          },
                                        ),
                                  },
                                  child: TextField(
                                    controller: _controller,
                                    focusNode: _focus,
                                    onTap: _handleEmptyInputTap,
                                    minLines: 1,
                                    maxLines: 4,
                                    keyboardType: TextInputType.multiline,
                                    textInputAction: widget.enterToSend
                                        ? TextInputAction.send
                                        : TextInputAction.newline,
                                    onSubmitted: widget.enterToSend
                                        ? (_) => unawaited(_sendCurrentText())
                                        : null,
                                    inputFormatters:
                                        widget.enterToSend &&
                                            Theme.of(context).platform ==
                                                TargetPlatform.android
                                        ? [
                                            _ComposerEnterToSendFormatter(
                                              onSend: _scheduleKeyboardSend,
                                            ),
                                          ]
                                        : null,
                                    style: TextStyle(
                                      fontSize: AppTextSize.messageBody(
                                        Theme.of(context).platform,
                                      ),
                                      color: c.textPrimary,
                                    ),
                                    contentInsertionConfiguration: editing
                                        ? null
                                        : ContentInsertionConfiguration(
                                            allowedMimeTypes: _imageMimeTypes,
                                            onContentInserted:
                                                _handleInsertedContent,
                                          ),
                                    contextMenuBuilder:
                                        (
                                          BuildContext context,
                                          EditableTextState editableTextState,
                                        ) {
                                          ContextMenuButtonItem? originalPaste;
                                          final items =
                                              <ContextMenuButtonItem>[];
                                          for (final item
                                              in editableTextState
                                                  .contextMenuButtonItems) {
                                            if (item.type ==
                                                ContextMenuButtonType.paste) {
                                              originalPaste = item;
                                            } else {
                                              items.add(item);
                                            }
                                          }
                                          final paste = ContextMenuButtonItem(
                                            type: ContextMenuButtonType.paste,
                                            label:
                                                originalPaste?.label ??
                                                MaterialLocalizations.of(
                                                  context,
                                                ).pasteButtonLabel,
                                            onPressed: () => unawaited(
                                              _handlePaste(originalPaste),
                                            ),
                                          );
                                          final copyIndex = items.indexWhere(
                                            (item) =>
                                                item.type ==
                                                ContextMenuButtonType.copy,
                                          );
                                          final pasteIndex = copyIndex < 0
                                              ? 0
                                              : copyIndex + 1;
                                          items.insert(pasteIndex, paste);
                                          final selection =
                                              _controller.selection;
                                          if (selection.isValid &&
                                              !selection.isCollapsed) {
                                            items.insert(
                                              pasteIndex + 1,
                                              ContextMenuButtonItem(
                                                label: AppStringKeys
                                                    .composerFormat
                                                    .l10n(context),
                                                onPressed: () => unawaited(
                                                  _showComposerFormatMenu(
                                                    editableTextState,
                                                  ),
                                                ),
                                              ),
                                            );
                                          }
                                          return AdaptiveTextSelectionToolbar.buttonItems(
                                            anchors: editableTextState
                                                .contextMenuAnchors,
                                            buttonItems: items,
                                          );
                                        },
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      isCollapsed: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (!hasText && replyKeyboard != null)
                              Semantics(
                                button: true,
                                label: _replyKeyboardVisible
                                    ? 'Hide bot keyboard'
                                    : 'Show bot keyboard',
                                child: GestureDetector(
                                  key: const ValueKey(
                                    'composerReplyKeyboardToggle',
                                  ),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _toggleReplyKeyboard,
                                  child: SizedBox(
                                    width: 32,
                                    height: 24,
                                    child: Center(
                                      child: AppIcon(
                                        _replyKeyboardVisible
                                            ? HeroAppIcons.chevronDown
                                            : HeroAppIcons.tableCells,
                                        size: _replyKeyboardVisible ? 22 : 23,
                                        color: c.textSecondary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (!hasText && vm.messageAutoDeleteTime > 0) ...[
                              const SizedBox(width: 4),
                              _autoDeleteInputIndicator(),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!editing &&
                      vm.canUseAiComposition &&
                      _aiDraftEligible) ...[
                    Semantics(
                      button: true,
                      label: AppStringKeys.telegramAiEditorTelegramAIEditor
                          .l10n(context),
                      child: GestureDetector(
                        key: const ValueKey('composerAiPrefixButton'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => unawaited(_openTelegramAiEditor()),
                        child: Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppTheme.brand.withValues(alpha: 0.10),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppTheme.brand.withValues(alpha: 0.34),
                              width: 0.75,
                            ),
                          ),
                          child: AppIcon(
                            HeroAppIcons.palette,
                            key: const ValueKey('composerAiStyleIcon'),
                            size: 19,
                            color: AppTheme.brand,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  AppInteractiveSurface(
                    key: const ValueKey('composerSendButton'),
                    semanticLabel:
                        (editing
                                ? AppStringKeys.messageActionEdit
                                : AppStringKeys.composerSend)
                            .l10n(context),
                    enabled: true,
                    onTap: () => unawaited(_sendCurrentText()),
                    onLongPress: editing
                        ? null
                        : () => unawaited(_showTextSendOptions()),
                    borderRadius: BorderRadius.circular(24),
                    child: SizedBox(
                      width: vm.requiresPaidMessage ? 58 : 44,
                      height: 44,
                      child: Center(
                        child: Container(
                          width: vm.requiresPaidMessage ? 58 : 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: editing
                                ? AppTheme.cloverGreen
                                : AppTheme.brand,
                            shape: BoxShape.circle,
                          ),
                          child: editing
                              ? const AppIcon(
                                  HeroAppIcons.check,
                                  size: 18,
                                  color: Colors.white,
                                )
                              : vm.requiresPaidMessage
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const AppIcon(
                                      HeroAppIcons.solidStar,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      'x${vm.paidMessageStarCount}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                )
                              : const AppIcon(
                                  HeroAppIcons.solidPaperPlane,
                                  size: 17,
                                  color: Colors.white,
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool get _hasActiveTextComposition {
    final composing = _controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  void _insertComposerLineBreak() {
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final text = value.text.replaceRange(start, end, '\n');
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  Widget _autoDeleteInputIndicator() {
    final label = AppLocalizations.of(context).t(
      AppStringKeys.chatAutoDeleteCountdown,
      {'value1': TDParse.formatDuration(vm.messageAutoDeleteTime)},
    );
    return Semantics(
      key: const ValueKey('composerAutoDeleteIndicator'),
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showToast(context, label),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: AppIcon(
              HeroAppIcons.stopwatch,
              size: 18,
              color: context.colors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _replyKeyboardMiniAppAction(
    _ReplyKeyboard keyboard,
    MessageButton button,
  ) {
    final colors = _replyKeyboardButtonColors(button, prominent: true);
    return Semantics(
      button: true,
      label: button.text,
      child: GestureDetector(
        key: const ValueKey('composerReplyKeyboardMiniAppAction'),
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_openReplyKeyboardWebApp(keyboard, button)),
        onLongPress: () => _showBotMenu(forceMenu: true),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 156),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: colors.border, width: 2),
            ),
            child: BotButtonLabel(
              button: button,
              color: colors.foreground,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  ({Color background, Color foreground, Color border})
  _replyKeyboardButtonColors(MessageButton button, {required bool prominent}) {
    final c = context.colors;
    return botButtonPalette(
      button.style,
      primary: AppTheme.brand,
      standard: prominent
          ? (
              background: AppTheme.brand,
              foreground: Colors.white,
              border: c.inputBarBackground.withValues(alpha: 0.72),
            )
          : (background: c.card, foreground: c.textPrimary, border: c.divider),
    );
  }

  Widget _replyKeyboardButtonCell(
    _ReplyKeyboard keyboard,
    MessageButton button,
  ) {
    final colors = _replyKeyboardButtonColors(button, prominent: false);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _pressReplyKeyboardButton(keyboard, button),
      child: Container(
        key: ValueKey('reply-keyboard-button-${button.text}'),
        height: 48,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: colors.border, width: 0.5),
        ),
        child: BotButtonLabel(
          button: button,
          color: colors.foreground,
          fontSize: AppTextSize.body,
          fontWeight: FontWeight.w500,
          iconSize: 19,
        ),
      ),
    );
  }

  Widget _replyKeyboardPanel(_ReplyKeyboard keyboard) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(maxHeight: 330),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: c.panelBackground,
        border: Border(top: BorderSide(color: c.divider, width: 0.5)),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (final row in keyboard.rows) ...[
              Row(
                children: [
                  for (var index = 0; index < row.length; index++) ...[
                    Expanded(
                      child: _replyKeyboardButtonCell(keyboard, row[index]),
                    ),
                    if (index < row.length - 1) const SizedBox(width: 8),
                  ],
                ],
              ),
              if (!identical(row, keyboard.rows.last))
                const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }


  Widget _iconStrip() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          if (_canSendVoiceNotes)
            _icon(
              HeroAppIcons.microphone,
              AppStrings.t(AppStringKeys.composerHoldToTalk),
              _panel == _Panel.voice,
              _toggleVoice,
            ),
          _icon(
            HeroAppIcons.image,
            AppStrings.t(AppStringKeys.composerImage),
            false,
            _pickPhotos,
          ),
          if (Platform.isAndroid || Platform.isIOS)
            _icon(
              HeroAppIcons.camera,
              AppStrings.t(AppStringKeys.composerCamera),
              false,
              _takePhoto,
            ),
          _icon(
            HeroAppIcons.grip,
            AppStrings.t(AppStringKeys.composerStickers),
            _panel == _Panel.sticker,
            () {
              _toggle(_Panel.sticker);
              if (_panel == _Panel.sticker) {
                StickerStore.shared.loadIfNeeded();
                GifStore.shared.loadIfNeeded();
                if (_isPanelSearchSelected &&
                    _panelSearch.text.trim().isNotEmpty) {
                  _queuePanelSearch();
                }
              }
            },
          ),
          _icon(
            HeroAppIcons.solidFaceSmile,
            AppStrings.t(AppStringKeys.composerEmoji),
            _panel == _Panel.emoji,
            () {
              _toggle(_Panel.emoji);
              if (_panel == _Panel.emoji) {
                EmojiStore.shared.loadIfNeeded();
                if (_isPanelSearchSelected &&
                    _panelSearch.text.trim().isNotEmpty) {
                  _queuePanelSearch();
                }
              }
            },
          ),
          _icon(
            _panel != _Panel.none
                ? HeroAppIcons.xmark
                : HeroAppIcons.circlePlus,
            AppStrings.t(
              _panel != _Panel.none
                  ? AppStringKeys.composerCloseMenu
                  : AppStringKeys.composerOpenMenu,
            ),
            _panel == _Panel.function,
            () => _toggle(_Panel.function),
          ),
        ],
      ),
    );
  }

  Widget _icon(
    AppIconData icon,
    String semanticLabel,
    bool active,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: AppInteractiveSurface(
        semanticLabel: semanticLabel,
        selected: active,
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: SizedBox(
          height: 40,
          child: Center(
            child: AppIcon(
              icon,
              size: 24,
              color: active ? AppTheme.brand : context.colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }


  Future<void> _pickPhotos() async {
    try {
      final selection = await AppAssetPicker.pickDetailed(
        context,
        type: AppAssetPickerType.imageAndVideo,
        maxAssets: 10,
        sendOptions: AppAssetSendOptions(),
      );
      if (!mounted) return;
      if (selection.failedCount > 0) {
        showToast(
          context,
          AppStrings.t(AppStringKeys.composerOpenAttachmentFailed, {
            'value1': AppStrings.t(AppStringKeys.composerImage),
          }),
        );
      }
      final attachments = selection.assets
          .map((asset) {
            final file = asset.file;
            final kind = galleryAttachmentKind(
              sendAsFile: false,
              isVideo: isPickedAssetVideo(file),
              isAnimation: isPickedAssetGif(file),
            );
            return OutgoingAttachment(
              path: file.path,
              kind: kind,
              fileName: asset.originalFile?.name ?? file.name,
              originalPath: asset.originalFile?.path,
              previewBytes: asset.thumbnailBytes,
              width: asset.width,
              height: asset.height,
            );
          })
          .toList(growable: false);
      if (attachments.isEmpty) return;
      await _previewAndSendAttachments(attachments);
    } catch (error, stackTrace) {
      debugPrint('Failed to send selected media: $error\n$stackTrace');
      _pickFailed(AppStrings.t(AppStringKeys.composerImage));
    }
  }

  Future<void> _takePhoto() async {
    try {
      final capture = await captureComposerPhoto(
        context,
        saveToAlbum: context.read<ThemeController>().saveCapturedPhotosToAlbum,
      );
      if (capture == null || !mounted) return;
      if (capture.albumWriteFailed) {
        showToast(
          context,
          capture.albumResult == MediaLibrarySaveResult.permissionDenied
              ? AppStringKeys.chatSaveToPhotosPermissionDenied
              : AppStringKeys.chatSaveToPhotosFailed,
        );
      }
      final path = capture.file.path;
      final isVideo = _isVideoPath(path);
      if (isVideo) {
        final attachment = await resolveAttachmentDimensions(
          OutgoingAttachment(path: path, kind: OutgoingAttachmentKind.video),
        );
        await widget.vm.sendAttachments([attachment]);
        widget.onMessageSent();
        return;
      }
      final edited = await _editImage(path);
      if (edited != null) {
        final attachment = await resolveAttachmentDimensions(
          OutgoingAttachment(
            path: edited.path,
            kind: OutgoingAttachmentKind.photo,
          ),
        );
        await widget.vm.sendAttachments([attachment], caption: edited.caption);
        widget.onMessageSent();
      }
    } catch (_) {
      _pickFailed(AppStrings.t(AppStringKeys.composerCamera));
    }
  }

  bool _isVideoPath(String path) {
    final ext = path.toLowerCase();
    return ext.endsWith('.mp4') ||
        ext.endsWith('.mov') ||
        ext.endsWith('.m4v') ||
        ext.endsWith('.webm') ||
        ext.endsWith('.avi');
  }

  Future<ImageEditResult?> _editImage(
    String path, {
    String initialCaption = '',
  }) {
    return Navigator.of(context).push<ImageEditResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            ImageEditView(sourcePath: path, initialCaption: initialCaption),
      ),
    );
  }

  void _handleInsertedContent(KeyboardInsertedContent content) {
    unawaited(_sendInsertedImage(content));
  }

  Future<void> _sendInsertedImage(KeyboardInsertedContent content) async {
    if (!content.mimeType.toLowerCase().startsWith('image/')) return;
    var data = content.data;
    var mimeType = content.mimeType;
    if (data == null || data.isEmpty) {
      final image = await _readInsertedImage(content.uri, content.mimeType);
      data = image?.data;
      mimeType = image?.mimeType ?? mimeType;
    }
    if (data == null || data.isEmpty) {
      if (mounted) {
        showToast(
          context,
          AppStrings.t(AppStringKeys.composerPastedImageReadFailed),
        );
      }
      return;
    }
    await _queueClipboardImageData(
      ClipboardImageData(data: data, mimeType: mimeType),
    );
  }

  Future<_ClipboardImage?> _readInsertedImage(
    String uri,
    String mimeType,
  ) async {
    if (uri.isEmpty) return null;
    try {
      final image = await _clipboardChannel.invokeMapMethod<String, dynamic>(
        'readImageUri',
        <String, dynamic>{'uri': uri, 'mimeType': mimeType},
      );
      final data = image?['data'];
      if (data is! Uint8List || data.isEmpty) return null;
      return (
        data: data,
        mimeType: (image?['mimeType'] as String?) ?? mimeType,
      );
    } catch (_) {
      return null;
    }
  }

  Future<_ClipboardImage?> _readClipboardImage() async {
    try {
      final image = await _clipboardChannel.invokeMapMethod<String, dynamic>(
        'readImage',
      );
      final data = image?['data'];
      if (data is! Uint8List || data.isEmpty) return null;
      final mimeType = (image?['mimeType'] as String?) ?? 'image/png';
      return (data: data, mimeType: mimeType);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _queueClipboardImageData(ClipboardImageData image) async {
    final remaining =
        _maximumPendingClipboardAttachments -
        _pendingClipboardAttachments.length;
    if (remaining <= 0) {
      if (mounted) _showClipboardAttachmentLimit();
      return true;
    }
    try {
      final result = await ClipboardImageService.storeImages([
        image,
      ], limit: remaining);
      if (!mounted) return false;
      return _applyClipboardImageReadResult(result, remaining: remaining);
    } catch (error, stackTrace) {
      debugPrint('Failed to store pasted image: $error\n$stackTrace');
      if (mounted) {
        showToast(
          context,
          AppStrings.t(AppStringKeys.composerPastedImageReadFailed),
        );
      }
      return false;
    }
  }

  bool _applyClipboardImageReadResult(
    ClipboardImageReadResult result, {
    required int remaining,
  }) {
    if (result.availableImageCount == 0) return false;
    if (result.failedImageCount > 0) {
      showToast(
        context,
        AppStrings.t(AppStringKeys.composerPastedImageReadFailed),
      );
    }
    if (result.availableImageCount > remaining) {
      _showClipboardAttachmentLimit();
    }
    if (result.attachments.isNotEmpty) {
      setState(() {
        _pendingClipboardAttachments.addAll(result.attachments);
        _panel = _Panel.none;
        _replyKeyboardVisible = false;
        _quickReplyContextVisible = false;
      });
      widget.onPanelGeometryChanged?.call();
    }
    _restoreKeyboardFocus();
    return true;
  }

  void _showClipboardAttachmentLimit() {
    showToast(
      context,
      AppStrings.t(AppStringKeys.composerMediaSelectionLimit, {
        'value1': _maximumPendingClipboardAttachments,
      }),
    );
  }

  Future<void> _previewAndSendAttachments(
    List<OutgoingAttachment> attachments,
  ) async {
    final MediaSendPreviewResult? preview;
    if (widget.mediaSendPreviewLauncher case final launcher?) {
      preview = await launcher(attachments);
    } else {
      final resolved = await resolveAttachmentListDimensions(attachments);
      if (!mounted) return;
      preview = await Navigator.of(context).push<MediaSendPreviewResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => MediaSendPreviewView(
            attachments: resolved,
            allowWhenOnline: widget.vm.canSendWhenOnline,
            effects: widget.vm.availableMessageEffects,
          ),
        ),
      );
    }
    if (!mounted || preview == null || preview.attachments.isEmpty) return;
    final finalAttachments = await resolveAttachmentListDimensions(
      preview.attachments,
    );
    await widget.vm.sendAttachments(
      finalAttachments,
      caption: preview.caption,
      sendConfiguration: preview.sendConfiguration,
    );
    widget.onMessageSent();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      final attachments = result?.files
          .map((file) => file.path)
          .whereType<String>()
          .take(10)
          .map(
            (path) => OutgoingAttachment(
              path: path,
              kind: OutgoingAttachmentKind.document,
            ),
          )
          .toList();
      if (attachments == null || attachments.isEmpty) return;
      await widget.vm.sendAttachments(attachments);
      widget.onMessageSent();
    } catch (_) {
      _pickFailed(AppStrings.t(AppStringKeys.topicPostContentFile));
    }
  }

  Future<void> _sendLocation() async {
    final start = await resolveLocationPickerStart();
    if (!mounted) return;
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(builder: (_) => LocationPickerView(initial: start)),
    );
    if (picked != null) {
      widget.vm.sendLocation(picked.latitude, picked.longitude);
      widget.onMessageSent();
    }
  }

  Future<void> _sendContact() async {
    final contact = await Navigator.of(context).push<MessageContactCard>(
      MaterialPageRoute(builder: (_) => const ContactSharePickerView()),
    );
    if (!mounted || contact == null) return;
    final sent = await widget.vm.sendContact(contact);
    if (!mounted) return;
    if (sent) {
      widget.onMessageSent();
    } else {
      showToast(context, AppStringKeys.topicPostContentActionFailed);
    }
  }

  Future<void> _createPoll() async {
    final maxOptions = await widget.vm.pollAnswerCountMax();
    if (!mounted) return;
    final result = await Navigator.of(context).push<PollComposerResult>(
      MaterialPageRoute(
        builder: (_) => PollComposerView(maxOptions: maxOptions),
      ),
    );
    if (!mounted || result == null) return;
    final sent = await widget.vm.sendPoll(result);
    if (!mounted) return;
    if (sent) {
      widget.onMessageSent();
    } else {
      showToast(context, AppStringKeys.topicPostContentActionFailed);
    }
  }

  Future<void> _pickLocalAudio() async {
    try {
      final preferred = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const [
          'mp3',
          'm4a',
          'aac',
          'flac',
          'wav',
          'ogg',
          'opus',
          'amr',
        ],
      );
      final result =
          preferred ?? await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null) return;
      final attachments = result.files
          .map((file) => file.path)
          .whereType<String>()
          .take(10)
          .map(
            (path) => OutgoingAttachment(
              path: path,
              kind: OutgoingAttachmentKind.audio,
            ),
          )
          .toList();
      if (attachments.isEmpty) return;
      await widget.vm.sendAttachments(attachments);
      widget.onMessageSent();
    } catch (_) {
      _pickFailed(AppStrings.t(AppStringKeys.composerAudio));
    }
  }

  Future<void> _pickAudio() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AudioSearchView(
          onSend: (sourceChatId, message) async {
            await widget.vm.sendAudioFromMessage(sourceChatId, message);
            widget.onMessageSent();
          },
          onPickLocal: _pickLocalAudio,
        ),
      ),
    );
  }

  Future<void> _createChecklist() async {
    final result = await Navigator.of(context).push<ChecklistComposerResult>(
      MaterialPageRoute(builder: (_) => const ChecklistComposerView()),
    );
    if (result == null) return;
    if (result.title.isEmpty || result.tasks.isEmpty) return;
    widget.vm.sendChecklist(result);
    widget.onMessageSent();
  }

  Future<void> _createSuggestedPost() async {
    final loader = ChannelDirectMessageTopicController(
      chatId: vm.chatId,
      topicId: 0,
    );
    try {
      final limits = await loader.loadLimits();
      if (!mounted) return;
      final draft = await showAppModalSheet<SuggestedPostDraft>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => SuggestedPostComposerSheet(limits: limits),
      );
      if (draft == null || !mounted) return;
      await vm.sendSuggestedPost(
        text: draft.text,
        attachment: draft.attachment,
        price: draft.price,
        sendDate: draft.sendDate,
      );
      widget.onMessageSent();
    } catch (error) {
      if (mounted) showToast(context, error.toString());
    } finally {
      loader.dispose();
    }
  }


  Widget _functionPanel() {
    final items = [
      if (widget.showCallAction)
        (
          HeroAppIcons.phone.data,
          AppStrings.t(
            vm.isGroup
                ? AppStringKeys.composerGroupVoiceCall
                : AppStringKeys.composerVoiceCall,
          ),
          () => widget.onStartCall(false),
        ),
      (
        HeroAppIcons.locationDot.data,
        AppStrings.t(AppStringKeys.composerLocation),
        _sendLocation,
      ),
      (
        HeroAppIcons.idBadge.data,
        AppStrings.t(AppStringKeys.composerContact),
        _sendContact,
      ),
      (
        HeroAppIcons.solidFolder.data,
        AppStrings.t(AppStringKeys.topicPostContentFile),
        _pickFile,
      ),
      if (!vm.isDirectMessagesGroup)
        (
          HeroAppIcons.grip.data,
          AppStrings.t(AppStringKeys.composerPoll),
          _createPoll,
        ),
      (
        HeroAppIcons.music.data,
        AppStrings.t(AppStringKeys.composerAudio),
        _pickAudio,
      ),
      if (!vm.isDirectMessagesGroup)
        (
          HeroAppIcons.listCheck.data,
          AppStrings.t(AppStringKeys.composerChecklist),
          _createChecklist,
        ),
      if (vm.isDirectMessagesGroup && !vm.isAdministeredDirectMessagesGroup)
        (
          HeroAppIcons.penToSquare.data,
          AppStrings.t(AppStringKeys.suggestedPostComposerTitle),
          _createSuggestedPost,
        ),
      (
        HeroAppIcons.clock.data,
        AppStrings.t(AppStringKeys.messageSendOptionsScheduledMessages),
        _openScheduledMessages,
      ),
    ];
    final c = context.colors;
    return Container(
      key: const ValueKey('composerFunctionPanel'),
      width: double.infinity,
      color: c.panelBackground,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      child: IconGrid(
        perRow: 5,
        children: [
          for (final item in items)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _setPanel(_Panel.none);
                item.$3();
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(item.$1, size: 22, color: c.textPrimary),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.$2.l10n(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: c.textSecondary),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }


  Widget _emojiPanel() {
    final c = context.colors;
    return Container(
      height: 326,
      color: c.panelBackground,
      child: Column(
        children: [
          _emojiTabStrip(),
          if (_emojiTab == _emojiSearchTab) _panelSearchField(),
          Expanded(child: _emojiContent()),
        ],
      ),
    );
  }

  Widget _emojiContent() {
    if (_emojiTab == _emojiSearchTab) {
      if (_panelSearch.text.trim().isEmpty) return const SizedBox.shrink();
      return _emojiSearchContent();
    }
    final store = EmojiStore.shared;
    if (_emojiTab != 'standard') {
      final id = int.tryParse(_emojiTab);
      CustomEmojiPack? pack;
      for (final p in store.customPacks) {
        if (p.id == id) {
          pack = p;
          break;
        }
      }
      if (pack != null) {
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 8,
          ),
          itemCount: pack.emoji.length,
          itemBuilder: (context, index) {
            final item = pack!.emoji[index];
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  _controller.insertCustomEmoji(item.customEmojiId, item.emoji),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: item.customEmojiId != 0
                    ? CustomEmojiView(
                        id: item.customEmojiId,
                        size: 34,
                        color: context.colors.textPrimary,
                      )
                    : const SizedBox(),
              ),
            );
          },
        );
      }
    }
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        for (final category in EmojiCatalog.categories) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(left: 14, top: 6, bottom: 2),
              child: Text(
                category.name.l10n(context),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: context.colors.textSecondary,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final emoji = category.emojis[index];
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _controller.insertText(emoji),
                  child: Center(
                    child: Text(emoji, style: const TextStyle(fontSize: 26)),
                  ),
                );
              }, childCount: category.emojis.length),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ],
    );
  }

  Widget _panelSearchField() {
    final c = context.colors;
    return Container(
      key: const ValueKey('composerMediaSearch'),
      height: 42,
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.searchFill,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        children: [
          AppIcon(
            HeroAppIcons.magnifyingGlass,
            size: 17,
            color: c.textTertiary,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: TextField(
              controller: _panelSearch,
              decoration: InputDecoration.collapsed(
                hintText: AppStringKeys.composerMediaSearch.l10n(context),
              ),
              style: TextStyle(fontSize: 14, color: c.textPrimary),
            ),
          ),
          if (_panelSearch.text.isNotEmpty)
            GestureDetector(
              key: const ValueKey('composerMediaSearchClear'),
              behavior: HitTestBehavior.opaque,
              onTap: _panelSearch.clear,
              child: SizedBox(
                width: 30,
                height: 30,
                child: Center(
                  child: AppIcon(
                    HeroAppIcons.circleXmark,
                    size: 18,
                    color: c.textTertiary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emojiSearchContent() {
    final count = _emojiSearchResults.length + _customEmojiSearchResults.length;
    if (count == 0) return _panelSearchState();
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
      ),
      itemCount: count,
      itemBuilder: (context, index) {
        if (index < _emojiSearchResults.length) {
          final emoji = _emojiSearchResults[index];
          return GestureDetector(
            key: ValueKey('emojiSearch-$emoji'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _controller.insertText(emoji),
            child: Center(
              child: Text(emoji, style: const TextStyle(fontSize: 26)),
            ),
          );
        }
        final item =
            _customEmojiSearchResults[index - _emojiSearchResults.length];
        return GestureDetector(
          key: ValueKey('customEmojiSearch-${item.customEmojiId}'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (item.customEmojiId != 0) {
              _controller.insertCustomEmoji(item.customEmojiId, item.emoji);
            } else if (item.emoji.isNotEmpty) {
              _controller.insertText(item.emoji);
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: item.customEmojiId != 0
                ? CustomEmojiView(
                    id: item.customEmojiId,
                    size: 34,
                    color: context.colors.textPrimary,
                  )
                : StickerPreview(item: item),
          ),
        );
      },
    );
  }

  Widget _panelSearchState() => Center(
    child: _panelSearchLoading
        ? const AppActivityIndicator(size: 23)
        : Text(
            AppStringKeys.composerMediaSearchEmpty.l10n(context),
            style: TextStyle(fontSize: 13, color: context.colors.textSecondary),
          ),
  );

  Widget _emojiTabStrip() {
    final c = context.colors;
    final packs = EmojiStore.shared.customPacks;
    return Container(
      key: const ValueKey('emojiPanelTabs'),
      decoration: BoxDecoration(
        color: c.inputBarBackground,
        border: Border(bottom: BorderSide(color: c.divider, width: 0.5)),
      ),
      child: SizedBox(
        height: 50,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          children: [
            _emojiTabButton(
              key: const ValueKey('emojiSearchTab'),
              selected: _emojiTab == _emojiSearchTab,
              onTap: () => _selectEmojiTab(_emojiSearchTab),
              child: AppIcon(
                HeroAppIcons.magnifyingGlass,
                size: 20,
                color: _emojiTab == _emojiSearchTab
                    ? AppTheme.brand
                    : c.textSecondary,
              ),
            ),
            _emojiTabButton(
              selected: _emojiTab == 'standard',
              onTap: () => _selectEmojiTab('standard'),
              child: AppIcon(
                HeroAppIcons.solidFaceSmile,
                size: 20,
                color: _emojiTab == 'standard'
                    ? AppTheme.brand
                    : c.textSecondary,
              ),
            ),
            for (final pack in packs)
              _emojiTabButton(
                selected: _emojiTab == pack.id.toString(),
                onTap: () => _selectEmojiTab(pack.id.toString()),
                child:
                    pack.emoji.isNotEmpty && pack.emoji.first.customEmojiId != 0
                    ? CustomEmojiView(
                        id: pack.emoji.first.customEmojiId,
                        size: 28,
                        color: c.textPrimary,
                      )
                    : (pack.cover != null
                          ? TDImage(photo: pack.cover, cornerRadius: 4)
                          : Text(
                              pack.title.isEmpty
                                  ? ''
                                  : pack.title.characters.first,
                              style: TextStyle(color: c.textPrimary),
                            )),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emojiTabButton({
    Key? key,
    required bool selected,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: selected ? context.colors.searchFill : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: SizedBox(width: 28, height: 28, child: Center(child: child)),
      ),
    );
  }

  Widget _voicePanel() {
    return _mobileVoicePanel();
  }

  Widget _mobileVoicePanel() {
    final c = context.colors;
    final granted = _recorder != null;
    final label = _startingRecording
        ? AppStrings.t(AppStringKeys.composerRecordingPreparing)
        : _stoppingRecording
        ? AppStrings.t(AppStringKeys.composerRecordingFinishing)
        : !granted
        ? AppStrings.t(AppStringKeys.composerMicrophonePermissionRequired)
        : !_recording
        ? AppStrings.t(AppStringKeys.composerHoldToTalk)
        : _recordingLocked
        ? (_recordingPaused
              ? AppStrings.t(AppStringKeys.composerRecordingPaused)
              : AppStrings.t(AppStringKeys.composerRecordingLocked))
        : (_recordCancelled
              ? AppStrings.t(AppStringKeys.composerReleaseFingerToCancel)
              : AppStrings.t(AppStringKeys.composerRecordingReleasePreview));
    return Container(
      height: 240,
      width: double.infinity,
      color: c.panelBackground,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: _recordCancelled ? AppTheme.tagRed : c.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          if (_recording) ...[
            SizedBox(
              width: 220,
              height: 28,
              child: ValueListenableBuilder<_RecTick>(
                valueListenable: _recTick,
                builder: (context, tick, _) => Row(
                  children: [
                    for (final level in tick.levels)
                      Expanded(
                        child: Align(
                          child: Container(
                            width: 2,
                            height:
                                (4 + ((level.clamp(-60.0, 0.0) + 60) / 60) * 24)
                                    .toDouble(),
                            decoration: BoxDecoration(
                              color: _recordingPaused
                                  ? c.textTertiary
                                  : AppTheme.brand,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
          Opacity(
            opacity: _recording ? 1 : 0.3,
            child: ValueListenableBuilder<_RecTick>(
              valueListenable: _recTick,
              builder: (context, tick, _) => Text(
                _recTime(tick.elapsed),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: c.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Listener(
            key: const ValueKey('mobileVoiceRecordButton'),
            onPointerDown: (e) {
              if (_recording || _voiceStop != null || _mobilePointerHeld) {
                return;
              }
              _voicePointerId = e.pointer;
              _mobilePointerHeld = true;
              _pressStartX = e.position.dx;
              _pressStartY = e.position.dy;
              unawaited(_beginVoiceRecording());
            },
            onPointerMove: (e) {
              if (_voicePointerId != e.pointer || _recordingLocked) return;
              final cancel = e.position.dx - _pressStartX < -70;
              final lock = _recording && e.position.dy - _pressStartY < -70;
              if (lock) {
                setState(() {
                  _recordingLocked = true;
                  _recordCancelled = false;
                });
                return;
              }
              if (cancel != _recordCancelled) {
                setState(() => _recordCancelled = cancel);
              }
            },
            onPointerUp: (e) {
              if (_voicePointerId != e.pointer) return;
              _voicePointerId = null;
              _mobilePointerHeld = false;
              if (!_recordingLocked) unawaited(_stopRec());
            },
            onPointerCancel: (e) {
              if (_voicePointerId == e.pointer) _cancelVoiceRecording();
            },
            child: AnimatedScale(
              scale: _recording ? 1.12 : 1,
              duration: const Duration(milliseconds: 150),
              child: Container(
                width: 84,
                height: 84,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _recordCancelled ? AppTheme.tagRed : AppTheme.brand,
                  shape: BoxShape.circle,
                ),
                child: const AppIcon(
                  HeroAppIcons.microphone,
                  size: 32,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          if (_recordingLocked) ...[
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _voiceRecordingAction(
                  icon: HeroAppIcons.trash,
                  color: AppTheme.tagRed,
                  onTap: _cancelLockedRecording,
                ),
                const SizedBox(width: 22),
                _voiceRecordingAction(
                  icon: _recordingPaused
                      ? HeroAppIcons.play
                      : HeroAppIcons.pause,
                  color: AppTheme.brand,
                  onTap: () => unawaited(_toggleRecPause()),
                ),
                const SizedBox(width: 22),
                _voiceRecordingAction(
                  icon: HeroAppIcons.square,
                  color: AppTheme.brand,
                  onTap: () => unawaited(_stopRec()),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _voiceRecordingAction({
    required AppIconData icon,
    required Color color,
    required VoidCallback onTap,
  }) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: AppIcon(icon, size: 20, color: color),
    ),
  );

  Widget _stickerPanel() {
    final c = context.colors;
    return Container(
      height: 326,
      color: c.panelBackground,
      child: Column(
        children: [
          _stickerTabStrip(),
          if (_stickerPack == _stickerSearchTabId) _panelSearchField(),
          Expanded(child: _stickerContent()),
        ],
      ),
    );
  }

  Widget _stickerContent() {
    final store = StickerStore.shared;
    final packs = store.packs;
    final activeId =
        _stickerPack ??
        (packs.isNotEmpty ? packs.first.id : StickerStore.recentPackId);
    if (activeId == _stickerSearchTabId) return _stickerSearchContent();
    if (activeId == _gifTabId) return _gifContent();
    if (packs.isEmpty) {
      return Center(
        child: Text(
          store.loading
              ? AppStrings.t(AppStringKeys.composerLoadingEmoji)
              : AppStrings.t(AppStringKeys.composerNoEmoji),
          style: TextStyle(fontSize: 13, color: context.colors.textSecondary),
        ),
      );
    }
    StickerPack? pack;
    for (final p in packs) {
      if (p.id == activeId) {
        pack = p;
        break;
      }
    }
    pack ??= packs.first;
    if (!pack.loaded && pack.stickers.isEmpty) {
      store.loadPack(pack.id);
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator.adaptive(strokeWidth: 2),
        ),
      );
    }
    final stickers = pack.stickers;
    return _stickerGrid(stickers);
  }

  Widget _stickerGrid(List<StickerItem> stickers, {bool search = false}) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: stickers.length,
      itemBuilder: (context, i) => _stickerTile(stickers[i], search: search),
    );
  }

  Future<void> _sendStickerItem(StickerItem item) async {
    widget.onMediaSendTapped?.call();
    final sent = await widget.vm.sendSticker(item);
    if (!mounted) return;
    if (sent) {
      _finishPanelSend();
    } else {
      showToast(
        context,
        AppStrings.t(AppStringKeys.stickerSetDetailActionFailed),
      );
    }
  }

  Widget _gifContent() {
    final store = GifStore.shared;
    final items = store.items;
    if (items.isEmpty) {
      return Center(
        child: Text(
          store.loading
              ? AppStrings.t(AppStringKeys.composerLoadingGifs)
              : AppStrings.t(AppStringKeys.composerNoGifs),
          style: TextStyle(fontSize: 13, color: context.colors.textSecondary),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 1.2,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (_, index) => _gifTile(items[index]),
    );
  }

  Widget _stickerSearchContent() {
    if (_panelSearch.text.trim().isEmpty) return const SizedBox.shrink();
    if (_stickerSearchResults.isEmpty && _gifSearchResults.isEmpty) {
      return _panelSearchState();
    }
    return CustomScrollView(
      slivers: [
        if (_stickerSearchResults.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) =>
                    _stickerTile(_stickerSearchResults[index], search: true),
                childCount: _stickerSearchResults.length,
              ),
            ),
          ),
        if (_gifSearchResults.isNotEmpty || _gifSearchNextOffset.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 1.2,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index == _gifSearchResults.length) {
                    return _gifSearchLoadMoreTile();
                  }
                  return _gifTile(_gifSearchResults[index], search: true);
                },
                childCount:
                    _gifSearchResults.length +
                    (_gifSearchNextOffset.isNotEmpty ? 1 : 0),
              ),
            ),
          ),
      ],
    );
  }

  Widget _stickerTile(StickerItem item, {bool search = false}) =>
      GestureDetector(
        key: ValueKey(
          search ? 'stickerSearch-${item.id}' : 'sticker-${item.id}',
        ),
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_sendStickerItem(item)),
        child: StickerPreview(item: item),
      );

  Widget _gifTile(GifItem item, {bool search = false}) => GestureDetector(
    key: ValueKey(search ? 'gifSearch-${item.id}' : 'gif-${item.id}'),
    behavior: HitTestBehavior.opaque,
    onTap: () => unawaited(_sendGifItem(item)),
    child: widget.gifPreviewBuilder?.call(item) ?? GifPreview(item: item),
  );

  Widget _gifSearchLoadMoreTile() => Semantics(
    button: true,
    label: AppStrings.t(AppStringKeys.chatInputBarLoadMoreGIFResults),
    child: GestureDetector(
      key: const ValueKey('gifSearchLoadMore'),
      behavior: HitTestBehavior.opaque,
      onTap: _gifSearchLoadingMore
          ? null
          : () => unawaited(_loadMoreGifSearch()),
      child: Center(
        child: _gifSearchLoadingMore
            ? const AppActivityIndicator(size: 22)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    HeroAppIcons.chevronDown,
                    size: 22,
                    color: context.colors.textSecondary,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppStrings.t(AppStringKeys.commonMore),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colors.textSecondary,
                    ),
                  ),
                ],
              ),
      ),
    ),
  );

  Future<void> _sendGifItem(GifItem item) async {
    widget.onMediaSendTapped?.call();
    final sent = await widget.vm.sendGif(item);
    if (!mounted) return;
    if (sent) {
      _finishPanelSend();
    } else {
      showToast(context, AppStrings.t(AppStringKeys.composerGifSendFailed));
    }
  }

  Widget _stickerTabStrip() {
    final c = context.colors;
    final packs = StickerStore.shared.packs;
    final activeId =
        _stickerPack ??
        (packs.isNotEmpty ? packs.first.id : StickerStore.recentPackId);
    final installed = packs.where((p) => p.id != StickerStore.recentPackId);
    return Container(
      key: const ValueKey('stickerPanelTabs'),
      decoration: BoxDecoration(
        color: c.inputBarBackground,
        border: Border(bottom: BorderSide(color: c.divider, width: 0.5)),
      ),
      child: SizedBox(
        height: 50,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          children: [
            _emojiTabButton(
              key: const ValueKey('stickerSearchTab'),
              selected: activeId == _stickerSearchTabId,
              onTap: () => _selectStickerTab(_stickerSearchTabId),
              child: AppIcon(
                HeroAppIcons.magnifyingGlass,
                size: 20,
                color: activeId == _stickerSearchTabId
                    ? AppTheme.brand
                    : c.textSecondary,
              ),
            ),
            _emojiTabButton(
              selected: activeId == StickerStore.recentPackId,
              onTap: () => _selectStickerTab(StickerStore.recentPackId),
              child: AppIcon(
                HeroAppIcons.clock,
                size: 20,
                color: activeId == StickerStore.recentPackId
                    ? AppTheme.brand
                    : c.textSecondary,
              ),
            ),
            _emojiTabButton(
              selected: activeId == _gifTabId,
              onTap: () => _selectStickerTab(_gifTabId),
              child: AppIcon(
                HeroAppIcons.gif,
                size: 22,
                color: activeId == _gifTabId ? AppTheme.brand : c.textSecondary,
              ),
            ),
            for (final pack in installed)
              _emojiTabButton(
                selected: pack.id == activeId,
                onTap: () => _selectStickerTab(pack.id),
                child: pack.cover != null
                    ? StickerTabPreview(item: pack.cover!)
                    : Text(
                        pack.title.isEmpty ? '' : pack.title.characters.first,
                        style: TextStyle(color: c.textPrimary),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openStickerStudio() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const StickerSetStudioView()),
    );
    StickerStore.shared.reset();
    EmojiStore.shared.reset();
    StickerStore.shared.loadIfNeeded();
    EmojiStore.shared.loadIfNeeded();
  }
}

enum _ComposerFormatAction {
  quote('textEntityTypeBlockQuote'),
  spoiler('textEntityTypeSpoiler'),
  bold('textEntityTypeBold'),
  italic('textEntityTypeItalic'),
  monospace('textEntityTypeCode'),
  link(''),
  strikethrough('textEntityTypeStrikethrough'),
  underline('textEntityTypeUnderline'),
  codeBlock('textEntityTypePre');

  const _ComposerFormatAction(this.entityType);

  final String entityType;

  String get labelKey => switch (this) {
    quote => AppStringKeys.messageActionQuote,
    spoiler => AppStringKeys.composerFormatSpoiler,
    bold => AppStringKeys.composerFormatBold,
    italic => AppStringKeys.composerFormatItalic,
    monospace => AppStringKeys.composerFormatMonospace,
    link => AppStringKeys.composerFormatLink,
    strikethrough => AppStringKeys.composerFormatStrikethrough,
    underline => AppStringKeys.composerFormatUnderline,
    codeBlock => AppStringKeys.composerFormatCodeBlock,
  };
}

class _ComposerFormatMenu extends StatelessWidget {
  const _ComposerFormatMenu({required this.anchor});

  static const _width = 232.0;
  static const _rowHeight = 44.0;
  static const _padding = 8.0;

  final Offset anchor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final media = MediaQuery.of(context);
    final screen = media.size;
    final menuHeight =
        _ComposerFormatAction.values.length * _rowHeight + _padding * 2;
    final safeTop = media.padding.top + 8;
    final safeBottom = screen.height - media.viewInsets.bottom - 8;
    final left = (anchor.dx - _width / 2)
        .clamp(12.0, math.max(12.0, screen.width - _width - 12))
        .toDouble();
    final below = anchor.dy + 10;
    final top = below + menuHeight <= safeBottom
        ? below
        : math.max(safeTop, anchor.dy - menuHeight - 10);
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: _width,
          child: TextFieldTapRegion(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: _padding),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: c.divider, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final action in _ComposerFormatAction.values)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).pop(action),
                      child: SizedBox(
                        height: _rowHeight,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Text(
                              action.labelKey.l10n(context),
                              style: TextStyle(
                                fontSize: 16,
                                color: c.textPrimary,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ComposerLinkDialog extends StatefulWidget {
  const _ComposerLinkDialog();

  @override
  State<_ComposerLinkDialog> createState() => _ComposerLinkDialogState();
}

class _ComposerLinkDialogState extends State<_ComposerLinkDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Container(
        width: math.min(360, MediaQuery.sizeOf(context).width - 40),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.divider, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppStringKeys.composerFormatLink.l10n(context),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              decoration: BoxDecoration(
                color: c.searchFill,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: _submit,
                style: TextStyle(fontSize: 16, color: c.textPrimary),
                decoration: InputDecoration(
                  hintText: AppStringKeys.composerFormatLinkPlaceholder.l10n(
                    context,
                  ),
                  hintStyle: TextStyle(color: c.textTertiary),
                  border: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _dialogAction(
                  context,
                  AppStringKeys.countryPickerCancel,
                  () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 8),
                _dialogAction(
                  context,
                  AppStringKeys.composerFormatApply,
                  () => _submit(_controller.text),
                  primary: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dialogAction(
    BuildContext context,
    String label,
    VoidCallback onTap, {
    bool primary = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Text(
          label.l10n(context),
          style: TextStyle(
            fontSize: 15,
            fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
            color: primary ? AppTheme.brand : context.colors.textSecondary,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  void _submit(String value) {
    final url = value.trim();
    if (url.isEmpty) return;
    Navigator.of(context).pop(url);
  }
}
