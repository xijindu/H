import 'package:flutter/widgets.dart' show ScrollMetrics;

const pinnedMessageScrollAlignment = 0.08;
const pinnedMessageTargetTopInset = 72.0;

double distanceToOldest(ScrollMetrics metrics) => metrics.extentBefore;

double distanceToLatest(ScrollMetrics metrics) => metrics.extentAfter;

class OldestHistoryPullController {
  OldestHistoryPullController({this.triggerDistance = 52})
    : assert(triggerDistance > 0);

  final double triggerDistance;
  double _distance = 0;
  bool _triggered = false;

  double get distance => _distance;
  bool get triggered => _triggered;

  bool addClampedOverscroll(double overscroll) {
    if (overscroll >= 0 || _triggered) return false;
    _distance += -overscroll;
    return _maybeTrigger();
  }

  bool updateBouncingPosition(ScrollMetrics metrics) {
    if (_triggered) return false;
    final beyondOldest = metrics.minScrollExtent - metrics.pixels;
    if (beyondOldest <= 0) return false;
    _distance = beyondOldest > _distance ? beyondOldest : _distance;
    return _maybeTrigger();
  }

  void reset() {
    _distance = 0;
    _triggered = false;
  }

  bool _maybeTrigger() {
    if (_triggered || _distance < triggerDistance) return false;
    _triggered = true;
    return true;
  }
}

bool isNearOldest(ScrollMetrics metrics, {required double threshold}) {
  assert(threshold >= 0);
  return distanceToOldest(metrics) <= threshold;
}

bool isNearLatest(ScrollMetrics metrics, {required double threshold}) {
  assert(threshold >= 0);
  return distanceToLatest(metrics) <= threshold;
}

double clampScrollOffset(ScrollMetrics metrics, double offset) =>
    offset.clamp(metrics.minScrollExtent, metrics.maxScrollExtent);

double pinnedMessageTargetScrollOffset(
  ScrollMetrics metrics, {
  required double targetTop,
  required double viewportTop,
  double topInset = pinnedMessageTargetTopInset,
}) => clampScrollOffset(
  metrics,
  metrics.pixels + targetTop - (viewportTop + topInset),
);

double scrollFraction(ScrollMetrics metrics, {double? offset}) {
  final extent = metrics.maxScrollExtent - metrics.minScrollExtent;
  if (extent <= 0) return 0;
  final clampedOffset = clampScrollOffset(metrics, offset ?? metrics.pixels);
  return (clampedOffset - metrics.minScrollExtent) / extent;
}

double scrollOffsetForFraction(ScrollMetrics metrics, double fraction) {
  final extent = metrics.maxScrollExtent - metrics.minScrollExtent;
  if (extent <= 0) return metrics.minScrollExtent;
  final clampedFraction = fraction.clamp(0.0, 1.0);
  return metrics.minScrollExtent + extent * clampedFraction;
}
