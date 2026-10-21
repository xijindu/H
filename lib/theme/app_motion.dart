import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';

abstract final class AppMotion {
  static const Duration instant = Duration.zero;
  static const Duration quick = Duration(milliseconds: 140);
  static const Duration responsive = Duration(milliseconds: 190);
  static const Duration deliberate = Duration(milliseconds: 280);
  static const Duration route = Duration(milliseconds: 300);
  static const Duration routeReverse = Duration(milliseconds: 240);

  static const Curve standard = Cubic(0.20, 0.0, 0.0, 1.0);

  static const Curve accelerate = Cubic(0.30, 0.0, 1.0, 1.0);

  static const Curve emphasized = Cubic(0.05, 0.70, 0.10, 1.0);

  static bool isReduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  static Duration duration(BuildContext context, Duration normal) =>
      isReduced(context) ? instant : normal;

  static Widget dialogTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (isReduced(context)) return child;
    final entrance = CurvedAnimation(
      parent: animation,
      curve: emphasized,
      reverseCurve: accelerate,
    );
    return FadeTransition(
      opacity: entrance,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1).animate(entrance),
        child: child,
      ),
    );
  }
}

@visibleForTesting
const appCenteredModalFrameKey = ValueKey<String>('app-centered-modal-frame');

@visibleForTesting
const appCenteredModalSurfaceKey = ValueKey<String>(
  'app-centered-modal-surface',
);

bool appModalUsesCenteredPresentation(Size size, [TargetPlatform? platform]) {
  if (kIsWeb) return false;
  final targetPlatform = platform ?? defaultTargetPlatform;

  return targetPlatform == TargetPlatform.iOS &&
      size.width > size.height &&
      size.shortestSide >= 600;
}

Future<T?> showAppAdaptiveSheetDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required String barrierLabel,
  required Color barrierColor,
  required Duration transitionDuration,
  required RouteTransitionsBuilder mobileTransitionBuilder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  bool? requestFocus,
  Color? centeredBackgroundColor,
  ShapeBorder? centeredShape,
  Clip centeredClipBehavior = Clip.antiAlias,
  BoxConstraints? centeredConstraints,
  bool centeredUseSafeArea = true,
  Curve centeredTransitionCurve = AppMotion.emphasized,
  Curve centeredReverseTransitionCurve = AppMotion.accelerate,
}) {
  if (appModalUsesCenteredPresentation(MediaQuery.sizeOf(context))) {
    final centeredDuration = AppMotion.duration(context, transitionDuration);
    return showAppModalSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: centeredBackgroundColor,
      shape: centeredShape,
      clipBehavior: centeredClipBehavior,
      constraints: centeredConstraints,
      barrierLabel: barrierLabel,
      barrierColor: barrierColor,
      isScrollControlled: true,
      useRootNavigator: useRootNavigator,
      isDismissible: barrierDismissible,
      enableDrag: false,
      showDragHandle: false,
      useSafeArea: centeredUseSafeArea,
      routeSettings: routeSettings,
      anchorPoint: anchorPoint,
      requestFocus: requestFocus,
      sheetAnimationStyle: AnimationStyle(
        duration: centeredDuration,
        reverseDuration: centeredDuration,
        curve: centeredTransitionCurve,
        reverseCurve: centeredReverseTransitionCurve,
      ),
    );
  }

  return showGeneralDialog<T>(
    context: context,
    pageBuilder: (dialogContext, _, _) => builder(dialogContext),
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: barrierColor,
    transitionDuration: transitionDuration,
    transitionBuilder: mobileTransitionBuilder,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    requestFocus: requestFocus,
  );
}

