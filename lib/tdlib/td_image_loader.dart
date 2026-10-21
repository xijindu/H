import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'json_helpers.dart';
import 'td_client.dart';
import 'td_models.dart';

class TdFileByteRange {
  const TdFileByteRange({required this.start, required this.end});

  final int start;

  final int end;
}

class TdFileProgress {
  const TdFileProgress({
    required this.fileId,
    required this.downloaded,
    required this.prefixDownloaded,
    required this.total,
    required this.isActive,
    required this.isCompleted,
    this.downloadedRanges,
  });

  final int fileId;
  final int downloaded;
  final int prefixDownloaded;
  final int total;
  final bool isActive;
  final bool isCompleted;

  final List<TdFileByteRange>? downloadedRanges;

  double? get fraction {
    if (isCompleted) return 1;
    if (total <= 0 || downloaded <= 0) return null;
    return (downloaded / total).clamp(0.0, 1.0);
  }

  double? get prefixFraction {
    if (isCompleted) return 1;
    if (total <= 0 || prefixDownloaded <= 0) return null;
    return (prefixDownloaded / total).clamp(0.0, 1.0);
  }
}

class TdFileCenter {
  TdFileCenter._();
  static final TdFileCenter shared = TdFileCenter._();

  final TdClient _client = TdClient.shared;

  final Map<String, String> _cache = {};
  final Map<String, List<Completer<String?>>> _waiters = {};
  final Map<String, List<Completer<String?>>> _playbackWaiters = {};
  final Map<String, StreamController<TdFileProgress>> _progressControllers = {};
  final Map<String, List<TdFileByteRange>> _downloadedRanges = {};
  bool _started = false;
  static const _cacheCapacity = 4096;
  static const _playbackInitialPrefix = 2 * 1024 * 1024;
  static const _pathPriority = 16;

  String _key(int slot, int fileId) => '$slot:$fileId';

  void _remember(String key, String path) {
    _cache[key] = path;
    if (_cache.length > _cacheCapacity) _cache.remove(_cache.keys.first);
  }

