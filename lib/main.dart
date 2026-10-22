import 'dart:async';
import 'dart:ui' as ui;

import 'package:f_videoplayer_fvp/f_videoplayer_fvp.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app_navigator.dart';
import 'app/app_version.dart';
import 'app/image_cache_config.dart';
import 'app/chat_deep_link_controller.dart';
import 'app/content_view.dart';
import 'app/deep_link_service.dart';
import 'app/global_video_split_host.dart';
import 'app/horizontal_safe_viewport.dart';
import 'app/telemetry_config.dart';
import 'auth/account_store.dart';
import 'auth/auth_manager.dart';
import 'call/call_manager.dart';
import 'call/call_overlay_host.dart';
import 'chat/animated_sticker_view.dart';
import 'chat/chat_view.dart';
import 'chat/music_player_controller.dart';
import 'chats/chat_folder_tag_controller.dart';
import 'components/keyboard_dismiss_on_tap.dart';
import 'l10n/app_locale_controller.dart';
import 'l10n/app_localizations.dart';
import 'media/video_playback_reporting.dart';
import 'media/video_view_compatibility.dart';
import 'notifications/in_app_notification_banner.dart';
import 'notifications/notification_controller.dart';
import 'notifications/push_device_registrar.dart';
import 'platform/firebase_configuration.dart';
import 'platform/system_ui.dart';
import 'security/local_app_lock_controller.dart';
import 'security/local_app_lock_views.dart';
import 'settings/auto_download_media_controller.dart';
import 'settings/blocked_user_service.dart';
import 'settings/business_service.dart';
import 'settings/country_message_filter.dart';
import 'settings/hidden_sender_store.dart';
import 'settings/keyword_blocker.dart';
import 'settings/safety_notice_controller.dart';
import 'settings/sensitive_content_controller.dart';
import 'settings/translation_controller.dart';
import 'tdlib/td_client.dart';
import 'theme/app_motion.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

Future<void> _preloadLocaleCatalogue([SharedPreferences? prefs]) {
  WidgetsFlutterBinding.ensureInitialized();
  Locale? saved;
  if (prefs != null) {
    final reader = AppLocaleController(prefs);
    saved = reader.locale;
    reader.dispose();
  }
  final locale = saved ?? ui.PlatformDispatcher.instance.locale;
  AppStrings.setLocale(locale);
  return AppStrings.ensureLoaded(locale);
}

Future<void> main(List<String> arguments) async {
  if (!sentryEnabled) {
    WidgetsFlutterBinding.ensureInitialized();
    configureAppImageCache();
    await _bootstrapAndRunApp();
    return;
  }

  await SentryFlutter.init(
    _configureSentry,
    appRunner: () async {
      configureAppImageCache();
      await _bootstrapAndRunApp();
    },
  );
}

Future<void> _bootstrapAndRunApp() async {
  GoogleFonts.config.allowRuntimeFetching = true;
  final auth = AuthManager()..start();
  _initializeVideoBackend();
  unawaited(
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]),
  );
  configureImmersiveSystemUI();
  final prefs = await SharedPreferences.getInstance();
  await Future.wait<void>([
    _preloadLocaleCatalogue(prefs),
    LocalAppLockController.shared.initialize(),
    ThemeController.preloadCachedEmojiFont(prefs),
    initializeCompatibleVideoViewType(),
  ]);
  KeywordBlocker.shared.initialize(prefs);
  HiddenSenderStore.shared.initialize(prefs);
  CountryMessageFilter.shared.initialize(prefs);
  unawaited(SensitiveContentController.shared.initialize());
  MusicPlayerController.shared.initialize(prefs);
  unawaited(BlockedUserService.shared.loadBlockedUsers());
  unawaited(
    SchedulerBinding.instance.scheduleTask<void>(_initTelemetry, Priority.idle),
  );
  final app = HandyApp(prefs: prefs, auth: auth);
  _runAppWithNonFatalGoogleFonts(app);
}

bool _shouldUseFvp() {
  if (kIsWeb) return false;
  if (defaultTargetPlatform == TargetPlatform.android) {
    return false;
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return true;
  }
  return true;
}

