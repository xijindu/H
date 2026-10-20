//
//  login_view.dart
//
//  Reference-styled multi-step login that adapts to AuthManager.step:
//  phone → code → password. Port of the Swift `LoginView`.
//

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dlibphonenumber/dlibphonenumber.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:handy/l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/ipad_window_chrome.dart';
import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../tdlib/td_client.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'account_store.dart';
import 'auth_manager.dart';
import 'country_picker.dart';

/// Whether the login flow owns the back action instead of allowing the root
/// app route to hand it to the platform as an app/window exit.
bool loginHasBackAction({
  required bool forcePhone,
  required AuthStep step,
  required int configuredAccountCount,
}) {
  final beyondPhone =
      step is AuthWaitCode ||
      step is AuthWaitPremiumPurchase ||
      step is AuthWaitEmailAddress ||
      step is AuthWaitEmailCode ||
      step is AuthWaitQrCode ||
      step is AuthWaitPassword;
  return (beyondPhone && !forcePhone) ||
      configuredAccountCount > 1;
}

class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  static const _resendCooldown = Duration(seconds: 60);

  final _phone = TextEditingController(text: '+');
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = ObscuringController();

  Timer? _resendTimer;
  DateTime? _resendAvailableAt;
  int _resendRemainingSeconds = 0;

  // When true, show the phone-number step even though TDLib is still at a later
  // auth state — lets the user back out of QR / code / 2FA to fix the number.
  bool _forcePhone = false;

  /// Explicit choice from the country picker. Takes precedence over
  /// [_detectedCountry] when both are available.
  Country? _selectedCountry;

  /// Auto-detected from the leading digits of the phone input as the user types.
  Country? get _detectedCountry => Country.match(_phoneDigits);

  /// Effective country for display: explicit picker choice wins, otherwise
  /// fall back to whatever the input digits match.
  Country? get _effectiveCountry => _selectedCountry ?? _detectedCountry;

  String get _phoneDigits => _phone.text.replaceAll(RegExp(r'[^0-9]'), '');

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    for (final c in [
      _phone,
      _email,
      _code,
      _password,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Formats the full international number via libphonenumber's as-you-type
  /// formatter (country-specific grouping). Re-runs from scratch on each change
  /// so paste/delete reformat correctly.
  static String _formatAsYouType(String input) {
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '+';
    try {
      final formatter = PhoneNumberUtil.instance.getAsYouTypeFormatter('US');
      var out = formatter.inputDigit('+');
      for (final ch in digits.split('')) {
        out = formatter.inputDigit(ch);
      }
      return out.trim();
    } catch (_) {
      return '+$digits';
    }
  }

  void _selectCountry(Country country) {
    final digits = _phoneDigits;
    final current = _detectedCountry;
    final national = current != null
        ? digits.substring(current.dial.length)
        : '';
    setState(() {
      _selectedCountry = country;
      _phone.text = _formatAsYouType('+${country.dial}$national');
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthManager>();
    final accounts = context.watch<AccountStore>();
    final c = context.colors;
    // True when the phone-entry step is on screen (the natural state, or because
    // the user chose to re-enter the number).
    final showingPhone =
        _forcePhone || auth.step is AuthWaitPhoneNumber;
    _syncResendCountdown(auth);
    // A back affordance is useful once past the phone step, or whenever another
    // account exists to switch to.
    final canGoBack = loginHasBackAction(
      forcePhone: _forcePhone,
      step: auth.step,
      configuredAccountCount: TdClient.shared.configuredSlots.length,
    );
    final backToPhoneOnly =
        !_forcePhone && auth.step is AuthWaitQrCode;
    return PopScope(
      // LoginView is the root content, so allowing the platform back action
      // through while the visible back affordance exists exits the app instead
      // of moving within the authentication flow.
      canPop: !canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && canGoBack) {
          _handleBack(
            auth,
            accounts,
            backToPhoneOnly: backToPhoneOnly,
            showingPhone: showingPhone,
          );
        }
      },
      child: Scaffold(
        backgroundColor: c.background,
        body: Stack(
          children: [
            Column(
              children: [
                _header(),
                Expanded(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _stepFor(auth, accounts),
                          if (auth.errorMessage != null) ...[
                            const SizedBox(height: 18),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                auth.errorMessage!,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.unreadBadge,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ),
              ],
            ),
            if (canGoBack)
              Positioned(
                top:
                    MediaQuery.of(context).padding.top +
                    iPadWindowChromeInsetOf(context) +
                    6,
                left: 6,
                child: AppInteractiveSurface(
                  semanticLabel: AppStringKeys.navigationBack.l10n(context),
                  // QR back returns to the phone-number form. Aborting an
                  // add-account at the phone step has nothing to re-enter, so
                  // go straight back to the previous account.
                  onTap: () => _handleBack(
                    auth,
                    accounts,
                    backToPhoneOnly: backToPhoneOnly,
                    showingPhone: showingPhone,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: AppIcon(
                      HeroAppIcons.chevronLeft,
                      size: 26,
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ),
            Positioned(
              top:
                  MediaQuery.of(context).padding.top +
                  iPadWindowChromeInsetOf(context) +
                  6,
              right: 6,
              child: _topRightActions(auth, showingPhone),
            ),
          ],
        ),
      ),
    );
  }

  void _handleBack(
    AuthManager auth,
    AccountStore accounts, {
    required bool backToPhoneOnly,
    required bool showingPhone,
  }) {
    if (backToPhoneOnly) {
      _showPhoneEntry();
      return;
    }
    if (accounts.hasPendingAdd && showingPhone) {
      accounts.cancelAddAccount(auth);
      return;
    }
    _showBackOptions(auth);
  }

  /// Back affordance for QR / code / 2FA steps: re-enter the
  /// phone number, abort an add-account back to the previous account, or switch
  /// to another configured account.
  void _showBackOptions(AuthManager auth) {
    final accounts = context.read<AccountStore>();
    final showReenter =
        !_forcePhone &&
        (auth.step is AuthWaitQrCode ||
            auth.step is AuthWaitCode ||
            auth.step is AuthWaitPremiumPurchase ||
            auth.step is AuthWaitEmailAddress ||
            auth.step is AuthWaitEmailCode ||
            auth.step is AuthWaitPassword);
    final pendingAdd = accounts.hasPendingAdd;
    final returnName = accounts.returnAccountName;
    final others = TdClient.shared.configuredSlots
        .where((s) => s != TdClient.shared.activeSlot)
        .toList();
    showAppCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        actions: [
          if (showReenter)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheet).pop();
                _showPhoneEntry();
              },
              child: Text(AppStrings.t(AppStringKeys.loginReenterPhoneNumber)),
            ),
          // Aborting an add-account drops the half-created slot and returns to
          // the account we came from.
          if (pendingAdd)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheet).pop();
                accounts.cancelAddAccount(auth);
                if (mounted) setState(() => _forcePhone = false);
              },
              child: Text(
                returnName != null
                    ? AppStrings.t(AppStringKeys.loginBackToAccount, {
                        'value1': returnName,
                      })
                    : AppStrings.t(AppStringKeys.loginBackToPreviousAccount),
              ),
            )
          else if (others.isNotEmpty)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheet).pop();
                accounts.switchTo(others.first, auth);
                if (mounted) setState(() => _forcePhone = false);
              },
              child: Text(AppStrings.t(AppStringKeys.loginSwitchAccount)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(AppStrings.t(AppStringKeys.countryPickerCancel)),
        ),
      ),
    );
  }

  void _showPhoneEntry() {
    final auth = context.read<AuthManager>();
    auth.cancelPendingAction();
    _code.clear();
    _password.clear();
    _stopResendCountdown();
    setState(() => _forcePhone = true);
    unawaited(auth.switchToPhoneLogin());
  }

  Widget _stepFor(AuthManager auth, AccountStore accounts) {
    if (_forcePhone) return _phoneStep(auth);
    return switch (auth.step) {
      AuthMissingCredentials() => _credentialsNotice(auth),
      AuthWaitQrCode(:final link) => _qrCodeStep(auth, link),
      AuthWaitCode(:final info) => _codeStep(auth, info),
      AuthWaitPremiumPurchase() => _premiumPurchaseStep(auth),
      AuthWaitEmailAddress() => _emailAddressStep(auth),
      AuthWaitEmailCode() => _emailCodeStep(auth),
      AuthWaitPassword(:final hint) => _passwordStep(auth, hint),
      _ => _phoneStep(auth),
    };
  }

  Widget _header() {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 96, bottom: 28),
      child: Column(
        children: [
          Image.asset(
            'assets/app_icon.png',
            width: 88,
            height: 88,
          ),
          const SizedBox(height: 14),
          Text(
            'Handy',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            AppStrings.t(AppStringKeys.loginTelegramAccountTitle),
            style: TextStyle(fontSize: 15, color: c.textSecondary),
          ),
        ],
      ),
    );
  }

  // MARK: Steps

  Widget _phoneStep(AuthManager auth) {
    final c = context.colors;
    final country = _effectiveCountry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppInteractiveSurface(
          semanticLabel:
              country != null
                  ? country.name.l10n(context)
                  : AppStringKeys.countryPickerSelectCountryOrRegion.l10n(
                    context,
                  ),
          onTap: _showCountrySheet,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    country != null
                        ? country.name.l10n(context)
                        : AppStrings.t(
                          AppStringKeys.countryPickerSelectCountryOrRegion,
                        ),
                    style: TextStyle(
                      fontSize: 16,
                      color: country != null
                          ? c.textPrimary
                          : c.textTertiary,
                    ),
                  ),
                ),
                AppIcon(
                  HeroAppIcons.chevronRight,
                  size: 18,
                  color: c.textTertiary,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  style: TextStyle(fontSize: 22, color: c.textPrimary),
                  decoration: InputDecoration(
                    hintText: country == null
                        ? AppStrings.t(
                          AppStringKeys.loginPhoneNumberWithCountryCode,
                        )
                        : null,
                    border: InputBorder.none,
                  ),
                  onChanged: (v) {
                    final formatted = _formatAsYouType(v);
                    if (formatted != v) {
                      _phone.value = TextEditingValue(
                        text: formatted,
                        selection: TextSelection.collapsed(
                          offset: formatted.length,
                        ),
                      );
                    }
                    setState(() {});
                  },
                  onSubmitted: (_) {
                    if (_phoneDigits.length >= 7 && !auth.isWorking) {
                      unawaited(_submitPhone(auth));
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _primaryButton(
          auth,
          AppStrings.t(AppStringKeys.loginGetVerificationCode),
          _phoneDigits.length >= 7,
          () => unawaited(_submitPhone(auth)),
        ),
      ],
    );
  }

  Future<void> _submitPhone(AuthManager auth) async {
    final submitted = await auth.submitPhone('+$_phoneDigits');
    if (submitted && mounted && _forcePhone) {
      setState(() => _forcePhone = false);
    }
  }



  Widget _emailAddressStep(AuthManager auth) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppStrings.t(AppStringKeys.loginConfirmYourEmailAddress),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          AppStrings.t(
            AppStringKeys.loginTelegramRequiresAnEmailAddressToFinishSigning,
          ),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: c.textSecondary),
        ),
        const SizedBox(height: 22),
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              AppIcon(HeroAppIcons.at, size: 22, color: c.textTertiary),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  style: TextStyle(fontSize: 17, color: c.textPrimary),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: AppStrings.t(AppStringKeys.loginEmailAddress),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (_email.text.trim().contains('@') && !auth.isWorking) {
                      auth.submitEmailAddress(_email.text);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _primaryButton(
          auth,
          'Send email code',
          _email.text.trim().contains('@'),
          () => auth.submitEmailAddress(_email.text),
        ),
      ],
    );
  }

  Widget _emailCodeStep(AuthManager auth) {
    final c = context.colors;
    final step = auth.step as AuthWaitEmailCode;
    final requiredLength = step.length > 0 ? step.length : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppStrings.t(AppStringKeys.loginEnterTheEmailCode),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          step.emailPattern.isEmpty
              ? 'Telegram sent a code to your email address.'
              : 'Telegram sent a code to ${step.emailPattern}.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: c.textSecondary),
        ),
        const SizedBox(height: 22),
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              AppIcon(
                HeroAppIcons.checkDouble,
                size: 22,
                color: c.textTertiary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.text,
                  autocorrect: false,
                  style: TextStyle(fontSize: 20, color: c.textPrimary),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: AppStrings.t(
                      AppStringKeys.loginEmailVerificationCode,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (_code.text.trim().isNotEmpty) {
                      auth.submitEmailCode(_code.text);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _primaryButton(
          auth,
          'Verify email',
          requiredLength == 0
              ? _code.text.trim().isNotEmpty
              : _code.text.trim().length == requiredLength,
          () => auth.submitEmailCode(_code.text),
        ),
        const SizedBox(height: 14),
        AppInteractiveSurface(
          onTap: auth.isWorking ? null : auth.resendCode,
          enabled: !auth.isWorking,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              AppStrings.t(AppStringKeys.loginResendEmailCode),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.brand,
              ),
            ),
          ),
        ),
        if (step.canReset)
          AppInteractiveSurface(
            onTap: auth.isWorking ? null : auth.resetAuthenticationEmailAddress,
            enabled: !auth.isWorking,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                step.resetPending && step.resetWaitSeconds > 0
                    ? 'Email reset available in ${step.resetWaitSeconds} seconds'
                    : 'Reset email address',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: c.textSecondary),
              ),
            ),
          ),
      ],
    );
  }

  Widget _premiumPurchaseStep(AuthManager auth) {
    final c = context.colors;
    final step = auth.step as AuthWaitPremiumPurchase;
    final days = step.premiumDayCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppIcon(HeroAppIcons.solidStar, size: 54, color: AppTheme.brand),
        const SizedBox(height: 16),
        Text(
          AppStrings.t(AppStringKeys.loginTelegramPremiumIsRequired),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          days > 0
              ? 'Purchase $days days of Telegram Premium to finish signing in.'
              : 'Complete the required Telegram Premium purchase to finish signing in.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.35, color: c.textSecondary),
        ),
        const SizedBox(height: 22),
        _primaryButton(
          auth,
          Platform.isIOS ? 'Continue with App Store' : 'Purchase unavailable',
          Platform.isIOS,
          () => unawaited(auth.purchaseRequiredPremium()),
        ),
        if (Platform.isIOS) ...[
          const SizedBox(height: 10),
          AppInteractiveSurface(
            onTap: auth.isWorking
                ? null
                : () => unawaited(auth.purchaseRequiredPremium(restore: true)),
            enabled: !auth.isWorking,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                AppStrings.t(AppStringKeys.loginRestoreAppStorePurchase),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.brand,
                ),
              ),
            ),
          ),
        ],
        if (step.supportEmail.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            AppStrings.t(AppStringKeys.loginPurchaseSupportValue1, {
              'value1': step.supportEmail,
            }),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: c.textTertiary),
          ),
        ],
      ],
    );
  }

  Widget _topRightActions(AuthManager auth, bool showingPhone) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showingPhone)
          _loginIconButton(
            icon: HeroAppIcons.qrcode,
            tooltip: AppStrings.t(AppStringKeys.loginWithQrCode),
            enabled: !auth.isWorking,
            onTap: () => _requestQrLogin(auth),
          ),
      ],
    );
  }

  Widget _loginIconButton({
    required AppIconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
    int badgeCount = 0,
  }) {
    final c = context.colors;
    final badgeText = badgeCount > 99 ? '99+' : '$badgeCount';
    return Tooltip(
      message: tooltip,
      child: AppInteractiveSurface(
        semanticLabel: tooltip,
        onTap: enabled ? onTap : null,
        enabled: enabled,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AppIcon(
                icon,
                size: 25,
                color: enabled ? c.textPrimary : c.textTertiary,
              ),
              if (badgeCount > 0)
                Positioned(
                  right: -8,
                  top: -7,
                  child: Container(
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.unreadBadge,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      border: Border.all(color: c.background, width: 1.2),
                    ),
                    child: Text(
                      badgeText,
                      style: const TextStyle(
                        color: Color(0xFFFFFFFF),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        height: 1,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _requestQrLogin(AuthManager auth) {
    if (_forcePhone) setState(() => _forcePhone = false);
    auth.requestQrLogin();
  }

  void _showCountrySheet() {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CountryPickerView(onSelect: _selectCountry),
      ),
    );
  }

  Widget _qrCodeStep(AuthManager auth, String link) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppStrings.t(AppStringKeys.loginQrCodeTitle),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.t(AppStringKeys.loginQrCodeSubtitle),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 22),
        Center(
          child: Container(
            width: 244,
            height: 244,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: link.isEmpty
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    ),
                  )
                : QrImageView(data: link, backgroundColor: Colors.white),
          ),
        ),
        const SizedBox(height: 18),
        OutlinedButton(
          onPressed: auth.isWorking ? null : auth.requestQrLogin,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            side: BorderSide(color: AppTheme.brand.withValues(alpha: 0.45)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
          ),
          child: Text(
            AppStrings.t(AppStringKeys.loginRefreshQrCode),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: auth.isWorking ? c.textTertiary : AppTheme.brand,
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _showPhoneEntry,
          child: Text(
            AppStrings.t(AppStringKeys.loginReenterPhoneNumber),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppTheme.brand,
            ),
          ),
        ),
      ],
    );
  }

  Widget _codeStep(AuthManager auth, AuthCodeInfo info) {
    final c = context.colors;
    final prompt = _codePrompt(info);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            prompt,
            style: TextStyle(fontSize: 13, color: c.textSecondary),
          ),
        ),
        const SizedBox(height: 16),
        _VerificationCodeInput(
          controller: _code,
          length: info.effectiveLength,
          numericOnly: info.isNumeric,
          enabled: !auth.isWorking,
          onChanged: (value) => _handleCodeChanged(auth, info, value),
        ),
        const SizedBox(height: 16),
        _primaryButton(
          auth,
          AppStrings.t(AppStringKeys.loginSubmit),
          _code.text.isNotEmpty,
          () => auth.submitCode(_code.text),
        ),
        const SizedBox(height: 14),
        _resendCodeAction(auth),
      ],
    );
  }

  void _handleCodeChanged(AuthManager auth, AuthCodeInfo info, String value) {
    setState(() {});
    final normalized = value.trim();
    if (auth.isWorking || normalized.length != info.effectiveLength) return;
    auth.submitCode(normalized);
  }

  String _codePrompt(AuthCodeInfo info) {
    return switch (info.method) {
      AuthCodeDeliveryMethod.telegramMessage => AppStrings.t(
        AppStringKeys.loginCodeSentToTelegramDevices,
      ),
      AuthCodeDeliveryMethod.sms => AppStrings.t(
        AppStringKeys.loginCodeSentBySms,
        {'value1': info.phoneNumber ?? ''},
      ),
      AuthCodeDeliveryMethod.call => AppStrings.t(
        AppStringKeys.loginCodeSentByPhoneCall,
        {'value1': info.phoneNumber ?? ''},
      ),
      AuthCodeDeliveryMethod.flashCall => AppStrings.t(
        AppStringKeys.loginCodeSentByFlashCall,
        {'value1': info.pattern ?? ''},
      ),
      AuthCodeDeliveryMethod.missedCall => AppStrings.t(
        AppStringKeys.loginCodeSentByMissedCall,
        {
          'value1': info.phoneNumberPrefix ?? '',
          'value2': '${info.effectiveLength}',
        },
      ),
      AuthCodeDeliveryMethod.fragment => AppStrings.t(
        AppStringKeys.loginCodeSentByFragment,
      ),
      AuthCodeDeliveryMethod.firebase => AppStrings.t(
        AppStringKeys.loginCodeSentByFirebase,
      ),
      AuthCodeDeliveryMethod.email => AppStrings.t(
        AppStringKeys.loginCodeSentByEmail,
      ),
      AuthCodeDeliveryMethod.unknown => AppStrings.t(
        AppStringKeys.loginCodeSentFallback,
      ),
    };
  }

  void _syncResendCountdown(AuthManager auth) {
    if (_forcePhone || auth.step is! AuthWaitCode) {
      _stopResendCountdown();
      return;
    }
    if (_resendAvailableAt == null) _startResendCountdown();
  }

  void _startResendCountdown({bool notify = false}) {
    _resendTimer?.cancel();
    _resendAvailableAt = DateTime.now().add(_resendCooldown);
    _updateResendRemaining(notify: notify);
    _resendTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateResendRemaining(notify: true),
    );
  }

  void _stopResendCountdown() {
    _resendTimer?.cancel();
    _resendTimer = null;
    _resendAvailableAt = null;
    _resendRemainingSeconds = 0;
  }

  void _updateResendRemaining({required bool notify}) {
    final availableAt = _resendAvailableAt;
    if (availableAt == null) return;
    final remainingMs = availableAt.difference(DateTime.now()).inMilliseconds;
    final next = remainingMs <= 0 ? 0 : (remainingMs + 999) ~/ 1000;
    if (next == _resendRemainingSeconds) return;
    _resendRemainingSeconds = next;
    if (next == 0) {
      _resendTimer?.cancel();
      _resendTimer = null;
    }
    if (notify && mounted) setState(() {});
  }

  Widget _resendCodeAction(AuthManager auth) {
    final c = context.colors;
    final canResend = _resendRemainingSeconds == 0 && !auth.isWorking;
    final base = AppStrings.t(AppStringKeys.loginResendVerificationCode);
    final title = _resendRemainingSeconds > 0
        ? '$base (${_resendRemainingSeconds}s)'
        : base;
    return Center(
      child: AppInteractiveSurface(
        onTap: canResend
            ? () {
                auth.resendCode();
                _startResendCountdown(notify: true);
              }
            : null,
        enabled: canResend,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: canResend ? c.textSecondary : c.textTertiary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _passwordStep(AuthManager auth, String hint) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hint.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              AppStrings.t(AppStringKeys.loginPasswordHint, {'value1': hint}),
              style: TextStyle(fontSize: 13, color: c.textSecondary),
            ),
          ),
        const SizedBox(height: 16),
        InputField(
          systemImage: HeroAppIcons.lock.data,
          placeholder: AppStrings.t(AppStringKeys.loginTwoStepPassword),
          controller: _password,
          secure: true,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_password.text.isNotEmpty && !auth.isWorking) {
              auth.submitPassword(_password.text);
            }
          },
        ),
        const SizedBox(height: 16),
        _primaryButton(
          auth,
          AppStrings.t(AppStringKeys.loginVerify),
          _password.text.isNotEmpty,
          () => auth.submitPassword(_password.text),
        ),
      ],
    );
  }

  Widget _credentialsNotice(AuthManager auth) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          AppIcon(
            HeroAppIcons.triangleExclamation,
            size: 40,
            color: AppTheme.unreadBadge,
          ),
          const SizedBox(height: 12),
          Text(
            AppStrings.t(AppStringKeys.loginTelegramApiCredentialsMissing),
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppStrings.t(AppStringKeys.loginTelegramApiSecretsInstructions) +
                AppStrings.t(AppStringKeys.loginTelegramApiPortalInstructions),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: c.textSecondary),
          ),
        ],
      ),
    );
  }

  // MARK: Building blocks

  Widget _primaryButton(
    AuthManager auth,
    String title,
    bool enabled,
    VoidCallback action, {
    bool? working,
  }) {
    final busy = working ?? auth.isWorking;
    final on = enabled && !busy;
    return AppInteractiveSurface(
      semanticLabel: title,
      onTap: on ? action : null,
      enabled: on,
      borderRadius: BorderRadius.circular(25),
      child: Container(
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? AppTheme.brand : context.colors.textTertiary,
          borderRadius: BorderRadius.circular(25),
        ),
        child: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation(Color(0xFFFFFFFF)),
                ),
              )
            : Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFFFFFFF),
                ),
              ),
      ),
    );
  }

}

