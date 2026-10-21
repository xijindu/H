class ChatAutoScrollPolicy {
  factory ChatAutoScrollPolicy({bool preserveViewport = false}) =>
      ChatAutoScrollPolicy._(preserveViewport);

  ChatAutoScrollPolicy._(this._preserveViewport);

  bool _preserveViewport;

  bool _suppressViewportPreservation = false;

  bool get preservesViewport => _preserveViewport;

  void noteUserScroll({
    required bool towardOlderMessages,
    required bool isAtBottom,
  }) {
    if (isAtBottom) {
      _preserveViewport = false;
      _suppressViewportPreservation = false;
      return;
    }
    if (_suppressViewportPreservation) return;
    if (towardOlderMessages) {
      _preserveViewport = true;
    }
  }

  void returnToBottom() {
    _preserveViewport = false;
    _suppressViewportPreservation = false;
  }

  void requestReturnToBottom() {
    _preserveViewport = false;
    _suppressViewportPreservation = true;
  }

  void allowViewportPreservation() {
    _suppressViewportPreservation = false;
  }

  void noteMessageSent() => requestReturnToBottom();

  bool shouldFollowAppendedMessage({required bool wasNearBottom}) =>
      !_preserveViewport && wasNearBottom;

  bool shouldFollowComposerPanelChange({required bool wasNearBottom}) =>
      !_preserveViewport && wasNearBottom;
}

enum ChatReopenDisposition {
  explicitTarget,
  firstUnread,
  savedPosition,
  defaultPosition,
}

ChatReopenDisposition resolveChatReopenDisposition({
  required bool hasExplicitTarget,
  required bool hasSavedPosition,
  required bool prioritizeUnread,
}) {
  if (hasExplicitTarget) return ChatReopenDisposition.explicitTarget;
  if (prioritizeUnread) return ChatReopenDisposition.firstUnread;
  if (hasSavedPosition) return ChatReopenDisposition.savedPosition;
  return ChatReopenDisposition.defaultPosition;
}

bool shouldPrioritizeUnreadOnChatReopen({
  required int currentUnreadCount,
  required int currentLastReadInboxId,
  required int? savedAnchorMessageId,
  required bool hasConfirmedNewUnread,
}) {
  if (hasConfirmedNewUnread) return true;
  if (currentUnreadCount <= 0) return false;
  if (savedAnchorMessageId == null) return true;
  if (currentLastReadInboxId <= 0) return false;
  return savedAnchorMessageId <= currentLastReadInboxId;
}

bool shouldLoadLatestChatHistory({
  required bool anchoredHistory,
  required bool historyReachesLatest,
}) => anchoredHistory || !historyReachesLatest;

bool isNewIncomingUnreadSinceChatSession({
  required int messageId,
  required bool isOutgoing,
  required bool isService,
  required int savedKnownLatestMessageId,
  required int currentLastReadInboxId,
}) {
  return savedKnownLatestMessageId > 0 &&
      !isOutgoing &&
      !isService &&
      messageId > savedKnownLatestMessageId &&
      messageId > currentLastReadInboxId;
}

bool shouldProbeChatSessionUnreadHistory({
  required int savedKnownLatestMessageId,
  required int currentKnownLatestMessageId,
  required int currentUnreadCount,
}) =>
    savedKnownLatestMessageId > 0 &&
    currentUnreadCount > 0 &&
    currentKnownLatestMessageId > savedKnownLatestMessageId;

bool shouldContinueChatSessionUnreadHistoryProbe({
  required int pagesScanned,
  int maximumPages = 5,
}) => pagesScanned < maximumPages;

bool shouldApplyInitialChatReadState({
  required int readInboxRevisionAtRequestStart,
  required int currentReadInboxRevision,
}) => readInboxRevisionAtRequestStart == currentReadInboxRevision;

class ChatSessionReopenNavigationGuard {
  int _generation = 0;

  int begin() => ++_generation;

  void cancel() => ++_generation;

  bool isCurrent(int generation) => generation == _generation;
}

