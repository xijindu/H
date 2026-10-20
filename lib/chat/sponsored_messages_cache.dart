import 'dart:async';

/// The unrendered TDLib response retained until sponsored-message rendering is
/// enabled. Keeping the complete payload preserves sponsor and reporting data.
class SponsoredMessagesSnapshot {
  const SponsoredMessagesSnapshot({
    required this.response,
    required this.fetchedAt,
  });

  final Map<String, dynamic> response;
  final DateTime fetchedAt;
}

/// Caches `getChatSponsoredMessages` results for Telegram's required five
/// minutes and coalesces concurrent requests for the same account and chat.
class SponsoredMessagesCache {
  SponsoredMessagesCache({
    this.ttl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _now;
  final Map<String, SponsoredMessagesSnapshot> _entries = {};
  final Map<String, Future<SponsoredMessagesSnapshot>> _inFlight = {};

  Future<SponsoredMessagesSnapshot> retrieve({
    required String cacheKey,
    required Future<Map<String, dynamic>> Function() fetch,
    bool refresh = false,
  }) {
    final now = _now();
    final cached = _entries[cacheKey];
    if (!refresh && cached != null && now.difference(cached.fetchedAt) < ttl) {
      return Future.value(cached);
    }
    if (cached != null && now.difference(cached.fetchedAt) >= ttl) {
      _entries.remove(cacheKey);
    }

    final inFlight = _inFlight[cacheKey];
    if (inFlight != null) return inFlight;

    late final Future<SponsoredMessagesSnapshot> request;
    request = fetch()
        .then((response) {
          final snapshot = SponsoredMessagesSnapshot(
            response: Map<String, dynamic>.unmodifiable(response),
            fetchedAt: _now(),
          );
          _entries[cacheKey] = snapshot;
          return snapshot;
        })
        .whenComplete(() {
          if (identical(_inFlight[cacheKey], request)) {
            _inFlight.remove(cacheKey);
          }
        });
    _inFlight[cacheKey] = request;
    return request;
  }
}
