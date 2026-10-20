//
//  json_helpers.dart
//
//  Typed accessors over the `Map<String, dynamic>` dictionaries TDLib produces.
//  `jsonDecode` yields num/String for numbers, so we normalize here. TDLib
//  serializes int64 fields (chat order, file sizes, …) as JSON **strings**; the
//  helpers parse those transparently — mirroring the Swift `JSON+Helpers`.
//

/// Convenience for an untyped TDLib JSON object.
typedef TdObject = Map<String, dynamic>;

extension TdJson on Map<String, dynamic> {
  /// The TDLib object type, e.g. "updateAuthorizationState".
  String? get type => this['@type'] as String?;

  String? str(String key) => this[key] as String?;

  int? integer(String key) {
    final v = this[key];
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// TDLib serializes int64 as strings; parse those transparently.
  int? int64(String key) {
    final v = this[key];
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  bool? boolean(String key) {
    final v = this[key];
    if (v is bool) return v;
    if (v is num) return v != 0;
    return null;
  }

  double? dbl(String key) {
    final v = this[key];
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  Map<String, dynamic>? obj(String key) {
    final v = this[key];
    return v is Map<String, dynamic> ? v : null;
  }

  List<Map<String, dynamic>>? objects(String key) {
    final v = this[key];
    if (v is! List) return null;
    return v.whereType<Map<String, dynamic>>().toList();
  }

  List<int>? int64Array(String key) {
    final v = this[key];
    if (v is! List) return null;
    return v
        .map<int?>((e) {
          if (e is int) return e;
          if (e is double) return e.toInt();
          if (e is String) return int.tryParse(e);
          return null;
        })
        .whereType<int>()
        .toList();
  }
}
