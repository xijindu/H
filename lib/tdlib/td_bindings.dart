import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _CreateClientIdC = Int32 Function();
typedef _CreateClientIdDart = int Function();

typedef _SendC = Void Function(Int32 clientId, Pointer<Utf8> request);
typedef _SendDart = void Function(int clientId, Pointer<Utf8> request);

typedef _ReceiveC = Pointer<Utf8> Function(Double timeout);
typedef _ReceiveDart = Pointer<Utf8> Function(double timeout);

typedef _ExecuteC = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _ExecuteDart = Pointer<Utf8> Function(Pointer<Utf8> request);

class TdBindings {
  TdBindings._(DynamicLibrary lib)
    : _createClientId = lib
          .lookupFunction<_CreateClientIdC, _CreateClientIdDart>(
            'td_create_client_id',
          ),
      _send = lib.lookupFunction<_SendC, _SendDart>('td_send'),
      _receive = lib.lookupFunction<_ReceiveC, _ReceiveDart>('td_receive'),
      _execute = lib.lookupFunction<_ExecuteC, _ExecuteDart>('td_execute');

  factory TdBindings.open() => TdBindings._(_openLibrary());

  final _CreateClientIdDart _createClientId;
  final _SendDart _send;
  final _ReceiveDart _receive;
  final _ExecuteDart _execute;

  int createClientId() => _createClientId();

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libtdjson.so');
    }
    if (Platform.isIOS) {
      try {
        return DynamicLibrary.open('tdjson.framework/tdjson');
      } on ArgumentError {
        return DynamicLibrary.process();
      }
    }
    return DynamicLibrary.open('libtdjson.so');
  }

  void send(int clientId, String request) {
    final ptr = request.toNativeUtf8();
    try {
      _send(clientId, ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  String? receive(double timeout) {
    final ptr = _receive(timeout);
    if (ptr == nullptr) return null;
    return ptr.toDartString();
  }

  Object? receiveJson(double timeout) {
    final ptr = _receive(timeout);
    if (ptr == nullptr) return null;
    final bytes = ptr.cast<Uint8>().asTypedList(ptr.length);
    try {
      return _utf8Json.convert(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static final Converter<List<int>, Object?> _utf8Json = const Utf8Decoder()
      .fuse(const JsonDecoder());

  String? execute(String request) {
    final reqPtr = request.toNativeUtf8();
    try {
      final out = _execute(reqPtr);
      if (out == nullptr) return null;
      return out.toDartString();
    } finally {
      malloc.free(reqPtr);
    }
  }
}
