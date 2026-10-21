const int inlineVideoAutoplayMaxArea = 1920 * 1080;

const int inlineVideoAutoplayMaxBytes = 8 * 1024 * 1024;

bool shouldAutoplayVideoInline({
  required String? contentType,
  required int? fileSizeBytes,
  required int? width,
  required int? height,
}) {
  switch (contentType) {
    case 'messageAnimation':
      return true;
    case 'messageVideo':
    case 'messageVideoNote':
      final size = fileSizeBytes ?? 0;
      if (size <= 0 || size > inlineVideoAutoplayMaxBytes) return false;
      return _fitsInlineFrame(width, height);
    default:
      return false;
  }
}

bool _fitsInlineFrame(int? width, int? height) {
  final frameWidth = width ?? 0;
  final frameHeight = height ?? 0;
  if (frameWidth <= 0 || frameHeight <= 0) return true;
  return frameWidth * frameHeight <= inlineVideoAutoplayMaxArea;
}
