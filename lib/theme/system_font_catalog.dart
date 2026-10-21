import 'package:flutter/services.dart';

class SystemFontCatalog {
  SystemFontCatalog._();

  static const MethodChannel _channel = MethodChannel('handy/fonts');

  static Future<List<String>> loadFonts() async {
    try {
      final result = await _channel.invokeListMethod<String>('listFonts');
      final fonts =
          (result ?? const <String>[])
              .map((font) => font.trim())
              .where((font) => font.isNotEmpty)
              .toSet()
              .toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return fonts;
    } catch (_) {
      return const <String>[];
    }
  }

  static Future<List<String>> normalizeFamilies(List<String> families) async {
    try {
      final result = await _channel.invokeListMethod<String>(
        'normalizeFontFamilies',
        families,
      );
      if (result == null || result.length != families.length) return families;
      return [
        for (var i = 0; i < result.length; i++)
          result[i].trim().isEmpty ? families[i] : result[i].trim(),
      ];
    } catch (_) {
      return families;
    }
  }
}
