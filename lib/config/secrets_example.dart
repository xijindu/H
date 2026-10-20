//
//  secrets_example.dart
//
//  Template for your TDLib credentials. Copy this to `secrets.dart` and fill in
//  your real values:
//
//      cp lib/config/secrets_example.dart lib/config/secrets.dart
//
//  `secrets.dart` is git-ignored so your credentials never get committed.
//  Create an api_id / api_hash once at https://my.telegram.org → API tools.
//

class Secrets {
  /// Your Telegram api_id (integer).
  static const int apiId = 0;

  /// Your Telegram api_hash (string).
  static const String apiHash = '';

  static bool get isConfigured => apiId != 0 && apiHash.isNotEmpty;
}
