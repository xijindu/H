import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/app_version.dart';
import '../app/diagnostic_breadcrumbs.dart';
import '../config/secrets.dart';
import 'avatar_animation_index.dart';
import 'json_helpers.dart';
import 'td_bindings.dart';
import 'td_user_index.dart';

class TdError implements Exception {
  TdError(Map<String, dynamic> object)
    : code = object.integer('code') ?? 0,
      message = object.str('message') ?? 'Unknown TDLib error';

  final int code;
  final String message;

  @override
  String toString() => 'TDLib error $code: $message';
}

class _PendingRequest {
  _PendingRequest(this.clientId, this.completer);

  final int clientId;
  final Completer<Map<String, dynamic>> completer;
  Timer? timeoutTimer;

  void cancelTimeout() {
    timeoutTimer?.cancel();
    timeoutTimer = null;
  }
}

@visibleForTesting
bool tdResponseMatchesRequestClient({
  required int responseClientId,
  required int requestClientId,
}) => responseClientId == requestClientId;

class TdClientProxyTransport {
  const TdClientProxyTransport({
    required this.accountSlot,
    required this.query,
    required this.send,
    required this.updates,
    this.accountUserId,
  });

  final int accountSlot;
  final int? accountUserId;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) query;
  final Future<void> Function(Map<String, dynamic>) send;
  final Stream<Map<String, dynamic>> updates;
}

@visibleForTesting
List<int> closeStaleDebugTdlibClients(
  Iterable<int> clientIds,
  void Function(int clientId, String request) send,
) {
  final staleClientIds = clientIds.where((id) => id > 0).toSet().toList();
  final closeRequest = jsonEncode({'@type': 'close'});
  for (final clientId in staleClientIds) {
    send(clientId, closeRequest);
  }
  return staleClientIds;
}

@visibleForTesting
Map<String, dynamic> quickAckTdlibOptionRequest() => <String, dynamic>{
  '@type': 'setOption',
  'name': 'use_quick_ack',
  'value': <String, dynamic>{'@type': 'optionValueBoolean', 'value': true},
};

@visibleForTesting
final class TdAccountLeaseReleasePlan {
  const TdAccountLeaseReleasePlan({
    this.closeClient = false,
    this.deleteData = false,
  });

  final bool closeClient;
  final bool deleteData;
}

@visibleForTesting
final class TdAccountLeaseBook {
  final Map<int, int> _counts = {};
  final Set<int> _pendingCloses = {};
  final Set<int> _pendingDeletes = {};

  int countFor(int accountSlot) => _counts[accountSlot] ?? 0;

  void retain(int accountSlot) {
    _counts.update(accountSlot, (count) => count + 1, ifAbsent: () => 1);
  }

  bool requestClose(int accountSlot) {
    if (countFor(accountSlot) == 0) return true;
    _pendingCloses.add(accountSlot);
    return false;
  }

  bool requestDelete(int accountSlot) {
    if (countFor(accountSlot) == 0 && !_pendingCloses.contains(accountSlot)) {
      return true;
    }
    _pendingDeletes.add(accountSlot);
    return false;
  }

  TdAccountLeaseReleasePlan release(int accountSlot) {
    final count = countFor(accountSlot);
    if (count <= 0) return const TdAccountLeaseReleasePlan();
    if (count > 1) {
      _counts[accountSlot] = count - 1;
      return const TdAccountLeaseReleasePlan();
    }
    _counts.remove(accountSlot);
    return TdAccountLeaseReleasePlan(
      closeClient: _pendingCloses.remove(accountSlot),
      deleteData: _pendingDeletes.remove(accountSlot),
    );
  }
}

final class TdAccountLease {
  TdAccountLease._(this.accountSlot, this.clientId, this._query, this._release);

  final int accountSlot;
  final int clientId;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) _query;
  final Future<void> Function() _release;
  bool _released = false;

  bool get isReleased => _released;

  Future<Map<String, dynamic>> query(Map<String, dynamic> request) {
    if (_released) {
      throw StateError('TDLib account lease for slot $accountSlot is released');
    }
    return _query(request);
  }

  Future<void> release() {
    if (_released) return Future<void>.value();
    _released = true;
    return _release();
  }
}

class TdClient {
  TdClient._();
  static final TdClient shared = TdClient._();
  static const defaultQueryTimeout = Duration(seconds: 30);

  late final TdBindings _bindings = TdBindings.open();
  TdClientProxyTransport? _proxyTransport;
  StreamSubscription<Map<String, dynamic>>? _proxyUpdateSub;

  bool _isRunning = false;
  bool _isShuttingDown = false;
  bool _shutdownComplete = false;
  Future<void>? _startOperation;
  Future<bool>? _shutdownOperation;
  Timer? _debugReceiveTimer;

  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _receiveSub;
  Isolate? _receiveIsolate;
  Future<void>? _receiveIsolateExited;
  final Set<Future<void>> _receiveIsolateExitFutures = {};
  int _receiveIsolateGeneration = 0;
  bool _receiveIsolateDead = false;

