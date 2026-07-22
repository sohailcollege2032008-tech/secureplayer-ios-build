import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    // Hardware-backed on Android via EncryptedSharedPreferences + Android Keystore
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> storeKey(String courseId, String keyHex) =>
      _storage.write(key: _keyName(courseId), value: keyHex);

  Future<String?> getKey(String courseId) =>
      _storage.read(key: _keyName(courseId));

  Future<void> deleteKey(String courseId) =>
      _storage.delete(key: _keyName(courseId));

  Future<bool> hasKey(String courseId) async {
    final v = await _storage.read(key: _keyName(courseId));
    return v != null && v.isNotEmpty;
  }

  /// Wipes every entry (course keys + cached student profile) — used on
  /// account deletion, since none of it is meaningful once the account
  /// it belongs to no longer exists.
  Future<void> deleteAll() => _storage.deleteAll();

  static String _keyName(String courseId) => 'course_key_$courseId';
}
