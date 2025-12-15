import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../models/connection_profile.dart';

abstract class ConnectionControllerBase extends GetxController {
  TextEditingController get userAtHostController;
  TextEditingController get portController;
  TextEditingController get privateKeyPemController;
  TextEditingController get privateKeyPassphraseController;

  RxBool get useLocalRunner;
  Rx<PosixShell> get remoteShell;

  RxBool get isBusy;
  RxBool get hasSavedPrivateKey;
  RxBool get requiresSshBootstrap;
  RxBool get checkingLocalKeys;
  RxString get status;
  RxList<ConnectionProfile> get recentProfiles;

  bool get supportsLocalRunner => Platform.isMacOS;

  Future<void> reloadKeyFromKeychain();
  Future<void> savePrivateKeyToKeychain();
  Future<void> savePrivateKeyPem(String pem);
  Future<String> generateNewPrivateKeyPem();
  Future<List<String>> listHostPrivateKeys({
    required String userAtHost,
    required int port,
    required String password,
  });
  Future<String> readHostPrivateKeyPem({
    required String userAtHost,
    required int port,
    required String password,
    required String remotePath,
  });
  Future<String> authorizedKeysLineFromPrivateKey({
    required String privateKeyPem,
    String? privateKeyPassphrase,
  });
  Future<void> installPublicKeyWithPassword({
    required String userAtHost,
    required int port,
    required String password,
    required String privateKeyPem,
    String? privateKeyPassphrase,
  });
  Future<void> runLocalCodex();
  Future<void> testSshConnection();
}
