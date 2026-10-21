import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:handy/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_version.dart';
import '../components/confirm_dialog.dart';
import 'release_feed.dart';

enum UpdateCheckOutcome { upToDate, updateAvailable, unavailable }

class UpdateChecker {
  UpdateChecker._();

  static const _isGooglePlayBuild = bool.fromEnvironment('GOOGLE_PLAY_BUILD');
  static const _channel = MethodChannel('handy/app_info');
  static bool _checkedThisLaunch = false;

  static bool automaticChecksEnabled({
    bool isGooglePlayBuild = _isGooglePlayBuild,
  }) => !isGooglePlayBuild;

  static bool platformSelfDistributes({bool isAndroid = false}) => isAndroid;

  static Future<void> maybePrompt(BuildContext context) async {
    if (!supportsManualCheck || _checkedThisLaunch) return;
    _checkedThisLaunch = true;
    try {
      await _check(context, unasked: true);
    } catch (_) {}
  }

  static bool get supportsManualCheck =>
      automaticChecksEnabled() &&
      platformSelfDistributes(isAndroid: Platform.isAndroid);

  static Future<UpdateCheckOutcome> checkNow(BuildContext context) async {
    if (!supportsManualCheck) return UpdateCheckOutcome.unavailable;
    try {
      return await _check(context, unasked: false);
    } catch (_) {
      return UpdateCheckOutcome.unavailable;
    }
  }

  static Future<UpdateCheckOutcome> _check(
    BuildContext context, {
    required bool unasked,
  }) async {
    final current = await _installedVersion();
    if (current.isEmpty) return UpdateCheckOutcome.unavailable;

    final release = await fetchLatestRelease();
    if (release == null) return UpdateCheckOutcome.unavailable;
    if (compareReleaseVersions(release.version, current) <= 0) {
      return UpdateCheckOutcome.upToDate;
    }

    if (!context.mounted) return UpdateCheckOutcome.updateAvailable;
    if (Platform.isAndroid) {
      return _offerAndroidApk(context, release, current);
    }
    return UpdateCheckOutcome.updateAvailable;
  }

  static Future<String> _installedVersion() async {
    if (Platform.isAndroid) {
      final info = await _channel.invokeMethod<Map<dynamic, dynamic>>('info');
      return (info?['version'] as String?) ?? '';
    }
    return (await AppVersion.load()).version;
  }

  static Future<List<String>> _deviceAbis() async {
    final info = await _channel.invokeMethod<Map<dynamic, dynamic>>('info');
    return ((info?['abis'] as List?) ?? const []).whereType<String>().toList();
  }

  static Future<UpdateCheckOutcome> _offerAndroidApk(
    BuildContext context,
    ReleaseInfo release,
    String current,
  ) async {
    final abis = await _deviceAbis();
    if (abis.isEmpty) return UpdateCheckOutcome.unavailable;
    final url = _apkFor(release, abis);
    if (url == null) return UpdateCheckOutcome.unavailable;
    if (!context.mounted) return UpdateCheckOutcome.updateAvailable;

    final ok = await confirmDialog(
      context,
      title: AppStrings.t(AppStringKeys.updateNewVersionFound),
      message: AppStrings.t(AppStringKeys.updateVersionPrompt, {
        'value1': current,
        'value2': release.version,
      }),
      confirmText: AppStrings.t(AppStringKeys.updateAction),
      cancelText: AppStrings.t(AppStringKeys.updateLater),
    );
    if (ok && context.mounted) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
    return UpdateCheckOutcome.updateAvailable;
  }

  static String? _apkFor(ReleaseInfo release, List<String> abis) {
    for (final abi in abis) {
      for (final asset in release.assets) {
        if (asset.name.endsWith('.apk') && asset.name.contains(abi)) {
          return asset.url;
        }
      }
    }
    return null;
  }
}
