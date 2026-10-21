import 'dart:async';

import 'package:flutter/foundation.dart';

import 'catalogues.dart';

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

  String? template(String key, {num? count}) {
    final plain = strings[key];
    if (plain != null) return plain;
    final forms = plurals[key];
    if (forms == null) return null;
    final category = count == null ? 'other' : pluralCategoryFor(appKey, count);
    return forms[category] ?? forms['other'] ?? forms.values.firstOrNull;
  }

  bool get isCounted => plurals.isNotEmpty;

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

abstract final class LocaleCatalogues {
  static const fallbackAppKey = 'en';

  static Map<String, LocaleCatalogue> _loaded = Map<String, LocaleCatalogue>.of(catalogues);

  static LocaleCatalogue? forAppKey(String appKey) => _loaded[appKey];

  static LocaleCatalogue? get fallback => _loaded[fallbackAppKey];

  static bool get isReady => _loaded.isNotEmpty;

  static bool isLoaded(String appKey) => _loaded.containsKey(appKey);

  static Future<void> ensureLoaded(String appKey) async {
  }

  static Future<void> ensureLoadedWithFallback(String appKey) async {
  }

  @visibleForTesting
  static void reset() {
    _loaded = Map<String, LocaleCatalogue>.of(catalogues);
  }

  @visibleForTesting
  static void install(Iterable<LocaleCatalogue> catalogues) {
    for (final catalogue in catalogues) {
      _loaded[catalogue.appKey] = catalogue;
    }
  }
}