Future<T?> showAppModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  double scrollControlDisabledMaxHeightRatio = 9.0 / 16.0,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool? requestFocus,
}) {
  final useCenteredPresentation = appModalUsesCenteredPresentation(
    MediaQuery.sizeOf(context),
  );
  final effectiveAnimationStyle =
      sheetAnimationStyle ??
      (AppMotion.isReduced(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              curve: AppMotion.emphasized,
              reverseCurve: AppMotion.accelerate,
              duration: AppMotion.deliberate,
              reverseDuration: AppMotion.responsive,
            ));
  if (useCenteredPresentation) {
    final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
    final materialLocalizations = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final sheetTheme = theme.bottomSheetTheme;
    final capturedThemes = InheritedTheme.capture(
      from: context,
      to: navigator.context,
    );
    final effectiveShape = switch (shape) {
      RoundedRectangleBorder() => shape.copyWith(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      final ShapeBorder value => value,
      null => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
    };
    final effectiveBackgroundColor =
        backgroundColor ??
        sheetTheme.modalBackgroundColor ??
        sheetTheme.backgroundColor ??
        theme.colorScheme.surface;
    final effectiveElevation =
        elevation ?? sheetTheme.modalElevation ?? sheetTheme.elevation ?? 0;
    final effectiveBarrierColor =
        barrierColor ?? sheetTheme.modalBarrierColor ?? Colors.black54;
    final forwardDuration =
        effectiveAnimationStyle.duration ?? AppMotion.deliberate;
    final reverseDuration =
        effectiveAnimationStyle.reverseDuration ?? AppMotion.responsive;

    return navigator.push<T>(
      _AppCenteredModalRoute<T>(
        pageBuilder: (dialogContext, _, _) {
          final centeredConstraints = _centeredModalConstraints(
            requested: constraints,
            availableSize: MediaQuery.sizeOf(dialogContext),
            isScrollControlled: isScrollControlled,
            scrollControlDisabledMaxHeightRatio:
                scrollControlDisabledMaxHeightRatio,
          );
          Widget content = Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                key: appCenteredModalFrameKey,
                constraints: centeredConstraints,
                child: SizedBox(
                  width: centeredConstraints.maxWidth,
                  child: Material(
                    key: appCenteredModalSurfaceKey,
                    color: effectiveBackgroundColor,
                    elevation: effectiveElevation,
                    shape: effectiveShape,
                    clipBehavior: clipBehavior ?? Clip.antiAlias,
                    child: builder(dialogContext),
                  ),
                ),
              ),
            ),
          );
          if (useSafeArea) content = SafeArea(child: content);
          return capturedThemes.wrap(content);
        },
        barrierDismissible: isDismissible,
        barrierLabel: barrierLabel ?? materialLocalizations.scrimLabel,
        barrierColor: effectiveBarrierColor,
        transitionDuration: forwardDuration,
        centeredReverseTransitionDuration: reverseDuration,
        transitionCurve: effectiveAnimationStyle.curve ?? AppMotion.emphasized,
        reverseTransitionCurve:
            effectiveAnimationStyle.reverseCurve ?? AppMotion.accelerate,
        settings: routeSettings,
        transitionAnimationController: transitionAnimationController,
        anchorPoint: anchorPoint,
        requestFocus: requestFocus,
      ),
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    backgroundColor: backgroundColor,
    barrierLabel: barrierLabel,
    elevation: elevation,
    shape: shape,
    clipBehavior: clipBehavior,
    constraints: constraints,
    barrierColor: barrierColor,
    isScrollControlled: isScrollControlled,
    scrollControlDisabledMaxHeightRatio: scrollControlDisabledMaxHeightRatio,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    transitionAnimationController: transitionAnimationController,
    anchorPoint: anchorPoint,
    sheetAnimationStyle: effectiveAnimationStyle,
    requestFocus: requestFocus,
  );
}

Future<T?> showAppCupertinoModalPopup<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  ui.ImageFilter? filter,
  Color barrierColor = cupertino.kCupertinoModalBarrierColor,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  bool semanticsDismissible = false,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  bool? requestFocus,
}) {
  if (!appModalUsesCenteredPresentation(MediaQuery.sizeOf(context))) {
    return cupertino.showCupertinoModalPopup<T>(
      context: context,
      builder: builder,
      filter: filter,
      barrierColor: barrierColor,
      barrierDismissible: barrierDismissible,
      useRootNavigator: useRootNavigator,
      semanticsDismissible: semanticsDismissible,
      routeSettings: routeSettings,
      anchorPoint: anchorPoint,
      requestFocus: requestFocus,
    );
  }

  return showAppModalSheet<T>(
    context: context,
    builder: builder,
    backgroundColor: Colors.transparent,
    barrierColor: cupertino.CupertinoDynamicColor.resolve(
      barrierColor,
      context,
    ),
    isScrollControlled: true,
    useRootNavigator: useRootNavigator,
    isDismissible: barrierDismissible,
    enableDrag: false,
    showDragHandle: false,
    useSafeArea: true,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    requestFocus: requestFocus,
  );
}

BoxConstraints _centeredModalConstraints({
  required BoxConstraints? requested,
  required Size availableSize,
  required bool isScrollControlled,
  required double scrollControlDisabledMaxHeightRatio,
}) {
  const outerPadding = 48.0;
  final availableWidth = math.max(0.0, availableSize.width - outerPadding);
  final availableHeight = math.max(0.0, availableSize.height - outerPadding);
  final requestedMaxWidth = requested?.maxWidth ?? double.infinity;
  final requestedMaxHeight = requested?.maxHeight ?? double.infinity;
  final maxWidth = math.min(requestedMaxWidth, availableWidth);
  final presentationMaxHeight = isScrollControlled
      ? availableHeight
      : availableHeight * scrollControlDisabledMaxHeightRatio;
  final maxHeight = math.min(requestedMaxHeight, presentationMaxHeight);
  return BoxConstraints(
    minWidth: math.min(requested?.minWidth ?? 0, maxWidth),
    maxWidth: maxWidth,
    minHeight: math.min(requested?.minHeight ?? 0, maxHeight),
    maxHeight: maxHeight,
  );
}

