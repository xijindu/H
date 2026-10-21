import 'dart:math' as math;
import 'dart:ui';

const double chatMediaPreviewMaxSide = 430;
const double chatMediaPreviewMinSide = 100;

const double telegramChatMediaPreviewMaxHeight = 320;

class MediaPreviewGeometry {
  const MediaPreviewGeometry({
    required this.contentSize,
    required this.frameSize,
  });

  final Size contentSize;

  final Size frameSize;

  bool get needsBlurredFill =>
      (contentSize.width - frameSize.width).abs() > 0.5 ||
      (contentSize.height - frameSize.height).abs() > 0.5;
}

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
