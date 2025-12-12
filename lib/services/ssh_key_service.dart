import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dartssh2/dartssh2.dart';

class SshKeyService {
  static const defaultComment = 'codex-remote';

  /// Generates an unencrypted OpenSSH Ed25519 private key PEM.
  ///
  /// The private key is intended to be stored in Apple Keychain via
  /// `flutter_secure_storage`.
  Future<String> generateEd25519PrivateKeyPem({String comment = defaultComment}) async {
    final seed = _secureRandomBytes(32);
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();

    // OpenSSH Ed25519 private key expects 64 bytes (seed + public key).
    final privateKey64 = Uint8List.fromList(<int>[...seed, ...publicKey.bytes]);

    final openSshKeyPair = OpenSSHEd25519KeyPair(
      Uint8List.fromList(publicKey.bytes),
      privateKey64,
      comment,
    );

    return openSshKeyPair.toPem();
  }

  /// Converts a private key PEM into a single `authorized_keys` line.
  String toAuthorizedKeysLine({
    required String privateKeyPem,
    String? privateKeyPassphrase,
    String comment = defaultComment,
  }) {
    final pairs = SSHKeyPair.fromPem(privateKeyPem, privateKeyPassphrase);
    if (pairs.isEmpty) {
      throw StateError('No keys found in PEM.');
    }
    final pair = pairs.first;
    final wire = pair.toPublicKey().encode();
    final b64 = base64.encode(wire);
    return '${pair.name} $b64 $comment';
  }

  static Uint8List _secureRandomBytes(int length) {
    final r = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = r.nextInt(256);
    }
    return bytes;
  }
}

