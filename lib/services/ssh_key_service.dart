import '../rinf/rust_ssh_service.dart';

class SshKeyService {
  static const defaultComment = 'codex-remote';

  Future<String> generateEd25519PrivateKeyPem({String comment = defaultComment}) {
    return RustSshService.generateEd25519PrivateKeyPem(comment: comment);
  }

  Future<String> toAuthorizedKeysLine({
    required String privateKeyPem,
    String? privateKeyPassphrase,
    String comment = defaultComment,
  }) {
    return RustSshService.toAuthorizedKeysLine(
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase: privateKeyPassphrase,
      comment: comment,
    );
  }
}

