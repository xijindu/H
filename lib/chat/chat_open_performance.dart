bool chatOpenWorkIsStale({
  required bool disposed,
  required int openingClientId,
  required int openingAccountSlot,
  required int activeClientId,
  required int activeAccountSlot,
}) =>
    disposed ||
    openingClientId != activeClientId ||
    openingAccountSlot != activeAccountSlot;

bool shouldShowTranscriptSkeleton({required bool initialTranscriptReady}) =>
    !initialTranscriptReady;

bool shouldHydrateInitialHistoryInBackground({
  required int loadedMessageCount,
}) => loadedMessageCount > 0;
