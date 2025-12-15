import 'dart:convert';
import 'dart:io';

import 'package:design_system/design_system.dart';

class LocalSshKeysService {
  static bool get supportsScan => Platform.isMacOS || Platform.isLinux;

  static String? _homeDir() {
    final home = Platform.environment['HOME']?.trim();
    if (home == null || home.isEmpty) return null;
    return home;
  }

  static bool _looksLikePrivateKeyHeader(String text) {
    return text.contains('BEGIN OPENSSH PRIVATE KEY') ||
        text.contains('BEGIN RSA PRIVATE KEY') ||
        text.contains('BEGIN EC PRIVATE KEY') ||
        text.contains('BEGIN DSA PRIVATE KEY');
  }

  static bool _looksEncrypted(String text) {
    final upper = text.toUpperCase();
    if (upper.contains('ENCRYPTED')) return true;
    if (text.contains('bcrypt')) return true;
    if (upper.contains('AES')) return true;
    return false;
  }

  static int _rankFilename(String filename) {
    switch (filename) {
      case 'id_ed25519':
        return 0;
      case 'id_rsa':
        return 1;
      case 'id_ecdsa':
        return 2;
      case 'id_dsa':
        return 3;
      default:
        return 10;
    }
  }

  Future<List<LocalSshKeyCandidate>> scan({int maxCandidates = 50}) async {
    if (!supportsScan) return const [];

    final home = _homeDir();
    if (home == null) return const [];

    final dir = Directory('$home/.ssh');
    if (!await dir.exists()) return const [];

    final entries = await dir.list(followLinks: false).toList();
    final candidates = <LocalSshKeyCandidate>[];

    for (final e in entries) {
      if (e is! File) continue;
      final path = e.path;
      final name = path.split('/').last;
      if (name.isEmpty) continue;
      if (name.endsWith('.pub')) continue;
      if (name == 'known_hosts' ||
          name.startsWith('known_hosts.') ||
          name == 'authorized_keys' ||
          name.startsWith('authorized_keys.') ||
          name == 'config') {
        continue;
      }

      try {
        final bytes = await e
            .openRead(0, 4096)
            .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        final head = utf8.decode(bytes, allowMalformed: true);
        if (!_looksLikePrivateKeyHeader(head)) continue;
        candidates.add(
          LocalSshKeyCandidate(
            path: path,
            looksEncrypted: _looksEncrypted(head),
          ),
        );
      } catch (_) {
        // Ignore unreadable files.
      }

      if (candidates.length >= maxCandidates) break;
    }

    candidates.sort((a, b) {
      if (a.looksEncrypted != b.looksEncrypted) {
        return a.looksEncrypted ? 1 : -1;
      }
      final ra = _rankFilename(a.filename);
      final rb = _rankFilename(b.filename);
      if (ra != rb) return ra.compareTo(rb);
      return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
    });

    return candidates.toList(growable: false);
  }

  Future<String> readPrivateKeyPem(String path) async {
    final file = File(path);
    final raw = (await file.readAsString()).trim();
    if (raw.isEmpty) {
      throw StateError('Key file is empty: $path');
    }
    return raw;
  }
}
