import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../theme/app_motion.dart';
import '../theme/app_theme.dart';

/// Glass fallback for non-iOS hosts. The shell overlays this transparent
/// surface above the scrollable content, with no opaque backing strip.
class LiquidGlassBottomBar extends StatelessWidget {
  const LiquidGlassBottomBar({
    super.key,
    required this.selection,
    required this.itemCount,
    required this.child,
    this.trailing,
    this.trailingGap = 14,
  }) : assert(itemCount > 0),
       assert(selection >= 0 && selection < itemCount);

  final int selection;
  final int itemCount;
  final Widget child;

  /// Optional trailing widget rendered to the right of the glass bar. It is
  /// wrapped in an identical glass surface for visual cohesion.
  final Widget? trailing;

  /// Horizontal gap between the glass pill and the trailing glass button.
  final double trailingGap;

  // Fixed palette primitives — hoisted out of the build hot path.
  static const _white = Color(0xFFFFFFFF);
  static const _black = Color(0xFF000000);

  /// Shared theme-derived values extracted once per build.
  static ({
    Color rim,
    Color tint,
    BorderRadius pillRadius,
    bool dark,
  }) _glassPalette(AppColors colors) {
    final dark = colors.navBar.computeLuminance() < 0.5;
    return (
      rim: _white.withValues(alpha: dark ? 0.22 : 0.85),
      tint: colors.navBar.withValues(alpha: dark ? 0.78 : 0.64),
      pillRadius: const BorderRadius.all(Radius.circular(AppRadius.pill)),
      dark: dark,
    );
  }

  Widget _buildGlassSurface({
    required Widget child,
    required BorderRadius radius,
    required AppColors colors,
    required bool highContrast,
    required ({Color rim, Color tint, BorderRadius pillRadius, bool dark})
    palette,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: _black.withValues(alpha: palette.dark ? 0.24 : 0.09),
            blurRadius: 20,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          enabled: !highContrast,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              color: highContrast ? colors.navBar : null,
              gradient: highContrast
                  ? null
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.alphaBlend(
                          _white.withValues(
                            alpha: palette.dark ? 0.09 : 0.48,
                          ),
                          palette.tint,
                        ),
                        palette.tint,
                        Color.alphaBlend(
                          colors.linkBlue.withValues(alpha: 0.045),
                          palette.tint,
                        ),
                      ],
                      stops: const [0, 0.52, 1],
                    ),
              border: Border.all(
                color: highContrast ? colors.textSecondary : palette.rim,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final highContrast = MediaQuery.highContrastOf(context);
    final palette = _glassPalette(colors);

    final glass = _buildGlassSurface(
      radius: palette.pillRadius,
      colors: colors,
      highContrast: highContrast,
      palette: palette,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tabAreaWidth = constraints.maxWidth;
            return Stack(
              children: [
                AnimatedPositionedDirectional(
                  duration: AppMotion.duration(
                    context,
                    AppMotion.deliberate,
                  ),
                  curve: AppMotion.emphasized,
                  start: tabAreaWidth * selection / itemCount,
                  width: tabAreaWidth / itemCount,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: const ValueKey(
                        'liquid-glass-selection',
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          AppRadius.pill,
                        ),
                        color: colors.linkBlue.withValues(
                          alpha: highContrast
                              ? 0.22
                              : (palette.dark ? 0.19 : 0.10),
                        ),
                        border: Border.all(
                          color: highContrast
                              ? colors.linkBlue
                              : _white.withValues(
                                  alpha: palette.dark ? 0.16 : 0.70,
                                ),
                          width: 0.8,
                        ),
                      ),
                    ),
                  ),
                ),
                child,
              ],
            );
          },
        ),
      ),
    );

    Widget content = glass;
    if (trailing != null) {
      // glass's intrinsic height = controls(46) + inner Padding(5*2) = 56.
      const trailingSize = 56.0;
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: glass),
          SizedBox(width: trailingGap),
          SizedBox(
            width: trailingSize,
            height: trailingSize,
            child: _buildGlassSurface(
              radius: BorderRadius.circular(trailingSize / 2),
              colors: colors,
              highContrast: highContrast,
              palette: palette,
              child: trailing!,
            ),
          ),
        ],
      );
    }

    return SafeArea(
      key: const ValueKey('liquid-glass-bottom-bar'),
      top: false,
      minimum: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: content,
      ),
    );
  }
}
