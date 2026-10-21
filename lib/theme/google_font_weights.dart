import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

const List<FontWeight> kGoogleFontWeights = [
  FontWeight.w400,
  FontWeight.w500,
  FontWeight.w600,
];

@visibleForTesting
String googleFontVariantSegment(FontWeight weight) =>
    weight == FontWeight.w400 ? 'regular' : '${weight.value}';

@visibleForTesting
FontWeight? googleFontWeightOfCacheFile({
  required String googleFamily,
  required String fileName,
}) {
  final prefix = '${googleFamily.replaceAll(' ', '')}_';
  if (!fileName.startsWith(prefix) || !fileName.endsWith('.ttf')) return null;
  final rest = fileName.substring(prefix.length, fileName.length - 4);
  final separator = rest.lastIndexOf('_');
  if (separator <= 0) return null;
  final variant = rest.substring(0, separator);
  for (final weight in kGoogleFontWeights) {
    if (googleFontVariantSegment(weight) == variant) return weight;
  }
  return null;
}

class GoogleFontWeightLoader extends ChangeNotifier {
  GoogleFontWeightLoader._();

  @visibleForTesting
  GoogleFontWeightLoader.forTesting();

  static final shared = GoogleFontWeightLoader._();

  final Set<String> _loaded = {};
  final Map<String, Future<void>> _inFlight = {};

  String? loadedFamily(String googleFamily) =>
      _loaded.contains(googleFamily) ? googleFamily : null;

  Future<void> ensure(String googleFamily) {
    if (_loaded.contains(googleFamily)) return Future.value();
    return _inFlight[googleFamily] ??= _load(
      googleFamily,
    ).catchError((_) {}).whenComplete(() => _inFlight.remove(googleFamily));
  }

  Future<void> _load(String googleFamily) async {
    for (final weight in kGoogleFontWeights) {
      GoogleFonts.getFont(googleFamily, fontWeight: weight);
    }
    await GoogleFonts.pendingFonts();

    final faces = await _cachedFaces(googleFamily);
    if (faces.isEmpty) return;
    final loader = FontLoader(googleFamily);
    for (final face in faces) {
      loader.addFont(face.readAsBytes().then(ByteData.sublistView));
    }
    await loader.load();
    _loaded.add(googleFamily);
    notifyListeners();
  }

  Future<List<File>> _cachedFaces(String googleFamily) async {
    final Directory support;
    try {
      support = await getApplicationSupportDirectory();
    } catch (_) {
      return const [];
    }
    if (!support.existsSync()) return const [];
    final byWeight = <FontWeight, File>{};
    await for (final entity in support.list()) {
      if (entity is! File) continue;
      final weight = googleFontWeightOfCacheFile(
        googleFamily: googleFamily,
        fileName: entity.uri.pathSegments.last,
      );
      if (weight == null) continue;
      final existing = byWeight[weight];
      if (existing != null &&
          existing.statSync().modified.isAfter(entity.statSync().modified)) {
        continue;
      }
      byWeight[weight] = entity;
    }
    return byWeight.values.toList(growable: false);
  }
}
