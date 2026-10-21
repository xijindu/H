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
      AuthInitializing() || AuthLoggingOut() =>
        ColoredBox(color: context.colors.background),
      _ => const LoginView(),
    };
    final content = AnimatedSwitcher(
      duration: child is MainTabView
          ? Duration.zero
          : const Duration(milliseconds: 250),
      child: KeyedSubtree(key: ValueKey(child.runtimeType), child: child),
    );
    return content;
  }
}