void _initializeVideoBackend() {
  try {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      FVideoFvpBackend.ensureAndroidAlphaWebmDecoderInitialized();
      return;
    }
    if (!_shouldUseFvp()) return;
    FVideoFvpBackend.ensureInitialized(
      configuration: const FVideoFvpConfiguration(
        platforms: {FVideoFvpPlatform.ios},
      ),
    );
  } catch (error, stackTrace) {
    debugPrint('FVP unavailable; using the platform video backend: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}

Future<void> _initTelemetry() async {
  try {
    final (hasFirebaseConfiguration, appVersion) = await (
      FirebaseConfiguration.isAvailable,
      AppVersion.load(),
    ).wait;
    if (hasFirebaseConfiguration) {
      await Firebase.initializeApp();
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true);
      await FirebaseAnalytics.instance.setDefaultEventParameters(
        appVersion.analyticsParameters,
      );
      await FirebaseAnalytics.instance.logAppOpen(
        parameters: appVersion.analyticsParameters,
      );
    } else {
      debugPrint('Firebase configuration not found; analytics disabled');
    }
    if (sentryEnabled) {
      await Sentry.configureScope((scope) async {
        await scope.setTag('app.version', appVersion.version);
        await scope.setTag('app.build_number', appVersion.buildNumber);
        await scope.setTag('git.commit', appVersion.commit);
      });
    }
  } catch (error) {
    debugPrint('telemetry init failed: $error');
  }
}

void _configureSentry(SentryFlutterOptions options) {
  options.dsn = sentryDsn;
  options.environment = sentryEnvironment;
  options.navigatorKey = appNavigatorKey;
  options.sendDefaultPii = false;
  options.tracesSampleRate = sentryTracesSampleRate;
  options.maxBreadcrumbs = 200;
  options.beforeSend = (event, hint) => _isGoogleFontLoadFailure(event)
      ? null
      : sanitizeVideoPlaybackEvent(event);
}

bool _isGoogleFontLoadFailure(SentryEvent event) {
  final parts = <String>[
    event.throwable?.toString() ?? '',
    event.message?.formatted ?? '',
    event.message?.template ?? '',
    for (final exception in event.exceptions ?? const [])
      '${exception.type ?? ''} ${exception.value ?? ''}',
  ];
  return _isGoogleFontLoadFailureText(parts.join('\n'));
}

void _runAppWithNonFatalGoogleFonts(Widget app) {
  final previousFlutterOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (_isGoogleFontLoadFailureText(details.exceptionAsString())) return;
    previousFlutterOnError?.call(details);
  };

  final previousPlatformOnError = ui.PlatformDispatcher.instance.onError;
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    if (_isGoogleFontLoadFailureText(error.toString())) return true;
    return previousPlatformOnError?.call(error, stack) ?? false;
  };

  runApp(app);
}

bool _isGoogleFontLoadFailureText(String value) {
  final text = value.toLowerCase();
  final isGoogleFonts =
      text.contains('google_fonts') ||
      text.contains('googlefonts') ||
      text.contains('fonts.gstatic.com') ||
      text.contains('fonts.googleapis.com');
  if (!isGoogleFonts) return false;
  return text.contains('failed to load font') ||
      text.contains('unable to load font') ||
      text.contains('handshakeexception') ||
      text.contains('socketexception') ||
      text.contains('clientexception');
}

typedef _HandyAppConsumer =
    Consumer3<ThemeController, AccountStore, AppLocaleController>;

class HandyApp extends StatefulWidget {
  const HandyApp({super.key, required this.prefs, this.auth});
  final SharedPreferences prefs;

  final AuthManager? auth;

  @override
  State<HandyApp> createState() => _HandyAppState();
}

class _HandyAppState extends State<HandyApp> with WidgetsBindingObserver {
  late final AuthManager _auth = widget.auth ?? AuthManager();
  late final AccountStore _accounts = AccountStore(widget.prefs);
  late final ThemeController _theme = ThemeController(
    widget.prefs,
    initialAccountSlot: _accounts.activeSlot,
    initialAccountUserId: _accounts.activeUserId,
  );
  late final TranslationController _translation = TranslationController(
    widget.prefs,
  );
  late final AppLocaleController _locale = AppLocaleController(widget.prefs);
  late final ChatDeepLinkController _chatDeepLinks =
      ChatDeepLinkController.shared;
  late final ChatFolderTagController _folderTags = ChatFolderTagController(
    widget.prefs,
  );
  late final AutoDownloadMediaController _autoDownload =
      AutoDownloadMediaController.shared;
  late final SafetyNoticeController _safetyNotice = SafetyNoticeController(
    widget.prefs,
  );
  late final SensitiveContentController _sensitiveContent =
      SensitiveContentController.shared;
  late final LocalAppLockController _appLock = LocalAppLockController.shared;
  late final CallManager _calls = CallManager()..start();

  bool _wasBackgrounded = true;

