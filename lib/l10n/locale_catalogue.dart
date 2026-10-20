import 'dart:async';

import 'package:flutter/foundation.dart';

import 'catalogues.dart';

/// One locale's strings, compiled into the app as const Dart maps.
///
/// Edit the strings_*.dart files in this directory to change translations.
/// The catalogue ships as code, so a translation change triggers a rebuild
/// rather than a runtime asset load.
@immutable
class LocaleCatalogue {
  const LocaleCatalogue({
    required this.tag,
    required this.appKey,
    required this.pluralCategories,
    required this.strings,
    required this.plurals,
    required this.countries,
  });

  final String tag;
  final String appKey;
  final List<String> pluralCategories;
  final Map<String, String> strings;
  final Map<String, Map<String, String>> plurals;
  final Map<String, String> countries;

  /// The template for [key], or null when this locale does not define it.
  ///
  /// [count] selects the CLDR category for a counted key and is ignored for a
  /// plain one.
  String? template(String key, {num? count}) {
    final plain = strings[key];
    if (plain != null) return plain;
    final forms = plurals[key];
    if (forms == null) return null;
    final category = count == null ? 'other' : pluralCategoryFor(appKey, count);
    return forms[category] ?? forms['other'] ?? forms.values.firstOrNull;
  }

  bool get isCounted => plurals.isNotEmpty;

  /// CLDR plural category for [count] in [appKey].
  ///
  /// Only the categories that CLDR reaches for integers are implemented.
  static String pluralCategoryFor(String appKey, num count) {
    final n = count.abs();
    switch (appKey) {
      case 'zh':
        return 'other';
      default:
        return n == 1 ? 'one' : 'other';
    }
  }
}

/// Provides locale catalogues. All are compiled in — no runtime asset load.
abstract final class LocaleCatalogues {
  static const fallbackAppKey = 'en';

  /// The single shared backing map. const Map.copyOf lets tests install
  /// overrides without mutating the compile-time constant.
  static Map<String, LocaleCatalogue> _loaded = Map<String, LocaleCatalogue>.of(catalogues);

  static LocaleCatalogue? forAppKey(String appKey) => _loaded[appKey];

  static LocaleCatalogue? get fallback => _loaded[fallbackAppKey];

  /// True once at least one catalogue is available. Since every catalogue is
  /// a compile-time const, this is always true after first frame — but tests
  /// and early boot paths still call `ensureLoaded` for API parity.
  static bool get isReady => _loaded.isNotEmpty;

  static bool isLoaded(String appKey) => _loaded.containsKey(appKey);

  /// Ensures [appKey] is in memory. A no-op in production (all catalogues
  /// ship as const), but preserves call sites that may guard against slow
  /// loading elsewhere.
  static Future<void> ensureLoaded(String appKey) async {
    // Compile-time constants are always available — nothing to do.
  }

  /// Await both [appKey] and the English fallback.
  static Future<void> ensureLoadedWithFallback(String appKey) async {
    // Already loaded at compile time.
  }

  @visibleForTesting
  static void reset() {
    _loaded = Map<String, LocaleCatalogue>.of(catalogues);
  }

  /// Installs catalogues directly, for tests that inject mocked data.
  @visibleForTesting
  static void install(Iterable<LocaleCatalogue> catalogues) {
    for (final catalogue in catalogues) {
      _loaded[catalogue.appKey] = catalogue;
    }
  }
}
