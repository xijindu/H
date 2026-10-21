import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

const _bytesPerMiB = 1024 * 1024;

@immutable
class AppImageCacheBudget {
  const AppImageCacheBudget({required this.entries, required this.bytes});

  final int entries;
  final int bytes;
}

AppImageCacheBudget appImageCacheBudgetFor(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.android => const AppImageCacheBudget(
      entries: 320,
      bytes: 64 * _bytesPerMiB,
    ),
    TargetPlatform.iOS => const AppImageCacheBudget(
      entries: 400,
      bytes: 80 * _bytesPerMiB,
    ),
    _ => const AppImageCacheBudget(entries: 600, bytes: 128 * _bytesPerMiB),
  };
}

void configureAppImageCache({ImageCache? cache, TargetPlatform? platform}) {
  final target = cache ?? PaintingBinding.instance.imageCache;
  final budget = appImageCacheBudgetFor(platform ?? defaultTargetPlatform);
  target.maximumSize = budget.entries;
  target.maximumSizeBytes = budget.bytes;
}