  @override
  void initState() {
    super.initState();
    MusicPlayerController.shared.setActiveAccountSlot(_accounts.activeSlot);
    WidgetsBinding.instance.addObserver(this);
    _accounts.addListener(_handleActiveAccountChange);
    _theme.addListener(_handleThemePreferencesChange);
    BusinessQuickReplyService.shared.startPreloading(
      enabled: _theme.quickRepliesEnabled,
    );
    unawaited(
      SchedulerBinding.instance.scheduleTask<void>(
        _theme.loadSelectedEmojiFontIfAvailable,
        Priority.idle,
      ),
    );
    _autoDownload.initialize(widget.prefs);
    _auth.start();
    DeepLinkService.shared.start();
    unawaited(_folderTags.refresh());
    unawaited(_accounts.recoverPendingAddOnStartup(_auth));
    NotificationController.shared.start(widget.prefs);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => PushDeviceRegistrar.shared.start(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accounts.removeListener(_handleActiveAccountChange);
    _theme.removeListener(_handleThemePreferencesChange);
    _folderTags.dispose();
    _calls.dispose();
    super.dispose();
  }

  void _handleActiveAccountChange() {
    MusicPlayerController.shared.setActiveAccountSlot(_accounts.activeSlot);
    unawaited(_folderTags.refresh());
    _theme.setActiveAccountSlot(
      _accounts.activeSlot,
      userId: _accounts.activeUserId,
    );
  }

  void _handleThemePreferencesChange() {
    BusinessQuickReplyService.shared.setPreloadingEnabled(
      _theme.quickRepliesEnabled,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLock.handleLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      clearChatMemoryCaches();
      clearAnimatedStickerMemoryCache();
    }
    if (state != AppLifecycleState.resumed) {
      if (state != AppLifecycleState.inactive) _wasBackgrounded = true;
      return;
    }
    TdClient.shared.restartReceiveIsolate();
    if (!_wasBackgrounded) return;
    _wasBackgrounded = false;
  }

  @override
  void didHaveMemoryPressure() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    clearChatMemoryCaches();
    clearAnimatedStickerMemoryCache();
  }

  final Map<Brightness, _ThemeDataMemo> _themeDataMemo = {};

  ThemeData _themeData(Brightness brightness, ThemeController theme) {
    final colors = theme.uiColorsFor(brightness);
    final families = theme.effectiveFontFamilyChain();
    final seedColor = theme.brandColor;
    final memo = _themeDataMemo[brightness];
    if (memo != null &&
        memo.colors == colors &&
        memo.seedColor == seedColor &&
        listEquals(memo.families, families)) {
      return memo.data;
    }
    final base = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamily: families.isEmpty ? null : families.first,
      fontFamilyFallback: families.length > 1
          ? families.skip(1).toList()
          : null,
      scaffoldBackgroundColor: colors.background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: brightness,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AppPageTransitionsBuilder(),
          TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      extensions: [colors],
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
    final data = base.copyWith(
      textTheme: theme.applyAppTextTheme(base.textTheme),
      primaryTextTheme: theme.applyAppTextTheme(base.primaryTextTheme),
    );
    _themeDataMemo[brightness] = _ThemeDataMemo(
      colors: colors,
      families: families,
      seedColor: seedColor,
      data: data,
    );
    return data;
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _auth),
        ChangeNotifierProvider.value(value: _theme),
        ChangeNotifierProvider.value(value: _translation),
        ChangeNotifierProvider.value(value: _locale),
        ChangeNotifierProvider.value(value: _accounts),
        ChangeNotifierProvider.value(value: _folderTags),
        ChangeNotifierProvider.value(value: _chatDeepLinks),
        ChangeNotifierProvider.value(value: _autoDownload),
        ChangeNotifierProvider.value(value: _safetyNotice),
        ChangeNotifierProvider.value(value: _sensitiveContent),
        ChangeNotifierProvider.value(value: _appLock),
        ChangeNotifierProvider.value(value: _calls),
      ],
      child: _HandyAppConsumer(
        builder: (context, theme, accounts, locale, _) {
          return MaterialApp(
            navigatorKey: appNavigatorKey,
            title: 'Handy',
            debugShowCheckedModeBanner: false,
            locale: locale.locale,
            localeResolutionCallback: (locale, _) => locale == null
                ? AppLocalizations.fallbackLocale
                : AppLocalizations.resolve(locale),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            navigatorObservers: _telemetryNavigatorObservers(),
            scrollBehavior: const AppScrollBehavior(),
            theme: _themeData(Brightness.light, theme),
            darkTheme: _themeData(Brightness.dark, theme),
            themeMode: theme.themeMode,
            builder: (context, child) {
              final boldText = MediaQuery.boldTextOf(context);
              final currentTheme = Theme.of(context);
              AppTheme.applyBrand(theme.brandColor);
              final themedChild = Theme(
                data: currentTheme.copyWith(
                  textTheme: theme.applyAppTextTheme(
                    currentTheme.textTheme,
                    boldText: boldText,
                  ),
                  primaryTextTheme: theme.applyAppTextTheme(
                    currentTheme.primaryTextTheme,
                    boldText: boldText,
                  ),
                ),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(decoration: TextDecoration.none),
                  child: child ?? const SizedBox.shrink(),
                ),
              );
              final unlockedApp = Stack(
                children: [
                  Positioned.fill(
                    child: GlobalVideoSplitHost(
                      child: HorizontalSafeViewport(
                        sideNavigation: true,
                        child: themedChild,
                      ),
                    ),
                  ),
                  Overlay(
                    initialEntries: [
                      OverlayEntry(
                        builder: (_) => const HorizontalSafeViewport(
                          child: Stack(children: [GlobalMusicPlayerOverlay()]),
                        ),
                      ),
                    ],
                  ),
                  Positioned.fill(
                    child: HorizontalSafeViewport(
                      child: InAppNotificationBannerHost(
                        controller: NotificationController.shared,
                      ),
                    ),
                  ),
                  const Positioned.fill(
                    child: HorizontalSafeViewport(
                      child: GlobalCallOverlayHost(),
                    ),
                  ),
                ],
              );
              final appLock = context.watch<LocalAppLockController>();
              final appChild = Stack(
                children: [
                  Positioned.fill(
                    child: ExcludeSemantics(
                      excluding: appLock.locked,
                      child: unlockedApp,
                    ),
                  ),
                  const Positioned.fill(child: LocalAppLockGate()),
                ],
              );
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: systemUiOverlayStyleForSurface(context.colors.navBar),
                child: _ScaledAppView(
                  textScale: theme.effectiveTextScale(
                    MediaQuery.textScalerOf(context),
                  ),
                  interfaceScale: theme.renderedInterfaceScale,
                  child: DefaultTextStyle(
                    style: theme.applyAppTextStyle(
                      AppTextStyle.body(context.colors.textPrimary),
                      boldText: boldText,
                    ),
                    child: ColoredBox(
                      color: context.colors.background,
                      child: appChild,
                    ),
                  ),
                ),
              );
            },
            home: KeyedSubtree(
              key: ValueKey((accounts.activeSlot, accounts.activeUserId)),
              child: const ContentView(),
            ),
          );
        },
      ),
    );
  }
}

