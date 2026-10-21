import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

const double iPadWindowControlsTopInset = 40;

const int _windowControlsMinimumMajorVersion = 26;

const double _sizeTolerance = 2;

final RegExp _versionPattern = RegExp(r'Version (\d+)');

int? _cachedHostMajorVersion;

double iPadWindowChromeInsetOf(BuildContext context) {
  final view = View.of(context);
  return iPadWindowChromeInset(
    viewSize: view.physicalSize,
    displaySize: view.display.size,
    paddingTop: MediaQuery.of(context).padding.top,
  );
}

double iPadWindowChromeInset({
  required Size viewSize,
  required Size displaySize,
  required double paddingTop,
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
  String? operatingSystemVersion,
}) {
  if (isWeb) return 0;
  if ((platform ?? defaultTargetPlatform) != TargetPlatform.iOS) return 0;
  if (!_supportsWindowControls(operatingSystemVersion)) return 0;
  final floating =
      paddingTop > 0 && paddingTop <= 16 ||
      _isSmallerInBothDimensions(viewSize, displaySize);
  return floating ? iPadWindowControlsTopInset : 0;
}

bool _isSmallerInBothDimensions(Size size, Size other) {
  final sides = [size.width, size.height]..sort();
  final otherSides = [other.width, other.height]..sort();
  return sides[0] < otherSides[0] - _sizeTolerance &&
      sides[1] < otherSides[1] - _sizeTolerance;
}

bool _supportsWindowControls(String? operatingSystemVersion) {
  final major = operatingSystemVersion == null
      ? _hostMajorVersion()
      : _parseMajorVersion(operatingSystemVersion);
  return major != null && major >= _windowControlsMinimumMajorVersion;
}

int? _hostMajorVersion() {
  return _cachedHostMajorVersion ??= _parseMajorVersion(
    _safeOperatingSystemVersion(),
  );
}

String _safeOperatingSystemVersion() {
  try {
    return Platform.operatingSystemVersion;
  } catch (_) {
    return '';
  }
}

int? _parseMajorVersion(String operatingSystemVersion) {
  final match = _versionPattern.firstMatch(operatingSystemVersion);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}
