import 'package:flutter/widgets.dart';

import 'app_theme.dart';

// Hoisted so a themeless chat does not re-slice the palette once per bubble.
final List<Color> _defaultNameColors = AppTheme.avatarPalette
    .take(7)
    .toList(growable: false);

/// Telegram's seven assigned sender-name colors in `accent_color_id` order:
/// red, orange, violet, green, cyan, blue, and pink.
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