class _AppCenteredModalRoute<T> extends RawDialogRoute<T> {
  _AppCenteredModalRoute({
    required super.pageBuilder,
    required super.barrierDismissible,
    required super.barrierColor,
    required super.barrierLabel,
    required super.transitionDuration,
    required this.centeredReverseTransitionDuration,
    required Curve transitionCurve,
    required Curve reverseTransitionCurve,
    super.settings,
    this.transitionAnimationController,
    super.anchorPoint,
    super.requestFocus,
  }) : super(
         transitionBuilder: (context, animation, secondaryAnimation, child) {
           final entrance = CurvedAnimation(
             parent: animation,
             curve: transitionCurve,
             reverseCurve: reverseTransitionCurve,
           );
           return FadeTransition(
             opacity: entrance,
             child: ScaleTransition(
               scale: Tween<double>(begin: 0.94, end: 1).animate(entrance),
               child: child,
             ),
           );
         },
       );

  final AnimationController? transitionAnimationController;
  final Duration centeredReverseTransitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      transitionAnimationController?.reverseDuration ??
      transitionAnimationController?.duration ??
      centeredReverseTransitionDuration;

  @override
  Duration get transitionDuration =>
      transitionAnimationController?.duration ?? super.transitionDuration;

  @override
  AnimationController createAnimationController() {
    final externalController = transitionAnimationController;
    if (externalController == null) return super.createAnimationController();
    willDisposeAnimationController = false;
    return externalController;
  }
}

class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.route;

  @override
  Duration get reverseTransitionDuration => AppMotion.routeReverse;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _buildAppPageTransition(
    context: context,
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    child: child,
    fullscreenDialog: route.fullscreenDialog,
  );
}

class AppPageRoute<T> extends MaterialPageRoute<T> {
  AppPageRoute({
    super.settings,
    super.requestFocus,
    required this.pageBuilder,
    super.maintainState = true,
    super.fullscreenDialog = false,
    super.allowSnapshotting = true,
    super.barrierDismissible = false,
    super.traversalEdgeBehavior,
    super.directionalTraversalEdgeBehavior,
  }) : super(
         builder: (context) => pageBuilder(
           context,
           kAlwaysCompleteAnimation,
           kAlwaysDismissedAnimation,
         ),
       );

  final RoutePageBuilder pageBuilder;

  @override
  Widget buildContent(BuildContext context) =>
      pageBuilder(context, animation!, secondaryAnimation!);

  @override
  Duration get transitionDuration => AppMotion.route;

  @override
  Duration get reverseTransitionDuration => AppMotion.routeReverse;
}

class AppFadePageRoute<T> extends PageRouteBuilder<T> {
  AppFadePageRoute({
    super.settings,
    super.requestFocus,
    required super.pageBuilder,
    super.opaque = true,
    super.barrierDismissible = false,
    super.barrierColor,
    super.barrierLabel,
    super.maintainState = true,
    super.fullscreenDialog = false,
    super.allowSnapshotting = true,
  }) : super(
         transitionDuration: AppMotion.responsive,
         reverseTransitionDuration: AppMotion.quick,
         transitionsBuilder: (context, animation, _, child) {
           if (AppMotion.isReduced(context)) return child;
           final entrance = CurvedAnimation(
             parent: animation,
             curve: AppMotion.standard,
             reverseCurve: AppMotion.accelerate,
           );
           return FadeTransition(opacity: entrance, child: child);
         },
       );
}

Widget _buildAppPageTransition({
  required BuildContext context,
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
  required bool fullscreenDialog,
}) {
  if (AppMotion.isReduced(context)) return child;

  final entering = CurvedAnimation(
    parent: animation,
    curve: AppMotion.standard,
    reverseCurve: AppMotion.accelerate,
  );
  final covered = CurvedAnimation(
    parent: secondaryAnimation,
    curve: AppMotion.standard,
    reverseCurve: AppMotion.accelerate,
  );

  if (fullscreenDialog) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.9, end: 1).animate(entering),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(entering),
        transformHitTests: false,
        child: child,
      ),
    );
  }

  return FadeTransition(
    opacity: Tween<double>(begin: 1, end: 0.96).animate(covered),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.018, 0),
      ).animate(covered),
      transformHitTests: false,
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.92, end: 1).animate(entering),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.045, 0),
            end: Offset.zero,
          ).animate(entering),
          transformHitTests: false,
          child: child,
        ),
      ),
    ),
  );
}

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();
}
