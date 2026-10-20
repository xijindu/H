import 'package:flutter/material.dart';

import 'profile_detail_view.dart';

/// Opens another user's profile without replacing a split-pane workspace.
///
/// Phone and tablet callers keep their existing navigation behavior through
/// [openFallback], while callers without a custom split-pane destination
/// receive the normal profile route.
///
/// [preferInlinePane] is for a caller that already has a detail pane sitting
/// empty beside its list — the contacts tab.
Future<void> openAdaptiveUserProfile(
  BuildContext context, {
  required int userId,
  required String name,
  VoidCallback? openFallback,
  bool preferInlinePane = false,
}) async {
  if (preferInlinePane && openFallback != null) {
    openFallback();
    return;
  }
  if (!context.mounted) return;
  if (openFallback != null) {
    openFallback();
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ProfileDetailView(userId: userId, name: name),
    ),
  );
}