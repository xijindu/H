import 'dart:math' as math;
import 'dart:ui';

/// Ordinary chat media stays inside a 430 x 430 logical-pixel box, and at least
/// 100 logical pixels are reserved for either preview dimension.
const double chatMediaPreviewMaxSide = 430;
const double chatMediaPreviewMinSide = 100;

/// Chat media fits into a 320 x 320 box, and only a landscape video may grow
/// wider than that. Height therefore stops short of the square media box: at
/// the full 430 a portrait photo or clip becomes a strip that pushes the rest
/// of the message off screen, taller than the layout intends.
const double telegramChatMediaPreviewMaxHeight = 320;

class MediaPreviewGeometry {
  const MediaPreviewGeometry({
    required this.contentSize,
    required this.frameSize,
  });

  /// Aspect-preserving source size, never enlarged beyond its source pixels.
  final Size contentSize;

  /// Stable layout box. Very small or extremely narrow media can use a
  /// low-resolution blurred fill around [contentSize].
  final Size frameSize;

  bool get needsBlurredFill =>
      (contentSize.width - frameSize.width).abs() > 0.5 ||
      (contentSize.height - frameSize.height).abs() > 0.5;
}

/// Chat-media preview geometry at Flutter logical-pixel scale: downscale into
/// the fixed media box, downscale again for a narrow chat pane, never upscale
/// the source, then enforce a small stable layout box.
///
/// [maxHeight] lets a caller keep tall media shorter than the square media box
/// — see [telegramChatMediaPreviewMaxHeight].
MediaPreviewGeometry chatMediaPreviewGeometry({
  required int? sourceWidth,
  required int? sourceHeight,
  required double availableWidth,
  double maxHeight = chatMediaPreviewMaxSide,
}) {
  final available = availableWidth.isFinite && availableWidth > 0
      ? math.min(availableWidth, chatMediaPreviewMaxSide)
      : chatMediaPreviewMaxSide;
  final boundedAvailable = math.max(1.0, available);
  final boundedMaxHeight = math.max(
    1.0,
    math.min(maxHeight, chatMediaPreviewMaxSide),
  );
  final width = sourceWidth ?? 0;
  final height = sourceHeight ?? 0;
  if (width <= 0 || height <= 0) {
    final fallback = Size(
      boundedAvailable,
      math.min(boundedAvailable, boundedMaxHeight),
    );
    return MediaPreviewGeometry(contentSize: fallback, frameSize: fallback);
  }

  final downscale = math.min(
    1.0,
    math.min(
      chatMediaPreviewMaxSide / width,
      boundedMaxHeight / height,
    ),
  );
  var contentWidth = width * downscale;
  var contentHeight = height * downscale;
  final paneScale = math.min(
    1.0,
    math.min(boundedAvailable / contentWidth, boundedAvailable / contentHeight),
  );
  contentWidth = math.max(1.0, contentWidth * paneScale);
  contentHeight = math.max(1.0, contentHeight * paneScale);

  final minimum = math.min(
    chatMediaPreviewMinSide,
    boundedAvailable,
  );
  final content = Size(contentWidth, contentHeight);
  final frame = Size(
    math.max(contentWidth, minimum),
    math.max(contentHeight, math.min(minimum, boundedMaxHeight)),
  );
  return MediaPreviewGeometry(contentSize: content, frameSize: frame);
}
