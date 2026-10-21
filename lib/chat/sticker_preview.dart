import 'package:flutter/material.dart';

import '../components/app_icons.dart';
import '../components/photo_avatar.dart';
import '../tdlib/td_models.dart';
import '../theme/app_theme.dart';
import 'animated_sticker_view.dart';
import 'sticker_item.dart';
import 'video_sticker_view.dart';

class StickerPreview extends StatelessWidget {
  const StickerPreview({super.key, required this.item, this.cornerRadius = 6});
  final StickerItem item;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    final file = TdFileRef(id: item.id);
    if (item.isAnimated) return AnimatedStickerView(file: file);
    if (item.isVideo) {
      final fallback = item.thumb?.id == item.id ? null : item.thumb;
      if (fallback != null) {
        return VideoStickerView(file: file, fallback: fallback);
      }
      return Center(
        child: Text(
          item.emoji.isEmpty ? '🎴' : item.emoji,
          style: const TextStyle(fontSize: 30),
        ),
      );
    }
    if (item.thumb != null) {
      return TDImage(
        photo: item.thumb,
        cornerRadius: cornerRadius,
        fit: BoxFit.contain,
      );
    }
    return Center(
      child: Text(
        item.emoji.isEmpty ? '🎴' : item.emoji,
        style: const TextStyle(fontSize: 30),
      ),
    );
  }
}

class StickerTabPreview extends StatelessWidget {
  const StickerTabPreview({super.key, required this.item});

  final StickerItem item;

  @override
  Widget build(BuildContext context) {
    final thumbnail = item.thumb;
    final canRenderThumbnail =
        thumbnail != null &&
        (!(item.isAnimated || item.isVideo) || thumbnail.id != item.id);
    if (canRenderThumbnail) {
      return TDImage(photo: thumbnail, cornerRadius: 4, fit: BoxFit.contain);
    }
    if (item.emoji.isNotEmpty) {
      return Text(item.emoji, style: const TextStyle(fontSize: 22));
    }
    return AppIcon(
      HeroAppIcons.solidFaceSmile,
      size: 20,
      color: context.colors.textSecondary,
    );
  }
}