  Future<String?> pathFor(
    TdFileRef ref, {
    int? accountSlot,
    int priority = _pathPriority,
  }) async {
    final slot = accountSlot ?? _client.activeSlot;
    final localPath = ref.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      final source = File(localPath);
      if (await source.exists()) {
        _remember(_key(slot, ref.id), localPath);
        return localPath;
      }
    }
    return path(ref.id, accountSlot: slot, priority: priority);
  }

  String? cachedPath(TdFileRef ref, {int? accountSlot}) {
    final slot = accountSlot ?? _client.activeSlot;
    return _cache[_key(slot, ref.id)];
  }

  void _startIfNeeded() {
    if (_started) return;
    _started = true;
    _client.updatesOf('updateFile', allAccounts: true).listen((update) {
      final file = update.obj('file');
      final clientId = update.integer('@client_id');
      final accountSlot = clientId == null
          ? _client.activeSlot
          : _client.slotForClient(clientId);
      if (file != null && accountSlot != null) {
        _ingest(file, accountSlot: accountSlot);
      }
    });
  }

  void _ingest(Map<String, dynamic> file, {required int accountSlot}) {
    final id = file.integer('id');
    final local = file.obj('local');
    if (id == null || local == null) {
      return;
    }
    final k = _key(accountSlot, id);
    final path = local.str('path');

    if (path != null && path.isNotEmpty) {
      final playbackPending =
          _playbackWaiters.remove(k) ?? const <Completer<String?>>[];
      for (final c in playbackPending) {
        if (!c.isCompleted) c.complete(path);
      }
    }

    final completed = local.boolean('is_downloading_completed') == true;
    final controller = _progressControllers[k];
    if (controller != null && !controller.isClosed && controller.hasListener) {
      final expectedSize = file.integer('expected_size') ?? 0;
      final fileSize = file.integer('size') ?? 0;
      final total = expectedSize > 0 ? expectedSize : fileSize;
      final downloadedSize = local.integer('downloaded_size') ?? 0;
      final downloadedPrefix = local.integer('downloaded_prefix_size') ?? 0;
      final downloadOffset = local.integer('download_offset') ?? 0;
      final downloaded = completed
          ? total
          : math.max(downloadedSize, downloadedPrefix);
      if (completed && total > 0) {
        _downloadedRanges[k] = <TdFileByteRange>[
          TdFileByteRange(start: 0, end: total),
        ];
      } else if (downloadedPrefix > 0 && total > 0) {
        _rememberDownloadedRange(
          k,
          start: downloadOffset,
          end: downloadOffset + downloadedPrefix,
          total: total,
        );
      }
      controller.add(
        TdFileProgress(
          fileId: id,
          downloaded: downloaded,
          prefixDownloaded: completed ? total : downloadedPrefix,
          total: total,
          isActive: local.boolean('is_downloading_active') == true,
          isCompleted: completed,
          downloadedRanges: List<TdFileByteRange>.unmodifiable(
            _downloadedRanges[k] ?? const <TdFileByteRange>[],
          ),
        ),
      );
    }

    if (!completed) return;
    if (path == null || path.isEmpty) return;

    final finished = _progressControllers.remove(k);
    _downloadedRanges.remove(k);
    unawaited(finished?.close());

    _remember(k, path);
    final pending = _waiters.remove(k) ?? const <Completer<String?>>[];
    for (final c in pending) {
      if (!c.isCompleted) c.complete(path);
    }
  }

  Stream<TdFileProgress> progress(int fileId, {int? accountSlot}) {
    _startIfNeeded();

    final slot = accountSlot ?? _client.activeSlot;
    final k = _key(slot, fileId);
    final controller = _progressControllers.putIfAbsent(k, () {
      late final StreamController<TdFileProgress> created;
      created = StreamController<TdFileProgress>.broadcast(
        onCancel: () {
          if (identical(_progressControllers[k], created)) {
            _progressControllers.remove(k);
            _downloadedRanges.remove(k);
          }
          created.close();
        },
      );
      return created;
    });
    scheduleMicrotask(() async {
      try {
        final file = await _client.queryForSlot({
          '@type': 'getFile',
          'file_id': fileId,
        }, slot);
        _ingest(file, accountSlot: slot);
      } catch (_) {}
    });
    return controller.stream;
  }

  void _rememberDownloadedRange(
    String key, {
    required int start,
    required int end,
    required int total,
  }) {
    final boundedStart = start.clamp(0, total);
    final boundedEnd = end.clamp(boundedStart, total);
    if (boundedEnd <= boundedStart) return;
    final ranges = <TdFileByteRange>[
      ...?_downloadedRanges[key],
      TdFileByteRange(start: boundedStart, end: boundedEnd),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <TdFileByteRange>[];
    for (final range in ranges) {
      if (merged.isEmpty || range.start > merged.last.end) {
        merged.add(range);
        continue;
      }
      final previous = merged.removeLast();
      merged.add(
        TdFileByteRange(
          start: previous.start,
          end: math.max(previous.end, range.end),
        ),
      );
    }
    _downloadedRanges[key] = merged;
  }

  Future<String?> playbackPath(int fileId, {int? accountSlot}) async {
    _startIfNeeded();

    final slot = accountSlot ?? _client.activeSlot;
    final k = _key(slot, fileId);
    final cached = _cache[k];
    if (cached != null) return cached;

    final pending = _playbackWaiters[k];
    if (pending != null && pending.isNotEmpty) {
      final completer = Completer<String?>();
      pending.add(completer);
      return completer.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          _playbackWaiters[k]?.remove(completer);
          return null;
        },
      );
    }

    final completer = Completer<String?>();
    _playbackWaiters[k] = [completer];

    try {
      final file = await _client.queryForSlot({
        '@type': 'getFile',
        'file_id': fileId,
      }, slot);
      _ingest(file, accountSlot: slot);
      final localPath = file.obj('local')?.str('path');
      if (localPath != null && localPath.isNotEmpty) {
        _playbackWaiters.remove(k);
        return localPath;
      }
    } catch (_) {}

    try {
      unawaited(
        downloadPriorityRange(
          fileId,
          accountSlot: slot,
          offset: 0,
          length: _playbackInitialPrefix,
          priority: 30,
          timeout: const Duration(seconds: 25),
        ),
      );
    } catch (_) {}

    return completer.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        _playbackWaiters[k]?.remove(completer);
        return null;
      },
    );
  }

  Future<void> requestPlaybackPrefix(
    int fileId,
    int bytes, {
    int? accountSlot,
  }) async {
    _startIfNeeded();
    final slot = accountSlot ?? _client.activeSlot;
    try {
      await downloadPriorityRange(
        fileId,
        accountSlot: slot,
        offset: 0,
        length: bytes,
        priority: 30,
        timeout: const Duration(seconds: 25),
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> downloadPriorityRange(
    int fileId, {
    int? accountSlot,
    required int offset,
    required int length,
    int priority = 32,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    _startIfNeeded();
    final slot = accountSlot ?? _client.activeSlot;
    if (fileId <= 0 || offset < 0 || length <= 0) return null;
    try {
      final response = await _client.queryForSlot(
        {
          '@type': 'downloadFile',
          'file_id': fileId,
          'priority': priority,
          'offset': offset,
          'limit': length,
          'synchronous': true,
        },
        slot,
        timeout: timeout,
      );
      _ingest(response, accountSlot: slot);
      return response;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> downloadPriorityFile(
    int fileId, {
    int? accountSlot,
    int priority = 32,
  }) async {
    _startIfNeeded();
    final slot = accountSlot ?? _client.activeSlot;
    if (fileId <= 0) return null;
    try {
      final response = await _client.queryForSlot({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': priority,
        'offset': 0,
        'limit': 0,
        'synchronous': false,
      }, slot);
      _ingest(response, accountSlot: slot);
      return response;
    } catch (_) {
      return null;
    }
  }

  void cancelDownload(int fileId, {int? accountSlot}) {
    _startIfNeeded();
    final slot = accountSlot ?? _client.activeSlot;
    final clientId = _client.clientId(slot);
    if (clientId == null) return;
    _client.sendTo({
      '@type': 'cancelDownloadFile',
      'file_id': fileId,
      'only_if_pending': false,
    }, clientId);
  }

  void resumeDownload(int fileId, {int? accountSlot}) {
    _startIfNeeded();
    final slot = accountSlot ?? _client.activeSlot;
    final clientId = _client.clientId(slot);
    if (clientId == null) return;
    _client.sendTo({
      '@type': 'downloadFile',
      'file_id': fileId,
      'priority': 32,
      'offset': 0,
      'limit': 0,
      'synchronous': false,
    }, clientId);
  }

  void forget(int fileId, {int? accountSlot}) {
    final slot = accountSlot ?? _client.activeSlot;
    _cache.remove(_key(slot, fileId));
  }

  Future<void> _requestPathDownload(
    int fileId,
    int accountSlot, {
    int priority = _pathPriority,
  }) async {
    try {
      final response = await _client.queryForSlot({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': priority,
        'offset': 0,
        'limit': 0,
        'synchronous': false,
      }, accountSlot);
      _ingest(response, accountSlot: accountSlot);
    } catch (_) {}
  }

  void _removePathWaiter(
    String key,
    Completer<String?> completer,
    List<Completer<String?>> waiters,
  ) {
    if (!identical(_waiters[key], waiters)) return;
    waiters.remove(completer);
    if (waiters.isEmpty) _waiters.remove(key);
  }

  Future<String?> path(
    int fileId, {
    int? accountSlot,
    int priority = _pathPriority,
  }) async {
    _startIfNeeded();

    final slot = accountSlot ?? _client.activeSlot;
    final k = _key(slot, fileId);
    final cached = _cache[k];
    if (cached != null) return cached;
    final pending = _waiters[k];
    if (pending != null && pending.isNotEmpty) {
      if (priority > _pathPriority) {
        unawaited(_requestPathDownload(fileId, slot, priority: priority));
      }
      final completer = Completer<String?>();
      pending.add(completer);
      return completer.future.timeout(
        const Duration(seconds: 180),
        onTimeout: () {
          _removePathWaiter(k, completer, pending);
          return null;
        },
      );
    }

    final completer = Completer<String?>();
    final waiters = <Completer<String?>>[completer];
    _waiters[k] = waiters;

    unawaited(_requestPathDownload(fileId, slot, priority: priority));

    final existing = _cache[k];
    if (existing != null) return existing;
    return completer.future.timeout(
      const Duration(seconds: 180),
      onTimeout: () {
        _removePathWaiter(k, completer, waiters);
        return null;
      },
    );
  }

  Future<String?> uploadPath(
    int fileId, {
    int? accountSlot,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    _startIfNeeded();
    if (fileId <= 0) return null;
    final slot = accountSlot ?? _client.activeSlot;
    final k = _key(slot, fileId);
    final cached = _cache[k];
    if (cached != null && await File(cached).exists()) return cached;
    try {
      final response = await _client
          .queryForSlot({
            '@type': 'downloadFile',
            'file_id': fileId,
            'priority': 32,
            'offset': 0,
            'limit': 0,
            'synchronous': true,
          }, slot)
          .timeout(timeout);
      _ingest(response, accountSlot: slot);
      final local = response.obj('local');
      final path = local?.str('path');
      if (local?.boolean('is_downloading_completed') == true &&
          path != null &&
          path.isNotEmpty &&
          await File(path).exists()) {
        _remember(k, path);
        return path;
      }
    } catch (_) {}
    return null;
  }
}
