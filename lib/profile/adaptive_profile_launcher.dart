import 'package:flutter/material.dart';

import 'profile_detail_view.dart';

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