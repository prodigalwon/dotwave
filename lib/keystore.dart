import 'package:flutter/services.dart';

class AndroidKeystore {
  static const _channel = MethodChannel('com.dotwave/keystore');

  static Future<void> generateKey() async {
    await _channel.invokeMethod('generateKey');
  }

  static Future<bool> keyExists() async {
    return await _channel.invokeMethod<bool>('keyExists') ?? false;
  }

  static Future<Uint8List> encrypt(Uint8List data) async {
    final result = await _channel.invokeMethod<Uint8List>('encrypt', {'data': data});
    if (result == null) throw Exception('Keystore encrypt returned null');
    return result;
  }

  static Future<Uint8List> decrypt(Uint8List data) async {
    final result = await _channel.invokeMethod<Uint8List>('decrypt', {'data': data});
    if (result == null) throw Exception('Keystore decrypt returned null');
    return result;
  }
}
