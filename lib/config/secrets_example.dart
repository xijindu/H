class Secrets {
  static const int apiId = 0;

  static const String apiHash = '';

  static bool get isConfigured => apiId != 0 && apiHash.isNotEmpty;
}
