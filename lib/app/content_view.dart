//
//  content_view.dart
//
//  Auth gate: shows the tab bar once TDLib reports ready, otherwise login.
//  Port of the Swift `ContentView`.
//

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_manager.dart';
import '../auth/login_view.dart';
import '../theme/app_theme.dart';
import 'main_tab_view.dart';

class ContentView extends StatelessWidget {
  const ContentView({super.key});

  @override
  Widget build(BuildContext context) {
    final step = context.watch<AuthManager>().step;
    final Widget child = switch (step) {
      AuthReady() => const MainTabView(),
      // No branded splash: a fast start-up leaves it on screen for only a few
      // frames, where the flash reads as a glitch. A plain background keeps
      // the hand-off from the native launch screen invisible.
      AuthInitializing() || AuthLoggingOut() =>
        ColoredBox(color: context.colors.background),
      _ => const LoginView(),
    };
    // Entering MainTabView is the one edge where the crossfade lands on the
    // frames that inflate the tab stack and the first chat rows; wrapping that
    // in a full-viewport opacity layer for 250 ms is the most expensive
    // rasterisation of the launch. Initializing <-> login still crossfades.
    final content = AnimatedSwitcher(
      duration: child is MainTabView
          ? Duration.zero
          : const Duration(milliseconds: 250),
      child: KeyedSubtree(key: ValueKey(child.runtimeType), child: child),
    );
    return content;
  }
}