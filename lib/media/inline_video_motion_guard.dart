import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

class InlineVideoMotionGuard extends StatelessWidget {
  const InlineVideoMotionGuard({
    super.key,
    required this.viewType,
    required this.child,
    this.placeholder = const SizedBox.shrink(),
  });

  final VideoViewType viewType;
  final Widget child;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        viewType != VideoViewType.platformView) {
      return child;
    }
    final vertical = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    final horizontal = Scrollable.maybeOf(
      context,
      axis: Axis.horizontal,
    )?.position;
    final route = ModalRoute.of(context);
    final entrance = route?.animation;
    final covering = route?.secondaryAnimation;
    return AnimatedBuilder(
      animation: Listenable.merge([
        vertical?.isScrollingNotifier,
        horizontal?.isScrollingNotifier,
        entrance,
        covering,
      ]),
      child: child,
      builder: (context, child) {
        final obscuredOrMoving =
            (route != null && !route.isCurrent) ||
            (vertical?.isScrollingNotifier.value ?? false) ||
            (horizontal?.isScrollingNotifier.value ?? false) ||
            (entrance != null && !entrance.isCompleted) ||
            (covering != null && !covering.isDismissed);
        return obscuredOrMoving ? placeholder : child!;
      },
    );
  }
}
