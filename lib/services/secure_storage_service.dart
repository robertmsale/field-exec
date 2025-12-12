import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const sshPrivateKeyPemKey = 'ssh_private_key_pem';

  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );
  static const _macOsOptions = MacOsOptions();

  final FlutterSecureStorage _storage;

  SecureStorageService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: _iosOptions,
              mOptions: _macOsOptions,
            );

  Future<void> write({required String key, required String value}) {
    return _storage.write(key: key, value: value);
  }

  Future<String?> read({required String key}) {
    return _storage.read(key: key);
  }

  Future<void> delete({required String key}) {
    return _storage.delete(key: key);
  }
}
