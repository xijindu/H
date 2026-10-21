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
