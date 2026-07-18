import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DeviceIdUtil {
  static const _fallbackKey = 'device_id_fallback';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<String> getDeviceId() async {
    // iOS: identifierForVendor resets when the user deletes every app from
    // this vendor and reinstalls, silently breaking device binding. Keychain
    // entries survive app deletion, so a self-generated UUID persisted there
    // is more stable than the platform identifier on this OS specifically.
    if (Platform.isIOS) {
      final stored = await _storage.read(key: _fallbackKey);
      if (stored != null && stored.isNotEmpty) return stored;

      final generated = _generateUuid();
      await _storage.write(key: _fallbackKey, value: generated);
      return generated;
    }

    String? id;

    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        id = info.id;
      } else if (Platform.isWindows) {
        id = await _getMachineGuid();
      }
    } catch (_) {
      id = null;
    }

    if (id != null && id.isNotEmpty) return id;

    String? stored = await _storage.read(key: _fallbackKey);
    if (stored != null && stored.isNotEmpty) return stored;

    final generated = _generateUuid();
    await _storage.write(key: _fallbackKey, value: generated);
    return generated;
  }

  static Future<String?> _getMachineGuid() async {
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKLM\SOFTWARE\Microsoft\Cryptography',
        '/v', 'MachineGuid',
      ]);
      final out = result.stdout as String;
      final m = RegExp(r'MachineGuid\s+REG_SZ\s+(\S+)').firstMatch(out);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  static String _generateUuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    return '${bytes.sublist(0, 4).map(hex).join()}'
        '-${bytes.sublist(4, 6).map(hex).join()}'
        '-${bytes.sublist(6, 8).map(hex).join()}'
        '-${bytes.sublist(8, 10).map(hex).join()}'
        '-${bytes.sublist(10).map(hex).join()}';
  }
}