  final Map<String, _PendingRequest> _pending = {};
  final Map<int, Completer<void>> _clientClosedWaiters = {};
  int _extraCounter = 0;

  final StreamController<Map<String, dynamic>> _updates =
      StreamController.broadcast(sync: true);
  final StreamController<Map<String, dynamic>> _allUpdates =
      StreamController.broadcast(sync: true);
  final StreamController<int> _activeSlotChanges = StreamController.broadcast(
    sync: true,
  );
  final Map<int, Map<String, dynamic>> _latestChatFoldersByClient = {};
  final Map<int, Map<String, dynamic>> _latestEmojiChatThemesByClient = {};
  final Map<int, Map<String, dynamic>> _latestTextCompositionStylesByClient =
      {};
  final Map<int, Map<int, Map<String, dynamic>>> _latestCommunitiesByClient =
      {};

  final Map<int, int> _clientForSlot = {};
  final Map<int, int> _slotForClient = {};
  final TdAccountLeaseBook _accountLeases = TdAccountLeaseBook();
  final Map<int, Future<bool>> _closingSlots = {};
  final Map<int, int> _unconfirmedSlotForClient = {};
  int _activeClientId = 0;
  int _activeSlot = 0;
  List<int> _slots = [0];

  late SharedPreferences _prefs;
  String _supportDir = '';
  String _appVersion = '';

  static const _slotsKey = 'drachma.accountSlots';
  static const _activeKey = 'drachma.activeSlot';
  static const _liveClientIdsKey = 'drachma.debugLiveClientIds';

  int get activeSlot => _activeSlot;
  int get activeClientId => _activeClientId;
  bool get hasActiveClient => _activeClientId != 0;
  int? get proxyAccountUserId => _proxyTransport?.accountUserId;
  List<int> get configuredSlots => List.unmodifiable(_slots);
  int? clientId(int slot) => _clientForSlot[slot];
  int? slotForClient(int clientId) => _slotForClient[clientId];

  Iterable<int> get registeredClientIds => _slotForClient.keys;
  Map<String, dynamic>? get latestChatFoldersUpdate =>
      _latestChatFoldersByClient[_activeClientId];
  Map<String, dynamic>? latestChatFoldersUpdateForClient(int clientId) =>
      _latestChatFoldersByClient[clientId];
  Map<String, dynamic>? get latestEmojiChatThemesUpdate =>
      _latestEmojiChatThemesByClient[_activeClientId];
  Map<String, dynamic>? latestEmojiChatThemesUpdateForClient(int clientId) =>
      _latestEmojiChatThemesByClient[clientId];
  Map<String, dynamic>? get latestTextCompositionStylesUpdate =>
      _latestTextCompositionStylesByClient[_activeClientId];
  Map<String, dynamic>? latestTextCompositionStylesUpdateForClient(
    int clientId,
  ) => _latestTextCompositionStylesByClient[clientId];
  Iterable<Map<String, dynamic>> get latestCommunityUpdates =>
      _latestCommunitiesByClient[_activeClientId]?.values ?? const [];
  Iterable<Map<String, dynamic>> latestCommunityUpdatesForClient(
    int clientId,
  ) => _latestCommunitiesByClient[clientId]?.values ?? const [];

  void configureProxy(TdClientProxyTransport transport) {
    if (_isRunning || _proxyTransport != null) {
      throw StateError(
        'TDLib proxy must be configured exactly once at startup',
      );
    }
    const proxyClientId = 1;
    _proxyTransport = transport;
    _activeSlot = transport.accountSlot;
    _activeClientId = proxyClientId;
    _slots = [transport.accountSlot];
    _clientForSlot
      ..clear()
      ..[transport.accountSlot] = proxyClientId;
    _slotForClient
      ..clear()
      ..[proxyClientId] = transport.accountSlot;
    _proxyUpdateSub = transport.updates.listen(_routeProxyUpdate);
  }

  Future<void> closeProxy() async {
    await _proxyUpdateSub?.cancel();
    _proxyUpdateSub = null;
  }

  void _routeProxyUpdate(Map<String, dynamic> source) {
    final object = <String, dynamic>{...source, '@client_id': _activeClientId};
    AvatarAnimationIndex.shared.observe(_activeSlot, object);
    TdUserIndex.shared.observe(_activeSlot, object);
    if (object.type == 'updateChatFolders') {
      _latestChatFoldersByClient[_activeClientId] = object;
    }
    if (object.type == 'updateEmojiChatThemes') {
      _latestEmojiChatThemesByClient[_activeClientId] = object;
    }
    if (object.type == 'updateTextCompositionStyles') {
      _latestTextCompositionStylesByClient[_activeClientId] = object;
    }
    if (object.type == 'updateCommunity') {
      final community = object.obj('community');
      final communityId = community?.int64('id');
      if (community != null && communityId != null) {
        _latestCommunitiesByClient.putIfAbsent(
          _activeClientId,
          () => {},
        )[communityId] = object;
      }
    }
    _dispatchToAllSubscribers(object);
    _dispatchToActiveSubscribers(object);
  }


