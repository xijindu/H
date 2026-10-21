import '../tdlib/td_models.dart';

class StickerItem {
  const StickerItem({
    required this.id,
    this.remoteId,
    required this.width,
    required this.height,
    required this.emoji,
    this.isAnimated = false,
    this.isVideo = false,
    this.thumb,
    this.customEmojiId = 0,
  });
  final int id;
  final String? remoteId;
  final int width;
  final int height;
  final String emoji;
  final bool isAnimated;
  final bool isVideo;
  final TdFileRef? thumb;
  final int customEmojiId;
}
