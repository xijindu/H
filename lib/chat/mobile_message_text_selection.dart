import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;

class MobileMessageTextSelectionArea extends StatefulWidget {
  const MobileMessageTextSelectionArea({
    super.key,
    required this.selectionAreaKey,
    required this.onSelectionChanged,
    required this.onDisposed,
    required this.child,
  });

  final GlobalKey<SelectionAreaState> selectionAreaKey;
  final ValueChanged<SelectedContent?>? onSelectionChanged;
  final VoidCallback onDisposed;
  final Widget child;

  @override
  State<MobileMessageTextSelectionArea> createState() =>
      _MobileMessageTextSelectionAreaState();
}

class _MobileMessageTextSelectionAreaState
    extends State<MobileMessageTextSelectionArea> {
  @override
  void dispose() {
    final onDisposed = widget.onDisposed;
    WidgetsBinding.instance.addPostFrameCallback((_) => onDisposed());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    key: widget.selectionAreaKey,
    onSelectionChanged: widget.onSelectionChanged,
    child: widget.child,
  );
}
