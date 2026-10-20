//
//  icon_grid.dart
//
//  Lays out fixed-width icon tiles (avatar/glyph + label) in tight rows. Unlike
//  GridView + childAspectRatio — where each cell's height is derived from its
//  width and dwarfs the content, leaving huge vertical slack — this measures the
//  row width, fixes each tile's width, and lets the tile keep its own (content)
//  height. Row gap = [runSpacing]; the whole grid hugs its content.
//

import 'package:flutter/widgets.dart';

class IconGrid extends StatelessWidget {
  const IconGrid({
    super.key,
    required this.perRow,
    required this.children,
    this.spacing = 8,
    this.runSpacing = 14,
  });

  final int perRow;
  final double spacing;
  final double runSpacing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileW = (constraints.maxWidth - spacing * (perRow - 1)) / perRow;
        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final child in children) SizedBox(width: tileW, child: child),
          ],
        );
      },
    );
  }
}