  Future<void> start() {
    if (_proxyTransport != null) return Future<void>.value();
    if (_isShuttingDown || _shutdownComplete) return Future<void>.value();
    if (_isRunning) return _startOperation ?? Future<void>.value();
    _isRunning = true;

    late final Future<void> operation;
    operation = _startGuarded().whenComplete(() {
      if (identical(_startOperation, operation)) _startOperation = null;
    });
    _startOperation = operation;
    return operation;
  }

  Future<void> _startGuarded() async {
    try {
      await _start();
    } catch (_) {
      _isRunning = false;
      rethrow;
    }
  }

  Future<void> _start() async {
    _bindings.execute(
      jsonEncode({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1}),
    );

    final (prefs, supportDir, appVersion) = await (
      SharedPreferences.getInstance(),
      getApplicationSupportDirectory(),
      AppVersion.load(),
    ).wait;
    if (_isShuttingDown) {
      _isRunning = false;
      return;
    }
    _prefs = prefs;
    _appVersion = appVersion.version;
    _supportDir = supportDir.path;
    if (kDebugMode) await _closeStaleDebugClients();

    final stored =
        _prefs.getStringList(_slotsKey)?.map(int.parse).toList() ?? <int>[];
    final loaded = stored.isEmpty ? <int>[0] : stored;
    final storedActive = _prefs.getInt(_activeKey);
    final active = (storedActive != null && loaded.contains(storedActive))
        ? storedActive
        : loaded.first;

    if (_isShuttingDown) {
      _isRunning = false;
      return;
    }

    _slots = loaded;
    _activeSlot = active;
    for (final slot in loaded) {
      final cid = _bindings.createClientId();
      _clientForSlot[slot] = cid;
      _slotForClient[cid] = slot;
    }
    _activeClientId = _clientForSlot[active] ?? 0;
    if (kDebugMode) unawaited(_persistDebugLiveClientIds());

    if (kDebugMode) {
      _startDebugReceivePump();
    } else {
      _spawnReceiveIsolate();
    }

    for (final cid in _clientForSlot.values.where((id) => id > 0)) {
      _bindings.send(
        cid,
        jsonEncode({'@type': 'getOption', 'name': 'version'}),
      );
    }
  }

  void _spawnReceiveIsolate() {
    final generation = ++_receiveIsolateGeneration;
    _receiveIsolate?.kill(priority: Isolate.immediate);
    _receiveIsolate = null;
    _receivePort?.close();
    unawaited(_receiveSub?.cancel());

    final port = ReceivePort();
    final exitPort = ReceivePort();
    _receivePort = port;
    _receiveIsolateDead = false;
    final exited = Completer<void>();
    late final Future<void> exitFuture;
    exitFuture = exited.future.whenComplete(() {
      _receiveIsolateExitFutures.remove(exitFuture);
      if (identical(_receiveIsolateExited, exitFuture)) {
        _receiveIsolateExited = null;
        _receiveIsolate = null;
      }
    });
    _receiveIsolateExitFutures.add(exitFuture);
    _receiveIsolateExited = exitFuture;
    late final StreamSubscription<dynamic> exitSubscription;
    exitSubscription = exitPort.listen((_) {
      if (!exited.isCompleted) exited.complete();
      unawaited(exitSubscription.cancel());
      exitPort.close();
    });

    unawaited(
      Isolate.spawn(
            _receiveEntry,
            port.sendPort,
            debugName: 'TDLibReceive',
            onExit: exitPort.sendPort,
          )
          .then<void>((isolate) {
            if (generation != _receiveIsolateGeneration ||
                (!_isRunning && !_isShuttingDown)) {
              isolate.kill(priority: Isolate.immediate);
              return;
            }
            _receiveIsolate = isolate;
          })
          .catchError((Object error, StackTrace stackTrace) {
            if (generation == _receiveIsolateGeneration) {
              _receiveIsolateDead = true;
              _failPending('TDLib receive isolate failed to start');
              debugPrint('🔑 [Handy] receive isolate failed to start: $error');
            }
            if (!exited.isCompleted) exited.complete();
            unawaited(exitSubscription.cancel());
            exitPort.close();
          }),
    );
    _receiveSub = port.listen((message) {
      if (message is List) {
        for (final event in message) {
          if (event is Map<String, dynamic>) {
            _route(event);
          } else if (event is String) {
            _routeRaw(event);
          }
        }
      } else if (message is Map<String, dynamic>) {
        _route(message);
      } else if (message is String) {
        _routeRaw(message);
      }
    });
  }

  void restartReceiveIsolate() {
    if (!_isRunning || _isShuttingDown) return;
    if (kDebugMode) return;
    if (!_receiveIsolateDead) return;

    debugPrint('🔑 [Handy] restarting receive isolate after resume');
    _spawnReceiveIsolate();
  }