/// A TextEditingController that masks its text with dots at render time, so the
/// field can stay a plain (non-obscured) text field. TextField.obscureText forces
/// a password input type that some Chinese/ColorOS IMEs render as a numeric
/// keypad; masking here keeps a real alphanumeric keyboard. Toggle [reveal].
class ObscuringController extends TextEditingController {
  bool reveal = false;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (reveal) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return TextSpan(style: style, text: '•' * value.text.length);
  }
}

class _VerificationCodeInput extends StatefulWidget {
  const _VerificationCodeInput({
    required this.controller,
    required this.length,
    required this.numericOnly,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final int length;
  final bool numericOnly;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  State<_VerificationCodeInput> createState() => _VerificationCodeInputState();
}

class _VerificationCodeInputState extends State<_VerificationCodeInput> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    _focusNode.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant _VerificationCodeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_refresh);
    widget.controller.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _focusNode.removeListener(_refresh);
    _focusNode.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final boxCount = math.max(4, math.min(widget.length, 8));
    final code = widget.controller.text;
    return Semantics(
      label: AppStrings.t(AppStringKeys.loginVerificationCode),
      textField: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? _focusNode.requestFocus : null,
        child: SizedBox(
          height: 58,
          child: Stack(
            children: [
              Positioned.fill(
                child: TextField(
                  focusNode: _focusNode,
                  controller: widget.controller,
                  enabled: widget.enabled,
                  keyboardType: widget.numericOnly
                      ? TextInputType.number
                      : TextInputType.text,
                  inputFormatters: [
                    if (widget.numericOnly)
                      FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(widget.length),
                  ],
                  autofillHints: const [AutofillHints.oneTimeCode],
                  autocorrect: false,
                  enableSuggestions: false,
                  enableInteractiveSelection: false,
                  showCursor: false,
                  style: const TextStyle(
                    color: Colors.transparent,
                    fontSize: 1,
                    height: 1,
                  ),
                  cursorColor: Colors.transparent,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: widget.onChanged,
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const gap = 8.0;
                      final boxWidth = math.min(
                        48.0,
                        (constraints.maxWidth - gap * (boxCount - 1)) /
                            boxCount,
                      );
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < boxCount; i++) ...[
                            _VerificationCodeBox(
                              width: boxWidth,
                              value: i < code.length ? code[i] : '',
                              focused:
                                  _focusNode.hasFocus &&
                                  widget.enabled &&
                                  i == math.min(code.length, boxCount - 1),
                            ),
                            if (i != boxCount - 1) const SizedBox(width: gap),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
              if (widget.length > boxCount && code.length > boxCount)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Text(
                      '${code.length}/${widget.length}',
                      style: TextStyle(
                        color: c.textTertiary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VerificationCodeBox extends StatelessWidget {
  const _VerificationCodeBox({
    required this.width,
    required this.value,
    required this.focused,
  });

  final double width;
  final String value;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      width: width,
      height: 54,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: focused ? AppTheme.brand : c.divider,
          width: focused ? 1.8 : 1,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: AppTheme.brand.withValues(alpha: 0.16),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Text(
        value,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w600,
          height: 1,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

/// A pill-shaped reference text field with a leading glyph. Secure fields get a
/// plain text keyboard and a show/hide eye toggle — Telegram 2-step passwords
/// are NOT numeric.
class InputField extends StatefulWidget {
  const InputField({
    super.key,
    required this.systemImage,
    required this.placeholder,
    required this.controller,
    this.secure = false,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
  });

  final IconData systemImage;
  final String placeholder;
  final TextEditingController controller;
  final bool secure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<InputField> createState() => _InputFieldState();
}

class _InputFieldState extends State<InputField> {
  late bool _obscure = widget.secure;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Secure fields mask through the controller (dots at render time); reflect
    // the eye toggle into it so showing/hiding works without obscureText.
    final maskCtrl = widget.controller is ObscuringController
        ? widget.controller as ObscuringController
        : null;
    maskCtrl?.reveal = !_obscure;
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(25),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Icon(widget.systemImage, size: 20, color: AppTheme.brand),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: ValueKey<Object?>((
                widget.placeholder,
                widget.secure,
                widget.keyboardType,
              )),
              controller: widget.controller,
              // Secure fields mask via an ObscuringController (render-time dots)
              // and keep obscureText FALSE — TextField.obscureText forces a
              // password input type that some Chinese/ColorOS IMEs render as a
              // numeric PIN pad. A plain text field avoids the PIN keyboard and
              // still accepts Telegram's alphanumeric 2-step passwords.
              obscureText: maskCtrl == null && _obscure,
              keyboardType:
                  widget.keyboardType ??
                  (widget.secure ? TextInputType.text : null),
              textInputAction: widget.textInputAction,
              inputFormatters: widget.inputFormatters,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(color: c.textPrimary, fontSize: 16),
              decoration: InputDecoration(
                hintText: widget.placeholder,
                border: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
          if (widget.secure)
            AppInteractiveSurface(
              semanticLabel: AppStrings.t(
                _obscure
                    ? AppStringKeys.loginShowPassword
                    : AppStringKeys.loginHidePassword,
              ),
              toggled: !_obscure,
              onTap: () => setState(() => _obscure = !_obscure),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: AppIcon(
                  _obscure ? HeroAppIcons.eyeSlash : HeroAppIcons.eye,
                  size: 20,
                  color: c.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
