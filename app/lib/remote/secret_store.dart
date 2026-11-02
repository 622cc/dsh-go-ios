import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where remote-access secrets live: SSH passwords and private keys, relay
/// device credentials. Never SharedPreferences.
///
/// Injectable so state and tests can swap in [MemorySecretStore], and so the
/// relay package (`dsh_remote`) can be handed the same store.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Storage backed by SharedPreferences on iOS TrollStore (where Ad-Hoc signing
/// lacks Apple Team ID Keychain entitlements) with FlutterSecureStorage fallback.
class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final Map<String, String> _mem = {};

  /// Every key is namespaced so remote secrets never collide with app settings.
  static String _k(String key) => 'remote.$key';
  static String _pk(String key) => 'trollstore.secret.remote.$key';

  @override
  Future<String?> read(String key) async {
    final k = _k(key);
    if (_mem.containsKey(k)) return _mem[k];
    try {
      final prefs = await SharedPreferences.getInstance();
      final val = prefs.getString(_pk(key));
      if (val != null) {
        _mem[k] = val;
        return val;
      }
    } catch (_) {}
    try {
      return await _storage.read(key: k);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final k = _k(key);
    _mem[k] = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pk(key), value);
    } catch (_) {}
    try {
      await _storage.write(key: k, value: value);
    } catch (_) {}
  }

  @override
  Future<void> delete(String key) async {
    final k = _k(key);
    _mem.remove(k);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pk(key));
    } catch (_) {}
    try {
      await _storage.delete(key: k);
    } catch (_) {}
  }
}

/// In-memory store for tests and previews.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
