//
//  td_client.dart
//
//  A thread-safe Dart wrapper around TDLib's `tdjson` JSON client, with
//  multi-account support — the Flutter port of the Swift `TDLibClient`.
//
//  TDLib lets one process host several independent clients (one per account),
//  each created via td_create_client_id() and bootstrapped with its own
//  database directory. A single background **isolate** pumps events for ALL
//  clients (each event carries "@client_id") back to the main isolate, which:
//   • resolves the matching `query` (responses tagged with our "@extra")
//   • bootstraps any client asking for parameters
//   • broadcasts the ACTIVE client's updates to UI subscribers
//
//  Accounts are identified by a stable integer "slot" persisted in
//  SharedPreferences; slot 0 uses the legacy "tdlib" directory so an existing
//  login keeps working. Client ids are per-process and recreated each launch.
//

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

/// An error returned by TDLib (its "error" object).
class TdError implements Exception {
  TdError(Map<String, dynamic> object)
    : code = object.integer('code') ?? 0,
      message = object.str('message') ?? 'Unknown TDLib error';

  final int code;
  final String message;

  @override
  String toString() => 'TDLib error $code: $message';
}

/// An in-flight [TdClient.queryTo], remembered with the client it went to so a
/// closing or dead client can fail exactly its own requests.
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

/// Transport used by a secondary Flutter engine.
///
/// The primary engine remains the sole TDLib/database owner. Secondary engines
/// send ordinary TDLib JSON requests over bounded local IPC and receive the
/// same update objects that the primary engine broadcasts.
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

/// Pure reference-count bookkeeping for long-lived account users.
///
/// Switching the foreground account never closes another slot, but secondary
/// engines and in-flight file work can outlive an explicit account cleanup or
/// session replacement. A requested close/delete is therefore held until the
/// last owner releases its lease.
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