bool shouldMarkChatReadOnExit({
  required bool isAtLoadedBottom,
  required bool sessionReopenPending,
  required bool restoredPositionProtected,
  required bool preservesViewport,
  required bool historyReachesLatest,
}) =>
    isAtLoadedBottom &&
    shouldAllowAutomaticChatRead(
      sessionReopenPending: sessionReopenPending,
      restoredPositionProtected: restoredPositionProtected,
      preservesViewport: preservesViewport,
      historyReachesLatest: historyReachesLatest,
    );

bool shouldAllowAutomaticChatRead({
  required bool sessionReopenPending,
  required bool restoredPositionProtected,
  required bool preservesViewport,
  required bool historyReachesLatest,
}) =>
    !sessionReopenPending &&
    !restoredPositionProtected &&
    !preservesViewport &&
    historyReachesLatest;

bool shouldSaveChatSessionScrollSnapshot({
  required bool sessionReopenPending,
  required bool preservingSnapshotAfterFailedJump,
}) => !sessionReopenPending && !preservingSnapshotAfterFailedJump;

class ChatRestoredPositionGuard {
  ChatRestoredPositionGuard(this._armed);

  bool _armed;
  bool _gestureActive = false;

  bool get blocksAutomaticReturn => _armed;

  void noteUserScroll() {
    if (_armed) _gestureActive = true;
  }

  bool finishUserScroll() {
    if (!_armed || !_gestureActive) return false;
    _armed = false;
    _gestureActive = false;
    return true;
  }

  void cancel() {
    _armed = false;
    _gestureActive = false;
  }
}

bool shouldContinueAnchoredHistory({
  required bool anchoredHistory,
  required bool restoredPositionProtected,
  required bool pointerDown,
  required bool hasScrollTarget,
  required bool hasScrollClients,
  required bool isNearLatestEdge,
}) {
  return anchoredHistory &&
      !restoredPositionProtected &&
      !pointerDown &&
      !hasScrollTarget &&
      hasScrollClients &&
      isNearLatestEdge;
}

bool isChatSessionAtLoadedBottom({
  required bool anchoredHistory,
  required double distanceToLoadedBottom,
  double epsilon = 0.5,
}) {
  return !anchoredHistory &&
      distanceToLoadedBottom.isFinite &&
      distanceToLoadedBottom >= 0 &&
      distanceToLoadedBottom <= epsilon;
}

enum ChatInitialViewportTargetKind {
  message,
  firstUnread,
  readBoundary,
  loadedBottom,
  preserveAnchoredHistory,
}

class ChatInitialViewportTarget {
  const ChatInitialViewportTarget(this.kind, {this.messageId});

  final ChatInitialViewportTargetKind kind;
  final int? messageId;
}

ChatInitialViewportTarget resolveChatInitialViewportTarget({
  required int? explicitMessageId,
  required int? pendingMessageId,
  required bool openAtBottom,
  required bool anchoredHistory,
  required int unreadCount,
  required int? firstUnreadMessageId,
  required bool unreadBoundaryLoaded,
  required int lastReadInboxId,
}) {
  final messageTarget = explicitMessageId ?? pendingMessageId;
  if (messageTarget != null) {
    return ChatInitialViewportTarget(
      ChatInitialViewportTargetKind.message,
      messageId: messageTarget,
    );
  }
  if (openAtBottom) {
    return const ChatInitialViewportTarget(
      ChatInitialViewportTargetKind.loadedBottom,
    );
  }
  if (unreadCount > 0 && firstUnreadMessageId != null && unreadBoundaryLoaded) {
    return ChatInitialViewportTarget(
      ChatInitialViewportTargetKind.firstUnread,
      messageId: firstUnreadMessageId,
    );
  }
  if (unreadCount > 0 && lastReadInboxId > 0) {
    return ChatInitialViewportTarget(
      ChatInitialViewportTargetKind.readBoundary,
      messageId: lastReadInboxId,
    );
  }
  if (anchoredHistory) {
    return const ChatInitialViewportTarget(
      ChatInitialViewportTargetKind.preserveAnchoredHistory,
    );
  }
  return const ChatInitialViewportTarget(
    ChatInitialViewportTargetKind.loadedBottom,
  );
}

class ChatInitialScrollPlan {
  const ChatInitialScrollPlan({
    required this.initialOffset,
    required this.correctToBottomAfterLayout,
  });

  final double initialOffset;
  final bool correctToBottomAfterLayout;
}

