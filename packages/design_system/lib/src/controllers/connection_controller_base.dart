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
  RxString get status;
  RxList<ConnectionProfile> get recentProfiles;

  bool get supportsLocalRunner => Platform.isMacOS;

  Future<void> reloadKeyFromKeychain();
  Future<void> savePrivateKeyToKeychain();
  Future<void> runLocalCodex();
  Future<void> testSshConnection();
}
