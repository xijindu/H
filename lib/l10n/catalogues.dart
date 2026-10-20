// Locale catalogue registry — edit strings_*.dart files to translate.
// Collects every locale's catalogue into one const Map.

import 'strings_en.dart' as strings_en;
import 'strings_zh.dart' as strings_zh;

import 'locale_catalogue.dart';

/// All locale catalogues, keyed by appKey.
final Map<String, LocaleCatalogue> catalogues = {
  'en': strings_en.createCatalogue(),
  'zh': strings_zh.createCatalogue(),
};

/// The fallback (English) catalogue, available as a direct reference.
final LocaleCatalogue fallbackCatalogue = strings_en.createCatalogue();
