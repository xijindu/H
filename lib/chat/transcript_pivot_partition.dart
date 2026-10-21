class TranscriptPivot {
  const TranscriptPivot(this.cutoffMessageId);

  final int cutoffMessageId;
}

TranscriptPivot? resolveTranscriptPivot({
  required TranscriptPivot? currentPivot,
  required bool initialWindowLoaded,
  required int? firstMessageId,
}) {
  if (currentPivot != null) return currentPivot;
  if (!initialWindowLoaded || firstMessageId == null) return null;
  return TranscriptPivot(firstMessageId);
}

bool shouldRebasePendingTranscriptPivot({
  required TranscriptPivot? pivot,
  required int pendingOrderId,
  required bool hasServerMessage,
}) {
  return pivot?.cutoffMessageId == pendingOrderId && hasServerMessage;
}

bool transcriptFollowsLatestEdge({
  required bool preservesViewport,
  required bool maintainsSessionAnchor,
  required bool viewportClaimedByUser,
  required bool hasPendingMessageTarget,
}) =>
    !preservesViewport &&
    !maintainsSessionAnchor &&
    !viewportClaimedByUser &&
    !hasPendingMessageTarget;

bool shouldRebaseForHydratedOlderPage({
  required bool prependedOlder,
  required bool latestArmWasShort,
  required bool historyFillInFlight,
  required bool revealRequested,
  bool hasPendingMessageTarget = false,
}) =>
    prependedOlder &&
    latestArmWasShort &&
    !hasPendingMessageTarget &&
    (historyFillInFlight || revealRequested);

bool isLatestTranscriptArmShort({
  required double maxScrollExtent,
  required int afterCenterEntryCount,
  double extentThreshold = 24,
  int entryThreshold = 3,
}) {
  if (afterCenterEntryCount < entryThreshold) return true;
  return maxScrollExtent <= extentThreshold;
}

bool shouldFreezeTranscriptPivot({
  required bool latestArmIsShort,
  required bool canLoadOlder,
}) => !latestArmIsShort || !canLoadOlder;

bool shouldDiscardRestoredTranscriptPivot({
  required int? pivotMessageId,
  required int? newestMessageId,
  required bool openAtBottom,
}) =>
    openAtBottom &&
    pivotMessageId != null &&
    newestMessageId != null &&
    pivotMessageId == newestMessageId;

bool shouldRestoreTranscriptPivot({
  required int? pivotMessageId,
  required bool hasSessionTranscript,
  required int? newestMessageId,
  required bool openAtBottom,
}) {
  if (pivotMessageId == null || !hasSessionTranscript) return false;
  return !shouldDiscardRestoredTranscriptPivot(
    pivotMessageId: pivotMessageId,
    newestMessageId: newestMessageId,
    openAtBottom: openAtBottom,
  );
}

bool shouldRebaseParkedShortTranscriptPivot({
  required int? pivotCutoffMessageId,
  required bool latestArmIsShort,
  required bool hasMessageOlderThanPivot,
  required bool followingLatest,
  bool hasExplicitMessageTarget = false,
  bool viewportClaimedByUser = false,
}) {
  if (hasExplicitMessageTarget ||
      viewportClaimedByUser ||
      !followingLatest ||
      pivotCutoffMessageId == null) {
    return false;
  }
  return latestArmIsShort && hasMessageOlderThanPivot;
}

bool shouldRebaseForExpandedInitialWindow({
  required bool transcriptChanged,
  required bool latestArmIsShort,
  required bool hasMessageOlderThanPivot,
  required bool followingLatest,
  bool viewportClaimedByUser = false,
}) =>
    transcriptChanged &&
    latestArmIsShort &&
    hasMessageOlderThanPivot &&
    followingLatest &&
    !viewportClaimedByUser;

bool shouldPlaceFirstContactCardAtCenter({
  required bool hasTranscriptEntries,
}) => !hasTranscriptEntries;

bool firstContactHistoryFitsViewport({
  required double cardTop,
  required double latestBottom,
  required double viewportExtent,
  double outerSpacing = 16,
}) {
  if (latestBottom < cardTop || viewportExtent < 0 || outerSpacing < 0) {
    return false;
  }
  return latestBottom - cardTop + outerSpacing <= viewportExtent + 0.5;
}

bool startsTranscriptPivotSection({
  required TranscriptPivot? pivot,
  required int previousMessageId,
  required int currentMessageId,
}) {
  if (pivot == null) return false;
  return previousMessageId < pivot.cutoffMessageId &&
      currentMessageId >= pivot.cutoffMessageId;
}

class TranscriptPivotPartition<Entry> {
  const TranscriptPivotPartition({
    required this.beforePivot,
    required this.pivotAndAfter,
  });

  final List<Entry> beforePivot;

  final List<Entry> pivotAndAfter;
}

TranscriptPivotPartition<Entry> partitionTranscriptAtPivot<Entry>({
  required Iterable<Entry> entries,
  required TranscriptPivot pivot,
  required Iterable<int> Function(Entry entry) messageIdsOf,
}) {
  final beforePivot = <Entry>[];
  final pivotAndAfter = <Entry>[];

  for (final entry in entries) {
    final messageIds = messageIdsOf(entry).toList(growable: false);
    if (messageIds.isEmpty) {
      throw ArgumentError.value(
        entry,
        'entries',
        'Each transcript entry must contain at least one message ID.',
      );
    }

    final isEntirelyBeforePivot = messageIds.every(
      (messageId) => messageId < pivot.cutoffMessageId,
    );
    (isEntirelyBeforePivot ? beforePivot : pivotAndAfter).add(entry);
  }

  return TranscriptPivotPartition<Entry>(
    beforePivot: List<Entry>.unmodifiable(beforePivot),
    pivotAndAfter: List<Entry>.unmodifiable(pivotAndAfter),
  );
}
