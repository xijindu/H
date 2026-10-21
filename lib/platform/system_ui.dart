import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void configureImmersiveSystemUI() {
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    systemUiOverlayStyleFor(Brightness.light),
  );
}

SystemUiOverlayStyle systemUiOverlayStyleFor(Brightness brightness) {
  final light = brightness == Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: light ? Brightness.light : Brightness.dark,
    statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: light
        ? Brightness.dark
        : Brightness.light,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );
}

SystemUiOverlayStyle systemUiOverlayStyleForSurface(Color surface) {
  return systemUiOverlayStyleFor(ThemeData.estimateBrightnessForColor(surface));
}

SystemUiOverlayStyle systemUiOverlayStyleForTheme(ThemeData theme) {
  return systemUiOverlayStyleFor(theme.brightness);
}

bool get supportsImmersiveSystemUI {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return true;
    default:
      return false;
  }
}
