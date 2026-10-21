import 'package:flutter/widgets.dart';

import 'app_theme.dart';

final List<Color> _defaultNameColors = AppTheme.avatarPalette
    .take(7)
    .toList(growable: false);

List<Color> messageNameColorsForTheme() => _defaultNameColors;

Color messageNameColorForSender({
  required int accentColorId,
  required bool showNameColors,
  required Color nameColorsDisabledFallback,
}) {
  if (!showNameColors) {
    return nameColorsDisabledFallback;
  }
  final colors = messageNameColorsForTheme();
  final paletteIndex = accentColorId < 0 ? 0 : accentColorId % colors.length;
  return colors[paletteIndex];
}