class _ThemeDataMemo {
  const _ThemeDataMemo({
    required this.colors,
    required this.families,
    required this.seedColor,
    required this.data,
  });

  final AppColors colors;
  final List<String> families;
  final Color seedColor;
  final ThemeData data;
}

NavigatorObserver? _buildSentryNavigatorObserver() =>
    sentryEnabled ? SentryNavigatorObserver() : null;

final NavigatorObserver? _sentryNavigatorObserver =
    _buildSentryNavigatorObserver();

List<NavigatorObserver> _telemetryNavigatorObservers() {
  final observers = <NavigatorObserver>[?_sentryNavigatorObserver];
  try {
    if (Firebase.apps.isNotEmpty) {
      observers.add(
        FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance),
      );
    }
  } catch (_) {}
  return observers;
}

class _ScaledAppView extends StatelessWidget {
  const _ScaledAppView({
    required this.textScale,
    required this.interfaceScale,
    required this.child,
  });

  final double textScale;
  final double interfaceScale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scale = interfaceScale;
    final virtualSize = Size(
      media.size.width / scale,
      media.size.height / scale,
    );
    final scaledMedia = media.copyWith(
      size: virtualSize,
      padding: _unscaleInsets(media.padding, scale),
      viewPadding: _unscaleInsets(media.viewPadding, scale),
      viewInsets: _unscaleInsets(media.viewInsets, scale),
      systemGestureInsets: _unscaleInsets(media.systemGestureInsets, scale),
      textScaler: TextScaler.linear(textScale),
    );

    return AppKeyboardDismissOnTap(
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: virtualSize.width,
          maxWidth: virtualSize.width,
          minHeight: virtualSize.height,
          maxHeight: virtualSize.height,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: virtualSize.width,
              height: virtualSize.height,
              child: MediaQuery(data: scaledMedia, child: child),
            ),
          ),
        ),
      ),
    );
  }

  EdgeInsets _unscaleInsets(EdgeInsets insets, double scale) {
    return EdgeInsets.fromLTRB(
      insets.left / scale,
      insets.top / scale,
      insets.right / scale,
      insets.bottom / scale,
    );
  }
}