/// Pins one concrete TDLib client for a long-lived video/file owner.
///
/// Queries never consult the current foreground account. Releasing is
/// idempotent so native window close/failure races cannot underflow the lease.
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

  // Lazy: only opened when first used, so demo/simulator builds (no tdjson) can
  // touch the singleton (e.g. read activeSlot) without resolving symbols.
  late final TdBindings _bindings = TdBindings.open();
  TdClientProxyTransport? _proxyTransport;
  StreamSubscription<Map<String, dynamic>>? _proxyUpdateSub;

  bool _isRunning = false;
  bool _isShuttingDown = false;
  bool _shutdownComplete = false;
  Future<void>? _startOperation;
  Future<bool>? _shutdownOperation;
  Timer? _debugReceiveTimer;

  // Receive isolate management — stored as fields so we can restart on resume.
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _receiveSub;
  Isolate? _receiveIsolate;
  Future<void>? _receiveIsolateExited;
  final Set<Future<void>> _receiveIsolateExitFutures = {};
  int _receiveIsolateGeneration = 0;
  bool _receiveIsolateDead = false;

  // Request/response correlation, keyed by the "@extra" we attach.
  final Map<String, _PendingRequest> _pending = {};
  final Map<int, Completer<void>> _clientClosedWaiters = {};
  int _extraCounter = 0;

  // Multicast of the ACTIVE account's updates.
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

  // Accounts
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

  /// Every client currently registered, for callers that need to ask each
  /// account something rather than only the active one.
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

  /// Configures this isolate as a read/write view onto the primary engine.
  /// Must be called before any native TDLib lifecycle is started.
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

  /// Releases a secondary-engine transport when its native window exits.
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
    // Same fan-out as the primary engine, so a secondary window's typed
    // `updatesOf` listeners are fed too and not just `subscribe()`.
    _dispatchToActiveSubscribers(object);
  }

  // MARK: - Lifecycle

  /// Creates a client for every known account and starts the receive isolate.
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
    // Keep TDLib quiet in the console; raise while debugging if needed.
    _bindings.execute(
      jsonEncode({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1}),
    );

    // Prefs, the support directory, and the app version are independent
    // platform channels; resolving them serially costs a full round trip on
    // the launch path.
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

    // Quit can be requested while secure storage is still resolving. Never
    // create a native client after shutdown has taken ownership of the process
    // lifecycle.
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

    // Start receiving before the first asynchronous backend startup. If Quit
    // lands in that window, shutdown must still receive every native
    // authorizationStateClosed acknowledgement before AppKit exits.
    if (kDebugMode) {
      _startDebugReceivePump();
    } else {
      _spawnReceiveIsolate();
    }

    // The first request "activates" each client; TDLib then emits its
    // updateAuthorizationState(authorizationStateWaitTdlibParameters).
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
      // The isolate batches events into one list; the terminal fatal notice is
      // still sent on its own so it can't sit behind a partial batch.
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

  /// Restarts the receive isolate if it died (e.g. after app background→foreground
  /// on Android where the FFI state became stale). Safe to call when healthy.
  void restartReceiveIsolate() {
    if (!_isRunning || _isShuttingDown) return;
    if (kDebugMode) return;
    if (!_receiveIsolateDead) return;

    debugPrint('🔑 [Handy] restarting receive isolate after resume');
    _spawnReceiveIsolate();
  }

  /// Closes every process-owned Telegram client during orderly termination.
  ///
  /// This latch keeps termination cancelable until every native client confirms
  /// authorizationStateClosed and the receive isolate itself has exited.
  /// Persisted accounts, tokens, sessions, and local databases are untouched.
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
      // Shutdown is a process-terminal latch. If Quit is cancelled because a
      // native client failed to close, do not resume ordinary traffic or let a
      // still-running startup operation create replacement clients. A later
      // Quit request can retry the remaining close operation safely.
      rethrow;
    }
  }

  Future<bool> _shutdownOwnedClients() async {
    final starting = _startOperation;
    if (starting != null) {
      try {
        await starting.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        // Startup checks the shutdown latch before creating clients, and Bot
        // API startup checks it again after opening its store. Continue with
        // the clients that already exist instead of hanging AppKit forever.
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

  // MARK: - Account management

  void _ensureAcceptingNewClients() {
    if (_isShuttingDown || _shutdownComplete) {
      throw StateError('TDLib is shutting down');
    }
  }

  /// Creates a fresh account slot (a new TDLib client + database directory)
  /// and returns its slot index. Does not change the active account.
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

  /// Cancels an in-progress QR login and recreates the active unauthenticated
  /// client on a clean database. TDLib persists QR authorization state, and it
  /// rejects setAuthenticationPhoneNumber until the client returns to
  /// authorizationStateWaitPhoneNumber.
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

  /// Routes future query/send/broadcast to the given account slot.
  void setActive(int slot) {
    final cid = _clientForSlot[slot];
    if (cid == null || !_slots.contains(slot)) return;
    final changed = slot != _activeSlot;
    _activeSlot = slot;
    _activeClientId = cid;
    _persist();
    if (changed) _activeSlotChanges.add(slot);
  }

  /// Discards an account slot: closes its TDLib client and forgets it, so it
  /// no longer appears in the switcher. Used to drop a freshly-added account
  /// whose login was aborted. Refuses to remove the active slot (switch away
  /// first) to avoid leaving the UI pointed at a dead client.
  void removeSlot(int slot) {
    if (slot == _activeSlot || !_slots.contains(slot)) return;
    unawaited(_closeAndForgetSlot(slot));
    _persist();
    if (kDebugMode) unawaited(_persistDebugLiveClientIds());
  }

  /// Deletes the local TDLib data for a forgotten slot without contacting
  /// Telegram. Slot 0 is the legacy base directory, so keep account-* child
  /// directories for other slots while removing slot-0 files.
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

  /// Drops the current active slot and replaces it with a clean login client.
  /// Used when the last account is cancelled/logged out: internally TDLib still
  /// needs one active client, but the account switcher can remain empty.
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

  /// Fails every stranded request, optionally only the ones sent to [clientId].
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
      // A completer nothing will answer keeps its awaiting frame suspended
      // forever, retaining everything that frame captured — the State, the view
      // model, decoded bytes. This client is gone, so fail its requests.
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

  /// The database directory for a slot. Slot 0 keeps the legacy path so an
  /// existing single-account login is preserved.
  String _databaseDirectory(int slot) {
    final base = '$_supportDir/tdlib';
    return slot == 0 ? base : '$base/account-$slot';
  }

  // MARK: - Routing (on the main isolate)

  void _route(Map<String, dynamic> object) {
    final clientId = object.integer('@client_id') ?? -1;
    final slot =
        _slotForClient[clientId] ??
        _unconfirmedSlotForClient[clientId] ??
        _activeSlot;
    AvatarAnimationIndex.shared.observe(slot, object);
    TdUserIndex.shared.observe(slot, object);

    // Responses to our requests carry the "@extra" we attached (any client).
    final extra = object.str('@extra');
    if (extra != null) {
      final pending = _pending[extra];
      // Timed-out replies must not escape into the update stream. Likewise, a
      // response carrying another client's id must never complete this query.
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
    // Bootstrap ANY client that asks for parameters, so every account
    // initializes and stays logged in (not just the active one).
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
    // Most UI consumers only need the active account's updates.
    if (clientId == _activeClientId) _dispatchToActiveSubscribers(object);

    // Internal: receive isolate reported a fatal error (e.g. td_receive threw
    // after Android background→foreground). Mark it dead so a later resume
    // restarts it.
    if (object.type == '_tdReceiveFatal') {
      _receiveIsolateDead = true;
      // No response can arrive until the isolate is restarted, and a restart
      // does not replay: everything in flight is stranded.
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
      // `close` is asynchronous inside TDLib. Give the native clients time to
      // release their database handles before creating replacements that use
      // the same account directories.
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
    // Ask Telegram's transport for an early server acknowledgement. TDLib
    // emits updateMessageSendAcknowledged only while this option is enabled;
    // without it the delivery indicator must wait for the slower final result.
    _bindings.send(clientId, jsonEncode(quickAckTdlibOptionRequest()));
  }

  /// Re-sends TDLib parameters for the active client. This is intentionally
  /// idempotent for development hot restart, where Dart state restarts while
  /// tdjson can still be waiting on the bootstrap request.
  void sendParametersForActiveClient() {
    final clientId = _activeClientId;
    if (clientId == 0) return;
    _sendParameters(clientId);
  }

  // MARK: - Sending

  /// Fire-and-forget request to the active account.
  void send(Map<String, dynamic> request) {
    sendTo(request, _activeClientId);
  }

  /// Fire-and-forget request to a specific account client.
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

  /// Sends a request to the active account and awaits its response.
  Future<Map<String, dynamic>> query(
    Map<String, dynamic> request, {
    Duration timeout = defaultQueryTimeout,
  }) {
    return queryTo(request, _activeClientId, timeout: timeout);
  }

  /// Sends a request to the client that owns [accountSlot].
  ///
  /// File ids and chat ids are account-scoped. Long-lived views must keep
  /// using the account that supplied those ids even if the user switches the
  /// app's active account while the request is in flight.
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

  /// Retains the concrete client currently registered for [accountSlot].
  ///
  /// The returned query stays pinned to that client when another account is
  /// selected. Explicit slot removal and local-data deletion are deferred
  /// until every detached window/file owner releases its lease.
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

  /// Sends a request to a SPECIFIC client and awaits its response (used to read
  /// each account's identity for the switcher).
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

  /// Synchronous, network-free request (e.g. log level). Returns parsed JSON.
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

  // MARK: - Updates (multicast)

  /// A fresh stream of the ACTIVE account's TDLib updates.
  Stream<Map<String, dynamic>> subscribe() => _updates.stream;

  /// Updates of exactly one @type from the active account, or from every
  /// configured account when [allAccounts] is true. Prefer this over
  /// [subscribe] + a type filter: during TDLib bursts (login sync, file
  /// progress) every [subscribe] listener runs for every event, while typed
  /// listeners run only for their own type.
  Stream<Map<String, dynamic>> updatesOf(
    String type, {
    bool allAccounts = false,
  }) {
    final controllers = allAccounts ? _typedAllUpdates : _typedUpdates;
    return (controllers[type] ??=
            StreamController<Map<String, dynamic>>.broadcast(sync: true))
        .stream;
  }

  /// Updates of any of [types] from the active account, in arrival order.
  /// With [allAccounts], inactive accounts are included too; consumers must
  /// keep identifiers scoped by the update's `@client_id` as with [subscribeAll].
  ///
  /// The same win as [updatesOf] for a consumer that needs several types: a
  /// [subscribe] listener is woken for every event in the app — including the
  /// highest-rate ones, `updateFile` during a chunked download and the login
  /// sync burst — only to walk its own `switch` and return.
  ///
  /// Order is preserved because every controller on this path is synchronous,
  /// so an event is forwarded and delivered before the next one is dispatched.
  Stream<Map<String, dynamic>> updatesOfAny(
    Iterable<String> types, {
    bool allAccounts = false,
  }) {
    final wanted = types.toSet();
    final subscriptions = <StreamSubscription<Map<String, dynamic>>>[];
    // Lives exactly as long as the stream it hands back; the source
    // subscriptions are dropped in onCancel, so nothing is retained after the
    // consumer lets go.
    // ignore: close_sinks
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
    // Session-lifetime like _allUpdates itself; never closed by design.
    // ignore: close_sinks
    final typed = _typedAllUpdates[type];
    if (typed != null && typed.hasListener) typed.add(update);
  }

  @visibleForTesting
  void routeUpdateForTesting(Map<String, dynamic> update) => _route(update);

  void _dispatchToActiveSubscribers(Map<String, dynamic> update) {
    _updates.add(update);
    final type = update['@type'];
    if (type is! String) return;
    // Session-lifetime like _updates itself; never closed by design.
    // ignore: close_sinks
    final typed = _typedUpdates[type];
    if (typed != null && typed.hasListener) typed.add(update);
  }

  /// Updates from every configured account. Consumers must use @client_id to
  /// keep account-scoped identifiers separate.
  Stream<Map<String, dynamic>> subscribeAll() => _allUpdates.stream;

  Stream<int> subscribeActiveSlotChanges() => _activeSlotChanges.stream;

  /// Broadcasts a local state correction to the same subscribers as TDLib
  /// updates. Use this only after sending the corresponding TDLib request, so
  /// list and badge UI can converge immediately while waiting for TDLib's
  /// eventual aggregate updates.
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

// MARK: - Receive isolate

/// Runs on its own isolate: opens its own handle to the (process-global)
/// tdjson library and pumps every incoming event back to the main isolate.
/// Events are decoded here so the main isolate never pays for JSON parsing
/// during TDLib bursts (login sync, file progress, …).
///
/// On Android, the OS may freeze the process when the app goes to background.
/// After thaw, the native FFI state can be stale and td_receive may throw or
/// crash. We catch the error, notify the main isolate, and exit gracefully —
/// the main isolate will restart us on the next foreground transition.
void _receiveEntry(SendPort toMain) {
  TdBindings bindings;
  try {
    bindings = TdBindings.open();
  } catch (e) {
    toMain.send({'@type': '_tdReceiveFatal', 'error': e.toString()});
    return;
  }

  // One port message per event costs the main isolate one event-loop turn each,
  // and a login sync emits thousands back to back. Batching removes that fixed
  // overhead. The batch is deliberately SMALL: a large one only converts cost
  // spread over many turns into a single uninterruptible chunk, which drops a
  // frame instead of saving one.
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
      // Only block when nothing is buffered — a partial batch must not wait a
      // second for the next event before the UI sees it.
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
    // Malformed events arrive as raw text; the main isolate decides via
    // _routeRaw, so the batch is mixed-type and order carries the meaning.
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