  Future<bool> shutdown() {
    if (_proxyTransport != null) {
      return closeProxy().then((_) => true);
    }
    if (_shutdownComplete) return Future<bool>.value(true);
    final existing = _shutdownOperation;
    if (existing != null) return existing;

    _isShuttingDown = true;
    late final Future<bool> operation;
    operation = _runShutdown().whenComplete(() {
      if (identical(_shutdownOperation, operation)) {
        _shutdownOperation = null;
      }
    });
    _shutdownOperation = operation;
    return operation;
  }

  Future<bool> _runShutdown() async {
    try {
      final closed = await _shutdownOwnedClients();
      if (closed) {
        _shutdownComplete = true;
      }
      return closed;
    } catch (_) {
      rethrow;
    }
  }

  Future<bool> _shutdownOwnedClients() async {
    final starting = _startOperation;
    if (starting != null) {
      try {
        await starting.timeout(const Duration(seconds: 3));
      } on TimeoutException {
      } catch (error) {
        debugPrint('🔑 [Handy] startup ended during Quit: $error');
      }
    }

    _ensureReceivePumpForShutdown();
    final slots = <int>{
      ..._clientForSlot.keys,
      ..._closingSlots.keys,
      ..._unconfirmedSlotForClient.values,
    };
    final results = await Future.wait<bool>([
      for (final slot in slots) _closeSlotForApplicationShutdown(slot),
    ]);
    if (results.any((closed) => !closed)) {
      debugPrint(
        '🔑 [Handy] Quit cancelled: a TDLib client did not close in time',
      );
      return false;
    }

    final receiverStopped = await _stopReceivePump();
    if (!receiverStopped) {
      debugPrint(
        '🔑 [Handy] Quit cancelled: the TDLib receive isolate did not exit',
      );
      return false;
    }

    _failPending('Application is shutting down');
    for (final waiter in _clientClosedWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _clientClosedWaiters.clear();
    _clientForSlot.clear();
    _slotForClient.clear();
    _unconfirmedSlotForClient.clear();
    _activeClientId = 0;
    _isRunning = false;
    return true;
  }

  void _ensureReceivePumpForShutdown() {
    if (_clientForSlot.isEmpty && _unconfirmedSlotForClient.isEmpty) return;
    if (kDebugMode) {
      if (_debugReceiveTimer == null) _startDebugReceivePump();
      return;
    }
    if (_receiveIsolateDead || _receiveIsolateExited == null) {
      _spawnReceiveIsolate();
    }
  }

  Future<bool> _closeSlotForApplicationShutdown(int slot) async {
    try {
      final closing =
          _closingSlots[slot] ??
          _startClosingSlotResult(slot);
      return await closing.timeout(const Duration(seconds: 16));
    } on TimeoutException {
      return false;
    } catch (error) {
      debugPrint('🔑 [Handy] failed to close account slot $slot: $error');
      return false;
    }
  }

  Future<bool> _stopReceivePump() async {
    _debugReceiveTimer?.cancel();
    _debugReceiveTimer = null;

    final receiveSubscription = _receiveSub;
    _receiveSub = null;
    await receiveSubscription?.cancel();
    _receivePort?.close();
    _receivePort = null;

    final exits = Set<Future<void>>.of(_receiveIsolateExitFutures);
    final isolate = _receiveIsolate;
    ++_receiveIsolateGeneration;
    isolate?.kill(priority: Isolate.immediate);
    if (exits.isEmpty) {
      _receiveIsolate = null;
      return true;
    }
    try {
      await Future.wait(exits).timeout(const Duration(seconds: 3));
      _receiveIsolate = null;
      _receiveIsolateExited = null;
      return true;
    } on TimeoutException {
      return false;
    }
  }


  void _ensureAcceptingNewClients() {
    if (_isShuttingDown || _shutdownComplete) {
      throw StateError('TDLib is shutting down');
    }
  }

  int addSlot() {
    _ensureAcceptingNewClients();
    final newSlot = _nextSlot();
    final cid = _bindings.createClientId();
    _slots.add(newSlot);
    _clientForSlot[newSlot] = cid;
    _slotForClient[cid] = newSlot;
    _persist();
    if (kDebugMode) unawaited(_persistDebugLiveClientIds());
    _bindings.send(cid, jsonEncode({'@type': 'getOption', 'name': 'version'}));
    return newSlot;
  }

  Future<void> acceptLoginQrLink(String link) async {
    await query({
      '@type': 'confirmQrCodeAuthentication',
      'link': link,
    }).timeout(const Duration(seconds: 20));
  }

  Future<void> resetActiveQrLogin() async {
    final slot = _activeSlot;
    final oldClientId = _activeClientId;
    if (oldClientId == 0) {
      throw StateError('TDLib client is not active yet');
    }

    final state = await queryTo({
      '@type': 'getAuthorizationState',
    }, oldClientId).timeout(const Duration(seconds: 5));
    if (state.type == 'authorizationStateWaitPhoneNumber') return;
    if (state.type != 'authorizationStateWaitOtherDeviceConfirmation') {
      throw StateError('Cannot cancel QR login from ${state.type}');
    }

    final closed = Completer<void>();
    _clientClosedWaiters[oldClientId] = closed;
    _activeClientId = 0;
    _bindings.send(oldClientId, jsonEncode({'@type': 'close'}));
    try {
      await closed.future.timeout(const Duration(seconds: 15));
    } finally {
      if (identical(_clientClosedWaiters[oldClientId], closed)) {
        _clientClosedWaiters.remove(oldClientId);
      }
    }

    if (_clientForSlot[slot] == oldClientId) {
      _clientForSlot.remove(slot);
    }
    _slotForClient.remove(oldClientId);
    _latestChatFoldersByClient.remove(oldClientId);
    _latestEmojiChatThemesByClient.remove(oldClientId);
    _latestCommunitiesByClient.remove(oldClientId);
    await deleteSlotData(slot);

    _ensureAcceptingNewClients();
    final newClientId = _bindings.createClientId();
    _clientForSlot[slot] = newClientId;
    _slotForClient[newClientId] = slot;
    _activeSlot = slot;
    _activeClientId = newClientId;
    _persist();
    if (kDebugMode) unawaited(_persistDebugLiveClientIds());

    final waitForPhoneNumber = _updates.stream
        .where((update) => update.type == 'updateAuthorizationState')
        .map((update) => update.obj('authorization_state'))
        .where((authorizationState) => authorizationState != null)
        .map((authorizationState) => authorizationState!)
        .firstWhere(
          (authorizationState) =>
              authorizationState.type == 'authorizationStateWaitPhoneNumber',
        )
        .timeout(const Duration(seconds: 20));
    _bindings.send(
      newClientId,
      jsonEncode({'@type': 'getOption', 'name': 'version'}),
    );
    await waitForPhoneNumber;
  }

  Future<void> _deleteDirectoryIfPresent(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 2) rethrow;
    }
  }

  void setActive(int slot) {
    final cid = _clientForSlot[slot];
    if (cid == null || !_slots.contains(slot)) return;
    final changed = slot != _activeSlot;
    _activeSlot = slot;
    _activeClientId = cid;
    _persist();
    if (changed) _activeSlotChanges.add(slot);
  }

  void removeSlot(int slot) {
    if (slot == _activeSlot || !_slots.contains(slot)) return;
    unawaited(_closeAndForgetSlot(slot));
    _persist();
    if (kDebugMode) unawaited(_persistDebugLiveClientIds());
  }

  Future<void> deleteSlotData(int slot) async {
    if (!_accountLeases.requestDelete(slot)) return;
    final closing = _closingSlots[slot];
    if (closing != null) await closing;
    await _deleteSlotDataNow(slot);
  }

  Future<void> _deleteSlotDataNow(int slot) async {
    final dbDir = Directory(_databaseDirectory(slot));
    if (!await dbDir.exists()) return;
    if (slot != 0) {
      await _deleteDirectoryIfPresent(dbDir);
      return;
    }

    await for (final entity in dbDir.list(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('account-')) continue;
      if (entity is Directory) {
        await _deleteDirectoryIfPresent(entity);
      } else {
        try {
          await entity.delete();
        } on FileSystemException catch (error) {
          if (error.osError?.errorCode != 2) rethrow;
        }
      }
    }
  }

  int replaceActiveWithFreshLoginSlot() {
    final oldSlot = _activeSlot;
    final newSlot = addSlot();
    setActive(newSlot);
    if (_slots.contains(oldSlot)) {
      unawaited(_closeAndForgetSlot(oldSlot));
      _persist();
      if (kDebugMode) unawaited(_persistDebugLiveClientIds());
    }
    return newSlot;
  }

  Future<void> _closeAndForgetSlot(int slot) {
    _slots.remove(slot);
    if (_accountLeases.requestClose(slot)) {
      return _startClosingSlot(slot);
    }
    return Future<void>.value();
  }

  void _failPending(String reason, {int? clientId}) {
    if (_pending.isEmpty) return;
    final stranded = [
      for (final entry in _pending.entries)
        if (clientId == null || entry.value.clientId == clientId) entry.key,
    ];
    for (final extra in stranded) {
      final pending = _pending.remove(extra);
      if (pending == null || pending.completer.isCompleted) continue;
      pending.cancelTimeout();
      pending.completer.completeError(
        TdError(<String, dynamic>{'code': 500, 'message': reason}),
      );
    }
  }

  Future<void> _startClosingSlot(int slot) {
    return _startClosingSlotResult(slot).then<void>((_) {});
  }

  Future<bool> _startClosingSlotResult(int slot) {
    final existing = _closingSlots[slot];
    if (existing != null) return existing;
    late final Future<bool> closing;
    closing = _closeClientForSlot(slot).whenComplete(() {
      if (identical(_closingSlots[slot], closing)) {
        _closingSlots.remove(slot);
      }
    });
    _closingSlots[slot] = closing;
    return closing;
  }

  Future<bool> _closeClientForSlot(int slot) async {
    final cid =
        _clientForSlot.remove(slot) ??
        _unconfirmedSlotForClient.entries
            .where((entry) => entry.value == slot)
            .map((entry) => entry.key)
            .firstOrNull;
    if (cid == null) return true;
    final existingWaiter = _clientClosedWaiters[cid];
    final closed = existingWaiter ?? Completer<void>();
    if (existingWaiter == null) {
      _clientClosedWaiters[cid] = closed;
      _bindings.send(cid, jsonEncode({'@type': 'close'}));
    }
    var didClose = true;
    try {
      await closed.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      didClose = false;
      _unconfirmedSlotForClient[cid] = slot;
    } finally {
      if (identical(_clientClosedWaiters[cid], closed)) {
        _clientClosedWaiters.remove(cid);
      }
      _failPending('TDLib client closed', clientId: cid);
      _slotForClient.remove(cid);
      TdUserIndex.shared.clearSlot(slot);
      _latestChatFoldersByClient.remove(cid);
      _latestEmojiChatThemesByClient.remove(cid);
      _latestTextCompositionStylesByClient.remove(cid);
      _latestCommunitiesByClient.remove(cid);
      if (kDebugMode) unawaited(_persistDebugLiveClientIds());
    }
    if (didClose) _unconfirmedSlotForClient.remove(cid);
    return didClose;
  }

  Future<void> _releaseAccountLease(int slot) async {
    final plan = _accountLeases.release(slot);
    Future<void>? closing;
    if (plan.closeClient) closing = _startClosingSlot(slot);
    if (plan.deleteData && !_slots.contains(slot)) {
      closing ??= _closingSlots[slot]?.then<void>((_) {});
      if (closing != null) await closing;
      await _deleteSlotDataNow(slot);
    }
  }

  void _persist() {
    _prefs.setStringList(_slotsKey, _slots.map((s) => s.toString()).toList());
    _prefs.setInt(_activeKey, _activeSlot);
  }

  int _nextSlot() {
    final occupied = <int>{..._slots, ..._clientForSlot.keys};
    return (occupied.isEmpty ? -1 : occupied.reduce((a, b) => a > b ? a : b)) +
        1;
  }

  String _databaseDirectory(int slot) {
    final base = '$_supportDir/tdlib';
    return slot == 0 ? base : '$base/account-$slot';
  }


  void _route(Map<String, dynamic> object) {
    final clientId = object.integer('@client_id') ?? -1;
    final slot =
        _slotForClient[clientId] ??
        _unconfirmedSlotForClient[clientId] ??
        _activeSlot;
    AvatarAnimationIndex.shared.observe(slot, object);
    TdUserIndex.shared.observe(slot, object);

    final extra = object.str('@extra');
    if (extra != null) {
      final pending = _pending[extra];
      if (pending == null ||
          !tdResponseMatchesRequestClient(
            responseClientId: clientId,
            requestClientId: pending.clientId,
          )) {
        return;
      }
      _pending.remove(extra);
      pending.cancelTimeout();
      if (object.type == 'error') {
        pending.completer.completeError(TdError(object));
      } else {
        pending.completer.complete(object);
      }
      return;
    }

    if (object.type == 'updateAuthorizationState' &&
        object.obj('authorization_state')?.type == 'authorizationStateClosed') {
      TdUserIndex.shared.clearSlot(slot);
      _unconfirmedSlotForClient.remove(clientId);
      final waiter = _clientClosedWaiters.remove(clientId);
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }
    if (!_isShuttingDown &&
        object.type == 'updateAuthorizationState' &&
        object.obj('authorization_state')?.type ==
            'authorizationStateWaitTdlibParameters') {
      _sendParameters(clientId);
    }

    if (object.type == 'updateChatFolders') {
      _latestChatFoldersByClient[clientId] = object;
    }
    if (object.type == 'updateEmojiChatThemes') {
      _latestEmojiChatThemesByClient[clientId] = object;
    }
    if (object.type == 'updateTextCompositionStyles') {
      _latestTextCompositionStylesByClient[clientId] = object;
    }
    if (object.type == 'updateCommunity') {
      final community = object.obj('community');
      final communityId = community?.int64('id');
      if (community != null && communityId != null) {
        _latestCommunitiesByClient.putIfAbsent(
          clientId,
          () => {},
        )[communityId] = object;
      }
    }

    _dispatchToAllSubscribers(object);
    if (clientId == _activeClientId) _dispatchToActiveSubscribers(object);

    if (object.type == '_tdReceiveFatal') {
      _receiveIsolateDead = true;
      _failPending('TDLib receive isolate died');
      debugPrint(
        '🔑 [Handy] receive isolate died: ${object['error'] ?? 'unknown'}',
      );
    }
  }

  void _routeRaw(String message) {
    final object = jsonDecode(message);
    if (object is Map<String, dynamic>) _route(object);
  }

  void _startDebugReceivePump() {
    _debugReceiveTimer?.cancel();
    _debugReceiveTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      for (var i = 0; i < 40; i++) {
        final event = _bindings.receive(0.0);
        if (event == null) break;
        _routeRaw(event);
      }
    });
  }

  Future<void> _closeStaleDebugClients() async {
    final ids = _prefs
        .getStringList(_liveClientIdsKey)
        ?.map(int.tryParse)
        .whereType<int>()
        .toList();
    if (ids == null || ids.isEmpty) return;
    final closedIds = closeStaleDebugTdlibClients(ids, _bindings.send);
    if (closedIds.isNotEmpty) {
      debugPrint(
        '🔑 [Handy] closing stale TDLib clients after hot restart: '
        '${closedIds.join(', ')}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await _prefs.remove(_liveClientIdsKey);
  }

  Future<void> _persistDebugLiveClientIds() {
    return _prefs.setStringList(
      _liveClientIdsKey,
      _clientForSlot.values
          .where((id) => id > 0)
          .map((id) => id.toString())
          .toList(),
    );
  }

  void _sendParameters(int clientId) {
    if (_isShuttingDown || _shutdownComplete) return;
    final slot = _slotForClient[clientId];
    if (slot == null) return;

    final dbDir = _databaseDirectory(slot);
    final filesDir = '$dbDir/files';

    _bindings.send(
      clientId,
      jsonEncode({
        '@type': 'setTdlibParameters',
        'use_test_dc': false,
        'database_directory': dbDir,
        'files_directory': filesDir,
        'use_file_database': true,
        'use_chat_info_database': true,
        'use_message_database': true,
        'use_secret_chats': true,
        'api_id': Secrets.apiId,
        'api_hash': Secrets.apiHash,
        'system_language_code': _safeSystemLanguageCode(),
        'device_model': Platform.isIOS ? 'iPhone' : 'Android',
        'system_version': _safeSystemVersion(),
        'application_version': _appVersion,
      }),
    );
    _bindings.send(clientId, jsonEncode(quickAckTdlibOptionRequest()));
  }

  void sendParametersForActiveClient() {
    final clientId = _activeClientId;
    if (clientId == 0) return;
    _sendParameters(clientId);
  }


  void send(Map<String, dynamic> request) {
    sendTo(request, _activeClientId);
  }

  void sendTo(Map<String, dynamic> request, int clientId) {
    if (_isShuttingDown || _shutdownComplete) return;
    if (!_slotForClient.containsKey(clientId)) return;
    final proxy = _proxyTransport;
    if (proxy != null) {
      unawaited(proxy.send(Map<String, dynamic>.from(request)));
      return;
    }
    _bindings.send(clientId, jsonEncode(request));
  }

  Future<Map<String, dynamic>> query(
    Map<String, dynamic> request, {
    Duration timeout = defaultQueryTimeout,
  }) {
    return queryTo(request, _activeClientId, timeout: timeout);
  }

  Future<Map<String, dynamic>> queryForSlot(
    Map<String, dynamic> request,
    int accountSlot, {
    Duration timeout = defaultQueryTimeout,
  }) {
    final clientId = _clientForSlot[accountSlot];
    if (clientId == null) {
      throw StateError('No TDLib client for account slot $accountSlot');
    }
    return queryTo(request, clientId, timeout: timeout);
  }

  TdAccountLease? retainAccountSlot(int accountSlot) {
    if (_isShuttingDown || _shutdownComplete) return null;
    final clientId = _clientForSlot[accountSlot];
    if (clientId == null || !_slots.contains(accountSlot)) return null;
    _accountLeases.retain(accountSlot);
    return TdAccountLease._(
      accountSlot,
      clientId,
      (request) => queryTo(request, clientId),
      () => _releaseAccountLease(accountSlot),
    );
  }

  Future<Map<String, dynamic>> queryTo(
    Map<String, dynamic> request,
    int clientId, {
    Duration timeout = defaultQueryTimeout,
  }) async {
    if (_isShuttingDown || _shutdownComplete) {
      throw StateError('TDLib is shutting down');
    }
    if (!_slotForClient.containsKey(clientId)) {
      throw StateError('TDLib client $clientId is not registered');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    final proxy = _proxyTransport;
    if (proxy != null) {
      final result = await proxy
          .query(Map<String, dynamic>.from(request))
          .timeout(timeout);
      if (result.type == 'error') throw TdError(result);
      return result;
    }
    final requestType = request.type ?? 'unknown';
    final stopwatch = Stopwatch()..start();
    final extra = _nextExtra();
    final tagged = {...request, '@extra': extra};
    final completer = Completer<Map<String, dynamic>>();
    final pending = _PendingRequest(clientId, completer);
    _pending[extra] = pending;
    pending.timeoutTimer = Timer(timeout, () {
      if (!identical(_pending[extra], pending)) return;
      _pending.remove(extra);
      pending.timeoutTimer = null;
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          TimeoutException('TDLib $requestType request timed out', timeout),
        );
      }
    });
    try {
      _bindings.send(clientId, jsonEncode(tagged));
      final result = await completer.future;
      stopwatch.stop();
      DiagnosticBreadcrumbs.tdlibRequestFinished(
        requestType: requestType,
        elapsed: stopwatch.elapsed,
        resultType: result.type,
      );
      return result;
    } catch (error, stackTrace) {
      if (identical(_pending[extra], pending)) _pending.remove(extra);
      pending.cancelTimeout();
      stopwatch.stop();
      DiagnosticBreadcrumbs.tdlibRequestFinished(
        requestType: requestType,
        elapsed: stopwatch.elapsed,
        failed: true,
        errorCode: error is TdError ? error.code : null,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Map<String, dynamic>? execute(Map<String, dynamic> request) {
    if (_isShuttingDown || _shutdownComplete) return null;
    final result = _bindings.execute(jsonEncode(request));
    if (result == null) return null;
    final decoded = jsonDecode(result);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  String _nextExtra() {
    _extraCounter += 1;
    return 'drachma_$_extraCounter';
  }


  Stream<Map<String, dynamic>> subscribe() => _updates.stream;

  Stream<Map<String, dynamic>> updatesOf(
    String type, {
    bool allAccounts = false,
  }) {
    final controllers = allAccounts ? _typedAllUpdates : _typedUpdates;
    return (controllers[type] ??=
            StreamController<Map<String, dynamic>>.broadcast(sync: true))
        .stream;
  }

  Stream<Map<String, dynamic>> updatesOfAny(
    Iterable<String> types, {
    bool allAccounts = false,
  }) {
    final wanted = types.toSet();
    final subscriptions = <StreamSubscription<Map<String, dynamic>>>[];
    late final StreamController<Map<String, dynamic>> merged;
    merged = StreamController<Map<String, dynamic>>.broadcast(
      sync: true,
      onListen: () {
        for (final type in wanted) {
          subscriptions.add(
            updatesOf(type, allAccounts: allAccounts).listen(merged.add),
          );
        }
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          unawaited(subscription.cancel());
        }
        subscriptions.clear();
      },
    );
    return merged.stream;
  }

  final Map<String, StreamController<Map<String, dynamic>>> _typedUpdates = {};
  final Map<String, StreamController<Map<String, dynamic>>> _typedAllUpdates =
      {};

  void _dispatchToAllSubscribers(Map<String, dynamic> update) {
    _allUpdates.add(update);
    final type = update['@type'];
    if (type is! String) return;
    final typed = _typedAllUpdates[type];
    if (typed != null && typed.hasListener) typed.add(update);
  }

  @visibleForTesting
  void routeUpdateForTesting(Map<String, dynamic> update) => _route(update);

  void _dispatchToActiveSubscribers(Map<String, dynamic> update) {
    _updates.add(update);
    final type = update['@type'];
    if (type is! String) return;
    final typed = _typedUpdates[type];
    if (typed != null && typed.hasListener) typed.add(update);
  }

  Stream<Map<String, dynamic>> subscribeAll() => _allUpdates.stream;

  Stream<int> subscribeActiveSlotChanges() => _activeSlotChanges.stream;

  void emitLocalUpdate(Map<String, dynamic> update) =>
      _dispatchToActiveSubscribers(update);

  String _safeSystemLanguageCode() {
    try {
      final code = Platform.localeName.split('_').first.trim();
      return code.isEmpty ? 'en' : code;
    } catch (_) {
      return 'en';
    }
  }

  String _safeSystemVersion() {
    try {
      final version = Platform.operatingSystemVersion.trim();
      return version.isEmpty ? Platform.operatingSystem : version;
    } catch (_) {
      return Platform.operatingSystem;
    }
  }
}


void _receiveEntry(SendPort toMain) {
  TdBindings bindings;
  try {
    bindings = TdBindings.open();
  } catch (e) {
    toMain.send({'@type': '_tdReceiveFatal', 'error': e.toString()});
    return;
  }

  const batchLimit = 16;
  const batchWindowMicroseconds = 2000;
  var batch = <Object>[];
  final buffered = Stopwatch();

  void flush() {
    if (batch.isEmpty) return;
    toMain.send(batch);
    batch = <Object>[];
    buffered
      ..stop()
      ..reset();
  }

  while (true) {
    Object? event;
    try {
      event = bindings.receiveJson(batch.isEmpty ? 1.0 : 0.0);
    } catch (e) {
      flush();
      toMain.send({'@type': '_tdReceiveFatal', 'error': e.toString()});
      return;
    }
    if (event == null) {
      flush();
      continue;
    }
    if (event is Map<String, dynamic> || event is String) {
      batch.add(event);
    }
    if (batch.isEmpty) continue;
    if (!buffered.isRunning) buffered.start();
    if (batch.length >= batchLimit ||
        buffered.elapsedMicroseconds >= batchWindowMicroseconds) {
      flush();
    }
  }
}