ChatInitialScrollPlan chatInitialScrollPlan({
  required bool hasCachedTranscript,
  required double? savedPixels,
  required bool savedAtBottom,
  bool openAtBottom = false,
}) {
  final finiteSavedPixels = savedPixels?.isFinite == true ? savedPixels! : 0.0;
  return ChatInitialScrollPlan(
    initialOffset: hasCachedTranscript ? finiteSavedPixels : 0.0,
    correctToBottomAfterLayout:
        hasCachedTranscript && (savedAtBottom || openAtBottom),
  );
}

class ChatBottomCorrectionCoordinator {
  bool _scheduled = false;

  void schedule({
    required bool enabled,
    required void Function(void Function()) schedulePostFrame,
    required bool Function() canCorrect,
    required void Function() correct,
  }) {
    if (!enabled || _scheduled) return;
    _scheduled = true;
    schedulePostFrame(() {
      _scheduled = false;
      if (canCorrect()) correct();
    });
  }
}

class ChatBottomFollowCoordinator {
  int _generation = 0;

  int begin() => ++_generation;

  void cancel() => ++_generation;

  bool isCurrent(int generation) => generation == _generation;

  void follow({
    required int generation,
    required void Function(void Function()) schedulePostFrame,
    required bool Function() canFollow,
    required double Function() distanceToLatest,
    required double Function() latestExtent,
    required void Function() correct,
    required void Function() settled,
    required void Function() abandoned,
    double epsilon = 0.5,
    int remainingFrames = 12,
    double? previousLatestExtent,
  }) {
    if (!isCurrent(generation)) return;
    if (remainingFrames <= 0) {
      abandoned();
      return;
    }
    schedulePostFrame(() {
      if (!isCurrent(generation)) return;
      if (!canFollow()) {
        abandoned();
        return;
      }
      final currentLatestExtent = latestExtent();
      if (distanceToLatest() <= epsilon) {
        final extentIsStable =
            previousLatestExtent != null &&
            (currentLatestExtent - previousLatestExtent).abs() <= epsilon;
        if (extentIsStable) {
          settled();
          return;
        }
        follow(
          generation: generation,
          schedulePostFrame: schedulePostFrame,
          canFollow: canFollow,
          distanceToLatest: distanceToLatest,
          latestExtent: latestExtent,
          correct: correct,
          settled: settled,
          abandoned: abandoned,
          epsilon: epsilon,
          remainingFrames: remainingFrames - 1,
          previousLatestExtent: currentLatestExtent,
        );
        return;
      }
      correct();
      follow(
        generation: generation,
        schedulePostFrame: schedulePostFrame,
        canFollow: canFollow,
        distanceToLatest: distanceToLatest,
        latestExtent: latestExtent,
        correct: correct,
        settled: settled,
        abandoned: abandoned,
        epsilon: epsilon,
        remainingFrames: remainingFrames - 1,
        previousLatestExtent: currentLatestExtent,
      );
    });
  }
}

bool shouldRestoreChatSessionOffset({
  required bool hasExplicitTarget,
  required bool hasSnapshot,
  required bool snapshotWasAtBottom,
}) {
  return !hasExplicitTarget && hasSnapshot && !snapshotWasAtBottom;
}

bool shouldPreserveChatSessionAnchorAcrossWindowChange({
  required bool anchorMaintenanceActive,
  required bool hasSavedPivot,
  required bool historyWindowInvalidated,
}) {
  return anchorMaintenanceActive && hasSavedPivot && !historyWindowInvalidated;
}

bool shouldOpenChatAtBottom({
  required bool hasExplicitTarget,
  required bool openAtLatest,
  required bool hasSnapshot,
  required bool snapshotWasAtBottom,
  bool hasCachedLatestTranscript = false,
}) {
  if (hasExplicitTarget) return false;
  if (hasSnapshot) return snapshotWasAtBottom;
  if (hasCachedLatestTranscript) return true;
  return openAtLatest;
}

double correctedChatSessionScrollOffset({
  required double currentPixels,
  required double currentAnchorViewportOffset,
  required double savedAnchorViewportOffset,
  required double minScrollExtent,
  required double maxScrollExtent,
}) {
  return (currentPixels +
          currentAnchorViewportOffset -
          savedAnchorViewportOffset)
      .clamp(minScrollExtent, maxScrollExtent);
}
