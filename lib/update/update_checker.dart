//
//  update_checker.dart
//
//  In-app update check against the project's GitHub Releases, on the platforms
//  Mithka distributes itself on. On launch it asks the latest release for its
//  tag (semver) and assets, compares the tag to the installed version, and
//  offers whatever that platform can act on:
//
//    Android — the APK for this device's ABI, handed to the browser.
//
//  iOS updates through the App Store and Google Play builds update through the
//  store, so neither is offered a package from GitHub Releases. The repo is
//  public, so the releases API needs no auth, and the launch check fails
//  silently (offline / rate-limited).
//

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:handy/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_version.dart';
import '../components/confirm_dialog.dart';
import 'release_feed.dart';

/// What a manual check from About found.
///
/// [maybePrompt] fails silently because it runs unasked on launch. A check the
/// user pressed has to say something either way.
enum UpdateCheckOutcome { upToDate, updateAvailable, unavailable }

class UpdateChecker {
  UpdateChecker._();

  static const _isGooglePlayBuild = bool.fromEnvironment('GOOGLE_PLAY_BUILD');
  static const _channel = MethodChannel('handy/app_info');
  static bool _checkedThisLaunch = false;

  /// Google Play builds update through the store and must not offer APKs from
  /// GitHub Releases. The optional argument keeps the distribution rule easy
  /// to verify without changing compile-time defines in the test process.
  static bool automaticChecksEnabled({
    bool isGooglePlayBuild = _isGooglePlayBuild,
  }) => !isGooglePlayBuild;

  /// Whether this platform ships packages Mithka can offer from GitHub.
  ///
  /// The optional argument keeps the rule testable off the target platform.
  static bool platformSelfDistributes({bool isAndroid = false}) => isAndroid;

  /// Checks once per launch and prompts when a newer build exists for this
  /// device. Safe to call from any screen's first frame; no-op otherwise.
  static Future<void> maybePrompt(BuildContext context) async {
    if (!supportsManualCheck || _checkedThisLaunch) return;
    _checkedThisLaunch = true;
    try {
      await _check(context, unasked: true);
    } catch (_) {
      // Offline, rate-limited, or no release yet — silently skip.
    }
  }

  /// Whether About shows a manual "check for updates" row.
  ///
  /// Same rule as the automatic check: only where Mithka distributes its own
  /// packages, and never on a Play build, where the store owns updates.
  static bool get supportsManualCheck =>
      automaticChecksEnabled() &&
      platformSelfDistributes(isAndroid: Platform.isAndroid);

  /// Runs a check the user asked for and reports what happened.
  ///
  /// Prompts exactly as the launch check does when a newer build exists, but a
  /// missing package or a failed request is an answer here rather than
  /// something to swallow.
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

  /// The running build's version, from the Android host or package metadata.
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
    // A newer release with no APK for this architecture is not something the
    // user can act on, so it is not reported as available.
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

  /// The release's APK for the device's preferred ABI, first match wins.
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
