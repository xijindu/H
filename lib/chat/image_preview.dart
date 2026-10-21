import 'package:flutter/widgets.dart';

import '../tdlib/td_models.dart';
import '../theme/app_motion.dart';
import 'full_image_viewer.dart';

export 'full_image_viewer.dart';

Future<void> openImagePreview(
  BuildContext context, {
  required List<TdFileRef> items,
  int startIndex = 0,
  String? primaryActionLabel,
  Future<void> Function(int index)? onPrimaryAction,
  Future<void> Function(int index)? onMore,
}) async {
  if (items.isEmpty) return;
  final index = startIndex.clamp(0, items.length - 1);
  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push<void>(
    AppPageRoute<void>(
      fullscreenDialog: true,
      pageBuilder: (_, _, _) => FullImageViewer(
        items: items,
        startIndex: index,
        primaryActionLabel: primaryActionLabel,
        onPrimaryAction: onPrimaryAction,
        onMore: onMore,
      ),
    ),
  );
}