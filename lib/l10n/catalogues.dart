import 'strings_en.dart' as strings_en;
import 'strings_zh.dart' as strings_zh;

import 'locale_catalogue.dart';

final Map<String, LocaleCatalogue> catalogues = {
  'en': strings_en.createCatalogue(),
  'zh': strings_zh.createCatalogue(),
};

final LocaleCatalogue fallbackCatalogue = strings_en.createCatalogue();
